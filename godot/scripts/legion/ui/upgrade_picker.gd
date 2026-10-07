class_name UpgradePicker
extends Control
## Выбор поправки — строки (не карточки). Четвёртая поправка требует явной замены: клик по слоту
## полосы «Редакция договора» вычёркивает прежний пункт.

signal picked(id: StringName)
signal back
var next_label := "Дальше: брифинг"
var _options: Array[StringName] = []
var _selected: StringName = &""
var _focused_option: StringName = &""
var _note: Label
var _strip: SlotStrip
var _replace_box: VBoxContainer
var _reroll: Button
var _primary: Button
## Тесты читают _cards_box.visible — держим этим именем контейнер предложений.
var _cards_box: VBoxContainer


func _ready() -> void:
	var shell := ProgressionUi.shell(self, "Поправка к договору",
		"Выберите правило забега. Три пункта — предел; детали раскрываются под строкой.")
	_note = shell["note"]
	var body: VBoxContainer = shell["body"]
	var footer: HBoxContainer = shell["footer"]
	body.add_child(ProgressionUi.text("Редакция договора", 18, UiStyle.TEXT_DIM))
	_strip = SlotStrip.new()
	body.add_child(_strip)
	_strip.slot_pressed.connect(func(slot: int) -> void:
		if _selected != &"":
			replace(slot))
	_cards_box = VBoxContainer.new()
	_cards_box.name = "Offers"
	_cards_box.add_theme_constant_override("separation", 8)
	body.add_child(_cards_box)
	_replace_box = VBoxContainer.new()
	_replace_box.add_theme_constant_override("separation", 10)
	body.add_child(_replace_box)
	_reroll = ProgressionUi.button("", _on_reroll)
	footer.add_child(_reroll)
	var nav := LegionUi.nav_bar(self, "В главное меню", func() -> void: back.emit(),
		next_label, func() -> void: choose(_focused_option))
	_primary = nav.get_node("NavPrimary") as Button
	_refresh_strip()
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
	var first := true
	for id in _options:
		var row := ProgressionRow.new()
		_cards_box.add_child(row)
		# Первая строка раскрыта по умолчанию: видно, что строки раскрываются (иначе игрок с мышью
		# не догадается, что под строкой есть детали). Остальные — по наведению/фокусу.
		row.configure(id, AmendmentDb.card(id), "Подписать поправку",
			{"together": true, "expanded": first})
		first = false
		row.pressed.connect(func(rid: StringName) -> void: choose(rid))
		row.button().focus_entered.connect(func() -> void: _focused_option = id)
	_refresh_strip()
	_refresh_footer()
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
	_refresh_strip(true)
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 18)
	split.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_replace_box.add_child(split)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	split.add_child(left)
	var info := ProgressionRow.new()
	left.add_child(info)
	info.configure(id, AmendmentDb.card(id), "", {"expanded": true, "interactive": false})
	left.add_child(ProgressionUi.button("Вернуться к предложению", _cancel_replacement))

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	split.add_child(right)
	right.add_child(ProgressionUi.text("Что вычеркнуть? Клик по слоту выше.", 17, UiStyle.TEXT_DIM))
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
	_refresh_strip()
	_refresh_footer()
	ModalFocus.contain.call_deferred(self)


func _on_reroll() -> void:
	var next := RunProgression.reroll(Campaign.pending_reward_rng())
	if not next.is_empty():
		offer(next)
	else:
		_note.text = "Переброска не оплачена. Предложение осталось прежним."
	_refresh_footer()


func _refresh_strip(interactive := false) -> void:
	ProgressionUi.clear(_strip)
	_strip.configure(Campaign.upgrades(), interactive)


func _refresh_footer() -> void:
	if not is_instance_valid(_reroll):
		return
	if is_instance_valid(_primary):
		_primary.disabled = _options.is_empty() or _selected != &""
	_reroll.text = "Другое предложение · %d премии" % AmendmentDb.REROLL_COST
	_reroll.disabled = not RunProgression.can_reroll() or _selected != &""
