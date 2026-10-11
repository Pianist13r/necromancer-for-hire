extends SceneTree
## Предел автомарша (Игорь 11.10.2026 после ночной сборки: «они идут через полкарты всё ещё до
## нарисованной линии»). Резерв у дома (D-1009-C1) сам идёт к пустому месту только в пределах
## LegionCfg.AUTOMARCH_R по прямой (PvP — AUTOMARCH_R_PVP); дальше его берёт только линия рядом
## (RECRUIT_R) или «Сбор». Превью черновика считает тот же план, что бой.
## Итог «LEGION AUTOMARCH CAP: N/M OK»; выход 1 при провале.

const SAVE := "user://legion_automarch_cap_test.cfg"
const MAP := {"size": [1280, 720], "cauldron": [100, 360],
	"plots": [{"id": "b", "pos": [300, 600]}], "start_army": 0}
## Через карту констант, а не LegionCfg.AUTOMARCH_R: тест запускается и падает на коде до правки.
var cfg := (load("res://scripts/legion/legion_cfg.gd") as Script).get_script_constant_map()
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


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	test_far_building_stays()
	test_near_building_marches()
	test_near_recruit_unchanged()
	await test_preview_matches_battle()
	test_pvp_radius_larger()
	finish()


func fresh() -> void:
	w.start_map("_gray", MAP)
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.souls = 1000
	w.contracts.mana = 1000.0


## Бытовка у двери (резерв у дома) и линия по горизонтали на расстоянии dx от входа.
func door_and_line(dx: float) -> Array:
	fresh()
	var b := w.staff.build(w.staff.plots[0], LegionCfg.KIND_LABORER)
	var at_door := w.spawn_unit(LegionCfg.KIND_LABORER, b.entry + Vector2(10, 0), b)
	var x := b.entry.x + dx
	var c := w.contracts.add_contract(PackedVector2Array([
		Vector2(x, b.entry.y - 40), Vector2(x, b.entry.y + 40)]), 1, true, LegionCfg.KIND_LABORER)
	w.grid.rebuild()
	w._assign_free()
	return [at_door, c]


## Главная жалоба 11.10: резерв у дальней постройки уходил через полкарты.
func test_far_building_stays() -> void:
	var pair := door_and_line(700.0)
	var at_door: Legionnaire = pair[0]
	var c: Contract = pair[1]
	check(at_door.state == Legionnaire.State.FREE, "резерв у Бытовки в 700 px от линии сам не идёт "
		+ "(предел %d)" % int(cfg.get("AUTOMARCH_R", 0.0)))
	check(c.posts.all(func(p: Dictionary) -> bool: return p["unit"] == null),
		"места линии за пределом автомарша остались пустыми")


func test_near_building_marches() -> void:
	var pair := door_and_line(300.0)
	var at_door: Legionnaire = pair[0]
	var c: Contract = pair[1]
	check(at_door.state == Legionnaire.State.MARCH and at_door.contract == c and at_door.auto_march,
		"резерв у Бытовки в 300 px идёт сам (автомарш B-344 сохранён)")


## Ближний набор RECRUIT_R не менялся: любой свободный в поле в 180 px идёт, в 240 px — нет.
func test_near_recruit_unchanged() -> void:
	fresh()
	var c := w.contracts.add_contract(PackedVector2Array([
		Vector2(1100, 300), Vector2(1100, 380)]), 1, true, LegionCfg.KIND_LABORER)
	var inside := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(920, 340))
	var outside := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(1100, 620))
	w.grid.rebuild()
	w._assign_free()
	check(inside.state == Legionnaire.State.MARCH and inside.contract == c
		and not inside.auto_march, "боец в поле в 180 px встаёт ближним набором")
	check(outside.state == Legionnaire.State.FREE, "боец в поле в 240 px остаётся (RECRUIT_R 200)")


## Превью и бой — один план: за пределом резерв не подсвечен и не идёт; в пределах — и то и то.
func test_preview_matches_battle() -> void:
	for case: Array in [[1000.0, false], [480.0, true]]:
		var x: float = case[0]
		var comes: bool = case[1]
		w.start_map("_gray", MAP)
		w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
		w.contracts.active = true
		w.contracts.human_input = true
		w.contracts.mana = 1000.0
		var home := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 360))
		w.grid.rebuild()
		await process_frame
		button(Vector2(x, 260), true)
		for y in range(280, 401, 20):
			motion(Vector2(x, y))
		w.contracts.update_preview()
		var shown := w.contracts._preview_plan.any(
			func(a: Dictionary) -> bool: return a["unit"] == home)
		var places := w.contracts._preview.posts.size() if w.contracts._preview != null else 0
		var caption := w.contracts.preview_caption(places)
		print("DIARY x=%d caption: %s" % [int(x), caption])
		check(shown == comes, "превью линии в %d px от резерва %s его" % [int(x - 160.0),
			"отмечает" if comes else "не отмечает"])
		check(caption.contains("из дома") == comes, "подпись превью согласована (%s)" % caption)
		button(Vector2(x, 400), false)
		w.grid.rebuild()
		w._assign_free()
		check(w.contracts.contracts.size() == 1
			and (home.state == Legionnaire.State.MARCH) == comes,
			"после отпускания резерв %s, как показало превью" % ("пошёл" if comes else "остался"))


## «Схватка»: поле 1600×900, предел больше — резерв у Котла доходит до своей половины фронта.
func test_pvp_radius_larger() -> void:
	check(float(cfg.get("AUTOMARCH_R_PVP", 0.0)) > float(cfg.get("AUTOMARCH_R", INF)),
		"предел PvP больше одиночного")
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.start_map(PvpMaps.DUEL)
	# линия у верхнего прохода стыка (x < 770 — своя половина): 585–613 px от резерва, между
	# одиночным пределом и пределом «Схватки»
	var home_at := w.cauldron_of(0) + Vector2(30, 0)
	var pts := PackedVector2Array([Vector2(760, 200), Vector2(760, 280)])
	var near := home_at.distance_to(pts[1])
	check(near > float(cfg.get("AUTOMARCH_R", INF)),
		"линия PvP-проверки (%d px) дальше одиночного предела" % int(near))
	var c := w.contracts.add_contract(pts, 1, true, LegionCfg.KIND_LABORER)
	var home := w.spawn_unit(LegionCfg.KIND_LABORER, home_at, null, 0)
	w.grid.rebuild()
	w._assign_free()
	check(c != null and home.state == Legionnaire.State.MARCH and home.auto_march,
		"PvP: резерв у Котла идёт к линии в %d px" % int(near))


func screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * w.world_to_screen(p)


func button(at: Vector2, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = screen(at)
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	ev.pressed = down
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func motion(at: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = screen(at)
	ev.global_position = ev.position
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func finish() -> void:
	Campaign.reset()
	print("LEGION AUTOMARCH CAP: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
