class_name EndlessBriefing
extends Control
##
## Брифинг объекта «Бесконечного подряда»/«Вызова дня» (mode line, BOOK §1–2). Тот же язык, что
## у Briefing кампании (название/подзаголовок/подсказка/«Кто идёт по объекту»), плюс шапка забега
## (номер объекта, стаж и души, накопленные ДО этого объекта) и переключатель сложности — в
## кампании его показывает MapSelect, здесь своего выбора карт нет, поэтому пикер стоит тут же.
##

signal start(map_id: String)
signal back
## Игрок взял пакет подготовки на брифинге (озвучка покупки — у LegionMain).
signal prep_bought


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## map_data — словарь карты объекта (кампанийный формат — раздел 3 STAGE2.md); k — номер объекта
## забега; tenure/souls — стаж и души, накопленные ДО этого объекта (после победы над ним они
## вырастут); daily/daily_date — «Вызов дня» и его дата, для подписи в шапке.
func populate(map_data: Dictionary, k: int, tenure: int, souls: int, daily: bool,
		daily_date: String) -> void:
	for c in get_children():
		c.queue_free()

	var map_id := String(map_data.get("id", ""))

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.88)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var box := UiStyle.card_box(self, 640.0, 10)

	var mode_label := UiStyle.label(
		("«Вызов дня» · %s" % daily_date) if daily else "Бесконечный подряд", 16,
		UiStyle.FONT_TITLE, UiStyle.SOUL)
	mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(mode_label)

	var header := UiStyle.label("Объект №%d" % k, 24, UiStyle.FONT_TITLE, UiStyle.GOLD)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(header)

	var tally := UiStyle.label("Объектов пройдено: %d · Души: %d" % [tenure, souls],
		16, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	tally.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(tally)
	box.add_child(ProgressionUi.text("Разряд открывает варианты поправок. "
		+ "Опыт растёт только в кампании.", 15, UiStyle.TEXT_DIM))

	# D-0927-96: рекорды — отдельно по сложности («Вызов дня» — ещё и по дате); показываем рекорд
	# ТОЙ сложности, с которой реально пойдёт объект (закреплённая — у «Вызова дня» ПОСЛЕ старта
	# первого объекта, иначе живой выбор пикера ниже).
	var locked := LegionRunStore.is_difficulty_locked(daily)
	var effective_diff := LegionRunStore.run_difficulty(daily) if locked else Settings.difficulty()
	var rec_tenure := LegionRunStore.endless_best_tenure(daily_date if daily else "", effective_diff)
	var rec_souls := LegionRunStore.endless_best_souls(daily_date if daily else "", effective_diff)
	if rec_tenure > 0 or rec_souls > 0:
		var rec := UiStyle.label(
			"Рекорд (%s): стаж %d · души %d"
				% [LegionChallenge.title(effective_diff), rec_tenure, rec_souls],
			14, UiStyle.FONT_TEXT, UiStyle.GOLD)
		rec.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(rec)

	var title := UiStyle.label(String(map_data.get("title", map_id)), 30, UiStyle.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := UiStyle.label(
		String(map_data.get("subtitle", "")), 17, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(subtitle)

	var hint := String(map_data.get("hint", ""))
	if hint != "":
		var hint_label := UiStyle.label(Controls.text(hint), 16, UiStyle.FONT_TEXT, UiStyle.TEXT)
		hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(hint_label)

	var threats := _threat_list(map_data, effective_diff)
	if not threats.is_empty():
		var threats_title := UiStyle.label(
			"Кто идёт по объекту", 15, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM)
		threats_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(threats_title)
		var threats_row := UiStyle.label(", ".join(threats), 16, UiStyle.FONT_TEXT, UiStyle.WARN)
		threats_row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		threats_row.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(threats_row)

	# D-0927-96/-120: сложность забега (обоих видов) «выбирается перед стартом и фиксируется» —
	# пикер живой только пока не закреплена (брифинг объекта 1 ДО «В бой»); дальше — подпись,
	# менять нечего до конца забега (иначе рекорд набивался бы сменой сложности посреди забега).
	if locked:
		var locked_label := UiStyle.label(
			"Сложность: %s (закреплена на весь %s)" % [LegionChallenge.title(effective_diff),
				"«Вызов дня»" if daily else "забег"],
			17, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM)
		locked_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(locked_label)
	else:
		var picker := DifficultyPicker.new()
		box.add_child(picker)

	# D-1007-P1/P2: что действует и подготовка — в карточке, как у брифинга кампании.
	Briefing.add_prep_block(box).changed.connect(func(bought: bool) -> void:
		if bought:
			prep_bought.emit())

	LegionUi.nav_bar(self, "В главное меню", func() -> void: back.emit(),
		"В бой", func() -> void: start.emit(map_id))


## Тот же расчёт угроз, что Briefing кампании (Briefing.FOE_NAMES — общий словарь имён).
## difficulty — не всегда живой Settings.difficulty(): у закреплённого «Вызова дня» это может
## быть сложность, выбранная ДО закрепления, если игрок потом сходил в кампанию и переключил
## глобальную настройку — угрозы должны показывать ту сложность, с которой реально пойдёт бой.
func _threat_list(map_data: Dictionary, difficulty: String) -> Array[String]:
	var seen: Dictionary = {}
	var out: Array[String] = []
	var waves: Array = LegionChallenge.apply_map(map_data, difficulty).get("waves", [])
	for wave in waves:
		if not (wave is Dictionary):
			continue
		var groups: Array = wave.get("groups", [])
		for group in groups:
			if not (group is Dictionary):
				continue
			var type_id := String(group.get("type", ""))
			if type_id == "" or seen.has(type_id):
				continue
			seen[type_id] = true
			out.append(String(Briefing.FOE_NAMES.get(type_id, type_id)))
	return out
