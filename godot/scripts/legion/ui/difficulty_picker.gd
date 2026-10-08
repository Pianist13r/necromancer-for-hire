class_name DifficultyPicker
extends VBoxContainer
##
## Переключатель сложности «Стажёр / Штатный / Ад» (LegionChallenge) — в главном меню и в выборе
## карт. Хранит Settings.set_difficulty(); действует со следующего боя. Строка под кнопками —
## чем уровень отличается, чтобы выбор был осознанным, а не угадайкой.
##

signal changed(difficulty: String)

## Выбранная кнопка — рамка цвета уровня: Ад красный, Штатный золотой, Стажёр спокойный.
const COLORS := {
	LegionChallenge.INTERN: Color(0.545, 1.0, 0.69),
	LegionChallenge.NORMAL: Color(1.0, 0.82, 0.48),
	LegionChallenge.HELL: Color(1.0, 0.353, 0.353),
}

var buttons: Dictionary = {}   # id уровня → Button (публично для тестов и кадров)
var _desc: Label


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	row.add_child(UiStyle.label("Сложность:", 18, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM))
	var group := ButtonGroup.new()
	for id in LegionChallenge.ORDER:
		var btn := Button.new()
		btn.text = "Стажёр · новичку" if id == LegionChallenge.INTERN else LegionChallenge.title(id)
		btn.toggle_mode = true
		btn.button_group = group
		btn.focus_mode = Control.FOCUS_ALL
		btn.custom_minimum_size = Vector2(120.0, 38.0)
		btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
		btn.add_theme_font_size_override("font_size", 17)
		UiStyle.style_button(btn)
		# выбранная — рамка, модулированная цветом уровня (StyleBoxTexture: цвет — через
		# modulate_color, ширину рамки девятисрезке менять нельзя), плюс цвет текста
		var on: StyleBoxTexture = (btn.get_theme_stylebox("pressed") as StyleBoxTexture).duplicate()
		on.modulate_color = COLORS[id]
		btn.add_theme_stylebox_override("pressed", on)
		btn.add_theme_stylebox_override("hover_pressed", on)
		btn.add_theme_color_override("font_pressed_color", COLORS[id])
		btn.pressed.connect(select.bind(id))
		row.add_child(btn)
		buttons[id] = btn
	_desc = UiStyle.label("", 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD
	_desc.custom_minimum_size = Vector2(560.0, 0.0)
	add_child(_desc)
	_show(Settings.difficulty())


## Выбор игрока (клик или тест): сохранить и показать.
func select(id: String) -> void:
	var v := LegionChallenge.valid(id)
	Settings.set_difficulty(v)
	_show(v)
	changed.emit(v)


func _show(id: String) -> void:
	for k: String in buttons:
		(buttons[k] as Button).set_pressed_no_signal(k == id)
	_desc.text = String(LegionChallenge.TABLE[id]["desc"])
