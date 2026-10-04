class_name PvpResult
extends CanvasLayer
##
## Экран итога «Схватки» (P5c): «Победа / Поражение / Ничья», причина, HP обоих Котлов, армии,
## время; кнопки «Ещё раз» и «В меню». Своя карточка, а не LegionResult: там договор, звёзды,
## премия и «Дальше» — в матче двух людей всего этого нет. Живёт в HUD (LegionHud.pvp_result) и
## работает при запуске мира без LegionMain (`legion_world.tscn -- --map pvp:duel`); меню входа
## «Схватка» (P6) подключается к сигналам again / menu.
##
## Текст собирает describe() по итогу мира (LegionWorld.pvp_stats): без узлов, его читает тест.
## Человек — сторона 0 (DESIGN §4): «Победа» — победила она.
##

signal again
signal menu

## Над PvpMenu (90) и HUD (5): итог закрывает всё, кроме самого себя.
const LAYER := 95
const CARD_W := 520.0

var _root: Control = null


## Слова итога по pvp_stats() мира: {title, reason, verdict (win|lose|draw), lines: [строки]}.
## me — сторона человека за этим экраном (сеть: local_side; вне сети 0).
static func describe(stats: Dictionary, me := 0) -> Dictionary:
	var winner := int(stats.get("winner", -2))
	var reason := String(stats.get("reason", ""))
	var verdict := "draw" if winner == -1 else ("win" if winner == me else "lose")
	var title := {"win": "Победа", "lose": "Поражение", "draw": "Ничья"}[verdict] as String
	var sides: Array = stats.get("sides", [])
	var mine: Dictionary = sides[me] if sides.size() > me else {}
	var rival: Dictionary = sides[1 - me] if sides.size() > 1 and me <= 1 else {}
	var why := ""
	match reason:
		PvpMatch.REASON_CAULDRON:
			why = "Котёл соперника разрушен" if verdict == "win" else "Ваш Котёл разрушен"
		PvpMatch.REASON_SURRENDER:
			why = "Соперник сдался" if verdict == "win" else "Вы сдались"
		PvpMatch.REASON_LIMIT:
			why = "Время вышло: " + ("Котлы почти равны" if verdict == "draw"
				else "у вас больше HP Котла" if verdict == "win" else "у соперника больше HP Котла")
		PvpMatch.REASON_DRAW:
			why = "Оба Котла разрушены одновременно"
	var lines: Array[String] = [
		"Ваш Котёл: %d    Котёл соперника: %d" % [ceili(float(mine.get("hp", 0.0))),
			ceili(float(rival.get("hp", 0.0)))],
		"Ваша армия: %d    армия соперника: %d" % [int(mine.get("army", 0)),
			int(rival.get("army", 0))],
		"Длина матча: %s" % PvpView.clock(float(stats.get("t", 0.0))),
	]
	return {"title": title, "reason": why, "verdict": verdict, "lines": lines}


## Показать итог мира w (pvp_stats уже посчитан: матч решён).
func show_for(w: LegionWorld) -> void:
	hide_result()
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	var d := describe(w.pvp_stats(), w.local_side)
	_root = Control.new()
	_root.name = "PvpResultRoot"
	UiStyle.fill_rect(_root)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.78)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP   # бой кончен: клики за карточкой не нужны
	_root.add_child(backdrop)
	var box := UiStyle.card_box(_root, CARD_W, 12)
	var col := {"win": UiStyle.GOOD, "lose": UiStyle.BAD, "draw": UiStyle.GOLD}[d["verdict"]] as Color
	var title := UiStyle.label(String(d["title"]), 44, UiStyle.FONT_TITLE, col)
	title.name = "Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var why := UiStyle.label(String(d["reason"]), 22, UiStyle.FONT_TEXT, UiStyle.TEXT)
	why.name = "Reason"
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(why)
	for line: String in d["lines"]:
		var l := UiStyle.label(line, 18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(l)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	if not w.net_mode:   # сеть: переиграть можно только вдвоём (лобби), не кнопкой одного
		row.add_child(_button("Ещё раз", func() -> void: again.emit()))
	row.add_child(_button("В меню", func() -> void: menu.emit()))
	visible = true


func hide_result() -> void:
	if _root != null:
		_root.queue_free()
		_root = null
	visible = false


func is_open() -> bool:
	return visible and _root != null


## Кнопки итога по имени (тест нажимает их настоящим сигналом pressed).
func button(text: String) -> Button:
	if _root == null:
		return null
	for b in _root.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			return b as Button
	return null


func _button(text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(190.0, 48.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 22)
	UiStyle.style_button(btn)
	btn.pressed.connect(on_pressed)
	return btn
