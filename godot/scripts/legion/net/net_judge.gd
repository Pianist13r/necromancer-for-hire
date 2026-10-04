extends SceneTree
##
## Сервер-судья онлайн-«Схватки» (Игорь 01.10: «сервер считает бой»; docs/pvp/NET_LOCKSTEP.md).
## Ретранслятор запускает судью отдельным процессом на каждый матч. Судья — невидимый третий
## участник комнаты: получает ввод ОБЕИХ сторон, считает тот же бой тем же порядком, что NetSession
## у игроков (команды хода t — в начале тика t·TURN, сторона 0, потом 1), и шлёт свой отпечаток
## каждые HASH_EVERY тиков. Ретранслятор сверяет отпечаток каждого игрока с судейским: разошёлся —
## значит, ошибся именно этот игрок; итог матча — судейский.
##
##   godot --headless --path godot --fixed-fps 60 --script res://scripts/legion/net/net_judge.gd \
##       -- --mute --url ws://127.0.0.1:18765 --room KXRT --key <ключ>
## --fixed-fps 60 без окна — судья шагает так быстро, как приходит ввод, и никогда не отстаёт.
##
## Подтяжка (Игорь 01.10: «бой корректируется с этим судьёй сразу… незаметно для игрока»):
## ретранслятор, заметив, что сторона s разошлась с судьёй, шлёт судье {"t":"heal","s","id"}.
## Судья снимает снимок боя (NetSnap) на своём текущем тике — между шагами, — сжимает и шлёт
## кусками {"t":"snap"} (NetSession.snap_parts); ретранслятор передаёт их только стороне s.
##

const TIMEOUT_MS := 2 * 60 * 60 * 1000
## Кусков снимка за кадр судьи не больше: ретранслятор читает судью буфером в 64 КБ.
const SNAP_PARTS_PER_FRAME := 2
## Исходящий буфер судьи держим не выше этого, пока идут куски снимка.
const SNAP_OUT_BUF := 32768

var w: LegionWorld
var _ws := WebSocketPeer.new()
var _url := "ws://127.0.0.1:18765"
var _room := ""
var _key := ""
var _hello_sent := false
var _turns: Array[Dictionary] = [{}, {}]
var _applied_turn := -1
var _started := false
var _over := false
var _born := 0
## Куски снимков, ждущие отправки (по SNAP_PARTS_PER_FRAME за кадр).
var _snap_q: Array[Dictionary] = []
## --snap-limit N: снимок длиннее N знаков не шлётся (проба tools/net_heal.sh big);
## по умолчанию — предел NetSession.
var _snap_limit := NetSession.SNAP_PART * NetSession.SNAP_PARTS_MAX


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		match args[i]:
			"--url":
				_url = args[i + 1]
			"--room":
				_room = args[i + 1]
			"--key":
				_key = args[i + 1]
			"--snap-limit":
				_snap_limit = int(args[i + 1])
	_born = Time.get_ticks_msec()
	_ws.inbound_buffer_size = 1 << 20
	_ws.max_queued_packets = 4096
	if _ws.connect_to_url(_url) != OK:
		print("[judge %s] не подключиться к %s" % [_room, _url])
		quit(1)


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() - _born > TIMEOUT_MS:
		quit(0)
		return true
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		quit(0)
		return true
	if st != WebSocketPeer.STATE_OPEN:
		return false
	if not _hello_sent:
		_hello_sent = true
		_send({"t": "judge", "v": NetSession.PROTO, "room": _room, "key": _key})
	while _ws.get_available_packet_count() > 0:
		var msg: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if msg is Dictionary:
			_handle(msg as Dictionary)
	_pump_snap()
	if _started and not _over:
		_advance()
	return false


## Куски снимков — понемногу за кадр и не переполняя свой исходящий буфер: ретранслятор читает
## судью тем же сокетом, что и игроков (буфер приёма 64 КБ).
func _pump_snap() -> void:
	var n := 0
	while not _snap_q.is_empty() and n < SNAP_PARTS_PER_FRAME \
			and _ws.get_current_outbound_buffered_amount() < SNAP_OUT_BUF:
		_send(_snap_q.pop_front())
		n += 1


func _handle(msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"start":
			_start(String(msg.get("map", "pvp:duel")), int(msg.get("seed", 1)))
		"in":
			# ход игрока — его исходный текст, разобранный ровно так, как у соперника (NetSession)
			var s := int(msg.get("s", -1))
			var inner: Variant = JSON.parse_string(String(msg.get("raw", "")))
			if not (inner is Dictionary) or not s in [0, 1]:
				return
			var k := int((inner as Dictionary).get("k", -1))
			var c: Variant = (inner as Dictionary).get("c", [])
			# первые DELAY_MIN ходов пусты у всех (заготовлены в _start); прочие — как пришли, один раз
			if k >= NetSession.DELAY_MIN and k > _applied_turn and c is Array \
					and not (_turns[s] as Dictionary).has(k):
				_turns[s][k] = c
		"left":
			_over = true
			_send({"t": "verdict", "why": "left", "tick": w.net_tick if w != null else -1})
		"heal":
			_heal(int(msg.get("s", -1)), int(msg.get("id", -1)))


## Снимок для разошедшейся стороны s — на текущем тике судьи (сюда попадаем между шагами мира:
## _handle зовётся до _advance). Решённый матч тоже снимается: у клиента, который ещё бьётся в
## разошедшемся бою, он закончит матч итогом судьи (сторону рассудит SnapWorld.finish).
func _heal(s: int, id: int) -> void:
	if w == null or not _started or not s in [0, 1] or id < 0:
		return
	var parts := NetSession.snap_parts(w.snapshot(), _snap_limit)
	if parts.is_empty():
		print("[judge %s] снимок для стороны %d слишком большой — не отправлен" % [_room, s])
		# ретранслятор не ждёт HEAL_WAIT_MS: подтяжка не состоялась сразу, игроку — надпись
		_send({"t": "heal_fail", "s": s, "id": id, "why": "снимок слишком большой"})
		return
	for i in parts.size():
		_snap_q.append({"t": "snap", "s": s, "id": id, "k": w.net_tick, "i": i,
			"n": parts.size(), "d": parts[i]})
	print("[judge %s] снимок для стороны %d на тике %d: %d кусков" % [_room, s, w.net_tick,
		parts.size()])


func _start(map_id: String, seed_value: int) -> void:
	Campaign.set_save_path("user://judge_%s.cfg" % _room)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.start_net_match(map_id, seed_value, 0)
	# первые DELAY_MIN ходов у игроков пусты (NetSession.attach) — у судьи так же
	for t in NetSession.DELAY_MIN:
		for s in 2:
			if not (_turns[s] as Dictionary).has(t):
				_turns[s][t] = []
	_started = true
	print("[judge %s] матч: карта %s, сид %d" % [_room, map_id, seed_value])


## Шагать, пока есть ввод обеих сторон: судья не ждёт реального времени.
func _advance() -> void:
	var guard := 0
	while guard < 4000 and w.net_can_step():
		guard += 1
		var tick := w.net_tick
		if tick % NetSession.TURN == 0 and tick / NetSession.TURN > _applied_turn:
			var t := tick / NetSession.TURN
			if not ((_turns[0] as Dictionary).has(t) and (_turns[1] as Dictionary).has(t)):
				return
			_applied_turn = t
			for s in 2:
				var cmds: Array = (_turns[s] as Dictionary).get(t, [])
				(_turns[s] as Dictionary).erase(t)
				for raw: Variant in cmds:
					var cmd := NetCodec.decode(raw)
					if not cmd.is_empty():
						w.net_apply(s, cmd)
		w.net_step()
		if w.net_tick % NetSession.HASH_EVERY == 0:
			_send({"t": "hash", "k": w.net_tick, "h": w.net_digest()})
	if not w.net_can_step() and w.phase != LegionWorld.Phase.BATTLE and not _over:
		_over = true
		var hp: Array = []
		for s in w.sides:
			hp.append(s.cauldron_hp)
		_send({"t": "verdict", "why": "end", "tick": w.net_tick,
			"winner": _winner(), "hp": hp})
		print("[judge %s] конец на тике %d, победитель %d" % [_room, w.net_tick, _winner()])


## Победитель по судейскому счёту: -1 — ничья/не решено (PvpMatch.result — липкий итог).
func _winner() -> int:
	if w.pvp_match == null or w.pvp_match.result.is_empty():
		return -1
	return int(w.pvp_match.result.get("winner", -1))


func _send(msg: Dictionary) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))
