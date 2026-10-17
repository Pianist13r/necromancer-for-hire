extends SceneTree
##
## Переподключение в идущий матч — клиенты целиком (docs/pvp/NET_LOCKSTEP.md, «Переподключение»;
## ветка slow/net-rejoin, 10.10.2026): ядро ретранслятора и две NetSession в одном процессе через
## NetLinkPipe (как legion_net_steam_test), настоящие миры, PvpBot по тикам, задержка ввода
## постоянная (dbg_fixed_delay), сид комнаты задан.
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60 \
##       --script res://tests/legion_net_rejoin_det_test.gd -- --mute
##
## Прогоны по TICKS тиков (мир шагает не больше тика за кадр — бот думает ровно по тикам, и бой не
## зависит от того, как кадры легли на сеть):
##  ref  — без обрыва: отпечатки каждого 60-го тика (эталон);
##  cut  — на тике CUT_AT канал гостя закрыт, CUT_MS попытки не проходят, потом возврат: отпечатки
##         равны эталону, у хозяина был «Соперник переподключается…» и не было ухода соперника;
##  udp  — «WebSocket гостя умер, UDP жив»: копии ходов гостя на сервер придержаны, хозяину они идут
##         «напрямую» (тест передаёт их сам), хозяин уходит вперёд до RELAY_LAG_MAX и встаёт; потом
##         обрыв и возврат — хвост ~200 ходов досылается без «вне очереди» и «слишком часто»;
##  lost — ответ «rejoined» первой удачной попытки теряется (сервер его «отправил»): клиент ждёт,
##         повторяет тем же rid и возвращается;
##  old  — гость без caps (старый клиент; для клиента то же, что старый сервер: в start нет rj):
##         обрыв — прежний путь, гость в лобби, хозяину — уход соперника.
## Итог «LEGION NET REJOIN DET: N/M OK», код выхода 1 при провале.
##

const SAVE := "user://legion_net_rejoin_det_test.cfg"
const MAP := "pvp:duel"
const TICKS := 1200
const CUT_AT := 600
const CUT_MS := 3000
const SEED := 4242
const DELAY := 4
const FRAMES_MAX := 9000

var core: NetRelayCore
var _fails := 0
var _checks := 0
## Канал гостя сейчас и до какого времени попытки «не проходят» (сеть ещё лежит).
var _guest_end: NetLinkPipe
var _down_until := 0
## Прогон lost: потерять ближайший «rejoined».
var _drop_rejoined := false
var _dropped := 0
## --only a,b — только эти прогоны (эталон ref — если нужен им для сравнения).
var _only: PackedStringArray = []


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _want(name: String) -> bool:
	return _only.is_empty() or name in _only


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == "--only":
			_only = args[i + 1].split(",")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var ref := {}
	if _want("ref") or _want("cut") or _want("udp") or _want("lost") or _want("refuse") \
			or _want("stall") or _want("refuse_play"):
		ref = await _match("ref", {})
		_check(ref["ticks"] == [TICKS, TICKS] and ref["digests"][0] == ref["digests"][1]
			and (ref["digests"][0] as Dictionary).size() == TICKS / 60,
			"эталон: оба мира дошли до %d, отпечатки сторон совпали (%d точек)" % [TICKS,
			(ref["digests"][0] as Dictionary).size()])
	if _want("cut"):
		var cut := await _match("cut", {"cut_at": CUT_AT})
		_same(ref, cut, "cut")
		_check(cut["rejoins"] == 1 and cut["opp_away_seen"] and not cut["remote_left"]
			and cut["aborted"].is_empty(), "cut: один возврат, у хозяина отсчёт, ухода нет: %s"
			% str(cut["aborted"]))
		_check(int(cut["away_ms"]) >= CUT_MS and int(cut["away_ms"]) < CUT_MS + 8000,
			"cut: вне связи %d мс (обрыв %d мс + попытки)" % [cut["away_ms"], CUT_MS])
	if _want("udp"):
		var udp := await _match("udp", {"hold_from": 60})
		_same(ref, udp, "udp")
		_check(udp["rejoins"] == 1 and not udp["remote_left"] and udp["aborted"].is_empty()
			and int(udp["resend"]) >= 150, "udp: хвост %d своих ходов дослан, ухода нет"
			% udp["resend"])
		_check(int(udp["host_max_hold"]) > 0, "udp: хозяин стоял на придержке (копий на сервере нет)")
	if _want("lost"):
		var lost := await _match("lost", {"cut_at": CUT_AT, "lose_reply": true})
		_same(ref, lost, "lost")
		_check(_dropped == 1 and lost["rejoins"] == 1 and int(lost["tries"]) >= 2
			and lost["aborted"].is_empty(),
			"lost: ответ потерян (%d), повтор тем же rid вернул (попыток %d)" % [_dropped,
			lost["tries"]])
	if _want("old"):
		var old := await _match("old", {"cut_at": CUT_AT, "no_caps": true})
		_check(old["rejoins"] == 0 and old["remote_left"] and old["guest_aborted"]
			and old["no_rj"], "old: без caps — rj нет, обрыв ведёт гостя в лобби, хозяину уход: %s"
			% str(old["aborted"]))
	# рецензия 10.10 (п. 2): канал отказывает в отправке посреди хвоста — ход не теряется (курсор
	# стоит, пачка прерывается), сервер не видит «вне очереди»; отказывает всё время — через
	# RESYNC_STALL_MS это обрыв, и возврат заново
	if _want("refuse"):
		var rf := await _match("refuse", {"hold_from": 60, "trigger": "resync", "action": "refuse",
			"refuse": 3})
		_same(ref, rf, "refuse")
		_check(rf["rejoins"] == 1 and not rf["remote_left"] and rf["aborted"].is_empty(),
			"refuse: 3 отказа канала посреди хвоста — ни одного пропуска, ухода нет: %s"
			% str(rf["aborted"]))
	if _want("stall"):
		var st := await _match("stall", {"hold_from": 60, "trigger": "resync", "action": "refuse",
			"refuse": 1000000})
		_same(ref, st, "stall")
		_check(st["rejoins"] == 2 and not st["remote_left"] and st["aborted"].is_empty(),
			"stall: канал отказывает всё время — без хода досылки это обрыв, второй возврат (%d), "
			% st["rejoins"] + "ухода нет: %s" % str(st["aborted"]))
	# то же в обычном бою, без всякого обрыва: канал не взял ход — досылка по порядку, а не пропуск
	if _want("refuse_play"):
		var rp := await _match("refuse_play", {"trigger": "tick", "at": 300, "action": "refuse",
			"refuse": 3})
		_same(ref, rp, "refuse_play")
		_check(rp["rejoins"] == 0 and not rp["remote_left"] and rp["aborted"].is_empty(),
			"refuse_play: 3 отказа канала в бою — ход не пропал, ухода нет: %s" % str(rp["aborted"]))
	await _terminal_runs()
	await _forge_run()
	core = null
	print("LEGION NET REJOIN DET: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Рецензия 10.10 (п. 3): подменённый UDP-ход, полученный до обрыва, сверяется с серверной копией,
## пришедшей ПОСЛЕ возврата (живого UDP уже нет), — подлог доказан, как без обрыва.
func _forge_run() -> void:
	if not _want("forge"):
		return
	var f := await _match("forge", {"forge": true})
	_check(f["forged_k"] >= 0 and f["mismatch"] == f["forged_k"] and f["forge"] == [0, 0]
		and f["guest_result"] == "win" and f["rejoins"] == 1,
		"forge: подмена хода %d хозяином доказана после возврата гостя (несовпадение %d, " % [
		f["forged_k"], f["mismatch"]] + "вердикт %s, итог гостя %s, возвратов %d)" % [
		str(f["forge"]), f["guest_result"], f["rejoins"]])


## Рецензия 10.10 (п. 1): конец матча, пришедший в RESYNC или сразу после «rejoined» до первого
## кадра досылки, обрабатывается, как в бою: «left» — уход соперника (победа), «overload» — отмена
## без итога. Прежде флаг ставился, а сдача — нет: бой стоял навсегда.
func _terminal_runs() -> void:
	if _want("left_resync"):
		var a := await _match("left_resync", {"hold_from": 60, "trigger": "resync",
			"action": "host_leave"})
		_check(a["guest_remote_left"] and a["guest_phase"] != LegionWorld.Phase.BATTLE
			and a["guest_result"] == "win" and not a["guest_aborted"],
			"left_resync: соперник ушёл во время досылки — у вернувшегося бой кончен, победа "
			+ "(фаза %d, итог %s, %s)" % [a["guest_phase"], a["guest_result"], str(a["aborted"])])
	if _want("left_bind"):
		var b := await _match("left_bind", {"cut_at": CUT_AT, "trigger": "bind",
			"action": "host_leave"})
		_check(b["guest_remote_left"] and b["guest_phase"] != LegionWorld.Phase.BATTLE
			and b["guest_result"] == "win" and not b["guest_aborted"],
			"left_bind: left сразу за rejoined (до кадра досылки) — бой кончен, победа "
			+ "(фаза %d, итог %s, %s)" % [b["guest_phase"], b["guest_result"], str(b["aborted"])])
	if _want("left_away"):
		# verifier 11.10 (г): соперник ушёл, пока гость без связи, — комната закрыта; гость,
		# вернувшись, узнаёт итог (rejoin_denied ended/opp_left) и получает победу, а не «не удалось»
		var e := await _match("left_away", {"cut_at": CUT_AT, "trigger": "away",
			"action": "host_leave"})
		_check(e["outage_elapsed"] and e["tries"] > 0,
			"left_away: simulated outage ended and rejoin was attempted")
		_check(e["guest_remote_left"] and e["guest_phase"] != LegionWorld.Phase.BATTLE
			and e["guest_result"] == "win" and not e["guest_aborted"],
			"left_away: соперник ушёл в отсутствие гостя — по возвращении победа "
			+ "(фаза %d, итог %s, %s)" % [e["guest_phase"], e["guest_result"], str(e["aborted"])])
	if _want("overload_resync"):
		var c := await _match("overload_resync", {"hold_from": 60, "trigger": "resync",
			"action": "overload"})
		_check(c["guest_aborted"] and str(c["aborted"]).contains("переполнен")
			and c["guest_result"] != "win",
			"overload_resync: отмена без итога во время досылки — гость в лобби без победы: %s"
			% str(c["aborted"]))


func _same(ref: Dictionary, run: Dictionary, name: String) -> void:
	_check(run["ticks"] == [TICKS, TICKS], "%s: оба мира дошли до %d (%s)" % [name, TICKS,
		str(run["ticks"])])
	var diff := []
	for s in 2:
		for t: int in (ref["digests"][s] as Dictionary):
			if String((ref["digests"][s] as Dictionary)[t]) \
					!= String((run["digests"][s] as Dictionary).get(t, "")):
				diff.append([s, t])
	_check(diff.is_empty(), "%s: отпечатки каждого 60-го тика = эталону у обеих сторон%s" % [name,
		"" if diff.is_empty() else " (расхождения: %s)" % str(diff.slice(0, 6))])
	_check(run["desync"] == [-1, -1], "%s: расхождений нет" % name)


func _noop_judge(_code: String) -> void:
	pass


## Отправка ядра: в прогоне lost первый «rejoined» «уходит» в никуда (ядро считает его
## отправленным — так теряется ответ в сети).
func _core_send(link: NetLink, text: String) -> bool:
	if _drop_rejoined and text.contains("\"t\":\"rejoined\""):
		_drop_rejoined = false
		_dropped += 1
		return true
	if link.state() != NetLink.State.OPEN:
		return false
	var buffered := link.buffered_out()
	if buffered > 0 and buffered + text.length() > NetRelayCore.PEER_BUF:
		return false
	return link.send_text(text) == OK


## Канал попытки переподключения гостя: пока «сеть лежит» — нет; потом — свежая пара в ядро.
func _guest_attempt() -> NetLink:
	if Time.get_ticks_msec() < _down_until:
		return null
	var pair := NetLinkPipe.pair()
	core.add_link(pair[1], false)
	_guest_end = pair[0]
	return _guest_end


func _no_link() -> NetLink:
	return null


func _match(name: String, opt: Dictionary) -> Dictionary:
	print("— прогон ", name)
	core = NetRelayCore.new()
	core.judge_max = 0
	core.dbg_spawn_judge = _noop_judge
	core.dbg_send = _core_send
	core._rng.seed = SEED
	_down_until = 0
	_drop_rejoined = false
	_dropped = 0
	var holder := Node.new()
	root.add_child(holder)
	# миры — до каналов: первая загрузка сцены идёт секундами, а ядро ждёт hello не дольше 10 с
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var worlds: Array[LegionWorld] = []
	var bots: Array[PvpBot] = []
	for i in 2:
		var w := scene.instantiate() as LegionWorld
		holder.add_child(w)
		worlds.append(w)
		bots.append(PvpBot.new())
	await process_frame
	var sessions: Array[NetSession] = [NetSession.new(), NetSession.new()]
	var aborted: Array = []
	for i in 2:
		var s := sessions[i]
		holder.add_child(s)
		s.dbg_fixed_delay = DELAY
		s.aborted.connect(func(t: String) -> void: aborted.append("%d: %s" % [i, t]))
		s.failed.connect(func(t: String) -> void: aborted.append("%d failed: %s" % [i, t]))
		# с фабрикой канала клиент шлёт caps «rejoin»; хозяину она не понадобится (его канал не рвём)
		if i == 0:
			s.rejoin_link = _no_link
		elif not opt.has("no_caps"):
			s.rejoin_link = _guest_attempt
		var pair := NetLinkPipe.pair()
		core.add_link(pair[1], false)
		if i == 1:
			_guest_end = pair[0]
		s.connect_link(pair[0], "det%d" % i)
	var started := [false, false]
	var rj_seen := [false, false]
	for i in 2:
		var s := sessions[i]
		var w := worlds[i]
		var bot := bots[i]
		s.match_start.connect(func(seed_value: int, map_id: String, side: int) -> void:
			w.start_net_match(map_id, seed_value, side)
			s.attach(w)
			s.stop_at_tick = 0
			rj_seen[i] = s._rejoin.token != ""
			bot.setup(w, side)
			var out: Callable = w.net_out
			bot.sink = func(cmd: Dictionary) -> void: out.call(cmd)
			started[i] = true)
	sessions[0].room_created.connect(func(code: String) -> void: sessions[1].join_room(code))
	for f in 20:
		await process_frame
		core.process()
		if sessions[0].stage == NetSession.Stage.LOBBY and sessions[1].stage == NetSession.Stage.LOBBY:
			break
	sessions[0].create_room(MAP)
	var digests := [{}, {}]
	var bot_ticks := [0, 0]
	var cut := false
	var forwarded := 0
	var opp_away_seen := false
	var host_max_hold := 0.0
	var resend := 0
	var tries := 0
	if opt.has("hold_from"):
		sessions[1].dbg_hold_from = int(opt["hold_from"])
		sessions[1].dbg_hold_ms = 600000
	if opt.has("lose_reply"):
		_drop_rejoined = true
	if opt.has("forge"):
		# хозяин — подменщик: копии его ходов на сервер придержаны, гостю они идут «напрямую»
		# (тест передаёт их сам), и одна из них подменена с верным HMAC хозяина
		sessions[0].dbg_hold_from = 60
		sessions[0].dbg_hold_ms = 600000
	var fwd_host := 0
	var t0 := -1
	var frames := 0
	var fired := -1
	var terminal_deadline_ms := 0
	var forged_k := -1
	var saw_away := false
	var code := ""
	while frames < FRAMES_MAX or (name == "left_away" and fired >= 0
			and Time.get_ticks_msec() < terminal_deadline_ms):
		frames += 1
		await process_frame
		core.process()
		if not (started[0] and started[1]):
			continue
		if code == "":
			code = sessions[0].room_code
		if t0 < 0:
			t0 = Time.get_ticks_msec()
		# темп не выше 60 тиков/с по настенным часам: ядро проверяет ходы по часам боя
		var ahead := int(float(worlds[0].net_tick) * 1000.0 / 60.0) - (Time.get_ticks_msec() - t0)
		if ahead > 0:
			OS.delay_msec(mini(ahead, 50))
		for i in 2:
			var w := worlds[i]
			var s := sessions[i]
			while bot_ticks[i] < w.net_tick:
				bot_ticks[i] += 1
				if w.phase == LegionWorld.Phase.BATTLE:
					bots[i].tick(NetSession.DT)
			if w.net_tick % 60 == 0 and w.net_tick > 0 and not (digests[i] as Dictionary).has(w.net_tick):
				digests[i][w.net_tick] = w.net_digest()
			# мир — не больше тика за кадр (бот думает строго по тикам)
			s.stop_at_tick = mini(w.net_tick + 1, TICKS)
		var host := sessions[0]
		var guest := sessions[1]
		opp_away_seen = opp_away_seen or host._rejoin.opp_away_until > 0
		host_max_hold = maxf(host_max_hold, host._hold_stall)
		if guest._rejoin.resend_k >= 0:
			resend = maxi(resend, guest._next_out - guest._rejoin.resend_k)
		tries = maxi(tries, guest._rejoin.attempt)
		# «UDP»: придержанные копии ходов гостя хозяину напрямую
		if opt.has("hold_from") and not cut:
			while forwarded < guest._hold_q.size():
				var raw := String(guest._hold_q[forwarded][1])
				host._on_remote_turn(JSON.parse_string(raw) as Dictionary, raw, "udp")
				forwarded += 1
		var cut_now := false
		if opt.has("forge") and not cut:
			# гостю — «живой UDP» (заглушка NetP2P: сверка путей включена, сокета нет)
			if guest._p2p == null and guest.stage == NetSession.Stage.PLAYING:
				guest._p2p = NetP2P.new()
			if guest._p2p != null:
				while fwd_host < host._hold_q.size():
					var raw := String(host._hold_q[fwd_host][1])
					if fwd_host == 5:
						var d: Dictionary = JSON.parse_string(raw)
						var c: Array = d["c"]
						c.append({"type": "x"})   # кодек его не примет — бой не меняется
						raw = JSON.stringify({"t": "in", "k": int(d["k"]), "c": c})
						forged_k = int(d["k"])
					guest._on_remote_turn(JSON.parse_string(raw) as Dictionary, raw, "udp",
						NetP2P.mac(host._my_key, raw))
					fwd_host += 1
			if guest._hold_stall > 1.0:
				cut_now = true
				# копии хозяина на сервер отпускаем — после возврата гость получит серверную
				for e: Array in host._hold_q:
					e[0] = 0
				host.dbg_hold_from = -1
		if opt.has("forge") and guest.forge_cheater >= 0 and fired < 0:
			fired = frames
		if opt.has("forge") and fired >= 0 and frames - fired > 120:
			break
		if opt.has("cut_at") and not cut and worlds[1].net_tick >= int(opt["cut_at"]):
			cut_now = true
		if opt.has("hold_from") and not cut and host._hold_stall > 1.0:
			cut_now = true
			guest.dbg_hold_from = -1
		if cut_now:
			cut = true
			_down_until = Time.get_ticks_msec() + CUT_MS
			_guest_end.close(1006, "обрыв")
		# событие в нужный момент восстановления: «resync» — гость только что вошёл в досылку
		# (её кадр ещё не прошёл); «bind» — сервер уже вернул гостя (rejoined в его канале), а гость
		# его ещё не прочёл
		if opt.has("trigger") and fired < 0:
			var room: Dictionary = core._rooms.get(code, {})
			if not room.is_empty() and int((room["away_until"] as Array)[1]) > 0:
				saw_away = true
			var go := false
			if String(opt["trigger"]) == "resync":
				go = guest.stage == NetSession.Stage.RESYNC
			elif String(opt["trigger"]) == "away":
				go = saw_away and guest.stage == NetSession.Stage.RECONNECTING
			elif String(opt["trigger"]) == "tick":
				go = worlds[1].net_tick >= int(opt["at"])
			elif String(opt["trigger"]) == "bind":
				go = saw_away and not room.is_empty() and int((room["away_until"] as Array)[1]) == 0 \
					and guest.stage == NetSession.Stage.RECONNECTING
			if go:
				fired = frames
				if name == "left_away":
					# The 3 s simulated outage is wall-clock time; 600 fast frames may end sooner.
					terminal_deadline_ms = _down_until + 15000
				print("  событие %s: гость в стадии %d, досылка с %d до %d" % [opt["action"],
					guest.stage, guest._rejoin.resend_k, guest._next_out])
				match String(opt["action"]):
					"host_leave":
						host.leave_match()
					"overload":
						core._close_room_void(code, "overload")
					"refuse":
						_guest_end.dbg_refuse = int(opt["refuse"])
				core.process()
		if name == "left_away" and fired >= 0:
			if guest._remote_left or Time.get_ticks_msec() >= terminal_deadline_ms:
				break
		elif String(opt.get("action", "")) in ["host_leave", "overload"] and fired >= 0 \
				and frames - fired > 150:
			break
		var done := worlds[0].net_tick >= TICKS and worlds[1].net_tick >= TICKS
		if done or (opt.has("no_caps") and cut and not aborted.is_empty() and host._remote_left):
			break
	var res := {"ticks": [worlds[0].net_tick, worlds[1].net_tick], "digests": digests,
		"rejoins": sessions[1]._rejoin.count, "away_ms": sessions[1]._rejoin.away_ms,
		"opp_away_seen": opp_away_seen, "remote_left": sessions[0]._remote_left,
		"aborted": aborted, "guest_aborted": aborted.any(func(a: String) -> bool:
			return a.begins_with("1: ")), "no_rj": not rj_seen[0] and not rj_seen[1],
		"desync": [sessions[0]._desync_tick, sessions[1]._desync_tick], "resend": resend,
		"host_max_hold": host_max_hold, "tries": tries, "frames": frames,
		"outage_elapsed": Time.get_ticks_msec() >= _down_until,
		"guest_phase": int(worlds[1].phase), "guest_result": NetMatchStats.end_result(worlds[1], 1),
		"guest_remote_left": sessions[1]._remote_left,
		"forge": [sessions[0].forge_cheater, sessions[1].forge_cheater], "forged_k": forged_k,
		"mismatch": sessions[1].p2p_mismatch}
	print("  прогон %s: %s" % [name, str({"ticks": res["ticks"], "rejoins": res["rejoins"],
		"away_ms": res["away_ms"], "resend": resend, "tries": tries, "frames": frames,
		"aborted": aborted})])
	for s: NetSession in sessions:
		s.close()
	for e: Variant in [_guest_end]:
		if e is NetLinkPipe:
			(e as NetLinkPipe).close(1000, "конец")
	core.process()
	holder.queue_free()
	await process_frame
	await process_frame
	return res
