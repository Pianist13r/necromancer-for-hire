class_name UpgradePicker
extends Control
##
## Модал «Поправка к договору №…» между картами кампании: 3 карточки из LegionMetaCfg.UPGRADE_POOL,
## выбор одной. Раскладка повторяет `scripts/ui/upgrade_screen.gd` (карточка-пергамент), с новыми
## текстами и без завязки на CfgMeta (та мета — старого режима).
##

signal picked(id: StringName)

const CARD_W := 320.0
const CARD_H := 260.0
const GAP := 30.0

var _cards_box: HBoxContainer


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.01, 0.04, 0.85)
	UiStyle.fill_rect(dim)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var title := UiStyle.label("Поправка к договору", 30, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 90.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var subtitle := UiStyle.label("Выберите одну — обратной силы не имеет", 17,
		UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	subtitle.offset_top = 134.0
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(subtitle)

	_cards_box = HBoxContainer.new()
	_cards_box.add_theme_constant_override("separation", int(GAP))
	_cards_box.set_anchors_preset(Control.PRESET_CENTER)
	_cards_box.offset_left = -(CARD_W * 1.5 + GAP)
	_cards_box.offset_right = CARD_W * 1.5 + GAP
	_cards_box.offset_top = -CARD_H * 0.5 + 10.0
	_cards_box.offset_bottom = CARD_H * 0.5 + 10.0
	add_child(_cards_box)


## options — id из LegionMetaCfg.UPGRADE_POOL (например, Campaign.offer_upgrades()).
func offer(options: Array) -> void:
	for c in _cards_box.get_children():
		c.queue_free()
	for id in options:
		_cards_box.add_child(_build_card(StringName(id)))


func _build_card(id: StringName) -> Control:
	var data: Dictionary = LegionMetaCfg.UPGRADE_POOL.get(String(id), {})
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.focus_mode = Control.FOCUS_ALL

	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.13, 0.09, 0.06, 0.95)
	normal.border_color = Color(0.79, 0.64, 0.35)
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(14)
	normal.content_margin_left = 20.0
	normal.content_margin_right = 20.0
	normal.content_margin_top = 22.0
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.2, 0.14, 0.08, 0.98)
	hover.border_color = UiStyle.GOLD
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	btn.add_theme_stylebox_override("focus", hover)

	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 20.0
	body.offset_top = 16.0
	body.offset_right = -20.0
	body.offset_bottom = -16.0
	body.add_theme_constant_override("separation", 10)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(body)

	var seal := UiStyle.label("✒", 26, UiStyle.FONT_TITLE, Color(0.74, 0.52, 0.98))
	seal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(seal)

	var title := UiStyle.label(
		String(data.get("title", String(id))), 21, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	body.add_child(title)

	var desc := UiStyle.label(String(data.get("text", "")), 16, UiStyle.FONT_TEXT, UiStyle.TEXT)
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc.custom_minimum_size = Vector2(CARD_W - 44.0, 0.0)
	body.add_child(desc)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(spacer)

	var hint := UiStyle.label("Подписать ✒", 17, UiStyle.FONT_TEXT, UiStyle.GOLD.darkened(0.15))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(hint)

	btn.pressed.connect(func() -> void: picked.emit(id))
	return btn
