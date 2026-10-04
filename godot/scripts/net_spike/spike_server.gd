extends SceneTree
##
## Спайк сети PvP: безголовый авторитетный сервер (docs/pvp/DESIGN.md §6, §10).
## НЕ часть игры. Запуск (tools/net_spike.sh делает это сам):
##   godot --headless --path godot --script res://scripts/net_spike/spike_server.gd -- --mute
##       [--port 24580] [--units 150] [--tick-hz 60] [--snap-hz 20] [--duration 12]
##       [--code ABC123] [--max-fps 0]
##
## Сервер сам считает «бой» (условный: N бойцов двух сторон бродят по полю 1280×720),
## принимает только проверенные команды и рассылает снимки. В конце — строка JSON с замером:
## цена тика, байты снимка, отказы проверки, выгнанные.
##

const Proto := preload("res://scripts/net_spike/spike_proto.gd")

const FIELD := Vector2(1280.0, 720.0)
const UNIT_SPEED := 70.0
const PULL_R := 120.0
const HIT_R := 90.0
const HIT_DMG := 10
const HP_MAX := 30
## Частота команд на клиента: ведро токенов. Живой игрок чертит линию раз в секунды, штрих
## уходит одной командой, так что 20/с с запасом 20 — втрое выше самого быстрого человека.
const CMD_RATE := 20.0
const CMD_BURST := 20.0
## Сколько нарушений (длина, версия, границы, частота, команда до HELLO) терпим до разрыва.
const KICK_AFTER := 25
## Пакеты длиннее этого не разбираем вовсе — отказ до чтения полей.
const MAX_PACKET := 64
## Сервер без игроков после первого подключения — выход через столько секунд.
const IDLE_QUIT := 1.0

var peer := ENetMultiplayerPeer.new()
var port := 24580
var n_units := 150
var tick_hz := 60
var snap_hz := 20
var duration := 12.0
var code := "ABC123"

var pos := PackedVector2Array()
var vel := PackedVector2Array()
var goal := PackedVector2Array()
var hp := PackedByteArray()
var flags := PackedByteArray()
var rng := RandomNumberGenerator.new()

var tick := 0
var elapsed := 0.0
var idle := 0.0
var ever_connected := false
## peer id → {side, hello, ack, tokens, bad, bytes_out, snaps}
var peers: Dictionary = {}
var stats := {
	"rejected_len": 0, "rejected_ver": 0, "rejected_type": 0, "rejected_bounds": 0,
	"rejected_rate": 0, "rejected_no_hello": 0, "rejected_code": 0, "kicked": 0,
	"cmds_applied": 0, "connected": 0,
}
var _tick_us: Array[int] = []
var _snap_bytes := 0
var _frames := 0


func _initialize() -> void:
	var a := _args()
	port = int(a.get("port", port))
	n_units = int(a.get("units", n_units))
	tick_hz = int(a.get("tick-hz", tick_hz))
	snap_hz = int(a.get("snap-hz", snap_hz))
	duration = float(a.get("duration", duration))
	code = String(a.get("code", code))
	# Безголовый движок без ограничения крутит _process вхолостую на всё ядро; серверу нужен
	# только физический тик. --max-fps 0 — оставить без ограничения (замер «как было бы»).
	Engine.max_fps = int(a.get("max-fps", tick_hz))
	Engine.physics_ticks_per_second = tick_hz
	rng.seed = 7
	for i in n_units:
		var side := 0 if i < n_units / 2 else 1
		var x0 := 0.0 if side == 0 else FIELD.x * 0.5
		pos.append(Vector2(x0 + rng.randf_range(20.0, FIELD.x * 0.5 - 20.0),
			rng.randf_range(20.0, FIELD.y - 20.0)))
		vel.append(Vector2.from_angle(rng.randf() * TAU) * UNIT_SPEED)
		goal.append(Vector2(-1.0, -1.0))
		hp.append(HP_MAX)
		flags.append(side)
	var err := peer.create_server(port, 2, Proto.CHANNELS)
	if err != OK:
		print(JSON.stringify({"role": "server", "error": "create_server", "code": err}))
		quit(2)
		return
	peer.peer_connected.connect(_on_connected)
	peer.peer_disconnected.connect(_on_disconnected)
	print(JSON.stringify({"role": "server", "listening": port, "units": n_units,
		"tick_hz": tick_hz, "snap_hz": snap_hz}))


func _args() -> Dictionary:
	var out := {}
	var list := OS.get_cmdline_user_args()
	var i := 0
	while i < list.size():
		var k := list[i]
		if k.begins_with("--") and i + 1 < list.size() and not list[i + 1].begins_with("--"):
			out[k.substr(2)] = list[i + 1]
			i += 2
		else:
			out[k.trim_prefix("--")] = true
			i += 1
	return out


func _process(_delta: float) -> bool:
	_frames += 1
	return false


func _physics_process(delta: float) -> bool:
	var t0 := Time.get_ticks_usec()
	peer.poll()
	_read_packets()
	_sim(delta)
	tick += 1
	if tick % maxi(1, tick_hz / snap_hz) == 0:
		_send_snapshots()
	_tick_us.append(Time.get_ticks_usec() - t0)
	elapsed += delta
	if ever_connected and peers.is_empty():
		idle += delta
	if elapsed >= duration or idle >= IDLE_QUIT:
		_report()
		return true
	return false


func _on_connected(id: int) -> void:
	ever_connected = true
	stats["connected"] = int(stats["connected"]) + 1
	peers[id] = {"side": -1, "hello": false, "ack": 0, "tokens": CMD_BURST, "bad": 0,
		"bytes_out": 0, "snaps": 0, "since": elapsed}


func _on_disconnected(id: int) -> void:
	peers.erase(id)


func _read_packets() -> void:
	for p: Dictionary in peers.values():
		p["tokens"] = minf(CMD_BURST, float(p["tokens"]) + CMD_RATE / float(tick_hz))
	while peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var b := peer.get_packet()
		if not peers.has(from):
			continue
		_handle(from, peers[from], b)


# gdlint: disable=max-returns
## Проверка идёт лестницей «дешёвое и опасное — первым»: длина до чтения полей, версия, код
## матча, потом частота и границы. Каждая ступень — ранний выход, поэтому возвратов много.
func _handle(from: int, p: Dictionary, b: PackedByteArray) -> void:
	if b.size() > MAX_PACKET or b.size() < 2:
		_bad(from, p, "rejected_len")
		return
	if b.decode_u8(0) != Proto.VERSION:
		_bad(from, p, "rejected_ver")
		return
	var t := b.decode_u8(1)
	if t == Proto.T_HELLO:
		if b.size() != Proto.HELLO_LEN or b.slice(2, 8).get_string_from_ascii() != code:
			stats["rejected_code"] = int(stats["rejected_code"]) + 1
			_kick(from)
			return
		p["hello"] = true
		p["side"] = _free_side()
		_send(from, Proto.welcome(int(p["side"]), n_units), Proto.CH_CMD,
			MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		return
	if not bool(p["hello"]):
		_bad(from, p, "rejected_no_hello")
		return
	if t != Proto.T_CMD or b.size() != Proto.CMD_LEN:
		_bad(from, p, "rejected_type")
		return
	if float(p["tokens"]) < 1.0:
		_bad(from, p, "rejected_rate")
		return
	p["tokens"] = float(p["tokens"]) - 1.0
	var at := Vector2(Proto.dq(b.decode_u16(7)), Proto.dq(b.decode_u16(9)))
	var kind := b.decode_u8(6)
	if not Rect2(Vector2.ZERO, FIELD).has_point(at) or kind not in [Proto.K_PULL, Proto.K_HIT]:
		_bad(from, p, "rejected_bounds")
		return
	_apply(int(p["side"]), kind, at)
	p["ack"] = b.decode_u32(2)
	stats["cmds_applied"] = int(stats["cmds_applied"]) + 1


func _free_side() -> int:
	var used := {}
	for p: Dictionary in peers.values():
		used[int(p["side"])] = true
	return 0 if not used.has(0) else 1


func _bad(from: int, p: Dictionary, key: String) -> void:
	stats[key] = int(stats[key]) + 1
	p["bad"] = int(p["bad"]) + 1
	if int(p["bad"]) >= KICK_AFTER:
		_kick(from)


func _kick(from: int) -> void:
	stats["kicked"] = int(stats["kicked"]) + 1
	peers.erase(from)
	peer.disconnect_peer(from)


func _apply(side: int, kind: int, at: Vector2) -> void:
	for i in n_units:
		var mine := int(flags[i]) & 1 == side
		if kind == Proto.K_PULL and mine and pos[i].distance_to(at) <= PULL_R:
			goal[i] = at
		elif kind == Proto.K_HIT and not mine and pos[i].distance_to(at) <= HIT_R:
			hp[i] = maxi(0, int(hp[i]) - HIT_DMG)


func _sim(dt: float) -> void:
	for i in n_units:
		if hp[i] == 0:
			continue
		var v := vel[i]
		if goal[i].x >= 0.0:
			var d := goal[i] - pos[i]
			if d.length() < 4.0:
				goal[i] = Vector2(-1.0, -1.0)
			else:
				v = d.normalized() * UNIT_SPEED
		var p := pos[i] + v * dt
		if p.x < 0.0 or p.x > FIELD.x:
			v.x = -v.x
		if p.y < 0.0 or p.y > FIELD.y:
			v.y = -v.y
		pos[i] = p.clamp(Vector2.ZERO, FIELD)
		vel[i] = v


func _send_snapshots() -> void:
	var body := Proto.snap_body(pos, hp, flags)
	for id: int in peers.keys():
		var p: Dictionary = peers[id]
		if not bool(p["hello"]):
			continue
		var pkt := Proto.snap(tick, int(p["ack"]), n_units, body)
		_send(id, pkt, Proto.CH_SNAP, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
		p["bytes_out"] = int(p["bytes_out"]) + pkt.size()
		p["snaps"] = int(p["snaps"]) + 1
		_snap_bytes = pkt.size()


func _send(id: int, pkt: PackedByteArray, ch: int, mode: MultiplayerPeer.TransferMode) -> void:
	peer.transfer_channel = ch
	peer.transfer_mode = mode
	peer.set_target_peer(id)
	peer.put_packet(pkt)


func _report() -> void:
	var s := _tick_us.duplicate()
	s.sort()
	var total := 0
	for v: int in s:
		total += v
	var n := maxi(1, s.size())
	var out := stats.duplicate()
	out["role"] = "server"
	out["ticks"] = tick
	out["seconds"] = snappedf(elapsed, 0.01)
	out["process_frames"] = _frames
	out["tick_us_avg"] = snappedf(float(total) / float(n), 0.1)
	out["tick_us_p99"] = s[mini(s.size() - 1, int(s.size() * 0.99))] if not s.is_empty() else 0
	out["tick_us_max"] = s[-1] if not s.is_empty() else 0
	out["snap_bytes"] = _snap_bytes
	out["snap_kbps_per_client"] = snappedf(float(_snap_bytes * snap_hz) / 1024.0, 0.1)
	print(JSON.stringify(out))
	peer.close()
