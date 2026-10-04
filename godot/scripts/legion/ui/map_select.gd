class_name MapSelect
extends Control
##
## Сетка карт кампании 3×2: номер, название, подзаголовок, звёзды, замок для закрытых.
## Данные — Campaign.maps()/is_unlocked()/stars(), боевого кода не касается.
##

signal map_chosen(map_id: String)
signal office_pressed
signal back

const COLS := 3
const CARD_W := 340.0
const CARD_H := 200.0
const GAP := 22.0


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.9)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var title := UiStyle.label("Карты", 36, UiStyle.FONT_TITLE)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 40.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var grid := GridContainer.new()
	grid.columns = COLS
	grid.add_theme_constant_override("h_separation", int(GAP))
	grid.add_theme_constant_override("v_separation", int(GAP))
	grid.set_anchors_preset(Control.PRESET_CENTER)
	var maps := Campaign.maps()
	var rows := ceili(float(maps.size()) / float(COLS))
	var full_w := CARD_W * COLS + GAP * (COLS - 1)
	var full_h := CARD_H * rows + GAP * (rows - 1)
	grid.offset_left = -full_w * 0.5
	grid.offset_right = full_w * 0.5
	grid.offset_top = -full_h * 0.5 + 10.0
	grid.offset_bottom = full_h * 0.5 + 10.0
	add_child(grid)

	for i in maps.size():
		grid.add_child(_build_card(maps[i], i))

	# slow/challenge: сложность — между заголовком и сеткой (сетка начинается с y≈159)
	var picker := DifficultyPicker.new()
	picker.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	picker.offset_top = 88.0
	picker.offset_bottom = 152.0
	add_child(picker)

	# meta: «Контора» доступна и из выбора карт (задание meta п.2), не только из меню.
	var bottom_row := HBoxContainer.new()
	bottom_row.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom_row.add_theme_constant_override("separation", 14)
	bottom_row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_row.offset_top = -70.0
	bottom_row.offset_bottom = -20.0
	add_child(bottom_row)

	var office_btn := Button.new()
	office_btn.text = "Контора (%d)" % Campaign.bounty()
	office_btn.custom_minimum_size = Vector2(180.0, 42.0)
	office_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	office_btn.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(office_btn)
	office_btn.pressed.connect(func() -> void: office_pressed.emit())
	bottom_row.add_child(office_btn)

	var back_btn := Button.new()
	back_btn.text = "Назад"
	back_btn.custom_minimum_size = Vector2(160.0, 42.0)
	back_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	back_btn.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(back_btn)
	back_btn.pressed.connect(func() -> void: back.emit())
	bottom_row.add_child(back_btn)


func _build_card(map_data: Dictionary, index: int) -> Control:
	var id := String(map_data.get("id", ""))
	var unlocked := Campaign.is_unlocked(id)
	var stars := Campaign.stars(id)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.disabled = not unlocked
	btn.focus_mode = Control.FOCUS_ALL if unlocked else Control.FOCUS_NONE

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.13, 0.09, 0.06, 0.95) if unlocked else Color(0.08, 0.08, 0.08, 0.9)
	normal.border_color = Cfg.RUNE_COLOR if unlocked else Color(0.3, 0.3, 0.3)
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(12)
	normal.content_margin_left = 18.0
	normal.content_margin_right = 18.0
	normal.content_margin_top = 16.0
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.2, 0.14, 0.08, 0.98)
	hover.border_color = Cfg.RUNE_CORE
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	btn.add_theme_stylebox_override("disabled", normal)
	if unlocked:
		btn.add_theme_stylebox_override("focus", hover)

	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 16.0
	body.offset_top = 12.0
	body.offset_right = -16.0
	body.offset_bottom = -12.0
	body.add_theme_constant_override("separation", 6)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(body)

	var number := UiStyle.label("№%d" % (index + 1), 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	body.add_child(number)

	if unlocked:
		var title := UiStyle.label(
			String(map_data.get("title", id)), 22, UiStyle.FONT_TITLE, UiStyle.GOLD)
		title.autowrap_mode = TextServer.AUTOWRAP_WORD
		body.add_child(title)
		var subtitle := UiStyle.label(
			String(map_data.get("subtitle", "")), 15, UiStyle.FONT_TEXT, UiStyle.TEXT)
		subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
		body.add_child(subtitle)
	else:
		var lock := UiStyle.label("🔒 Закрыто", 20, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM)
		body.add_child(lock)
		var hint := UiStyle.label("Пройдите предыдущий объект", 14, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD
		body.add_child(hint)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(spacer)

	if unlocked:
		var stars_row := UiStyle.label(_star_text(stars), 20, UiStyle.FONT_TITLE, UiStyle.GOLD)
		body.add_child(stars_row)

	if unlocked:
		btn.pressed.connect(func() -> void: map_chosen.emit(id))
	return btn


func _star_text(stars: int) -> String:
	var filled := "★".repeat(stars)
	var empty := "☆".repeat(3 - stars)
	return filled + empty
