extends SceneTree
## Регрессы независимого verifier: удержание, выходы, HUD, старые поля снимка.

var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func fresh() -> void:
	w.start_map("_gray")
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.contracts.active = true
	w.contracts.mana = 1000.0


func line_at(x: float) -> Contract:
	return w.contracts.add_contract(
		PackedVector2Array([Vector2(x, 540), Vector2(x, 640)]), 1, true)


func _run() -> void:
	Campaign.set_save_path("user://verifier_1008.cfg")
	Campaign.reset()
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	test_rally()
	test_hold_lifecycle()
	test_plots()
	test_snapshot()
	Campaign.reset()
	print("LEGION VERIFIER 1008: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func test_rally() -> void:
	fresh()
	line_at(1000)
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 440))
	w.grid.rebuild()
	check(w.rally(Vector2(300, 600)) == 1, "ручной Сбор принят")
	for i in 600:
		u.tick(1.0 / 60.0)
	var at := u.position
	w.grid.rebuild()
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "после прибытия Сбор удерживает от автомарша")
	for i in 120:
		u.tick(1.0 / 60.0)
	check(u.position.distance_to(at) < 1.0, "через две секунды боец остаётся у Сбора")
	# Марш не исчезает из суммы армии в HUD.
	var marcher := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 330))
	w.grid.rebuild()
	w._assign_free()
	check(marcher.state == Legionnaire.State.MARCH, "новорождённый всё ещё получает автомарш")
	var hud := LegionHud.new()
	root.add_child(hud)
	hud.setup(w)
	hud.tick(1.0)
	check(hud._stats.text.contains("свободно 2"), "HUD учитывает марш вместе со свободными")
	hud.queue_free()
	fresh()
	line_at(370)
	u = w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 580))
	u.rally_to(PackedVector2Array([u.position]))
	u.tick(0.1)
	w.grid.rebuild()
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "старая ближняя линия не отменяет Сбор")
	line_at(340)
	w.grid.rebuild()
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH, "новая ближняя линия отменяет удержание")


func test_hold_lifecycle() -> void:
	fresh()
	line_at(1000)
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 580))
	u.rally_to(PackedVector2Array([Vector2(300, 600)]))
	u.rally_to(PackedVector2Array([Vector2(320, 600)]))
	check(u._path[-1] == Vector2(320, 600), "новый Сбор заменяет приказ ещё в пути")
	for i in 26 * 60:
		u.tick(1.0 / 60.0)
	w.grid.rebuild()
	w._assign_free()
	# D-1009-C1: игрок поставил бойца в поле — после удержания он стоит, где поставили; у дома
	# автомарш возобновляется (удержание не вечное)
	check(u.state == Legionnaire.State.FREE, "по истечении удержания боец в поле остаётся на месте")
	u.position = w.cauldron_pos + Vector2(60, 40)
	w.grid.rebuild()
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH, "по истечении удержания у дома автомарш возобновляется")
	u.set_free()
	u.rally_to(PackedVector2Array([u.position]))
	u.start_charge(Vector2.RIGHT)
	check(u.held_t == 0.0, "рогатка отменяет удержание")
	u.set_free()
	u.rally_to(PackedVector2Array([u.position]))
	u.tick(0.1)
	var digest := w.net_digest()
	var snap := NetSnap.save(w)
	u.held_t = 0.0
	check(w.net_digest() != digest, "срок удержания входит в digest")
	var reg := NetSnap.load(w, snap)
	u = w.units[0]
	check(reg.errors.is_empty() and w.net_digest() == digest and u.held_t > 0.0,
		"снимок восстанавливает срок удержания и digest")
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "удержание действует после загрузки снимка")


func test_plots() -> void:
	var total := 0
	var warned: Array[String] = []
	for map_id in ["gatehouse", "archive", "bridge", "fork", "maze", "swamp", "wasteland", "boss"]:
		w.start_map(map_id)
		var rng_before := w.rng.state
		for p in w.staff.plots:
			total += 1
			if w.staff.plot_near_road(p):
				warned.append("%s/%s" % [map_id, p["id"]])
		check(w.rng.state == rng_before, "предупреждение не расходует RNG: " + map_id)
	print("PLOTS warnings=%d/%d %s" % [warned.size(), total, warned])
	# B-043: доля безопасных рождений < 50 % (сверено с probe_plots2.log, 1500 настоящих рождений)
	var expected: Array[String] = ["bridge/p5", "bridge/p6", "fork/p2", "fork/p5", "maze/p1",
		"maze/p2", "maze/p3", "maze/p5", "maze/p6", "maze/p7", "swamp/p4", "boss/p1", "boss/p3",
		"boss/p6"]
	check(total == 47 and warned == expected,
		"предупреждение — когда больше половины рождений под удар")


func test_snapshot() -> void:
	check(NetSession.BUILD == "net-2026-10-09a" and NetSnap.VERSION == 5,
		"старый сетевой клиент отделён версией сборки и снимка")
	fresh()
	w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 400))
	var snap := NetSnap.save(w)
	for d: Dictionary in snap["units"]["units"]:
		d.erase("auto_march")
		d.erase("held_t")
	w.units[0].auto_march = true
	w.units[0].held_t = 12.0
	var reg := NetSnap.load(w, snap)
	check(reg.errors.is_empty() and not w.units[0].auto_march and w.units[0].held_t == 0.0,
		"снимок без auto_march загружается со значением false")
	snap["v"] = 4
	reg = NetSnap.load(w, snap)
	check(not reg.errors.is_empty(), "полный снимок старой версии отклонён до изменения мира")
