extends SceneTree
##
## Регресс линии L1 «Ядро: несколько сторон» онлайн-PvP «Схватка» (docs/pvp/DESIGN.md §2, §3.3,
## §4, §11). Сессия e5d60159, 27.09.2026.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_core_test.gd -- --mute
##
## 1) одиночка не изменилась: полный бой бота selective на двух картах кампании — трасса и итог
##    совпадают с эталоном, снятым на коде ДО линии (tests/data/legion_pvp_core_single_ref.txt;
##    PVP_CORE_WRITE_REF=1 — переснять эталон, только на старом коде!); строка fork переснята
##    30.09 в slow/home-guard: одиночку намеренно изменила «оборона дома», не линия PvP;
## 2) PvP-мир: размер из карты (1600×900), стороны со своими Котлами/полями/штатом, зеркало вида;
## 3) бойцы своей стороны не бьют своих; чужие бьются (и у x > 1280 — сетка не обрезана);
## 4) бойцы бьют чужой Котёл и не исчезают; Котёл падает — победа стороны; души за чужого бойца;
## 5) проверяющий идёт к Котлу своей половины и бьёт бойцов любой стороны;
## 6) ничья по пределу, победа по проценту HP на пределе, ничья при общем падении, сдача;
## 7) правила PvP: нет паузы (Esc — меню поверх), нет вызова волны, нет Отсрочки и hit-stop;
## 8) API команд: чужие договоры и площадки недоступны, штрих/щелчок/рогатка/Ку/«Сбор» — через
##    одну точку; бот против бота за 150 с игры чертит оборону и делает перебежки.
## Этот полный тест требует классы L1. Проверка старого кода без них вынесена в
## legion_pvp_entry_test.gd. Итог «LEGION PVP CORE: N/M OK»; выход 1 при провале.
##

const SAVE := "user://legion_pvp_core_test.cfg"
const DT := 1.0 / 60.0
const REF := "res://tests/data/legion_pvp_core_single_ref.txt"
## Полный бой бота: карта, сид; предел шагов — страховка от вечного боя.
const SINGLE_RUNS := [["wasteland", 3], ["fork", 2]]
const SINGLE_MAX_STEPS := 60 * 60 * 20
const DUEL := "pvp:duel"

var w: LegionWorld
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
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	# одиночка — первой, пока мир не видел PvP: порядок прогона тот же, что у эталона
	_test_single_same()
	if _pvp_ok():
		_test_world_shape()
		_test_friends_and_foes()
		_test_cauldron_bite()
		_test_pve_half()
		_test_match_end()
		_test_rules()
		_test_commands()
		_test_no_cross_control()
		_test_bots()
	Campaign.reset()
	print("LEGION PVP CORE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── 1. Одиночка побайтно прежняя ─────────────────────────────────────────────

func _single_digest(map_id: String, seed: int) -> String:
	Settings.scheme_override = ""
	w.dev = {"difficulty": "intern"}
	w.dev_invuln = false
	w.args["bot"] = "selective"
	w._base_seed = seed
	w.start_map(map_id)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	var i := 0
	while w.phase == LegionWorld.Phase.BATTLE and i < SINGLE_MAX_STEPS:
		w._step(DT)
		i += 1
		if i % 60 != 0:
			continue
		var line := "%d|%.4f|%.4f|%d|%d|%d|" % [i, w.cauldron_hp, w.contracts.mana, w.souls,
			w.army_alive(), w.active_foes()]
		for u in w.units:
			line += "%.2f,%.2f,%.2f,%d;" % [u.position.x, u.position.y, u.hp, u.state]
		ctx.update(line.to_utf8_buffer())
	var fin := w.final_stats(w.phase == LegionWorld.Phase.VICTORY)
	var keys := fin.keys()
	keys.sort()
	var tail := ""
	for k in keys:
		tail += "%s=%s," % [k, str(fin[k])]
	ctx.update(tail.to_utf8_buffer())
	w.args.erase("bot")
	print("  итог %s s%d: %s за %d шагов" % [map_id, seed, fin["result"], i])
	return ctx.finish().hex_encode()


func _test_single_same() -> void:
	print("— одиночка: полный бой бота как до линии")
	var got: Array[String] = []
	for run: Array in SINGLE_RUNS:
		var t0 := Time.get_ticks_msec()
		var d := _single_digest(run[0], run[1])
		got.append("%s %d %s" % [run[0], run[1], d])
		print("  SINGLEREF %s %d %s  (%d мс)" % [run[0], run[1], d, Time.get_ticks_msec() - t0])
	if OS.get_environment("PVP_CORE_WRITE_REF") == "1":
		var f := FileAccess.open(REF, FileAccess.WRITE)
		f.store_string("\n".join(got) + "\n")
		f.close()
		print("  эталон записан: ", REF)
	var ref: Array[String] = []
	var rf := FileAccess.open(REF, FileAccess.READ)
	if rf != null:
		for line in rf.get_as_text().split("\n", false):
			ref.append(line.strip_edges())
	for g in got:
		_check(ref.has(g), "одиночный бой совпал с эталоном: %s" % g.substr(0, g.rfind(" ")))


# ── PvP: подготовка ──────────────────────────────────────────────────────────

func _pvp_ok() -> bool:
	_fresh()
	var sides: Variant = w.get("sides")
	var ok := sides is Array and (sides as Array).size() == 2 and not w.map.is_empty()
	_check(ok, "карта «%s» стартует матч двух сторон" % DUEL)
	return ok


## Матч без волн, без ботов, без стартового штата: тест расставляет всех сам.
func _fresh(waves := false, bots := false) -> void:
	w.dev = {"spawn_units": "0", "pvp_nobot": "1"}
	if not waves:
		w.dev["no_waves"] = "1"
	if bots:
		w.dev.erase("pvp_nobot")
		w.args["pvp_bots"] = true
	else:
		w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 7
	w.start_map(DUEL)


func _side(i: int) -> PvpSide:
	return (w.get("sides") as Array)[i]


func _unit(kind: StringName, at: Vector2, side: int) -> Legionnaire:
	return w.call("spawn_unit", kind, at, null, side) as Legionnaire


func _steps(n: int) -> void:
	for i in n:
		if w.phase != LegionWorld.Phase.BATTLE:
			return
		w._step(DT)


# ── 2. Мир и стороны ─────────────────────────────────────────────────────────

func _test_world_shape() -> void:
	print("— мир PvP: размер из карты, стороны, зеркало")
	_fresh()
	_check(w.get("world_size") == PvpRules.FIELD, "размер мира из карты: %s" % str(w.get("world_size")))
	_check(w.terrain.walkable(Vector2(1500, 450)) and not w.terrain.walkable(Vector2(800, 450)),
		"рельеф на всём поле: x 1500 проходим, стык x 800 — глыба")
	var s0 := _side(0)
	var s1 := _side(1)
	_check(s0.contracts == w.contracts and s0.staff == w.staff and s0.hero == w.hero,
		"сторона 0 — те же поле, штат и герой, что у мира (одиночка — частный случай)")
	_check(s1.contracts != s0.contracts and s1.staff != s0.staff and s1.hero != null
		and s1.hero != s0.hero, "у стороны 1 своё поле договоров, свой штат и свой герой")
	_check(s0.cauldron_pos.x < 800.0 and s1.cauldron_pos.x > 800.0
		and is_equal_approx(s0.cauldron_pos.x + s1.cauldron_pos.x, PvpRules.FIELD.x),
		"Котлы зеркальны: %s и %s" % [str(s0.cauldron_pos), str(s1.cauldron_pos)])
	_check(is_equal_approx(s1.cauldron_hp, PvpRules.CAULDRON_HP)
		and is_equal_approx(w.cauldron_hp, PvpRules.CAULDRON_HP), "Котёл PvP — %d HP" % PvpRules.CAULDRON_HP)
	_check(s1.view_xf * Vector2(100, 50) == Vector2(1500, 50) and s0.view_xf * Vector2(100, 50) == Vector2(100, 50),
		"вид стороны 1 — отражение x' = W − x, стороны 0 — тождество")
	var plots0: Array = []
	for p: Dictionary in s0.staff.plots:
		plots0.append(p["id"])
	_check(plots0.size() == PvpMaps.PLOTS.size() and String(plots0[0]).begins_with("s0_"), "площадки стороны 0 — только свои: %s" % str(plots0))
	# одиночная карта — прежний размер
	w.dev = {"no_waves": "1"}
	w.start_map("bridge")
	_check(w.get("world_size") == LegionCfg.WORLD_SIZE and (w.get("sides") as Array).size() == 1,
		"одиночная карта: мир 1280×720, одна сторона")


# ── 3. Свои и чужие ──────────────────────────────────────────────────────────

func _test_friends_and_foes() -> void:
	print("— свои не бьют своих, чужие бьются")
	_fresh()
	var a := _unit(LegionCfg.KIND_LABORER, Vector2(300, 150), 0)
	var b := _unit(LegionCfg.KIND_LABORER, Vector2(312, 150), 0)
	var c := _unit(LegionCfg.KIND_LABORER, Vector2(1300, 150), 1)
	var d := _unit(LegionCfg.KIND_LABORER, Vector2(1312, 150), 1)
	# чужие у x > 1280: сетка соседей обязана видеть всё поле
	var e := _unit(LegionCfg.KIND_LABORER, Vector2(1500, 300), 0)
	var f := _unit(LegionCfg.KIND_LABORER, Vector2(1514, 300), 1)
	_check(a != null and f != null and a.get("side") == 0 and f.get("side") == 1, "бойцы родились со стороной")
	if a == null or f == null:
		return
	_steps(150)
	_check(a.hp == a.max_hp and b.hp == b.max_hp, "два своих бойца стороны 0 вплотную — оба целы")
	_check(c.hp == c.max_hp and d.hp == d.max_hp, "два своих бойца стороны 1 вплотную — оба целы")
	_check(e.hp < e.max_hp and f.hp < f.max_hp, "чужие вплотную у x 1500 бьют друг друга: %.1f / %.1f" % [e.hp, f.hp])
	var hp_e := e.hp
	_steps(60 * 12)
	_check(not e.alive or not f.alive, "стычка один на один кончается гибелью (%s / %s)" % [str(e.alive), str(f.alive)])
	# бой одновременный: равные бойцы гибнут в одном шаге — души обеим сторонам
	_check(not e.alive and not f.alive, "равные бойцы — взаимная гибель: бой одновременный, "
		+ "порядок списка бойцов не даёт первого удара")
	var want0 := LegionCfg.SOULS_START + (PvpRules.SOULS_PER_UNIT if not f.alive else 0)
	var want1 := LegionCfg.SOULS_START + (PvpRules.SOULS_PER_UNIT if not e.alive else 0)
	_check(_side(0).souls == want0 and _side(1).souls == want1,
		"души за чужого бойца — убившей стороне: %d / %d" % [_side(0).souls, _side(1).souls])
	_check(hp_e > 0.0, "бой шёл обычными числами")


# ── 4. Котёл ────────────────────────────────────────────────────────────────

func _test_cauldron_bite() -> void:
	print("— бойцы бьют чужой Котёл и не исчезают")
	_fresh()
	var s1 := _side(1)
	var at := s1.cauldron_pos
	var army: Array[Legionnaire] = []
	for i in 10:
		army.append(_unit(LegionCfg.KIND_LABORER, at + Vector2(-48, -45 + 10 * i), 0))
	# свой боец у своего Котла Котёл не бьёт
	var own := _unit(LegionCfg.KIND_LABORER, _side(0).cauldron_pos + Vector2(40, 0), 0)
	_steps(120)
	var hp := s1.cauldron_hp
	_check(hp < PvpRules.CAULDRON_HP, "чужой Котёл теряет HP: %.1f" % hp)
	_check(is_equal_approx(_side(0).cauldron_hp, PvpRules.CAULDRON_HP), "свой Котёл свой боец не бьёт")
	var alive := 0
	for u in army:
		alive += int(u.alive and u.visible)
	_check(alive == army.size(), "дошедшие бойцы не исчезают: %d/%d" % [alive, army.size()])
	_check(own.alive, "свой у своего Котла жив")
	s1.cauldron_hp = 5.0
	_steps(120)
	_check(w.phase == LegionWorld.Phase.VICTORY, "Котёл стороны 1 пал — сторона 0 победила (фаза %d)" % w.phase)
	var fin := w.final_stats(true)
	var pvp: Dictionary = fin.get("pvp", {})
	_check(int(pvp.get("winner", -9)) == 0 and String(pvp.get("reason", "")) == PvpMatch.REASON_CAULDRON,
		"итог матча: %s" % str(pvp))


# ── 5. Волны PvE ────────────────────────────────────────────────────────────

func _test_pve_half() -> void:
	print("— проверяющий идёт к Котлу своей половины и бьёт бойцов любой стороны")
	_fresh()
	var f0 := w.spawn_foe("zombie", "s0_top")
	var f1 := w.spawn_foe("zombie", "s1_bot")
	_check(f0 != null and f1 != null and f0.get("goal_side") == 0 and f1.get("goal_side") == 1,
		"цель — Котёл половины, где кончается дорога")
	if f0 == null or f1 == null:
		return
	# боец стороны 0 на пути к Котлу стороны 1: волна половины 1 бьёт и его
	var path := w.road_path("s1_bot")
	var guest := _unit(LegionCfg.KIND_LABORER, path[1] + Vector2(0, -30), 0)
	var guest_hp := guest.hp
	_steps(60 * 8)
	_check(guest.hp < guest_hp or not guest.alive, "проверяющий половины 1 бьёт бойца стороны 0")
	w.dev_invuln = false
	_steps(60 * 40)
	_check(_side(0).cauldron_hp < PvpRules.CAULDRON_HP and _side(1).cauldron_hp < PvpRules.CAULDRON_HP,
		"дошедшие бьют каждый свой Котёл: %.0f / %.0f" % [_side(0).cauldron_hp, _side(1).cauldron_hp])


# ── 6. Конец матча ──────────────────────────────────────────────────────────

func _match() -> PvpMatch:
	return w.get("pvp_match") as PvpMatch


func _test_match_end() -> void:
	print("— предел, ничья, сдача")
	_fresh()
	_match().limit = 2.0
	_steps(60 * 3)
	var pvp: Dictionary = w.final_stats(false).get("pvp", {})
	_check(w.phase != LegionWorld.Phase.BATTLE and int(pvp.get("winner", -9)) == -1
		and String(pvp.get("reason", "")) == PvpMatch.REASON_LIMIT,
		"предел при равных Котлах — ничья: %s" % str(pvp))
	_check(String(w.final_stats(false).get("result", "")) == "draw", "итог стороны 0 — «draw»")
	_fresh()
	_match().limit = 2.0
	_side(1).cauldron_hp = PvpRules.CAULDRON_HP * 0.5
	_steps(60 * 3)
	pvp = w.final_stats(false).get("pvp", {})
	_check(int(pvp.get("winner", -9)) == 0 and w.phase == LegionWorld.Phase.VICTORY,
		"предел: у стороны 0 больше HP — победа: %s" % str(pvp))
	_fresh()
	_match().limit = 2.0
	_side(0).cauldron_hp = PvpRules.CAULDRON_HP * 0.97
	_steps(60 * 3)
	pvp = w.final_stats(false).get("pvp", {})
	_check(int(pvp.get("winner", -9)) == -1, "предел: разница меньше 5 %% — ничья: %s" % str(pvp))
	_fresh()
	_side(0).cauldron_hp = 0.0
	_side(1).cauldron_hp = 0.0
	_steps(2)
	pvp = w.final_stats(false).get("pvp", {})
	_check(int(pvp.get("winner", -9)) == -1 and String(pvp.get("reason", "")) == PvpMatch.REASON_DRAW,
		"оба Котла пали в одном шаге — ничья: %s" % str(pvp))
	_fresh()
	var res: Dictionary = w.call("command", 1, PvpCmd.surrender())
	pvp = w.final_stats(false).get("pvp", {})
	_check(bool(res.get("ok", false)) and w.phase == LegionWorld.Phase.VICTORY
		and int(pvp.get("winner", -9)) == 0 and String(pvp.get("reason", "")) == PvpMatch.REASON_SURRENDER,
		"сдача стороны 1 засчитана сразу: %s" % str(pvp))
	_fresh()
	w.call("command", 0, PvpCmd.surrender())
	_check(w.phase == LegionWorld.Phase.DEFEAT, "сдача стороны 0 — её поражение")


# ── 7. Правила PvP ──────────────────────────────────────────────────────────

func _test_rules() -> void:
	print("— нет паузы, вызова волны, Отсрочки")
	_fresh(true)
	var esc := InputEventAction.new()
	esc.action = &"pause"
	esc.pressed = true
	w._unhandled_input(esc)
	_check(not w.paused and not paused, "Esc в PvP не ставит паузу")
	var menu: Variant = w.get("pvp_menu")
	_check(menu is CanvasLayer and (menu as CanvasLayer).visible, "Esc открывает меню поверх боя")
	w._unhandled_input(esc)
	_check(menu is CanvasLayer and not (menu as CanvasLayer).visible, "второй Esc закрывает меню")
	_check(w.call_wave() == -1, "вызова волны нет (F/N)")
	_steps(60 * 61)
	_check(w.wave_runner.wave_no() == 1, "первая волна — по часам на 60-й секунде")
	var f := _side(0).contracts
	var c := f.add_contract(PackedVector2Array([Vector2(300, 250), Vector2(300, 400)]), 1)
	_check(c != null, "договор стороны 0")
	if c != null:
		f.set("_grab", {"contract": c, "seg": 0})
		f.set("_slinging", true)
		_check(is_equal_approx(f.real_tick(0.1), 1.0), "натяжка рогатки не замедляет мир (Отсрочки нет)")
		f.cancel_sling()
	w.set("_hitstop_left", 0.0)
	w.call("_charge_feedback", Vector2(300, 300), true)
	_check(is_equal_approx(float(w.get("_hitstop_left")), 0.0), "hit-stop натиска в PvP не останавливает мир")


# ── 8. API команд ───────────────────────────────────────────────────────────

func _test_commands() -> void:
	print("— API команд стороны")
	_fresh()
	_side(0).souls = 500
	_side(1).souls = 500
	var line := PackedVector2Array()
	for i in 21:
		line.append(Vector2(420.0, 300.0 + 8.0 * i))
	var r0: Dictionary = w.call("command", 0, PvpCmd.stroke(line, LegionCfg.KIND_LABORER, Vector2(500, 380)))
	_check(bool(r0.get("ok", false)) and _side(0).contracts.contracts.size() == 1
		and _side(1).contracts.contracts.is_empty(), "штрих стороны 0 — договор в её поле: %s" % str(r0))
	var c0 := _side(0).contracts.by_id(int(r0.get("contract", -1)))
	_check(c0 != null and c0.dir.x > 0.9, "стрелка штриха — к точке arrow")
	var r1: Dictionary = w.call("command", 1, PvpCmd.click(int(r0.get("contract", -1)), 0))
	_check(not bool(r1.get("ok", true)), "щелчок по чужому договору — отказ: %s" % str(r1))
	var far := PackedVector2Array([Vector2(1590, 10), Vector2(1700, 10)])
	_check(not bool((w.call("command", 1, PvpCmd.stroke(far)) as Dictionary).get("ok", true)),
		"штрих за полем — отказ")
	var r2: Dictionary = w.call("command", 1, PvpCmd.plot("s0_a", PvpCmd.BUILD, LegionCfg.KIND_LABORER))
	_check(not bool(r2.get("ok", true)), "стройка на чужой площадке — отказ")
	var r3: Dictionary = w.call("command", 1, PvpCmd.plot("s1_a", PvpCmd.BUILD, LegionCfg.KIND_LABORER))
	_check(bool(r3.get("ok", false)) and _side(1).souls < 500 and _side(0).souls == 500,
		"стройка на своей площадке — души своей стороны")
	var built: LegionBuilding = _side(1).staff.plot_by_id("s1_a")["building"]
	_check(built != null and built.get("side") == 1, "постройка знает сторону")
	_steps(60 * 3)
	var from_b := 0
	for u in w.units:
		if u.home == built:
			from_b += 1
			_check(u.side == 1, "боец постройки стороны 1 — стороны 1")
			break
	_check(from_b > 0, "постройка выпускает бойцов")
	# свои бойцы встают в строй своего договора и срываются рогаткой через API
	for i in 8:
		_unit(LegionCfg.KIND_LABORER, Vector2(400 + 6 * i, 330), 0)
	_steps(60 * 4)
	_check(c0 != null and c0.manned_posts() >= 6, "бойцы стороны 0 встали в строй: %d" % (c0.manned_posts() if c0 else 0))
	var foe_units := _unit(LegionCfg.KIND_LABORER, Vector2(520, 360), 1)
	_steps(2)
	var charging := 0
	var rs: Dictionary = w.call("command", 0, PvpCmd.sling(c0.id, 0, Vector2(-80, 0)))
	for u in w.units:
		charging += int(u.side == 0 and u.state == Legionnaire.State.CHARGE)
	_check(bool(rs.get("ok", false)) and charging > 0, "рогатка через API — натиск по стрелке: %d в натиске" % charging)
	var rq: Dictionary = w.call("command", 1, PvpCmd.cast(LegionHero.SLOT_Q, Vector2(420, 330)))
	_check(bool(rq.get("ok", false)), "Ку стороны 1 бьёт бойцов стороны 0: %s" % str(rq))
	_check(foe_units != null, "цель натиска на месте")
	var rr: Dictionary = w.call("command", 0, PvpCmd.rally(Vector2(300, 450)))
	_check(rr.has("ok"), "«Сбор» через API отвечает: %s" % str(rr))


# ── 8б. Чужие бойцы не встают на мои договоры ────────────────────────────────

## Поле стороны раздаёт места только бойцам своей стороны, а выпуск линии не трогает чужих
## (дефект «игрок управляет бойцами соперника», 02.10.2026).
func _test_no_cross_control() -> void:
	print("— чужие бойцы не встают на договоры и не бегут в натиск")
	for mine in 2:
		_fresh()
		var foe := 1 - mine
		var base: Vector2 = _side(mine).cauldron_pos
		var dx := 150.0 if mine == 0 else -150.0
		var line := PackedVector2Array()
		for i in 21:
			line.append(Vector2(base.x + dx, base.y - 80.0 + 8.0 * i))
		var arrow := Vector2(base.x + dx * 2.0, base.y)
		var r: Dictionary = w.call("command", mine, PvpCmd.stroke(line, LegionCfg.KIND_LABORER, arrow))
		var c := _side(mine).contracts.by_id(int(r.get("contract", -1)))
		_check(c != null, "сторона %d: договор начерчен" % mine)
		if c == null:
			continue
		var theirs: Array[Legionnaire] = []
		for i in 6:
			theirs.append(_unit(LegionCfg.KIND_LABORER,
				Vector2(base.x + dx + 6.0 * i, base.y - 20.0), foe))
		_steps(60 * 4)
		var foreign_posted := 0
		for u in theirs:
			foreign_posted += int(u.state == Legionnaire.State.POSTED or u.state == Legionnaire.State.MARCH)
		for p in c.posts:
			var pu: Legionnaire = p["unit"]
			foreign_posted += int(pu != null and pu.side != mine)
		_check(foreign_posted == 0, "сторона %d: чужие бойцы на её линии: %d" % [mine, foreign_posted])
		var ours: Array[Legionnaire] = []
		for i in 6:
			ours.append(_unit(LegionCfg.KIND_LABORER,
				Vector2(base.x + dx + 6.0 * i, base.y + 10.0), mine))
		_steps(60 * 4)
		var own_posted := 0
		for u in ours:
			own_posted += int(u.state == Legionnaire.State.POSTED)
		_check(own_posted > 0, "сторона %d: свои бойцы встали на линию: %d" % [mine, own_posted])
		# защита в глубину: чужой, силой посаженный на место, при выпуске освобождается, не бежит
		var intruder: Legionnaire = theirs[0]
		var seg := -1
		for p in c.posts:
			var pu: Legionnaire = p["unit"]
			if pu != null and pu.side == mine and pu.state == Legionnaire.State.POSTED:
				seg = int(p["seg"])
				break
		for p in c.posts:
			if p["unit"] == null and not p["dead"] and int(p["seg"]) == seg:
				intruder.assign(c, p, PackedVector2Array([intruder.position, p["pos"]]))
				intruder.position = p["pos"]
				intruder.state = Legionnaire.State.POSTED
				break
		_check(seg >= 0 and intruder.state == Legionnaire.State.POSTED,
			"сторона %d: чужой подсажен на участок %d" % [mine, seg])
		var pull := Vector2(-80.0 * signf(dx), 0.0)
		w.call("command", mine, PvpCmd.sling(c.id, seg, pull))
		var foreign_charging := 0
		var own_charging := 0
		for u in w.units:
			if u.state == Legionnaire.State.CHARGE:
				if u.side == mine:
					own_charging += 1
				else:
					foreign_charging += 1
		_check(foreign_charging == 0,
			"сторона %d: рогатка не гонит чужих в натиск: %d" % [mine, foreign_charging])
		_check(own_charging > 0, "сторона %d: свои в натиске: %d" % [mine, own_charging])

# ── 9. Бот против бота ──────────────────────────────────────────────────────

func _test_bots() -> void:
	print("— бот против бота: оборона и перебежки")
	_fresh(true, true)
	w.dev.erase("spawn_units")
	w.start_map(DUEL)
	var advanced: Array[bool] = [false, false]
	# Передовой отряд мог погибнуть к последнему тику: проверяем наступление за всё окно,
	# причём группой хотя бы MARCH_MIN, а не одним выжившим ровно на 150-й секунде.
	for _tick in 60 * 150:
		if w.phase != LegionWorld.Phase.BATTLE:
			break
		_steps(1)
		var beyond: Array[int] = [0, 0]
		for u in w.units:
			if u.alive and absf(u.position.x - _side(u.side).cauldron_pos.x) > 450.0:
				beyond[u.side] += 1
		for side in 2:
			advanced[side] = advanced[side] or beyond[side] >= PvpBot.MARCH_MIN
	for i in 2:
		var bot: Variant = _side(i).bot
		_check(bot is PvpBot, "сторона %d играет ботом PvP" % i)
		if not bot is PvpBot:
			continue
		var counts: Dictionary = (bot as PvpBot).counts
		_check(int(counts["defense_lines"]) >= 3, "сторона %d: рубежи обороны: %s" % [i, str(counts)])
		_check(int(counts["leaps"]) >= 2, "сторона %d: перебежки за 150 с: %d" % [i, int(counts["leaps"])])
	_check(advanced[0] and advanced[1],
		"обе армии за 150 с вывели группу дальше 450 px: %s" % str(advanced))
	w.args.erase("pvp_bots")
