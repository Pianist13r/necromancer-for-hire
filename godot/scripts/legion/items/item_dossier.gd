class_name LegionItemDossier
extends Control
## Постоянный инвентарь поверх паузы. Открытие не меняет состояние боя или его паузы.

signal closed
const STYLE_NAMES := {&"hr": "Кадры", &"law": "Договоры", &"warlock": "Некромантия"}
var inventory: LegionItems = null
var _body: VBoxContainer
var _cards: GridContainer
var _close: Button
var _return_focus: Control
var _hidden_layers: Array[CanvasLayer] = []
var _layer: CanvasLayer
var _scroll: ScrollContainer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	UiStyle.fill_rect(self)
	z_index = 1000
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# Камера PvP уменьшает холст мира до 0,8; досье остаётся в экранных координатах.
	_layer = CanvasLayer.new()
	_layer.layer = 20
	_layer.hide()
	add_child(_layer)
	var surface := Control.new()
	UiStyle.fill_rect(surface)
	_layer.add_child(surface)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.01, 0.03, 0.94)
	UiStyle.fill_rect(shade)
	surface.add_child(shade)
	var margins := MarginContainer.new()
	UiStyle.fill_rect(margins)
	for key in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margins.add_theme_constant_override(key, 92 if key == "margin_bottom" else 24)
	surface.add_child(margins)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", LegionUi.blank_style(LegionUi.GOLD,
		Color(0.085, 0.068, 0.095, 1.0), 22, 18))
	margins.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	panel.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	var title := LegionUi.label("Досье артефактов", 28, LegionUi.FONT_TITLE, LegionUi.GOLD)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var nav := LegionUi.nav_bar(surface, "← Назад", close)
	_close = nav.get_node("NavBack") as Button
	_close.name = "Close"
	content.add_child(_label("Ваш инвентарь этого забега · срабатывания за текущий бой", 18))
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.focus_mode = Control.FOCUS_ALL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 14)
	scroll.add_child(_body)
	resized.connect(_resize_cards)
	get_viewport().size_changed.connect(_resize_cards)


func setup(it: LegionItems) -> LegionItemDossier:
	inventory = it
	return self


func open() -> void:
	_return_focus = get_viewport().gui_get_focus_owner()
	if inventory != null:
		for child in inventory.world.find_children("*", "CanvasLayer", true, false):
			var layer := child as CanvasLayer
			if layer.visible:
				layer.hide()
				_hidden_layers.append(layer)
	_refresh()
	show()
	_layer.show()
	_close.grab_focus()


func close() -> void:
	hide()
	_layer.hide()
	for layer in _hidden_layers:
		if is_instance_valid(layer):
			layer.show()
	_hidden_layers.clear()
	if is_instance_valid(_return_focus) and _return_focus.is_visible_in_tree():
		_return_focus.grab_focus()
	closed.emit()


func _input(event: InputEvent) -> void:
	if visible and (event.is_action_pressed(&"pause") or event.is_action_pressed(&"ui_cancel")):
		close()
		get_viewport().set_input_as_handled()
	elif visible and event is InputEventKey and (event as InputEventKey).pressed:
		var key := (event as InputEventKey).physical_keycode
		if key == KEY_PAGEDOWN or key == KEY_PAGEUP:
			_scroll.scroll_vertical += 360 if key == KEY_PAGEDOWN else -360
			get_viewport().set_input_as_handled()


func _label(text: String, font_size := 17, color := LegionUi.TEXT) -> Label:
	var label := LegionUi.label(text, font_size, LegionUi.num_font(), color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _refresh() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_cards = GridContainer.new()
	_cards.name = "Cards"
	_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards.add_theme_constant_override("h_separation", 16)
	_cards.add_theme_constant_override("v_separation", 16)
	_body.add_child(_cards)
	_resize_cards()
	if inventory == null or inventory.total() == 0:
		_body.add_child(_label("Артефактов пока нет. Победите элитного носителя: находка сама "
			+ "попадёт в инвентарь и останется до конца забега.", 20))
		return
	for id in inventory.owned():
		_cards.add_child(_card(id))
	_body.add_child(_label("Синергии — соберите обе части", 22, LegionUi.GOLD))
	for sid in LegionItemDb.synergy_ids():
		_body.add_child(_synergy(sid))


func _resize_cards() -> void:
	if is_instance_valid(_cards):
		_cards.columns = 2 if get_viewport_rect().size.x >= 900 else 1


func _card(id: StringName) -> Control:
	var d := LegionItemDb.item(id)
	var rarity_color: Color = CfgItems.RARITY_COLOR[LegionItemDb.rarity(id)]
	var panel := PanelContainer.new()
	panel.name = String(id)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", LegionUi.blank_style(rarity_color,
		LegionUi.PAPER_HI, 16, 14, false))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	column.add_child(header)
	var icon := TextureRect.new()
	icon.texture = LegionIcons.tex(LegionItemDb.icon_name(id))
	icon.custom_minimum_size = Vector2(76, 76)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(icon)
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	heading.add_child(_label(String(d["title"]), 22, rarity_color))
	var tags: Array[String] = []
	for style: StringName in d["styles"]:
		tags.append(String(STYLE_NAMES.get(style, style)))
	heading.add_child(_label(String(CfgItems.RARITY_TITLE[LegionItemDb.rarity(id)])
		+ " · " + " / ".join(tags), 16, LegionUi.TEXT_DIM))
	var active := bool(d.get("passive", false))
	heading.add_child(_label("Действует постоянно" if active else "Срабатываний: %d"
		% inventory.activation_count(id), 17, LegionUi.GOLD))
	column.add_child(_label("Когда: " + String(d["trigger"])))
	column.add_child(_label("Эффект: " + String(d["result"])))
	column.add_child(_label("Приём: " + String(d["play_hint"]), 17, LegionUi.GOOD))
	column.add_child(_label("На поле: " + String(d["cue"]), 16, LegionUi.TEXT_DIM))
	return panel


func _synergy(id: StringName) -> Control:
	var d := LegionItemDb.synergy(id)
	var missing: Array[String] = []
	var parts: Array[String] = []
	for part: String in d["items"]:
		var title := String(LegionItemDb.item(StringName(part))["title"])
		parts.append(title)
		if inventory.count(StringName(part)) == 0:
			missing.append(title)
	var row := VBoxContainer.new()
	row.add_child(_label(String(d["title"]) + " · " + ("Собрана" if missing.is_empty()
		else "Не хватает: " + ", ".join(missing)), 20, LegionUi.GOLD))
	row.add_child(_label(" + ".join(parts) + " → " + String(d["text"])))
	return row
