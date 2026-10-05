extends SceneTree
## Настоящие кнопки, возвраты и слои; headless, отдельный профиль.

var main: LegionMain
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL: ", message)


func _frames() -> void:
	await process_frame
	await process_frame


func _button(node: Node, caption: String) -> Button:
	for child in node.find_children("*", "Button", true, false):
		if (child as Button).text == caption:
			return child as Button
	return null


func _click(node: Node, caption: String) -> void:
	var button := _button(node, caption)
	_check(button != null and button.is_visible_in_tree(), "доступна кнопка " + caption)
	if button != null:
		button.pressed.emit()


func _nav(node: Node, primary := true) -> void:
	var back := node.find_child("NavBack", true, false) as Button
	_check(back != null, "есть нижний возврат: " + node.get_class())
	var next := node.find_child("NavPrimary", true, false) as Button
	if primary:
		_check(next != null, "есть главное действие")
	if back != null and next != null:
		_check(back.get_global_rect().end.x < next.get_global_rect().position.x,
			"возврат слева, действие справа")


func _run() -> void:
	Campaign.set_save_path("user://legion_nav_test.cfg")
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	main = LegionMain.new()
	root.add_child(main)
	await _frames()
	var first := String(Campaign.maps()[0]["id"])
	var second := String(Campaign.maps()[1]["id"])
	_click(main.screen, (main.screen.find_child("CampaignAction", true, false) as Button).text)
	await _frames()
	_check(main.screen is Briefing, "меню → брифинг")
	_nav(main.screen)
	_click(main.screen, "В главное меню")
	await _frames()
	main.show_map_select()
	await _frames()
	_nav(main.screen)
	(main.screen as MapSelect).map_chosen.emit(first)
	await _frames()
	_click(main.screen, "← Назад")
	await _frames()
	_check(main.screen is MapSelect, "брифинг из карт возвращается к картам")
	main.show_briefing(first)
	await _frames()
	_click(main.screen, "Контора (%d премии)" % Campaign.bounty())
	await _frames()
	_nav(main.screen, false)
	_click(main.screen, "Досье некроманта")
	await _frames()
	_nav(main.screen, false)
	_click(main.screen, "← Назад")
	await _frames()
	_check(main.screen is OfficeShop, "герой → та же Контора")
	_click(main.screen, "← Назад")
	await _frames()
	_check(main.screen is Briefing and main.screen._map_id == first, "Контора → тот же брифинг")
	_click(main.screen, "В бой")
	await _frames()
	main.world.items.grant(&"clip_of_fate")
	await _pause_checks()
	main.world.force_end(true)
	await _frames()
	_nav(main.screen)
	_click(main.screen, "Дальше: выбор поправки")
	await _frames()
	_nav(main.screen)
	var options := (main.screen as UpgradePicker).offered()
	_click(main.screen, "В главное меню")
	await _frames()
	_click(main.screen, (main.screen.find_child("CampaignAction", true, false) as Button).text)
	await _frames()
	_check((main.screen as UpgradePicker).offered() == options, "возврат не перебрасывает выбор")
	(main.screen.find_child("NavPrimary", true, false) as Button).pressed.emit()
	await _frames()
	_check(main.screen is Briefing and main.screen._map_id == second, "выбор → следующий брифинг")
	_check(Campaign.upgrades().size() == 1, "одна поправка")
	_click(main.screen, "В бой")
	await _frames()
	main.world.force_end(false)
	await _frames()
	_nav(main.screen)
	_click(main.screen, "Ещё раз")
	await _frames()
	_check(main.world.phase == LegionWorld.Phase.BATTLE, "повтор после поражения")
	main.show_menu()
	await _frames()
	await _other_screens()
	await _collection_check()
	await _pvp_check()
	main.queue_free()
	await _frames()
	print("LEGION NAV: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _pause_checks() -> void:
	var hud := main.world.find_child("*", true, false)
	for node in main.world.get_children():
		if node is LegionHud:
			hud = node
	for resolution: Vector2i in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = resolution
		await _frames()
		var pause_button: Button = hud.pause_button
		var rect := pause_button.get_global_rect()
		_check(Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(rect),
			"Пауза внутри экрана %s" % resolution)
		_check(not rect.intersects(hud._preview.get_global_rect()), "Пауза не перекрывает волны")
	root.size = Vector2i(1280, 720)
	_click(hud, "❚❚ Пауза")
	await _frames()
	_check(paused, "кнопка приостановила дерево")
	_check(root.gui_get_focus_owner().text == "Продолжить", "фокус продолжения")
	_nav(main._pause_screen)
	for caption in ["Настройки", "Как играть"]:
		var opener := _button(main._pause_screen, caption)
		_click(main._pause_screen, caption)
		await _frames()
		var overlay: Control
		for node in main.get_children():
			if node is SettingsScreen or node is HowtoLegion:
				overlay = node
		_click(overlay, "← Назад")
		await _frames()
		_check(paused and not hud.visible, caption + ": возврат сохранил паузу и скрыл HUD")
		_check(root.gui_get_focus_owner() == opener, caption + ": фокус вернулся")
	for caption in ["Заново", "В главное меню"]:
		_click(main._pause_screen, caption)
		await _frames()
		var dialog := _dialog(main._pause_screen)
		_check(dialog != null and paused, caption + ": ждёт подтверждения")
		if dialog != null:
			dialog.canceled.emit()
		await _frames()
		_check(paused and main.world.phase == LegionWorld.Phase.BATTLE,
			caption + ": отмена оставила бой на паузе")
	_click(main._pause_screen, "Как играть")
	await _frames()
	var howto: HowtoLegion
	for node in main.get_children():
		if node is HowtoLegion:
			howto = node
	_click(howto, "Обучение")
	await _frames()
	var tutorial_dialog := _dialog(howto)
	_check(tutorial_dialog != null and paused, "обучение во время боя требует подтверждения")
	if tutorial_dialog != null:
		tutorial_dialog.canceled.emit()
	_click(howto, "← Назад")
	await _frames()
	_click(main._pause_screen, "Досье артефактов")
	await _frames()
	main._dossier.close()
	await _frames()
	_check(paused and not hud.visible, "досье вернуло скрытое состояние слоёв паузы")
	_click(main._pause_screen, "Продолжить")
	await _frames()
	_check(not paused and hud.visible, "продолжение вернуло боевые слои")
	# Прямой open/close обязан вернуть и первоначально видимый слой.
	var dossier := LegionItemDossier.new()
	main.add_child(dossier)
	dossier.setup(main.world.items_of(main.world.local_side))
	dossier.open()
	_check(not hud.visible, "досье скрывает видимый HUD")
	dossier.close()
	_check(hud.visible, "досье close возвращает видимый HUD")
	dossier.queue_free()


func _other_screens() -> void:
	main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}
	main._start_endless_flow(false)
	await _frames()
	_nav(main.screen)
	_click(main.screen, "Контора (%d премии)" % Campaign.bounty())
	await _frames()
	_click(main.screen, "← Назад")
	await _frames()
	_check(main.screen is EndlessBriefing, "Контора → брифинг забега")
	main.show_menu()
	await _frames()
	main._show_necrolog({"daily": true}, "", "Проверка")
	await _frames()
	_nav(main.screen, false)
	_check(_button(main.screen, "Новый забег") == null, "в некрологе дня нет ложного нового забега")
	_click(main.screen, "В главное меню")
	await _frames()
	_check(main.screen is LegionMenu, "некролог дня → меню")
	main.world.hud.show()
	main._play_cutscene(main._finale_frames(), main._ensure_audio(), main.show_menu)
	await _frames()
	_check(not main.world.hud.visible, "финальная катсцена скрывает HUD боя")
	_click(main.screen, "Пропустить ▸▸")
	await _frames()
	_check(main.screen is LegionMenu, "клик пропускает всю катсцену")


func _pvp_check() -> void:
	PvpFlow.start(main, PvpMaps.DUEL)
	await _frames()
	for node in main.world.get_children():
		if node is LegionHud:
			var hud := node as LegionHud
			_click(hud, "❚❚ Пауза")
			await _frames()
			_check(main.world.pvp_menu.visible and not paused, "PvP открывает меню без паузы мира")
			_click(main.world.pvp_menu, "Продолжить")
			await _frames()
			_check(not main.world.pvp_menu.visible, "мышиный возврат из PvP-меню")
	main.show_menu()
	await _frames()


func _dialog(node: Node) -> ConfirmationDialog:
	for child in node.get_children():
		if child is ConfirmationDialog:
			return child as ConfirmationDialog
	return null


func _collection_check() -> void:
	var map_id := String(Campaign.maps()[0]["id"])
	LegionCollection.save({"map_id": map_id, "title": "Тест удаления"})
	LegionCollectionFlow.show_screen(main)
	await _frames()
	_nav(main.screen, false)
	_click(main.screen, "Убрать")
	await _frames()
	_check(LegionCollection.has(map_id), "до подтверждения карта остаётся")
	var dialog := _dialog(main.screen)
	_check(dialog != null, "удаление спрашивает подтверждение")
	if dialog != null:
		dialog.get_ok_button().pressed.emit()
	await _frames()
	_check(not LegionCollection.has(map_id), "после подтверждения карта удалена")
	_click(main.screen, "← Назад")
	await _frames()
