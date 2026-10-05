class_name MapSelect
extends Control
##
## Сетка карт кампании: номер, название, подзаголовок, звёзды, замок для закрытых.
## Данные — Campaign.maps()/is_unlocked()/stars(), боевого кода не касается.
##
## Раскладка (slow/layout-k): сверху вниз — заголовок «Карты» → выбор сложности с подписью →
## сетка карточек → нижняя панель. Сетка занимает весь остаток высоты и сама ужимает карточки
## (вместе с их шрифтами) под него. Раньше сетка была центрована с фиксированной высотой
## карточки: при 8 картах (3 ряда) она ложилась на заголовок, панель сложности и нижнюю панель
## (H_report, «Вёрстка», п. 1–2).
##

signal map_chosen(map_id: String)
signal office_pressed
signal back

const COLS := 3
const CARD_W := 340.0
## Высота карточки: 200 — «полная» (как было), 118 — предел ужатия при 3 рядах.
const CARD_H_MAX := 200.0
const CARD_H_MIN := 118.0
const GAP := 22.0
const MARGIN := 24.0
## Нижняя панель (LegionUi.nav_bar) прижата к низу и занимает 76 px: колонка контента
## заканчивается выше неё, поэтому нижнее поле — 92.
const NAV_RESERVE := 92.0
## Ниже этого множителя шрифты карточки не ужимаются: 17/16/12 pt ещё читаются.
const FONT_FLOOR := 0.78

var _grid: GridContainer
var _cards: Array[Button] = []


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.9)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var margin := MarginContainer.new()
	UiStyle.fill_rect(margin)
	margin.add_theme_constant_override("margin_left", int(MARGIN))
	margin.add_theme_constant_override("margin_right", int(MARGIN))
	margin.add_theme_constant_override("margin_top", int(MARGIN))
	margin.add_theme_constant_override("margin_bottom", int(NAV_RESERVE))
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)

	var title := UiStyle.label("Карты", 36, UiStyle.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	# Сложность — между заголовком и сеткой, со своей строкой-подписью (DifficultyPicker).
	var picker := DifficultyPicker.new()
	picker.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(picker)

	var holder := Control.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.clip_contents = true
	column.add_child(holder)

	_grid = GridContainer.new()
	_grid.columns = COLS
	_grid.add_theme_constant_override("h_separation", int(GAP))
	_grid.add_theme_constant_override("v_separation", int(GAP))
	_grid.set_anchors_preset(Control.PRESET_CENTER)
	holder.add_child(_grid)

	var maps := Campaign.maps()
	var full_w := CARD_W * COLS + GAP * (COLS - 1)
	_grid.offset_left = -full_w * 0.5
	_grid.offset_right = full_w * 0.5
	_grid.offset_top = 0.0
	_grid.offset_bottom = 0.0

	for i in maps.size():
		var card := _build_card(maps[i], i)
		_cards.append(card)
		_grid.add_child(card)

	holder.resized.connect(_fit_cards)
	_fit_cards()

	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit(),
		"Контора (%d премии)" % Campaign.bounty(), func() -> void: office_pressed.emit())


## Ужать карточки под оставшуюся высоту: высота ряда делится поровну, шрифты едут за ней.
## Сетка при этом центрируется в holder'е по вертикали (anchors — CENTER).
func _fit_cards() -> void:
	if _cards.is_empty():
		return
	var rows := ceili(float(_cards.size()) / float(COLS))
	var card_h := clampf((_grid.get_parent() as Control).size.y / float(rows) - GAP,
		CARD_H_MIN, CARD_H_MAX)
	card_h = floorf(card_h)
	var k := clampf(card_h / CARD_H_MAX, FONT_FLOOR, 1.0)
	for card in _cards:
		card.custom_minimum_size = Vector2(CARD_W, card_h)
		_fit_card_text(card, k)
	var full_h := card_h * float(rows) + GAP * float(rows - 1)
	_grid.offset_top = -full_h * 0.5
	_grid.offset_bottom = full_h * 0.5


func _fit_card_text(card: Button, k: float) -> void:
	var fit: Dictionary = card.get_meta("fit")
	var body: VBoxContainer = fit["body"]
	body.add_theme_constant_override("separation", maxi(2, roundi(6.0 * k)))
	for key: String in ["number", "title", "subtitle", "lock", "hint", "stars"]:
		var lab: Label = fit.get(key)
		if lab == null:
			continue
		var base: int = fit.get(key + "_size", 18)
		lab.add_theme_font_size_override("font_size", maxi(10, roundi(float(base) * k)))


func _build_card(map_data: Dictionary, index: int) -> Control:
	var id := String(map_data.get("id", ""))
	var unlocked := Campaign.is_unlocked(id)
	var stars := Campaign.stars(id)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H_MAX)
	btn.clip_contents = true
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

	var fit := {"body": body}

	var number := UiStyle.label("№%d" % (index + 1), 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	body.add_child(number)
	fit["number"] = number
	fit["number_size"] = 15

	if unlocked:
		var title := UiStyle.label(
			String(map_data.get("title", id)), 22, UiStyle.FONT_TITLE, UiStyle.GOLD)
		title.autowrap_mode = TextServer.AUTOWRAP_WORD
		body.add_child(title)
		fit["title"] = title
		fit["title_size"] = 22
		var subtitle := UiStyle.label(
			String(map_data.get("subtitle", "")), 15, UiStyle.FONT_TEXT, UiStyle.TEXT)
		subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
		body.add_child(subtitle)
		fit["subtitle"] = subtitle
		fit["subtitle_size"] = 15
	else:
		var lock := UiStyle.label("🔒 Закрыто", 20, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM)
		body.add_child(lock)
		fit["lock"] = lock
		fit["lock_size"] = 20
		var hint := UiStyle.label("Пройдите предыдущий объект", 14, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD
		body.add_child(hint)
		fit["hint"] = hint
		fit["hint_size"] = 14

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(spacer)

	if unlocked:
		var stars_row := UiStyle.label(_star_text(stars), 20, UiStyle.FONT_TITLE, UiStyle.GOLD)
		body.add_child(stars_row)
		fit["stars"] = stars_row
		fit["stars_size"] = 20

	btn.set_meta("fit", fit)
	if unlocked:
		btn.pressed.connect(func() -> void: map_chosen.emit(id))
	return btn


func _star_text(stars: int) -> String:
	var filled := "★".repeat(stars)
	var empty := "☆".repeat(3 - stars)
	return filled + empty
