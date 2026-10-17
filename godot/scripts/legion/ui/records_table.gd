class_name RecordsTable
extends RefCounted
##
## Вкладка «Рекорды» «Досье» (slow/records 10.10.2026): личные рекорды по картам и сложностям из
## LegionRecords, строки «Подряд»/«Вызов дня» из рекордов забега (Campaign.ENDLESS_RECORDS_SECTION)
## и счёт «Схватки» с ботом. Только Control-дерево из данных сохранения — боевого кода не касается.
## Отдельный файл, чтобы DossierView не рос за предел строк.
##

const CELL_W := 190.0
const NAME_W := 230.0
const EMPTY := "—"


## Вся вкладка: VBox с разделами; пустые разделы коллекции не показываются.
static func build() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "RecordsTab"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	box.add_child(DailyBoard.new())
	box.add_child(_note(I18n.t("Лучшая победа на карте: больше HP Котла, при равенстве — быстрее. ")
		+ I18n.t("Поражения рекорд не меняют.")))
	var campaign_rows: Array = []
	for m in Campaign.maps():
		var id := String(m.get("id", ""))
		campaign_rows.append([I18n.map_text(String(m.get("title", id))),
			_run_cells(LegionRecords.MODE_CAMPAIGN, id)])
	box.add_child(_section(I18n.t("Кампания"), "CampaignRecords", campaign_rows))
	var collection := {}
	for row: Dictionary in LegionRecords.rows(LegionRecords.MODE_COLLECTION):
		collection[String(row["map"])] = I18n.map_text(String(row.get("title", row["map"])))
	if not collection.is_empty():
		var rows: Array = []
		for id: String in collection:
			rows.append([collection[id], _run_cells(LegionRecords.MODE_COLLECTION, id)])
		box.add_child(_section(I18n.t("Коллекция"), "CollectionRecords", rows))
	box.add_child(_section(I18n.t("Подряд и «Вызов дня»"), "EndlessRecords", [
		[I18n.t("Подряд"), _endless_cells(false)], [I18n.t("Вызов дня"), _endless_cells(true)]]))
	box.add_child(_note(I18n.t("«Вызов дня»: рекорды текущей версии генератора (v%d).")
		% ProcGen.VERSION))
	box.add_child(_pvp_section())
	return box


## Ячейки по сложностям LegionChallenge.ORDER: «HP 180 · 3:07» или «—».
static func _run_cells(mode: String, map_id: String) -> Array[String]:
	var out: Array[String] = []
	for d: String in LegionChallenge.ORDER:
		var text := LegionRecords.short_text(LegionRecords.best(mode, map_id, d))
		out.append(text if text != "" else EMPTY)
	return out


static func _endless_cells(daily: bool) -> Array[String]:
	var rows := LegionRecords.endless_rows(daily)
	var out: Array[String] = []
	for d: String in LegionChallenge.ORDER:
		var r: Dictionary = rows.get(d, {})
		out.append(EMPTY if r.is_empty() else I18n.t("стаж %d · души %d") % [
			int(r["tenure"]), int(r["souls"])])
	return out


## «Схватка» с ботом: уровня бота нет — одна колонка счёта на поле.
static func _pvp_section() -> VBoxContainer:
	var sec := VBoxContainer.new()
	sec.name = "PvpRecords"
	sec.add_theme_constant_override("separation", 4)
	sec.add_child(UiStyle.label(I18n.t("«Схватка» с ботом"), 22, UiStyle.FONT_TITLE, UiStyle.GOLD))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	sec.add_child(grid)
	for pair: Array in [[I18n.t("Дуэль"), LegionRecords.PVP_DUEL],
			[I18n.t("Случайное поле"), LegionRecords.PVP_RANDOM]]:
		var t := LegionRecords.pvp_tally(String(pair[1]))
		grid.add_child(_cell(String(pair[0]), NAME_W, UiStyle.TEXT))
		grid.add_child(_cell(I18n.t("побед %d · поражений %d · ничьих %d") % [
			int(t["wins"]), int(t["losses"]), int(t["draws"])], CELL_W * 2.0, UiStyle.TEXT))
	return sec


## Раздел: заголовок и таблица «название | Стажёр | Штатный | Ад». rows — [[название, ячейки]].
static func _section(title: String, node_name: String, rows: Array) -> VBoxContainer:
	var sec := VBoxContainer.new()
	sec.name = node_name
	sec.add_theme_constant_override("separation", 4)
	sec.add_child(UiStyle.label(title, 22, UiStyle.FONT_TITLE, UiStyle.GOLD))
	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = 1 + LegionChallenge.ORDER.size()
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 2)
	sec.add_child(grid)
	grid.add_child(_cell("", NAME_W, UiStyle.TEXT_DIM))
	for d: String in LegionChallenge.ORDER:
		grid.add_child(_cell(LegionChallenge.title(d), CELL_W, UiStyle.TEXT_DIM))
	for row: Array in rows:
		grid.add_child(_cell(String(row[0]), NAME_W, UiStyle.TEXT))
		for text: String in row[1]:
			grid.add_child(_cell(text, CELL_W, UiStyle.GOLD if text != EMPTY else UiStyle.TEXT_DIM))
	return sec


static func _cell(text: String, width: float, color: Color) -> Label:
	var l := UiStyle.label(text, 17, UiStyle.FONT_TEXT, color)
	l.custom_minimum_size.x = width
	l.clip_text = true
	return l


static func _note(text: String) -> Label:
	var l := ProgressionUi.text(text, 16, UiStyle.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l
