class_name PvpFieldSelect
extends Control
##
## Выбор поля «Схватки» (P6, D-0927-199): «Дуэль» — готовое симметричное поле, «Случайное поле» —
## поле процгена с новым сидом на каждый вход (D-0930-30). Уровня бота нет: PvpBot и PvpRules
## уровней не знают, придумывать их ради экрана не стали. Esc и «Назад» — в главное меню.
## Экран без ссылок на LegionMain: отдаёт выбор сигналом, дальше ведёт PvpFlow.
##

signal chosen(map_id: String)
signal back
## «По сети» — общее лобби онлайн-«Схватки» (NetLobby), человек против человека.
signal net

const CARD_W := 560.0
const FIELD_W := 496.0

## Steam-сборка с клиентом Steam: «По сети» ведёт в лобби Steam (ставит PvpFlow до показа).
var via_steam := false


func _ready() -> void:
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
		"menu_pvp")
	duel.pressed.connect(func() -> void: chosen.emit(PvpMaps.DUEL))
	box.add_child(duel)
	var rnd := _field_button("PvpFieldRandom", "Случайное поле", "Новое поле при каждом входе",
		"menu_map")
	rnd.pressed.connect(func() -> void: chosen.emit(random_map_id()))
	box.add_child(rnd)
	var online := _field_button("PvpFieldNet", "По сети",
		"Против человека: через Steam" if via_steam else "Против человека: общее лобби",
		"menu_pvp")
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


## Случайное поле: сид новый при каждом нажатии («Ещё раз» его не меняет — тот же матч заново).
## Сложность процгена 3 — как у поля, на котором строилась серия «бот против бота».
static func random_map_id() -> String:
	return "%s%d:3:%s" % [ProcGen.ID_PREFIX, randi_range(1000, 999999), PgPvp.ID_SUFFIX]


## Крупная кнопка поля: иконка слева, название и пояснение в одной кнопке (наполнение мышь не
## перехватывает — кликает сама кнопка).
func _field_button(node_name: String, caption: String, tip: String, icon_name: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.custom_minimum_size = Vector2(FIELD_W, 84.0)
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
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(sub)
	return b
