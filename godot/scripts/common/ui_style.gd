class_name UiStyle
extends RefCounted
##
## Общий стиль интерфейса: шрифты, палитра, кнопки. Виджеты пакетов (scripts/ui/*) берут
## оформление отсюда, чтобы HUD читался одной рукой, а не десятью (docs/PROTOTYPE_PLAN.md §2.6).
##
## Шрифты: Underdog — заголовки и крупные числа слотов, Neucha — текст. Числа-счётчики HUD
## (EM §15) лучше читаются системным шрифтом — для них FONT_NUMBERS = null (тема по умолчанию).
##

const FONT_TITLE := preload("res://assets/fonts/Underdog-Regular.ttf")
const FONT_TEXT := preload("res://assets/fonts/Neucha-Regular.ttf")

const PANEL_BG := Color(0.05, 0.04, 0.08, 0.88)
const TEXT := Color(0.94, 0.91, 1.0)
const TEXT_DIM := Color(0.82, 0.78, 0.9)
const GOLD := Color(1.0, 0.82, 0.48)            # #ffd27a — счёт, новые типы врагов
const GOOD := Color(0.545, 1.0, 0.69)           # #8bffb0
const WARN := Color(1.0, 0.81, 0.42)            # #ffcf6b
const BAD := Color(1.0, 0.353, 0.353)           # #ff5a5a
const SOUL := Color(0.541, 0.361, 0.965)        # #8a5cf6 — души, порталы

## Художественная рамка кнопки «мрачная канцелярия» (assets/legion/ui/, docs/dev/UI_ART.md):
## латунный фасеточный ободок, заклёпки и филигрань в углах, чистая эмаль в центре под текст.
const BTN_FRAME := "res://assets/legion/ui/button_frame.svg"
const BTN_FRAME_GOLD := "res://assets/legion/ui/button_frame_gold.svg"
## Поля девятисрезки в самой картинке (угловые квадраты с заклёпками не тянутся).
const BTN_FRAME_MARGIN := 16.0

## Кэш текстур рамок: SVG тяжело парсить на каждый стиль, грузим по одному разу.
static var _frame_cache: Dictionary = {}


static func _frame_texture(primary: bool) -> Texture2D:
	var path := BTN_FRAME_GOLD if primary else BTN_FRAME
	if not _frame_cache.has(path):
		_frame_cache[path] = load(path) as Texture2D
	return _frame_cache[path]


## Художественная кнопка: nine-patch рамка с латунным ободком. primary — золотая версия
## для главных действий. Поля content — место под текст между внутренними кромками рамки.
## При нажатии рамка чуть утапливается без изменения области клика; закрытая — тусклая.
static func button_style(primary: bool = false, margin_h: float = 18.0,
		margin_v: float = 8.0) -> StyleBoxTexture:
	var st := StyleBoxTexture.new()
	st.texture = _frame_texture(primary)
	st.texture_margin_left = BTN_FRAME_MARGIN
	st.texture_margin_top = BTN_FRAME_MARGIN
	st.texture_margin_right = BTN_FRAME_MARGIN
	st.texture_margin_bottom = BTN_FRAME_MARGIN
	# центр nine-patch тянется, углы — нет; модуляция оставлена состояниям/цветам вида
	st.modulate_color = Color.WHITE
	st.content_margin_left = margin_h
	st.content_margin_right = margin_h
	st.content_margin_top = margin_v
	st.content_margin_bottom = margin_v
	return st


## Кнопка должна ВЫГЛЯДЕТЬ кнопкой. Тема Godot по умолчанию даёт почти прозрачный фон,
## и на тёмном кладбище «Играть» читалось как обычная строчка текста (поймано на кадре).
static func style_button(btn: Button) -> void:
	var normal := button_style(false, 26.0, 10.0)
	var hover := button_style(false, 26.0, 10.0)
	hover.modulate_color = Color(1.14, 1.12, 1.08)   # латунь теплеет и светлеет под курсором
	var pressed := button_style(false, 26.0, 10.0)
	pressed.modulate_color = Color(0.78, 0.72, 0.68) # утоплена и темнее
	pressed.expand_margin_left = -1.0
	pressed.expand_margin_top = -1.0
	pressed.expand_margin_right = -1.0
	pressed.expand_margin_bottom = -1.0
	var disabled := button_style(false, 26.0, 10.0)
	disabled.modulate_color = Color(0.62, 0.58, 0.62, 0.55)

	# фокус — отдельная чистая рамка по контуру, не заливка: видно клавиатурный выбор
	var focus := StyleBoxFlat.new()
	focus.draw_center = false
	focus.border_color = Color(Cfg.RUNE_CORE, 0.9)
	focus.set_border_width_all(2)
	focus.set_corner_radius_all(9)
	focus.expand_margin_left = 2.0
	focus.expand_margin_top = 2.0
	focus.expand_margin_right = 2.0
	focus.expand_margin_bottom = 2.0

	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("hover_pressed", pressed)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_stylebox_override("focus", focus)
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	animate_button(btn)


## Повторный style_button безопасен: одно соединение, один прерываемый tween.
## Меняется только цвет рисунка, поэтому область клика и раскладка неподвижны.
static func animate_button(btn: Button) -> void:
	if btn.has_meta(&"visual_button"):
		return
	btn.set_meta(&"visual_button", true)
	btn.mouse_entered.connect(_button_tone.bind(btn, Color(1.08, 1.045, 1.0)))
	btn.mouse_exited.connect(_button_tone.bind(btn, Color.WHITE))
	btn.focus_entered.connect(_button_tone.bind(btn, Color(1.08, 1.045, 1.0)))
	btn.focus_exited.connect(_button_tone.bind(btn, Color.WHITE))
	btn.button_down.connect(_button_tone.bind(btn, Color(0.85, 0.80, 0.76)))
	btn.button_up.connect(_button_tone.bind(btn, Color.WHITE))


static func _button_tone(btn: Button, tone: Color) -> void:
	if not btn.is_inside_tree():
		return
	var previous: Tween
	if btn.has_meta(&"visual_tween"):
		previous = btn.get_meta(&"visual_tween")
	if previous != null and previous.is_valid():
		previous.kill()
	var tw := btn.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(btn, "self_modulate", tone, 0.12)
	btn.set_meta(&"visual_tween", tw)


## Общая точка входа для экранов: мягкое проявление не меняет фокус или ввод.
static func reveal(control: Control) -> void:
	if not control.is_inside_tree():
		return
	control.modulate.a = 0.0
	var tw := control.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(control, "modulate:a", 1.0, 0.22)


static func _reveal_id(instance: int) -> void:
	var control := instance_from_id(instance) as Control
	if is_instance_valid(control):
		reveal(control)


## Подпись: шрифт, размер, цвет. Корень виджета поверх арены — MOUSE_FILTER_IGNORE (грабля
## hud.gd: STOP на боевом слое съедает клики по арене и руна не чертится).
static func label(text: String, size: int = 18, font: Font = FONT_TEXT,
		color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Растянуть control на весь родительский прямоугольник. НЕ `set_anchors_preset(FULL_RECT)`:
## на свежесозданном Control (ещё вне дерева, rect 0×0) тот метод пересчитывает offset'ы так,
## чтобы сохранить ТЕКУЩИЙ (нулевой) размер — на экране получается 0×0 (поймано кадром P6,
## меню оказалось невидимым). Прямая установка anchor+offset такого не делает.
static func fill_rect(c: Control) -> void:
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0


## Карточка модального экрана по центру (пауза, настройки, «Как играть», рекорды): растёт
## от центра под содержимое, возвращает колонку для наполнения. Без карточки экраны были
## голым текстом поверх затемнения, и настройки, открытые из паузы, читались сквозь её
## кнопки (кадр приёмки 2026-09-23).
static func card_box(parent: Control, min_w: float, separation: int = 12) -> VBoxContainer:
	var card := PanelContainer.new()
	card.name = "Card"
	card.anchor_left = 0.5
	card.anchor_right = 0.5
	card.anchor_top = 0.5
	card.anchor_bottom = 0.5
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(min_w, 0.0)
	var st := StyleBoxTexture.new()
	st.texture = load("res://assets/legion/ui/panel_frame.svg") as Texture2D
	st.texture_margin_left = 24.0
	st.texture_margin_top = 24.0
	st.texture_margin_right = 24.0
	st.texture_margin_bottom = 24.0
	st.content_margin_left = 32.0
	st.content_margin_right = 32.0
	st.content_margin_top = 20.0
	st.content_margin_bottom = 24.0
	card.add_theme_stylebox_override("panel", st)
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	card.add_child(box)
	_reveal_id.call_deferred(card.get_instance_id())
	return box


## Окно-диалог (подтверждение, согласие) в стиле игры. Без этого Godot рисует встроенное окно
## серой системной рамкой с английским «Please Confirm…» — так оно и попало в запись для рекламы
## (B-435). Рамка окна (embedded_border) рисуется вокруг панели и заодно служит полосой
## заголовка: её верхний край расширен на высоту заголовка.
static func style_dialog(dialog: AcceptDialog, title: String) -> void:
	dialog.title = title
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color(0.09, 0.07, 0.12, 0.98)
	frame.border_color = Color(GOLD, 0.75)
	frame.set_border_width_all(2)
	frame.set_corner_radius_all(8)
	frame.expand_margin_left = 10.0
	frame.expand_margin_right = 10.0
	frame.expand_margin_bottom = 10.0
	frame.expand_margin_top = 40.0
	frame.shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	frame.shadow_size = 12
	var unfocused := frame.duplicate() as StyleBoxFlat
	unfocused.border_color = Color(GOLD, 0.45)
	dialog.add_theme_stylebox_override("embedded_border", frame)
	dialog.add_theme_stylebox_override("embedded_unfocused_border", unfocused)
	dialog.add_theme_constant_override("title_height", 38)
	dialog.add_theme_font_override("title_font", FONT_TITLE)
	dialog.add_theme_font_size_override("title_font_size", 22)
	dialog.add_theme_color_override("title_color", GOLD)
	# фон панели непрозрачный: под прозрачной панелью видна серая заливка самого окна
	var panel := panel_style(Color(frame.bg_color, 1.0), 0)
	panel.content_margin_left = 18.0
	panel.content_margin_right = 18.0
	panel.content_margin_top = 16.0
	panel.content_margin_bottom = 16.0
	dialog.add_theme_stylebox_override("panel", panel)
	var text := dialog.get_label()
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_theme_font_override("font", FONT_TEXT)
	text.add_theme_font_size_override("font_size", 20)
	text.add_theme_color_override("font_color", TEXT)
	style_button(dialog.get_ok_button())
	if dialog is ConfirmationDialog:
		style_button((dialog as ConfirmationDialog).get_cancel_button())


## Тёмная панель со скруглением — фон виджетов HUD.
static func panel_style(bg: Color = PANEL_BG, radius: int = 6) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	st.set_corner_radius_all(radius)
	st.border_color = Color(0.48, 0.36, 0.24, 0.8)
	st.set_border_width_all(1)
	st.shadow_color = Color(0.025, 0.015, 0.035, 0.40)
	st.shadow_size = 5
	st.shadow_offset = Vector2(0, 3)
	return st
