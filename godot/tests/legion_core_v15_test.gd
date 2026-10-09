extends SceneTree
## Приёмка core v15: настоящий мир, изолированное сохранение, управляемое время.

const SAVE := "user://legion_core_v15_test.cfg"
var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", text])


func fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.dev_invuln = false
	w.contracts.active = true


func line_at(at: Vector2, kind := LegionCfg.KIND_LABORER, length := 96.0) -> Contract:
	return w.contracts.add_contract(PackedVector2Array([at, at + Vector2(0, length)]), 1, false, kind)


func man(c: Contract, seg := 0) -> Array[Legionnaire]:
	var units: Array[Legionnaire] = []
	for p in c.posts:
		if int(p["seg"]) != seg:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		units.append(u)
	return units


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	root.size = Vector2i(1280, 720)
	await process_frame
	test_recruit()
	test_river()
	test_free()
	test_input()
	test_package()
	test_settlement_aura()
	test_shield()
	test_price_preview()
	test_idle_badge()
	test_performance()
	if OS.get_cmdline_user_args().has("--core-shots"):
		await capture()
	print("LEGION CORE V15: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func test_recruit() -> void:
	fresh()
	var c := line_at(Vector2(500, 100), LegionCfg.KIND_LABORER, 400)
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(280, 120))
	# D-1009-C1: автомарш — только резерв у дома; ставим Котёл рядом с бойцом
	w.cauldron_pos = Vector2(280, 170)
	w.grid.rebuild()
	check(w.contracts.assignment_plan(w.contracts.contracts).is_empty(),
		"ближний набор и превью по-прежнему ограничены радиусом")
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH and u.auto_march, "вне 200 px включается автомарш")
	u.set_free()
	u.position.x = 320
	for p in c.posts:
		if (p["pos"] as Vector2).y < 400:
			p["dead"] = true
	check(w.contracts.assignment_plan(w.contracts.contracts).is_empty(),
		"близкая мёртвая геометрия не расширяет радиус ближнего набора")
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH and u.auto_march and u.post["pos"].y >= 400,
		"автомарш выбирает только живое дальнее место")
	u.set_free()
	for p in c.posts:
		p["dead"] = false
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH and u.position.distance_to(u.post["pos"]) <= 200,
		"выбрано ближайшее достижимое место в радиусе")
	u.position.x = 100
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH and u.contract == c, "назначение сохраняется за радиусом")
	w.release_segment(c, int(u.post["seg"]), &"melt")
	check(u.state == Legionnaire.State.FREE, "исчез участок на марше — свободен")
	for s in range(1, c.seg_count()):
		w.release_segment(c, s, &"manual")
	u.position = Vector2(490, 120)
	w._assign_free()
	check(u.state == Legionnaire.State.FREE and not w.contracts.nearby_kind(u.position, u.kind),
		"мёртвая геометрия не набирает и не лечит")


func test_river() -> void:
	fresh()
	w.terrain = LegionTerrain.new().setup({"water": [[[608, 0], [672, 0], [672, 740], [608, 740]]]})
	line_at(Vector2(720, 200))
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(550, 220))
	w.grid.rebuild()
	w._assign_free()
	var queries := w.contracts.path_queries
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "река без перехода — не набор")
	check(w.contracts.path_queries == queries, "недостижимость кэширована")
	w.terrain = LegionTerrain.new().setup({"water": [[[608, 0], [672, 0], [672, 740], [608, 740]]],
		"bridges": [[[600, 320], [680, 320], [680, 384], [600, 384]]]})
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH and u._path.size() > 3, "мост — марш в обход реки")


func test_free() -> void:
	fresh()
	var at := Vector2(500, 300)
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, at)
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at + Vector2(55, 0)]), at + Vector2(55, 0))
	w.grid.rebuild()
	u.tick(3.0)
	check(u.position == at and f.hp == f.max_hp, "свободный не гонится за врагом в 55 px")
	check(u.idle_time >= 2 and u.idle_reason == &"no_contract", "простой: нет своего договора")
	f.position = at + Vector2(30, 0)
	w.grid.rebuild()
	u.tick(1.0)
	check(f.hp < f.max_hp and u.position == at, "в досягаемости бьёт с места")
	var c := line_at(at + Vector2(100, 0))
	man(c)
	u._aura_t = 0
	u.tick(0.1)
	check(u.idle_reason == &"no_places", "простой: рядом свой договор")


func key(pressed: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = KEY_SPACE
	e.pressed = pressed
	w.contracts._unhandled_input(e)


func move(at: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = at
	w.contracts._unhandled_input(e)


func test_input() -> void:
	fresh()
	var field := w.contracts
	field.begin(Vector2(400, 200))
	field.extend(Vector2(400, 300))
	key(true)
	move(Vector2(523, 327))
	var wanted := Vector2(123, 77).normalized()
	check(field._draft_dir.is_equal_approx(wanted) and field._draft_len == 100,
		"Пробел: произвольный угол, перо стоит")
	key(false)
	move(Vector2(600, 400))
	check(field._draft_len == 100 and field._pen_wait, "отпускание ждёт возврата к перу")
	move(Vector2(400, 305))
	move(Vector2(400, 320))
	field.finish()
	var c := field.contracts[0]
	check(c.dir.is_equal_approx(wanted) and c.length == 120, "продолжение после возврата и сохранение dir")
	move(c.seg_center(0))
	key(true)
	move(c.point_at(c.length * 0.5) + Vector2(-71, 29))
	key(false)
	check(c.dir.is_equal_approx(Vector2(-71, 29).normalized()), "живой договор перенацелен через ввод")
	var positions: Array[Vector2] = []
	for p in c.posts:
		positions.append(p["pos"])
	c.flip_dir()
	var rows_ok := true
	for i in c.posts.size():
		var p := c.posts[i]
		rows_ok = rows_ok and p["pos"] == positions[i]
		rows_ok = rows_ok and (int(p["row"]) == 0) == ((p["offset"] as Vector2).dot(c.dir) >= 0)
	check(rows_ok, "передний ряд следует dir без перемещения мест")
	var previous := c.dir
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = c.seg_center(0)
	field._unhandled_input(wheel)
	check(c.dir == previous, "колесо не меняет стрелку")
	field.unlocked[LegionCfg.KIND_CLERK] = false
	check(not field.set_kind(LegionCfg.KIND_CLERK), "закрытый вид нельзя выбрать")


func test_package() -> void:
	fresh()
	var a := line_at(Vector2(500, 250))
	var b := line_at(Vector2(550, 250), LegionCfg.KIND_GUARD)
	var squad := man(a)
	man(b)
	w.contracts.tick_packages(1.9)
	check(not w.contracts.in_package(a, 0), "пакет требует 2 секунды")
	w.contracts.tick_packages(0.1)
	check(w.contracts.in_package(a, 0) and w.contracts.in_package(b, 0), "пакет собран")
	var u := squad[0]
	var hp := u.hp
	u.take_damage(10, u.position - a.dir * 20)
	check(is_equal_approx(hp - u.hp, 8.5), "пакет даёт ×0,85 входящего урона")
	a.refresh_segments(PackedInt32Array([0]))
	check(w.contracts.seal_ready(a, 0), "продлённый пакет готов к печати")
	w.release_segment(a, 0, &"melt")
	check(u._seal_t == LegionCfg.SEAL_TIME and a.release_causes[0] == &"melt", "таяние выдаёт печать")
	check(not w.contracts.in_package(b, 0), "пакет развалился сразу после выпуска соседа")
	var foe := w.spawn_foe_on_path("zombie", PackedVector2Array([u.position]), u.position + Vector2(20, 0))
	u._atk_cd = 0
	u._strike(foe, 1.0)
	check(is_equal_approx(foe.hp, foe.max_hp - 6 * 1.25) and foe.seal_slow_t == 2,
		"первый удар печати ×1,25 и замедление 30% на 2 с")
	u._atk_cd = 0
	u._strike(foe, 1.0)
	check(is_equal_approx(foe.hp, foe.max_hp - 6 * 2.25), "печать расходуется одним ударом")
	check(not u.grant_seal(), "повторная печать не раньше 8 с")
	fresh()
	a = line_at(Vector2(500, 250))
	b = line_at(Vector2(550, 250), LegionCfg.KIND_GUARD)
	squad = man(a)
	var guards := man(b)
	w.contracts.tick_packages(2.0)
	a.refresh_segments(PackedInt32Array([0]))
	w.contracts.release(a, 0)
	check(squad[0]._seal_t == 0 and squad[0].hp == 30, "ПКМ не выдаёт печать и расчёт")
	check(guards[0]._seal_t == 0, "сосед не получает чужую печать")
	fresh()
	a = line_at(Vector2(500, 250))
	b = line_at(Vector2(550, 250), LegionCfg.KIND_GUARD)
	squad = man(a)
	guards = man(b)
	w.contracts.tick_packages(2.0)
	check(not w.contracts.seal_ready(a, 0), "без продления пакет не готов к печати")
	for i in range(2, guards.size()):
		guards[i].take_damage(1000, guards[i].position)
	check(not w.contracts.in_package(a, 0), "потеря строевых сразу снимает пакет")
	w.contracts.tick_packages(0.1)
	a.refresh_segments(PackedInt32Array([0]))
	w.release_segment(a, 0, &"melt")
	check(squad[0]._seal_t == 0, "без занятого соседа естественный выпуск не даёт печать")
	squad[0].grant_seal()
	squad[0].tick(LegionCfg.SEAL_TIME)
	check(squad[0]._seal_t == 0, "неиспользованная печать истекает через 3 с")


func test_settlement_aura() -> void:
	for kind in LegionCfg.KIND_ORDER:
		fresh()
		var c := line_at(Vector2(500, 200), kind)
		var u := man(c)[0]
		var base := float(u.spec["hp"])
		u.hp = base * 0.5
		c.refresh_segments(PackedInt32Array([0]))
		w.contracts.settlement_mult = 1.25
		w.release_segment(c, 0, &"melt")
		check(is_equal_approx(u.hp, base * 1.75), "расчёт по базовому HP %s и множителю" % kind)
		u.settle(2.0)
		check(is_equal_approx(u.hp, base * 2), "потолок расчёта %s" % kind)
	fresh()
	line_at(Vector2(500, 200))
	var lab := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(450, 200))
	var guard := w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(450, 240))
	lab.hp = 10
	guard.hp = 10
	w.contracts.aura_enabled = true
	lab.tick(1.0)
	guard.tick(1.0)
	# 29.09 (D-0929-01) LINE_AURA_REGEN 1,0 → 0,5: ждём число из конфига, а не прежнюю единицу
	var healed := 10.0 + LegionCfg.LINE_AURA_REGEN
	check(is_equal_approx(lab.hp, healed) and guard.hp == 10, "соцпакет лечит только свой вид")
	w.contracts.aura_enabled = false
	lab.tick(1.0)
	check(is_equal_approx(lab.hp, healed), "соцпакет выключается флагом")
	w.contracts.aura_enabled = true
	lab.assign(w.contracts.contracts[0], w.contracts.contracts[0].posts[0])
	lab.tick(0.1)
	check(is_equal_approx(lab.hp, healed), "соцпакет не лечит на марше")


func test_shield() -> void:
	fresh()
	var at := Vector2(650, 300)
	var foe := w.spawn_foe_on_path("shield_inspector", PackedVector2Array([at, at + Vector2.LEFT * 100]), at)
	foe.take_damage(10, at + Vector2.LEFT * 50, true)
	check(foe.hp == 66, "щитоносец спереди получает ×0,4 от снаряда")
	foe.take_damage(10, at + Vector2.UP * 50, true)
	check(foe.hp == 56, "щитоносец с фланга получает ×1 от снаряда")
	foe.take_damage(10, at + Vector2.LEFT * 50)
	check(foe.hp == 46, "щит не защищает от рукопашной")
	var clerk := w.spawn_unit(LegionCfg.KIND_CLERK, at + Vector2.LEFT * 100)
	clerk.grant_seal()
	clerk._strike(foe, 1.0)
	w.projectiles.tick(1.0)
	check(is_equal_approx(foe.hp, 43.5) and foe.seal_slow_t == 2, "настоящий снаряд учитывает щит и печать")
	check(LegionCfg.SIGNER_WARN == 1.0, "предупреждение нотариуса 1 секунда")


func test_price_preview() -> void:
	fresh()
	var field := w.contracts
	var c := line_at(Vector2(500, 200), LegionCfg.KIND_LABORER, 70)
	var m := field.mana
	field.refresh(c, PackedInt32Array([1, 1]), true)
	check(is_equal_approx(m - field.mana, 6 * c.mana_per_px()), "бот платит за реальную длину хвоста один раз")
	m = field.mana
	# v18: колесо листает вид договора, а test_arrow выше крутит колесо — вид надо задать явно
	field.set_kind(LegionCfg.KIND_LABORER)
	field.begin(Vector2(500, 264))
	field.extend(Vector2(500, 270))
	field.finish()
	check(is_equal_approx(m - field.mana, 6 * c.mana_per_px()), "человек платит столько же за тот же штрих")
	field.set_kind(LegionCfg.KIND_GUARD)
	field.begin(Vector2(550, 200))
	field.extend(Vector2(550, 300))
	var guard := w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(450, 210))
	w.grid.rebuild()
	field.update_preview()
	check(field._preview_plan.size() == 1 and field._preview_plan[0]["unit"] == guard,
		"черновик подсвечивает назначаемого бойца")
	field.finish()
	w._assign_free()
	check(guard.state == Legionnaire.State.MARCH, "прогноз совпал с набором")


## polish1 (ревью 25.09.2026): значок простоя core — раньше висел над КАЖДЫМ бойцом, включая
## толпу у Котла в начале боя, когда ни один договор ещё не начерчен (простой там ожидаемый,
## не проблема), и не группировался в кластере. Проверяем сами условия (`_draw()` рисует только
## Canvas — тут смотрим на функции-условия, не на пиксели).
func test_idle_badge() -> void:
	fresh()
	var a := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(500, 300))
	var b := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(510, 300))   # 10 px — тот же кластер
	var c := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(700, 300))   # далеко — свой кластер
	w.grid.rebuild()
	a.tick(3.0)
	b.tick(3.0)
	c.tick(3.0)
	check(a.idle_time >= LegionCfg.IDLE_NOTICE_TIME and a.idle_reason == &"no_contract",
		"простаивает достаточно долго — условие таймера как раньше")
	check(not a._idle_worth_flagging(), "нет ни одного живого договора вида — значок не нужен")
	line_at(Vector2(900, 100), LegionCfg.KIND_LABORER, 60)   # договор далеко от всех троих
	check(a._idle_worth_flagging(), "договор этого вида появился на поле — значок оправдан")
	check(not a._cluster_has_representative(), "a — представитель своего кластера (меньший idx)")
	check(b._cluster_has_representative(), "b рядом с a (10 px < 40 px) — значок за неё рисует a")
	check(not c._cluster_has_representative(), "c далеко (200 px) — свой кластер, значок свой")


func test_performance() -> void:
	fresh()
	for i in 6:
		line_at(Vector2(400 + i * 50, 140), LegionCfg.KIND_LABORER, 400)
	for i in 180:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(360 + i % 12 * 8, 130 + i / 12 * 14))
	w.grid.rebuild()
	var t := Time.get_ticks_usec()
	var plan := w.contracts.assignment_plan(w.contracts.contracts)
	var cold := Time.get_ticks_usec() - t
	var queries := w.contracts.path_queries
	t = Time.get_ticks_usec()
	w.contracts.assignment_plan(w.contracts.contracts)
	var warm := Time.get_ticks_usec() - t
	check(w.contracts.path_queries == queries and plan.size() > 0, "повторная раздача 180 бойцов не вызывает A*")
	print("CORE PERF assignment 180: cold=%d us warm=%d us paths=%d" % [cold, warm, queries])


func capture() -> void:
	fresh()
	var a := line_at(Vector2(560, 300))
	var b := line_at(Vector2(610, 300), LegionCfg.KIND_GUARD)
	man(a)
	man(b)
	w.contracts.tick_packages(2.0)
	a.refresh_segments(PackedInt32Array([0]))
	var idle := w.spawn_unit(LegionCfg.KIND_CLERK, Vector2(380, 420))
	idle.tick(3)
	w.spawn_unit(LegionCfg.KIND_CLERK, Vector2(330, 280))
	var full := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(480, 420))
	man(a, 1)
	full.tick(3)
	w.contracts.set_kind(LegionCfg.KIND_CLERK)
	w.contracts.begin(Vector2(420, 220))
	w.contracts.extend(Vector2(420, 340))
	w.grid.rebuild()
	w.contracts.update_preview()
	w.contracts.set_aiming(true)
	w.contracts.aim_at(Vector2(490, 230))
	w.contracts.set_aiming(false)
	w.hud.tick(1.0)
	w.contracts.queue_redraw()
	w.contracts.overlay.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	var dir := ProjectSettings.globalize_path("res://../batches/v15/core")
	DirAccess.make_dir_recursive_absolute(dir)
	var error := root.get_texture().get_image().save_png(dir.path_join("core_acceptance.png"))
	check(error == OK, "кадр приёмки сохранён окном")
