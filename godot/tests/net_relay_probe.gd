extends SceneTree
##
## Проба ретранслятора и кодека онлайн-«Схватки» (docs/pvp/NET_LOCKSTEP.md). Ретранслятор должен
## быть уже запущен отдельным процессом (net_relay.gd) на --port. Два клиента WebSocket здесь же:
## комната, вход по коду, старт с одним сидом, пересылка ввода, сверка отпечатков, уход соперника,
## отказ по чужой сборке и несуществующей комнате. Итог «N/M OK», код выхода 1 при провале.
##   godot --headless --path godot --script res://tests/net_relay_probe.gd -- --mute --port 18799
##

var _ok := 0
var _all := 0
var _port := 18799
## --url — проба через туннель (wss://…), иначе ws://127.0.0.1:порт
var _url := ""
## Все сокеты пробы опрашиваются вместе: неопрошенный сокет не отвечает на heartbeat сервера.
var _socks: Array[WebSocketPeer] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			_port = int(args[i + 1])
		elif args[i] == "--url" and i + 1 < args.size():
			_url = NetCodec.normalize_url(args[i + 1])
	_codec_checks()
	_relay_checks.call_deferred()


func _check(cond: bool, what: String) -> void:
	_all += 1
	if cond:
		_ok += 1
	else:
		print("FAIL: ", what)


func _codec_checks() -> void:
	var pts := PackedVector2Array([Vector2(100.123, 200.456), Vector2(140.0, 210.0),
		Vector2(180.7, 230.1)])
	var s := NetCodec.roundtrip({"type": "stroke", "pts": pts, "kind": "laborer",
		"arrow": Vector2(300.3, 400.4)})
	_check(s.get("type") == "stroke" and (s["pts"] as PackedVector2Array).size() == 3,
		"stroke roundtrip")
	_check((s["pts"] as PackedVector2Array)[0] == Vector2(100.125, 200.5), "квантование 1/8")
	_check(NetCodec.roundtrip(s) == s, "повторный roundtrip неподвижен")
	_check(s["arrow"] == Vector2(300.25, 400.375), "стрелка")
	var p := NetCodec.roundtrip({"type": "plot", "plot": "a", "action": "rush", "kind": ""})
	_check(p.get("action") == "rush", "plot rush")
	_check(NetCodec.roundtrip({"type": "cast", "slot": 2, "at": Vector2(5, 6)}).get("slot") == 2,
		"cast")
	_check(NetCodec.roundtrip({"type": "surrender"}) == {"type": "surrender"}, "surrender")
	_check(NetCodec.decode({"type": "donos"}).is_empty(), "донос убран (D-1002-09)")
	_check(NetCodec.decode({"type": "hack"}).is_empty(), "чужой тип")
	_check(NetCodec.decode({"type": "cast", "slot": 9, "at": [0, 0]}).is_empty(), "слот 9")
	_check(NetCodec.decode({"type": "aim", "contract": -1, "at": [0, 0]}).is_empty(), "id -1")
	_check(NetCodec.decode({"type": "rally", "at": [1.0e12, 0]}).is_empty(), "огромное число")
	_check(NetCodec.decode({"type": "plot", "plot": "a", "action": "steal", "kind": ""}).is_empty(),
		"чужое действие площадки")
	_check(NetCodec.decode({"type": "stroke", "pts": [1, 2, 3], "kind": "laborer"}).is_empty(),
		"нечётные точки")
	_check(NetCodec.decode({"type": "stroke", "pts": [1, 2, 3, 4], "kind": "a b"}).is_empty(),
		"мусор в виде")
	_check(NetCodec.decode("строка").is_empty(), "не словарь")
	_check(NetCodec.decode({"type": "cast", "slot": 1.999999999999999, "at": [0, 0]}).is_empty(),
		"дробный слот (1.999…) отброшен")
	_check(NetCodec.decode({"type": "rally", "at": [800.9999999999999, 8]}).is_empty(),
		"дробная координата отброшена")
	_check(NetCodec.normalize_url("https://abc.trycloudflare.com")
		== "wss://abc.trycloudflare.com", "адрес https")
	_check(NetCodec.normalize_url("abc.trycloudflare.com") == "wss://abc.trycloudflare.com",
		"адрес без схемы")
	_check(NetCodec.normalize_url("192.168.1.5:18765") == "ws://192.168.1.5:18765",
		"адрес домашней сети")


func _relay_checks() -> void:
	var url := _url if _url != "" else "ws://127.0.0.1:%d" % _port
	var a := await _connect(url)
	var b := await _connect(url)
	var c := await _connect(url)
	_check(a != null and b != null and c != null, "подключение клиентов")
	if a == null or b == null or c == null:
		_done()
		return
	_send(a, {"t": "hello", "v": NetSession.PROTO, "build": "x", "name": "Аня"})
	_send(b, {"t": "hello", "v": NetSession.PROTO, "build": "x", "name": "  "})
	_send(c, {"t": "hello", "v": NetSession.PROTO, "build": "y", "name": "Чужой<b>"})
	_check(String((await _recv_t(a, "welcome")).get("name")) == "Аня", "имя")
	_check(String((await _recv_t(b, "welcome")).get("name")).begins_with("Игрок"), "пустое имя")
	_check(String((await _recv_t(c, "welcome")).get("name")) == "Чужойb", "мусор из имени")
	_send(a, {"t": "create", "map": "pvp:duel"})
	var room := await _recv_t(a, "room")
	var code := String(room.get("code", ""))
	_check(code.length() == 4 and int(room.get("side", -1)) == 0, "комната")
	var lb := await _recv_lobby(b, 1)
	_check(String(((lb.get("rooms", []) as Array)[0] as Dictionary).get("host", "")) == "Аня"
		if (lb.get("rooms", []) as Array).size() == 1 else false, "лобби видит комнату Ани")
	var lc := await _recv_lobby(c, 0)
	_check((lc.get("rooms", [1]) as Array).is_empty() and (lc.get("players", []) as Array).size()
		== 3, "чужая сборка комнату не видит, онлайн трое")
	_send(c, {"t": "join", "code": code})
	_check((await _recv_t(c, "error")).get("code") == "build", "отказ по сборке")
	_send(c, {"t": "join", "code": "QQQQ"})
	_check((await _recv_t(c, "error")).get("code") == "no_room", "нет комнаты")
	_send(b, {"t": "join", "code": code.to_lower()})
	var sa := await _recv_t(a, "start")
	var sb := await _recv_t(b, "start")
	_check(sa.get("t") == "start" and sb.get("t") == "start", "старт у обоих")
	_check(sa.get("seed") == sb.get("seed") and sa.get("map") == "pvp:duel", "один сид и карта")
	_check(int(sa.get("side", -1)) == 0 and int(sb.get("side", -1)) == 1, "стороны 0 и 1")
	_check(sa.get("opponent") == sb.get("name", sb.get("opponent")) or sb.get("opponent") == "Аня",
		"имя соперника")
	var lc2 := await _recv_lobby(c, 0)
	_check(int(lc2.get("in_game", 0)) == 2, "лобби: двое в игре")
	# прямое соединение: общий токен комнаты, кандидаты — проверенными и только сопернику
	var tok := String(sa.get("p2p", ""))
	_check(tok.length() == 32 and tok.is_valid_hex_number() and tok == String(sb.get("p2p", "")),
		"токен p2p: 16 байт hex, один на комнату")
	_send(a, {"t": "cand", "c": [{"ip": "203.0.113.7", "port": 5000, "kind": "stun", "x": 1}],
		"rtt": 120, "nat": "cone"})
	var cb := await _recv_t(b, "cand")
	_check((cb.get("c", []) as Array).size() == 1 and int(cb.get("rtt", -1)) == 120
		and not ((cb["c"] as Array)[0] as Dictionary).has("x") and cb.get("nat") == "cone",
		"кандидаты пересланы сопернику без лишних полей")
	# кандидаты пересылаются раз за матч от стороны (B-378) — кривые шлёт вторая сторона
	_send(b, {"t": "cand", "c": [{"ip": "999.1.1.1", "port": 5000, "kind": "stun"}], "rtt": {},
		"nat": "<>"})
	var cb2 := await _recv_t(a, "cand")
	_check((cb2.get("c", ["x"]) as Array).is_empty() and int(cb2.get("rtt", 0)) == -1
		and cb2.get("nat") == "?", "кривые кандидаты не пересланы (пустой список)")
	_send(a, {"t": "cand", "c": [{"ip": "203.0.113.8", "port": 5001, "kind": "stun"}],
		"rtt": 50, "nat": "cone"})
	_send(a, {"t": "late"})   # метка: следующее у b — «late», а не повтор кандидатов
	_check((await _recv(b)).get("t") == "late", "повтор кандидатов стороной не переслан (B-378)")
	_send(b, {"t": "late"})
	_check((await _recv_t(a, "late")).get("t") == "late", "«late» — сопернику")
	_send(a, {"t": "path", "mode": "p2p", "rtt": 9, "delay": 2, "nat": "cone"})
	_send(b, {"t": "p2p_mismatch", "k": 77})
	_send(a, {"t": "path", "mode": {}, "rtt": [], "delay": "x", "nat": 5})
	for k0 in 4:
		_send(a, {"t": "in", "k": k0, "c": []})
	_send(a, {"t": "in", "k": 4, "c": [{"type": "rally", "at": [0, 0]}]})
	var ib := {}
	for i in 5:
		ib = await _recv_t(b, "in")
	_check(int(ib.get("k", -1)) == 4 and (ib["c"] as Array).size() == 1, "пересылка ввода")
	_send(a, {"t": "ready"})
	_check((await _recv_t(b, "ready")).get("t") == "ready", "пересылка ready")
	_send(b, {"t": "ready"})   # общий старт — иначе ретранслятор закроет комнату по тайм-ауту
	_send(a, {"t": "hash", "k": 60, "h": "aa"})
	_send(b, {"t": "hash", "k": 60, "h": "aa"})
	_send(a, {"t": "hash", "k": 120, "h": "aa"})
	_send(b, {"t": "hash", "k": 120, "h": "bb"})
	var da := await _recv_t(a, "desync")
	_check(int(da.get("k", -1)) == 120, "рассинхрон 120, не 60")
	_check((await _recv_t(b, "desync")).get("t") == "desync", "рассинхрон у второго")
	_send(a, {"t": "ping", "ms": 77})
	_check(int((await _recv_t(a, "pong")).get("ms", 0)) == 77, "pong")
	_send(a, {"t": "leave"})
	_check((await _recv_t(b, "left")).get("t") == "left", "соперник вышел из матча")
	var la := await _recv_lobby(a, 0)
	_check(int(la.get("in_game", -1)) == 0, "оба снова в лобби")
	_send(a, {"t": "create", "map": "gen:"})
	await _recv_t(a, "room")
	await _recv_lobby(b, 1)
	_send(a, {"t": "cancel"})
	_check((await _recv_lobby(b, 0)).get("t") == "lobby", "отмена ожидания убирает комнату")
	_send(b, {"t": "create", "map": "gen:"})
	var room2 := await _recv_t(b, "room")
	_send(a, {"t": "join", "code": room2.get("code", "")})
	var g := await _recv_t(a, "start")
	_check(String(g.get("map", "")).begins_with("gen:") and String(g.get("map", "")).ends_with(
		":3:pvp"), "случайное поле получает сид сервера")
	# повтор хода с другими командами — способ подставить соперника под судью: отправителя рвём
	_send(a, {"t": "in", "k": 0, "c": []})
	_send(a, {"t": "in", "k": 0, "c": [{"type": "rally", "at": [0, 0]}]})
	_check((await _recv_t(b, "left")).get("t") == "left", "повтор хода: нарушитель отключён")
	# огромная длина цепочки процгена вешала судью — такую карту сервер не принимает
	_send(c, {"t": "create", "map": "gen:1:2000000000:pvp"})
	_check(String((await _recv_t(c, "room")).get("map", "")) == "pvp:duel",
		"кривая карта заменена «Дуэлью»")
	# поля не того типа — не ошибка скрипта у сервера, а пустые значения
	var e := await _connect(url)
	_send(e, {"t": "hello", "v": NetSession.PROTO, "build": [], "name": {}})
	_check(String((await _recv_t(e, "welcome")).get("name", "")).begins_with("Игрок"),
		"hello с полями не того типа")
	var g2 := await _connect(url)
	_send(g2, {"t": "hello", "v": {}})
	_check((await _recv_t(g2, "error")).get("code") == "proto", "версия не числом — отказ")
	_send(e, {"t": "hash", "k": {}, "h": "x"})
	_send(e, {"t": "create", "map": {}})
	_check(String((await _recv_t(e, "room")).get("map", "")) == "pvp:duel", "карта не строка")
	b.close()
	await _forge_checks(url)
	await _replay_checks(url)
	await _lag_checks(url)
	await _stats_checks(url)
	_done()


## HMAC-SHA256 хода ключом стороны, первые 16 байт hex — своей копией (как NetP2P.mac), чтобы
## проба ретранслятора не зависела от клиентского кода и запускалась против старых версий.
func _mac(key: PackedByteArray, raw: String) -> String:
	var h := HMACContext.new()
	h.start(HashingContext.HASH_SHA256, key)
	h.update(raw.to_utf8_buffer())
	return h.finish().slice(0, 16).hex_encode()


## Пара игроков в новой комнате: [хозяин, гость, start хозяина, start гостя].
func _pair(url: String, build: String) -> Array:
	var x := await _connect(url)
	var y := await _connect(url)
	_send(x, {"t": "hello", "v": NetSession.PROTO, "build": build, "name": "X" + build})
	_send(y, {"t": "hello", "v": NetSession.PROTO, "build": build, "name": "Y" + build})
	await _recv_t(x, "welcome")
	await _recv_t(y, "welcome")
	_send(x, {"t": "create", "map": "pvp:duel"})
	var room := await _recv_t(x, "room")
	_send(y, {"t": "join", "code": room.get("code", "")})
	return [x, y, await _recv_t(x, "start"), await _recv_t(y, "start")]


## Подмена хода (verifier 01.10, B): ключ стороны — только ей; жалоба с HMAC её ключом на строку,
## отличную от присланной серверу, — доказанный подлог; поддельный HMAC или та же строка — ничего.
func _forge_checks(url: String) -> void:
	var pr := await _pair(url, "forge")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	var kx := String((pr[2] as Dictionary).get("key", ""))
	var ky := String((pr[3] as Dictionary).get("key", ""))
	_check(kx.length() == 32 and ky.length() == 32 and kx != ky and kx.is_valid_hex_number(),
		"ключ стороны: 16 байт hex, у каждой свой")
	# журнал нельзя выжечь чужим спамом: у подменщика свой счётчик строк
	for i in 45:
		_send(x, {"t": "path", "mode": "p2p", "rtt": 1, "delay": 2, "nat": "cone"})
	for k0 in 4:
		_send(x, {"t": "in", "k": k0, "c": []})
	var honest := {"t": "in", "k": 4, "c": [{"type": "rally", "at": [0, 0]}]}
	var raw_ok := JSON.stringify(honest)
	var raw_bad := JSON.stringify({"t": "in", "k": 4, "c": []})
	_send(x, honest)
	for i in 5:
		await _recv_t(y, "in")
	# 1) поддельный HMAC — жалоба без последствий
	_send(y, {"t": "p2p_mismatch", "k": 4, "raw": raw_bad, "mac": "00".repeat(16)})
	# 2) верный HMAC, но строка та же, что у сервера, — тоже ничего
	_send(y, {"t": "p2p_mismatch", "k": 4, "raw": raw_ok,
		"mac": _mac(kx.hex_decode(), raw_ok)})
	# 3) HMAC ключом X на другой строке — подлог доказан
	_send(y, {"t": "p2p_mismatch", "k": 4, "raw": raw_bad,
		"mac": _mac(kx.hex_decode(), raw_bad)})
	var vy := await _recv_t(y, "verdict")
	var vx := await _recv_t(x, "verdict")
	_check(vy.get("why") == "forge" and int(vy.get("winner", -1)) == 1
		and int(vy.get("cheat", -1)) == 0 and vx.get("why") == "forge",
		"доказанный подлог: техническое поражение подменщику, вердикт обоим")
	_check((await _recv_t(y, "left")).get("t") == "left", "матч закрыт как при сдаче подменщика")
	# 4) жалоба раньше, чем ход обвиняемого дошёл до сервера, — ждёт его
	var pr2 := await _pair(url, "forge2")
	var x2: WebSocketPeer = pr2[0]
	var y2: WebSocketPeer = pr2[1]
	var kx2 := String((pr2[2] as Dictionary).get("key", ""))
	var r2 := JSON.stringify({"t": "in", "k": 2, "c": [{"type": "rally", "at": [0, 0]}]})
	_send(y2, {"t": "p2p_mismatch", "k": 2, "raw": r2, "mac": _mac(kx2.hex_decode(), r2)})
	for k0 in 3:
		_send(x2, {"t": "in", "k": k0, "c": []})
	_check((await _recv_t(y2, "verdict")).get("why") == "forge",
		"жалоба, пришедшая раньше хода обвиняемого, разобрана, когда ход дошёл")
	# 5) «late» — не чаще двух в секунду
	var pr3 := await _pair(url, "late")
	var x3: WebSocketPeer = pr3[0]
	var y3: WebSocketPeer = pr3[1]
	for i in 20:
		_send(x3, {"t": "late"})
	var lates := 0
	for i in 60:
		for o in _socks:
			o.poll()
		while y3.get_available_packet_count() > 0:
			var v: Variant = JSON.parse_string(y3.get_packet().get_string_from_utf8())
			if v is Dictionary and (v as Dictionary).get("t") == "late":
				lates += 1
		await create_timer(0.005).timeout
	_check(lates == 1, "спам «late» срезан (дошло %d из 20)" % lates)
	x3.close()
	y3.close()


## Повтор честного хода под чужим номером (verifier №2 01.10, B1): HMAC верный, но строка — ход
## другого номера; такая жалоба не доказывает ничего, честный не получает поражения.
func _replay_checks(url: String) -> void:
	var pr := await _pair(url, "rep1")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	var kx := String((pr[2] as Dictionary).get("key", "")).hex_decode()
	var raws: Array[String] = []
	for k0 in 6:
		raws.append(JSON.stringify({"t": "in", "k": k0, "c": []}))
		x.send_text(raws[k0])
	for i in 6:
		await _recv_t(y, "in")
	y.send_text(JSON.stringify({"t": "p2p_mismatch", "k": 5, "raw": raws[3],
		"mac": _mac(kx, raws[3])}))
	# лишнее поле в строке хода — тоже не «ход k»
	var extra := JSON.stringify({"t": "in", "k": 5, "c": [], "x": 1})
	y.send_text(JSON.stringify({"t": "p2p_mismatch", "k": 5, "raw": extra, "mac": _mac(kx, extra)}))
	_check((await _recv_t(x, "verdict")).get("t") == "timeout",
		"повтор хода 3 под номером 5 и ход с лишним полем — честному вердикта нет")
	x.close()
	y.close()
	# то же через очередь: жалоба на ещё не присланный ход строкой хода 0
	var pr2 := await _pair(url, "rep2")
	var x2: WebSocketPeer = pr2[0]
	var y2: WebSocketPeer = pr2[1]
	var kx2 := String((pr2[2] as Dictionary).get("key", "")).hex_decode()
	var r0 := JSON.stringify({"t": "in", "k": 0, "c": []})
	x2.send_text(r0)
	await _recv_t(y2, "in")
	y2.send_text(JSON.stringify({"t": "p2p_mismatch", "k": 1, "raw": r0, "mac": _mac(kx2, r0)}))
	await create_timer(0.3).timeout
	x2.send_text(JSON.stringify({"t": "in", "k": 1, "c": []}))
	_check((await _recv_t(x2, "verdict")).get("t") == "timeout",
		"повтор через очередь жалоб — честному вердикта нет")
	x2.close()
	y2.close()


## Забег, разрыв и общий старт (verifier 01.10 A, verifier №2 A1): ретранслятор запущен с
## --lag-turns 60 --ready-timeout 4000 (tools/net_probe.sh).
func _lag_checks(url: String) -> void:
	# до общего старта (оба «ready») — только стартовые ходы: обманщик, придержавший «ready» и
	# гонящий ходы, отключается, а честный не застревает на сотнях его ходов
	var pr0 := await _pair(url, "noready")
	var h0: WebSocketPeer = pr0[0]
	var c0: WebSocketPeer = pr0[1]
	h0.send_text(JSON.stringify({"t": "ready"}))
	for k0 in 30:
		_send(c0, {"t": "in", "k": k0, "c": []})
	var got0 := {}
	for i in 2:
		got0 = await _recv_t(h0, "left")
		if got0.get("t") == "left":
			break
	_check(got0.get("t") == "left", "ходы вперёд без общего старта — отключён гонящий, не честный")
	_send(h0, {"t": "ping", "ms": 6})
	_check(int((await _recv_t(h0, "pong")).get("ms", 0)) == 6, "честный остался на связи")
	h0.close()
	# соперник так и не прислал «ready» — комната закрывается без итога, причина — обоим
	var pr1 := await _pair(url, "noready2")
	var h1: WebSocketPeer = pr1[0]
	var c1: WebSocketPeer = pr1[1]
	h1.send_text(JSON.stringify({"t": "ready"}))
	var e1 := await _recv_long(h1, "error")
	_check(e1.get("code") == "no_ready", "нет «ready» соперника — «поле не загружено», без сдачи")
	h1.close()
	c1.close()
	# ходы раньше часов боя — спам будущим: рвётся отправитель
	var pr := await _pair(url, "clock")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	_send(x, {"t": "ready"})
	_send(y, {"t": "ready"})
	await _recv_t(x, "ready")   # как клиент: ходы — только после «ready» соперника
	for k0 in 60:
		_send(x, {"t": "in", "k": k0, "c": []})
	var got := {}
	for i in 3:   # до «left» сопернику приходят 53 пересланных хода — больше одного окна _recv_t
		got = await _recv_t(y, "left")
		if got.get("t") == "left":
			break
	_check(got.get("t") == "left", "ход раньше часов матча — отправитель отключён")
	y.close()
	# одна сторона далеко впереди другой на сервере (честный медленный или придержка) — сервер
	# никого не рвёт (verifier №3: так рвало честного с медленной машиной)
	var pr2 := await _pair(url, "lag")
	var x2: WebSocketPeer = pr2[0]
	var y2: WebSocketPeer = pr2[1]
	_send(x2, {"t": "ready"})
	_send(y2, {"t": "ready"})
	await create_timer(6.0).timeout   # по часам боя — 120 ходов
	for k0 in 2:
		_send(y2, {"t": "in", "k": k0, "c": []})
	# «void» без разрыва ходов — запрос отклонён ТОЛЬКО заявителю, без выхода и сдачи (verifier №4);
	# повтор раньше 25 с — молча мимо
	var pr3 := await _pair(url, "void0")
	var x3: WebSocketPeer = pr3[0]
	var y3: WebSocketPeer = pr3[1]
	_send(x3, {"t": "ready"})
	_send(y3, {"t": "ready"})
	await _recv_t(x3, "ready")
	_send(x3, {"t": "void"})
	_check((await _recv_t(x3, "void_denied")).get("t") == "void_denied",
		"«void» без разрыва — отказ заявителю")
	_send(x3, {"t": "void"})
	_send(y3, {"t": "ping", "ms": 8})
	var py := await _recv_t(y3, "pong")   # до pong соперник не получил ни «left», ни «error»
	_send(x3, {"t": "ping", "ms": 7})
	_check(int(py.get("ms", 0)) == 8 and int((await _recv_t(x3, "pong")).get("ms", 0)) == 7,
		"после отказа и повтора оба в матче: ни выхода, ни сдачи")
	x3.close()
	y3.close()
	for k0 in 110:
		_send(x2, {"t": "in", "k": k0, "c": []})
	_send(x2, {"t": "ping", "ms": 5})
	_check(int((await _recv_long(x2, "pong")).get("ms", 0)) == 5 and y2.get_ready_state()
		== WebSocketPeer.STATE_OPEN, "разрыв 108 ходов — никого не отключили")
	# обоснованный «void» (впереди на ≥ 100) — матч без итога, причина обоим
	_send(x2, {"t": "void"})
	_check((await _recv_long(y2, "error")).get("code") == "void"
		and (await _recv_long(x2, "error")).get("code") == "void",
		"«void» при разрыве — матч прерван без итога у обоих")
	x2.close()
	y2.close()
	# имя: кавычки-ёлочки и двунаправленные символы вычищены
	var n := await _connect(url)
	_send(n, {"t": "hello", "v": NetSession.PROTO, "build": "nm",
		"name": "A»: итог стороны 1 «B" + String.chr(0x202E) + "x" + String.chr(0x200F)})
	_check(String((await _recv_t(n, "welcome")).get("name", "")) == "A: итог стороны 1 Bx",
		"имя без «ёлочек» и двунаправленных символов")
	n.close()


## То же, что _recv_t, но дольше: до нужного пакета бывает больше 40 пересланных ходов, а одно
## ожидание _recv — 3 с.
func _recv_long(ws: WebSocketPeer, t: String) -> Dictionary:
	var m := {}
	for i in 4:
		m = await _recv_t(ws, t)
		if m.get("t") == t:
			break
	return m


## Сводка матча (Игорь 01.10): одна на сторону, проверена и обрезана; повтор и мусор — молча;
## не пришла за --stats-grace после закрытия комнаты — строка «не пришёл». Строки сверяет
## tools/net_probe.sh по relay.log.
func _stats_checks(url: String) -> void:
	var pr := await _pair(url, "stats")
	var x: WebSocketPeer = pr[0]
	var y: WebSocketPeer = pr[1]
	var good := {"t": "stats", "mode": "p2p", "fb_tick": -1, "udp": 87, "relay": 13,
		"stall_s": 3.1, "stall_max": 0.8, "stall_n": 5, "d0": 2, "d1": 3, "p2p50": 15,
		"p2p90": 40, "rel50": 110, "rel90": 190, "nat": "cone", "desync": -1, "ticks": 22320,
		"wall": 372.0, "end": "win"}
	_send(x, good)
	_send(x, good)   # повтор — молча мимо
	_send(y, {"t": "stats", "mode": [], "fb_tick": 1.0e300, "udp": -5, "relay": "x",
		"stall_s": 1.0e300, "stall_max": {}, "stall_n": -1, "d0": 999,
		"d1": "a", "p2p50": 1.0e20, "p2p90": null, "rel50": -7, "nat": "<b>", "desync": 3.5,
		"ticks": -1, "wall": -10, "end": "hacked"})
	_send(x, {"t": "ping", "ms": 9})
	_check(int((await _recv_t(x, "pong")).get("ms", 0)) == 9, "сводка с мусором — без падения")
	x.close()
	y.close()
	# сводки нет — после закрытия комнаты и --stats-grace строка «не пришёл»
	var pr2 := await _pair(url, "nostats")
	var x2: WebSocketPeer = pr2[0]
	var y2: WebSocketPeer = pr2[1]
	_send(x2, {"t": "leave"})
	await create_timer(2.6).timeout
	_send(y2, {"t": "stats", "udp": 1, "relay": 1, "end": "opp_left"})   # поздно — мимо
	_send(y2, {"t": "ping", "ms": 4})
	_check(int((await _recv_t(y2, "pong")).get("ms", 0)) == 4, "поздняя сводка — без падения")
	# сводка оставшегося сразу после ухода соперника — принимается (комната уже закрыта)
	var pr3 := await _pair(url, "afterleft")
	var x3: WebSocketPeer = pr3[0]
	var y3: WebSocketPeer = pr3[1]
	_send(x3, {"t": "leave"})
	await _recv_t(y3, "left")
	_send(y3, {"t": "stats", "udp": 0, "relay": 10, "end": "opp_left", "mode": "relay"})
	_send(y3, {"t": "ping", "ms": 3})
	await _recv_t(y3, "pong")
	for w: WebSocketPeer in [x2, y2, x3, y3]:
		w.close()


## Первое сообщение нужного типа (остальные — лобби, приветствия — пропускаются).
func _recv_t(ws: WebSocketPeer, t: String) -> Dictionary:
	for i in 40:
		var m := await _recv(ws)
		if m.get("t") == t or m.get("t") == "timeout":
			return m
	return {"t": "timeout"}


## Лобби с ровно n открытыми комнатами (ждём, пока придёт такое).
func _recv_lobby(ws: WebSocketPeer, n: int) -> Dictionary:
	for i in 40:
		var m := await _recv_t(ws, "lobby")
		if m.get("t") == "timeout":
			return m
		if (m.get("rooms", []) as Array).size() == n:
			return m
	return {"t": "timeout"}


func _connect(url: String) -> WebSocketPeer:
	var ws := WebSocketPeer.new()
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


func _send(ws: WebSocketPeer, msg: Dictionary) -> void:
	ws.send_text(JSON.stringify(msg))


func _recv(ws: WebSocketPeer) -> Dictionary:
	for i in 600:
		for other in _socks:
			other.poll()
		if ws.get_available_packet_count() > 0:
			var v: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			return v if v is Dictionary else {}
		await create_timer(0.005).timeout
	return {"t": "timeout"}


func _done() -> void:
	print("net_relay_probe: %d/%d OK" % [_ok, _all])
	quit(0 if _ok == _all else 1)
