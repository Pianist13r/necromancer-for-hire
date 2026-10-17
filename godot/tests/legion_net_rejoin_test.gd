extends SceneTree
##
## Переподключение в идущий матч (docs/pvp/NET_LOCKSTEP.md, «Переподключение»; ветка
## slow/net-rejoin, 10.10.2026) — ядро ретранслятора NetRelayCore без сокетов и судей.
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60 \
##       --script res://tests/legion_net_rejoin_test.gd -- --mute
##
## Игроки — базовые NetLink (CLOSED: отправка не проходит, служебное копится в outq, его и читаем)
## или пары NetLinkPipe там, где важен настоящий приём пачкой (предел частоты). Запуск судьи
## подменён крючком. Проверки — по дизайну §7.1 и рецензии 10.10 (решения координатора):
##  1) обрыв (сокет закрыт) → отсрочка: комната жива, сопернику opp_away, не left;
##  2) верный rj → канал заменён, ходы соперника с have+1, сопернику opp_back, rejoined.next;
##  3) неверный rj / чужая сторона / кривой have → отказ, комната не тронута;
##  4) повтор при живом прежнем канале: другой rid раньше 2 с — busy; позже — вытеснение; старый
##     _drop после замены комнату не трогает;
##  5) потерянный rejoined: повтор с тем же rid сразу — тот же ответ, без busy;
##  6) срок вышел → left сопернику; 7) бюджет отсутствия исчерпан → сразу left;
##  8) выкидывание за нарушение → сразу left; 9) leave → сразу;
##  10) обрыв у обоих: оба вернулись — матч идёт; срок вышел у обоих — закрыта без итога;
##  11) void в отсрочке → void_denied {away}, запрос не потрачен;
##  12) подтяжка: обрыв до первого куска / посреди / после последнего и до healed — отменена без
##      траты HEAL_MAX, следующее расхождение — снимок с новым номером;
##  13) heal_busy снимается таймером без новых отпечатков; 14) итог судьи — в rejoined.verdict;
##  15) старый клиент (без caps): rj нет, обрыв — сразу left; 16) закончившему бой отсрочки нет;
##  17) хвост ходов вернувшейся стороны пачкой (300 за кадр) не выкидывает «слишком часто», а у
##      обычной стороны такая пачка — выкидывает (предел частоты жив);
##  18) повторы с одним rid: чаще 2 с — busy; принятый повтор окно досылки не продлевает;
##  19) возврат после закрытия комнаты — итог (ended / opp_left | void); 20) бюджет перемоток.
## Итог «LEGION NET REJOIN: N/M OK», код выхода 1 при провале.
##

const MAP := "pvp:duel"

var r: NetRelayCore
var _fails := 0
var _checks := 0
var _logs: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return false


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	_t_drop_grace()
	_t_rejoin_ok()
	_t_rejoin_bad()
	_t_displace()
	_t_lost_reply()
	_t_expire()
	_t_budget()
	_t_violation()
	_t_leave()
	_t_both_away()
	_t_void()
	_t_heal_cut()
	_t_heal_timer()
	_t_verdict()
	_t_old_client()
	_t_ended()
	if not "--skip-burst" in OS.get_cmdline_user_args():
		_t_burst()
	_t_same_rid_flood()
	_t_ended_outcome()
	_t_rewind_budget()
	r = null
	print("LEGION NET REJOIN: %d/%d OK" % [_checks - _fails, _checks])
	# выход — после пары кадров: освобождение ядер и каналов не совпадает с остановкой движка
	await process_frame
	await process_frame
	quit(1 if _fails > 0 else 0)


# ── Оснастка ────────────────────────────────────────────────────────────────

func _noop_judge(_code: String) -> void:
	pass


## Ядро и начатый бой двух игроков (id 1 — сторона 0, id 2 — сторона 1); caps — у кого «rejoin».
## Возвращает код комнаты.
func _match(caps := [true, true], turns := 10) -> String:
	r = NetRelayCore.new()
	r.dbg_spawn_judge = _noop_judge
	for i in 2:
		var id := r.add_link(NetLink.new(), false)
		r._handle(id, {"t": "hello", "v": NetRelayCore.PROTO, "build": "t", "name": "p%d" % id,
			"caps": ["rejoin"] if caps[i] else []}, "")
	r._handle(1, {"t": "create", "map": MAP}, "")
	var code := String(r._peers[1]["room"])
	r._handle(2, {"t": "join", "code": code}, "")
	r._handle(1, {"t": "ready"}, "")
	r._handle(2, {"t": "ready"}, "")
	for id: int in [1, 2]:
		for k in turns:
			var raw := JSON.stringify({"t": "in", "k": k, "c": []})
			r._handle(id, JSON.parse_string(raw), raw)
	_clear_q(1)
	_clear_q(2)
	return code


## Поля комнаты для переподключения — через get (тест писался и прогонялся на старом ядре:
## 17/46). Вызовы через get_script()/callv и чтение исходника ядра убраны 11.10: с ними процесс
## раз в ~10 прогонов падал на выходе с кодом 139.
func _a(room: Dictionary, key: String) -> Array:
	return room.get(key, [0, 0] if key != "rj" else ["", ""])


## Транспортный разрыв канала игрока — настоящим путём ядра (_poll_peer: базовый NetLink всегда
## CLOSED); выкинутому (kick) — его кик «дошёл».
func _cut(id: int) -> void:
	if not r._peers.has(id):
		return
	if r._peers[id].has("kick_at"):
		r._peers[id]["kick_at"] = 0
	r._poll_peer(id)


func _room(code: String) -> Dictionary:
	return r._rooms[code] if r._rooms.has(code) else {}


func _clear_q(id: int) -> void:
	if r._peers.has(id):
		(r._peers[id]["outq"] as Array).clear()
		r._peers[id]["outq_bytes"] = 0


## Типы служебного в очереди игрока (и сами пакеты) — по порядку.
func _q(id: int) -> Array:
	var out := []
	if not r._peers.has(id):
		return out
	for text: String in r._peers[id]["outq"]:
		var m: Variant = JSON.parse_string(text)
		out.append(m if m is Dictionary else {})
	return out


func _types(id: int) -> Array:
	var out := []
	for m: Dictionary in _q(id):
		out.append(String(m.get("t", "")))
	return out


func _find(id: int, t: String) -> Dictionary:
	for m: Dictionary in _q(id):
		if String(m.get("t", "")) == t:
			return m
	return {}


## Новый канал (id) после hello с caps — готов слать rejoin.
func _newcomer() -> int:
	var id := r.add_link(NetLink.new(), false)
	r._handle(id, {"t": "hello", "v": NetRelayCore.PROTO, "build": "t", "name": "back",
		"caps": ["rejoin"]}, "")
	_clear_q(id)
	return id


func _rejoin(id: int, code: String, s: int, rj: String, have: int, rid := "r1") -> void:
	r._handle(id, {"t": "rejoin", "code": code, "side": s, "rj": rj, "have": have, "rid": rid},
		"")


func _rj(code: String, s: int) -> String:
	return String(_a(_room(code), "rj")[s])


# ── 1–3 ─────────────────────────────────────────────────────────────────────

func _t_drop_grace() -> void:
	print("— 1) обрыв в бою → отсрочка")
	var code := _match()
	_check(_rj(code, 0).length() == 32 and _rj(code, 1).length() == 32
		and _rj(code, 0) != _rj(code, 1) and bool(_room(code).get("rejoin", false)),
		"оба умеют — у каждой стороны свой rj (32 hex)")
	_cut(2)
	var room := _room(code)
	_check(not room.is_empty() and int(_a(room, "away_until")[1]) > Time.get_ticks_msec(),
		"комната жива, сторона 1 отсутствует до срока")
	var away := _find(1, "opp_away")
	_check(not away.is_empty() and int(away.get("ms", 0)) == NetRelayCore.RECONNECT_GRACE_MS
		and not "left" in _types(1), "сопернику opp_away {ms: 45000}, не left: %s" % str(_types(1)))
	_check(int(r._peers[1]["side"]) == 0 and String(r._peers[1]["room"]) == code,
		"оставшийся по-прежнему в комнате")


func _t_rejoin_ok() -> void:
	print("— 2) верный rj → возврат")
	var code := _match()
	_cut(2)
	_clear_q(1)
	var room := _room(code)
	var nid := _newcomer()
	_rejoin(nid, code, 1, _rj(code, 1), 3)
	var rep := _find(nid, "rejoined")
	_check(int((room["peers"] as Array)[1]) == nid and String(r._peers[nid]["room"]) == code
		and int(r._peers[nid]["side"]) == 1, "сторона 1 теперь — новый канал %d" % nid)
	_check(int((room["out_k"] as Array)[0]) == 4, "ходы стороны 0 ей — с have+1 = 4 (out_k %d)"
		% int((room["out_k"] as Array)[0]))
	_check(not rep.is_empty() and int(rep.get("next", -1)) == 10 and rep.get("opp_ready") == true,
		"rejoined {next: 10, opp_ready: true}: %s" % str(rep))
	_check("opp_back" in _types(1) and int(_a(room, "away_until")[1]) == 0,
		"сопернику opp_back, отсутствия больше нет")
	_check(String(r._peers[nid].get("stats_key", "")) == "%s:1" % code,
		"сводка матча стороны 1 — от нового канала")
	# ход вернувшейся стороны принимается строго с next
	var raw := JSON.stringify({"t": "in", "k": 10, "c": []})
	r._handle(nid, JSON.parse_string(raw), raw)
	_check(r._peers.has(nid) and int((room["next_k"] as Array)[1]) == 11,
		"досылка с next принята (next_k стороны 1 = 11)")


func _t_rejoin_bad() -> void:
	print("— 3) неверные возвраты не трогают комнату")
	var code := _match()
	_cut(2)
	var room := _room(code)
	var until := int(_a(room, "away_until")[1])
	var cases := [["чужой rj", 1, "0".repeat(32), 3, "token"],
		["rj другой стороны", 1, _rj(code, 0), 3, "token"],
		["сторона 0 (на месте) со своим rj… но чужая сторона", 0, _rj(code, 1), 3, "token"],
		["have за пределами ходов соперника", 1, _rj(code, 1), 10, "state"],
		["have < -1", 1, _rj(code, 1), -5, "state"]]
	for c: Array in cases:
		var nid := _newcomer()
		_rejoin(nid, code, int(c[1]), String(c[2]), int(c[3]))
		var den := _find(nid, "rejoin_denied")
		_check(String(den.get("why", "")) == String(c[4]) and r._peers[nid].has("kick_at")
			and int((room["peers"] as Array)[1]) == 2 and int((room["peers"] as Array)[0]) == 1
			and int(_a(room, "away_until")[1]) == until and String(r._peers[nid]["room"]) == "",
			"%s → отказ «%s», комната не тронута" % [c[0], c[4]])
	var nid2 := _newcomer()
	_rejoin(nid2, "ZZZZ", 1, _rj(code, 1), 3)
	_check(String(_find(nid2, "rejoin_denied").get("why", "")) == "no_room", "нет комнаты → no_room")




# ── 4–5 ─────────────────────────────────────────────────────────────────────

func _t_displace() -> void:
	print("— 4) повтор при живом прежнем канале")
	var code := _match()
	var room := _room(code)
	var a := _newcomer()
	_rejoin(a, code, 1, _rj(code, 1), 5, "A")
	_check(int((room["peers"] as Array)[1]) == a and r._peers[2].has("kick_at")
		and String(r._peers[2]["room"]) == "", "полумёртвый канал 2 вытеснен (выкинут, без комнаты)")
	_check(not "left" in _types(1), "сопернику не left")
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), 5, "B")
	_check(String(_find(b, "rejoin_denied").get("why", "")) == "busy"
		and int((room["peers"] as Array)[1]) == a, "другой rid раньше 2 с — busy, канал прежний")
	_a(room, "bind_at")[1] = Time.get_ticks_msec() - NetRelayCore.REJOIN_GAP_MS - 1
	var c := _newcomer()
	_rejoin(c, code, 1, _rj(code, 1), 5, "C")
	_check(int((room["peers"] as Array)[1]) == c and r._peers[a].has("kick_at"),
		"после 2 с — вытеснение нового канала ещё более новым")
	# старый канал 2 закрывается по-настоящему (кик дошёл): его _drop не трогает комнату; канал a
	# — хуже: будто он всё ещё числит себя в комнате (сторона 1) и закрылся сам — тоже мимо, он
	# не актуальный (id/поколение)
	_cut(2)
	if r._peers.has(a):
		r._peers[a].erase("kick_at")
		r._peers[a]["room"] = code
		r._peers[a]["side"] = 1
	_cut(a)
	_check(r._rooms.has(code) and int((room["peers"] as Array)[1]) == c
		and int(_a(room, "away_until")[1]) == 0 and not "left" in _types(1)
		and not "opp_away" in _types(1), "запоздалый _drop вытесненных каналов комнату не трогает")
	# канал с актуальным id, но чужим поколением — тоже не актуальный
	if r._peers.has(c):
		r._peers[c]["gen"] = 0
		_check(not r._is_current(room, c, r._peers[c]),
			"id тот же, поколение старое — не актуальный")
		r._peers[c]["gen"] = int(_a(room, "gen")[1])
	else:
		_check(false, "id тот же, поколение старое — не актуальный (канала нет)")


func _t_lost_reply() -> void:
	print("— 5) потерянный rejoined: повтор с тем же rid")
	var code := _match()
	_cut(2)
	var room := _room(code)
	var a := _newcomer()
	_rejoin(a, code, 1, _rj(code, 1), 4, "same")
	# ответ потерян (канал a умер для клиента, но сервер его ещё считает живым) — клиент повторяет
	# (не раньше чем через 2 с — с тем же rid чаще нельзя, см. проверку 18)
	_a(room, "bind_at")[1] = Time.get_ticks_msec() - NetRelayCore.REJOIN_SAME_GAP_MS - 100
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), 4, "same")
	var rep := _find(b, "rejoined")
	_check(not rep.is_empty() and int(rep.get("next", -1)) == 10
		and int((room["peers"] as Array)[1]) == b, "тот же rid через 2,1 с — снова rejoined, без busy")
	_check(int((room["out_k"] as Array)[0]) == 5, "ходы соперника снова с have+1")


## 18) Рецензия 10.10: повторы с одним rid не обходят интервал бесконечно и не продлевают окно
## досылки без предела частоты.
func _t_same_rid_flood() -> void:
	print("— 18) поток повторов с одним rid")
	var code := _match()
	var room := _room(code)
	var a := _newcomer()
	_rejoin(a, code, 1, _rj(code, 1), 4, "R")
	var busy := 0
	for i in 20:
		# «за миг» — по часам ядра: привязка будто только что (иначе под нагрузкой машины 20 попыток
		# растягивались за 2 с, и последняя законно проходила)
		_a(room, "bind_at")[1] = Time.get_ticks_msec()
		var x := _newcomer()
		_rejoin(x, code, 1, _rj(code, 1), 4, "R")
		busy += int(String(_find(x, "rejoin_denied").get("why", "")) == "busy")
	_check(busy == 20 and int((room["peers"] as Array)[1]) == a,
		"20 повторов тем же rid за миг — все busy (%d), сторона за первым каналом" % busy)
	var fk: Variant = r._peers[a].get("free_k") if r._peers.has(a) else null
	var fu: Variant = r._peers[a].get("free_until") if r._peers.has(a) else null
	_a(room, "bind_at")[1] = Time.get_ticks_msec() - NetRelayCore.REJOIN_SAME_GAP_MS - 100
	OS.delay_msec(20)
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), 4, "R")
	_check(int((room["peers"] as Array)[1]) == b and fk != null
		and r._peers[b].get("free_k") == fk and r._peers[b].get("free_until") == fu,
		"повтор тем же rid через 2,1 с принят, окно досылки — прежнее, не продлено (%s/%s)"
		% [str(r._peers[b].get("free_until")), str(fu)])
	r._peers[b].erase("free_k")   # окно кончилось
	_a(room, "bind_at")[1] = Time.get_ticks_msec() - NetRelayCore.REJOIN_SAME_GAP_MS - 100
	var c := _newcomer()
	_rejoin(c, code, 1, _rj(code, 1), 4, "R")
	_check(int((room["peers"] as Array)[1]) == c and not r._peers[c].has("free_k"),
		"окно кончилось — повтор тем же rid нового окна не даёт")


## 19) verifier 11.10: вернувшийся после закрытия комнаты узнаёт итог (ушёл соперник — победа;
## обрыв у обоих — без итога), а не «вернуться не удалось»; чужой rj итога не узнаёт.
func _t_ended_outcome() -> void:
	print("— 19) возврат после закрытия комнаты")
	var code := _match()
	_cut(2)
	r._handle(1, {"t": "leave"}, "")
	_check(not r._rooms.has(code), "соперник ушёл, пока сторона 1 без связи, — комната закрыта")
	var a := _newcomer()
	_rejoin(a, code, 1, _rj_of_ended(code, 1), 3)
	var d := _find(a, "rejoin_denied")
	_check(String(d.get("why", "")) == "ended" and String(d.get("outcome", "")) == "opp_left",
		"возврат: ended / opp_left (победа): %s" % str(d))
	var x := _newcomer()
	_rejoin(x, code, 1, "0".repeat(32), 3)
	_check(String(_find(x, "rejoin_denied").get("why", "")) == "no_room",
		"чужой rj — просто no_room, итога не узнаёт")
	var code2 := _match()
	_cut(1)
	_cut(2)
	_a(_room(code2), "away_until")[0] = Time.get_ticks_msec() - 1
	r._check_away()
	var b := _newcomer()
	_rejoin(b, code2, 1, _rj_of_ended(code2, 1), 3)
	_check(String(_find(b, "rejoin_denied").get("outcome", "")) == "void",
		"обрыв у обоих, срок вышел — возврат: ended / void")


func _rj_of_ended(code: String, s: int) -> String:
	var e: Dictionary = r._ended.get(code, {})
	return String((e.get("rj", ["", ""]) as Array)[s])


## 20) verifier 11.10: перемотки истории соперника на возвратах ограничены за матч.
func _t_rewind_budget() -> void:
	print("— 20) бюджет перемоток истории")
	var code := _match()
	var room := _room(code)
	(room["out_k"] as Array)[0] = 10
	_a(room, "rewound")[1] = NetRelayCore.REWIND_TURNS_MAX - 5
	var a := _newcomer()
	_rejoin(a, code, 1, _rj(code, 1), -1)
	_check(String(_find(a, "rejoin_denied").get("why", "")) == "budget"
		and int((room["peers"] as Array)[1]) == 2, "have=-1 сверх бюджета перемоток — отказ budget")
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), 7)
	_check(not _find(b, "rejoined").is_empty() and int(_a(room, "rewound")[1])
		== NetRelayCore.REWIND_TURNS_MAX - 3, "перемотка на 2 хода — в пределах, учтена")


# ── 6–9 ─────────────────────────────────────────────────────────────────────

func _t_expire() -> void:
	print("— 6) срок отсрочки вышел")
	var code := _match()
	_cut(2)
	_a(_room(code), "away_until")[1] = Time.get_ticks_msec() - 1
	r._check_away()
	_check(not r._rooms.has(code) and "left" in _types(1) and String(r._peers[1]["room"]) == "",
		"комната закрыта, оставшемуся left (уход отсутствующего): %s" % str(_types(1)))


func _t_budget() -> void:
	print("— 7) бюджет отсутствия за матч исчерпан")
	var code := _match()
	_a(_room(code), "away_total")[1] = NetRelayCore.AWAY_TOTAL_MAX_MS
	_cut(2)
	_check(not r._rooms.has(code) and "left" in _types(1) and not "opp_away" in _types(1),
		"90 с вне связи уже были — обрыв сразу уход")
	var code2 := _match()
	_a(_room(code2), "away_total")[1] = NetRelayCore.AWAY_TOTAL_MAX_MS - 10000
	_cut(2)
	_check(int(_find(1, "opp_away").get("ms", 0)) == 10000, "остаток бюджета 10 с — отсрочка 10 с")


func _t_violation() -> void:
	print("— 8) выкидывание за нарушение — без отсрочки")
	var code := _match()
	var raw := JSON.stringify({"t": "in", "k": 99, "c": []})
	r._handle(2, JSON.parse_string(raw), raw)   # ход вне очереди
	_check(not r._peers.has(2) and not r._rooms.has(code) and "left" in _types(1),
		"«ход вне очереди» — сразу уход, как прежде")


func _t_leave() -> void:
	print("— 9) leave — сразу")
	var code := _match()
	r._handle(2, {"t": "leave"}, "")
	_check(not r._rooms.has(code) and "left" in _types(1), "явный выход — сразу уход")


# ── 10–11 ───────────────────────────────────────────────────────────────────

func _t_both_away() -> void:
	print("— 10) обрыв у обоих")
	var code := _match()
	var room := _room(code)
	_cut(1)
	_cut(2)
	_check(r._rooms.has(code) and int(_a(room, "away_until")[0]) > 0
		and int(_a(room, "away_until")[1]) > 0, "обе стороны отсутствуют, комната жива")
	var a := _newcomer()
	_rejoin(a, code, 0, _rj(code, 0), 9)
	var b := _newcomer()
	_rejoin(b, code, 1, _rj(code, 1), 9)
	_check(int((room["peers"] as Array)[0]) == a and int((room["peers"] as Array)[1]) == b
		and not _find(a, "rejoined").is_empty() and not _find(b, "rejoined").is_empty(),
		"обе вернулись — матч продолжается")
	var code2 := _match()
	_cut(1)
	_cut(2)
	_a(_room(code2), "away_until")[0] = Time.get_ticks_msec() - 1
	r._check_away()
	_check(not r._rooms.has(code2) and (r._stats_wait as Dictionary).has("%s:0" % code2),
		"срок вышел, соперник тоже не на связи — закрыта без итога (никому не left)")


func _t_void() -> void:
	print("— 11) void в отсрочке")
	var code := _match()
	_cut(2)
	r._handle(1, {"t": "void"}, "")
	var den := _find(1, "void_denied")
	_check(r._rooms.has(code) and den.get("away") == true, "отклонено с away: %s" % str(den))
	_check(not r._peers[1].has("req_at"), "запрос не потрачен (повтор не ждёт 25 с)")


# ── 12–14 ───────────────────────────────────────────────────────────────────

func _heal_start(code: String, s: int) -> void:
	var room := _room(code)
	# судья «жив» — пир судьи-заглушки в комнате
	var j := r.add_link(NetLink.new(), true)
	r._peers[j]["judge"] = true
	r._peers[j]["hello"] = true
	r._peers[j]["room"] = code
	room["judge"] = j
	r._judge_mismatch(code, room, s, 120)


func _t_heal_cut() -> void:
	print("— 12) обрыв посреди подтяжки")
	for phase in ["до первого куска", "посреди", "после последнего, до healed"]:
		var code := _match()
		var room := _room(code)
		_heal_start(code, 1)
		_check(bool((room["heal_busy"] as Array)[1]) and int((room["heal"] as Array)[1]) == 1,
			"%s: подтяжка 1 запрошена" % phase)
		if phase != "до первого куска":
			r._judge_snap(code, room, {"s": 1, "id": 1, "k": 100, "i": 0, "n": 2, "d": "AAAA"})
			(room["snap"] as Array)[1]["out"] = 1
		if phase == "после последнего, до healed":
			r._judge_snap(code, room, {"s": 1, "id": 1, "k": 100, "i": 1, "n": 2, "d": "BBBB"})
			(room["snap"] as Array)[1] = {}
			(room["heal_sent"] as Array)[1] = true
		_cut(2)
		_check(not bool((room["heal_busy"] as Array)[1])
			and ((room["snap"] as Array)[1] as Dictionary).is_empty()
			and int((room["heal"] as Array)[1]) == 0, "%s: подтяжка отменена, HEAL_MAX не потрачен"
			% phase)
		var nid := _newcomer()
		_rejoin(nid, code, 1, _rj(code, 1), 3)
		r._judge_mismatch(code, room, 1, 180)
		_check(bool((room["heal_busy"] as Array)[1]) and int((room["heal_id"] as Array)[1]) == 2
			and "desync" in _types(nid), "%s: после возврата — снимок с новым номером 2" % phase)


func _t_heal_timer() -> void:
	print("— 13) heal_busy — по таймеру")
	var code := _match()
	var room := _room(code)
	_heal_start(code, 0)
	_clear_q(1)
	(room["heal_at"] as Array)[0] = Time.get_ticks_msec() - NetRelayCore.HEAL_WAIT_MS - 1
	r._check_heals()
	var d := _find(1, "desync")
	_check(not bool((room["heal_busy"] as Array)[0]) and d.get("judge") == true
		and not d.has("heal"), "без новых отпечатков: снято, стороне — обычное расхождение")


func _t_verdict() -> void:
	print("— 14) итог судьи отсутствовавшему")
	var code := _match()
	var room := _room(code)
	_heal_start(code, 0)   # (нужен лишь пир судьи)
	_cut(2)
	var raw := JSON.stringify({"t": "verdict", "why": "end", "winner": 0, "tick": 300})
	r._judge_msg(int(room["judge"]), "verdict", raw)
	var nid := _newcomer()
	_rejoin(nid, code, 1, _rj(code, 1), 3)
	var v: Variant = _find(nid, "rejoined").get("verdict")
	_check(v is Dictionary and int((v as Dictionary).get("winner", -1)) == 0,
		"rejoined.verdict — итог судьи: %s" % str(v))


# ── 15–16 ───────────────────────────────────────────────────────────────────

func _t_old_client() -> void:
	print("— 15) старый клиент (без caps)")
	var code := _match([true, false])
	var start: Dictionary = {}
	_check(not bool(_room(code).get("rejoin", false)) and _rj(code, 0) == "",
		"один без caps — rj нет никому")
	_cut(2)
	_check(not r._rooms.has(code) and "left" in _types(1), "обрыв — сразу уход, как прежде")
	start = {}
	# start без rj (пакет перехватываем через очередь нового матча)
	r = NetRelayCore.new()
	r.dbg_spawn_judge = _noop_judge
	for i in 2:
		var id := r.add_link(NetLink.new(), false)
		r._handle(id, {"t": "hello", "v": NetRelayCore.PROTO, "build": "t", "name": "o%d" % id}, "")
	r._handle(1, {"t": "create", "map": MAP}, "")
	r._handle(2, {"t": "join", "code": String(r._peers[1]["room"])}, "")
	start = _find(2, "start")
	_check(not start.is_empty() and not start.has("rj"), "в start старым клиентам rj нет")


func _t_ended() -> void:
	print("— 16) закончившему бой отсрочки нет")
	var code := _match()
	r._handle(2, {"t": "end"}, "")
	_cut(2)
	_check(not r._rooms.has(code) and "left" in _types(1), "end, потом обрыв — уход")


# ── 17) Хвост пачкой ────────────────────────────────────────────────────────

## Пары каналов: настоящий приём пачкой (предел частоты считается по чтению сервером).
func _t_burst() -> void:
	print("— 17) хвост ходов пачкой")
	# часы боя (ход не раньше времени) считаются от настоящего старта процесса: 300 ходов
	# разрешены, когда с «go» прошло ≥ 13 с — go ставим на 15 с назад, а он не может быть ≤ 0
	while Time.get_ticks_msec() < 16000:
		OS.delay_msec(100)
	for rejoined in [true, false]:
		r = NetRelayCore.new()
		r.dbg_spawn_judge = _noop_judge
		var ends: Array = []
		for i in 2:
			var pair := NetLinkPipe.pair()
			r.add_link(pair[1], false)
			ends.append(pair[0])
			(pair[0] as NetLinkPipe).send_text(JSON.stringify({"t": "hello", "v": NetRelayCore.PROTO,
				"build": "t", "name": "b%d" % i, "caps": ["rejoin"]}))
		r.process()
		(ends[0] as NetLinkPipe).send_text(JSON.stringify({"t": "create", "map": MAP}))
		r.process()
		var code := String(r._peers[1]["room"])
		(ends[1] as NetLinkPipe).send_text(JSON.stringify({"t": "join", "code": code}))
		r.process()
		for e: NetLinkPipe in ends:
			e.send_text(JSON.stringify({"t": "ready"}))
		r.process()
		var room := _room(code)
		room["go_ms"] = Time.get_ticks_msec() - 15000   # часы боя позволяют 300 + 52 хода
		var guest: NetLinkPipe = ends[1]
		var sender := 2
		if rejoined:
			guest.close(1006, "обрыв")
			r.process()
			var pair := NetLinkPipe.pair()
			sender = r.add_link(pair[1], false)
			guest = pair[0]
			guest.send_text(JSON.stringify({"t": "hello", "v": NetRelayCore.PROTO, "build": "t",
				"name": "b1", "caps": ["rejoin"]}))
			r.process()
			guest.send_text(JSON.stringify({"t": "rejoin", "code": code, "side": 1,
				"rj": _rj(code, 1), "have": -1, "rid": "x"}))
			r.process()
		for k in 300:
			guest.send_text(JSON.stringify({"t": "in", "k": k, "c": []}))
		r.process()
		var got := int((room["next_k"] as Array)[1]) if not room.is_empty() else -1
		if rejoined:
			_check(r._peers.has(sender) and got == 300,
				"вернувшаяся сторона: 300 ходов одной пачкой приняты (next_k %d)" % got)
			# после хвоста предел частоты снова действует
			for k in range(300, 300 + NetRelayCore.MAX_MSGS_PER_SEC + 5):
				guest.send_text(JSON.stringify({"t": "ping", "ms": k}))
			r.process()
			_check(not r._peers.has(sender), "прочие пакеты вернувшейся стороны — под пределом частоты")
		else:
			_check(not r._peers.has(sender), "обычная сторона: та же пачка — «слишком часто»")
		for e: NetLinkPipe in ends:
			e.close(1000, "конец")
		guest.close(1000, "конец")
		r.process()
		# каналы-пары держат друг друга и ядро через словари пиров: рвём всё явно до выхода (код 139
		# на выходе процесса при живых парах NetLinkPipe — legion_net_steam_test, 08.10)
		r._peers.clear()
		r._rooms.clear()
		ends.clear()
		guest = null
		r = null
