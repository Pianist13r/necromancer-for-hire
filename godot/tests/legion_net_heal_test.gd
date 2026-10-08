extends SceneTree
##
## Подтяжка снимком судьи (slow/net-heal, docs/pvp/NET_LOCKSTEP.md «Подтяжка») — в одном процессе,
## без сокетов: «судья» — сетевой мир J, где за обе стороны играют PvpBot (их команды проходят кодек
## и JSON, как в сети, и ставятся на ход t + 2), «клиент» — мир C стороны 1 под настоящей NetSession
## (ходы применяет она сама, _apply_turn — с журналом ходов для досчёта).
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60 --script res://tests/legion_net_heal_test.gd -- --mute
##
## 1) куски снимка (NetSession.snap_parts/snap_join): туда-обратно побайтно, порча и чужое — пусто;
## 2) клиент испортил бой → отпечатки разошлись → снимок судьи СТАРШЕ своего тика: загрузка на месте
##    и досчёт своими ходами — отпечаток и снимок равны судейским и ещё 10 с идут вровень;
## 3) снимок НОВЕЕ своего тика (клиент отстал) — бой перескакивает, дальше вровень;
## 4) снимок кусками через _on_snap_part (чужой номер, не по порядку — мимо), подтяжки считаются;
## 5) отказы без порчи мира: старая версия снимка (v 2), нет ходов для досчёта, другой бой;
## 6) B-377 (1): закончившему матч снимок не грузится — мир не перезапущен, итог показан один раз;
##    клиент, ещё бьющийся в разошедшемся бою, со снимком решённого матча кончает его один раз,
##    итогом судьи от своей стороны;
## 7) B-377 (2): несетевая ветка SnapWorld.finish — снимок боя, решённого не «Схваткой» (фаза
##    VICTORY/DEFEAT без итога матча), закрывает свежий мир той же фазой и одним match_ended;
## 8) B-377 (3): NetSnap.VERSION ≥ 3 (PHASE_DECIDED не читается старой сборкой как поражение);
## 9) B-375: путь из кэша ContractField не зависит от того, кто спросил первым (точка за краем
##    карты и точка в крайней клетке-скале — одна прижатая клетка). Страховка: на старом коде
##    тоже проходит — A* из твёрдой клетки пуст, так что разный ответ «проходимо» по исходным
##    точкам на деле давал один путь; правка убирает зависимость от этого свойства A*.
## 10) ревью 03.10 (1): ложный «healed» (номер подтяжки предсказуем, «at» любой) ретранслятор не
##     засчитывает — расхождения после K пишутся снова (ретранслятор в процессе, без сокетов);
## 11) ревью 03.10 (2): после перескока вперёд снимком подтверждение ходов соперника (_remote_contig)
##     догоняет применённый ход, а не застревает;
## 12) ревью 03.10 (3): снимок больше предела — судья слать не будет, ретранслятор по «heal_fail»
##     сразу снимает ожидание (без 60 с) и пишет игроку «разошёлся».
## Итог «LEGION NET HEAL: N/M OK», код выхода 1 при провале.
##

const SAVE := "user://legion_net_heal_test.cfg"
const DT := 1.0 / 60.0
const SEED := 11
const MAP := "pvp:duel"
const TURN := NetSession.TURN

var _fails := 0
var _checks := 0
## ход → [команды стороны 0, стороны 1] (сырые, как пришли бы по сети); ставит судья
var _script: Dictionary = {}
var _pending: Array = [[], []]
var _bots: Array[PvpBot] = []
var _ends: Dictionary = {}   ## мир → сколько раз match_ended


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
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_test_parts()
	await _test_heal()
	await _test_decided()
	await _test_finish_offline()
	_check(NetSnap.VERSION >= 3, "B-377 (3): версия снимка %d ≥ 3" % NetSnap.VERSION)
	await _test_path_cache()
	_test_relay_forged_healed()
	_test_relay_heal_fail()
	await _test_ack_jump()
	Campaign.reset()
	print("LEGION NET HEAL: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Мир и lockstep ──────────────────────────────────────────────────────────

func _new_world() -> LegionWorld:
	var w := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"noview": "1"}
	_ends[w] = 0
	w.match_ended.connect(func(_v: bool, _s: Dictionary) -> void: _ends[w] = int(_ends[w]) + 1)
	return w


func _free(w: Node) -> void:
	if w != null and is_instance_valid(w):
		w.queue_free()
		await process_frame


## Клиент стороны 1 под NetSession: сессия в бою, сокета нет (_send молчит).
func _client(c: LegionWorld) -> NetSession:
	var s := NetSession.new()
	root.add_child(s)
	s.side = 1
	s.attach(c)
	s.stage = NetSession.Stage.PLAYING
	s._relay_contig = 1 << 30
	return s


func _setup_judge(j: LegionWorld) -> void:
	_script.clear()
	_pending = [[], []]
	_bots.clear()
	for side in 2:
		var bot := PvpBot.new()
		bot.setup(j, side)
		var sd := side
		bot.sink = func(cmd: Dictionary) -> void:
			(_pending[sd] as Array).append(JSON.parse_string(JSON.stringify(NetCodec.encode(cmd))))
		_bots.append(bot)


## Команда стороны «из сети» — как от бота: уйдёт ближайшим закрытием хода.
func _inject(side: int, cmd: Dictionary) -> void:
	(_pending[side] as Array).append(JSON.parse_string(JSON.stringify(NetCodec.encode(cmd))))


## Тик судьи: в начале хода t закрываются команды, набранные ботами (они уйдут на ход t + 2), и
## применяется ход t — сторона 0, потом 1, как у NetSession и net_judge.
func _judge_tick(j: LegionWorld) -> void:
	if not j.net_can_step():
		return
	var tick := j.net_tick
	if tick % TURN == 0:
		var t := tick / TURN
		if not _script.has(t + NetSession.DELAY_MIN):
			_script[t + NetSession.DELAY_MIN] = [(_pending[0] as Array).duplicate(),
				(_pending[1] as Array).duplicate()]
			_pending = [[], []]
		var cmds: Array = _script.get(t, [[], []])
		for s in 2:
			for raw: Variant in cmds[s]:
				var cmd := NetCodec.decode(raw)
				if not cmd.is_empty():
					j.net_apply(s, cmd)
	j.net_step()
	for bot in _bots:
		bot.tick(DT)


## Тик клиента: ход t — из «сети» (то, что судья поставил), применяет сама сессия.
func _client_tick(c: LegionWorld, s: NetSession) -> void:
	if not c.net_can_step():
		return
	var tick := c.net_tick
	if tick % TURN == 0 and tick / TURN > s._applied_turn:
		var t := tick / TURN
		var cmds: Array = _script.get(t, [[], []])
		(s._turns[0] as Dictionary)[t] = cmds[0]
		(s._turns[1] as Dictionary)[t] = cmds[1]
		s._apply_turn(t)
	c.net_step()


func _lock(j: LegionWorld, c: LegionWorld, s: NetSession, n: int) -> void:
	for i in n:
		_judge_tick(j)
		if c != null:
			_client_tick(c, s)
		if i % 6 == 5:
			await process_frame


func _wire(snap: Dictionary) -> Dictionary:
	return bytes_to_var(var_to_bytes(snap))


func _same(j: LegionWorld, c: LegionWorld) -> bool:
	return j.net_tick == c.net_tick and j.net_digest() == c.net_digest() \
		and var_to_bytes(j.snapshot()) == var_to_bytes(c.snapshot())


## Вровень n тиков: отпечаток на каждом HASH_EVERY-м совпадает.
func _lock_same(j: LegionWorld, c: LegionWorld, s: NetSession, n: int) -> int:
	var bad := 0
	for i in n:
		_judge_tick(j)
		_client_tick(c, s)
		if j.net_tick % NetSession.HASH_EVERY == 0 and j.net_digest() != c.net_digest():
			bad += 1
		if i % 6 == 5:
			await process_frame
	return bad


# ── 1) Куски ────────────────────────────────────────────────────────────────

func _test_parts() -> void:
	print("— куски снимка")
	var a := PackedFloat64Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 40000:
		a.append(rng.randf() * 1.0e6)
	var big := {"v": NetSnap.VERSION, "a": a, "s": "ё".repeat(5000)}
	var parts := NetSession.snap_parts(big)
	_check(parts.size() > 1 and parts.size() <= NetSession.SNAP_PARTS_MAX,
		"снимок ~330 КБ порезан на %d кусков ≤ %d символов" % [parts.size(), NetSession.SNAP_PART])
	var back := NetSession.snap_join(parts)
	_check(var_to_bytes(back) == var_to_bytes(big), "собран побайтно (float — без потерь)")
	var bad := parts.duplicate()
	bad[0] = "999999999999:" + bad[0].substr(bad[0].find(":") + 1)
	_check(NetSession.snap_join(bad).is_empty(), "размер больше SNAP_RAW_MAX — пусто")
	bad = parts.duplicate()
	bad.remove_at(bad.size() - 1)
	_check(NetSession.snap_join(bad).is_empty(), "без последнего куска — пусто")
	_check(NetSession.snap_join(PackedStringArray(["12:AAAA"])).is_empty(), "мусор — пусто")
	var huge := {"s": Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(2_000_000))}
	_check(NetSession.snap_parts(huge).is_empty(),
		"несжимаемые 2,7 МБ больше SNAP_PARTS_MAX кусков — судья не шлёт")


# ── 2–5) Подтяжка идущего боя ───────────────────────────────────────────────

func _test_heal() -> void:
	print("— подтяжка: %s, сид %d" % [MAP, SEED])
	var j := await _new_world()
	j.start_net_match(MAP, SEED, 0)
	var c := await _new_world()
	c.start_net_match(MAP, SEED, 1)
	_setup_judge(j)
	var s := _client(c)
	await _lock(j, c, s, 600)
	_check(_same(j, c), "до порчи клиент вровень с судьёй (тик %d)" % c.net_tick)
	var cmds := 0
	for t: int in _script:
		cmds += ((_script[t] as Array)[0] as Array).size() + ((_script[t] as Array)[1] as Array).size()
	_check(cmds > 0, "боты за 10 с отдали %d команд (досчёт идёт с командами)" % cmds)
	# 2) порча → снимок судьи на тике 660 → клиент уходит до 720 → подтяжка с досчётом
	c.sides[0].cauldron_hp -= 1.0
	await _lock(j, c, s, 60)
	_check(j.net_digest() != c.net_digest(), "порча видна в отпечатке (тик %d)" % c.net_tick)
	var snap := _wire(j.snapshot())
	var k := j.net_tick
	await _lock(j, c, s, 63)
	var t0 := Time.get_ticks_usec()
	var why := s.heal(snap)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check(why == "" and c.net_tick == j.net_tick and _same(j, c),
		"снимок тика %d в клиента на тике %d: досчитан своими ходами (%.1f мс), вровень с судьёй%s"
			% [k, j.net_tick, ms, "" if why == "" else " — " + why])
	_check(s.heals == 1 and s._desync_tick == -1 and s._applied_turn == (c.net_tick - 1) / TURN,
		"подтяжка засчитана, надписи нет, применённый ход %d" % s._applied_turn)
	var bad := await _lock_same(j, c, s, 600)
	_check(bad == 0 and _same(j, c), "ещё 10 с вровень (расхождений отпечатка %d)" % bad)
	# 3) клиент отстал: снимок новее его тика — перескок
	c.sides[1].souls += 9
	await _lock(j, null, s, 31)
	var snap2 := _wire(j.snapshot())
	var was := c.net_tick
	why = s.heal(snap2)
	_check(why == "" and c.net_tick == j.net_tick and _same(j, c),
		"снимок тика %d в отставшего клиента (тик %d): перескок, вровень%s" % [j.net_tick, was,
			"" if why == "" else " — " + why])
	bad = await _lock_same(j, c, s, 600)
	_check(bad == 0 and _same(j, c), "после перескока ещё 10 с вровень (расхождений %d)" % bad)
	# 4) куски через сессию: чужой номер и не по порядку — мимо, целиком — подтяжка
	c.sides[0].souls += 3
	await _lock(j, c, s, 30)
	var parts := NetSession.snap_parts(j.snapshot())
	var heals := s.heals
	s._on_snap_part({"t": "snap", "id": 7, "i": 1, "n": parts.size() + 1, "d": "AAAA"})
	for i in parts.size():
		s._on_snap_part({"t": "snap", "id": 8, "k": j.net_tick, "i": i, "n": parts.size(),
			"d": parts[i]})
	_check(s.heals == heals + 1 and _same(j, c),
		"снимок %d кусками через _on_snap_part — подтянут (подтяжек %d)" % [parts.size(), s.heals])
	# 5) отказы: мир не тронут
	c.sides[0].souls += 5
	var before := var_to_bytes(c.snapshot())
	var old := _wire(j.snapshot())
	old["v"] = 2
	why = s.heal(old)
	_check(why != "" and var_to_bytes(c.snapshot()) == before,
		"снимок версии 2 не принят, мир не тронут («%s»)" % why)
	var ancient := _wire(j.snapshot())
	await _lock(j, c, s, (NetSession.HIST_KEEP + 5) * TURN)
	before = var_to_bytes(c.snapshot())
	why = s.heal(ancient)
	_check(why != "" and var_to_bytes(c.snapshot()) == before,
		"снимок старше журнала ходов (%d ходов) не принят, мир не тронут («%s»)" % [
			NetSession.HIST_KEEP, why])
	var o := await _new_world()
	o.start_net_match(MAP, SEED + 1, 0)
	why = s.heal(_wire(o.snapshot()))
	_check(why.begins_with("другой бой") and var_to_bytes(c.snapshot()) == before,
		"снимок другого боя (сид %d) не принят — без перезапуска мира («%s»)" % [SEED + 1, why])
	await _free(o)
	# 6) B-377 (1): закончившему матч снимок не грузится
	s.heal(_wire(j.snapshot()))
	_inject(0, PvpCmd.surrender())
	await _lock(j, c, s, (NetSession.DELAY_MIN + 2) * TURN + 3)
	_check(j.phase != LegionWorld.Phase.BATTLE and c.phase == LegionWorld.Phase.VICTORY
			and int(_ends[c]) == 1,
		"сторона 0 сдалась: клиент стороны 1 — победа, итог показан %d раз" % int(_ends[c]))
	var end_tick := c.net_tick
	before = var_to_bytes(c.snapshot())
	why = s.heal(_wire(j.snapshot()))
	_check(why != "" and int(_ends[c]) == 1 and c.phase == LegionWorld.Phase.VICTORY
			and c.net_tick == end_tick and var_to_bytes(c.snapshot()) == before,
		"снимок решённого матча закончившему не грузится: мир тот же, итог один («%s»)" % why)
	# снимок запрошен, а матч кончился раньше, чем он пришёл: надпись и итог судьи — как без подтяжки
	s._handle({"t": "desync", "k": 777, "judge": true, "heal": true})
	_check(s._desync_tick == -1 and s._heal_wait == 777,
		"desync с heal: надписи «разошёлся» нет, ждём снимок")
	s._finish()
	_check(s._desync_tick == 777 and s._desync_judge and s._heal_wait == -1,
		"матч кончился раньше снимка — расхождение показано, итог по счёту судьи")
	await _free(s)
	await _free(j)
	await _free(c)


## 6) Клиент ещё бьётся в разошедшемся бою, а у судьи матч решён: снимок решённого матча кончает
## бой клиента один раз — итогом судьи от стороны клиента.
func _test_decided() -> void:
	print("— снимок решённого матча в клиента, который ещё в бою")
	var j := await _new_world()
	j.start_net_match(MAP, SEED, 0)
	var c := await _new_world()
	c.start_net_match(MAP, SEED, 1)
	_setup_judge(j)
	var s := _client(c)
	await _lock(j, c, s, 120)
	_inject(1, PvpCmd.surrender())
	await _lock(j, null, s, (NetSession.DELAY_MIN + 2) * TURN + 3)
	_check(j.phase != LegionWorld.Phase.BATTLE and c.phase == LegionWorld.Phase.BATTLE,
		"судья: сторона 1 сдалась; клиент (отстал) ещё в бою")
	var why := s.heal(_wire(j.snapshot()))
	var win := int(c.pvp_match.result.get("winner", -2)) if c.pvp_match != null else -2
	_check(why == "" and c.phase == LegionWorld.Phase.DEFEAT and win == 0 and int(_ends[c]) == 1,
		"клиент кончил матч итогом судьи: фаза %d, победитель %d, итог показан %d раз%s" % [
			c.phase, win, int(_ends[c]), "" if why == "" else " — " + why])
	await _free(s)
	await _free(j)
	await _free(c)


# ── 7) Несетевая ветка SnapWorld.finish ─────────────────────────────────────

func _test_finish_offline() -> void:
	print("— B-377 (2): снимок решённого боя вне «Схватки»")
	for victory: bool in [true, false]:
		var a := await _new_world()
		a.args["pvp_bots"] = true
		a._base_seed = SEED
		a.start_map(MAP)
		for i in 60:
			a._step(DT)
		a._end(victory)
		var want := LegionWorld.Phase.VICTORY if victory else LegionWorld.Phase.DEFEAT
		var snap := a.snapshot()
		var phase := int((snap["world"] as Dictionary)["phase"])
		_check(not a.net_mode and phase == want and phase != SnapWorld.PHASE_DECIDED,
			"снимок: мир вне сети, фаза %d (не «матч решён»)" % phase)
		var b := await _new_world()
		b.args["pvp_bots"] = true
		b._base_seed = SEED
		b.start_map(MAP)
		var got := []
		b.match_ended.connect(func(v: bool, _s: Dictionary) -> void: got.append(v))
		var reg := b.load_snapshot(_wire(snap))
		_check(reg.errors.is_empty() and b.phase == want and got == [victory],
			"%s: свежий мир закрыт той же фазой %d, match_ended %s" % [
				"победа" if victory else "поражение", b.phase, str(got)])
		await _free(a)
		await _free(b)


# ── 9) B-375: кэш путей ─────────────────────────────────────────────────────

func _test_path_cache() -> void:
	print("— B-375: кэш путей не зависит от порядка вопросов")
	var w := await _new_world()
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	var cell := float(LegionCfg.CELL)
	# скала в крайней левой клетке ряда 5: точка за краем карты прижимается к той же клетке,
	# но проходима (за краем — «чистое поле»), а точка в клетке — скала
	var y0 := 5.0 * cell
	w.terrain = LegionTerrain.new().setup({"rocks": [[[0, y0], [cell, y0], [cell, y0 + cell],
		[0, y0 + cell]]]})
	w.grid.rebuild()
	var f := w.contracts
	var p_out := Vector2(-10.0, y0 + cell * 0.5)
	var p_in := Vector2(cell * 0.5, y0 + cell * 0.5)
	var dest := Vector2(400.0, 400.0)
	_check(w.terrain.cell_of(p_out) == w.terrain.cell_of(p_in) and w.terrain.walkable(p_out)
			and not w.terrain.walkable(p_in), "одна прижатая клетка, проходимость разная")
	var first := {}
	f._paths.clear()
	first["in"] = f.recruit_path(p_in, dest)
	first["out"] = f.recruit_path(p_out, dest)
	f._paths.clear()
	var second := {}
	second["out"] = f.recruit_path(p_out, dest)
	second["in"] = f.recruit_path(p_in, dest)
	_check(first["out"] == second["out"] and first["in"] == second["in"],
		"ответ не зависит от того, кто спросил первым (за краем: %d точек / %d; в скале: %d / %d)"
			% [(first["out"] as PackedVector2Array).size(),
			(second["out"] as PackedVector2Array).size(),
			(first["in"] as PackedVector2Array).size(), (second["in"] as PackedVector2Array).size()])
	_check((first["in"] as PackedVector2Array).is_empty(), "из клетки-скалы пути нет")
	await _free(w)


# ── 10–12) Ревью 03.10 ──────────────────────────────────────────────────────

## Ретранслятор в процессе: сокетов нет, игроки — заглушки (сообщения копятся в outq), судья — третья.
## Комната начата, стороны 0 и 1 = игроки 1 и 2.
func _relay_stub() -> Array:
	var relay: Object = NetRelayCore.new()
	var peers: Dictionary = relay.get("_peers")
	for id in [1, 2, 3]:
		# базовый NetLink — CLOSED: отправка не проходит, сообщения копятся в outq
		peers[id] = {"outq": [], "tail": [], "lobby_next": "", "outq_bytes": 0,
			"link": NetLink.new(), "room": "", "side": 0, "hello": true,
			"name": "p%d" % id, "build": "t"}
	relay.call("_create_room", 1, MAP)
	var code := String((peers[1] as Dictionary)["room"])
	var room: Dictionary = (relay.get("_rooms") as Dictionary)[code]
	(room["peers"] as Array).append(2)
	(peers[2] as Dictionary)["room"] = code
	(peers[2] as Dictionary)["side"] = 1
	(peers[3] as Dictionary)["room"] = code
	(peers[3] as Dictionary)["judge"] = true
	room["judge"] = 3
	room["started"] = true
	return [relay, code, room]


func _outq_types(relay: Object, id: int) -> Array:
	var out := []
	for text: String in ((relay.get("_peers") as Dictionary)[id] as Dictionary)["outq"]:
		var m: Variant = JSON.parse_string(text)
		out.append(m if m is Dictionary else {})
	return out


func _test_relay_forged_healed() -> void:
	print("— ревью 03.10 (1): ложный healed")
	var st := _relay_stub()
	var relay: Object = st[0]
	var code: String = st[1]
	var room: Dictionary = st[2]
	var busy: Array = room["heal_busy"]
	relay.call("_judge_mismatch", code, room, 1, 100)
	_check(bool(busy[1]) and int((room["heal_id"] as Array)[1]) == 1,
		"расхождение стороны 1 → подтяжка 1 запрошена")
	# ложный отчёт до всякого снимка: номер 1 предсказуем, at любой
	relay.call("_healed", 2, {"t": "healed", "id": 1, "ok": true, "at": 5})
	_check(bool(busy[1]) and int((room["heal_upto"] as Array)[1]) == -1,
		"healed без снимка не принят: ждём настоящий, расхождения не заглушены")
	# снимок тика 660 в пути к стороне (не отдан целиком): отчёт тоже ложный
	relay.call("_judge_snap", code, room, {"s": 1, "id": 1, "k": 660, "i": 0, "n": 2, "d": "AAAA"})
	relay.call("_healed", 2, {"t": "healed", "id": 1, "ok": true, "at": 700})
	_check(bool(busy[1]), "снимок не отдан целиком — healed не принят")
	# снимок отдан стороне целиком (отправку сокетом имитируем — сокета в тесте нет)
	(room["heal_sent"] as Array)[1] = true
	relay.call("_healed", 2, {"t": "healed", "id": 1, "ok": true, "at": 1000000000})
	_check(not bool(busy[1]) and int((room["heal_upto"] as Array)[1]) == 660,
		"at = 1e9 при снимке тика 660 — ложный: подтяжка не засчитана, молчат только тики ≤ 660 (upto %d)"
			% int((room["heal_upto"] as Array)[1]))
	relay.call("_judge_mismatch", code, room, 1, 720)
	_check(bool(busy[1]) and int((room["heal"] as Array)[1]) == 2,
		"расхождение на тике 720 > K снова пишется: подтяжка 2 запрошена")
	# настоящая подтяжка: снимок отдан, at в пределах [K, K + запас]
	(room["heal_k"] as Array)[1] = 760
	(room["heal_sent"] as Array)[1] = true
	relay.call("_healed", 2, {"t": "healed", "id": 2, "ok": true, "at": 759})
	_check(not bool(busy[1]) and int((room["heal_upto"] as Array)[1]) == 760,
		"at меньше тика снимка — ложный: подтяжка не засчитана, молчат тики ≤ 760")
	busy[1] = true   # (ждём настоящий отчёт той же подтяжки — как если бы ложный не пришёл)
	relay.call("_healed", 2, {"t": "healed", "id": 2, "ok": true, "at": 820})
	_check(not bool(busy[1]) and int((room["heal_upto"] as Array)[1]) == 820,
		"настоящий healed (снимок 760, at 820) принят: upto %d" % int((room["heal_upto"] as Array)[1]))


func _test_relay_heal_fail() -> void:
	print("— ревью 03.10 (3): снимок слишком большой")
	var big := {"v": NetSnap.VERSION, "s": "ё".repeat(5000)}
	var st := _relay_stub()
	var relay: Object = st[0]
	var code: String = st[1]
	var room: Dictionary = st[2]
	var busy: Array = room["heal_busy"]
	relay.call("_judge_mismatch", code, room, 1, 100)
	_check(bool(busy[1]), "подтяжка запрошена, ждём снимок")
	var known := relay.has_method("_judge_heal_fail")
	_check(known, "ретранслятор знает отказ судьи heal_fail")
	if not known:
		return
	relay.call("_judge_heal_fail", code, room, {"s": 1, "id": 99, "why": "x"})
	_check(bool(busy[1]), "отказ с чужим номером подтяжки — мимо")
	relay.call("_judge_heal_fail", code, room, {"s": 1, "id": 1, "why": "снимок слишком большой"})
	var tail: Array = _outq_types(relay, 2)
	var last: Dictionary = tail[tail.size() - 1] if not tail.is_empty() else {}
	_check(not bool(busy[1]) and int((room["heal"] as Array)[1]) == int(relay.get("HEAL_MAX"))
			and String(last.get("t")) == "desync" and bool(last.get("judge")) and not last.has("heal"),
		"подтяжка несостоявшаяся сразу (не через 60 с), новых нет, игроку desync без «heal»")
	relay.call("_judge_mismatch", code, room, 1, 200)
	var heal_reqs := 0
	for m: Dictionary in _outq_types(relay, 3):
		heal_reqs += int(String(m.get("t")) == "heal")
	_check(heal_reqs == 1 and not bool(busy[1]),
		"дальше как без подтяжек: нового снимка судье не просим (запросов %d)" % heal_reqs)
	var limited: Variant = Callable(NetSession, "snap_parts").call(big, 5)
	_check(NetSession.snap_parts(big).size() >= 1 and limited is PackedStringArray
			and (limited as PackedStringArray).is_empty(),
		"snap_parts с пределом 5 знаков — пусто (судья не шлёт)")


## Клиент отстал, судья ушёл вперёд: после перескока снимком подтверждение ходов соперника
## (_remote_contig, уходит в UDP-пакет) догоняет применённый ход (проба verifier'а jump_probe).
func _test_ack_jump() -> void:
	print("— ревью 03.10 (2): подтверждение ходов после перескока")
	var j := await _new_world()
	j.start_net_match(MAP, SEED, 0)
	var c := await _new_world()
	c.start_net_match(MAP, SEED, 1)
	_setup_judge(j)
	var s := _client(c)
	for i in 600:
		_judge_tick(j)
		_client_tick_wire(c, s)
		if i % 6 == 5:
			await process_frame
	_check(s._remote_contig >= s._applied_turn - 2,
		"до перескока подтверждено %d из применённых %d" % [s._remote_contig, s._applied_turn])
	for i in 30:
		_judge_tick(j)
	var why := s.heal(_wire(j.snapshot()))
	_check(why == "" and s._remote_contig >= s._applied_turn,
		"после перескока (применённый ход %d) подтверждение сдвинуто к нему: %d%s" % [s._applied_turn,
			s._remote_contig, "" if why == "" else " — " + why])
	for i in 600:
		_judge_tick(j)
		_client_tick_wire(c, s)
		if i % 6 == 5:
			await process_frame
	_check(s._remote_contig >= s._applied_turn - 2 and s._remote_have.size() < 4,
		"ещё 10 с спустя подтверждено %d из применённых %d (не застряло)" % [s._remote_contig,
			s._applied_turn])
	await _free(s)
	await _free(j)
	await _free(c)


## Как _client_tick, но ход соперника — через _on_remote_turn (с подтверждением), как из сети.
func _client_tick_wire(c: LegionWorld, s: NetSession) -> void:
	var tick := c.net_tick
	if tick % TURN == 0 and tick / TURN > s._applied_turn:
		var t := tick / TURN
		var cmds: Array = _script.get(t, [[], []])
		if not (s._turns[0] as Dictionary).has(t):
			var raw := JSON.stringify({"t": "in", "k": t, "c": cmds[0]})
			s._on_remote_turn(JSON.parse_string(raw), raw, "relay")
		(s._turns[1] as Dictionary)[t] = cmds[1]
		s._apply_turn(t)
	c.net_step()
