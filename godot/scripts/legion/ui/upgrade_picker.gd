class_name UpgradePicker
extends Control
## Выбор поправки — строки (не карточки). Щелчок по строке выделяет её и раскрывает детали;
## подписывает кнопка «Подписать «…»» справа внизу или двойной щелчок (D-1007-P4, B-422) — само
## ничего не подписывается. Четвёртая поправка требует явной замены: клик по слоту полосы
## вычёркивает прежний пункт.

signal picked(id: StringName)
signal back
const STRIP_CAPTION := "Действующие поправки"
const REPLACE_CAPTION := "Все три места заняты. Щёлкните поправку, которую вычеркнуть:"
var _strip_caption: Label
var _options: Array[StringName] = []
## Поправка, ждущая выбора слота для вычёркивания (режим замены); &"" — не в режиме замены.
var _replacing: StringName = &""
## Выделенная строка предложения — её подписывает главная кнопка.
var _chosen: StringName = &""
var _note: Label
var _strip: SlotStrip
var _replace_box: VBoxContainer
var _reroll: Button
var _primary: Button
var _back: Button
var _back_shortcut: Shortcut
## Тесты читают _cards_box.visible — держим этим именем контейнер предложений.
var _cards_box: VBoxContainer


func _ready() -> void:
	var scope_name := "забега" if Campaign.is_endless_scope() else "кампании"
	var shell := ProgressionUi.shell(self, "Поправка к договору",
		"Одна поправка — правило до конца %s; действуют сразу три. " % scope_name
		+ "Щелчок по строке — детали, подпись — кнопкой справа внизу.")
	_note = shell["note"]
	var body: VBoxContainer = shell["body"]
	var footer: HBoxContainer = shell["footer"]
	_strip_caption = ProgressionUi.text(STRIP_CAPTION, 18, UiStyle.TEXT_DIM)
	body.add_child(_strip_caption)
	_strip = SlotStrip.new()
	body.add_child(_strip)
	_strip.slot_pressed.connect(func(slot: int) -> void:
		if _replacing != &"":
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
		"Выберите поправку", func() -> void: choose(_chosen))
	_primary = nav.get_node("NavPrimary") as Button
	_back = nav.get_node("NavBack") as Button
	_back_shortcut = _back.shortcut
	_refresh_strip()
	_refresh_footer()
	ModalFocus.contain.call_deferred(self)


func _exit_tree() -> void:
	RunProgression.clear_stage()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _replacing != &"":
		_cancel_replacement()
		get_viewport().set_input_as_handled()
	ModalFocus.contain(self)


func offered() -> Array[StringName]:
	return _options.duplicate()


func offer(options: Array) -> void:
	_options.clear()
	for id in options:
		_options.append(StringName(id))
	_chosen = &""
	_cancel_replacement()
	ProgressionUi.clear(_cards_box)
	for id in _options:
		var row := ProgressionRow.new()
		_cards_box.add_child(row)
		row.configure(id, AmendmentDb.card(id), "",
			{"together": true, "select_mode": true, "note": RunProgression.unseen_note(id)})
		row.pressed.connect(func(rid: StringName) -> void: select(rid))
		row.activated.connect(func(rid: StringName) -> void: choose(rid))
		# Клавиатура: выделение идёт за фокусом, Enter — главная кнопка.
		row.button().focus_entered.connect(func() -> void: select(id))
	# Первая строка выделена сразу: видно, что строки раскрываются, а кнопка называет, ЧТО
	# подпишет, — молча ничего не подписывается.
	if not _options.is_empty():
		select(_options[0])
	_refresh_strip()
	_refresh_footer()
	ModalFocus.contain.call_deferred(self)


## Выделить строку предложения: детали раскрыты только у неё, главная кнопка называет её.
func select(id: StringName) -> void:
	if not _options.has(id) or _replacing != &"":
		return
	_chosen = id
	for row in _cards_box.get_children():
		if row is ProgressionRow:
			(row as ProgressionRow).set_selected((row as ProgressionRow).amendment_id == id)
	_refresh_footer()


func chosen() -> StringName:
	return _chosen


## Подписать поправку id (главная кнопка, двойной щелчок). При полной сборке — режим замены.
func choose(id: StringName) -> void:
	if not _options.has(id):
		return
	if Campaign.upgrades().size() < AmendmentDb.MAX_ACTIVE:
		picked.emit(id)
		return
	_replacing = id
	# Esc в режиме замены — «вернуться к предложению», а не горячая клавиша «В главное меню»
	# (она срабатывала раньше _unhandled_key_input, verifier этапа 2).
	_back.shortcut = null
	_cards_box.hide()
	ProgressionUi.clear(_replace_box)
	_refresh_strip(true)
	# Подсказка — на месте подписи полосы, во всю ширину: узкая колонка справа раскладывала её
	# столбиком по букве (кадр 38_E4, 07.10.2026).
	_strip_caption.text = REPLACE_CAPTION
	_strip_caption.add_theme_color_override("font_color", UiStyle.WARN)
	_replace_box.add_child(ProgressionUi.text("Новая поправка:", 17, UiStyle.TEXT_DIM))
	var info := ProgressionRow.new()
	_replace_box.add_child(info)
	info.configure(id, AmendmentDb.card(id), "", {"expanded": true, "interactive": false})
	var back_row := HBoxContainer.new()
	_replace_box.add_child(back_row)
	back_row.add_child(ProgressionUi.button("Вернуться к предложению", _cancel_replacement))
	_refresh_footer()
	ModalFocus.contain.call_deferred(self)


func replace(slot: int) -> void:
	if _replacing == &"" or not RunProgression.stage(slot):
		return
	picked.emit(_replacing)


func _cancel_replacement() -> void:
	var was := _replacing
	_replacing = &""
	if is_instance_valid(_back):
		_back.shortcut = _back_shortcut
	RunProgression.clear_stage()
	if is_instance_valid(_replace_box):
		ProgressionUi.clear(_replace_box)
	if is_instance_valid(_cards_box):
		_cards_box.show()
	if is_instance_valid(_strip_caption):
		_strip_caption.text = STRIP_CAPTION
		_strip_caption.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	_refresh_strip()
	_refresh_footer()
	ModalFocus.contain.call_deferred(self)
	# Возврат из замены — выделение остаётся на той строке, что выбирали (фокус ModalFocus иначе
	# перескакивал на первую и молча меняет выделение).
	if was != &"":
		_refocus.call_deferred(was)


func _refocus(id: StringName) -> void:
	for row in _cards_box.get_children():
		if row is ProgressionRow and (row as ProgressionRow).amendment_id == id:
			(row as ProgressionRow).button().grab_focus()
	select(id)


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
		_primary.disabled = _chosen == &"" or _replacing != &""
		var title := String(AmendmentDb.card(_chosen).get("title", ""))
		_primary.text = "Подписать «%s»" % title if _chosen != &"" else "Выберите поправку"
	_reroll.text = "Другое предложение · %d премии" % AmendmentDb.REROLL_COST
	_reroll.disabled = not RunProgression.can_reroll() or _replacing != &""
