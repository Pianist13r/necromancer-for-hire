extends SceneTree
## Обманщик-хозяин (проба verifier №4 01.10, перенесена как регресс): придерживает «ready» и шлёт
## его за --race мс после «ready» честного — за миг до отмены загрузки честным. Честный не должен
## получить сдачу: отмена отклоняется, бой начинается. Гоняет tools/net_attack.sh.
var _port := 18971
var _race := 29900
var ws := WebSocketPeer.new()
var born := 0
var hello_sent := false
var honest_ready := -1
var my_ready := false
var go := -1
var ky := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			_port = int(args[i + 1])
		if args[i] == "--race" and i + 1 < args.size():
			_race = int(args[i + 1])
	born = Time.get_ticks_msec()
	ws.connect_to_url("ws://127.0.0.1:%d" % _port)

func _send(d: Dictionary) -> void:
	ws.send_text(JSON.stringify(d))

func _process(_dt: float) -> bool:
	ws.poll()
	var now := Time.get_ticks_msec()
	if now - born > 120000:
		print("VFR: timeout"); return true
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		print("VFR: closed ", ws.get_close_reason()); return true
	if st != WebSocketPeer.STATE_OPEN:
		return false
	if not hello_sent:
		hello_sent = true
		_send({"t": "hello", "v": 2, "build": NetSession.BUILD, "name": "probe-host"})
		_send({"t": "create", "map": "pvp:duel"})
	while ws.get_available_packet_count() > 0:
		var m: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
		if not (m is Dictionary):
			continue
		var t := String(m.get("t", ""))
		if t == "start":
			_send({"t": "cand", "c": [], "rtt": 40, "nat": "off"})
			_send({"t": "in", "k": 0, "c": []})
			_send({"t": "in", "k": 1, "c": []})
			ky = 2
		elif t == "ready":
			honest_ready = now
			print("VFR: honest ready at %d" % now)
		elif t in ["left", "error", "void"]:
			print("VFR: got %s, %d ms after honest ready, my ready sent: %s" % [JSON.stringify(m), now - honest_ready, my_ready])
			if t == "left":
				return true
	if honest_ready > 0 and not my_ready and now - honest_ready >= _race:
		my_ready = true
		go = now
		_send({"t": "ready"})
		print("VFR: my ready sent %d ms after honest ready" % (now - honest_ready))
	if go > 0:
		var clock := (now - go) / 50
		while ky <= clock + 3:
			_send({"t": "in", "k": ky, "c": []})
			ky += 1
	return false
