extends SceneTree
## Подменщик-хозяин (проба verifier №2 01.10, перенесена как регресс): «ready» придерживает, ходы
## гонит по часам матча (+50), без команд, чтобы честного гостя (tests/net_duel_probe.gd --role
## guest) выбило правило «рвём отстающего». Гоняет tools/net_attack.sh; итог — по relay.log.
var _port := 18852
var ws := WebSocketPeer.new()
var t0 := -1
var ky := 0
var honest_k := -1
var honest_ready := -1
var sent_ready := -1
var started := false
var done := false
var born := 0

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
	if now - born > 90000:
		print("CHEAT: timeout, honest_k=%d ky=%d" % [honest_k, ky]); return true
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		print("CHEAT: my socket closed: ", ws.get_close_reason()); return true
	if st != WebSocketPeer.STATE_OPEN:
		return false
	if born > 0 and not started and t0 == -1:
		t0 = -2
		_send({"t": "hello", "v": 2, "build": NetSession.BUILD, "name": "probe-host"})
		_send({"t": "create", "map": "pvp:duel"})
	while ws.get_available_packet_count() > 0:
		var m: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
		if not (m is Dictionary):
			continue
		var t := String(m.get("t", ""))
		if t == "start":
			started = true
			t0 = now
			_send({"t": "cand", "c": [], "rtt": 40, "nat": "off"})
			print("CHEAT: start side ", m.get("side"))
		elif t == "in":
			honest_k = maxi(honest_k, int(m.get("k", -1)))
		elif t == "ready":
			honest_ready = now - t0
			print("CHEAT: honest ready at %d ms" % honest_ready)
		elif t == "left":
			print("CHEAT: got LEFT at %d ms (honest last k %d, my ky %d, ready sent at %d)" % [now - t0, honest_k, ky, sent_ready])
			done = true
	if done:
		return true
	if started:
		var clock := (now - t0) / 50
		while ky <= clock + 50:
			_send({"t": "in", "k": ky, "c": []})
			ky += 1
		if sent_ready < 0 and honest_ready >= 0 and ky - (honest_k + 1) >= 360:
			sent_ready = now - t0
			_send({"t": "ready"})
			print("CHEAT: ready sent at %d ms, gap %d" % [sent_ready, ky - honest_k - 1])
	return false
