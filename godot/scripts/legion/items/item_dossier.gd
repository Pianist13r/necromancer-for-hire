class_name LegionItemDossier
extends Control
## «Досье» поверх паузы (D-1007-P2): тот же DossierView, что экран меню, но по умолчанию на вкладке
## «Артефакты» — живой инвентарь боя со счётчиками срабатываний. Открытие не меняет состояние боя
## или его паузы.

signal closed
var inventory: LegionItems = null
var view: DossierView = null
var _content: VBoxContainer
var _close: Button
var _return_focus: Control
var _hidden_layers: Array[CanvasLayer] = []
var _layer: CanvasLayer


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
	# Непрозрачная: сквозь 0,94 просвечивала кнопка «Продолжить» паузы под досье (кадр 42_F3).
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.01, 0.03, 1.0)
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
	_content = VBoxContainer.new()
	panel.add_child(_content)
	var nav := LegionUi.nav_bar(surface, "← Назад", close)
	_close = nav.get_node("NavBack") as Button
	_close.name = "Close"


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
	elif visible and view != null and event is InputEventKey and (event as InputEventKey).pressed:
		var key := (event as InputEventKey).physical_keycode
		if key == KEY_PAGEDOWN or key == KEY_PAGEUP:
			view.scroll().scroll_vertical += 360 if key == KEY_PAGEDOWN else -360
			get_viewport().set_input_as_handled()


## Пересобрать досье на вкладке «Артефакты» (каждое открытие — свежие счётчики боя).
func _refresh() -> void:
	if is_instance_valid(view):
		_content.remove_child(view)
		view.queue_free()
	view = DossierView.new()
	_content.add_child(view)
	view.configure(inventory, DossierView.TAB_ITEMS)
