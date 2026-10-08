class_name PrepPanel
extends VBoxContainer
##
## «Подготовка к бою» прямо на брифинге (D-1007-P1: экран «Контора» убран). Строка на пакет
## AmendmentDb.PREPARATIONS: щелчок — взять за премию (RunProgression.buy_service), щелчок по
## взятой — снять с полным возвратом (RunProgression.cancel_service). Взятая строка выделена,
## недоступная приглушена и называет причину. D-1007-P5: при сборке панель докупает то, что игрок
## брал в прошлый раз (RunProgression.auto_prepare) и говорит об этом строкой.
##

## bought — true после покупки, false после снятия (озвучка покупки — только на true).
signal changed(bought: bool)

const ROW_H := 54.0
var _auto: Array[String] = []
var _rows: Array[ProgressionRow] = []
## Второй щелчок двойного щелчка (привычный жест «подписать» с экрана поправок) не снимает только
## что взятое (verifier этапа 3): строка шлёт activated на нажатии с double_click, а pressed — на
## отпускании; помеченный так pressed проглатывается.
var _swallow := ""


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_auto = RunProgression.auto_prepare()
	refresh()


## Строки пакетов (по одной на AmendmentDb.PREPARATIONS) — наружу для тестов.
func rows() -> Array[ProgressionRow]:
	return _rows


## Что панель докупила сама при сборке (D-1007-P5) — для раннера забега и тестов.
func auto_taken() -> Array[String]:
	return _auto


func refresh() -> void:
	ProgressionUi.clear(self)
	_rows.clear()
	var picked := RunProgression.preparations()
	var slots := RunProgression.preparations_max()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	add_child(head)
	head.add_child(UiStyle.label("Подготовка к бою", 18, UiStyle.FONT_TITLE, UiStyle.GOLD))
	var status := "Премия: %d · мест: %d из %d" % [Campaign.bounty(), picked.size(), slots]
	if slots == 1:
		status += " · второе место — с разряда %d" % AmendmentDb.PREP_SLOT2_LEVEL
	var status_label := UiStyle.label(status, 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(status_label)
	# Пояснения — одной строкой: брифинг и так плотный по высоте.
	var notes: PackedStringArray = []
	var auto_kept := _auto.filter(func(id: String) -> bool: return picked.has(id))
	if not auto_kept.is_empty():
		notes.append("Взято как в прошлый раз — щелчок снимает.")
	if not notes.is_empty():
		var note := UiStyle.label(" ".join(notes), 15, UiStyle.FONT_TEXT, UiStyle.GOOD)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD
		add_child(note)
	for id: String in AmendmentDb.PREPARATIONS:
		_add_row(id, picked, slots)


func _add_row(id: String, picked: Array[String], slots: int) -> void:
	var data: Dictionary = AmendmentDb.PREPARATIONS[id].duplicate()
	var cost := int(data["cost"])
	# Короткий эффект — первая фраза полного текста («+45 душ на следующем объекте.»).
	data["short"] = String(data["text"]).get_slice(". ", 0).trim_suffix(".") + "."
	var owned := picked.has(id)
	var reason := ""
	if not owned:
		if picked.size() >= slots:
			reason = "мест больше нет"
		elif Campaign.bounty() < cost:
			reason = "не хватает %d премии" % (cost - Campaign.bounty())
	var right := "%d премии" % cost
	if owned:
		right = "взято · щелчок вернёт %d" % cost
	elif reason != "":
		right = reason
	var row := ProgressionRow.new()
	add_child(row)
	row.configure(StringName(id), data, "", {"right": right, "row_h": ROW_H, "icon": 34.0,
		"chips": false, "select_mode": true})
	# Выделение без раскрытия деталей: брифинг не должен расти от щелчка.
	row.set_selected(owned)
	row.details().visible = false
	if reason != "":
		row.button().disabled = true
		row.modulate = Color(1.0, 1.0, 1.0, 0.5)
	row.pressed.connect(func(sid: StringName) -> void: _toggle(String(sid)))
	row.activated.connect(func(sid: StringName) -> void: _swallow = String(sid))
	_rows.append(row)


func _toggle(id: String) -> void:
	if _swallow == id:
		_swallow = ""
		return
	var taking := not RunProgression.preparations().has(id)
	var ok := RunProgression.buy_service(id) if taking else RunProgression.cancel_service(id)
	if not ok:
		return
	if taking:
		LegionAudio.ui(&"ui_buy")
	refresh()
	changed.emit(taking)
