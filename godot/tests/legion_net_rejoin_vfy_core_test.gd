extends SceneTree
##
## Пробы verifier 11.10 по переподключению (ядро NetRelayCore без сокетов), перенесены как регресс
## (ветка slow/net-rejoin): V1 «void» соперника сразу после возврата, до хвоста, — не прерывает
## матч (окно VOID_SHIELD_MS); V2 поток неверных rj не трогает сторону и не выжигает её строки лога;
## V3 утёкший rj — вытеснение (ожидаемо; rj — полномочие стороны); V4 кривой have — отказ state;
## V5 ожидание/загрузка/после своего end — отказ, канал цел; V6 обрыв у обоих: вернувшемуся —
## отсчёт соперника, срок соперника — победа; V7 подтяжка, запрошенная в отсутствие, отменяется на
## возврате; V8 повторы одним rid (справочно).
##   "$GODOT" --headless --path godot --fixed-fps 60 \
##       --script res://tests/legion_net_rejoin_vfy_core_test.gd -- --mute
## Итог «VFY REJOIN CORE: N/M OK», код выхода 1 при провале.
##

const MAP := "pvp:duel"
var r: NetRelayCore
var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _process(_d: float) -> bool:
	return false


func _check(cond: bool, what: String) -> void:
	_checks += 1
	print(("  ok   " if cond else "  FAIL "), what)
	if not cond:
		_fails += 1


func _noop_judge(_c: String) -> void:
	pass


func _match(turns := 10) -> String:
	r = NetRelayCore.new()
	r.dbg_spawn_judge = _noop_judge
	for i in 2:
		var id := r.add_link(NetLink.new(), false)
		r._handle(id, {"t": "hello", "v": NetRelayCore.PROTO, "build": "t", "name": "p%d" % id,
			"caps": ["rejoin"]}, "")
	r._handle(1, {"t": "create", "map": MAP}, "")
	var code := String(r._peers[1]["room"])
	r._handle(2, {"t": "join", "code": code}, "")
	r._handle(1, {"t": "ready"}, "")
	r._handle(2, {"t": "ready"}, "")
	for id: int in [1, 2]:
		_turns(id, 0, turns)
	_clear(1)
	_clear(2)
	return code


func _turns(id: int, from: int, to: int) -> void:
	for k in range(from, to):
		var raw := JSON.stringify({"t": "in", "k": k, "c": []})
		r._handle(id, JSON.parse_string(raw), raw)


func _clear(id: int) -> void:
	if r._peers.has(id):
		(r._peers[id]["outq"] as Array).clear()
		r._peers[id]["outq_bytes"] = 0


func _types(id: int) -> Array:
	var out := []
	if not r._peers.has(id):
		return out
	for t: String in r._peers[id]["outq"]:
		var m: Variant = JSON.parse_string(t)
		if m is Dictionary:
			var d: Dictionary = m
			out.append(String(d.get("t", "")) + ("/" + String(d.get("code", "")) if d.has("code") else ""))
		else:
			out.append("?")
	return out


func _find(id: int, t: String) -> Dictionary:
	if not r._peers.has(id):
		return {}
	for s: String in r._peers[id]["outq"]:
		var m: Variant = JSON.parse_string(s)
		if m is Dictionary and String((m as Dictionary).get("t", "")) == t:
			return m
	return {}


func _cut(id: int) -> void:
	if r._peers.has(id):
		if r._peers[id].has("kick_at"):
			r._peers[id]["kick_at"] = 0
		r._poll_peer(id)


func _newcomer() -> int:
	var id := r.add_link(NetLink.new(), false)
	r._handle(id, {"t": "hello", "v": NetRelayCore.PROTO, "build": "t", "name": "x",
		"caps": ["rejoin"]}, "")
	_clear(id)
	return id


func _rejoin(id: int, code: String, s: int, rj: Variant, have: Variant, rid := "r1") -> void:
	r._handle(id, {"t": "rejoin", "code": code, "side": s, "rj": rj, "have": have, "rid": rid}, "")


func _rj(code: String, s: int) -> String:
	return String((r._rooms[code]["rj"] as Array)[s])


func _run() -> void:
	while Time.get_ticks_msec() < 12000:
		OS.delay_msec(100)
	_v1_void_race()
	_v2_wrong_rj_present()
	_v3_leaked_rj()
	_v4_have()
	_v5_lobby_and_end()
	_v6_both_away()
	_v7_heal_while_away()
	_v8_same_rid_no_limit()
	_v9_stale_peer()
	_v10_live_rejoin_budget()
	print("VFY REJOIN CORE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## void race: B ahead by >= VOID_MIN_GAP on server (A copies lost with dead WS), A away,
## B void denied with away; A rejoins; B void retry arrives BEFORE A tail.
func _v1_void_race() -> void:
	print("-- V1 void after rejoined, before tail")
	var code := _match(10)
	var room: Dictionary = r._rooms[code]
	room["go_ms"] = Time.get_ticks_msec() - 10000
	_turns(1, 10, 160)
	_check(int((room["next_k"] as Array)[0]) == 160, "B next_k 160, A next_k 10")
	_cut(2)
	_clear(1)
	r._handle(1, {"t": "void"}, "")
	_check(_find(1, "void_denied").get("away") == true, "void during away -> denied {away}")
	_clear(1)
	var nid := _newcomer()
	_rejoin(nid, code, 1, _rj(code, 1), 159)
	_check(not _find(nid, "rejoined").is_empty(), "A rejoined (next %s)" % str(_find(nid, "rejoined").get("next")))
	r._handle(1, {"t": "void"}, "")
	var closed := not r._rooms.has(code)
	print("    B queue: ", _types(1), "   A(new) queue: ", _types(nid))
	_check(not closed, "honest A just returned: match NOT voided by B void before A tail (closed=%s)" % closed)


func _v2_wrong_rj_present() -> void:
	print("-- V2 wrong rj, victim present")
	var code := _match(10)
	var room: Dictionary = r._rooms[code]
	var logs_before := int((room["logs"] as Array)[1])
	for i in 50:
		var a := _newcomer()
		_rejoin(a, code, 1, "f".repeat(32), 5, "atk%d" % i)
		if i == 0:
			_check(String(_find(a, "rejoin_denied").get("why", "")) == "token", "-> token")
	_check(int((room["peers"] as Array)[1]) == 2 and r._peers.has(2) and not r._peers[2].has("kick_at")
		and int((room["away_total"] as Array)[1]) == 0 and int((room["rejoins"] as Array)[1]) == 0
		and int((room["gen"] as Array)[1]) == 0, "victim channel alive, budget/gen untouched")
	_check(int((room["logs"] as Array)[1]) - logs_before <= NetRelayCore.PATH_LOGS_MAX,
		"attacker did not exhaust victim log budget (logs[1] %d -> %d, cap %d)" % [logs_before,
		int((room["logs"] as Array)[1]), NetRelayCore.PATH_LOGS_MAX])


func _v3_leaked_rj() -> void:
	print("-- V3 leaked rj")
	var code := _match(10)
	var a := _newcomer()
	_rejoin(a, code, 1, _rj(code, 1), 5, "evil")
	_check(int((r._rooms[code]["peers"] as Array)[1]) == a and r._peers[2].has("kick_at"),
		"(expected) leaked rj displaces the live honest channel without away")
	_clear(1)
	r._handle(a, {"t": "leave"}, "")
	_check(not r._rooms.has(code) and "left" in _types(1),
		"(expected) ...and its leave = honest side surrender: %s" % str(_types(1)))


func _v4_have() -> void:
	print("-- V4 have")
	var code := _match(10)
	_cut(2)
	for c: Array in [[10, "state"], [1000000000, "state"], [1.0e20, "state"], ["5", "state"],
			[-2, "state"], [3.5, "state"]]:
		var a := _newcomer()
		_rejoin(a, code, 1, _rj(code, 1), c[0])
		_check(String(_find(a, "rejoin_denied").get("why", "")) == String(c[1])
			and int((r._rooms[code]["peers"] as Array)[1]) == 2,
			"have=%s -> %s" % [str(c[0]), String(_find(a, "rejoin_denied").get("why", ""))])
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), -1)
	_check(not _find(b, "rejoined").is_empty() and int((r._rooms[code]["out_k"] as Array)[0]) == 0,
		"have=-1 -> rejoined, opponent turns from 0")


func _v5_lobby_and_end() -> void:
	print("-- V5 lobby / loading / end")
	r = NetRelayCore.new()
	r.dbg_spawn_judge = _noop_judge
	for i in 2:
		var id := r.add_link(NetLink.new(), false)
		r._handle(id, {"t": "hello", "v": NetRelayCore.PROTO, "build": "t", "name": "p%d" % id,
			"caps": ["rejoin"]}, "")
	r._handle(1, {"t": "create", "map": MAP}, "")
	var code := String(r._peers[1]["room"])
	var a := _newcomer()
	_rejoin(a, code, 0, "0".repeat(32), -1)
	_check(String(_find(a, "rejoin_denied").get("why", "")) == "token" and r._rooms.has(code)
		and String(r._peers[1]["room"]) == code, "waiting room: token, host untouched")
	r._handle(2, {"t": "join", "code": code}, "")
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), -1)
	_check(String(_find(b, "rejoin_denied").get("why", "")) == "expired" and r._peers.has(2)
		and int((r._rooms[code]["peers"] as Array)[1]) == 2, "loading: expired, side untouched")
	_cut(2)
	_check(not r._rooms.has(code), "drop during loading: room closed (as before)")
	code = _match(10)
	r._handle(2, {"t": "end"}, "")
	var c := _newcomer()
	_rejoin(c, code, 1, _rj(code, 1), 5)
	_check(String(_find(c, "rejoin_denied").get("why", "")) == "expired" and r._peers.has(2),
		"after own end: expired, live channel untouched")


func _v6_both_away() -> void:
	print("-- V6 both away, one returns, other expires")
	var code := _match(10)
	_cut(1)
	_cut(2)
	var a := _newcomer()
	_rejoin(a, code, 0, _rj(code, 0), 9)
	print("    A queue after rejoin: ", _types(a))
	_check("opp_away" in _types(a), "returning A is told that B is away (countdown)")
	_clear(a)
	(r._rooms[code]["away_until"] as Array)[1] = Time.get_ticks_msec() - 1
	r._check_away()
	print("    A queue after B expiry: ", _types(a))
	_check(not r._rooms.has(code) and "left" in _types(a), "B expired while A back -> A gets left (B loss)")


func _v7_heal_while_away() -> void:
	print("-- V7 heal triggered while away")
	var code := _match(10)
	var room: Dictionary = r._rooms[code]
	var j := r.add_link(NetLink.new(), true)
	r._peers[j]["judge"] = true
	r._peers[j]["hello"] = true
	r._peers[j]["room"] = code
	room["judge"] = j
	_cut(2)
	r._judge_mismatch(code, room, 1, 120)
	var busy := bool((room["heal_busy"] as Array)[1])
	var nid := _newcomer()
	_rejoin(nid, code, 1, _rj(code, 1), 5)
	print("    heal_busy while away: ", busy, "  after rejoin: ", (room["heal_busy"] as Array)[1],
		"  new channel queue: ", _types(nid))
	_check(not busy or not bool((room["heal_busy"] as Array)[1]) or "desync" in _types(nid),
		"heal requested while away is cancelled on return or announced to the new channel")


func _v8_same_rid_no_limit() -> void:
	print("-- V8 same rid repeated")
	var code := _match(10)
	var n := 0
	for i in 20:
		var a := _newcomer()
		_rejoin(a, code, 1, _rj(code, 1), -1, "same")
		if not _find(a, "rejoined").is_empty():
			n += 1
	print("    20 rejoins with same rid and have=-1 accepted: ", n)
	_check(true, "info only")


func _v9_stale_peer() -> void:
	print("-- V9 stale peer packet after drop")
	var code := _match(10)
	var stale := _newcomer()
	r._drop(stale, "test")
	_check(not r._peers.has(stale), "stale peer removed before queued packets")
	r._handle(stale, {"t": "rejoin", "code": code, "side": 1,
		"rj": "f".repeat(32), "have": 5, "rid": "stale"}, "")
	r._handle(-1, {"t": "hello"}, "")
	_clear(1)
	r._handle(1, {"t": "ping"}, "")
	_check(not r._peers.has(stale) and r._rooms.has(code)
		and (r._rooms[code]["peers"] as Array) == [1, 2]
		and r._peers.has(1) and r._peers.has(2) and not _find(1, "pong").is_empty(),
		"stale and invalid ids ignored; valid peer and room remain usable")


func _v10_live_rejoin_budget() -> void:
	print("-- V10 live-channel rejoin budget")
	var code := _match(10)
	var room: Dictionary = r._rooms[code]
	(room["away_total"] as Array)[1] = NetRelayCore.AWAY_TOTAL_MAX_MS - NetRelayCore.VOID_SHIELD_MS
	var a := _newcomer()
	_rejoin(a, code, 1, _rj(code, 1), 9, "first")
	_check(not _find(a, "rejoined").is_empty()
		and int((room["away_total"] as Array)[1]) == NetRelayCore.AWAY_TOTAL_MAX_MS,
		"one honest live replacement uses remaining shield budget")
	(room["bind_at"] as Array)[1] = Time.get_ticks_msec() - NetRelayCore.REJOIN_GAP_MS - 1
	var gen := int((room["gen"] as Array)[1])
	var bind_at := int((room["bind_at"] as Array)[1])
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), 9, "second")
	var c := _newcomer()
	_rejoin(c, code, 1, _rj(code, 1), 9, "first")
	_check(String(_find(b, "rejoin_denied").get("why", "")) == "budget"
		and String(_find(c, "rejoin_denied").get("why", "")) == "budget"
		and int((room["peers"] as Array)[1]) == a and int((room["gen"] as Array)[1]) == gen
		and int((room["bind_at"] as Array)[1]) == bind_at,
		"new-rid churn and same-rid replay denied; peer/gen/shield clock unchanged")
	room["go_ms"] = Time.get_ticks_msec() - 10000
	_turns(1, 10, 160)
	(room["bind_at"] as Array)[1] = Time.get_ticks_msec() - NetRelayCore.VOID_SHIELD_MS - 1
	_clear(1)
	r._handle(1, {"t": "void"}, "")
	_check(not r._rooms.has(code) and r._ended.has(code)
		and int(r._ended[code]["leaver"]) == -1 and r._peers.has(1),
		"after shield expires, honest opponent can void a stalled live side")
