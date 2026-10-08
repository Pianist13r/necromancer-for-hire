extends SceneTree
##
## Регресс прямого соединения онлайн-«Схватки» (docs/pvp/NET_LOCKSTEP.md, «Прямое соединение»):
##   "$GODOT" --headless --path godot --script res://tests/net_p2p_test.gd -- --mute
##
## 1) STUN: запрос по RFC 5389; разбор ответа на готовых байтах — XOR-MAPPED и обычный MAPPED,
##    чужой txid, обрезанный пакет, ошибка вместо успеха;
## 2) пакет ходов: сырые строки проходят байт в байт, потолок размера, старые первыми, длинный ход
##    пропускается;
## 3) мусор: чужой токен, не ASCII, не JSON, не те типы, огромные числа, кривые кандидаты;
## 4) настоящие сокеты на 127.0.0.1: пробивка двух NetP2P, ход напрямую, мусор и пакеты «своей
##    стороны» с третьего сокета не ломают путь;
## 5) сверка путей в NetSession: одинаковые строки — путь жив, разные — путь выключен;
## 6) задержка ввода: выбор по пути, рост по опозданиям (с потолком), пустые ходы в разрыве;
## 7) нижняя граница задержки совпадает у клиента и ретранслятора, протокол — тоже.
## Итог «NET P2P: N/M OK»; код выхода 1, если что-то упало.
##

const TOKEN := "0123456789abcdef0123456789abcdef"

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	_stun_checks()
	_pack_checks()
	_junk_checks()
	_socket_checks()
	await _hardening_checks()
	await _reconcile_checks()
	await _delay_checks()
	await _proto_checks()
	print("NET P2P: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── 1. STUN ─────────────────────────────────────────────────────────────────

func _stun_checks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var txid := NetStun.new_txid(rng)
	var req := NetStun.make_request(txid)
	_check(req.size() == 20 and req[0] == 0 and req[1] == 1 and req[2] == 0 and req[3] == 0
		and req[4] == 0x21 and req[5] == 0x12 and req[6] == 0xA4 and req[7] == 0x42
		and req.slice(8, 20) == txid, "STUN: Binding Request — тип, длина, cookie, txid")
	var xor_attr := _xor_mapped("203.0.113.7", 54321)
	var r := NetStun.parse_response(_stun_resp(0x0101, txid, [xor_attr]), txid)
	_check(r.get("ip") == "203.0.113.7" and r.get("port") == 54321, "STUN: XOR-MAPPED-ADDRESS")
	var plain := _mapped(0x0001, "198.51.100.20", 3478)
	r = NetStun.parse_response(_stun_resp(0x0101, txid, [plain]), txid)
	_check(r.get("ip") == "198.51.100.20" and r.get("port") == 3478, "STUN: обычный MAPPED-ADDRESS")
	# неизвестный атрибут с длиной 5 (выравнивание до 8), потом MAPPED, потом XOR — XOR главнее
	var odd := PackedByteArray([0x80, 0x22, 0, 5, 1, 2, 3, 4, 5, 0, 0, 0])
	r = NetStun.parse_response(_stun_resp(0x0101, txid, [odd, plain, xor_attr]), txid)
	_check(r.get("ip") == "203.0.113.7", "STUN: выравнивание атрибутов, XOR важнее обычного")
	var other := NetStun.new_txid(rng)
	_check(NetStun.parse_response(_stun_resp(0x0101, other, [xor_attr]), txid).is_empty(),
		"STUN: чужой txid отброшен")
	var full := _stun_resp(0x0101, txid, [xor_attr])
	_check(NetStun.parse_response(full.slice(0, full.size() - 3), txid).is_empty(),
		"STUN: обрезанный пакет отброшен")
	_check(NetStun.parse_response(full.slice(0, 12), txid).is_empty(), "STUN: обрубок заголовка")
	_check(NetStun.parse_response(_stun_resp(0x0111, txid, [xor_attr]), txid).is_empty(),
		"STUN: ответ-ошибка не адрес")
	_check(NetStun.looks_like_stun(full) and not NetStun.looks_like_stun(
		"{\"p\":1}".to_ascii_buffer()), "STUN отличается от наших пакетов на одном сокете")


func _stun_resp(typ: int, txid: PackedByteArray, attrs: Array) -> PackedByteArray:
	var body := PackedByteArray()
	for a: PackedByteArray in attrs:
		body.append_array(a)
	var out := PackedByteArray([typ >> 8, typ & 255, body.size() >> 8, body.size() & 255,
		0x21, 0x12, 0xA4, 0x42])
	out.append_array(txid)
	out.append_array(body)
	return out


func _mapped(typ: int, ip: String, port: int) -> PackedByteArray:
	var o := ip.split(".")
	return PackedByteArray([typ >> 8, typ & 255, 0, 8, 0, 1, port >> 8, port & 255,
		o[0].to_int(), o[1].to_int(), o[2].to_int(), o[3].to_int()])


func _xor_mapped(ip: String, port: int) -> PackedByteArray:
	var o := ip.split(".")
	var xp := port ^ 0x2112
	return PackedByteArray([0, 0x20, 0, 8, 0, 1, xp >> 8, xp & 255, o[0].to_int() ^ 0x21,
		o[1].to_int() ^ 0x12, o[2].to_int() ^ 0xA4, o[3].to_int() ^ 0x42])


# ── 2. Пакет ходов ──────────────────────────────────────────────────────────

func _pack_checks() -> void:
	var raws: Array = []
	for k in 3:
		raws.append(JSON.stringify({"t": "in", "k": k, "c": [{"type": "rally", "at": [8, -16]}]}))
	var key := "00112233445566778899aabbccddeeff".hex_decode()
	var macs: Array = []
	for r: String in raws:
		macs.append(NetP2P.mac(key, r))
	var data := NetP2P.pack_turns(TOKEN, 0, 41, raws, macs, NetP2P.PACKET_MAX)
	var u := NetP2P.unpack(TOKEN, data)
	_check(u.get("y") == "tu" and u.get("a") == 41 and u.get("sd") == 0, "пакет ходов: поля")
	_check((u.get("r", []) as Array) == raws, "пакет ходов: сырые строки байт в байт")
	_check((u.get("m", []) as Array) == macs and String(macs[0]).length() == NetP2P.MAC_HEX,
		"пакет ходов: HMAC каждого хода доходит рядом с ним")
	var bad := ("{\"p\":\"%s\",\"sd\":0,\"y\":\"tu\",\"a\":1,\"r\":[\"x\",\"y\"],\"m\":[5]}"
		% TOKEN).to_ascii_buffer()
	_check((NetP2P.unpack(TOKEN, bad).get("m") as Array) == ["", ""],
		"кривой или недостающий HMAC — пустая строка (жалоба с ним не докажет ничего)")
	var many: Array = []
	for k in 200:
		many.append(JSON.stringify({"t": "in", "k": k, "c": []}))
	var many_m: Array = []
	for r: String in many:
		many_m.append(NetP2P.mac(key, r))
	data = NetP2P.pack_turns(TOKEN, 1, -1, many, many_m, NetP2P.PACKET_MAX)
	u = NetP2P.unpack(TOKEN, data)
	var got: Array = u.get("r", [])
	_check(data.size() <= NetP2P.PACKET_MAX and got.size() > 10 and got.size() < 200
		and got[0] == many[0], "пакет ходов: потолок %d байт, старые первыми (%d из 200)" % [
		NetP2P.PACKET_MAX, got.size()])
	var big := JSON.stringify({"t": "in", "k": 5, "c": [{"type": "stroke", "pts": range(400)}]})
	data = NetP2P.pack_turns(TOKEN, 0, 3, [big, raws[1]], ["", macs[1]], NetP2P.PACKET_MAX)
	u = NetP2P.unpack(TOKEN, data)
	_check((u.get("r", []) as Array) == [raws[1]], "пакет ходов: ход больше потолка пропущен")


# ── 3. Мусор ────────────────────────────────────────────────────────────────

func _junk_checks() -> void:
	var good := NetP2P.pack(TOKEN, 1, {"y": "pr", "ts": 5, "ok": 1})
	_check(not NetP2P.unpack(TOKEN, good).is_empty(), "проба разбирается")
	_check(NetP2P.unpack("ffffffffffffffffffffffffffffffff", good).is_empty(), "чужой токен")
	_check(NetP2P.unpack("", good).is_empty(), "пустой токен — ничего не принимаем")
	var junk := [
		PackedByteArray(),
		PackedByteArray([0xff, 0xfe, 0x7b]),
		("{\"p\":\"%s\",\"sd\":1,\"y\":\"pr\",\"x\":\"é\"}" % TOKEN).to_utf8_buffer(),
		"{not json".to_ascii_buffer(),
		"[1,2,3]".to_ascii_buffer(),
		("{\"p\":\"%s\",\"sd\":1e300,\"y\":\"pr\"}" % TOKEN).to_ascii_buffer(),
		("{\"p\":\"%s\",\"sd\":2,\"y\":\"pr\"}" % TOKEN).to_ascii_buffer(),
		("{\"p\":\"%s\",\"sd\":1,\"y\":\"zz\"}" % TOKEN).to_ascii_buffer(),
		("{\"p\":\"%s\",\"sd\":1,\"y\":\"tu\",\"r\":5}" % TOKEN).to_ascii_buffer(),
		("{\"p\":5,\"sd\":1,\"y\":\"pr\"}").to_ascii_buffer(),
	]
	var big := ("{\"p\":\"%s\",\"sd\":1,\"y\":\"pr\",\"pad\":\"" % TOKEN) + "x".repeat(1300) + "\"}"
	junk.append(big.to_ascii_buffer())
	var rejected := 0
	for j: PackedByteArray in junk:
		rejected += int(NetP2P.unpack(TOKEN, j).is_empty())
	_check(rejected == junk.size(), "мусор отброшен целиком (%d/%d)" % [rejected, junk.size()])
	var huge := ("{\"p\":\"%s\",\"sd\":0,\"y\":\"tu\",\"a\":1e300,\"ts\":-1e300,\"r\":[1,\"x\"]}"
		% TOKEN).to_ascii_buffer()
	var h := NetP2P.unpack(TOKEN, huge)
	_check(h.get("a") == -1 and h.get("ts") == -1 and (h.get("r") as Array) == ["x"],
		"огромные числа — без падения, как «нет значения»; в ходах только строки")
	var c: Variant = NetP2P.clean_cands([{"ip": "203.0.113.7", "port": 5000, "kind": "stun"},
		{"ip": "192.168.1.5", "port": 5000, "kind": "lan"}])
	_check(c is Array and (c as Array).size() == 2, "кандидаты: честные проходят")
	var bad_sets := [
		"x", [1], [{"ip": "1.2.3.999", "port": 5, "kind": "lan"}],
		[{"ip": "1.2.3.4", "port": 0, "kind": "lan"}], [{"ip": "1.2.3.4", "port": 70000, "kind": "lan"}],
		[{"ip": "1.2.3.4", "port": 5, "kind": "relay"}], [{"ip": "239.1.1.1", "port": 5, "kind": "lan"}],
		[{"ip": "0.0.0.0", "port": 5, "kind": "lan"}], [{"ip": 5, "port": 5, "kind": "lan"}],
		[{"ip": "1.2.3.4", "port": 1e300, "kind": "lan"}],
	]
	var nine: Array = []
	for i in 9:
		nine.append({"ip": "10.0.0.%d" % (i + 1), "port": 5, "kind": "lan"})
	bad_sets.append(nine)
	var nulls := 0
	for b: Variant in bad_sets:
		nulls += int(NetP2P.clean_cands(b) == null)
	_check(nulls == bad_sets.size(), "кандидаты: кривые и больше 8 — отказ (%d/%d)" % [nulls,
		bad_sets.size()])
	_check(NetP2P.clean_cands([{"ip": "2001:db8::1", "port": 9, "kind": "stun"}]) is Array,
		"кандидаты: IPv6-строка допустима")


# ── 4. Настоящие сокеты ─────────────────────────────────────────────────────

func _socket_checks() -> void:
	var a := NetP2P.new()
	var b := NetP2P.new()
	a.allow_loopback = true   # два клиента на одной машине — только в пробах
	b.allow_loopback = true
	var now := Time.get_ticks_msec()
	_check(a.start(TOKEN, 0, false, now) and b.start(TOKEN, 1, false, now), "UDP-сокеты открыты")
	var ca := a.local_candidates()
	var cb := b.local_candidates()
	_check(not ca.is_empty() and ca[0]["ip"] == "127.0.0.1", "LAN-кандидаты: 127.0.0.1 первым")
	_check(ca.size() <= NetP2P.MAX_CANDS and NetP2P.clean_cands(ca) is Array,
		"свои кандидаты проходят проверку ретранслятора")
	a.set_remote([cb[0]], now)
	b.set_remote([ca[0]], now)
	var junk := PacketPeerUDP.new()
	junk.bind(0)
	var t0 := Time.get_ticks_msec()
	var got_b: Array[String] = []
	var mac_b := ""
	var sent := false
	while Time.get_ticks_msec() - t0 < 4000:
		now = Time.get_ticks_msec()
		# третий сокет сыплет мусор и чужую сторону — путь не должен ни сломаться, ни принять его
		junk.set_dest_address("127.0.0.1", int(cb[0]["port"]))
		junk.put_packet("{garbage".to_ascii_buffer())
		junk.put_packet(NetP2P.pack(TOKEN, 1, {"y": "tu", "a": 0, "r": ["{\"t\":\"in\"}"]}))
		junk.put_packet(NetP2P.pack(TOKEN, 0, {"y": "tu", "a": 0, "r": ["{\"t\":\"in\",\"k\":9}"]}))
		a.poll(now)
		for item: Dictionary in b.poll(now):
			got_b.append(String(item["raw"]))
			mac_b = String(item["mac"])
		if a.is_active() and b.is_active() and not sent:
			sent = true
			a.send_turns(["{\"t\":\"in\",\"k\":7,\"c\":[]}"], ["ab".repeat(16)], 3, now)
		if sent and got_b.has("{\"t\":\"in\",\"k\":7,\"c\":[]}"):
			break
		OS.delay_msec(5)
	_check(a.is_active() and b.is_active(), "пробивка через 127.0.0.1: путь у обоих (RTT %d/%d мс)"
		% [a.rtt_ms, b.rtt_ms])
	_check(got_b == ["{\"t\":\"in\",\"k\":7,\"c\":[]}"] and b.remote_ack == 3
		and mac_b == "ab".repeat(16),
		"ход напрямую дошёл байт в байт, ack пришёл; ходы с чужого адреса не приняты")
	_check(int(b.stats["junk"]) > 0, "мусор и «своя сторона» посчитаны и отброшены молча")
	junk.close()
	a.close()
	b.close()
	# соперник без прямого пути — сразу запасной, без ожидания
	var c := NetP2P.new()
	c.start(TOKEN, 0, false, Time.get_ticks_msec())
	c.set_remote([], Time.get_ticks_msec())
	c.poll(Time.get_ticks_msec())
	_check(c.state == NetP2P.State.FAILED and c.decided(),
		"у соперника прямое выключено — сразу сервер")
	c.close()
	# глушёный UDP: пробы не доходят — за отведённое время путь признан неудачным
	var d := NetP2P.new()
	var e := NetP2P.new()
	d.allow_loopback = true
	e.allow_loopback = true
	d.dbg_off = true
	now = Time.get_ticks_msec()
	d.start(TOKEN, 0, false, now)
	e.start(TOKEN, 1, false, now)
	d.set_remote([e.local_candidates()[0]], now)
	e.set_remote([d.local_candidates()[0]], now)
	var later := now + NetP2P.PUNCH_TIMEOUT_MS + 100
	d.poll(now)
	e.poll(now)
	d.poll(later)
	e.poll(later)
	_check(d.state == NetP2P.State.FAILED and e.state == NetP2P.State.FAILED,
		"UDP глушён — оба уходят на сервер по тайм-ауту пробивки")
	d.close()
	e.close()


## Находки verifier 01.10 (D): потолок адресов соперника, loopback и Tailscale.
func _hardening_checks() -> void:
	var key := "00112233445566778899aabbccddeeff".hex_decode()
	var m1 := NetP2P.mac(key, "{\"t\":\"in\",\"k\":5,\"c\":[]}")
	_check(m1.length() == NetP2P.MAC_HEX and m1 == NetP2P.mac(key, "{\"t\":\"in\",\"k\":5,\"c\":[]}")
		and m1 != NetP2P.mac(key, "{\"t\":\"in\",\"k\":5,\"c\":[{}]}")
		and m1 != NetP2P.mac("ff112233445566778899aabbccddeeff".hex_decode(),
		"{\"t\":\"in\",\"k\":5,\"c\":[]}"), "HMAC: зависит от строки и ключа, 16 байт")
	# живая игра: ни 127.0.0.1, ни адресов Tailscale в своих кандидатах
	var lan := NetP2P._lan_candidates(5000, false)
	var leaks := 0
	for c: Dictionary in lan:
		var ip := String(c["ip"])
		var o := ip.split(".")
		leaks += int(NetP2P.is_loopback(ip) or (o[0] == "100" and o[1].to_int() >= 64
			and o[1].to_int() <= 127))
	_check(leaks == 0 and NetP2P._lan_candidates(5000, true)[0]["ip"] == "127.0.0.1",
		"свои кандидаты: без 127.0.0.1 и Tailscale (127.0.0.1 — только в пробах)")
	var p := NetP2P.new()
	var now := Time.get_ticks_msec()
	p.start(TOKEN, 0, false, now)
	p.set_remote([{"ip": "127.0.0.1", "port": 9, "kind": "lan"}], now)
	p.poll(now)
	_check(p.state == NetP2P.State.FAILED, "чужой кандидат 127.0.0.1 в живой игре отброшен")
	p.close()
	# соперник с токеном шлёт пробы с 40 портов: адресов и ответов — не больше потолка
	var q := NetP2P.new()
	q.allow_loopback = true
	now = Time.get_ticks_msec()
	q.start(TOKEN, 0, false, now)
	q.set_remote([{"ip": "127.0.0.1", "port": 9, "kind": "lan"}], now)
	var port := q._udp.get_local_port()
	var socks: Array[PacketPeerUDP] = []
	for i in 40:
		var u := PacketPeerUDP.new()
		u.bind(0)
		u.set_dest_address("127.0.0.1", port)
		u.put_packet(NetP2P.pack(TOKEN, 1, {"y": "pr", "ts": 1, "ok": 0}))
		socks.append(u)
	await process_frame
	OS.delay_msec(30)
	q.poll(Time.get_ticks_msec())
	var answered := 0
	OS.delay_msec(30)
	for u in socks:
		answered += int(u.get_available_packet_count() > 0)
		u.close()
	_check(q._verified.size() <= NetP2P.VERIFIED_MAX and answered <= NetP2P.VERIFIED_MAX,
		"потолок адресов соперника: %d адресов, %d ответов из 40" % [q._verified.size(), answered])
	q.close()


# ── 5. Сверка путей ─────────────────────────────────────────────────────────

func _session() -> NetSession:
	var s := NetSession.new()
	root.add_child(s)
	s.side = 0
	s._p2p = NetP2P.new()
	s._p2p.state = NetP2P.State.ACTIVE
	return s


func _reconcile_checks() -> void:
	await process_frame
	var s := _session()
	var r5 := JSON.stringify({"t": "in", "k": 5, "c": [{"type": "rally", "at": [0, 0]}]})
	s._on_remote_turn(JSON.parse_string(r5), r5, "udp")
	s._on_remote_turn(JSON.parse_string(r5), r5, "udp")
	s._on_remote_turn(JSON.parse_string(r5), r5, "relay")
	_check(s.p2p_mismatch < 0 and s._p2p.is_active() and (s._turns[1] as Dictionary).has(5)
		and s.first_via["udp"] == 1 and s.first_via["relay"] == 0,
		"сверка: одинаковые строки по двум путям — путь жив, ход взят из первого")
	var r6 := JSON.stringify({"t": "in", "k": 6, "c": [{"type": "rally", "at": [0, 0]}]})
	var r6f := JSON.stringify({"t": "in", "k": 6, "c": []})
	s._on_remote_turn(JSON.parse_string(r6f), r6f, "udp", "cd".repeat(16))
	s._on_remote_turn(JSON.parse_string(r6), r6, "relay")
	_check(s.p2p_mismatch == 6 and s._p2p.state == NetP2P.State.FAILED,
		"сверка: подлог (напрямую одно, серверу другое) — прямой путь выключен")
	_check(s.mismatch_report.get("raw") == r6f and s.mismatch_report.get("mac") == "cd".repeat(16)
		and s.mismatch_report.get("k") == 6,
		"жалоба серверу несёт строку, пришедшую НАПРЯМУЮ, и её HMAC (сервер проверит ключом)")
	_check(((s._turns[1] as Dictionary)[6] as Array).is_empty(),
		"применённый первым ход не переписан вторым (отменить нельзя — чинит снимок судьи)")
	# порядок «сначала сервер, потом напрямую» ловится так же
	var s2 := _session()
	var r9 := JSON.stringify({"t": "in", "k": 9, "c": []})
	var r9f := JSON.stringify({"t": "in", "k": 9.0, "c": []})
	s2._on_remote_turn(JSON.parse_string(r9), r9, "relay")
	s2._on_remote_turn(JSON.parse_string(r9f), r9f, "udp")
	_check(s2.p2p_mismatch == 9, "сверка: сравниваются сырые строки (9 и 9.0 — разные)")
	# мусорные номера ходов — без падения и без записи
	var junk := {"t": "in", "k": 1.0e300, "c": []}
	s2._on_remote_turn(junk, "x", "udp")
	s2._on_remote_turn({"t": "in", "k": -3, "c": []}, "x", "udp")
	s2._on_remote_turn({"t": "in", "k": 100000, "c": []}, "x", "udp")
	_check((s2._turns[1] as Dictionary).size() == 1, "огромный, отрицательный и далёкий k отброшены")
	s.queue_free()
	s2.queue_free()


# ── 6. Задержка ввода ───────────────────────────────────────────────────────

func _delay_checks() -> void:
	_check(NetSession.delay_for(0.0) == NetSession.DELAY_MIN, "задержка: локально — нижняя граница")
	_check(NetSession.delay_for(9.0) == 2, "задержка: напрямую по городу (9 мс) — 2 хода")
	_check(NetSession.delay_for(215.0) == 7, "задержка: через Франкфурт (215 мс) — 7 ходов")
	_check(NetSession.delay_for(5000.0) == NetSession.DELAY_MAX, "задержка: потолок")
	await process_frame
	var s := _session()
	s.stage = NetSession.Stage.PLAYING
	s.path_mode = "relay"
	s._p2p.state = NetP2P.State.PUNCH   # не FAILED: свои ходы копятся и для прямого пути
	s._remote_relay_rtt = 200
	s._relay_rtts = [100, 180, 120]
	s._choose_delay()
	_check(s.delay == NetSession.delay_for(180.0 / 2.0 + 200.0 / 2.0) and s.delay == 7,
		"через сервер: своя половина RTT по верхнему замеру + половина RTT соперника")
	s.delay = 2
	s._delay_start = 2
	s._next_out = 2
	s._close_local_turn(0)
	s._on_late()
	s._close_local_turn(1)
	var mine: Dictionary = s._turns[0]
	_check(s.delay == 3 and mine.has(2) and mine.has(3) and mine.has(4) and s._next_out == 5
		and (mine[3] as Array).is_empty(), "рост задержки: пропущенный номер ушёл пустым ходом")
	_check(s._sent_raw.keys() == [2, 3, 4] and s._sent_raw[3][0] == JSON.stringify(
		{"t": "in", "k": 3, "c": []}), "те же строки ждут прямого пути (нумерация подряд)")
	for i in 10:
		s._on_late()
	_check(s.delay == 2 + NetSession.LATE_ADD_MAX, "рост по опозданиям — не больше %d ходов"
		% NetSession.LATE_ADD_MAX)
	# прямой путь пропал посреди боя: задержка сразу до нужной серверному пути
	s.path_mode = "p2p"
	s.delay = 2
	s._p2p.state = NetP2P.State.FAILED
	s._relay_rtts = [200, 230]
	s._remote_relay_rtt = 200
	s._tick_p2p()
	_check(s.path_mode == "relay" and s.delay == NetSession.delay_for(115.0 + 100.0),
		"путь пропал — сервер и задержка по нему (%d)" % s.delay)
	s.queue_free()


# ── 7. Протокол ─────────────────────────────────────────────────────────────

func _proto_checks() -> void:
	var relay: Dictionary = (load("res://scripts/legion/net/net_relay_core.gd") as Script) \
		.get_script_constant_map()
	_check(int(relay["EMPTY_TURNS"]) == NetSession.DELAY_MIN,
		"ретранслятор: пустых ходов требует столько же, сколько нижняя граница задержки")
	_check(int(relay["PROTO"]) == NetSession.PROTO and NetSession.PROTO == 2, "протокол 2 у обоих")
	# окно ходов соперника у клиента шире того, насколько ретранслятор пускает ход вперёд часов
	# боя (иначе честный выбрасывал бы ходы и застревал — verifier №2 01.10)
	var ahead := NetSession.DELAY_MAX + int(relay["AHEAD_SLACK"])
	_check(NetSession.REMOTE_WINDOW >= 72000 + ahead and not relay.has("LAG_TURNS"),
		"окно ходов клиента (%d) — час боя и забег (%d); правила разрыва на сервере нет" % [
		NetSession.REMOTE_WINDOW, ahead])
	await process_frame
	var s := _session()
	s._on_remote_turn({"t": "in", "k": 1000, "c": []}, "x", "relay")
	_check((s._turns[1] as Dictionary).has(1000), "ход на 1000 вперёд принят, не выброшен")
	# придержка копии на сервер: ход напрямую дальше «через сервер + 200 + 64» не храним
	s._on_remote_turn({"t": "in", "k": 1300, "c": []}, "y", "udp")
	s._on_remote_turn({"t": "in", "k": 1200, "c": []}, "z", "udp")
	_check(not (s._turns[1] as Dictionary).has(1300) and (s._turns[1] as Dictionary).has(1200)
		and s._relay_contig == 1000, "ход напрямую далеко за копией на сервере не хранится")
	# «void» — запрос, а не выход: клиент остаётся в матче; отказ сервера — без последствий
	s.stage = NetSession.Stage.PLAYING
	s._hold_stall = 31.0
	s._request("void")
	var still := s.stage == NetSession.Stage.PLAYING and s._req_wait == 0.0
	s._handle({"t": "void_denied", "gap": 3})
	_check(still and s.stage == NetSession.Stage.PLAYING and s._req_wait < 0.0
		and s._hold_stall == 0.0 and s.last_error == "",
		"«void» — запрос: после отправки и отказа клиент в матче, без выхода")
	s.queue_free()
	# сводка матча: простои, которые видел игрок, и процентили RTT
	var ms := NetMatchStats.new()
	ms.reset()
	for i in 30:   # простой 0,5 с кадрами по 1/60
		ms.on_stall(i / 60.0, 1.0 / 60.0, NetSession.STALL_SHOW)
	ms.on_stall(0.0, 0.1, NetSession.STALL_SHOW)
	for v in [10, 20, 30, 40, 200]:
		ms.add_relay_rtt(v)
	_check(ms.stall_n == 1 and is_equal_approx(ms.stall_total, 0.6) and is_equal_approx(
		ms.stall_max, 0.5) and NetMatchStats.pct(ms.relay_rtts, 0.5) == 30
		and NetMatchStats.pct(ms.relay_rtts, 0.9) == 200 and NetMatchStats.pct([], 0.5) == -1,
		"сводка: видимые простои, сумма, максимум, p50/p90")
