class_name HeroScreen
extends Control
## Досье: полоса «Редакция договора», следующее открытие разряда и таблица колоды по трём ветвям
## (переработка 06.10.2026, Э2). Каждая карта — строка ~52 px: иконка, название, эффект одной
## строкой, справа статус «в базе / открыто / разряд N». Разряд открывает варианты, не покупает
## проценты.

signal back
var _body: VBoxContainer


func _ready() -> void:
	var progress := Campaign.hero_xp_progress()
	var status := "Разряд %d · опыт %d. " % [Campaign.hero_level(), Campaign.hero_xp()]
	status += "Все записи досье открыты." if bool(progress["maxed"]) else \
		"До нового разряда: %d опыта." % (int(progress["need"]) - int(progress["cur"]))
	var shell := ProgressionUi.shell(self, "Досье некроманта", status)
	_body = shell["body"]
	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit())
	var strip := SlotStrip.new()
	_body.add_child(strip)
	strip.configure(Campaign.upgrades(), false, true)
	_body.add_child(ProgressionUi.text(_next_unlock_text(), 19, UiStyle.GOLD))

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(columns)
	for tag: String in ["hr", "law", "magic"]:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 4)
		columns.add_child(col)
		col.add_child(ProgressionUi.text(String(AmendmentDb.TAGS[tag]["title"]), 22,
			AmendmentDb.TAGS[tag]["color"]))
		for id: String in AmendmentDb.ORDER:
			var data := AmendmentDb.card(StringName(id))
			if String(data["tag"]) != tag:
				continue
			var level := int(data.get("unlock_level", 1))
			var state := "в базе" if level <= 1 else \
				("открыто" if level <= Campaign.hero_level() else "разряд %d" % level)
			var row := ProgressionRow.new()
			col.add_child(row)
			row.configure(StringName(id), data, "", {"right": state, "row_h": 50.0,
				"icon": 38.0, "chips": false, "interactive": false})
	ModalFocus.contain.call_deferred(self)


func _unhandled_key_input(_event: InputEvent) -> void:
	ModalFocus.contain(self)


## Первая по колоде карта, которую откроет следующий разряд (ближайший unlock_level выше текущего).
func _next_unlock_text() -> String:
	var level := Campaign.hero_level()
	var best := ""
	var best_level := 99
	for id: String in AmendmentDb.ORDER:
		var ul := int(AmendmentDb.card(StringName(id)).get("unlock_level", 1))
		if ul > level and ul < best_level:
			best_level = ul
			best = String(AmendmentDb.card(StringName(id)).get("title", id))
	if best == "":
		return "Следующий разряд не откроет новых записей — колода открыта целиком."
	return "Следующий разряд откроет: «%s»." % best
