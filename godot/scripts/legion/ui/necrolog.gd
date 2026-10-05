class_name Necrolog
extends Control
##
## Некролог — экран конца «Бесконечного подряда»/«Вызова дня»: Котёл пал, забег кончился (BOOK
## §1: «Коллектив с прискорбием сообщает…»). Сатира на корпоративную рассылку, а не мрачный экран
## поражения — тон должен быть смешным, не тяжёлым (BOOK «замысел этапа», слова Игоря №7).
##
## Игорь 27.09 (после первой версии): «лицо режима», «красивенькая, офигенная штука» — оформлен
## как настоящий лист траурной корпоративной рассылки (не карточка UiStyle.card_box, как у
## остальных экранов): кремовая бумага в чёрной траурной рамке, шапка «Рассылка/От/Дата», портрет
## некроманта (assets/img/necromancer.png — уже готовый портрет с портфелем и кружкой, ничего
## вырезать не пришлось), линии-разделители, подпись с печатью (assets/legion/icons/
## item_named_stamp.png). Появление — тот же паттерн затемнения, что у LegionResult.
##

signal menu
signal restart
## D-0927-162: «В коллекцию» — сохранить карту объекта, на котором пал Котёл (см. show_collect).
signal collect_pressed

const PORTRAIT := preload("res://assets/img/necromancer.png")

## Палитра «бумаги» — отдельная от UiStyle (тот тёмно-фиолетовый, здесь нарочно светлый лист:
## письмо, а не игровой оверлей). Чернила — тёмно-коричневые, не чёрным по чёрному с траурной
## рамкой.
const PAPER_BG := Color(0.90, 0.86, 0.76)
const PAPER_INK := Color(0.16, 0.12, 0.09)
const PAPER_INK_DIM := Color(0.36, 0.30, 0.24)
const PAPER_BORDER := Color(0.08, 0.06, 0.05)
const PAPER_RED := Color(0.55, 0.09, 0.09)
## Тёмное бронзовое золото — UiStyle.GOLD (светлый, для тёмного фона) на кремовой бумаге читался
## бы бледно; здесь свой тон под ту же роль («особое, приз»).
const PAPER_GOLD := Color(0.55, 0.36, 0.05)


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## report — LegionRunStore.endless_end_run() (tenure/souls/*_record/is_new_*_record/daily/
## daily_date); foe_type — stats["last_hit_foe_type"] боя (может быть "" — LegionEndless.
## death_reason даёт общую фразу); map_title — название объекта, на котором пал Котёл.
## show_collect (D-0927-162) —
## «В коллекцию» доступна только для СГЕНЕРИРОВАННОЙ карты (gen: или стаб для проверки).
func show_report(report: Dictionary, foe_type: String, map_title: String,
		show_collect: bool = false) -> void:
	for c in get_children():
		c.queue_free()

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.92)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var daily := bool(report.get("daily", false))
	var box := _paper_card(680.0)

	box.add_child(_header_row(daily, String(report.get("daily_date", ""))))
	box.add_child(_rule())

	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	box.add_child(content)

	var portrait := TextureRect.new()
	portrait.texture = PORTRAIT
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.custom_minimum_size = Vector2(110.0, 110.0)
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(portrait)

	var text_col := VBoxContainer.new()
	text_col.add_theme_constant_override("separation", 4)
	text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(text_col)

	var stamp := UiStyle.label("Коллектив с прискорбием сообщает", 26, UiStyle.FONT_TITLE,
		PAPER_RED)
	stamp.autowrap_mode = TextServer.AUTOWRAP_WORD
	text_col.add_child(stamp)

	var tenure := int(report.get("tenure", 0))
	var souls := int(report.get("souls", 0))
	var reason := LegionEndless.death_reason(foe_type)
	var body_lines := [
		"Некромант не пережил окончание рабочего дня на объекте «%s»." % map_title,
		"Стаж: %d объект%s. Души: %d." % [tenure, _plural_ru(tenure), souls],
		"Причина: %s." % reason,
	]
	for line in body_lines:
		var l := UiStyle.label(line, 17, UiStyle.FONT_TEXT, PAPER_INK)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD
		text_col.add_child(l)

	box.add_child(BattleDebrief.panel(report.get("debrief", {}), PAPER_INK))
	var records := _record_lines(report)
	if not records.is_empty():
		var rec_box := VBoxContainer.new()
		rec_box.add_theme_constant_override("separation", 2)
		box.add_child(rec_box)
		for line in records:
			var r := UiStyle.label(line, 16, UiStyle.FONT_TITLE, PAPER_GOLD)
			r.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			rec_box.add_child(r)

	box.add_child(_rule())
	box.add_child(_signature_row())

	LegionUi.nav_bar(self, "В главное меню", func() -> void: menu.emit(),
		"" if daily else "Новый забег", func() -> void: restart.emit())
	if show_collect:
		box.add_child(ProgressionUi.button("В коллекцию", func() -> void: collect_pressed.emit()))



## Лист бумаги в траурной рамке (двойная чёрная обводка, кремовый фон) — центр экрана, растёт от
## содержимого, как UiStyle.card_box(), но своя (светлая) палитра: это письмо, не игровой оверлей.
func _paper_card(min_w: float) -> VBoxContainer:
	var outer := PanelContainer.new()
	outer.name = "MourningFrame"
	outer.anchor_left = 0.5
	outer.anchor_right = 0.5
	outer.anchor_top = 0.5
	outer.anchor_bottom = 0.5
	outer.grow_horizontal = Control.GROW_DIRECTION_BOTH
	outer.grow_vertical = Control.GROW_DIRECTION_BOTH
	outer.custom_minimum_size = Vector2(min_w, 0.0)
	var outer_st := StyleBoxFlat.new()
	outer_st.bg_color = PAPER_BORDER
	outer_st.set_corner_radius_all(4)
	outer_st.content_margin_left = 6.0
	outer_st.content_margin_right = 6.0
	outer_st.content_margin_top = 6.0
	outer_st.content_margin_bottom = 6.0
	outer.add_theme_stylebox_override("panel", outer_st)
	add_child(outer)

	var inner := PanelContainer.new()
	var inner_st := StyleBoxFlat.new()
	inner_st.bg_color = PAPER_BG
	inner_st.border_color = PAPER_BORDER
	inner_st.set_border_width_all(2)
	inner_st.set_corner_radius_all(2)
	inner_st.content_margin_left = 30.0
	inner_st.content_margin_right = 30.0
	inner_st.content_margin_top = 22.0
	inner_st.content_margin_bottom = 22.0
	inner.add_theme_stylebox_override("panel", inner_st)
	outer.add_child(inner)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	inner.add_child(box)
	return box


## Шапка рассылки: «Рассылка: Все сотрудники» / «От: Отдел кадров Конторы» слева, дата справа —
## Игорь 27.09: «шапка (Рассылка: Все сотрудники, От: Отдел кадров Конторы, дата игрового дня)».
## Дата — реальная (LegionEndless.today_date()) или дата «Вызова дня», если забег был им.
func _header_row(daily: bool, daily_date: String) -> Control:
	var row := HBoxContainer.new()
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 1)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	var to_line := UiStyle.label("Рассылка: Все сотрудники", 14, UiStyle.FONT_TITLE, PAPER_INK)
	left.add_child(to_line)
	var from_line := UiStyle.label(
		"От: Отдел кадров Конторы", 13, UiStyle.FONT_TEXT, PAPER_INK_DIM)
	left.add_child(from_line)

	var date_str := daily_date if daily and daily_date != "" else LegionEndless.today_date()
	var date_label := UiStyle.label("Дата: %s" % date_str, 13, UiStyle.FONT_TEXT, PAPER_INK_DIM)
	date_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	date_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	row.add_child(date_label)

	if daily:
		var tag := UiStyle.label("«Вызов дня»", 13, UiStyle.FONT_TITLE, PAPER_RED)
		left.add_child(tag)
	return row


## Тонкая траурная линейка-разделитель — тот же чёрный, что рамка листа.
func _rule() -> Control:
	var r := ColorRect.new()
	r.color = PAPER_BORDER
	r.custom_minimum_size = Vector2(0.0, 2.0)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Подпись с печатью и цветами от профсоюза — низ листа.
func _signature_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(LegionIcons.rect("item_named_stamp", 40.0))
	var sig_col := VBoxContainer.new()
	sig_col.add_theme_constant_override("separation", 1)
	row.add_child(sig_col)
	var sig := UiStyle.label("Отдел кадров Конторы", 15, UiStyle.FONT_TITLE, PAPER_INK)
	sig_col.add_child(sig)
	var flowers := UiStyle.label("Цветы — за счёт профсоюза.", 15, UiStyle.FONT_TEXT, PAPER_INK_DIM)
	sig_col.add_child(flowers)
	return row


func _record_lines(report: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if bool(report.get("is_new_tenure_record", false)):
		out.append("Новый личный рекорд стажа: %d!" % int(report.get("tenure", 0)))
	else:
		out.append("Личный рекорд стажа: %d" % int(report.get("tenure_record", 0)))
	if bool(report.get("is_new_souls_record", false)):
		out.append("Новый личный рекорд душ: %d!" % int(report.get("souls", 0)))
	else:
		out.append("Личный рекорд душ: %d" % int(report.get("souls_record", 0)))
	return out


## Число объектов по-русски: 1 объект, 2–4 объекта, 5+ объектов (и 11–14 — тоже «объектов»).
func _plural_ru(n: int) -> String:
	var n10 := n % 10
	var n100 := n % 100
	if n10 == 1 and n100 != 11:
		return ""
	if n10 in [2, 3, 4] and not (n100 in [12, 13, 14]):
		return "а"
	return "ов"
