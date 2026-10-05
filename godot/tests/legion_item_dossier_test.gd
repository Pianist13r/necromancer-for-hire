extends SceneTree
## Читаемые условия всех предметов, правдивые счётчики и доступный постоянный инвентарь.
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, text: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", text])


func _run() -> void:
	Campaign.set_save_path("user://legion_item_dossier_test.cfg")
	Campaign.reset()
	var w := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
	w.start_map("pvp:duel")
	for id in LegionItemDb.ids():
		var d := LegionItemDb.item(id)
		_check(not String(d.get("trigger", "")).is_empty()
			and not String(d.get("result", "")).is_empty()
			and not String(d.get("play_hint", "")).is_empty()
			and not (d.get("styles", []) as Array).is_empty(), "досье: " + String(id))
	w.items.grant(&"golden_pen")
	w.hero._cd[LegionHero.SLOT_Q] = 4.0
	w.items.on(&"charge_impact", [Vector2(400, 320), false])
	_check(_uses(w.items, &"golden_pen") == 0, "нет эффекта — нет срабатывания")
	w.items.on(&"charge_impact", [Vector2(400, 320), true])
	_check(_uses(w.items, &"golden_pen") == 1, "точный удар снял откат — одно срабатывание")
	w.items.on(&"charge_impact", [Vector2(400, 320), true])
	_check(_uses(w.items, &"golden_pen") == 1, "готовая Ку не считает фиктивный сброс")
	_check(_uses(w.items_of(1), &"golden_pen") == 0, "счётчик не течёт на чужую сторону")
	var snap: Dictionary = bytes_to_var(var_to_bytes(w.snapshot()))
	w.load_snapshot(snap)
	_check(_uses(w.items, &"golden_pen") == 1, "снимок сохраняет счётчик реального эффекта")
	_test_staff(w)
	_test_feedback(w)
	var path := "res://scripts/legion/items/item_dossier.gd"
	_check(FileAccess.file_exists(path), "постоянное досье существует")
	if FileAccess.file_exists(path):
		for id in LegionItemDb.ids():
			w.items.grant(id)
		var dossier: Control = (load(path) as GDScript).new()
		root.add_child(dossier)
		dossier.call("setup", w.items)
		w.set_paused(true)
		# Слои — только живые: GroundLoading (временная плашка загрузки карты) в headless
		# гаснет синхронно внутри start_map (PgArt без GPU падает сразу) и доживает до конца
		# кадра уже queue_free'нутым. Контракт досье — вернуть видимость БОЕВЫХ слоёв (его
		# close() сам бережётся is_instance_valid); умирающий оверлей не должен ни попадать
		# в замер, ни ронять тест кастом на освобождённый объект (тест без quit() висел).
		var layers: Array[Node] = []
		for child in w.find_children("*", "CanvasLayer", true, false):
			if not child.is_queued_for_deletion():
				layers.append(child)
		var before: Array[bool] = []
		if not layers.is_empty():
			(layers[0] as CanvasLayer).hide()
		for layer: CanvasLayer in layers:
			before.append(layer.visible)
		dossier.call("open")
		await process_frame
		await process_frame
		_check(dossier.visible, "досье открывается независимо от карточки выпадения")
		var cards := dossier.find_child("Cards", true, false) as GridContainer
		_check(cards != null and cards.get_child_count() == 13, "все 13 предметов доступны в прокрутке")
		_check(cards.columns == 2, "широкий экран показывает две колонки")
		var close_button := dossier.find_child("Close", true, false) as Button
		_check(close_button != null and close_button.has_focus(), "закрыть доступно с клавиатуры")
		if "--shots" in OS.get_cmdline_user_args():
			await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png(
				"C:/AI/necro/batches/oct05-artifacts/dossier.png")
		var page := InputEventKey.new()
		page.physical_keycode = KEY_PAGEDOWN
		page.pressed = true
		Input.parse_input_event(page)
		await process_frame
		var scroll := dossier.find_child("*", true, false) as ScrollContainer
		for child in dossier.find_children("*", "ScrollContainer", true, false):
			scroll = child as ScrollContainer
		_check(scroll != null and scroll.scroll_vertical > 0,
			"клавиатура прокручивает длинный инвентарь")
		close_button.pressed.emit()
		_check(not dossier.visible, "кнопка закрывает только досье")
		var restored := true
		for i in layers.size():
			# освобождение боевого слоя посреди досье — тоже провал, но без каста на труп
			restored = restored and is_instance_valid(layers[i]) \
				and (layers[i] as CanvasLayer).visible == before[i]
		_check(restored and w.paused, "слои восстановлены точно; бой остался на паузе")
		dossier.call("open")
		var escape := InputEventKey.new()
		escape.physical_keycode = KEY_ESCAPE
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		Input.parse_input_event(escape)
		await process_frame
		_check(not dossier.visible and w.paused, "повторное открытие: Esc закрыл досье, сохранил паузу")
		if "--shots" in OS.get_cmdline_user_args():
			root.size = Vector2i(960, 540)
			dossier.call("open")
			await process_frame
			await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png(
				"C:/AI/necro/batches/oct05-artifacts/dossier-960.png")
			dossier.call("close")
		dossier.queue_free()
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION ITEM DOSSIER: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _uses(it: LegionItems, id: StringName) -> int:
	return int((it.state.get(&"activations", {}) as Dictionary).get(id, 0))


func _test_staff(w: LegionWorld) -> void:
	w.items.grant(&"staff_schedule")
	var buildings: Array[LegionBuilding] = [w.sides[0].staff.cauldron]
	w.sides[0].souls = 1000
	var st := w.sides[0].staff
	buildings.append(st.build(st.plots[0], LegionCfg.KIND_LABORER))
	for b in buildings:
		b.dismiss_all()
		b.set_staff(4, 20.0)
		_check(b.tick(0.01, 99) == 1, "Расписание: свежий штат не удваивается (%s)" % b.source)
		b.fill_now(99)
		for u in b.slot_unit.duplicate():
			u.take_damage(9999, u.position)
		b.slot_t[0] = 0.0
		_check(b.tick(0.01, 99) == 2, "Расписание: настоящий парный возврат (%s)" % b.source)
		_check(_uses(w.items, &"staff_schedule") == 0, "пассив не выдаёт фиктивный счётчик")


func _test_feedback(w: LegionWorld) -> void:
	var events: Array[Dictionary] = []
	w.items.fx_event.connect(func(kind: StringName, d: Dictionary) -> void:
		if kind == &"used":
			events.append(d.duplicate()))
	for id: StringName in [&"clip_of_fate", &"overtime_sheet", &"wholesale_ink"]:
		w.items.grant(id)
	w.terrain = LegionTerrain.new().setup({"size": [w.world_size.x, w.world_size.y]})
	var at := Vector2(500, 320)
	w.spawn_foe_on_path("zombie", PackedVector2Array([at, w.cauldron_of(1)]), at)
	w.grid.rebuild()
	w.hero.reset_cd(LegionHero.SLOT_Q)
	w.contracts.mana = 100
	_check(w.hero.cast(LegionHero.SLOT_Q, at), "настоящее применение Ку для проверки обратной связи")
	_check(events.any(func(d: Dictionary) -> bool: return d["id"] == &"clip_of_fate"),
		"Скрепка отмечает настоящее применение Ку своим значком")
	w.spawn_unit(LegionCfg.KIND_LABORER, at)
	w.contracts.mana = 100
	_check(w.hero.cast(LegionHero.SLOT_E, at), "настоящий Аврал на своих бойцах")
	_check(events.any(func(d: Dictionary) -> bool: return d["id"] == &"overtime_sheet"),
		"Табель отмечает настоящий Аврал")
	w.contracts.mana = 100
	var c := w.contracts.add_contract(PackedVector2Array([Vector2(160, 240), Vector2(260, 240)]),
		1, false)
	_check(c != null and events.any(func(d: Dictionary) -> bool:
		return d["id"] == &"wholesale_ink"), "Чернила отмечают настоящий договор")
	w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 320), w.sides[0].staff.cauldron)
	_check(events.any(func(d: Dictionary) -> bool: return d["id"] == &"staff_schedule"),
		"Расписание отмечает настоящего штатного у источника найма")
	_check(events.all(func(d: Dictionary) -> bool: return d["side"] == 0),
		"обратная связь принадлежит своей стороне")
	_check(_uses(w.items, &"clip_of_fate") == 0 and _uses(w.items, &"overtime_sheet") == 0,
		"пассивные события не притворяются отдельными срабатываниями")
