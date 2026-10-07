class_name OfficeShop
extends Control
## «Контора» — короткая подготовка боя, сметой строками (переработка 06.10.2026, Э2): цена и остаток
## премии, «на этот объект уже взято», полоса «Редакция договора». До двух пакетов на объект
## (второй слот открывает разряд 4). Переброска живёт на экране выбора поправок, не здесь.

signal back
signal hero_pressed
signal bought
var _body: VBoxContainer
var _services: VBoxContainer
var _note: Label


func _ready() -> void:
	var shell := ProgressionUi.shell(self, "Контора: перед выходом",
		"Мёртвые работают. Деньги — тоже. Подготовка действует на следующий объект.")
	_body = shell["body"]
	_note = shell["note"]
	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit(),
		"Досье некроманта", func() -> void: hero_pressed.emit())
	refresh()
	ModalFocus.contain.call_deferred(self)


func _unhandled_key_input(_event: InputEvent) -> void:
	ModalFocus.contain(self)


func refresh() -> void:
	var picked := RunProgression.preparations()
	var slots := RunProgression.preparations_max()
	_note.text = "Премия: %d. Пакетов на объект: %d из %d; постоянных надбавок нет." \
		% [Campaign.bounty(), picked.size(), slots]
	ProgressionUi.clear(_body)
	var refund := int(Campaign.raw_file().get_value(Campaign._meta_section(), "legacy_refund", 0))
	if refund > 0:
		_body.add_child(ProgressionUi.text("Старая Контора возвращает %d премии за покупки. "
			% refund + "Деньги уже на счёте; разряд и пройденные объекты сохранены.", 18, UiStyle.GOOD))
	_body.add_child(ProgressionUi.text("Редакция договора", 18, UiStyle.TEXT_DIM))
	var strip := SlotStrip.new()
	_body.add_child(strip)
	strip.configure(Campaign.upgrades())
	if not picked.is_empty():
		var names := []
		for id in picked:
			names.append(String(AmendmentDb.PREPARATIONS[id]["title"]))
		_body.add_child(ProgressionUi.text("На этот объект уже взято: %s." % ", ".join(names),
			18, UiStyle.GOOD))
	_body.add_child(ProgressionUi.text("Смета на объект", 24))
	_services = VBoxContainer.new()
	_services.add_theme_constant_override("separation", 8)
	_body.add_child(_services)
	var remaining := Campaign.bounty()
	for id: String in AmendmentDb.PREPARATIONS:
		var data: Dictionary = AmendmentDb.PREPARATIONS[id]
		var cost := int(data["cost"])
		var owned := picked.has(id)
		var blocked := owned or picked.size() >= slots or remaining < cost
		var after := remaining - cost if not blocked else remaining
		var action := "Купить — останется %d премии" % after if not blocked else \
			("Оплачено · следующий объект" if owned else
			("Слотов подготовки больше нет" if picked.size() >= slots
			else "Не хватает %d премии" % (cost - remaining)))
		var row := ProgressionRow.new()
		_services.add_child(row)
		row.configure(StringName(id), data, action,
			{"right": "%d премии" % cost, "interactive": true})
		row.button().disabled = blocked
		row.pressed.connect(func(sid: StringName) -> void: _buy(String(sid)))
		if not blocked:
			remaining = after


func _buy(id: String) -> void:
	if RunProgression.buy_service(id):
		bought.emit()
		refresh()
	else:
		_note.text = "Услуга не оплачена. Премия сохранена; попробуйте снова."
