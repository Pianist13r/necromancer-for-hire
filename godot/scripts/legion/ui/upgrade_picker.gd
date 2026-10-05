class_name UpgradePicker
extends Control
## Четвёртая поправка требует явной замены одного пункта.

signal picked(id: StringName)
signal back
var next_label := "Дальше: брифинг"
var _cards_box: GridContainer
var _replace_box: VBoxContainer
var _replace_grid: GridContainer
var _note: Label
var _reroll: Button
var _options: Array[StringName] = []
var _selected: StringName = &""
var _focused_option: StringName = &""
var _primary: Button


func _ready() -> void:
	var shell := ProgressionUi.shell(self, "Поправка к договору",
		"Выберите правило забега. Три пункта — предел; мелкий шрифт читаем до подписи.")
	_note = shell["note"]
	var body: VBoxContainer = shell["body"]
	var footer: HBoxContainer = shell["footer"]
	_cards_box = ProgressionUi.grid()
	body.add_child(_cards_box)
	_replace_box = VBoxContainer.new()
	_replace_box.add_theme_constant_override("separation", 10)
	body.add_child(_replace_box)
	_reroll = ProgressionUi.button("", _on_reroll)
	footer.add_child(_reroll)
	var nav := LegionUi.nav_bar(self, "В главное меню", func() -> void: back.emit(),
		next_label, func() -> void: choose(_focused_option))
	_primary = nav.get_node("NavPrimary") as Button
	resized.connect(_resize_cards)
	_resize_cards()
	_refresh_footer()
	ModalFocus.contain.call_deferred(self)


func _exit_tree() -> void:
	RunProgression.clear_stage()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _selected != &"":
		_cancel_replacement()
		get_viewport().set_input_as_handled()
	ModalFocus.contain(self)


func offered() -> Array[StringName]:
	return _options.duplicate()


func offer(options: Array) -> void:
	_options.clear()
	for id in options:
		_options.append(StringName(id))
	_focused_option = _options[0] if not _options.is_empty() else &""
	_cancel_replacement()
	ProgressionUi.clear(_cards_box)
	for id in _options:
		# E-1005: у предложенной карточки — строка о дележе ключа с уже действующими источниками
		# (на экране замены ниже она не нужна: там речь о вычёркивании, а не о наборе силы).
		var card := AmendmentCard.new().configure(id, AmendmentDb.card(id),
			"Подписать поправку", true)
		_cards_box.add_child(card)
		card.pressed.connect(func() -> void: choose(id))
		card.focus_entered.connect(func() -> void: _focused_option = id)
	_refresh_footer()
	_resize_cards()
	ModalFocus.contain.call_deferred(self)


func choose(id: StringName) -> void:
	if not _options.has(id):
		return
	if Campaign.upgrades().size() < AmendmentDb.MAX_ACTIVE:
		picked.emit(id)
		return
	_selected = id
	_cards_box.hide()
	ProgressionUi.clear(_replace_box)
	var active := Campaign.upgrades()
	var data := AmendmentDb.card(id)
	# В ряд: слева — что подписываем (и возврат к предложению), справа — что вычеркнуть
	# (компактные карточки). Вертикальная колонка не влезала в 720 px на 183 px (H_report).
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 18)
	split.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_replace_box.add_child(split)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	split.add_child(left)
	left.add_child(ProgressionUi.text("Новый пункт: " + String(data["title"]), 22,
		AmendmentDb.color(id)))
	left.add_child(ProgressionUi.text(String(data["text"]), 18))
	left.add_child(ProgressionUi.text("Мелкий шрифт: " + String(data["tradeoff"]), 16, UiStyle.WARN))
	left.add_child(ProgressionUi.text("Что вычеркнуть? Его правило и цена исчезнут.", 17,
		UiStyle.TEXT_DIM))
	var pad := Control.new()
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(pad)
	left.add_child(ProgressionUi.button("Вернуться к предложению", _cancel_replacement))

	_replace_grid = ProgressionUi.grid()
	_replace_grid.columns = maxi(1, active.size())
	split.add_child(_replace_grid)
	for slot in active.size():
		var old := active[slot]
		var card := AmendmentCard.new().configure(old, AmendmentDb.card(old),
			"Вычеркнуть этот пункт", false, true)
		_replace_grid.add_child(card)
		card.pressed.connect(func() -> void: replace(slot))
	_reroll.disabled = true
	_primary.disabled = true
	ModalFocus.contain.call_deferred(self)


func replace(slot: int) -> void:
	if _selected == &"" or not RunProgression.stage(slot):
		return
	picked.emit(_selected)


func _cancel_replacement() -> void:
	_selected = &""
	RunProgression.clear_stage()
	if is_instance_valid(_replace_box):
		ProgressionUi.clear(_replace_box)
	if is_instance_valid(_cards_box):
		_cards_box.show()
	_refresh_footer()
	ModalFocus.contain.call_deferred(self)


func _on_reroll() -> void:
	var next := RunProgression.reroll(Campaign.pending_reward_rng())
	if not next.is_empty():
		offer(next)
	else:
		_note.text = "Переброска не оплачена. Предложение осталось прежним."
	_refresh_footer()


func _refresh_footer() -> void:
	if not is_instance_valid(_reroll):
		return
	if is_instance_valid(_primary):
		_primary.disabled = _options.is_empty() or _selected != &""
	_reroll.text = "Другое предложение · %d премии" % AmendmentDb.REROLL_COST \
		if RunProgression.reroll_tokens() == 0 else "Другое предложение · оплачено"
	_reroll.disabled = not RunProgression.can_reroll() or _selected != &""


func _resize_cards() -> void:
	if is_instance_valid(_cards_box):
		ProgressionUi.resize_grid(_cards_box, size.x)
	# Сетку замены по ширине окна не пересобираем: карточки стоят в ряд по числу активных
	# поправок (всегда MAX_ACTIVE), и должны остаться узкими.
