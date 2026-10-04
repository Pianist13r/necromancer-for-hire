class_name PvpMenu
extends CanvasLayer
##
## Меню «Схватки» по Esc (docs/pvp/DESIGN.md §2.1, §2.7): паузы в PvP нет — мир общий, бой
## идёт под меню. «Продолжить» — закрыть; «Сдаться» → подтверждение → команда SURRENDER своей
## стороны (та же точка API, что у сети и бота). Внешний вид PvP-HUD — линия L4; здесь только
## то, без чего правило «нет паузы, есть сдача» не проверить.
##

const LAYER := 90
const CARD_W := 380.0

var world: LegionWorld = null
var _main_box: VBoxContainer = null
var _confirm_box: VBoxContainer = null


func setup(w: LegionWorld) -> void:
	world = w
	layer = LAYER
	# мир под меню не стоит — меню тоже живёт на любой паузе дерева (её в PvP нет, но пусть)
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	UiStyle.fill_rect(root)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.45)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(backdrop)
	_main_box = UiStyle.card_box(root, CARD_W, 12)
	_main_box.alignment = BoxContainer.ALIGNMENT_CENTER
	var title := UiStyle.label("Бой идёт", 34, UiStyle.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main_box.add_child(title)
	_main_box.add_child(_button("Продолжить", close))
	_main_box.add_child(_button("Сдаться", _ask))
	_confirm_box = UiStyle.card_box(root, CARD_W, 12)
	_confirm_box.alignment = BoxContainer.ALIGNMENT_CENTER
	var q := UiStyle.label("Сдаться? Победа уйдёт сопернику", 24, UiStyle.FONT_TITLE)
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_box.add_child(q)
	_confirm_box.add_child(_button("Да, сдаюсь", _surrender))
	_confirm_box.add_child(_button("Нет", _back))
	visible = false


## Esc: открыть или закрыть (подтверждение закрывается целиком).
func toggle() -> void:
	if visible:
		close()
	else:
		visible = true
		_back()
		world.cancel_human_gestures()   # B-370/B-371: начатое до меню не доживает до отпускания


func close() -> void:
	visible = false


## Карточки UiStyle.card_box — родители коробок: прячем карточку целиком, не пустую рамку.
func _ask() -> void:
	(_main_box.get_parent() as Control).visible = false
	(_confirm_box.get_parent() as Control).visible = true


func _back() -> void:
	(_main_box.get_parent() as Control).visible = true
	(_confirm_box.get_parent() as Control).visible = false


func _surrender() -> void:
	close()
	world.local_cmd(PvpCmd.surrender())   # вне сети — сразу своей стороной, в сети — командой


func _button(text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(220.0, 44.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 22)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UiStyle.style_button(btn)
	btn.pressed.connect(on_pressed)
	return btn
