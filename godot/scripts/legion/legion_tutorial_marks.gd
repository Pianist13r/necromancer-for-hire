class_name LegionTutorialMarks
extends Node2D
##
## Метки уроков карты (LegionTutorial) в мире — показать, а не написать: светящаяся пунктирная
## линия «черти здесь» с бегущей мышью (договор), клавиша «Пробел» над линией и дуга поворота
## (стрелка), бегущая мышь вдоль своей линии (подновление), значок мыши с подсвеченной правой
## кнопкой над линией (натиск),
## круг и клавиша R над свободными (Сбор), кольцо и стрелка над площадкой (Бытовка), кольцо и
## клавиша Q/W/E над целью способности, шаблон фигуры с бегущей мышью (кольцо/восьмёрка/
## треугольник/квадрат),
## кольцо на прогнутом участке («пружина») и на элитном (предмет). Выше бойцов и эффектов героя
## (z_index), иначе строй закрывает метку. Пульс — по игровому времени кадра, а не по часам ОС:
## в записи ролика (--fixed-fps) иначе мигало бы вразнобой.
##
## Отдельный файл, а не внутренний класс legion_tutorial.gd: тот упёрся в потолок gdlint
## (1000 строк), когда тур вырос до девяти шагов.
##

const Z := 60
const COLOR := UiStyle.GOLD
const LIT := Color(1.0, 0.78, 0.2)
const SHADOW := Color(0.03, 0.02, 0.06, 0.8)
const PULSE_RATE := 5.0
const GHOST_GLOW_W := 30.0
const GHOST_W := 7.0
const GHOST_DASH := 14.0
const GHOST_RUN_TIME := 1.8
const GHOST_MOUSE_LIFT := 44.0
const MOUSE_SIZE := Vector2(32.0, 46.0)
const MOUSE_LIFT := 74.0
const BOB := 5.0
const BOB_RATE := 4.0
const RING_R := 18.0
const PLOT_RING_R := 48.0
const PLOT_RING_SQUASH := 0.55
const ARROW_LIFT := 58.0
const ARROW_SIZE := Vector2(26.0, 22.0)
const FOE_RING_R := 24.0
const FOE_KEY_LIFT := 70.0
const KEY_SIZE := 28.0
const KEY_FONT := 20
const KEY_PAD := 10.0
## Дуга «стрелка ходит за мышью»: радиус и размах (рад) вокруг середины договора.
const SWING_R := 46.0
const SWING_ARC := 1.4
## Широкие круги (Сбор, Аврал) — тоньше и прозрачнее: они про область, а не про цель.
const AREA_ALPHA := 0.45
## Выше этой строки экрана значок не ставим — там плашка и тосты под ней; цель у верхнего
## края — значок переезжает под неё.
const SAFE_TOP := 120.0

var tut: LegionTutorial = null
var _t := 0.0

func _init(t: LegionTutorial) -> void:
	tut = t
	z_index = Z

func _process(dt: float) -> void:
	# на паузе кампании метка (z_index выше всего слоя) светилась поверх затемнения экрана
	# паузы (кадр приёмки skip 25.09) — прячем, как и плашку
	visible = not tut.world.paused
	_t += dt
	queue_redraw()

func _draw() -> void:
	if tut == null or not tut.active:
		return
	var pulse := 0.5 + 0.5 * sin(_t * PULSE_RATE)
	var bob := sin(_t * BOB_RATE) * BOB
	match tut.step_kind():
		&"draw":
			if tut.ghost_points().size() >= 2:
				_draw_ghost(pulse)
		&"aim":
			var c := tut.line_target()
			if c != null:
				_draw_swing(c, pulse)
				_draw_key(_key_above(c.point_at(c.length * 0.5), bob), Controls.label(&"aim_contract", true))
		&"refresh":
			var c := tut.line_target()
			if c != null:
				_draw_run(c.points, pulse)
		&"release", &"perfect":
			_draw_rmb(tut.release_target(), pulse, bob)
		&"erase":
			var hit := tut.release_target()
			if not hit.is_empty():
				var at := (hit["contract"] as Contract).seg_center(int(hit["seg"]))
				_draw_ring(at, RING_R + 4.0 * pulse, 1.0, pulse)
				_draw_key(_key_above(at, bob), Controls.label(&"erase_piece", true))
		&"spring":
			_draw_rmb(tut.spring_target(), pulse, bob)
		&"stun_hit":
			var f := tut.stunned_foe()
			if f != null:
				_draw_ring(f.position, FOE_RING_R + 4.0 * pulse, PLOT_RING_SQUASH, pulse)
			_draw_rmb(tut.release_target(), pulse, bob)
		&"rally":
			var at := tut.rally_target()
			if at != Vector2.INF:
				_draw_area(at, LegionCfg.RALLY_R, pulse)
				_draw_key(_key_on_area(at, LegionCfg.RALLY_R, bob), Controls.label(&"rally"))
		&"build":
			var p := tut.target_plot()
			if not p.is_empty():
				var at: Vector2 = p["pos"]
				_draw_ring(at, PLOT_RING_R + 5.0 * pulse, PLOT_RING_SQUASH, pulse)
				_draw_down_arrow(at + Vector2(0.0, -ARROW_LIFT + bob))
		&"hero_q", &"item":
			var f := tut.target_foe()
			if f != null:
				_draw_ring(f.position, FOE_RING_R + 4.0 * pulse, PLOT_RING_SQUASH, pulse)
				if tut.step_kind() == &"hero_q":
					_draw_key(_key_above(f.position, bob), Controls.label(&"cast_q"))
		&"hero_w":
			var corpse := tut.target_corpse()
			if corpse != null:
				_draw_ring(corpse.position, FOE_RING_R + 4.0 * pulse, PLOT_RING_SQUASH, pulse)
				_draw_key(_key_above(corpse.position, bob), Controls.label(&"cast_w"))
		&"hero_e":
			var at := tut.aura_target()
			if at != Vector2.INF:
				_draw_area(at, LegionCfg.E_RADIUS, pulse)
				_draw_key(_key_on_area(at, LegionCfg.E_RADIUS, bob), Controls.label(&"cast_e"))
		&"figure":
			_draw_template(tut.figure_points(), pulse)

## Значок ПКМ над участком {contract, seg}: кольцо на участке и мышь с горящей правой кнопкой.
func _draw_rmb(hit: Dictionary, pulse: float, bob: float) -> void:
	if hit.is_empty():
		return
	var at: Vector2 = (hit["contract"] as Contract).seg_center(int(hit["seg"]))
	_draw_ring(at, RING_R + 4.0 * pulse, 1.0, pulse)
	var lift := -MOUSE_LIFT if at.y - MOUSE_LIFT > SAFE_TOP else MOUSE_LIFT
	var icon := at + Vector2(0.0, lift + bob)
	draw_line(icon - Vector2(0.0, signf(lift) * MOUSE_SIZE.y * 0.5),
		at + Vector2(0.0, signf(lift) * RING_R), Color(COLOR, 0.7), 2.0, true)
	_draw_mouse(icon, MOUSE_BUTTON_RIGHT, pulse)

## Клавиша над целью; у верхнего края — под ней (там плашка и тосты).
func _key_above(at: Vector2, bob: float) -> Vector2:
	var lift := -FOE_KEY_LIFT
	if at.y - FOE_KEY_LIFT < SAFE_TOP:
		lift = FOE_KEY_LIFT * 0.5
	return at + Vector2(0.0, lift + bob)

## Клавиша широкой способности — на верхней кромке её круга: в середине круга стоит строй и
## Котёл с полоской здоровья (кадр шага «Сбор» 26.09 — клавиша закрывала полоску). Кромка
## выше плашки — клавиша опускается под неё.
func _key_on_area(at: Vector2, radius: float, bob: float) -> Vector2:
	return Vector2(at.x, maxf(at.y - radius, SAFE_TOP + KEY_SIZE) + bob)


## Пунктир-призрак и «рука»: мышь с горящей левой кнопкой бежит от начала к концу линии.
func _draw_ghost(pulse: float) -> void:
	var pts := tut.ghost_points()
	var a := pts[0]
	var b := pts[pts.size() - 1]
	draw_line(a, b, Color(COLOR, 0.25 + 0.2 * pulse), GHOST_GLOW_W, true)
	draw_dashed_line(a, b, SHADOW, GHOST_W + 3.0, GHOST_DASH, true, true)
	draw_dashed_line(a, b, Color(COLOR, 0.7 + 0.3 * pulse), GHOST_W, GHOST_DASH, true, true)
	draw_circle(a, 8.0, SHADOW)
	draw_circle(a, 6.0, COLOR)
	draw_arc(b, 8.0, 0.0, TAU, 20, COLOR, 2.5, true)
	_draw_runner(a.lerp(b, fmod(_t, GHOST_RUN_TIME) / GHOST_RUN_TIME))

## Шаблон фигуры: светящийся пунктир по всей фигуре и бегущая мышь с горящей ЛКМ — «обведи так».
## Пунктир, а не только свечение: кольцо у Котла тонуло в строе и сиянии Котла (кадр fork_ring).
func _draw_template(pts: PackedVector2Array, pulse: float) -> void:
	if pts.size() < 2:
		return
	draw_polyline(pts, Color(COLOR, 0.2 + 0.2 * pulse), GHOST_GLOW_W, true)
	draw_polyline(pts, SHADOW, GHOST_W + 3.0, true)
	var dash := maxi(1, roundi(GHOST_DASH / LessonsCfg.FIG_STEP))
	for i in range(1, pts.size()):
		if (i / dash) % 2 == 0:
			draw_line(pts[i - 1], pts[i], Color(COLOR, 0.7 + 0.3 * pulse), GHOST_W, true)
	draw_circle(pts[0], 8.0, SHADOW)
	draw_circle(pts[0], 6.0, COLOR)
	_draw_run(pts, pulse)


## Подновление: та же бегущая мышь с горящей ЛКМ, но вдоль своей линии — «веди по ней».
func _draw_run(pts: PackedVector2Array, pulse: float) -> void:
	if pts.size() < 2:
		return
	draw_polyline(pts, Color(COLOR, 0.2 + 0.2 * pulse), GHOST_GLOW_W, true)
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	var d := total * fmod(_t, GHOST_RUN_TIME) / GHOST_RUN_TIME
	var at := pts[pts.size() - 1]
	for i in range(1, pts.size()):
		var seg := pts[i - 1].distance_to(pts[i])
		if d <= seg and seg > 0.0:
			at = pts[i - 1].lerp(pts[i], d / seg)
			break
		d -= seg
	_draw_runner(at)

func _draw_runner(at: Vector2) -> void:
	draw_circle(at, 7.0, Color(1.0, 1.0, 1.0, 0.9))
	# мышь едет НАД линией (не на ней — закрыла бы пунктир), от начала к концу
	draw_line(at, at + Vector2(0.0, -GHOST_MOUSE_LIFT + MOUSE_SIZE.y * 0.5),
		Color(1.0, 1.0, 1.0, 0.6), 2.0, true)
	_draw_mouse(at + Vector2(0.0, -GHOST_MOUSE_LIFT), MOUSE_BUTTON_LEFT, 1.0)

## Стрелка: дуга со стрелками на концах вокруг середины договора, по обе стороны от его
## стрелки — «её можно вертеть». Саму стрелку отряда рисует ContractField.
func _draw_swing(c: Contract, pulse: float) -> void:
	var mid := c.point_at(c.length * 0.5)
	var ang := c.dir.angle()
	var col := Color(COLOR, 0.6 + 0.4 * pulse)
	var a0 := ang - SWING_ARC * 0.5
	var a1 := ang + SWING_ARC * 0.5
	draw_arc(mid, SWING_R, a0, a1, 24, SHADOW, 6.0, true)
	draw_arc(mid, SWING_R, a0, a1, 24, col, 3.0, true)
	for end_a: float in [a0, a1]:
		var tip := mid + Vector2.from_angle(end_a) * SWING_R
		var tangent := Vector2.from_angle(end_a + (PI * 0.5 if end_a == a1 else -PI * 0.5))
		var side := Vector2.from_angle(end_a) * 6.0
		draw_colored_polygon(PackedVector2Array([
			tip + tangent * 9.0, tip + side, tip - side]), col)

## Круг области способности (Сбор, Аврал) — в мировом радиусе, как круг прицела в игре.
func _draw_area(at: Vector2, radius: float, pulse: float) -> void:
	draw_arc(at, radius, 0.0, TAU, 64, SHADOW, 5.0, true)
	draw_arc(at, radius, 0.0, TAU, 64, Color(COLOR, AREA_ALPHA + 0.3 * pulse), 2.5, true)

## Иконка мыши кодом: корпус, разрез кнопок, горящая кнопка `lit` (левая/правая).
func _draw_mouse(center: Vector2, lit: MouseButton, pulse: float) -> void:
	var half := MOUSE_SIZE * 0.5
	var r := half.x
	var body := PackedVector2Array()
	# корпус — «таблетка»: полуокружности сверху и снизу, прямые бока
	for i in 13:
		body.append(center + Vector2(0.0, -half.y + r) + Vector2.from_angle(PI + PI * i / 12.0) * r)
	for i in 13:
		body.append(center + Vector2(0.0, half.y - r) + Vector2.from_angle(PI * i / 12.0) * r)
	draw_colored_polygon(body, Color(0.12, 0.1, 0.16, 0.95))
	var top := center + Vector2(0.0, -half.y + r)
	var btn := PackedVector2Array([center + Vector2(0.0, -half.y + r * 0.1)])
	# дуга кнопки — от верха корпуса к её боку (вправо или влево), иначе многоугольник
	# выворачивается и не триангулируется
	var to_a := 0.0 if lit == MOUSE_BUTTON_RIGHT else -PI
	for i in 9:
		btn.append(top + Vector2.from_angle(lerpf(-PI * 0.5, to_a, i / 8.0)) * (r - 2.5))
	var side := 1.0 if lit == MOUSE_BUTTON_RIGHT else -1.0
	btn.append(center + Vector2(side * (r - 2.5), -2.0))
	btn.append(center + Vector2(0.0, -2.0))
	# горящая кнопка — ярче всей остальной метки и мигает к белому: её ищут глазом первой
	draw_colored_polygon(btn, LIT.lerp(Color.WHITE, 0.45 * pulse))
	var outline := body.duplicate()
	outline.append(body[0])
	draw_polyline(outline, SHADOW, 4.0, true)
	draw_polyline(outline, Color(1.0, 1.0, 1.0, 0.9), 2.0, true)
	draw_line(center + Vector2(0.0, -half.y), center + Vector2(0.0, -2.0), Color.WHITE, 1.5, true)
	draw_line(center + Vector2(-r, -2.0), center + Vector2(r, -2.0), Color.WHITE, 1.5, true)

## Кольцо (squash < 1 — эллипс «на земле» для площадки и зомби).
func _draw_ring(at: Vector2, radius: float, squash: float, pulse: float) -> void:
	draw_set_transform(at, 0.0, Vector2(1.0, squash))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, SHADOW, 7.0, true)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(COLOR, 0.75 + 0.25 * pulse), 4.0, true)
	draw_set_transform(Vector2.ZERO)

func _draw_down_arrow(tip_top: Vector2) -> void:
	var w := ARROW_SIZE.x * 0.5
	var tri := PackedVector2Array([
		tip_top + Vector2(-w, 0.0), tip_top + Vector2(w, 0.0), tip_top + Vector2(0.0, ARROW_SIZE.y),
	])
	var stem := Rect2(tip_top + Vector2(-w * 0.35, -ARROW_SIZE.y * 0.8),
		Vector2(w * 0.7, ARROW_SIZE.y * 0.8))
	draw_rect(stem.grow(2.0), SHADOW)
	var outline := tri.duplicate()
	outline.append(tri[0])
	draw_polyline(outline, SHADOW, 5.0, true)
	draw_rect(stem, COLOR)
	draw_colored_polygon(tri, COLOR)

## Клавиша: квадрат под одну букву, шире — под слово («Пробел»).
func _draw_key(center: Vector2, text: String) -> void:
	var font := UiStyle.FONT_TITLE
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, KEY_FONT)
	var w := maxf(KEY_SIZE, sz.x + KEY_PAD * 2.0)
	var rect := Rect2(center - Vector2(w, KEY_SIZE) * 0.5, Vector2(w, KEY_SIZE))
	draw_rect(rect.grow(2.0), SHADOW)
	draw_rect(rect, Color(0.12, 0.1, 0.16, 0.95))
	draw_rect(rect, COLOR, false, 2.0)
	draw_string(font, center + Vector2(-sz.x * 0.5, sz.y * 0.32), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, KEY_FONT, COLOR)
