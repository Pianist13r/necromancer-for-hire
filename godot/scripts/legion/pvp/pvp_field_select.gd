class_name PvpFieldSelect
extends Control
##
## Выбор поля «Схватки» (P6, D-0927-199): «Дуэль» — готовое симметричное поле, «Случайное поле» —
## поле процгена (D-0930-30). Сид случайного поля выбирается при входе и виден на кнопке;
## «Другое поле» перебрасывает его, не выходя в меню (B-332). Под полями — уровень бота и сторона
## человека (B-331): выбор сразу пишется в Settings (user://settings.cfg) и действует на матч,
## который начинает PvpFlow. Esc и «Назад» — в главное меню. Экран без ссылок на LegionMain:
## отдаёт выбор поля сигналом, дальше ведёт PvpFlow.
##

signal chosen(map_id: String)
signal back
## «По сети» — общее лобби онлайн-«Схватки» (NetLobby), человек против человека.
signal net

const CARD_W := 560.0
const FIELD_W := 496.0
const REROLL_W := 150.0
const OPTION_W := 112.0
const SIDE_TITLES: Array[String] = ["Левая", "Правая"]
const SIDE_NODES: Array[String] = ["PvpSideLeft", "PvpSideRight"]

## Steam-сборка с клиентом Steam: «По сети» ведёт в лобби Steam (ставит PvpFlow до показа).
var via_steam := false
## Случайное поле, которое начнёт кнопка «Случайное поле» (gen:<сид>:3:pvp).
var random_id := ""

var _random_tip: Label = null


func _ready() -> void:
	random_id = random_map_id()
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.9)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	var box := UiStyle.card_box(self, CARD_W, 12)
	var title := UiStyle.label("Схватка", 44, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var hint := UiStyle.label("Против бота: разрушьте Котёл соперника", 18, UiStyle.FONT_TEXT,
		UiStyle.TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	var duel := _field_button("PvpFieldDuel", "Дуэль", "Готовое поле: два прохода в стыке",
		"menu_pvp", FIELD_W)
	duel.pressed.connect(func() -> void: chosen.emit(PvpMaps.DUEL))
	box.add_child(duel)
	var rnd_row := _row(box)
	var rnd := _field_button("PvpFieldRandom", "Случайное поле", _seed_text(), "menu_map",
		FIELD_W - REROLL_W - 10.0)
	_random_tip = rnd.find_child("Tip", true, false) as Label
	rnd.tooltip_text = "Поле процгена; «Другое поле» — новый сид"
	rnd.pressed.connect(func() -> void: chosen.emit(random_id))
	rnd_row.add_child(rnd)
	var reroll := _option_button("PvpFieldReroll", "Другое поле", REROLL_W, 84.0)
	reroll.toggle_mode = false
	reroll.tooltip_text = "Новый сид случайного поля"
	reroll.pressed.connect(reroll_field)
	rnd_row.add_child(reroll)
	_bot_row(box)
	_side_row(box)
	var online := _field_button("PvpFieldNet", "По сети",
		"Против человека: через Steam" if via_steam else "Против человека: общее лобби",
		"menu_pvp", FIELD_W)
	online.pressed.connect(func() -> void: net.emit())
	box.add_child(online)
	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit())
	duel.grab_focus.call_deferred()


## Esc — «Назад». ui_cancel, а не «pause»: в «pause» замаплена и латинская P, а _input идёт
## РАНЬШЕ GUI — P закрывала бы экран при любом текстовом вводе (как закрывала лобби до фикса).
## echo гасим — автоповтор Esc не дублирует «Назад». Потребляем: мир под экраном тоже слушает
## «pause». _input, а не _unhandled_input — по той же причине.
func _input(event: InputEvent) -> void:
	if visible and not event.is_echo() and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		back.emit()


## Случайное поле: новый сид на каждый вход на экран и на каждое «Другое поле» («Ещё раз» его не
## меняет — тот же матч заново). Сложность процгена 3 — как у поля серий «бот против бота».
static func random_map_id() -> String:
	return "%s%d:3:%s" % [ProcGen.ID_PREFIX, randi_range(1000, 999999), PgPvp.ID_SUFFIX]


## «Другое поле» (B-332): новый сид без выхода в меню; превью полей процгена нет — виден номер.
func reroll_field() -> void:
	var was := random_id
	while random_id == was:
		random_id = random_map_id()
	if _random_tip != null:
		_random_tip.text = _seed_text()


func _seed_text() -> String:
	return "Поле №%s" % random_id.trim_prefix(ProcGen.ID_PREFIX).get_slice(":", 0)


func _bot_row(box: VBoxContainer) -> void:
	var row := _row(box, "Бот:")
	var group := ButtonGroup.new()
	var current := Settings.pvp_bot_level()
	for id: String in LegionCfg.PVP_BOT_LEVEL_ORDER:
		var b := _option_button("PvpBotLevel_" + id,
			String(LegionCfg.PVP_BOT_LEVELS[id]["title"]), OPTION_W, 40.0)
		b.button_group = group
		b.button_pressed = id == current
		b.pressed.connect(func() -> void: Settings.set_pvp_bot_level(id))
		row.add_child(b)


func _side_row(box: VBoxContainer) -> void:
	var row := _row(box, "Ваша сторона:")
	var group := ButtonGroup.new()
	var current := Settings.pvp_side()
	for side in SIDE_TITLES.size():
		var b := _option_button(SIDE_NODES[side], SIDE_TITLES[side], OPTION_W, 40.0)
		b.button_group = group
		b.button_pressed = side == current
		b.pressed.connect(func() -> void: Settings.set_pvp_side(side))
		row.add_child(b)


func _row(box: VBoxContainer, caption := "") -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	if caption != "":
		var l := UiStyle.label(caption, 18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		l.custom_minimum_size = Vector2(110.0, 0.0)
		row.add_child(l)
	return row


## Переключатель выбора: выбранный — утоплен и с золотой надписью.
func _option_button(node_name: String, text: String, w: float, h: float) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(w, h)
	b.add_theme_font_override("font", UiStyle.FONT_TITLE)
	b.add_theme_font_size_override("font_size", 18)
	UiStyle.style_button(b)
	b.add_theme_color_override("font_pressed_color", UiStyle.GOLD)
	b.add_theme_color_override("font_hover_pressed_color", UiStyle.GOLD)
	return b


## Крупная кнопка поля: иконка слева, название и пояснение в одной кнопке (наполнение мышь не
## перехватывает — кликает сама кнопка).
func _field_button(node_name: String, caption: String, tip: String, icon_name: String,
		w: float) -> Button:
	var b := Button.new()
	b.name = node_name
	b.custom_minimum_size = Vector2(w, 84.0)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.tooltip_text = tip
	UiStyle.style_button(b)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	row.add_child(LegionIcons.rect(icon_name, 52.0))
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	var cap := UiStyle.label(caption, 26, UiStyle.FONT_TITLE, UiStyle.TEXT)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(cap)
	var sub := UiStyle.label(tip, 16, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	sub.name = "Tip"
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(sub)
	return b
