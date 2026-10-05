class_name ProgressionUi
extends RefCounted
## Прокручивается содержимое; выход всегда виден.

static func shell(screen: Control, title: String, subtitle: String) -> Dictionary:
	UiStyle.fill_rect(screen)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.035, 0.025, 0.065, 0.98)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	screen.add_child(backdrop)
	var margin := MarginContainer.new()
	UiStyle.fill_rect(margin)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 92 if side == "bottom" else 24)
	screen.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	column.add_child(UiStyle.label(title, 32, UiStyle.FONT_TITLE, UiStyle.GOLD))
	var note := text(subtitle, 19, UiStyle.TEXT_DIM)
	column.add_child(note)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	column.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	scroll.add_child(body)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 14)
	column.add_child(footer)
	return {"body": body, "footer": footer, "note": note}


static func text(value: String, size := 18, color := UiStyle.TEXT) -> Label:
	var label := UiStyle.label(value, size, UiStyle.FONT_TEXT, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func button(value: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = value
	btn.custom_minimum_size = Vector2(150.0, 48.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 19)
	UiStyle.style_button(btn)
	btn.pressed.connect(callback)
	return btn


static func clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


static func grid() -> GridContainer:
	var out := GridContainer.new()
	out.columns = 3
	out.add_theme_constant_override("h_separation", 16)
	out.add_theme_constant_override("v_separation", 16)
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return out


static func resize_grid(grid_node: GridContainer, width: float) -> void:
	grid_node.columns = clampi(int((width - 48.0) / 285.0), 1, 3)
