extends SceneTree
## Управляемость 0.3.1 (Игорь 09.10.2026: «слишком далеко линии забирают скелетов… очень часто не те
## скелеты, которых ты хотел, идут»). Автомарш B-344 берёт только резерв у дома (Котёл, постройки),
## ближний резерв — первым; боец в поле слушается только линии рядом и «Сбора»; превью черновика
## показывает и тех, кто придёт из дома.

const SAVE := "user://legion_control_1009_test.cfg"
const MAP := {"size": [1280, 720], "cauldron": [100, 360],
	"plots": [{"id": "b", "pos": [700, 600]}], "start_army": 0}
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
	test_field_veteran_stays()
	test_home_reserve_marches()
	test_nearest_reserve_first()
	test_near_line_still_recruits()
	test_crypt_is_home()
	test_preview_counts_rally()
	await test_preview_counts_reserve()
	finish()


func fresh() -> Contract:
	w.start_map("_gray", MAP)
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.souls = 1000
	w.contracts.mana = 1000.0
	return w.contracts.add_contract(PackedVector2Array([
		Vector2(1100, 300), Vector2(1100, 380)]), 1, true, LegionCfg.KIND_LABORER)


## Главная жалоба: боец, которого игрок оставил в поле (после натиска, Сбора, растаявшей линии),
## не должен бежать через полкарты к линии, нарисованной далеко от него.
func test_field_veteran_stays() -> void:
	var c := fresh()
	var vet := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(600, 200))
	w.grid.rebuild()
	w._assign_free()
	check(vet.state == Legionnaire.State.FREE,
		"боец в поле не уходит к дальней линии (в 500 px)")
	check(c.posts.all(func(p: Dictionary) -> bool: return p["unit"] == null),
		"места дальней линии остались пустыми")


func test_home_reserve_marches() -> void:
	var c := fresh()
	var home := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 360))
	var b := w.staff.build(w.staff.plots[0], LegionCfg.KIND_LABORER)
	var at_door := w.spawn_unit(LegionCfg.KIND_LABORER, b.entry + Vector2(20, 10), b)
	w.grid.rebuild()
	w._assign_free()
	check(home.state == Legionnaire.State.MARCH and home.contract == c and home.auto_march,
		"резерв у Котла сам идёт на дальнюю линию (удобство 0.3.0 сохранено)")
	check(at_door.state == Legionnaire.State.MARCH and at_door.auto_march,
		"резерв у Бытовки сам идёт на дальнюю линию")


## Мест меньше, чем резерва: идёт ближний к линии, а не первый по порядку рождения.
func test_nearest_reserve_first() -> void:
	var c := fresh()
	for i in range(1, c.posts.size()):
		c.posts[i]["dead"] = true
	var far := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(40, 360))     # родился первым
	var near := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(230, 360))
	w.grid.rebuild()
	w._assign_free()
	check(near.state == Legionnaire.State.MARCH, "единственное место взял ближний резерв")
	check(far.state == Legionnaire.State.FREE, "дальний резерв остался дома")


## Ближний набор (радиус RECRUIT_R) работает для любого свободного, как до 0.3.0.
func test_near_line_still_recruits() -> void:
	fresh()
	var vet := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(960, 340))
	w.grid.rebuild()
	w._assign_free()
	check(vet.state == Legionnaire.State.MARCH and not vet.auto_march,
		"боец в поле в 140 px от линии встаёт в неё ближним набором")


## Склеп — тоже дом (его постройка — дочерний узел с нулевой локальной позицией; verifier 09.10
## поймал, что домом считался угол карты (0, 0), а склеп — нет).
func test_crypt_is_home() -> void:
	w.start_map("_gray", {"size": [1280, 720], "cauldron": [100, 360], "start_army": 0,
		"crypts": [{"pos": [400, 150]}]})
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.contracts.mana = 1000.0
	var b: LegionBuilding = w.crypts[0].building
	b.frozen = false
	w.contracts.add_contract(PackedVector2Array([
		Vector2(1100, 300), Vector2(1100, 380)]), 1, true, LegionCfg.KIND_LABORER)
	var at_crypt := w.spawn_unit(LegionCfg.KIND_LABORER, b.entry, b)
	var corner := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(40, 40))
	w.grid.rebuild()
	w._assign_free()
	check(at_crypt.state == Legionnaire.State.MARCH, "резерв у захваченного склепа идёт сам")
	check(corner.state == Legionnaire.State.FREE, "угол карты (0, 0) — не дом")


## Идущий «Сбором» рядом с черновиком освободится при создании линии — превью его показывает.
func test_preview_counts_rally() -> void:
	fresh()
	var pts := PackedVector2Array([Vector2(800, 300), Vector2(800, 380)])
	var rallier := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(700, 340))
	rallier.rally_to(PackedVector2Array([Vector2(700, 340), Vector2(650, 500)]))
	w.grid.rebuild()
	var draft := Contract.new().build(pts, 0, w.terrain.walkable, LegionCfg.KIND_LABORER)
	var lines: Array[Contract] = w.contracts.contracts.duplicate()
	lines.append(draft)
	var shown := LegionStaff.deployment_plan(w.contracts, lines, draft).any(
		func(a: Dictionary) -> bool: return a["contract"] == draft and a["unit"] == rallier)
	check(shown, "превью показывает идущего «Сбором», которого освободит линия")
	var real := w.contracts.add_contract(pts, 0, true, LegionCfg.KIND_LABORER)
	w.grid.rebuild()
	w._assign_free()
	check(rallier.contract == real, "и в бою он встаёт в эту линию")


## Превью черновика: подпись и кольца говорят правду — придут и те, кто идёт из дома.
func test_preview_counts_reserve() -> void:
	w.start_map("_gray", MAP)
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.contracts.active = true
	w.contracts.human_input = true
	w.contracts.mana = 1000.0
	var home := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 360))
	var vet := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(600, 200))
	w.grid.rebuild()
	await process_frame
	button(Vector2(1000, 260), true)
	for y in range(280, 401, 20):
		motion(Vector2(1000, y))
	w.contracts.update_preview()
	var plan := w.contracts._preview_plan.map(func(a: Dictionary) -> Object: return a["unit"])
	check(plan.has(home), "превью отмечает резерв из дома, который придёт")
	check(not plan.has(vet), "превью не отмечает бойца в поле, который не придёт")
	var places := w.contracts._preview.posts.size() if w.contracts._preview != null else 0
	var caption: String = w.contracts.call("preview_caption", places) \
		if w.contracts.has_method("preview_caption") else ""
	print("DIARY caption: %s" % caption)
	check(caption.contains("из дома"), "подпись превью называет идущих из дома")
	button(Vector2(1000, 400), false)
	check(w.contracts.contracts.size() == 1, "живой ввод создал линию")
	w.grid.rebuild()
	w._assign_free()
	check(home.state == Legionnaire.State.MARCH and vet.state == Legionnaire.State.FREE,
		"после отпускания пошли ровно те, кого показало превью")


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
	print("LEGION CONTROL 1009: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
