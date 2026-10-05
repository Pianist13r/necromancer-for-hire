class_name LegionCollectionScreen
extends Control
##
## D-0927-162: экран «Коллекция» — список сохранённых карт объектов, «Играть»/«Убрать» на каждую.
## Экран сам зовёт LegionCollection.remove()/repopulate() — тот же приём, что OfficeShop.gd зовёт
## Campaign.shop_buy() напрямую; LegionMain нужен только для запуска боя («Играть»).
##

signal play_requested(map_id: String)
signal back

## Русские подписи биомов (BOOK §6) — только для отображения, генератор и карты знают их латиницей.
const BIOME_LABELS := {
	"grave": "кладбище", "office": "контора", "swamp": "болото", "ash": "пустырь",
	"site": "стройка", "boiler": "котельная", "winter": "зимний погост", "hell": "приёмная Ада",
}
const SOURCE_LABELS := {"endless": "Бесконечный подряд", "daily": "Вызов дня"}


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	populate()


func populate() -> void:
	for c in get_children():
		c.queue_free()

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.92)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var title := UiStyle.label("Коллекция", 34, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 30.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var list := LegionCollection.entries()

	if list.is_empty():
		var empty_label := UiStyle.label(
			"Коллекция пуста. Сохраните карту во время боя (пауза) или на итоге объекта.",
			18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		empty_label.set_anchors_preset(Control.PRESET_CENTER)
		empty_label.position = Vector2(-320.0, -20.0)
		empty_label.size = Vector2(640.0, 40.0)
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		add_child(empty_label)
	else:
		var scroll := ScrollContainer.new()
		scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		scroll.offset_top = 90.0
		scroll.offset_bottom = -80.0
		scroll.offset_left = 60.0
		scroll.offset_right = -60.0
		add_child(scroll)

		var rows := VBoxContainer.new()
		rows.add_theme_constant_override("separation", 10)
		rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(rows)

		# Свежие сверху — саму запись сохраняем в порядке добавления (FIFO), список для игрока
		# удобнее видеть в обратном порядке (последняя сохранённая карта — первой в списке).
		for i in range(list.size() - 1, -1, -1):
			rows.add_child(_build_row(list[i]))

	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit())



func _build_row(entry: Dictionary) -> Control:
	var map_id := String(entry.get("map_id", ""))

	var panel := PanelContainer.new()
	var st := UiStyle.panel_style(Color(0.13, 0.09, 0.06, 0.92), 10)
	st.border_color = Cfg.RUNE_COLOR
	st.set_border_width_all(2)
	st.content_margin_left = 16.0
	st.content_margin_right = 16.0
	st.content_margin_top = 10.0
	st.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", st)
	panel.custom_minimum_size = Vector2(0.0, 0.0)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	var title := UiStyle.label(String(entry.get("title", map_id)), 20, UiStyle.FONT_TITLE)
	info.add_child(title)

	var card: Dictionary = {}
	var biome := String(entry.get("biome", ""))
	var archetype := String(entry.get("archetype", ""))
	var meta_bits: Array[String] = []
	if biome != "":
		meta_bits.append(String(BIOME_LABELS.get(biome, biome)))
	if archetype != "":
		meta_bits.append(archetype)
	meta_bits.append(LegionChallenge.title(String(entry.get("difficulty", ""))))
	meta_bits.append(String(SOURCE_LABELS.get(String(entry.get("source", "")), "?")))
	meta_bits.append(String(entry.get("saved_date", "")))
	var meta_label := UiStyle.label(" · ".join(meta_bits), 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	info.add_child(meta_label)

	var best: Dictionary = entry.get("best_result", {})
	if not best.is_empty():
		var verdict := "победа" if bool(best.get("victory", false)) else "поражение"
		var pct := roundi(100.0 * float(best.get("hp_ratio", 0.0)))
		var best_label := UiStyle.label(
			"Лучший результат: %s, HP Котла %d%%" % [verdict, pct], 14, UiStyle.FONT_TEXT,
			UiStyle.GOOD if bool(best.get("victory", false)) else UiStyle.WARN)
		info.add_child(best_label)

	if LegionCollection.entry_stale(entry):
		var stale := UiStyle.label(
			"Старая версия генератора — карта может выглядеть иначе", 13, UiStyle.FONT_TEXT,
			UiStyle.WARN)
		info.add_child(stale)

	var play_btn := Button.new()
	play_btn.text = "Играть"
	play_btn.custom_minimum_size = Vector2(110.0, 40.0)
	play_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	play_btn.add_theme_font_size_override("font_size", 17)
	play_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UiStyle.style_button(play_btn)
	play_btn.pressed.connect(func() -> void: play_requested.emit(map_id))
	row.add_child(play_btn)

	var remove_btn := Button.new()
	remove_btn.text = "Убрать"
	remove_btn.custom_minimum_size = Vector2(110.0, 40.0)
	remove_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	remove_btn.add_theme_font_size_override("font_size", 17)
	remove_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UiStyle.style_button(remove_btn)
	remove_btn.pressed.connect(func() -> void:
		LegionUi.confirm(self, "Убрать карту из коллекции? Сохранённая запись будет удалена.",
			func() -> void:
				LegionCollection.remove(map_id)
				populate()))
	row.add_child(remove_btn)

	return panel
