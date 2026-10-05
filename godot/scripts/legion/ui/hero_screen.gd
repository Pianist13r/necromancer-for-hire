class_name HeroScreen
extends Control
## Стаж открывает варианты колоды, а не обязательную силу между забегами.

signal back
var _body: VBoxContainer


func _ready() -> void:
	var progress := Campaign.hero_xp_progress()
	var status := "Стаж %d · опыт %d. " % [Campaign.hero_level(), Campaign.hero_xp()]
	status += "Все записи досье открыты." if bool(progress["maxed"]) else \
		"До нового стажа: %d опыта." % (int(progress["need"]) - int(progress["cur"]))
	var shell := ProgressionUi.shell(self, "Досье некроманта", status)
	_body = shell["body"]
	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit())
	_body.add_child(ProgressionUi.text("Базовые девять правил доступны сразу. Стаж добавляет новые "
		+ "варианты в случайное предложение. В бою действуют только три подписанных пункта.", 20))
	for tag: String in ["hr", "law", "magic"]:
		_body.add_child(ProgressionUi.text(String(AmendmentDb.TAGS[tag]["title"]), 26,
			AmendmentDb.TAGS[tag]["color"]))
		var grid := ProgressionUi.grid()
		_body.add_child(grid)
		for id: String in AmendmentDb.ORDER:
			var data := AmendmentDb.card(StringName(id))
			if String(data["tag"]) != tag:
				continue
			var level := int(data.get("unlock_level", 1))
			var action := "В базовой колоде" if level <= 1 else "Открыто стажем"
			if level > Campaign.hero_level():
				action = "Откроется на стаже %d" % level
			var card := AmendmentCard.new().configure(StringName(id), data, action)
			card.focus_mode = Control.FOCUS_NONE
			grid.add_child(card)
	resized.connect(_resize_cards)
	_resize_cards()
	ModalFocus.contain.call_deferred(self)


func _unhandled_key_input(_event: InputEvent) -> void:
	ModalFocus.contain(self)


func _resize_cards() -> void:
	for child in _body.get_children():
		if child is GridContainer:
			ProgressionUi.resize_grid(child, size.x)
