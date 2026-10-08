class_name SlotStrip
extends HBoxContainer
##
## Полоса «Редакция договора» (переработка 06.10.2026, Э2): три слота активных поправок видны и на
## выборе поправок, и в «Конторе», и в досье — игрок сразу видит, что у него уже действует.
## Заполненный слот: иконка, название и цвет ветки. Пустой — пунктирная рамка «пусто».
## На экране замены (interactive) клик по заполненному слоту = вычеркнуть: emit slot_pressed(index).
##

signal slot_pressed(index: int)

const SLOT_H := 66.0


func configure(active: Array, interactive := false, compact := false) -> void:
	add_theme_constant_override("separation", 10)
	var accent := Color(0.47, 0.76, 0.90)
	for i in AmendmentDb.MAX_ACTIVE:
		var id: StringName = active[i] if i < active.size() else &""
		add_child(_slot(i, id, interactive, compact, accent))


func _slot(index: int, id: StringName, interactive: bool, compact: bool,
		accent: Color) -> Button:
	var btn := Button.new()
	btn.name = "Slot%d" % index
	btn.flat = true
	btn.custom_minimum_size = Vector2(0.0, 44.0 if compact else SLOT_H)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE
	var filled := id != &"" and not AmendmentDb.card(id).is_empty()
	btn.focus_mode = Control.FOCUS_ALL if filled else Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
		if filled else Control.CURSOR_ARROW
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var data := AmendmentDb.card(id) if filled else {}
	if filled:
		btn.tooltip_text = Controls.text("%s\n%s\nМелкий шрифт: %s\n%s" % [
			data.get("title", id), data.get("text", ""), data.get("tradeoff", ""),
			data.get("hint", "")])
		var focus := StyleBoxFlat.new()
		focus.draw_center = false
		focus.border_color = UiStyle.GOLD
		focus.set_border_width_all(3)
		btn.add_theme_stylebox_override("focus", focus)
	var tag := String(data.get("tag", "law"))
	var col: Color = AmendmentDb.TAGS.get(tag, AmendmentDb.TAGS["law"])["color"] if filled else accent
	btn.add_child(_frame(filled, col))

	var m := MarginContainer.new()
	UiStyle.fill_rect(m)
	for side: String in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 6 if compact else 8)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(m)
	if filled:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.add_child(row)
		row.add_child(LegionIcons.rect(String(data.get("icon", "shop_general")),
			28.0 if compact else 40.0))
		var names := VBoxContainer.new()
		names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		names.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		names.mouse_filter = Control.MOUSE_FILTER_IGNORE
		names.add_theme_constant_override("separation", 0)
		row.add_child(names)
		if not compact:
			names.add_child(UiStyle.label(String(AmendmentDb.TAGS.get(tag,
				AmendmentDb.TAGS["law"])["title"]).to_upper(), 13, UiStyle.FONT_TEXT, col))
		var t := UiStyle.label(String(data.get("title", id)), 15 if compact else 17,
			UiStyle.FONT_TITLE, UiStyle.TEXT)
		t.clip_text = true
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		names.add_child(t)
		# Экран замены: слот — кнопка «вычеркнуть»; без надписи щелчок по слоту не угадать.
		if interactive:
			var cross := UiStyle.label("× вычеркнуть", 15, UiStyle.FONT_TEXT, UiStyle.BAD)
			cross.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(cross)
	else:
		var empty := UiStyle.label("пусто", 15 if compact else 17, UiStyle.FONT_TEXT,
			Color(UiStyle.TEXT_DIM, 0.7))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.add_child(empty)
	if interactive and filled:
		btn.pressed.connect(func() -> void: slot_pressed.emit(index))
	elif filled:
		btn.pressed.connect(func() -> void: ProgressionUi.inspect_card(self, id))
	return btn


## Рамка слота: заполненный — сплошная цветом ветки, пустой — пунктирная.
func _frame(filled: bool, color: Color) -> Control:
	var box := _SlotBox.new()
	box.filled = filled
	box.accent = color
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiStyle.fill_rect(box)
	return box


## Рисует рамку слота: сплошную или пунктирную (StyleBoxFlat пунктира не умеет).
class _SlotBox:
	extends Control

	const DASH := 9.0
	const GAP := 7.0

	var filled := true
	var accent := Color.WHITE

	func _draw() -> void:
		var r := Rect2(Vector2(2.0, 2.0), size - Vector2(4.0, 4.0))
		var bg := Color(0.09, 0.075, 0.12, 0.94) if filled else Color(0.06, 0.05, 0.08, 0.55)
		draw_rect(r, bg, true)
		var col := Color(accent, 0.95) if filled else Color(accent, 0.5)
		if filled:
			draw_rect(r, col, false, 2.0)
		else:
			_dashed(r, col, 2.0)

	func _dashed(r: Rect2, col: Color, w: float) -> void:
		var corners := [r.position, Vector2(r.end.x, r.position.y), r.end,
			Vector2(r.position.x, r.end.y), r.position]
		for i in 4:
			_dash_line(corners[i], corners[i + 1], col, w)

	func _dash_line(a: Vector2, b: Vector2, col: Color, w: float) -> void:
		var length := a.distance_to(b)
		var dir := a.direction_to(b)
		var t := 0.0
		while t < length:
			var seg := minf(DASH, length - t)
			draw_line(a + dir * t, a + dir * (t + seg), col, w, true)
			t += DASH + GAP
