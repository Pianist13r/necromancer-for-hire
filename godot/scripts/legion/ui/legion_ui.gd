class_name LegionUi
extends RefCounted
##
## Единый стиль боевого интерфейса v17 — «бюрократия преисподней» (docs/legion/DESIGN_V17.md §1):
## тёмный бланк с чернильной рамкой и едва заметной линовкой, штамп-бейдж (клавиша, счётчик),
## полоса-шкала с плавным ходом и «хвостом» урона, всплеск числа при изменении. Другие потоки
## (Отсрочка, комбо, Юрист) берут оформление отсюда, а не рисуют своё.
##
## Главное — читается одним взглядом, пока игрок чертит линии: числа — чистым системным шрифтом
## (FONT_NUM), рукописный Underdog — только подписи и заголовки, украшения тусклые.
##
## Два способа нарисовать бланк: StyleBox (`blank_style` — для PanelContainer/Button) и прямой
## вызов в `_draw` (`draw_blank`) — одна функция рисования на оба пути, вид не расходится.
##

const FONT_TITLE := preload("res://assets/fonts/Underdog-Regular.ttf")
const FONT_TEXT := preload("res://assets/fonts/Neucha-Regular.ttf")

## Тёмная бумага бланка (тёплый фиолетово-бурый, просвечивает арену на 12 %).
const PAPER := Color(0.085, 0.068, 0.095, 0.88)
## Бланк под курсором / выбранный.
const PAPER_HI := Color(0.15, 0.115, 0.17, 0.94)
## Чернила рамки — фиолетовые, как руна-договор.
const INK := Color(0.66, 0.56, 0.92, 0.9)
const INK_FAINT := Color(0.66, 0.56, 0.92, 0.32)
## Линовка бланка — на грани видимости: фактура, а не шум.
const RULE := Color(0.8, 0.74, 1.0, 0.05)
const RULE_STEP := 8.0
## Красные чернила печати: штамп «Вызвать», предупреждения, урон Котлу.
const STAMP := Color(0.93, 0.3, 0.26)
const GOLD := Color(1.0, 0.82, 0.48)
const TEXT := Color(0.95, 0.92, 1.0)
const TEXT_DIM := Color(0.76, 0.72, 0.86)
const BAD := Color(1.0, 0.36, 0.33)
const GOOD := Color(0.55, 1.0, 0.66)
const MANA := Color(0.62, 0.43, 1.0)
## Контур текста поверх арены: без него светлая подпись тонет в светлой земле.
const OUTLINE := Color(0.0, 0.0, 0.0, 0.85)


## Шрифт чисел: системный (тема по умолчанию) — цифры в нём ровнее и шире рукописных.
static func num_font() -> Font:
	return ThemeDB.fallback_font


# ── Бланк ───────────────────────────────────────────────────────────────────

## StyleBox бланка: рисует тот же draw_blank_rid. Внутренний класс, чтобы Button и
## PanelContainer получали бланк через обычные theme override, без картинок-девятисрезок.
class BlankBox:
	extends StyleBox

	var bg := LegionUi.PAPER
	var ink := LegionUi.INK
	var ruled := true
	var border := 2.0

	func _draw(to_canvas_item: RID, rect: Rect2) -> void:
		LegionUi.draw_blank_rid(to_canvas_item, rect, bg, ink, ruled, border)


## Бланк-StyleBox с полями под содержимое.
static func blank_style(ink: Color = INK, bg: Color = PAPER, margin_h: float = 12.0,
		margin_v: float = 7.0, ruled: bool = true) -> BlankBox:
	var st := BlankBox.new()
	st.ink = ink
	st.bg = bg
	st.ruled = ruled
	st.content_margin_left = margin_h
	st.content_margin_right = margin_h
	st.content_margin_top = margin_v
	st.content_margin_bottom = margin_v
	return st


## Бланк в `_draw` виджета.
static func draw_blank(ci: CanvasItem, rect: Rect2, ink: Color = INK, bg: Color = PAPER,
		ruled: bool = true, border: float = 2.0) -> void:
	draw_blank_rid(ci.get_canvas_item(), rect, bg, ink, ruled, border)


## Бумага, линовка, двойная чернильная рамка (толстая снаружи, волосяная внутри — как у
## печатного бланка) и уголки-засечки. Всё векторное: масштаб и цвет — параметрами.
static func draw_blank_rid(rid: RID, rect: Rect2, bg: Color, ink: Color, ruled: bool,
		border: float) -> void:
	var rs := RenderingServer
	# Тонкая тень и светлый верх придают бланку толщину, не съедая место под текст.
	rs.canvas_item_add_rect(rid, Rect2(rect.position + Vector2(0.0, 3.0), rect.size),
		Color(0.025, 0.018, 0.03, bg.a * 0.45))
	rs.canvas_item_add_rect(rid, rect, bg)
	var sheen := Rect2(rect.position + Vector2(3.0, 3.0),
		Vector2(maxf(0.0, rect.size.x - 6.0), minf(12.0, rect.size.y * 0.2)))
	rs.canvas_item_add_rect(rid, sheen, Color(0.94, 0.82, 0.63, 0.055))
	if ruled and rect.size.y > RULE_STEP * 2.0:
		var y := rect.position.y + RULE_STEP + 2.0
		while y < rect.end.y - 4.0:
			rs.canvas_item_add_line(rid, Vector2(rect.position.x + 5.0, y),
				Vector2(rect.end.x - 5.0, y), RULE, 1.0)
			y += RULE_STEP
	var r := rect.grow(-border * 0.5)
	var outer := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end,
		Vector2(r.position.x, r.end.y), r.position])
	rs.canvas_item_add_polyline(rid, outer, PackedColorArray([ink]), border)
	rs.canvas_item_add_line(rid, r.position + Vector2(2.0, 1.0),
		Vector2(r.end.x - 2.0, r.position.y + 1.0), Color(1.0, 0.87, 0.63, ink.a * 0.32), 1.0)
	var inner := rect.grow(-border - 2.5)
	if inner.size.x > 8.0 and inner.size.y > 8.0:
		var pts := PackedVector2Array([inner.position, Vector2(inner.end.x, inner.position.y),
			inner.end, Vector2(inner.position.x, inner.end.y), inner.position])
		rs.canvas_item_add_polyline(rid, pts, PackedColorArray([Color(ink, ink.a * 0.35)]), 1.0)
	# засечки в углах — «уголки» бланка, по 5 px наружу по горизонтали
	var tick := Color(ink, ink.a * 0.8)
	for c in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
			Vector2(rect.position.x, rect.end.y)]:
		var sx := -1.0 if c.x <= rect.position.x else 1.0
		rs.canvas_item_add_line(rid, c, c + Vector2(sx * 4.0, 0.0), tick, border)


## Кнопка-бланк: обычная / под курсором / нажата / закрыта / фокус. Рамка — общая художественная
## девятисрезка UiStyle (латунь + тёмная эмаль, docs/dev/UI_ART.md); чернила ink ложатся
## модуляцией в тон рамки, текст и шрифт — свои, канцелярские.
static func style_button(btn: Button, ink: Color = INK, font_size: int = 16) -> void:
	UiStyle.style_button(btn)
	# тонировка рамки чернилами (кнопка «Вызвать» краснеет, кнопка «Ещё раз» золотеет)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := btn.get_theme_stylebox(state) as StyleBoxTexture
		if sb != null:
			# Боевые карточки и превью волн рассчитаны на эти поля: новый рисунок
			# не должен увеличивать область HUD и закрывать площадки карты.
			sb.content_margin_left = 12.0
			sb.content_margin_right = 12.0
			sb.content_margin_top = 5.0
			sb.content_margin_bottom = 5.0
			var tint := sb.modulate_color.lerp(ink, 0.45)
			sb.modulate_color = Color(tint.r, tint.g, tint.b, sb.modulate_color.a)
	btn.add_theme_font_override("font", FONT_TEXT)
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", TEXT)
	btn.add_theme_color_override("font_disabled_color", Color(TEXT_DIM, 0.45))


## Подпись с контуром (читается поверх любой земли).
static func label(text: String, size: int, font: Font = FONT_TEXT, color: Color = TEXT) -> Label:
	var l := UiStyle.label(text, size, font, color)
	l.add_theme_color_override("font_outline_color", OUTLINE)
	l.add_theme_constant_override("outline_size", 3)
	return l


## Общая нижняя панель: возврат слева, главное действие справа. Центр свободен для услуг.
static func nav_bar(parent: Control, left_text: String, on_back: Callable,
		right_text := "", on_next: Callable = Callable()) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Navigation"
	parent.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	row.offset_left = 24
	row.offset_right = -24
	row.offset_top = -76
	row.offset_bottom = -24
	row.add_theme_constant_override("separation", 14)
	var back := ProgressionUi.button(left_text, on_back)
	back.name = "NavBack"
	style_button(back, INK, 20)
	row.add_child(back)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	if right_text != "":
		var next := ProgressionUi.button(right_text, on_next)
		next.name = "NavPrimary"
		next.custom_minimum_size = Vector2(220, 52)
		style_button(next, GOLD, 22)
		row.add_child(next)
		var shortcut := Shortcut.new()
		var key := InputEventKey.new()
		key.keycode = KEY_ENTER
		shortcut.events = [key]
		next.shortcut = shortcut
	var cancel := Shortcut.new()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	cancel.events = [escape]
	back.shortcut = cancel
	return row


static func confirm(parent: Node, message: String, action: Callable) -> void:
	for child in parent.get_children():
		if child is ConfirmationDialog and not child.is_queued_for_deletion():
			return
	var dialog := ConfirmationDialog.new()
	dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	dialog.dialog_text = message
	dialog.ok_button_text = "Подтвердить"
	dialog.cancel_button_text = "Отмена"
	parent.add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		dialog.queue_free()
		action.call())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(480, 180))


# ── Штамп ───────────────────────────────────────────────────────────────────

## Штамп-бейдж: прямоугольник красных (или любых) чернил под небольшим углом, двойной контур,
## текст по центру. Для клавиш (1/2/3, Q/W/E) и счётчиков.
static func draw_stamp(ci: CanvasItem, center: Vector2, text: String, color: Color = STAMP,
		size: int = 14, angle: float = -0.12, min_w: float = 0.0) -> void:
	var font: Font = FONT_TITLE
	var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var w := maxf(min_w, ts.x + 10.0)
	var h := float(size) + 8.0
	ci.draw_set_transform(center, angle)
	var r := Rect2(Vector2(-w * 0.5, -h * 0.5), Vector2(w, h))
	ci.draw_rect(r, Color(0.06, 0.03, 0.04, 0.9), true)
	ci.draw_rect(r, Color(color, 0.95), false, 2.0)
	ci.draw_rect(r.grow(-3.0), Color(color, 0.45), false, 1.0)
	var base := Vector2(-ts.x * 0.5, font.get_ascent(size) - ts.y * 0.5)
	ci.draw_string(font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color.lightened(0.35))
	ci.draw_set_transform(Vector2.ZERO)


# ── Шкала ───────────────────────────────────────────────────────────────────

## Полоса-шкала: подложка, «хвост» урона (ghost > frac — светлый кусок, который догоняет),
## заливка, блик сверху, риски четвертей и чернильный контур.
static func draw_bar(ci: CanvasItem, rect: Rect2, frac: float, color: Color,
		ghost: float = -1.0, flash: float = 0.0) -> void:
	frac = clampf(frac, 0.0, 1.0)
	ci.draw_rect(rect, Color(0.0, 0.0, 0.0, 0.55), true)
	if ghost > frac:
		var g := Rect2(rect.position + Vector2(rect.size.x * frac, 0.0),
			Vector2(rect.size.x * (minf(ghost, 1.0) - frac), rect.size.y))
		ci.draw_rect(g, Color(1.0, 0.9, 0.8, 0.75), true)
	if frac > 0.0:
		var f := Rect2(rect.position, Vector2(rect.size.x * frac, rect.size.y))
		var c := color.lerp(Color.WHITE, clampf(flash, 0.0, 1.0) * 0.6)
		ci.draw_rect(f, c, true)
		ci.draw_rect(Rect2(f.position, Vector2(f.size.x, maxf(1.0, rect.size.y * 0.3))),
			Color(1.0, 1.0, 1.0, 0.22), true)
	for k in [0.25, 0.5, 0.75]:
		var x: float = rect.position.x + rect.size.x * k
		ci.draw_line(Vector2(x, rect.position.y + 1.0), Vector2(x, rect.end.y - 1.0),
			Color(0.0, 0.0, 0.0, 0.45), 1.0)
	ci.draw_rect(rect, Color(INK, 0.55), false, 1.0)


## Число с контуром; bump 0..1 — всплеск (увеличение от точки привязки и подсветка).
## anchor — левый нижний угол строки при align LEFT, правый нижний при RIGHT.
static func draw_number(ci: CanvasItem, anchor: Vector2, text: String, size: int, color: Color,
		bump: float = 0.0, align_right: bool = false) -> void:
	var font := num_font()
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var s := 1.0 + 0.3 * clampf(bump, 0.0, 1.0)
	var pivot := anchor + Vector2(-w * 0.5 if align_right else w * 0.5, -size * 0.35)
	ci.draw_set_transform(pivot, 0.0, Vector2(s, s))
	var at := anchor - pivot + (Vector2(-w, 0.0) if align_right else Vector2.ZERO)
	var col := color.lerp(Color.WHITE, clampf(bump, 0.0, 1.0) * 0.5)
	ci.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, OUTLINE)
	ci.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	ci.draw_set_transform(Vector2.ZERO)


## Подпись в `_draw` с контуром.
static func draw_text(ci: CanvasItem, at: Vector2, text: String, size: int, color: Color,
		font: Font = FONT_TEXT, align_right: bool = false) -> void:
	var x := at.x
	if align_right:
		x -= font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	ci.draw_string_outline(font, Vector2(x, at.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 3,
		Color(OUTLINE, OUTLINE.a * color.a))
	ci.draw_string(font, Vector2(x, at.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


## Сектор отката: тёмный «пирог» от 12 часов по часовой стрелке на долю frac.
static func draw_pie(ci: CanvasItem, center: Vector2, radius: float, frac: float,
		color: Color) -> void:
	if frac <= 0.0:
		return
	var pts := PackedVector2Array([center])
	var steps := maxi(3, int(ceil(40.0 * frac)))
	for i in steps + 1:
		var a := -PI * 0.5 + TAU * frac * float(i) / float(steps)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	ci.draw_colored_polygon(pts, color)


## Плавная шкала с «хвостом» и всплеском числа. Живёт в виджете, обновляется в `_process`.
## shown — что рисует полоса (догоняет цель экспонентой), ghost — светлый хвост после потери
## (держится HOLD и сползает), bump — всплеск числа при изменении ≥ bump_min, flash — вспышка
## (выставляет владелец, например при уроне Котлу).
class Meter:
	extends RefCounted

	const HOLD := 0.35
	var shown := 0.0
	var ghost := 0.0
	var bump := 0.0
	var flash := 0.0
	var bump_min := 1.0
	## Мана растёт непрерывно — всплеск на каждом пополнении мельтешил бы; её пульсирует только трата.
	var bump_on_gain := true
	var _last := NAN
	var _hold := 0.0

	func _init(min_step: float = 1.0, on_gain: bool = true) -> void:
		bump_min = min_step
		bump_on_gain = on_gain

	func update(target: float, dt: float) -> void:
		if is_nan(_last):
			_last = target
			shown = target
			ghost = target
		if target < _last - 0.001:
			if _last - target >= bump_min:
				_hold = HOLD
				ghost = maxf(ghost, shown)
				bump = 1.0
			_last = target
		elif target - _last >= bump_min:
			if bump_on_gain:
				bump = 1.0
			_last = target
		shown = lerpf(shown, target, 1.0 - exp(-14.0 * dt))
		if absf(shown - target) < 0.01:
			shown = target
		if _hold > 0.0:
			_hold -= dt
		else:
			ghost = lerpf(ghost, shown, 1.0 - exp(-5.0 * dt))
		ghost = maxf(ghost, shown)
		bump = maxf(0.0, bump - dt * 4.0)
		flash = maxf(0.0, flash - dt * 2.2)
