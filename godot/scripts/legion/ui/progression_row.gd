class_name ProgressionRow
extends VBoxContainer
##
## Строка вместо карточки 250×440 (переработка 06.10.2026, Э2): иконка, название строкой, эффект
## одной строкой, справа — чипы дельт; детали (полный текст, «мелкий шрифт», подсказка, строка
## «Вместе с …») раскрываются ПОД этой же строкой, только когда она в фокусе или под курсором.
## Один элемент на все три экрана меты: выбор поправок, «Контора», досье.
##
## Строка — Button (клик/фокус/наведение), но без «рамочной» кнопочной шкурки: фон — тёмная плашка
## строки, справа чипы-плашки. Детали всегда построены как дочерние Label (экран выбора читает их
## текстом), но видимы только у раскрытой строки.
##

signal pressed(id: StringName)

const ROW_H := 72.0

var amendment_id: StringName = &""
var _btn: Button = null


## Кнопка строки — наружу для тестов и экранов (фокус, disabled, connect).
func button() -> Button:
	return _btn


func configure(id: StringName, data: Dictionary, action := "", opts := {}) -> ProgressionRow:
	amendment_id = id
	add_theme_constant_override("separation", 0)
	var tag := String(data.get("tag", "law"))
	var tag_color: Color = AmendmentDb.TAGS.get(tag, AmendmentDb.TAGS["law"])["color"]
	var row_h := float(opts.get("row_h", ROW_H))
	var interactive := bool(opts.get("interactive", true))

	var plate := PanelContainer.new()
	var st := UiStyle.panel_style(Color(0.085, 0.075, 0.115, 0.96), 8)
	st.border_color = Color(tag_color, 0.55)
	st.set_border_width_all(2)
	st.content_margin_left = 12.0
	st.content_margin_right = 12.0
	st.content_margin_top = 6.0
	st.content_margin_bottom = 6.0
	plate.add_theme_stylebox_override("panel", st)
	plate.custom_minimum_size = Vector2(0.0, row_h)
	add_child(plate)

	var button := Button.new()
	button.name = "RowButton"
	_btn = button
	button.flat = true
	button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	button.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	button.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	button.add_theme_stylebox_override("focus", _focus_style(tag_color))
	button.focus_mode = Control.FOCUS_ALL if interactive else Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if interactive \
		else Control.CURSOR_ARROW
	plate.add_child(button)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiStyle.fill_rect(line)
	button.add_child(line)
	line.add_child(LegionIcons.rect(String(data.get("icon", "shop_general")),
		float(opts.get("icon", 48.0))))

	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	names.add_theme_constant_override("separation", 0)
	line.add_child(names)
	var title := UiStyle.label(String(data.get("title", id)), 20, UiStyle.FONT_TITLE, tag_color)
	names.add_child(title)
	var eff_text := String(data.get("short", ""))
	if eff_text == "":
		eff_text = AmendmentDb.short_text(amendment_id)
	if eff_text == "":
		eff_text = String(data.get("text", ""))
	var effect := UiStyle.label(eff_text, 17, UiStyle.FONT_TEXT, UiStyle.TEXT)
	effect.clip_text = true
	effect.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	names.add_child(effect)

	var right := String(opts.get("right", ""))
	if right != "":
		var r := UiStyle.label(right, 17, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		r.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(r)

	if bool(opts.get("chips", true)):
		var chips := HBoxContainer.new()
		chips.add_theme_constant_override("separation", 6)
		chips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for chip_text in MetaMods.delta_chips(data.get("mods", {})):
			chips.add_child(_chip(chip_text, tag_color))
		line.add_child(chips)

	# ── Детали под строкой (скрыты, пока строка не в фокусе/не под курсором) ─────────────────────
	var details := VBoxContainer.new()
	details.add_theme_constant_override("separation", 4)
	details.visible = bool(opts.get("expanded", false))
	add_child(details)
	details.add_child(_line(String(data.get("text", "")), 18, UiStyle.TEXT))
	var price := String(data.get("tradeoff", ""))
	if price != "":
		details.add_child(_line("Мелкий шрифт: " + price, 16, UiStyle.WARN))
	var hint := String(data.get("hint", ""))
	if hint != "":
		details.add_child(_line(hint, 16, UiStyle.TEXT_DIM))
	if bool(opts.get("together", false)):
		for note in MetaMods.together_notes(amendment_id):
			details.add_child(_line(note, 16, UiStyle.GOLD))
	if action != "":
		details.add_child(_line(action, 16, tag_color))

	if interactive:
		button.pressed.connect(func() -> void: pressed.emit(amendment_id))
		button.focus_entered.connect(func() -> void: details.visible = true)
		button.mouse_entered.connect(func() -> void: details.visible = true)
		button.focus_exited.connect(func() -> void: details.visible = false)
		button.mouse_exited.connect(func() -> void: details.visible = false)
	return self


## Строка деталей (раскрытие под строкой) — видима только у выбранной/наведённой строки.
func details() -> VBoxContainer:
	for c in get_children():
		if c is VBoxContainer:
			return c as VBoxContainer
	return null


static func _focus_style(accent: Color) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.draw_center = false
	st.border_color = Color(accent, 0.95)
	st.set_border_width_all(3)
	st.set_corner_radius_all(8)
	return st


func _line(value: String, size: int, color: Color) -> Label:
	var l := ProgressionUi.text(value, size, color)
	return l


func _chip(value: String, accent: Color) -> PanelContainer:
	var chip := PanelContainer.new()
	var st := UiStyle.panel_style(Color(0.12, 0.10, 0.16, 0.95), 6)
	st.border_color = Color(accent, 0.35)
	st.set_border_width_all(1)
	st.content_margin_left = 7.0
	st.content_margin_right = 7.0
	st.content_margin_top = 2.0
	st.content_margin_bottom = 2.0
	chip.add_theme_stylebox_override("panel", st)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(UiStyle.label(value, 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM))
	return chip
