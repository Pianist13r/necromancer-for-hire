class_name UpgradeNode
extends Button
##
## Узел дерева покупок (slow/tree, Игорь 26.09: «дерево… с иконками… надо читать до фига текста»):
## круглая печать с иконкой, цена числом со значком валюты, короткая подпись. Состояние читается
## без текста — формой, а не только цветом (правило «не цветом одним»):
##   куплено        — золотое кольцо, тёплая подложка, зелёная галочка;
##   можно купить   — кольцо цвета ветки, мягко пульсирует, цена золотом;
##   не хватает     — кольцо приглушено, цена красным;
##   закрыто        — иконка потускнела, серое кольцо, замок в углу.
## Рисуется целиком в _draw (Button без своих стилей): 35 узлов «Конторы» — 35 вызовов отрисовки
## без вложенных Label/TextureRect, и нечему перехватывать мышь мимо самого узла.
##

enum State { OWNED, BUYABLE, POOR, LOCKED }

## Имена состояний для тестов (meta "tree_state") — тест читает их, не зная класса узла, чтобы
## мог честно упасть на старом экране без узлов.
const STATE_NAMES: Array[String] = ["owned", "buyable", "poor", "locked"]
const RADIUS := 30.0
const CIRCLE_Y := 34.0
const ICON_SIDE := 44.0
const LOCK_TEX := preload("res://assets/legion/icons/tree_lock.png")
const LINE_DIM := Color(0.36, 0.33, 0.44)

var key := ""
var grid := Vector2i.ZERO
var state: State = State.LOCKED
var icon_tex: Texture2D
var accent: Color = Cfg.RUNE_COLOR
## 0 — цену не рисуем (купленный узел цены не показывает).
var price := 0
var price_tex: Texture2D
## Подпись под узлом (1–3 слова); "" — без подписи (у цепочек «Конторы» имя — над цепочкой).
var caption := ""
## Подсказка: заголовок, одна строка «что даёт» с числами, строка цены/требования.
var tip_title := ""
var tip_what := ""
var tip_need := ""

var _deny := 0.0
var _pop := 0.0
var _t := 0.0
var _plate := StyleBoxFlat.new()


func _init() -> void:
	flat = true
	text = ""
	_plate.bg_color = Color(0.05, 0.035, 0.08, 1.0)
	_plate.set_corner_radius_all(6)
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Свой рисунок целиком — стили темы Button не нужны ни в одном состоянии (иначе фокус
	# рисовал бы прямоугольную рамку вокруг круглой печати).
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		add_theme_stylebox_override(st, empty)


func setup(node_key: String, tex_path: String, node_accent: Color, node_caption: String,
		cell: Vector2i) -> void:
	key = node_key
	grid = cell
	accent = node_accent
	caption = node_caption
	icon_tex = LegionIcons.tex(tex_path)
	name = node_key.replace(":", "_")
	set_meta("tree_key", node_key)
	set_meta("tree_icon", LegionIcons.DIR + tex_path + ".png")


func set_state(new_state: State, new_price: int, currency: Texture2D) -> void:
	state = new_state
	price = new_price if new_state != State.OWNED else 0
	price_tex = currency
	set_meta("tree_state", STATE_NAMES[new_state])
	set_process(new_state == State.BUYABLE)
	queue_redraw()


## Отказ: короткое красное мигание кольца (причину пишет подсказка).
func flash_denied() -> void:
	set_meta("tree_denied", true)
	create_tween().tween_method(func(v: float) -> void:
		_deny = v
		queue_redraw(), 1.0, 0.0, 0.45)


## Покупка: золотая волна расходится от печати.
func flash_bought() -> void:
	create_tween().tween_method(func(v: float) -> void:
		_pop = v
		queue_redraw(), 1.0, 0.0, 0.4)


func circle_center() -> Vector2:
	return Vector2(size.x * 0.5, CIRCLE_Y)


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _notification(what: int) -> void:
	# Наведение/фокус меняют толщину кольца — перерисовать; Button сам этого не делает для
	# пустых стилей.
	if what in [NOTIFICATION_MOUSE_ENTER, NOTIFICATION_MOUSE_EXIT, NOTIFICATION_FOCUS_ENTER,
			NOTIFICATION_FOCUS_EXIT]:
		queue_redraw()


func _draw() -> void:
	var c := circle_center()
	var hovered := is_hovered()
	var locked := state == State.LOCKED

	if state == State.BUYABLE:
		var pulse := 0.5 + 0.5 * sin(_t * 3.2)
		draw_circle(c, RADIUS + 5.0 + 3.0 * pulse, Color(accent, 0.16 + 0.14 * pulse))
	if _pop > 0.0:
		draw_arc(c, RADIUS + 4.0 + (1.0 - _pop) * 22.0, 0.0, TAU, 48, Color(UiStyle.GOLD, _pop),
			3.0, true)

	var bg := Color(0.22, 0.15, 0.06, 0.98) if state == State.OWNED else Color(0.08, 0.06, 0.12, 0.98)
	draw_circle(c, RADIUS, bg)

	if icon_tex != null:
		var mod := Color.WHITE
		if locked:
			mod = Color(0.42, 0.40, 0.48, 0.75)
		elif state == State.POOR:
			mod = Color(0.86, 0.84, 0.9)
		var half := ICON_SIDE * 0.5
		draw_texture_rect(icon_tex, Rect2(c - Vector2(half, half), Vector2(ICON_SIDE, ICON_SIDE)),
			false, mod)

	var ring := LINE_DIM
	var width := 3.0
	match state:
		State.OWNED:
			ring = UiStyle.GOLD
			width = 4.0
		State.BUYABLE:
			ring = accent.lightened(0.15)
			width = 4.0
		State.POOR:
			ring = Color(accent, 0.55)
	if hovered:
		ring = ring.lightened(0.3)
		width += 1.0
	if _deny > 0.0:
		ring = ring.lerp(UiStyle.BAD, _deny)
		width += 2.0 * _deny
	draw_arc(c, RADIUS, 0.0, TAU, 56, ring, width, true)
	if has_focus():
		draw_arc(c, RADIUS + 6.0, 0.0, TAU, 56, Cfg.RUNE_CORE, 2.5, true)

	if state == State.OWNED:
		_draw_check(c + Vector2(RADIUS * 0.86, RADIUS * 0.8))
	elif locked:
		var lc := c + Vector2(RADIUS * 0.86, RADIUS * 0.8)
		draw_circle(lc, 11.0, Color(0.08, 0.06, 0.12))
		draw_texture_rect(LOCK_TEX, Rect2(lc - Vector2(10.0, 10.0), Vector2(20.0, 20.0)), false)

	var y := CIRCLE_Y + RADIUS + 20.0
	if price > 0:
		_draw_price(y, locked)
		y += 20.0
	if caption != "":
		var col := UiStyle.TEXT_DIM if locked else UiStyle.TEXT
		if state == State.OWNED:
			col = UiStyle.GOLD
		var cw := UiStyle.FONT_TEXT.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15).x
		_draw_plate(Rect2((size.x - cw) * 0.5 - 5.0, y - 14.0, cw + 10.0, 19.0))
		draw_string(UiStyle.FONT_TEXT, Vector2(0.0, y), caption, HORIZONTAL_ALIGNMENT_CENTER, size.x,
			15, col)


## Тёмная плашка под ценой/подписью: линия связи идёт от кольца к следующему узлу под текстом.
func _draw_plate(r: Rect2) -> void:
	draw_style_box(_plate, r)


func _draw_check(at: Vector2) -> void:
	draw_circle(at, 11.0, Color(0.09, 0.09, 0.19))
	draw_circle(at, 9.0, UiStyle.GOOD)
	draw_polyline(PackedVector2Array([at + Vector2(-4.5, 0.0), at + Vector2(-1.2, 3.8),
		at + Vector2(5.0, -4.0)]), Color(0.09, 0.09, 0.19), 2.6, true)


func _draw_price(baseline: float, locked: bool) -> void:
	var col := UiStyle.GOLD
	if state == State.POOR:
		col = UiStyle.BAD
	elif locked:
		col = Color(UiStyle.TEXT_DIM, 0.6)
	var s := str(price)
	var fsize := 17
	var tw := UiStyle.FONT_TITLE.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize).x
	var icon := 18.0 if price_tex != null else 0.0
	var x0 := (size.x - tw - icon - 3.0) * 0.5
	_draw_plate(Rect2(x0 - 5.0, baseline - 16.0, tw + icon + 13.0, 20.0))
	if price_tex != null:
		draw_texture_rect(price_tex, Rect2(x0, baseline - 15.0, icon, icon), false,
			Color(1, 1, 1, 0.55) if locked else Color.WHITE)
	draw_string(UiStyle.FONT_TITLE, Vector2(x0 + icon + 3.0, baseline), s, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, fsize, col)
