extends SceneTree
##
## Самопроверка пакета staff (docs/legion/DESIGN_V15.md §5, §12 п.4, п.5, п.11):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_staff_test.gd -- --mute
##
## Итог «LEGION STAFF: N/M OK»; код выхода 1, если что-то упало. Мир настоящий (карта _plots:
## копия _gray + 4 участка, волны выключены). Штат тикается напрямую (w.staff.tick) — без боя,
## чтобы таймеры мерились точно. Кампания — нейтральная (compat-путь мира), сохранение — во
## временном файле.
##

const SAVE := "user://legion_staff_test.cfg"
const MAP := "_plots"
const DT := 0.01

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
	w.set_process(false)
	_test_start_staff()
	_test_respawn_timers()
	_test_build_upgrade_sell()
	_test_hard_cap()
	_test_souls()
	_test_campaign_stats()
	_test_map_respawn()
	_test_brisk_building()
	_test_menu()
	_test_bot_builds()
	Campaign.reset()
	print("LEGION STAFF: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh(army := -1) -> void:
	w.dev["no_waves"] = "1"
	if army >= 0:
		w.dev["spawn_units"] = str(army)
	else:
		w.dev.erase("spawn_units")
	w.start_map(MAP)
	w.dev_invuln = false


func _tick(seconds: float) -> void:
	for i in roundi(seconds / DT):
		w.now += DT
		w.staff.tick(DT)
		w._cleanup(DT)


func _home_units(b: LegionBuilding) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in w.units:
		if u.alive and u.home == b:
			out.append(u)
	return out


func _test_start_staff() -> void:
	_fresh()
	# D-0927-49: штат карты × STAFF_PACE, возрождение × RESPAWN_PACE — числа из констант
	var start := LegionStaff.paced(int(w.map["start_army"]))
	var c := w.staff.cauldron
	_check(c != null and c.kind == LegionCfg.KIND_LABORER and c.cap == start
			and is_equal_approx(c.respawn_t, LegionCfg.CAULDRON_RESPAWN),
		"Котёл — постройка подрядчиков со штатом start_army (%d) и возрождением %.0f с" % [start,
		LegionCfg.CAULDRON_RESPAWN])
	_check(w.army_alive() == start and c.alive_count() == start and w.wave_runner.wave_no() == 0,
		"стартовый штат выдан целиком до первой волны")
	_check(w.staff.plots.size() == 4 and w.buildings.size() == 1,
		"участки карты прочитаны, постройка пока одна — Котёл")
	_check(w.souls == LegionCfg.SOULS_START, "стартовые души 60")
	_check(w.effective_army_cap() == start, "потолок армии — сумма штатов")


## Индивидуальные таймеры мест: двое павших с разницей 3 с возвращаются с разницей 3 с.
func _test_respawn_timers() -> void:
	_fresh(10)
	var c := w.staff.cauldron
	var squad := _home_units(c)
	var spawned: Array[float] = []
	var on_spawn := func(u: Legionnaire) -> void:
		if u.home == c:
			spawned.append(w.now)
	w.unit_spawned.connect(on_spawn)
	squad[0].take_damage(1000.0, squad[0].position)
	var t0 := w.now
	# D-0927-49: интервал Котла — CAULDRON_RESPAWN (6 с × RESPAWN_PACE); зазоры проверки прежние
	var rt := LegionCfg.CAULDRON_RESPAWN
	_tick(3.0)
	squad[1].take_damage(1000.0, squad[1].position)
	_tick(rt - 3.0 + 0.5)
	_check(spawned.size() == 1 and absf(spawned[0] - t0 - rt) < 0.05,
		"первый павший вернулся через respawn_t %.0f с (%.2f)" % [rt,
		spawned[0] - t0 if spawned.size() > 0 else -1.0])
	_tick(3.0)
	_check(spawned.size() == 2 and absf(spawned[1] - spawned[0] - 3.0) < 0.05,
		"второй — ровно на 3 с позже (свой таймер места)")
	_check(c.alive_count() == 10 and w.army_alive() == 10, "штат снова полный")
	var back := _home_units(c)
	_check(back.size() == 10 and back[back.size() - 1].position.distance_to(w.cauldron_pos) < 120.0,
		"возрождённый боец выходит у хозяина (Котла)")
	w.unit_spawned.disconnect(on_spawn)


func _test_build_upgrade_sell() -> void:
	_fresh(0)
	var st := w.staff
	var plot := st.plot_at(Vector2(302, 252))
	_check(not plot.is_empty() and plot["id"] == "p2", "участок находится tap-радиусом 28 px")
	_check(st.plot_at(Vector2(340, 250)).is_empty(), "дальше 28 px участка нет")
	var b := st.build(plot, LegionCfg.KIND_LABORER)
	_check(b != null and w.souls == 20 and plot["building"] == b and w.buildings.has(b),
		"Бытовка за 40 душ (осталось %d)" % w.souls)
	_check(st.build(st.plot_at(Vector2(300, 470)), LegionCfg.KIND_GUARD) == null and w.souls == 20,
		"на Проходную (60) душ не хватает — не строится")
	_tick(0.05)
	_check(b.alive_count() == 1, "первый боец выходит сразу")
	_tick(0.4)
	_check(b.alive_count() == 2, "дальше — по бойцу раз в 0,4 с")
	# D-0927-49: штат Бытовки × STAFF_PACE (10 → 8), заполнение по 0,4 с прежнее
	var cap1 := LegionStaff.paced(10)
	var cap2 := LegionStaff.paced(15)
	_tick(0.4 * (cap1 - 2) + 0.2)
	_check(b.alive_count() == cap1 and b.cap == cap1, "весь штат %d — по 0,4 с" % cap1)
	# с 26.09.2026 — веером перед дверью, а не в точке входа (стопка под печатью нотариуса)
	var door := _home_units(b)[0].position
	_check(door.distance_to(b.entry) <= LegionCfg.BUILDING_ENTRY_RING.y + 0.5
			and door.y >= b.entry.y - 0.5, "боец рождается у входа постройки, перед дверью")
	w.souls = 60
	_check(st.upgrade(b) and b.level == 2 and b.cap == cap2 and w.souls == 0
			and is_equal_approx(b.respawn_t, 6.0 * LegionCfg.RESPAWN_PACE),
		"улучшение до ур. 2 за 60: штат %d, возрождение 6 с × темп" % cap2)
	_tick(0.3)
	_check(b.alive_count() == cap1 + 1, "новые места улучшения тоже по 0,4 с")
	_tick(0.4 * (cap2 - cap1) + 0.2)
	_check(b.alive_count() == cap2, "улучшение добавило %d мест" % (cap2 - cap1))
	var army := w.army_alive()
	var back := st.sell(b)
	_check(back == 50 and w.souls == 50, "продажа — 50 %% вложенного (40+60 → %d)" % back)
	_tick(0.1)
	_check(w.army_alive() == army - cap2 and plot["building"] == null and not w.buildings.has(b),
		"бойцы проданной постройки гибнут, места исчезли")
	_tick(12.0 * LegionCfg.RESPAWN_PACE)
	_check(w.army_alive() == army - cap2, "проданные не возрождаются")


func _test_hard_cap() -> void:
	_fresh(200)
	_check(w.army_alive() == LegionCfg.ARMY_HARD_CAP, "стартовый штат 200 режется потолком 180")
	w.souls = 1000
	var b := w.staff.build(w.staff.plots[0], LegionCfg.KIND_LABORER)
	_tick(6.0)
	_check(w.army_alive() == LegionCfg.ARMY_HARD_CAP and b.alive_count() == 0,
		"сверх 180 постройка не выпускает")
	w.units[0].take_damage(1000.0, Vector2.ZERO)
	_tick(0.5)
	_check(w.army_alive() == LegionCfg.ARMY_HARD_CAP, "освободилось место — занято снова до 180")


func _test_souls() -> void:
	_fresh(0)
	var s0 := w.souls
	var at := Vector2(760, 130)
	var z := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	z.take_damage(1000.0, at)
	_check(w.souls == s0 + 3 and int(w.stats["kills_rewardable"]) == 1, "зомби (инспектор) — 3 души")
	var sig := w.spawn_foe_on_path("signer", PackedVector2Array([at]), at)
	sig.take_damage(1000.0, at)
	_check(w.souls == s0 + 8, "нотариус — 5 душ")
	var esc := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at, true)
	esc.take_damage(1000.0, at)
	_check(w.souls == s0 + 8 and int(w.stats["kills_rewardable"]) == 2
			and int(w.stats["kills"]) == 3,
		"призванный (свита) душ не даёт и не идёт в kills_rewardable")
	w.on_wave_cleared(0)
	_check(w.souls == s0 + 8 + LegionCfg.SOULS_WAVE, "отбитая волна +15")
	_check(w.final_stats(true).has("kills_rewardable"), "kills_rewardable в итоговой статистике")


func _test_campaign_stats() -> void:
	w.staff.stat_fn = func(key: StringName) -> float:
		match String(key):
			"cap_mult_laborer":
				return 1.5
			"respawn_mult_laborer":
				return 0.5
			"start_souls":
				return 30.0
			"kind_unlocked_clerk":
				return 0.0
		return 1.0 if Campaign.is_mult_key(key) or String(key).contains("_unlocked_") else 0.0
	_fresh(20)
	var c := w.staff.cauldron
	_check(c.cap == 30 and is_equal_approx(c.respawn_t, 3.0 * LegionCfg.RESPAWN_PACE)
			and w.army_alive() == 30,
		"штат ×cap_mult, возрождение ×respawn_mult (Котёл 20→30, 6→3 с, × темп D-0927-49)")
	_check(w.souls == 90, "старт душ 60 + start_souls")
	w.souls = 500
	var b := w.staff.build(w.staff.plots[0], LegionCfg.KIND_LABORER)
	var cap_b := roundi(LegionStaff.paced(10) * 1.5)   # штат × темп × cap_mult
	_check(b.cap == cap_b and is_equal_approx(b.respawn_t, 4.0 * LegionCfg.RESPAWN_PACE),
		"поправки вида и для Бытовки (%d, 4 с × темп)" % cap_b)
	_check(not w.staff.kind_unlocked(LegionCfg.KIND_CLERK)
			and w.staff.build(w.staff.plots[1], LegionCfg.KIND_CLERK) == null,
		"закрытый вид (kind_unlocked_clerk 0) не строится")
	w.staff.stat_fn = Callable()


func _test_map_respawn() -> void:
	_fresh(0)
	w.staff.stat_fn = func(key: StringName) -> float:
		if key == &"respawn_mult_laborer":
			return 0.5
		return 1.0 if Campaign.is_mult_key(key) or String(key).contains("_unlocked_") else 0.0
	w.staff.setup(w, {"cauldron_respawn": 18.0}, 2)
	var c := w.staff.cauldron
	_check(is_equal_approx(c.respawn_t, 9.0), "интервал Котла карты умножается на мету: 18→9 с")
	_home_units(c)[0].take_damage(1000.0, Vector2.ZERO)
	_tick(8.5)
	_check(c.alive_count() == 1, "раннее возрождение по прежним 6 с запрещено")
	_tick(0.6)
	_check(c.alive_count() == 2, "место возвращается по интервалу карты с поправкой меты")
	w.staff.stat_fn = Callable()


## «Бодрый выход» как перк героя удалён (D-1006-11), но механизм постройки (brisk_exit) сохранён —
## проверяем его напрямую по флагу: вернувшийся боец +25 % скорости на 3 с, потом обычная.
func _test_brisk_building() -> void:
	_fresh(2)
	var c := w.staff.cauldron
	c.brisk_exit = true
	var base := float(LegionCfg.UNIT_KINDS[LegionCfg.KIND_LABORER]["speed"])
	_home_units(c)[0].take_damage(1000.0, Vector2.ZERO)
	_tick(LegionCfg.CAULDRON_RESPAWN + 0.05)   # D-0927-49: интервал × RESPAWN_PACE
	var fresh: Legionnaire = null
	for u in _home_units(c):
		if not is_equal_approx(float(u.spec["speed"]), base):
			fresh = u
	var boosted := fresh != null and is_equal_approx(float(fresh.spec["speed"]),
		base * LegionCfg.BRISK_EXIT_MULT)
	_check(boosted, "«Бодрый выход» постройки: вернувшийся +25 % скорости")
	_tick(LegionCfg.BRISK_EXIT_TIME + 0.1)
	_check(fresh != null and fresh.spec == LegionCfg.UNIT_KINDS[LegionCfg.KIND_LABORER],
		"через 3 с скорость обычная")


func _mouse(at: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = at
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	w.contracts._unhandled_input(ev)


func _move(at: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = at
	w.contracts._unhandled_input(mv)


func _click(at: Vector2) -> void:
	_mouse(at, true)
	_mouse(at, false)


func _test_menu() -> void:
	_fresh(0)
	var m := w.plot_menu
	var p1: Dictionary = w.staff.plots[0]
	var pos: Vector2 = p1["pos"]
	w.souls = 50
	_click(pos + Vector2(10, 10))
	_check(m.is_open() and m.plot == p1, "tap у участка открывает меню")
	var btns := m.buttons()
	_check(btns.size() == 3 and not btns[0].disabled and btns[1].disabled and btns[2].disabled,
		"меню: три вида; на 50 душ Бытовка доступна, Проходная/Бухгалтерия серые")
	var n0 := w.contracts.contracts.size()
	var mana0 := w.contracts.mana
	_click(Vector2(640, 600))
	_check(not m.is_open() and not w.contracts.has_draft() and w.contracts.contracts.size() == n0
			and w.contracts.mana == mana0,
		"клик мимо закрывает меню и больше ничего не делает")
	_click(pos)
	var p2: Dictionary = w.staff.plots[1]
	_click(p2["pos"])
	_check(not m.is_open(), "закрывающий клик по другому участку съеден (меню не открылось)")
	_click(pos)
	var from := Vector2(640, 500)
	_mouse(from, true)
	for i in range(1, 11):
		_move(from + Vector2(0, 6.0 * i))
	_check(not m.is_open() and w.contracts.has_draft(), "протяжка мимо меню закрывает его и рисует")
	_mouse(from + Vector2(0, 60), false)
	_click(pos)
	var esc := InputEventAction.new()
	esc.action = &"pause"
	esc.pressed = true
	m._input(esc)
	_check(not m.is_open() and not w.paused, "Esc закрывает меню, не ставя паузу")
	_click(pos)
	m.buttons()[0].pressed.emit()
	var b: LegionBuilding = p1["building"]
	_check(not m.is_open() and b != null and b.kind == LegionCfg.KIND_LABORER and w.souls == 10,
		"кнопка «Бытовка» строит и закрывает меню")
	w.souls = 200
	_click(pos)
	btns = m.buttons()
	# D-0927-135: между «Улучшить» и «Продать» — срочный найм (все на местах — закрыт)
	_check(btns.size() == 3 and btns[0].text.contains("Улучшить")
		and btns[1].text.contains("Срочный найм") and btns[1].disabled
		and btns[2].text.contains("+20"),
		"меню постройки: улучшить / срочный найм / продать за 20")
	btns[0].pressed.emit()
	_check(b.level == 2 and w.souls == 140, "улучшение из меню")
	_click(pos)
	m.buttons()[2].pressed.emit()
	_check(p1["building"] == null and w.souls == 190, "продажа из меню (+50)")


func _test_bot_builds() -> void:
	_fresh(0)
	var bot := LegionBot.new()
	bot.setup(w, &"selective", w.map)
	w.souls = 50
	bot._build_step()
	var top: Dictionary = w.staff.plots[0]
	_check(top["building"] == null and w.souls == 50, "бот копит на участок с высшим приоритетом")
	w.souls = 60
	bot._build_step()
	_check(top["building"] != null and (top["building"] as LegionBuilding).kind == LegionCfg.KIND_GUARD,
		"бот ставит первый вид из preferred_kinds (Проходная на p1)")
	w.souls = 1000
	for i in 3:
		bot._build_step()
	var built := 0
	for p in w.staff.plots:
		if p["building"] != null:
			built += 1
	_check(built == 4 and w.souls == 1000 - 40 - 60 - 40, "бот застраивает все участки по приоритету")
	bot._build_step()
	_check((top["building"] as LegionBuilding).level == 2, "затем улучшает приоритетный участок")
