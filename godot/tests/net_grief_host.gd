extends SceneTree
## Обманщик-хозяин (проба verifier №3 01.10, перенесена как регресс): «ready» шлёт сразу, ходы —
## по часам от общего старта (+45), не ждёт честного гостя. Честный с медленной машиной не должен
## быть разорван за это сервером. Гоняет tools/net_attack.sh; итог — по relay.log и guest.log.
var _port := 18951
var ws := WebSocketPeer.new()
var ky := 0
var honest_k := -1
var go := -1
var started := false
var my_ready := false
var born := 0
var last_print := 0
var hello_sent := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			_port = int(args[i + 1])
	born = Time.get_ticks_msec()
	ws.connect_to_url("ws://127.0.0.1:%d" % _port)

func _send(d: Dictionary) -> void:
	ws.send_text(JSON.stringify(d))

func _process(_dt: float) -> bool:
	ws.poll()
	var now := Time.get_ticks_msec()
	if now - born > 240000:
		print("GRIEF: timeout honest_k=%d ky=%d" % [honest_k, ky]); return true
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		print("GRIEF: socket closed: ", ws.get_close_reason()); return true
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
			started = true
			_send({"t": "cand", "c": [], "rtt": 40, "nat": "off"})
			_send({"t": "in", "k": 0, "c": []})
			_send({"t": "in", "k": 1, "c": []})
			ky = 2
			_send({"t": "ready"})
			print("GRIEF: start, ready sent")
		elif t == "in":
			honest_k = maxi(honest_k, int(m.get("k", -1)))
		elif t == "ready":
			go = now
			print("GRIEF: honest ready -> go")
		elif t in ["left", "error"]:
			print("GRIEF: got %s at %d ms after go (honest k %d, my ky %d)" % [JSON.stringify(m), now - go, honest_k, ky])
			if t == "left":
				return true
	if go > 0:
		var clock := (now - go) / 50
		while ky <= clock + 45:
			_send({"t": "in", "k": ky, "c": []})
			ky += 1
		if now - last_print > 5000:
			last_print = now
			print("GRIEF: t=%d s clock=%d my=%d honest=%d gap=%d" % [(now - go) / 1000, clock, ky, honest_k, ky - honest_k - 1])
	return false
