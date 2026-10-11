class_name MouseBind
extends RefCounted
##
## B-448: кнопки мыши боя — единая точка. Обработчик боя спрашивает не «какая физическая
## кнопка», а «какая это кнопка по смыслу»: LEFT — перо (штрих, щелчок по площадке, меню
## участка), RIGHT — рогатка/натиск/щелчок по участку. Режим левши меняет их местами,
## инверсия колеса — направление прокрутки (вид договора по кругу). Зажатое колесо (прицел)
## не меняется.
##
## Меняется только ВВОД боя (ContractField): команды, уходящие в мир и по сети (PvpCmd), кнопок
## мыши не содержат — симуляция и «Схватка» режима не видят. Кнопки интерфейса (Button, Касса,
## меню участка, заставка) остаются на физической ЛКМ, как в любом окне ОС: левша, которому
## нужен обмен везде, меняет кнопки в самой ОС.
##
## Хранение — Settings (раздел controls: left_handed, wheel_invert); по умолчанию всё как было.
##

## Слова прозы → действие мыши: «ЛКМ» — перо, «ПКМ» — рогатка (мост для текстов, как у клавиш).
const PROSE := {"ЛКМ": &"draw", "ПКМ": &"sling"}
## Действие → кнопка по смыслу (до обмена).
const ACTIONS := {&"draw": MOUSE_BUTTON_LEFT, &"sling": MOUSE_BUTTON_RIGHT}
const NAMES := {MOUSE_BUTTON_LEFT: "ЛКМ", MOUSE_BUTTON_RIGHT: "ПКМ"}


## Кнопка события по смыслу: физическая ПКМ у левши — LEFT (перо), и наоборот; прокрутка при
## инверсии — в обратную сторону. Прочие кнопки — как есть.
static func button(mb: InputEventMouseButton) -> MouseButton:
	return map(mb.button_index)


## То же для кнопки без события. Отображение — свою собственную обратную (обмен), поэтому им
## же переводится «смысл → физическая» (значок мыши в уроке, подписи).
static func map(b: MouseButton) -> MouseButton:
	if Settings.is_left_handed():
		if b == MOUSE_BUTTON_LEFT:
			return MOUSE_BUTTON_RIGHT
		if b == MOUSE_BUTTON_RIGHT:
			return MOUSE_BUTTON_LEFT
	if Settings.is_wheel_inverted():
		if b == MOUSE_BUTTON_WHEEL_UP:
			return MOUSE_BUTTON_WHEEL_DOWN
		if b == MOUSE_BUTTON_WHEEL_DOWN:
			return MOUSE_BUTTON_WHEEL_UP
	return b


## Физическая кнопка действия (&"draw" | &"sling").
static func physical(action: StringName) -> MouseButton:
	return map(ACTIONS.get(action, MOUSE_BUTTON_LEFT))


## Подпись физической кнопки действия: «ЛКМ» / «ПКМ» (токен {mouse:draw|sling}).
static func label(action: StringName) -> String:
	return NAMES[physical(action)]


## Слово старой прозы «ЛКМ»/«ПКМ» — подпись кнопки того действия, которое оно называло.
static func prose(word: String) -> String:
	var action: StringName = PROSE.get(word, &"")
	return word if action == &"" else label(action)
