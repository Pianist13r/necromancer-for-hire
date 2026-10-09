extends SceneTree
## B-344: дальний резерв идёт в нарисованный игроком строй без транспортных линий.

const SAVE := "user://legion_gameplay_1008_test.cfg"
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
	w.start_map("_gray")
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.contracts.active = true
	w.contracts.human_input = true
	w.contracts.mana = 1000.0
	# Настоящий жест: ЛКМ, протяжка, отпускание. Поле, не тест, создаёт договор.
	button(Vector2(800, 260), true)
	for y in range(280, 401, 20):
		var ev := InputEventMouseMotion.new()
		ev.position = root.get_final_transform() * Vector2(800, y)
		ev.global_position = ev.position
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
	button(Vector2(800, 400), false)
	check(w.contracts.contracts.size() == 1, "живой ввод создал линию")
	if w.contracts.contracts.is_empty():
		finish()
		return
	var c: Contract = w.contracts.contracts[0]
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 330))
	var other := w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(170, 330))
	var banned := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(180, 330))
	banned.no_return_id = c.id
	var rally := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(190, 330))
	rally.rally_to(PackedVector2Array([Vector2(190, 500)]))
	w.grid.rebuild()
	w._assign_free()
	check(u.state == Legionnaire.State.MARCH, "дальний резерв сам получил место")
	check(other.state == Legionnaire.State.FREE, "чужой вид остаётся в резерве")
	check(banned.state == Legionnaire.State.FREE, "запрет возврата в договор соблюдён")
	check(rally.state == Legionnaire.State.RALLY, "ручной Сбор имеет приоритет")
	var start := u.position
	for i in 120:
		u.tick(1.0 / 60.0)
	check(u.position.x > start.x + 50.0, "боец действительно идёт, не только сменил состояние")
	print("DIARY reserve: %s -> %s state=%d" % [start, u.position, u.state])
	await capture("reserve")
	check(w.rally_preview(u.position)["reach"].has(u), "Сбор может перенаправить автомарш")
	var old_post := u.post
	var motion := InputEventMouseMotion.new()
	motion.position = root.get_final_transform() * w.world_to_screen(u.position + Vector2(0, 50))
	motion.global_position = motion.position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for down: bool in [true, false]:
		var key: InputEvent = InputMap.action_get_events(&"rally")[0].duplicate()
		key.pressed = down
		Input.parse_input_event(key)
		Input.flush_buffered_events()
	check(u.state == Legionnaire.State.RALLY, "настоящая клавиша Сбора перебила автомарш")
	check(old_post.is_empty() or old_post["unit"] == null, "Сбор освободил забронированное место")
	u = w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 330))
	w.grid.rebuild()
	w._assign_free()
	if u.contract != null:
		u.post["dead"] = true
		u.tick(1.0 / 60.0)
	check(u.state == Legionnaire.State.FREE, "исчезнувшее место освобождает марш")
	await test_plot_warning()
	test_bot()
	test_rear()
	test_birth_and_boundaries()
	test_siege_priority()
	finish()


func test_plot_warning() -> void:
	w.start_map("maze")
	var menu := w.plot_menu
	var p: Dictionary = w.staff.plots[4]
	var at := w.world_to_screen(p["pos"])
	button(at, true)
	button(at, false)
	await process_frame
	check(menu.is_open(), "настоящий клик по p5 открыл площадку")
	check(labels(menu).contains("У дороги"), "предупреждение видно ДО покупки")
	print("DIARY maze/p5 menu: ", labels(menu))
	await capture("road-warning")
	menu.close()
	w.souls = 1000
	var b := w.staff.build(p, LegionCfg.KIND_LABORER)
	b.fill_now(100)
	b.slot_unit[0].take_damage(10000, b.position)
	menu.open(p, p["pos"])
	check(labels(menu).contains("Штат постройки"), "улучшение показывает прирост штата постройки")
	check(labels(menu).contains("Бесплатно через"), "найм сравним с бесплатным ожиданием")
	print("DIARY hiring: ", labels(menu))
	await capture("hiring-choice")
	await process_frame
	var cap := b.cap
	var souls := w.souls
	var price := w.staff.rush_price(b)
	for btn in menu.buttons():
		if btn.text.begins_with("Срочный найм"):
			var center := btn.get_global_rect().get_center()
			button(center, true)
			button(center, false)
			break
	await process_frame
	check(b.waiting_count() == 0 and w.souls == souls - price,
		"настоящий клик найма вернул павшего за показанную цену")
	check(b.cap == cap, "срочный найм не увеличил постоянный штат")
	menu.close()
	await process_frame


func test_bot() -> void:
	w.start_map("_gray")
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.contracts.mana = 1000
	var bot := LegionBot.new()
	bot.setup(w, LegionBot.SELECTIVE, {})
	var points := PackedVector2Array([Vector2(800, 260), Vector2(800, 340)])
	var preview := Contract.new().build(points, 1, w.terrain.walkable, LegionCfg.KIND_LABORER)
	for i in 5:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 300 + i * 10))
	w.grid.rebuild()
	check(bot._recruits(preview) >= 3, "бот учитывает дальний резерв, не требует линию доставки")
	var c := w.contracts.add_contract(points, 1, true, LegionCfg.KIND_LABORER)
	c.set_dir(Vector2.RIGHT)
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
	var center := c.seg_center(0)
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([
		center + Vector2(65, -100), center + Vector2(65, 150)]), center + Vector2(65, -10))
	w.grid.rebuild()
	bot._observe()
	w.now += 0.5
	f.position.y += 10
	bot._observe()
	w.grid.rebuild()
	check(w.contracts.seg_gold(c, 0), "колонна вошла в настоящую полосу точного срыва")
	var slot := {"role": "flank", "contracts": [c]}
	bot._selective(slot)
	check(not c.seg_alive(0), "бот выпускает фланг по проходящей пехоте")
	print("DIARY flank: alive=%s released=%s" % [c.seg_alive(0), slot.has("last_release")])


func test_rear() -> void:
	w.start_map("_gray")
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.contracts.mana = 1000
	var bot := LegionBot.new()
	bot.setup(w, LegionBot.SELECTIVE, {})
	var points := PackedVector2Array([Vector2(800, 260), Vector2(800, 340)])
	var template := Contract.new().build(points, 1, w.terrain.walkable, LegionCfg.KIND_LABORER)
	var rear := {"role": "rear", "kind": LegionCfg.KIND_LABORER, "pts": points,
		"template": template, "side": 1, "contracts": [], "dir": Vector2.RIGHT, "min_units": 3}
	for i in 5:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160, 300 + i * 10))
	w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(880, 300), Vector2(100, 300)]),
		Vector2(880, 300))
	w.grid.rebuild()
	bot._observe()
	bot._tick_slot(rear)
	check(not (rear["contracts"] as Array).is_empty(),
		"видимая угроза активирует тыл даже без сигнала прорыва")
	check(w.contracts.mana < 1000, "бот оплатил тыловую линию обычной маной")


func labels(node: Node) -> String:
	var text := String(node.text) + "\n" if node is Label else ""
	for child in node.get_children():
		text += labels(child)
	return text


func test_birth_and_boundaries() -> void:
	w.start_map("_gray", {"size": [1280, 720], "cauldron": [100, 600],
		"plots": [{"id": "birth", "pos": [150, 300]}], "start_army": 0})
	w.souls = 1000
	w.contracts.mana = 1000
	var b := w.staff.build(w.staff.plots[0], LegionCfg.KIND_LABORER)
	b.tick(LegionCfg.STAFF_FILL_STEP, 1)
	var u: Legionnaire = b.slot_unit[0]
	check(u != null and u.home == b, "боец действительно родился из таймера Бытовки")
	var far := w.contracts.add_contract(PackedVector2Array([
		Vector2(1000, 260), Vector2(1000, 340)]), 1, true, b.kind)
	var near := w.contracts.add_contract(PackedVector2Array([
		Vector2(600, 260), Vector2(600, 340)]), 1, true, b.kind)
	w.grid.rebuild()
	w._assign_free()
	check(u.contract == near, "рождённый боец выбрал ближайшую живую линию")
	check(u.auto_march and SnapUnits.UNIT_PROPS.has("auto_march"),
		"автоприказ включён в сетевой снимок")
	var snapshot := w.snapshot()
	w.load_snapshot(snapshot)
	u = w.units[0]
	check(u.auto_march and u.can_rally(), "снимок восстановил право перебить автомарш Сбором")
	# После снимка ссылки на договоры берём из восстановленного мира.
	near = u.contract
	far = w.contracts.contracts[0]
	u.position = u.post["pos"]
	u._arrive()
	w.release_segment(near, int(u.post["seg"]))
	u._end_charge()
	w.grid.rebuild()
	w._assign_free()
	# D-1009-C1 (Игорь 09.10: «слишком далеко линии забирают скелетов»): вышедший натиском боец
	# стоит в поле, далеко от дома, — дальняя линия его сама не забирает
	check(u.state == Legionnaire.State.FREE and far.posts.all(
		func(p: Dictionary) -> bool: return p["unit"] == null),
		"отстоявший и вышедший в поле боец сам не уходит к дальнему договору")
	u.set_free()
	u.position = Vector2(150, 300)
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720],
		"rocks": [[[400, -20], [450, -20], [450, 740], [400, 740]]]})
	w.grid.rebuild()
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "недостижимая линия не даёт ложного приказа")
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	u.side = 1
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "чужая сторона не получает приказ нашего поля")
	u.side = 0
	u.stun(2.0)
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "оглушённый дальний резерв не получает приказа")
	print("DIARY birth/regroup: nearest, snapshot, no-return, disconnected, side, stun checked")


func test_siege_priority() -> void:
	w.dev = {"spawn_units": "0", "pvp_nobot": "1", "no_waves": "1"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w.start_map("pvp:duel")
	w.terrain = LegionTerrain.new().setup({"size": [1600, 900]})
	for side in 2:
		var field: ContractField = w.sides[side].contracts
		var at := w.cauldron_of(side) + Vector2(200 * (1 - 2 * side), 0)
		field.mana = 1000
		field.add_contract(PackedVector2Array([at - Vector2(0, 40), at + Vector2(0, 40)]),
			1, true, LegionCfg.KIND_LABORER)
		var enemy := w.sides[1 - side]
		var u := w.spawn_unit(LegionCfg.KIND_LABORER,
			enemy.cauldron_pos + Vector2(40 * (2 * side - 1), 0), null, side)
		w.grid.rebuild()
		check(u._in_reach(enemy.staff.cauldron), "осадный боец достаёт чужой Котёл")
		w._assign_free(field)
		check(u.state == Legionnaire.State.FREE, "автомарш не отзывает бойца от чужого Котла")
		var hp := enemy.cauldron_hp
		for i in 60:
			u.tick(1.0 / 60.0)
		check(enemy.cauldron_hp < hp, "боец продолжает осаду при вакансии в дальнем тылу")


func capture(label: String) -> void:
	if "--shots" not in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless":
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var file := ProjectSettings.globalize_path("res://../batches/gameplay-1008/%s.png" % label)
	check(root.get_texture().get_image().save_png(file) == OK, "кадр " + label)


func button(at: Vector2, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = root.get_final_transform() * at
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	ev.pressed = down
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func finish() -> void:
	Campaign.reset()
	print("LEGION GAMEPLAY 1008: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
