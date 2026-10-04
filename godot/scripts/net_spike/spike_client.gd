extends SceneTree
##
## Спайк сети PvP: клиент (docs/pvp/DESIGN.md §6, §10). НЕ часть игры. Без окна: мерит сеть,
## а не рисование. Запуск:
##   godot --headless --path godot --script res://scripts/net_spike/spike_client.gd -- --mute
##       [--host 127.0.0.1] [--port 24580] [--code ABC123] [--duration 8] [--cmd-hz 4]
##       [--evil]    — вредный клиент: залп команд, длинный пакет, точка за полем
##       [--badcode] — неверный код матча (сервер должен сразу разорвать)
##
## Задержка «команда → видно в состоянии»: клиент помнит время отправки каждой команды,
## сервер возвращает номер последней применённой (ack) в шапке снимка; разница — то, что
## почувствует игрок, без предсказания. Отдельно — RTT самого ENet.
##

const Proto := preload("res://scripts/net_spike/spike_proto.gd")

const FIELD := Vector2(1280.0, 720.0)
## Сколько секунд ждём подключения, прежде чем признать провал.
const CONNECT_TIMEOUT := 3.0
## Залп вредного клиента: больше ведра токенов сервера (CMD_BURST 20) и порога разрыва.
const EVIL_BURST := 300

var peer := ENetMultiplayerPeer.new()
var host := "127.0.0.1"
var port := 24580
var code := "ABC123"
var duration := 8.0
var cmd_hz := 4.0
var evil := false

var side := -1
var seq := 0
var sent_at: Dictionary = {}   ## seq → usec
var lat_ms: Array[float] = []
var rtt_ms: Array[float] = []
var snaps := 0
var snap_bytes := 0
var last_tick := -1
var out_of_order := 0
var hp_first := -1
var hp_last := -1
var units_seen := 0
var elapsed := 0.0
var _cmd_t := 0.0
var _welcomed := false
var _closed := false
var _evil_done := false
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	var a := _args()
	host = String(a.get("host", host))
	port = int(a.get("port", port))
	code = String(a.get("code", code))
	duration = float(a.get("duration", duration))
	cmd_hz = float(a.get("cmd-hz", cmd_hz))
	evil = a.has("evil")
	if a.has("badcode"):
		code = "WRONG1"
	Engine.max_fps = 120
	_rng.seed = hash(str(OS.get_process_id()))
	var err := peer.create_client(host, port, Proto.CHANNELS)
	if err != OK:
		_finish({"error": "create_client", "code": err})
		return
	peer.peer_connected.connect(func(_id: int) -> void:
		_send(Proto.hello(code), Proto.CH_CMD))
	peer.peer_disconnected.connect(func(_id: int) -> void: _closed = true)


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


func _process(delta: float) -> bool:
	elapsed += delta
	peer.poll()
	while peer.get_available_packet_count() > 0:
		_on_packet(peer.get_packet())
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		var ep := peer.get_peer(1)
		if ep != null:
			rtt_ms.append(ep.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
	if _welcomed and not _closed:
		if evil and not _evil_done:
			_evil()
		elif not evil:
			_cmd_t -= delta
			if _cmd_t <= 0.0:
				_cmd_t = 1.0 / cmd_hz
				_send_cmd()
	var stuck := not _welcomed and elapsed > CONNECT_TIMEOUT
	if elapsed >= duration or _closed or stuck:
		_finish({})
		return true
	return false


func _send_cmd() -> void:
	seq += 1
	# своя половина — PULL (перебежка своих), чужая — HIT (удар по чужим)
	var kind := Proto.K_PULL if seq % 2 == 0 else Proto.K_HIT
	var half_x := 0.0 if (kind == Proto.K_PULL) == (side == 0) else FIELD.x * 0.5
	var at := Vector2(half_x + _rng.randf_range(40.0, FIELD.x * 0.5 - 40.0),
		_rng.randf_range(40.0, FIELD.y - 40.0))
	sent_at[seq] = Time.get_ticks_usec()
	_send(Proto.cmd(seq, kind, at), Proto.CH_CMD)


func _evil() -> void:
	_evil_done = true
	# длинный пакет и точка за полем — первыми: после залпа сервер разорвёт связь и их не увидит
	var big := PackedByteArray()
	big.resize(4000)
	_send(big, Proto.CH_CMD)
	seq += 1
	_send(Proto.cmd(seq, Proto.K_HIT, Vector2(5000.0, 7000.0)), Proto.CH_CMD)
	for i in EVIL_BURST:
		seq += 1
		_send(Proto.cmd(seq, Proto.K_HIT, Vector2(640.0, 360.0)), Proto.CH_CMD)


func _on_packet(b: PackedByteArray) -> void:
	if b.size() < 2 or b.decode_u8(0) != Proto.VERSION:
		return
	match b.decode_u8(1):
		Proto.T_WELCOME:
			side = b.decode_u8(2)
			_welcomed = true
		Proto.T_SNAP:
			_on_snap(b)
		_:
			pass


func _on_snap(b: PackedByteArray) -> void:
	var now := Time.get_ticks_usec()
	snaps += 1
	snap_bytes += b.size()
	var t := b.decode_u32(2)
	if t <= last_tick:
		out_of_order += 1
	last_tick = t
	var ack := b.decode_u32(6)
	for s: int in sent_at.keys():
		if s <= ack:
			lat_ms.append(float(now - int(sent_at[s])) / 1000.0)
			sent_at.erase(s)
	var n := b.decode_u16(10)
	units_seen = n
	var total := 0
	for i in n:
		total += b.decode_u8(Proto.SNAP_HDR + i * Proto.UNIT_LEN + 6)
	if hp_first < 0:
		hp_first = total
	hp_last = total


func _send(pkt: PackedByteArray, ch: int) -> void:
	peer.transfer_channel = ch
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	peer.set_target_peer(1)
	peer.put_packet(pkt)


static func _pct(a: Array[float], k: float) -> float:
	if a.is_empty():
		return -1.0
	var s := a.duplicate()
	s.sort()
	return snappedf(s[mini(s.size() - 1, int(s.size() * k))], 0.01)


func _finish(extra: Dictionary) -> void:
	var out := {
		"role": "client", "evil": evil, "side": side, "welcomed": _welcomed,
		"closed_by_server": _closed, "seconds": snappedf(elapsed, 0.01),
		"cmds_sent": seq, "cmds_acked": seq - sent_at.size(), "snaps": snaps,
		"snaps_per_s": snappedf(float(snaps) / maxf(0.01, elapsed), 0.1),
		"kb_per_s": snappedf(float(snap_bytes) / 1024.0 / maxf(0.01, elapsed), 0.1),
		"units_seen": units_seen, "out_of_order": out_of_order,
		"hp_first": hp_first, "hp_last": hp_last,
		"lat_ms_p50": _pct(lat_ms, 0.5), "lat_ms_p95": _pct(lat_ms, 0.95),
		"lat_ms_max": _pct(lat_ms, 1.0), "rtt_ms_p50": _pct(rtt_ms, 0.5),
	}
	out.merge(extra)
	print(JSON.stringify(out))
	peer.close()
