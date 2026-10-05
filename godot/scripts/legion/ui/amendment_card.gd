class_name AmendmentCard
extends Button
## Действие и цена видны до клика. Цвет дополняет подпись ветки.

var amendment_id: StringName = &""


## together — экран выбора (UpgradePicker): под карточкой строка «Вместе с „X“: …» для ключей,
## которые карточка делит с уже действующими поправками/артефактами (MetaMods.together_notes —
## тот же свод, что считает бой). На витринах «Конторы» и героя строка не нужна — там не выбирают.
## compact — экран замены (UpgradePicker в режиме вычёркивания): карточки стоят в ряд по три,
## во всю ширину не разворачиваются и должны уложиться в окно без прокрутки — мельче поля,
## значки и шрифты, вместо 440 px высоты 232.
func configure(id: StringName, data: Dictionary, action: String = "Подписать",
		together := false, compact := false) -> AmendmentCard:
	amendment_id = id
	var pad := 12 if compact else 18
	var gap := 5 if compact else 8
	var f_tag := 12 if compact else 15
	var f_title := 18 if compact else 24
	var f_text := 15 if compact else 20
	var f_price := 14 if compact else 18
	var f_hint := 13 if compact else 17
	var f_action := 15 if compact else 19
	custom_minimum_size = Vector2(232.0, 300.0) if compact else Vector2(250.0, 440.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tag := String(data.get("tag", "law"))
	var color: Color = AmendmentDb.TAGS.get(tag, AmendmentDb.TAGS["law"])["color"]
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.085, 0.075, 0.115)
	normal.border_color = color.darkened(0.25)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.15, 0.13, 0.19)
	hover.border_color = color
	var focus: StyleBoxFlat = hover.duplicate()
	focus.set_border_width_all(4)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("pressed", hover)
	add_theme_stylebox_override("focus", focus)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, pad)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", gap)
	margin.add_child(column)
	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_constant_override("separation", 8 if compact else 14)
	column.add_child(header)
	header.add_child(LegionIcons.rect(String(data.get("icon", "shop_general")),
		44.0 if compact else 62.0))
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(names)
	names.add_child(ProgressionUi.text(String(AmendmentDb.TAGS.get(tag,
		AmendmentDb.TAGS["law"])["title"]).to_upper(), f_tag, color))
	names.add_child(ProgressionUi.text(String(data.get("title", id)), f_title, UiStyle.TEXT))
	column.add_child(ProgressionUi.text(String(data.get("text", "")), f_text))
	var price := String(data.get("tradeoff", ""))
	if price != "":
		column.add_child(ProgressionUi.text("Мелкий шрифт: " + price, f_price, UiStyle.WARN))
	var hint := String(data.get("hint", ""))
	if hint != "":
		column.add_child(ProgressionUi.text(hint, f_hint, UiStyle.TEXT_DIM))
	if together:
		for note in MetaMods.together_notes(amendment_id):
			column.add_child(ProgressionUi.text(note, 17, UiStyle.GOLD))
	var space := Control.new()
	space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(space)
	column.add_child(ProgressionUi.text(action, f_action, color))
	return self
