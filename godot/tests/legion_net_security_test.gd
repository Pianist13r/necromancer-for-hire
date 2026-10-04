extends "res://scripts/legion/net/net_relay.gd"
## B-403/B-405: состояние настоящего ретранслятора, без тяжёлых процессов судей и внешней сети.

var _ok := 0
var _all := 0
var _spawns := 0
var _allow_sends := false


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return false


func _spawn_judge(_code: String) -> void:
	_spawns += 1


func _try_send(_ws: WebSocketPeer, _text: String) -> bool:
	return _allow_sends


func _check(cond: bool, what: String) -> void:
	_all += 1
	if cond:
		_ok += 1
	else:
		print("FAIL: ", what)


func _peer(id: int) -> Dictionary:
	var now := Time.get_ticks_msec()
	var p := {"ws": WebSocketPeer.new(), "born": now, "hello": true, "name": "P%d" % id,
		"build": "test", "room": "", "side": -1, "win_start": now, "win_count": 0,
		"outq": [], "outq_bytes": 0, "lobby_next": "", "tail": [], "tail_bytes": 0,
		"tail_cost": 0, "judge_only": false, "idle_at": now, "op_at": now,
		"op_tokens": float(ROOM_OP_BURST)}
	_peers[id] = p
	return p


func _reset() -> void:
	_rooms.clear()
	_peers.clear()
	_stats_wait.clear()
	_judge_tokens = JUDGE_START_BURST
	_judge_refill_at = Time.get_ticks_msec()
	_spawns = 0
	_allow_sends = false


func _last_error(id: int) -> String:
	var q: Array = _peers[id]["outq"]
	if q.is_empty():
		return ""
	return String((JSON.parse_string(String(q.back())) as Dictionary).get("code", ""))


func _run() -> void:
	_start_budget()
	_idle_checks()
	_history_checks()
	_role_checks()
	_log_checks()
	await _privacy_checks()
	_reset()
	print("legion_net_security_test: %d/%d OK" % [_ok, _all])
	quit(0 if _ok == _all else 1)


func _start_budget() -> void:
	_reset()
	_judge_max = 1
	for i in JUDGE_START_BURST:
		# Новые сокеты на каждом цикле: глобальный бюджет reconnect не восстанавливает.
		_peer(i * 2 + 1)
		_peer(i * 2 + 2)
		_create_room(i * 2 + 1, "pvp:duel")
		_join_room(i * 2 + 2, String(_peers[i * 2 + 1]["room"]))
		_leave_room(i * 2 + 2)
	var a := _peer(30)
	var b := _peer(31)
	_create_room(30, "pvp:duel")
	var code := String(a["room"])
	_join_room(31, code)
	_check(_spawns == JUDGE_START_BURST, "churn/reconnect ограничен глобальным бюджетом")
	_check(_last_error(31) == "rate_limit" and String(b["room"]) == ""
		and not bool(_rooms[code]["started"]), "отказ join сохраняет ожидающую комнату")
	_judge_refill_at -= JUDGE_START_MS
	_join_room(31, code)
	_check(_spawns == JUDGE_START_BURST + 1 and bool(_rooms[code]["started"]),
		"после восстановления бюджета матч запускается")
	_reset()
	var p := _peer(1)
	for i in ROOM_OP_BURST:
		_check(_room_op_ok(1), "разрешён первоначальный запас запросов %d" % i)
	_check(not _room_op_ok(1) and _last_error(1) == "rate_limit", "лимит запросов комнаты")
	p["op_at"] = int(p["op_at"]) - ROOM_OP_MS
	_check(_room_op_ok(1), "бюджет запросов восстанавливается")
	_create_room(1, "pvp:duel")
	_handle(1, {"t": "leave"}, "")
	_check(String(p["room"]) == "", "leave разрешён при исчерпанном бюджете")


func _idle_checks() -> void:
	_reset()
	var p := _peer(1)
	var now := Time.get_ticks_msec()
	p["idle_at"] = now - LOBBY_IDLE_MS
	_handle(1, {"t": "ping", "ms": 1}, "")
	_handle(1, {"t": "hello", "v": PROTO}, "")
	_check(_idle_expired(p, now), "ping/повтор hello не продлевают ожидание")
	_create_room(1, "pvp:duel")
	p["idle_at"] = now - LOBBY_IDLE_MS
	_check(_idle_expired(p, now), "ожидание соперника истекает")
	var code := String(p["room"])
	_rooms[code]["started"] = true
	_check(not _idle_expired(p, now), "тайм-аут лобби не рвёт активный матч")
	_rooms[code]["started"] = false
	_leave_room(1)
	_check(not _idle_expired(p, Time.get_ticks_msec()), "после матча новое окно ожидания")


func _pair() -> Dictionary:
	_reset()
	_judge_max = 0
	_peer(1)
	_peer(2)
	_create_room(1, "pvp:duel")
	_join_room(2, String(_peers[1]["room"]))
	return _rooms[String(_peers[1]["room"])]


func _history_checks() -> void:
	var room := _pair()
	var raw := JSON.stringify({"t": "in", "k": 0, "c": []})
	_in(1, JSON.parse_string(raw), raw)
	_check(_history_total() > raw.length() * 4 + TURN_STORAGE_OVERHEAD,
		"учтены обе строки и накладные расходы записи")
	var code := String(_peers[1]["room"])
	_leave_room(1)
	_check(not _rooms.has(code) and _history_total() == int(_peers[2]["tail_cost"])
		and _history_total() > 0, "бюджет закрытой комнаты освобождён, хвост учтён")
	_allow_sends = true
	_pump_out()
	_check(_history_total() == 0 and _peers.has(2), "доставка хвоста освобождает бюджет")
	room = _pair()
	_in(1, JSON.parse_string(raw), raw)
	_leave_room(1)
	_drop(2, "тест")
	_check(_history_total() == 0, "отключение получателя освобождает хвост")
	room = _pair()
	(room["history_cost"] as Array)[0] = HISTORY_SIDE_MAX
	_in(1, JSON.parse_string(raw), raw)
	_check(not _peers.has(1) and _peers.has(2) and _rooms.is_empty(),
		"переполнение стороны отключает отправителя, соперник остаётся")
	_check(int((room["next_k"] as Array)[0]) == 0, "отклонённый ход не сдвигает next_k")
	room = _pair()
	var hoarder := _peer(3)
	hoarder["tail_cost"] = HISTORY_TOTAL_MAX
	_in(1, JSON.parse_string(raw), raw)
	_check(not _peers.has(3) and _peers.has(1) and _peers.has(2)
		and int((room["next_k"] as Array)[0]) == 1,
		"общий бюджет включает хвосты и не подставляет следующего отправителя")
	_reset()
	_check(_history_total() == 0, "новая комната не наследует старую память")


func _role_checks() -> void:
	var room := _pair()
	room["key"] = "secret"
	var code := String(_peers[1]["room"])
	_peer(3)
	_handle(3, {"t": "judge", "v": PROTO, "room": code, "key": "secret"}, "")
	_check(not _peers.has(3) and int(room["judge"]) == 0,
		"даже правильный ключ не допускает судью на публичном входе")
	var p := _peer(4)
	p["judge_only"] = true
	p["hello"] = false
	_handle(4, {"t": "hello", "v": PROTO}, "")
	_check(not _peers.has(4), "обычный hello не занимает резерв судьи")
	p = _peer(5)
	p["judge_only"] = true
	p["hello"] = false
	_handle(5, {"t": "judge", "v": PROTO, "room": code, "key": "wrong"}, "")
	_check(p.has("kick_at") and int(room["judge"]) == 0, "резерв требует правильный ключ")
	p = _peer(6)
	p["judge_only"] = true
	p["hello"] = false
	_handle(6, {"t": "judge", "v": PROTO, "room": code, "key": "secret"}, "")
	_check(bool(p.get("judge", false)) and int(room["judge"]) == 6,
		"судья проходит внутренний вход по ключу")


func _log_checks() -> void:
	_check(_clean_build("v1\n\r\u001b[31m\u202efile").find("\n") < 0
		and _clean_build("v1\n\r\u001b[31m\u202efile") == "v131mfile", "build очищен")
	_check(_clean_build(NetSession.BUILD) == NetSession.BUILD, "идентификатор сборки сохранён")
	_log_at = Time.get_ticks_msec()
	_log_count = LOGS_PER_SEC
	_log_suppressed = 0
	_log("подавленный тест")
	_check(_log_suppressed == 1, "общее ограничение частоты лога")
	_proof_log_count = 0
	_log("доказательство теста", true)
	_check(_proof_log_count == 1, "шторм обычного лога не скрывает доказательство")
	_log_at -= 1000
	_log("после окна")
	_check(_log_count == 1 and _log_suppressed == 0, "лог восстанавливается после окна")


func _privacy_checks() -> void:
	var cfg := ConfigFile.new()
	cfg.save(NetLobby.CFG)
	var session := NetSession.new()
	root.add_child(session)
	_check(not session.direct_enabled, "сессия по умолчанию без прямого пути")
	session._start_p2p("11".repeat(16))
	_check(session._p2p == null, "без согласия нет UDP/STUN")
	var lobby := NetLobby.new().setup(session)
	root.add_child(lobby)
	_check(not lobby._direct.button_pressed and not session.direct_enabled,
		"новый игрок в лобби без прямого пути")
	lobby._direct.button_pressed = true
	lobby.free()
	lobby = NetLobby.new().setup(session)
	root.add_child(lobby)
	_check(lobby._direct.button_pressed and session.direct_enabled, "существующий выбор сохранён")
	lobby._direct.button_pressed = false
	lobby.free()
	session.free()
	await process_frame
