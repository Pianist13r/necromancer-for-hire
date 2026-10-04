extends SceneTree
##
## Атаки обманщика на ретранслятор (пробы verifier №2 01.10, перенесены как регресс):
##   1 — повтор настоящего хода 3 честного под номером 5 в жалобе p2p_mismatch (HMAC верный);
##   2 — то же через очередь жалоб (жалоба на ещё не присланный ход 1 строкой хода 0);
##   3 — обманщик держит «ready» и гонит пустые ходы по часам, чтобы честного выбило правило
##       «рвём отстающего».
##   4 — залив через сервер (verifier №5 01.10, B-378): обманщик шлёт «end»/«ready» по 16 КБ
##       200 раз в секунду, пока честный 3 с не читает сокет (заминка). Сервер пересылал их сырыми,
##       очередь к честному росла — и сервер рвал ЧЕСТНОГО «не успевает принимать».
##   5 — то же ходами: обманщик шлёт ходы по 8 КБ в пределах часов боя, честный 4 с не читает.
##       Честный не должен быть отключён и должен получить ВСЕ ходы подряд, без пропусков.
##   6 — запрос «void» без придержки отклоняется («void_denied»), матч идёт дальше.
##   7 — запрос «no_ready», когда сам не готов или поле уже загружено у обоих, отклоняется
##       («no_ready_denied»), матч идёт дальше.
##   8 — обманщик гонит ходы до предела объёма матча (LOG_CAP) и отключается сервером: честный
##       на связи, получает «left»; SCRIPT ERROR в ретрансляторе нет (проверяет tools/net_attack.sh;
##       verifier B-378 — хвост ходов читал строку хода, не записанную при отключении).
## Честный не должен получить ни «доказанной подмены», ни разрыва за «ходы не доходят».
##   godot --headless --path godot --script res://tests/net_attack_probe.gd -- --mute --port N
## Ретранслятор поднимает tools/net_attack.sh. Итог «NET ATTACK: N/8 OK», код выхода 1 при провале.
##
var _port := 18851
var _ok := 0
var _socks: Array[WebSocketPeer] = []
var _which := "12345678"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			_port = int(args[i + 1])
		elif args[i] == "--which" and i + 1 < args.size():
			_which = args[i + 1]
	_run.call_deferred()

func _mac(key: PackedByteArray, raw: String) -> String:
	var h := HMACContext.new()
	h.start(HashingContext.HASH_SHA256, key)
	h.update(raw.to_utf8_buffer())
	return h.finish().slice(0, 16).hex_encode()

func _run() -> void:
	var url := "ws://127.0.0.1:%d" % _port
	if "1" in _which:
		var pr := await _pair(url, "rep1")
		var x: WebSocketPeer = pr[0]
		var y: WebSocketPeer = pr[1]
		var kx := String((pr[2] as Dictionary).get("key", "")).hex_decode()
		var raws := []
		for k0 in 6:
			var r := JSON.stringify({"t": "in", "k": k0, "c": []})
			raws.append(r)
			x.send_text(r)
		for i in 6:
			await _recv_t(y, "in")
		y.send_text(JSON.stringify({"t": "p2p_mismatch", "k": 5, "raw": raws[3], "mac": _mac(kx, raws[3])}))
		var vx := await _recv_t(x, "verdict")
		print("ATTACK1 replay k3->k5: verdict to honest = ", vx)
		_ok += int(vx.get("why") != "forge")
		x.close(); y.close()
	if "2" in _which:
		var pr := await _pair(url, "rep2")
		var x: WebSocketPeer = pr[0]
		var y: WebSocketPeer = pr[1]
		var kx := String((pr[2] as Dictionary).get("key", "")).hex_decode()
		var r0 := JSON.stringify({"t": "in", "k": 0, "c": []})
		x.send_text(r0)
		await _recv_t(y, "in")
		y.send_text(JSON.stringify({"t": "p2p_mismatch", "k": 1, "raw": r0, "mac": _mac(kx, r0)}))
		await create_timer(0.3).timeout
		x.send_text(JSON.stringify({"t": "in", "k": 1, "c": []}))
		var vx := await _recv_t(x, "verdict")
		print("ATTACK2 pending replay: verdict to honest = ", vx)
		_ok += int(vx.get("why") != "forge")
		x.close(); y.close()
	if "3" in _which:
		var pr := await _pair(url, "hold")
		var x: WebSocketPeer = pr[0]
		var y: WebSocketPeer = pr[1]
		var t0 := Time.get_ticks_msec()
		x.send_text(JSON.stringify({"t": "in", "k": 0, "c": []}))
		x.send_text(JSON.stringify({"t": "in", "k": 1, "c": []}))
		x.send_text(JSON.stringify({"t": "ready"}))
		var ky := 0
		var x_closed := -1
		while Time.get_ticks_msec() - t0 < 30000:
			var clock := (Time.get_ticks_msec() - t0) / 50
			while ky <= clock + 12 + 30:
				y.send_text(JSON.stringify({"t": "in", "k": ky, "c": []}))
				ky += 1
			for o in _socks:
				o.poll()
			while x.get_available_packet_count() > 0:
				x.get_packet()
			while y.get_available_packet_count() > 0:
				var v: Variant = JSON.parse_string(y.get_packet().get_string_from_utf8())
				if v is Dictionary and (v as Dictionary).get("t") == "left":
					print("ATTACK3: cheater got left at %d ms" % (Time.get_ticks_msec() - t0))
			if x.get_ready_state() == WebSocketPeer.STATE_CLOSED and x_closed < 0:
				x_closed = Time.get_ticks_msec() - t0
				print("ATTACK3: honest disconnected at %d ms, code %d reason %s" % [x_closed, x.get_close_code(), x.get_close_reason()])
				break
			await create_timer(0.02).timeout
		if x_closed < 0:
			print("ATTACK3: honest NOT disconnected in 30 s")
			_ok += 1
	if "4" in _which:
		_ok += int(await _attack_flood_ctl(url))
	if "5" in _which:
		_ok += int(await _attack_flood_turns(url))
	if "6" in _which:
		_ok += int(await _attack_void_denied(url))
	if "7" in _which:
		_ok += int(await _attack_no_ready_denied(url))
	if "8" in _which:
		_ok += int(await _attack_log_cap(url))
	print("NET ATTACK: %d/%d OK" % [_ok, _which.length()])
	quit(0 if _ok == _which.length() else 1)

## 4: залив «end»/«ready» по 16 КБ, честный 3 с не читает сокет.
func _attack_flood_ctl(url: String) -> bool:
	var pr := await _pair(url, "flood4")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	x.send_text(JSON.stringify({"t": "ready"}))
	y.send_text(JSON.stringify({"t": "ready"}))
	var got := await _drain(x, 300)
	var pad := "A".repeat(16000)
	var t0 := Time.get_ticks_msec()
	var sent := 0
	while Time.get_ticks_msec() - t0 < 3000:
		var want := (Time.get_ticks_msec() - t0) * 200 / 1000
		while sent < want:
			y.send_text('{"t":"%s","x":"%s"}' % ["end" if sent % 2 == 0 else "ready", pad])
			sent += 1
		_poll_except(x)
		await create_timer(0.01).timeout
	y.send_text(JSON.stringify({"t": "in", "k": 0, "c": []}))
	got.append_array(await _drain(x, 3000))
	var n := _count(got)
	var alive := x.get_ready_state() == WebSocketPeer.STATE_OPEN
	var ok := alive and int(n.get("in", 0)) == 1 and int(n.get("left", 0)) == 0 \
		and int(n.get("ready", 0)) <= 1 and int(n.get("end", 0)) <= 1 and int(n["max"]) < 1024
	print("ATTACK4 flood end/ready %d×16 KB, honest frozen 3 s: %s — honest open %s, got %s" % [
		sent, "OK" if ok else "FAIL", alive, n])
	x.close()
	y.close()
	return ok


## 5: ходы по 8 КБ в пределах часов боя, честный 4 с не читает сокет. Все ходы — подряд.
func _attack_flood_turns(url: String) -> bool:
	var pr := await _pair(url, "flood5")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	x.send_text(JSON.stringify({"t": "ready"}))
	y.send_text(JSON.stringify({"t": "ready"}))
	y.send_text(JSON.stringify({"t": "in", "k": 0, "c": []}))
	y.send_text(JSON.stringify({"t": "in", "k": 1, "c": []}))
	var got := await _drain(x, 300)
	var big := "B".repeat(8000)
	var ky := 2
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 4000:
		# часы сервера пошли раньше наших (общий старт — до t0), так что предел соблюдён с запасом
		var clock := (Time.get_ticks_msec() - t0) / 50
		while ky <= clock + NetSession.DELAY_MAX + 30:
			y.send_text(JSON.stringify({"t": "in", "k": ky, "c": [{"pad": big}]}))
			ky += 1
		_poll_except(x)
		await create_timer(0.01).timeout
	got.append_array(await _drain(x, 5000))
	var ks: Array[int] = []
	for g: Dictionary in got:
		if (g["m"] as Dictionary).get("t") == "in":
			ks.append(int((g["m"] as Dictionary).get("k", -1)))
	var in_order := ks.size() == ky
	for i in ks.size():
		in_order = in_order and ks[i] == i
	var n := _count(got)
	var alive := x.get_ready_state() == WebSocketPeer.STATE_OPEN
	var ok := alive and in_order and int(n.get("left", 0)) == 0
	print("ATTACK5 turns %d×8 KB, honest frozen 4 s: %s — honest open %s, turns got %d of %d, " % [
		ky, "OK" if ok else "FAIL", alive, ks.size(), ky] + "in order %s, left %d" % [in_order,
		int(n.get("left", 0))])
	x.close()
	y.close()
	return ok


## 6: «void» без придержки — отказ, матч идёт (ход соперника доходит, «left»/«error» нет).
func _attack_void_denied(url: String) -> bool:
	var pr := await _pair(url, "void6")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	x.send_text(JSON.stringify({"t": "ready"}))
	y.send_text(JSON.stringify({"t": "ready"}))
	await _drain(x, 300)
	x.send_text(JSON.stringify({"t": "void"}))
	var got := await _drain(x, 500)
	y.send_text(JSON.stringify({"t": "in", "k": 0, "c": []}))
	got.append_array(await _drain(x, 500))
	var gy := await _drain(y, 100)
	var n := _count(got)
	var ny := _count(gy)
	var ok := int(n.get("void_denied", 0)) == 1 and int(n.get("in", 0)) == 1 \
		and int(n.get("left", 0)) + int(n.get("error", 0)) + int(ny.get("left", 0)) \
		+ int(ny.get("error", 0)) == 0
	print("ATTACK6 void without hold: %s — requester got %s, opponent got %s" % [
		"OK" if ok else "FAIL", n, ny])
	x.close()
	y.close()
	return ok


## 7: «no_ready», когда сам не загрузил поле, и когда поле загружено у обоих, — оба отказа.
func _attack_no_ready_denied(url: String) -> bool:
	var pr := await _pair(url, "nrdy7")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	y.send_text(JSON.stringify({"t": "ready"}))
	await _drain(x, 300)
	x.send_text(JSON.stringify({"t": "no_ready"}))   # x сам ещё не готов
	var got := await _drain(x, 500)
	x.send_text(JSON.stringify({"t": "ready"}))
	await _drain(x, 300)
	y.send_text(JSON.stringify({"t": "no_ready"}))   # поле загружено у обоих
	var gy := await _drain(y, 500)
	y.send_text(JSON.stringify({"t": "in", "k": 0, "c": []}))
	got.append_array(await _drain(x, 500))
	var n := _count(got)
	var ny := _count(gy)
	var ok := int(n.get("no_ready_denied", 0)) == 1 and int(ny.get("no_ready_denied", 0)) == 1 \
		and int(n.get("in", 0)) == 1 and int(n.get("left", 0)) + int(n.get("error", 0)) \
		+ int(ny.get("left", 0)) + int(ny.get("error", 0)) == 0
	print("ATTACK7 no_ready denied twice: %s — x got %s, y got %s" % ["OK" if ok else "FAIL", n, ny])
	x.close()
	y.close()
	return ok


## 8: ходы по ~8 КБ из кавычек (в журнале комнаты каждая экранируется — предел LOG_CAP
## достигается за ~25 с) по часам боя, пока сервер не отключит обманщика. Честный читает всё.
func _attack_log_cap(url: String) -> bool:
	var pr := await _pair(url, "cap8")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	x.send_text(JSON.stringify({"t": "ready"}))
	y.send_text(JSON.stringify({"t": "ready"}))
	y.send_text(JSON.stringify({"t": "in", "k": 0, "c": []}))
	y.send_text(JSON.stringify({"t": "in", "k": 1, "c": []}))
	var got := await _drain(x, 300)
	var pad := "\"".repeat(4000)
	var ky := 2
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 90000 and y.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var clock := (Time.get_ticks_msec() - t0) / 50
		while ky <= clock + NetSession.DELAY_MAX + 30:
			y.send_text(JSON.stringify({"t": "in", "k": ky, "c": [{"p": pad}]}))
			ky += 1
		got.append_array(await _drain(x, 20))
	got.append_array(await _drain(x, 2000))
	var n := _count(got)
	var alive := x.get_ready_state() == WebSocketPeer.STATE_OPEN
	var cut := y.get_ready_state() == WebSocketPeer.STATE_CLOSED
	var ok := alive and cut and int(n.get("left", 0)) == 1
	print("ATTACK8 log cap: %s — cheater cut %s after %d turns, honest open %s, got in %d, left %d" % [
		"OK" if ok else "FAIL", cut, ky, alive, int(n.get("in", 0)), int(n.get("left", 0))])
	x.close()
	y.close()
	return ok


## Заминка честного: он не зовёт poll() — не читает сокет, сервер копит отправку к нему.
func _poll_except(skip: WebSocketPeer) -> void:
	for o in _socks:
		if o != skip:
			o.poll()


## Всё, что пришло в сокет за ms: [{n: размер пакета, m: словарь}].
func _drain(ws: WebSocketPeer, ms: int) -> Array:
	var out := []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		for o in _socks:
			o.poll()
		while ws.get_available_packet_count() > 0:
			var pk := ws.get_packet()
			var v: Variant = JSON.parse_string(pk.get_string_from_utf8())
			out.append({"n": pk.size(), "m": v if v is Dictionary else {}})
		await create_timer(0.01).timeout
	return out


## Пакеты по типу и самый большой (байт).
func _count(got: Array) -> Dictionary:
	var n := {"max": 0}
	for g: Dictionary in got:
		var t := String((g["m"] as Dictionary).get("t", "?"))
		n[t] = int(n.get(t, 0)) + 1
		if t != "in":
			n["max"] = maxi(int(n["max"]), int(g["n"]))
	return n


func _pair(url: String, build: String) -> Array:
	var x := await _connect(url)
	var y := await _connect(url)
	x.send_text(JSON.stringify({"t": "hello", "v": 2, "build": build, "name": "Honest" + build}))
	y.send_text(JSON.stringify({"t": "hello", "v": 2, "build": build, "name": "Cheat" + build}))
	await _recv_t(x, "welcome")
	await _recv_t(y, "welcome")
	x.send_text(JSON.stringify({"t": "create", "map": "pvp:duel"}))
	var room := await _recv_t(x, "room")
	y.send_text(JSON.stringify({"t": "join", "code": room.get("code", "")}))
	return [x, y, await _recv_t(x, "start"), await _recv_t(y, "start")]

func _recv_t(ws: WebSocketPeer, t: String) -> Dictionary:
	for i in 40:
		var m := await _recv(ws)
		if m.get("t") == t or m.get("t") == "timeout":
			return m
	return {"t": "timeout"}

func _connect(url: String) -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	# обманщику — буфер под залив, честному — чтобы после заминки прочесть всё накопленное
	ws.outbound_buffer_size = 8 << 20
	ws.inbound_buffer_size = 1 << 20
	ws.max_queued_packets = 8192
	if ws.connect_to_url(url) != OK:
		return null
	_socks.append(ws)
	for i in 300:
		for other in _socks:
			other.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return ws
		await process_frame
	return null

func _recv(ws: WebSocketPeer) -> Dictionary:
	for i in 600:
		for other in _socks:
			other.poll()
		if ws.get_available_packet_count() > 0:
			var v: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			return v if v is Dictionary else {}
		await create_timer(0.005).timeout
	return {"t": "timeout"}
