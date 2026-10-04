class_name LegionLessonBanner
extends CanvasLayer
##
## Плашка урока: одна короткая строка задания и приглушённый счётчик «1/5» сверху по центру,
## под строкой статов HUD. Мышь не ловит, кнопок нет. Пока видна, двигает тосты HUD ниже себя
## (LegionHud.set_toast_floor). Отдельный CanvasLayer: уроки временные и снимаются по finished.
## Отдельный файл: движок уроков (legion_tutorial.gd) у потолка gdlint.
##

## 46: строка статов HUD (legion_hud.gd, y=8, шрифт 17 с обводкой) кончается около y=38.
const TOP := 50.0
const FONT := 22
const COUNT_FONT := 16
const POP_TIME := 0.25
## Ширина строки задания, дальше — перенос на вторую строку. Плашка по центру не должна залезать
## под раскрытую панель волны справа сверху (x от ~965 при 1280): кадры уроков v20, 26.09.
const MAX_TEXT_W := 540.0

var world: LegionWorld = null
var _panel: PanelContainer
var _count: Label
var _label: Label
var _floor := -1.0
var _outro := false
var _outro_t := 0.0

func _init(w: LegionWorld) -> void:
	world = w
	layer = 6

func _ready() -> void:
	# CenterContainer во всю ширину держит плашку по центру при любой длине строки
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_TOP_WIDE)
	center.offset_top = TOP
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := UiStyle.panel_style(Color(0.05, 0.04, 0.08, 0.9), 10)
	st.border_color = Color(UiStyle.GOLD, 0.75)
	st.set_border_width_all(2)
	st.content_margin_left = 20.0
	st.content_margin_right = 22.0
	st.content_margin_top = 8.0
	st.content_margin_bottom = 9.0
	_panel.add_theme_stylebox_override("panel", st)
	_panel.visible = false
	center.add_child(_panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(row)
	_count = UiStyle.label("", COUNT_FONT, UiStyle.FONT_TITLE, Color(UiStyle.TEXT_DIM, 0.6))
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_count)
	_label = UiStyle.label("", FONT, UiStyle.FONT_TEXT, UiStyle.TEXT)
	row.add_child(_label)
	world.match_started.connect(_on_world_reset)
	world.menu_entered.connect(_on_world_reset)

func set_task(text: String, counter: String) -> void:
	_count.text = counter
	_count.visible = counter != ""
	_label.text = text
	var w := _label.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		_label.get_theme_font_size("font_size")).x
	var wrap := w > MAX_TEXT_W
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size.x = MAX_TEXT_W if wrap else 0.0
	_panel.visible = true
	# короткое проявление вместо резкой подмены строки: глаз замечает, что задание сменилось
	_panel.modulate.a = 0.25
	create_tween().tween_property(_panel, "modulate:a", 1.0, POP_TIME)

func hide_task() -> void:
	if _panel != null:
		_panel.visible = false

func rect() -> Rect2:
	return _panel.get_global_rect() if _panel != null and _panel.visible else Rect2()

## После последнего урока начала боя: «пройдено» на TUTORIAL_DONE_TIME, потом плашка
## убирает себя.
func play_outro(done_text: String) -> void:
	set_task(done_text, "")
	_outro = true
	_outro_t = LegionCfg.TUTORIAL_DONE_TIME

func _process(dt: float) -> void:
	# экраны паузы и «Как играть» (LegionMain) — Control на нижнем слое холста: плашка
	# слоя 6 рисовалась бы поверх их текста. На паузе задание всё равно не выполнить.
	# вне боя (итог и экраны после него, B-093) — тоже прячем
	visible = not world.paused and world.phase == LegionWorld.Phase.BATTLE
	var bottom := rect().end.y
	if bottom != _floor:
		_floor = bottom
		if world.hud != null:
			world.hud.set_toast_floor(
				bottom + LegionCfg.TUTORIAL_TOAST_GAP if bottom > 0.0 else 0.0)
	if not _outro or world.paused:
		return
	_outro_t -= dt
	if _outro_t <= 0.0:
		queue_free()

func _exit_tree() -> void:
	if world != null and is_instance_valid(world) and world.hud != null:
		world.hud.set_toast_floor(0.0)

## Новый матч или выход в меню, пока плашка ещё доживает после уроков, — убрать её.
func _on_world_reset(_a: Variant = null) -> void:
	if _outro:
		queue_free()
