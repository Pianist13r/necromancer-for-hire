class_name OfficeShop
extends Control
## На объект — один пакет; переброски хранятся до следующего выбора.

signal back
signal hero_pressed
signal bought
var _body: VBoxContainer
var _services: GridContainer
var _note: Label


func _ready() -> void:
	var shell := ProgressionUi.shell(self, "Контора: перед выходом",
		"Мёртвые работают. Деньги — тоже. Подготовка действует на следующий объект.")
	_body = shell["body"]
	_note = shell["note"]
	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit(),
		"Досье некроманта", func() -> void: hero_pressed.emit())
	resized.connect(_resize_cards)
	refresh()
	ModalFocus.contain.call_deferred(self)


func _unhandled_key_input(_event: InputEvent) -> void:
	ModalFocus.contain(self)


func refresh() -> void:
	_note.text = "Премия: %d. Один пакет на следующий объект; постоянных надбавок нет." \
		% Campaign.bounty()
	ProgressionUi.clear(_body)
	var refund := int(Campaign.raw_file().get_value(Campaign._meta_section(), "legacy_refund", 0))
	if refund > 0:
		_body.add_child(ProgressionUi.text("Старая Контора возвращает %d премии за покупки. "
			% refund + "Деньги уже на счёте; стаж и пройденные объекты сохранены.", 18, UiStyle.GOOD))
	_services = ProgressionUi.grid()
	_body.add_child(_services)
	for id: String in ["souls", "mana", "reroll"]:
		var data: Dictionary = AmendmentDb.PREPARATIONS.get(id, {}).duplicate()
		if id == "reroll":
			data = {"title": "Переподписать", "icon": "perk_fine_print",
				"text": "Оплатить другое случайное предложение поправок. До двух в запасе.",
				"cost": AmendmentDb.REROLL_COST}
		var cost := int(data["cost"])
		var locked := Campaign.bounty() < cost \
			or (id != "reroll" and RunProgression.preparation() != "") \
			or (id == "reroll" and RunProgression.reroll_tokens() >= 2)
		var action := "Купить · %d премии" % cost
		if id == RunProgression.preparation():
			action = "Оплачено · следующий объект"
		elif id != "reroll" and RunProgression.preparation() != "":
			action = "Пакет на объект уже выбран"
		elif Campaign.bounty() < cost:
			action = "Не хватает %d премии" % (cost - Campaign.bounty())
		elif id == "reroll" and RunProgression.reroll_tokens() >= 2:
			action = "Две переброски уже оплачены"
		var card := AmendmentCard.new().configure(StringName(id), data, action)
		card.disabled = locked
		_services.add_child(card)
		card.pressed.connect(func() -> void: _buy(id))
	_body.add_child(ProgressionUi.text("Редакция забега · %d из 3 пунктов"
		% Campaign.upgrades().size(), 24))
	if Campaign.upgrades().is_empty():
		_body.add_child(ProgressionUi.text("Первый пункт получите после победы. "
			+ "Новые забеги начинают с чистого договора."))
	else:
		var active := ProgressionUi.grid()
		_body.add_child(active)
		for id in Campaign.upgrades():
			var card := AmendmentCard.new().configure(id, AmendmentDb.card(id), "Действует до замены")
			card.focus_mode = Control.FOCUS_NONE
			active.add_child(card)
	_resize_cards()
	ModalFocus.contain.call_deferred(self)


func _buy(id: String) -> void:
	if RunProgression.buy_service(id):
		bought.emit()
		refresh()
	else:
		_note.text = "Услуга не оплачена. Премия сохранена; попробуйте снова."


func _resize_cards() -> void:
	if is_instance_valid(_body):
		for child in _body.get_children():
			if child is GridContainer:
				ProgressionUi.resize_grid(child, size.x)
