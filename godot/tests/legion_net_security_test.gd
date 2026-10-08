extends SceneTree
## B-403/B-405: состояние настоящего ретранслятора, без тяжёлых процессов судей и внешней сети.
## С 08.10.2026 ядро — NetRelayCore (сокеты у владельца): проверки идут на самом ядре, отправка и
## запуск судьи подменены крючками dbg_send / dbg_spawn_judge (подкласс ядра внутренним классом
## ронял процесс на выходе — код 139); каналы игроков — базовые NetLink (CLOSED: отправка
## не проходит, служебное копится в outq, как раньше с неоткрытым WebSocketPeer). Проверки
## прямого пути/галочки лобби — legion_net_privacy_test.gd (вместе в одном процессе падало на выходе).

var r: NetRelayCore


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return false


func _run() -> void:
	r = NetRelayCore.new()
	# крючки вместо подкласса ядра (см. шапку)
	r.dbg_spawn_judge = _spawn_judge_stub
	r.dbg_send = _send_stub
	_start_budget()
	_idle_checks()
	_history_checks()
	_role_checks()
	_log_checks()
	_reset()
	var code := 0 if _ok == _all else 1
	print("legion_net_security_test: %d/%d OK" % [_ok, _all])
	quit(code)


func _spawn_judge_stub(_code: String) -> void:
	_spawns += 1


func _send_stub(_link: NetLink, _text: String) -> bool:
	return _allow_sends


var _ok := 0
var _all := 0
var _spawns := 0
var _allow_sends := false




func _check(cond: bool, what: String) -> void:
	_all += 1
	if cond:
		_ok += 1
	else:
		print("FAIL: ", what)


func _peer(id: int) -> Dictionary:
	var now := Time.get_ticks_msec()
	var p := {"link": NetLink.new(), "born": now, "hello": true, "name": "P%d" % id,
		"build": "test", "room": "", "side": -1, "win_start": now, "win_count": 0,
		"outq": [], "outq_bytes": 0, "lobby_next": "", "tail": [], "tail_bytes": 0,
		"tail_cost": 0, "judge_only": false, "idle_at": now, "op_at": now,
		"op_tokens": float(NetRelayCore.ROOM_OP_BURST)}
	r._peers[id] = p
	return p


func _reset() -> void:
	r._rooms.clear()
	r._peers.clear()
	r._stats_wait.clear()
	r._judge_tokens = NetRelayCore.JUDGE_START_BURST
	r._judge_refill_at = Time.get_ticks_msec()
	_spawns = 0
	_allow_sends = false


func _last_error(id: int) -> String:
	var q: Array = r._peers[id]["outq"]
	if q.is_empty():
		return ""
	return String((JSON.parse_string(String(q.back())) as Dictionary).get("code", ""))


func _start_budget() -> void:
	_reset()
	r.judge_max = 1
	for i in NetRelayCore.JUDGE_START_BURST:
		# Новые сокеты на каждом цикле: глобальный бюджет reconnect не восстанавливает.
		_peer(i * 2 + 1)
		_peer(i * 2 + 2)
		r._create_room(i * 2 + 1, "pvp:duel")
		r._join_room(i * 2 + 2, String(r._peers[i * 2 + 1]["room"]))
		r._leave_room(i * 2 + 2)
	var a := _peer(30)
	var b := _peer(31)
	r._create_room(30, "pvp:duel")
	var code := String(a["room"])
	r._join_room(31, code)
	_check(_spawns == NetRelayCore.JUDGE_START_BURST, "churn/reconnect ограничен глобальным бюджетом")
	_check(_last_error(31) == "rate_limit" and String(b["room"]) == ""
		and not bool(r._rooms[code]["started"]), "отказ join сохраняет ожидающую комнату")
	r._judge_refill_at -= NetRelayCore.JUDGE_START_MS
	r._join_room(31, code)
	_check(_spawns == NetRelayCore.JUDGE_START_BURST + 1 and bool(r._rooms[code]["started"]),
		"после восстановления бюджета матч запускается")
	_reset()
	var p := _peer(1)
	for i in NetRelayCore.ROOM_OP_BURST:
		_check(r._room_op_ok(1), "разрешён первоначальный запас запросов %d" % i)
	_check(not r._room_op_ok(1) and _last_error(1) == "rate_limit", "лимит запросов комнаты")
	p["op_at"] = int(p["op_at"]) - NetRelayCore.ROOM_OP_MS
	_check(r._room_op_ok(1), "бюджет запросов восстанавливается")
	r._create_room(1, "pvp:duel")
	r._handle(1, {"t": "leave"}, "")
	_check(String(p["room"]) == "", "leave разрешён при исчерпанном бюджете")


func _idle_checks() -> void:
	_reset()
	var p := _peer(1)
	var now := Time.get_ticks_msec()
	p["idle_at"] = now - NetRelayCore.LOBBY_IDLE_MS
	r._handle(1, {"t": "ping", "ms": 1}, "")
	r._handle(1, {"t": "hello", "v": NetRelayCore.PROTO}, "")
	_check(r._idle_expired(p, now), "ping/повтор hello не продлевают ожидание")
	r._create_room(1, "pvp:duel")
	p["idle_at"] = now - NetRelayCore.LOBBY_IDLE_MS
	_check(r._idle_expired(p, now), "ожидание соперника истекает")
	var code := String(p["room"])
	r._rooms[code]["started"] = true
	_check(not r._idle_expired(p, now), "тайм-аут лобби не рвёт активный матч")
	r._rooms[code]["started"] = false
	r._leave_room(1)
	_check(not r._idle_expired(p, Time.get_ticks_msec()), "после матча новое окно ожидания")


func _pair() -> Dictionary:
	_reset()
	r.judge_max = 0
	_peer(1)
	_peer(2)
	r._create_room(1, "pvp:duel")
	r._join_room(2, String(r._peers[1]["room"]))
	return r._rooms[String(r._peers[1]["room"])]


func _history_checks() -> void:
	var room := _pair()
	var raw := JSON.stringify({"t": "in", "k": 0, "c": []})
	r._in(1, JSON.parse_string(raw), raw)
	_check(r._history_total() > raw.length() * 4 + NetRelayCore.TURN_STORAGE_OVERHEAD,
		"учтены обе строки и накладные расходы записи")
	var code := String(r._peers[1]["room"])
	r._leave_room(1)
	_check(not r._rooms.has(code) and r._history_total() == int(r._peers[2]["tail_cost"])
		and r._history_total() > 0, "бюджет закрытой комнаты освобождён, хвост учтён")
	_allow_sends = true
	r._pump_out()
	_check(r._history_total() == 0 and r._peers.has(2), "доставка хвоста освобождает бюджет")
	room = _pair()
	r._in(1, JSON.parse_string(raw), raw)
	r._leave_room(1)
	r._drop(2, "тест")
	_check(r._history_total() == 0, "отключение получателя освобождает хвост")
	room = _pair()
	(room["history_cost"] as Array)[0] = NetRelayCore.HISTORY_SIDE_MAX
	r._in(1, JSON.parse_string(raw), raw)
	_check(not r._peers.has(1) and r._peers.has(2) and r._rooms.is_empty(),
		"переполнение стороны отключает отправителя, соперник остаётся")
	_check(int((room["next_k"] as Array)[0]) == 0, "отклонённый ход не сдвигает next_k")
	room = _pair()
	var hoarder := _peer(3)
	hoarder["tail_cost"] = NetRelayCore.HISTORY_TOTAL_MAX
	r._in(1, JSON.parse_string(raw), raw)
	_check(not r._peers.has(3) and r._peers.has(1) and r._peers.has(2)
		and int((room["next_k"] as Array)[0]) == 1,
		"общий бюджет включает хвосты и не подставляет следующего отправителя")
	_reset()
	_check(r._history_total() == 0, "новая комната не наследует старую память")


func _role_checks() -> void:
	var room := _pair()
	room["key"] = "secret"
	var code := String(r._peers[1]["room"])
	_peer(3)
	r._handle(3, {"t": "judge", "v": NetRelayCore.PROTO, "room": code, "key": "secret"}, "")
	_check(not r._peers.has(3) and int(room["judge"]) == 0,
		"даже правильный ключ не допускает судью на публичном входе")
	var p := _peer(4)
	p["judge_only"] = true
	p["hello"] = false
	r._handle(4, {"t": "hello", "v": NetRelayCore.PROTO}, "")
	_check(not r._peers.has(4), "обычный hello не занимает резерв судьи")
	p = _peer(5)
	p["judge_only"] = true
	p["hello"] = false
	r._handle(5, {"t": "judge", "v": NetRelayCore.PROTO, "room": code, "key": "wrong"}, "")
	_check(p.has("kick_at") and int(room["judge"]) == 0, "резерв требует правильный ключ")
	p = _peer(6)
	p["judge_only"] = true
	p["hello"] = false
	r._handle(6, {"t": "judge", "v": NetRelayCore.PROTO, "room": code, "key": "secret"}, "")
	_check(bool(p.get("judge", false)) and int(room["judge"]) == 6,
		"судья проходит внутренний вход по ключу")


func _log_checks() -> void:
	_check(r._clean_build("v1\n\r\u001b[31m\u202efile").find("\n") < 0
		and r._clean_build("v1\n\r\u001b[31m\u202efile") == "v131mfile", "build очищен")
	_check(r._clean_build(NetSession.BUILD) == NetSession.BUILD, "идентификатор сборки сохранён")
	r._log_at = Time.get_ticks_msec()
	r._log_count = NetRelayCore.LOGS_PER_SEC
	r._log_suppressed = 0
	r._log("подавленный тест")
	_check(r._log_suppressed == 1, "общее ограничение частоты лога")
	r._proof_log_count = 0
	r._log("доказательство теста", true)
	_check(r._proof_log_count == 1, "шторм обычного лога не скрывает доказательство")
	r._log_at -= 1000
	r._log("после окна")
	_check(r._log_count == 1 and r._log_suppressed == 0, "лог восстанавливается после окна")
