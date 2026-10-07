extends SceneTree
## Главное меню: клавиатура, поведение и посадка (fit), без привязки к конкретной раскладке.
## Проверяем инварианты, а не структуру: Enter запускает продолжение ровно раз; подписи и
## иконки помещаются в кнопки (шрифт + иконка + зазор); всё интерактивное — в экране;
## декоративные дети кнопок не перехватывают мышь; сигналы подключены, закрытые режимы
## неактивны; карточки-ссылки содержат живую иконку и подпись.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL ", message)


func _run() -> void:
	root.size = Vector2i(1280, 720)
	Campaign.set_save_path("user://menu_polish_test.cfg")
	Campaign.reset()
	await _menu_case(false)
	Campaign.unlock_all()
	for map_data: Dictionary in Campaign.maps():
		if String(map_data.get("id", "")) == "maze":
			break
		Campaign.record_result(String(map_data["id"]), true, 1.0)
	await _menu_case(true)
	print("LEGION MENU POLISH: %d/%d OK" % [_checks - _fails, _checks])
	quit(0 if _fails == 0 else 1)


func _menu_case(open_modes: bool) -> void:
	var menu := LegionMenu.new()
	menu.dev_force_open = open_modes
	root.add_child(menu)
	for i in 5:
		await process_frame
	var focus := root.gui_get_focus_owner()
	_check(focus is Button and focus.name == "CampaignAction" and menu.is_ancestor_of(focus),
		"продолжение кампании имеет начальный фокус")
	var buttons: Array[Button] = []
	_collect(menu, buttons)
	var bounds := Rect2(Vector2.ZERO, Vector2(1280, 720))
	for button in buttons:
		_check(bounds.encloses(button.get_global_rect()), "кнопка в экране: " + button.name)
		_check(button.size.y >= 40.0, "кнопка удобна для нажатия: " + button.name)
		_check(not button.pressed.get_connections().is_empty(),
			"действие подключено: " + button.name)
		_check_decor(button)
		if button.text.is_empty():
			continue
		var font := button.get_theme_font("font")
		var font_size := button.get_theme_font_size("font_size")
		var style := button.get_theme_stylebox("normal")
		var text_width := font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, font_size).x
		var content_width := text_width
		if button.icon != null:
			var icon_limit := button.get_theme_constant("icon_max_width")
			content_width += float(mini(button.icon.get_width(), icon_limit))
			if not button.text.is_empty():
				content_width += float(button.get_theme_constant("h_separation"))
		_check(content_width + style.get_minimum_size().x <= button.size.x + 1.0,
			"подпись без обрезки: " + button.name)
	_check_action(menu, bounds)
	_check_cards(menu, bounds)
	_check_difficulty(menu)
	_check_menu_signals(menu)
	await _check_card_mouse(menu)
	var activations: Array[int] = [0]
	menu.continue_pressed.connect(func(_map_id: String) -> void: activations[0] += 1)
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	Input.parse_input_event(enter)
	await process_frame
	enter = enter.duplicate() as InputEventKey
	enter.pressed = false
	Input.parse_input_event(enter)
	await process_frame
	_check(activations[0] == 1, "Enter один раз запускает продолжение кампании")
	menu.free()


## Главное действие: крупный шрифт и заметная иконка,tooltip с названием карты, сигнал ведёт
## на следующую карту кампании.
func _check_action(menu: LegionMenu, bounds: Rect2) -> void:
	var cta := menu.find_child("CampaignAction", true, false) as Button
	if cta == null:
		_check(false, "главное действие найдено")
		return
	_check(bounds.encloses(cta.get_global_rect()), "главное действие в экране")
	_check(cta.get_theme_font_size("font_size") >= 40, "главное действие крупным шрифтом")
	if cta.icon != null:
		var limit := cta.get_theme_constant("icon_max_width")
		_check(mini(cta.icon.get_width(), limit) >= 40, "иконка главного действия крупная")
	else:
		_check(false, "у главного действия есть иконка")


## Карточки-ссылки: это кнопки с неклипующейся подписью и видимой иконкой; декор внутри
## полностью помещается в карточку.
func _check_cards(menu: LegionMenu, bounds: Rect2) -> void:
	for card_name in ["CardMaps", "CardDossier"]:
		var card := menu.find_child(card_name, true, false) as Button
		if card == null:
			_check(false, "карточка найдена: " + card_name)
			continue
		_check(bounds.encloses(card.get_global_rect()), "карточка в экране: " + card_name)
		var labels: Array[Label] = []
		var icons: Array[TextureRect] = []
		_collect_card_decor(card, labels, icons)
		_check(labels.size() == 1 and not labels[0].text.is_empty(),
			"у карточки есть подпись: " + card_name)
		_check(icons.size() >= 1 and icons[0].texture != null,
			"у карточки есть иконка: " + card_name)
		if icons.size() >= 1 and icons[0].texture != null:
			_check(minf(icons[0].size.x, icons[0].size.y) >= 48.0,
				"иконка карточки крупная: " + card_name)
		for label in labels:
			_check(not label.clip_text, "подпись не клипуется: " + card_name)
			var font := label.get_theme_font("font")
			var size := label.get_theme_font_size("font_size")
			var text_width := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT,
				-1, size).x
			_check(text_width <= card.size.x - 24.0, "подпись без обрезки: " + card_name)
			_check(card.get_global_rect().encloses(label.get_global_rect()),
				"подпись внутри карточки: " + card_name)


## Сложность: строка-описание убрана (не занимает колонку), подсказка переехала в tooltip
## кнопок; закрытые режимы неактивны и не принимают фокус, открытые — активны.
func _check_difficulty(menu: LegionMenu) -> void:
	var picker: DifficultyPicker = null
	for child in menu.find_children("*", "DifficultyPicker", true, false):
		picker = child as DifficultyPicker
		break
	if picker == null:
		_check(false, "переключатель сложности найден")
		return
	for id: String in picker.buttons:
		var btn := picker.buttons[id] as Button
		_check(not btn.tooltip_text.is_empty(), "у сложности есть tooltip: " + id)
	for label in picker.find_children("*", "Label", true, false):
		if (label as Label).text != "Сложность:":
			_check(not (label as Label).visible, "строка-описание сложности убрана")
	var endless := menu.find_child("EndlessAction", true, false) as Button
	var daily := menu.find_child("DailyAction", true, false) as Button
	if endless == null or daily == null:
		_check(false, "кнопки режимов найдены")
		return
	if menu.dev_force_open or LegionRunStore.campaign_completed():
		_check(not endless.disabled, "подряд открыт: кнопка активна")
		_check(endless.focus_mode != Control.FOCUS_NONE, "подряд открыт: принимает фокус")
	else:
		_check(endless.disabled, "подряд закрыт: кнопка неактивна")
		_check(endless.focus_mode == Control.FOCUS_NONE, "подряд закрыт: без фокуса")
		_check(daily.disabled, "вызов закрыт вместе с подрядом: кнопка неактивна")


## Каждая основная кнопка должна вести в свой экран/режим, а не просто иметь любой callback.
func _check_menu_signals(menu: LegionMenu) -> void:
	var counts := {
		"continue_pressed": 0, "maps_pressed": 0, "hero_pressed": 0,
		"howto_pressed": 0, "settings_pressed": 0, "quit_pressed": 0,
		"endless_pressed": 0, "daily_pressed": 0, "collection_pressed": 0,
	}
	menu.continue_pressed.connect(func(_id: String) -> void:
		counts["continue_pressed"] += 1)
	menu.maps_pressed.connect(func() -> void: counts["maps_pressed"] += 1)
	menu.hero_pressed.connect(func() -> void: counts["hero_pressed"] += 1)
	menu.howto_pressed.connect(func() -> void: counts["howto_pressed"] += 1)
	menu.settings_pressed.connect(func() -> void: counts["settings_pressed"] += 1)
	menu.quit_pressed.connect(func() -> void: counts["quit_pressed"] += 1)
	menu.endless_pressed.connect(func() -> void: counts["endless_pressed"] += 1)
	menu.daily_pressed.connect(func() -> void: counts["daily_pressed"] += 1)
	menu.collection_pressed.connect(func() -> void: counts["collection_pressed"] += 1)
	var routes := {
		"CampaignAction": "continue_pressed", "CardMaps": "maps_pressed",
		"CardDossier": "hero_pressed",
		"HowtoAction": "howto_pressed", "SettingsAction": "settings_pressed",
		"QuitAction": "quit_pressed", "EndlessAction": "endless_pressed",
		"DailyAction": "daily_pressed", "CollectionAction": "collection_pressed",
	}
	for button_name: String in routes:
		var button := menu.find_child(button_name, true, false) as Button
		if button == null:
			continue # Коллекция штатно скрыта, пока нет ни одной сохранённой карты.
		var signal_name: String = routes[button_name]
		button.emit_signal("pressed")
		_check(counts[signal_name] == 1, "кнопка ведёт в %s" % signal_name)
		counts[signal_name] = 0


## Нажатие по самой картинке проходит к Button: дочерние иконки не крадут клик.
func _check_card_mouse(menu: LegionMenu) -> void:
	var card := menu.find_child("CardMaps", true, false) as Button
	if card == null:
		_check(false, "карточка карт найдена для проверки клика")
		return
	var labels: Array[Label] = []
	var icons: Array[TextureRect] = []
	_collect_card_decor(card, labels, icons)
	if icons.is_empty() or icons[0].texture == null:
		_check(false, "иконка карты доступна для проверки клика")
		return
	var maps_clicks: Array[int] = [0]
	menu.maps_pressed.connect(func() -> void: maps_clicks[0] += 1)
	var click := InputEventMouseButton.new()
	click.position = icons[0].get_global_rect().get_center()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await process_frame
	click = click.duplicate() as InputEventMouseButton
	click.pressed = false
	Input.parse_input_event(click)
	await process_frame
	_check(maps_clicks[0] == 1, "клик по иконке карточки запускает её действие ровно раз")
	var cta := menu.find_child("CampaignAction", true, false) as Button
	if cta != null:
		cta.grab_focus()
		await process_frame


## Дети кнопки — только декор: ни один не перехватывает мышь, клик всегда достаётся кнопке.
func _check_decor(button: Button) -> void:
	var stack: Array[Node] = button.get_children()
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Control and node != button:
			_check((node as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"декор не перехватывает мышь: %s/%s" % [button.name, node.name])
		stack.append_array(node.get_children())


func _collect_card_decor(card: Button, labels: Array[Label], icons: Array[TextureRect]) -> void:
	for child in card.get_children():
		if child is Label:
			labels.append(child as Label)
		if child is TextureRect:
			icons.append(child as TextureRect)
		for node in child.get_children():
			if node is Label:
				labels.append(node as Label)
			if node is TextureRect:
				icons.append(node as TextureRect)


func _collect(node: Node, buttons: Array[Button]) -> void:
	for child in node.get_children():
		if child is Button and child.is_visible_in_tree():
			buttons.append(child as Button)
		_collect(child, buttons)
