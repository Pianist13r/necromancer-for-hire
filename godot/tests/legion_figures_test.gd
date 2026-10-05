# gdlint: disable=max-file-lines
extends SceneTree
##
## Фигуры D-1002-03 (Игорь 02.10.2026) и D-1002 (05.10.2026). Треугольник — «Обряд», квадрат —
## «Каре»; с 05.10 бойцы этих фигур стоят ТОЛЬКО на углах, ульта — только у ЗАРЯЖЕННОГО строя
## (1,5 с заполнения порога), а распознавание знает ещё «Комиссию» (пятиугольник), «Неустойку»
## (полукруг «D») и мини-размер 48…112 px. Места, заряд, цена и «D» против круга/линий —
## в tests/legion_corners_test.gd.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_figures_test.gd -- --mute
##
## 1) корпус штрихов: треугольники и квадраты (ровные, повёрнутые, рукой с дрожью, разного
##    размера, с недотянутым и перелетевшим концом, скруглённые) признаются; круг и овал рукой,
##    восьмёрка, L, U, Z, V, зигзаг, «D», сильно скруглённый квадрат, ромб-почти-круг, вытянутый
##    клин, пяти- и шестиугольник, «бабочка», невыпуклый четырёхугольник, звезда — нет;
##    серии случайных фигур «рукой»: ≥ 90 % признаны, ни одного перепутанного; круги — ни одного
##    многоугольника;
## 2) «Обряд» треугольника: мест три (по углам), порог заряда 2/3 держится 1,5 с; срабатывает
##    при самотаянии, ПКМ, рогатке и Табе; потеря одного бойца заряд не рвёт; недобор —
##    без обряда; удар — от размера фигуры; ранний выпуск ульты не даёт;
## 3) «Каре»: четверо на углах; боец получает меньше урона, давка квадрат не прогибает и не
##    прорывает, квадрат тает дольше, заряженный срыв (3 из 4) даёт защиту участникам;
## 4) звезда больше не фигура; открытия: «Лабиринт» — треугольник и «Комиссия», «Болото» —
##    квадрат и «Неустойка»; шестиугольник не фигура, а «D» — «Неустойка»;
##    старое сохранение с показанной звездой не падает и узнаёт про треугольник;
## 5) уроки: «Мост» — треугольник, «Болото» — квадрат, оба кончаются заряженным срывом; на
##    «Мосте» штрих по шаблону урока набирает порог заряда стартовой армией, и обряд срабатывает.
## Новый API — через get()/call(): на старом коде тест не падает разбором, а проваливает
## проверки. Итог «LEGION FIGURES: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_figures_test.cfg"
const SHAPE_PATH := "res://scripts/legion/contract_shape.gd"
const FIG_CFG_PATH := "res://scripts/legion/figure_cfg.gd"
## Свободное поле карты _gray (как в legion_runes_test).
const FC := Vector2(1130.0, 405.0)
const DT := 1.0 / 60.0

var w: LegionWorld
var shape: Script = null
var fcfg: Script = null
var _fails := 0
var _checks := 0
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	if ResourceLoader.exists(SHAPE_PATH):
		shape = load(SHAPE_PATH)
	if ResourceLoader.exists(FIG_CFG_PATH):
		fcfg = load(FIG_CFG_PATH)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.set_process(false)
	_test_corpus()
	_test_random()
	_test_fast()
	_test_charge()
	_test_rite()
	_test_square()
	_test_hints()
	_test_overshoot_refund()
	_test_star_gone()
	_test_unlocks()
	_test_lessons()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION FIGURES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Генераторы штрихов «рукой» ───────────────────────────────────────────────

func _jit(p: Vector2, j: float) -> Vector2:
	return p + Vector2(_rng.randf_range(-j, j), _rng.randf_range(-j, j))


## Уплотнить ломаную до шага ~6 px (шаг мыши), дрожь jit на каждой точке.
func _dense(pts: PackedVector2Array, jit := 0.0) -> PackedVector2Array:
	var out := PackedVector2Array([_jit(pts[0], jit)])
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, ceili(a.distance_to(b) / 6.0))
		for k in range(1, n + 1):
			out.append(_jit(a.lerp(b, float(k) / n), jit))
	return out


func _chaikin(p: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([p[0]])
	for i in range(1, p.size()):
		out.append(p[i - 1].lerp(p[i], 0.25))
		out.append(p[i - 1].lerp(p[i], 0.75))
	out.append(p[p.size() - 1])
	return out


## Многоугольник одним штрихом по вершинам corners (по порядку, без повтора первой):
## start — откуда начат (доля первого ребра), end_gap — недотяг конца (px, < 0 — перелёт),
## round_n — скругление вершин рукой (Чайкин по вершинам), jit — дрожь.
func _shape(corners: Array[Vector2], start := 0.0, end_gap := 0.0, round_n := 0,
		jit := 0.0) -> PackedVector2Array:
	var m := corners.size()
	var s0 := corners[0].lerp(corners[1 % m], start)
	var path := PackedVector2Array([s0])
	for i in range(1, m + 1):
		path.append(corners[i % m])
	if start > 0.0:
		path.append(s0)
	if end_gap != 0.0:
		var last := path[path.size() - 1]
		var prev := path[path.size() - 2]
		if end_gap > 0.0:
			path[path.size() - 1] = last + (prev - last).normalized() * end_gap
		else:
			var nxt := corners[1 % m]
			path.append(last + (nxt - last).normalized() * -end_gap)
	var dense := _dense(path)
	for r in round_n:
		dense = _chaikin(dense)
	if round_n > 0:
		var thin := PackedVector2Array([dense[0]])
		for p in dense:
			if p.distance_to(thin[thin.size() - 1]) >= 6.0:
				thin.append(p)
		dense = thin
	var out := PackedVector2Array()
	for p in dense:
		out.append(_jit(p, jit))
	return out


## Правильный n-угольник: центр c, радиус вершин r, поворот rot, обход dir (±1).
func _ngon(c: Vector2, n: int, r: float, rot := 0.0, dir := 1.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in n:
		out.append(c + Vector2.from_angle(rot + dir * TAU * i / n) * r)
	return out


func _rect(c: Vector2, wd: float, ht: float, rot := 0.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for v: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		out.append(c + (v * Vector2(wd, ht) * 0.5).rotated(rot))
	return out


func _arc(c: Vector2, rx: float, ry: float, a0: float, sweep: float, wob := 0.0,
		jit := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(8, ceili(absf(sweep) * maxf(rx, ry) / 6.0))
	for i in n + 1:
		var a := a0 + sweep * float(i) / n
		var k := 1.0 + wob * sin(a * 3.0 + 0.7)
		pts.append(_jit(c + Vector2(cos(a) * rx * k, sin(a) * ry * k), jit))
	return pts


func _open(corners: Array[Vector2], jit := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for c in corners:
		pts.append(c)
	return _dense(pts, jit)


func _fig(pts: PackedVector2Array) -> StringName:
	if shape == null:
		return &"?"
	return shape.call("classify", pts)


static func _len(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in range(1, pts.size()):
		s += pts[i].distance_to(pts[i - 1])
	return s


# ── 1. Корпус ────────────────────────────────────────────────────────────────

func _test_corpus() -> void:
	print("— корпус штрихов")
	_rng.seed = 1002
	var o := Vector2(500, 380)
	var tris := {
		"ровный r60 с вершины": _shape(_ngon(o, 3, 60, -PI * 0.5)),
		"против часовой": _shape(_ngon(o, 3, 70, -PI * 0.5, -1.0)),
		"повёрнутый на 40°": _shape(_ngon(o, 3, 75, 0.7)),
		"вершиной вниз, с середины ребра": _shape(_ngon(o, 3, 70, PI * 0.5), 0.5),
		"рукой: дрожь 1,5 px": _shape(_ngon(o, 3, 72, -1.3), 0.2, 0.0, 0, 1.5),
		"рукой: дрожь 2 px": _shape(_ngon(o, 3, 80, 2.0), 0.0, 0.0, 0, 2.0),
		"рукой: скруглённые вершины": _shape(_ngon(o, 3, 75, -PI * 0.5), 0.3, 0.0, 3, 1.5),
		"недотянутый конец 25 px": _shape(_ngon(o, 3, 70, -PI * 0.5), 0.0, 25.0, 0, 1.5),
		"перелёт конца 20 px": _shape(_ngon(o, 3, 70, -PI * 0.5), 0.0, -20.0, 0, 1.5),
		"малый (~260 px)": _shape(_ngon(o, 3, 50, -PI * 0.5), 0.0, 0.0, 0, 1.0),
		"крупный (~680 px)": _shape(_ngon(o, 3, 130, -PI * 0.5), 0.0, 0.0, 0, 2.0),
		"прямоугольный": _shape([o + Vector2(-70, 60), o + Vector2(70, 60), o + Vector2(-70, -60)],
			0.0, 0.0, 0, 1.5),
		"неровный (вершины вразброс)": _shape([o + Vector2(-80, 50), o + Vector2(70, 65),
			o + Vector2(-5, -75)], 0.6, 10.0, 1, 2.0),
		"по шаблону урока": _lesson_tpl("triangle", o, 60.0),
	}
	for name: String in tris:
		var f := _fig(tris[name])
		_check(f == &"triangle", "треугольник: %s → «%s» (%.0f px)" % [name, f, _len(tris[name])])
	var squares := {
		"ровный 100 с вершины": _shape(_rect(o, 100, 100)),
		"против часовой": _shape(_ngon(o, 4, 75, PI * 0.25, -1.0)),
		"повёрнутый на 25°": _shape(_rect(o, 110, 110, 0.44)),
		"ромб (на угол)": _shape(_ngon(o, 4, 80, -PI * 0.5), 0.5),
		"рукой: дрожь 1,5 px": _shape(_rect(o, 105, 100, 0.1), 0.3, 0.0, 0, 1.5),
		"рукой: дрожь 2 px": _shape(_rect(o, 120, 115, -0.2), 0.0, 0.0, 0, 2.0),
		"рукой: скруглённые вершины": _shape(_rect(o, 120, 120, 0.15), 0.4, 0.0, 3, 1.5),
		"недотянутый конец 25 px": _shape(_rect(o, 110, 110), 0.0, 25.0, 0, 1.5),
		"перелёт конца 20 px": _shape(_rect(o, 110, 110), 0.0, -20.0, 0, 1.5),
		"малый (~270 px)": _shape(_rect(o, 68, 68), 0.0, 0.0, 0, 1.0),
		"крупный (~680 px)": _shape(_rect(o, 170, 170, 0.3), 0.2, 0.0, 0, 2.0),
		"прямоугольник 3:2": _shape(_rect(o, 150, 100, 0.1), 0.0, 0.0, 0, 1.5),
		"кривой четырёхугольник": _shape([o + Vector2(-60, -55), o + Vector2(70, -45),
			o + Vector2(55, 65), o + Vector2(-50, 50)], 0.5, 12.0, 1, 2.0),
		"по шаблону урока": _lesson_tpl("square", o, 70.0),
	}
	for name: String in squares:
		var f := _fig(squares[name])
		_check(f == &"square", "квадрат: %s → «%s» (%.0f px)" % [name, f, _len(squares[name])])
	# D-1002: пятиугольник — «Комиссия», «D» (прямая + дуга) — «Неустойка», мелкий треугольник —
	# мини-треугольник; шестиугольник остаётся линией (н>5 не фигура)
	var d_shape := _open([o + Vector2(0, 70), o + Vector2(0, -70)])
	d_shape.append_array(_arc(o, 70, 70, -PI * 0.5, PI, 0.0, 1.0))
	var positives := {
		"пятиугольник r85": _shape(_ngon(o, 5, 85, -PI * 0.5), 0.0, 0.0, 0, 1.5),
		"пятиугольник рукой (дрожь 2 px)": _shape(_ngon(o, 5, 90, 0.7), 0.4, 8.0, 1, 2.0),
		"пятиугольник против часовой": _shape(_ngon(o, 5, 88, 1.1, -1.0), 0.0, 0.0, 0, 1.5),
		"полукруг «D»": d_shape,
		"малый треугольник (~180 px)": _shape(_ngon(o, 3, 35, -PI * 0.5)),
	}
	for name: String in positives:
		var want := &"d_shape" if name.begins_with("полукруг") else &"triangle" \
			if name.begins_with("малый") else &"pentagon"
		var f := _fig(positives[name])
		_check(f == want, "%s → «%s» (ждали «%s»)" % [name, f, want])
	var negatives := _negatives(o)
	for name: String in negatives:
		var f := _fig(negatives[name])
		_check(f != &"triangle" and f != &"square" and f != &"pentagon" and f != &"d_shape" \
			and f != &"?", "не угловая фигура: %s → «%s»" % [name, f])
	# круг и восьмёрка — по-прежнему свои фигуры
	_check(_fig(negatives["круг рукой"]) == &"ring", "круг рукой → «ring»")
	_check(_fig(negatives["овал 2:1 рукой"]) == &"ring", "овал 2:1 рукой → «ring»")
	_check(_fig(negatives["восьмёрка"]) == &"eight", "восьмёрка → «eight»")
	# B-069: квадрат и треугольник больше не «Оцепление»
	_check(shape != null and not bool(shape.call("is_ring", squares["ровный 100 с вершины"])),
		"квадрат — не кольцо (B-069)")
	_check(shape != null and not bool(shape.call("is_ring", tris["ровный r60 с вершины"])),
		"треугольник — не кольцо")


func _lesson_tpl(fig: String, c: Vector2, r: float) -> PackedVector2Array:
	return LegionLessonBot.template(fig, c, r)


func _negatives(o: Vector2) -> Dictionary:
	# лемниската Жероно, как «8 вертикальная» в legion_runes_test
	var eight := PackedVector2Array()
	for i in 105:
		var t := PI * 0.5 + TAU * i / 104.0
		eight.append(_jit(o + Vector2(45 * sin(t), 110 * sin(t) * cos(t)).rotated(PI * 0.5), 1.0))
	var star := PackedVector2Array()
	var tips := _ngon(o, 5, 70, -PI * 0.5)
	for k in 6:
		star.append(tips[posmod(2 * k, 5)])
	var zig: Array[Vector2] = []
	for i in 8:
		zig.append(o + Vector2(-200 + i * 50.0, 40.0 if i % 2 == 0 else -40.0))
	var closed_zig: Array[Vector2] = [o + Vector2(-60, -80), o + Vector2(60, -40),
		o + Vector2(-60, 0), o + Vector2(60, 40), o + Vector2(-60, 80), o + Vector2(-80, 0),
		o + Vector2(-62, -78)]
	var d_shape := _open([o + Vector2(0, 70), o + Vector2(0, -70)])
	d_shape.append_array(_arc(o, 70, 70, -PI * 0.5, PI, 0.0, 1.0))
	# сильно скруглённый квадрат (радиус угла 35 % стороны): скорее кольцо, чем ложный квадрат
	var squircle := PackedVector2Array()
	for i in 4:
		var cc: Vector2 = o + Vector2(1 if i in [0, 3] else -1, 1 if i < 2 else -1) * 42.0
		for k in 9:
			var a := PI * 0.5 * i + PI * 0.5 * k / 8.0
			squircle.append(_jit(cc + Vector2.from_angle(a) * 42.0, 1.0))
	squircle.append(squircle[0])
	squircle = _dense(squircle, 1.0)
	# ромб, скруглённый целиком (Чайкин по четырём вершинам, а не по плотной ломаной): на глаз
	# почти круг, касается середин сторон
	var dv := _ngon(o, 4, 95, -PI * 0.5)
	var coarse := PackedVector2Array([dv[0].lerp(dv[1], 0.5), dv[1], dv[2], dv[3], dv[0],
		dv[0].lerp(dv[1], 0.5)])
	for r in 5:
		coarse = _chaikin(coarse)
	var diamond_round := _dense(coarse, 1.0)
	var negs := {
		"круг рукой": _arc(o, 70, 66, 4.0, TAU + 0.1, 0.06, 1.5),
		"овал 2:1 рукой": _arc(o, 100, 50, 0.4, TAU + 0.05, 0.04, 1.5),
		"овал 3:1": _arc(o, 120, 40, 1.0, TAU),
		"восьмёрка": eight,
		"звезда (пентаграмма)": _dense(star, 1.0),
		"L": _open([o + Vector2(-60, -120), o + Vector2(-60, 60), o + Vector2(100, 60)], 1.5),
		"U": _open([o + Vector2(-60, -100), o + Vector2(-60, 60), o + Vector2(60, 60),
			o + Vector2(60, -100)], 1.5),
		"Z": _open([o + Vector2(-80, -70), o + Vector2(80, -70), o + Vector2(-80, 70),
			o + Vector2(80, 70)], 1.5),
		"V": _open([o + Vector2(-90, -100), o + Vector2(0, 80), o + Vector2(90, -100)], 1.5),
		"зигзаг": _open(zig, 1.0),
		"замкнутый зигзаг-«молния»": _open(closed_zig, 1.0),
		"сильно скруглённый квадрат": squircle,
		"ромб-«почти круг» (скруглён весь)": diamond_round,
		"вытянутый клин 300 × 40": _shape([o + Vector2(-150, 20), o + Vector2(150, 20),
			o + Vector2(0, -20)]),
		"шестиугольник": _shape(_ngon(o, 6, 80, 0.0), 0.0, 0.0, 0, 1.5),
		"«бабочка» (перекрещенный четырёхугольник)": _shape([o + Vector2(-70, -70),
			o + Vector2(70, 70), o + Vector2(70, -70), o + Vector2(-70, 70)]),
		"невыпуклый четырёхугольник («стрелка»)": _shape([o + Vector2(-80, 70),
			o + Vector2(0, -90), o + Vector2(80, 70), o + Vector2(0, 10)]),
		"треугольник с незамкнутым концом (60 px)": _shape(_ngon(o, 3, 70, -PI * 0.5), 0.0,
			60.0),
		# D-1002: «D», пятиугольник и малый (~180 px, bbox 60) треугольник — уже фигуры: их
		# проверяют положительные корпуса ниже (малый — мини-треугольник)
	}
	return negs


## Серии случайных фигур «рукой»: признаётся ≥ 90 %, перепутанных нет; круги и овалы —
## ни одного многоугольника; замкнутые каракули — единицы.
func _test_random() -> void:
	print("— случайные фигуры «рукой»")
	_rng.seed = 4243
	var o := Vector2(500, 380)
	var n := 60
	var hit_t := 0
	var hit_s := 0
	var mixed := 0
	for i in n:
		var t := _shape(_ngon(o, 3, _rng.randf_range(52, 120), _rng.randf_range(0, TAU),
			1.0 if _rng.randf() < 0.5 else -1.0), _rng.randf(), _rng.randf_range(-15, 25),
			_rng.randi_range(0, 2), _rng.randf_range(0, 2.0))
		var ft := _fig(t)
		hit_t += 1 if ft == &"triangle" else 0
		mixed += 1 if ft == &"square" else 0
		var wd := _rng.randf_range(65, 160)
		var sq := _shape(_rect(o, wd, wd * _rng.randf_range(0.75, 1.3), _rng.randf_range(0, PI)),
			_rng.randf(), _rng.randf_range(-15, 25), _rng.randi_range(0, 2),
			_rng.randf_range(0, 2.0))
		var fs := _fig(sq)
		hit_s += 1 if fs == &"square" else 0
		mixed += 1 if fs == &"triangle" else 0
	_check(hit_t >= n * 0.9, "случайные треугольники: признано %d из %d" % [hit_t, n])
	_check(hit_s >= n * 0.9, "случайные квадраты: признано %d из %d" % [hit_s, n])
	_check(mixed == 0, "треугольник и квадрат не перепутаны ни разу: %d" % mixed)
	var circ := 0
	for i in 100:
		var rx := _rng.randf_range(40, 100)
		var c := _arc(o, rx, rx * _rng.randf_range(0.5, 1.0), _rng.randf_range(0, TAU),
			(TAU + _rng.randf_range(-0.25, 0.15)) * (1.0 if _rng.randf() < 0.5 else -1.0),
			_rng.randf_range(0, 0.08), _rng.randf_range(0, 2.0))
		var f := _fig(c)
		circ += 1 if f == &"triangle" or f == &"square" else 0
	_check(circ == 0, "100 кругов и овалов рукой: многоугольников %d" % circ)
	var closed_hits := 0
	for i in 300:
		var pts := PackedVector2Array([o])
		var dir := Vector2.from_angle(_rng.randf_range(0, TAU))
		var turn := _rng.randf_range(-0.12, 0.12)
		for k in _rng.randi_range(40, 110):
			turn = clampf(turn + _rng.randf_range(-0.05, 0.05), -0.2, 0.2)
			dir = dir.rotated(turn)
			pts.append(pts[pts.size() - 1] + dir * 6.0)
		pts.append_array(_dense(PackedVector2Array([pts[pts.size() - 1], o])))
		var f := _fig(pts)
		closed_hits += 1 if f == &"triangle" or f == &"square" else 0
	_check(closed_hits <= 6, "300 каракуль, замкнутых прямым возвратом: многоугольников %d (≤ 6)"
		% closed_hits)


# ── 1а. Быстрая рука (verifier 02.10) ────────────────────────────────────────
# Игра кладёт точку на каждое событие движения мыши, а Godot копит движение до кадра: при 60 Гц
# и ~1000 px/с точки идут через 15–30 px, на фигуру бывает 8–12 точек. Генераторы — как в пробе
# verifier (C:/AI/necro/pvp/verify-figures/probe_steps.gd): путь фигуры, точки через случайный
# шаг 0,7…1,3 от заданного, дрожь 1,5 px, начало где угодно, недотяг/перелёт до 15 px.

func _sample(path: PackedVector2Array, smin: float, smax: float, j: float) -> PackedVector2Array:
	var out := PackedVector2Array([_jit(path[0], j)])
	var cum := PackedFloat32Array([0.0])
	for i in range(1, path.size()):
		cum.append(cum[i - 1] + path[i].distance_to(path[i - 1]))
	var total := cum[cum.size() - 1]
	var d := 0.0
	while true:
		d += _rng.randf_range(smin, smax)
		if d >= total:
			break
		var k := 1
		while k < path.size() - 1 and cum[k] < d:
			k += 1
		var seg := cum[k] - cum[k - 1]
		var t := 0.0 if seg <= 0.0 else (d - cum[k - 1]) / seg
		out.append(_jit(path[k - 1].lerp(path[k], t), j))
	out.append(_jit(path[path.size() - 1], j))
	return out


## Путь многоугольника (без уплотнения): вершины по кругу радиуса r, начало — доля start
## первого ребра, gap > 0 — недотяг, < 0 — перелёт.
func _poly_path(c: Vector2, n: int, r: float, rot: float, start: float,
		gap: float) -> PackedVector2Array:
	var v := _ngon(c, n, r, rot)
	var s0 := v[0].lerp(v[1], start)
	var path := PackedVector2Array([s0])
	for i in range(1, n + 1):
		path.append(v[i % n])
	path.append(s0)
	var last := path[path.size() - 1]
	if gap > 0.0:
		path[path.size() - 1] = last + (path[path.size() - 2] - last).normalized() * gap
	elif gap < 0.0:
		path.append(last + (v[1] - last).normalized() * -gap)
	return path


func _test_fast() -> void:
	print("— быстрая рука: редкие точки")
	_rng.seed = 12345
	var o := Vector2(640, 360)
	var per := 40
	for step: float in [14.0, 18.0, 26.0, 30.0]:
		var got := {"sq": 0, "sq_ring": 0, "tri": 0, "tri_ring": 0, "mixed": 0, "circ": 0,
			"circ_poly": 0, "eight": 0, "eight_poly": 0, "neg": 0}
		var n := 0
		for r: float in [70.0, 100.0, 130.0]:
			for i in per:
				n += 1
				var sq := _fig(_sample(_poly_path(o, 4, r, _rng.randf() * TAU, _rng.randf(),
					_rng.randf_range(-15, 15)), step * 0.7, step * 1.3, 1.5))
				got["sq"] += 1 if sq == &"square" else 0
				got["sq_ring"] += 1 if sq == &"ring" else 0
				got["mixed"] += 1 if sq == &"triangle" else 0
				var tr := _fig(_sample(_poly_path(o, 3, r, _rng.randf() * TAU, _rng.randf(),
					_rng.randf_range(-15, 15)), step * 0.7, step * 1.3, 1.5))
				got["tri"] += 1 if tr == &"triangle" else 0
				got["tri_ring"] += 1 if tr == &"ring" else 0
				got["mixed"] += 1 if tr == &"square" else 0
				var circ := _fig(_sample(_arc(o, r, r, _rng.randf() * TAU,
					TAU * _rng.randf_range(0.97, 1.03), _rng.randf_range(0, 0.08)), step * 0.7,
					step * 1.3, 1.5))
				got["circ"] += 1 if circ == &"ring" else 0
				got["circ_poly"] += 1 if circ == &"triangle" or circ == &"square" else 0
				var e8 := PackedVector2Array()
				var rot := _rng.randf() * TAU
				for k in 121:
					var t := PI * 0.5 + TAU * k / 120.0
					e8.append(o + Vector2(r * 0.45 * sin(t), r * 1.1 * sin(t) * cos(t)).rotated(rot))
				var f8 := _fig(_sample(e8, step * 0.7, step * 1.3, 1.5))
				got["eight"] += 1 if f8 == &"eight" else 0
				got["eight_poly"] += 1 if f8 == &"triangle" or f8 == &"square" else 0
				# отрицательные: прямая, L, U, зигзаг на том же шаге
				var a := o + Vector2(_rng.randf_range(-200, 0), _rng.randf_range(-100, 100))
				var d := Vector2.from_angle(_rng.randf() * TAU)
				var nrm := d.orthogonal()
				var zz := PackedVector2Array()
				for k in 8:
					zz.append(a + d * (k * 50.0) + nrm * (40.0 if k % 2 == 0 else -40.0))
				for neg: PackedVector2Array in [PackedVector2Array([a, a + d * 400.0]),
						PackedVector2Array([a, a + d * 220.0, a + d * 220.0 + nrm * 200.0]),
						PackedVector2Array([a, a + d * 200.0, a + d * 200.0 + nrm * 80.0,
							a + nrm * 80.0]), zz]:
					got["neg"] += 1 if _fig(_sample(neg, step * 0.7, step * 1.3, 1.5)) != &"" else 0
		print("  шаг %d px: %s (из %d на фигуру)" % [step, str(got), n])
		_check(got["sq"] >= n * 0.9 and got["sq_ring"] <= n * 0.08,
			"шаг %d: квадрат признан %d/%d, кольцом %d" % [step, got["sq"], n, got["sq_ring"]])
		_check(got["tri"] >= n * 0.95 and got["tri_ring"] <= n * 0.03,
			"шаг %d: треугольник признан %d/%d, кольцом %d" % [step, got["tri"], n,
			got["tri_ring"]])
		_check(got["mixed"] == 0, "шаг %d: треугольник и квадрат не перепутаны" % step)
		_check(got["circ"] == n and got["circ_poly"] == 0,
			"шаг %d: круги — кольца %d/%d, многоугольников %d" % [step, got["circ"], n,
			got["circ_poly"]])
		_check(got["eight_poly"] == 0, "шаг %d: восьмёрка не стала многоугольником (восьмёрок %d/%d)"
			% [step, got["eight"], n])
		_check(got["neg"] == 0, "шаг %d: прямые, L, U, зигзаги — ни одной фигуры (%d)"
			% [step, got["neg"]])
	# 8–12 точек на всю фигуру: многоугольник честно неотличим от круга из стольких точек —
	# пропуск допустим, ложный квадрат из круга — нет
	var sq_hit := 0
	var tri_hit := 0
	var circ_poly := 0
	var circ_ring := 0
	var m := 200
	for i in m:
		var cnt := _rng.randi_range(8, 12)
		var r := _rng.randf_range(60, 130)
		var sp := _poly_path(o, 4, r, _rng.randf() * TAU, _rng.randf(), _rng.randf_range(-15, 15))
		var st := _len(sp) / cnt
		sq_hit += 1 if _fig(_sample(sp, st * 0.8, st * 1.2, 1.5)) == &"square" else 0
		var tp := _poly_path(o, 3, r, _rng.randf() * TAU, _rng.randf(), _rng.randf_range(-15, 15))
		st = _len(tp) / cnt
		tri_hit += 1 if _fig(_sample(tp, st * 0.8, st * 1.2, 1.5)) == &"triangle" else 0
		var cp := _arc(o, r, r, _rng.randf() * TAU, TAU * _rng.randf_range(0.97, 1.03),
			_rng.randf_range(0, 0.08))
		st = _len(cp) / cnt
		var fc := _fig(_sample(cp, st * 0.8, st * 1.2, 1.5))
		circ_poly += 1 if fc == &"triangle" or fc == &"square" else 0
		circ_ring += 1 if fc == &"ring" else 0
	_check(sq_hit >= m * 0.7 and tri_hit >= m * 0.95,
		"8–12 точек: квадрат %d/%d, треугольник %d/%d" % [sq_hit, m, tri_hit, m])
	_check(circ_ring >= m - 2 and circ_poly <= 1,
		"8–12 точек: круг — кольцо %d/%d, многоугольником %d (≤ 1)" % [circ_ring, m, circ_poly])
	# круг с рывками мыши (1–4 точки отскочили наружу на 8–20 px) — кольцо, как на базе bbd8ed0c
	var spiky := 0
	for i in 150:
		var r := _rng.randf_range(50, 130)
		var cp := _arc(o, r, r * _rng.randf_range(0.6, 1.0), _rng.randf() * TAU,
			TAU * _rng.randf_range(0.97, 1.03), _rng.randf_range(0, 0.1))
		var pts := _sample(cp, 5, 9, 2.0)
		for k in _rng.randi_range(1, 4):
			var idx := _rng.randi_range(2, pts.size() - 3)
			pts[idx] = pts[idx] + (pts[idx] - o).normalized() * _rng.randf_range(8, 20)
		spiky += 1 if _fig(pts) == &"ring" else 0
	_check(spiky == 150, "круг с рывками 8–20 px — кольцо: %d/150" % spiky)


# ── Мир ──────────────────────────────────────────────────────────────────────

func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


func _last() -> Contract:
	var cs := w.contracts.contracts
	return cs[cs.size() - 1] if not cs.is_empty() else null


func _fig_of(c: Contract) -> StringName:
	if c == null:
		return &""
	var v: Variant = c.get("figure")
	return v if v is StringName else &""


## Договор-фигура в обход мыши; на старом коде (нет такой фигуры) — null.
func _make_fig(fig: StringName, pts: PackedVector2Array) -> Contract:
	var n := w.contracts.contracts.size()
	w.contracts.call("_create", pts, 1, LegionCfg.KIND_LABORER, false, fig)
	var c := _last() if w.contracts.contracts.size() > n else null
	return c if _fig_of(c) == fig else null


func _tri() -> Contract:
	_rng.seed = 31
	return _make_fig(&"triangle", _shape(_ngon(FC, 3, 80, -PI * 0.5 + 0.1), 0.2, 0.0, 0, 1.5))


func _sq() -> Contract:
	_rng.seed = 41
	return _make_fig(&"square", _shape(_rect(FC, 120, 120, 0.1), 0.3, 0.0, 0, 1.5))


func _man(c: Contract, frac := 1.0) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if p["unit"] != null or p["dead"]:
			continue
		if float(out.size()) >= frac * c.posts.size():
			break
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _still_foe(at: Vector2, hp := 100000.0) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + Vector2(0, 400)]), at)
	f.speed = 0.0
	f.hp = hp
	f.max_hp = hp
	return f


func _cfg(key: String, fallback: Variant) -> Variant:
	return fcfg.get_script_constant_map().get(key, fallback) if fcfg != null else fallback


func _live(c: Contract) -> int:
	var n := 0
	for s in c.seg_count():
		if c.seg_alive(s):
			n += 1
	return n


func _melt_all(c: Contract) -> void:
	for s in c.seg_count():
		if c.seg_alive(s):
			c.seg_age[s] = c.ttl - 0.01
	w.contracts.tick(0.05, w.now)


func _steps(sec: float) -> void:
	for i in roundi(sec / DT):
		w._step(DT)


func _rites() -> int:
	return int(w.stats.get("rites", 0))


# ── 2. «Обряд» треугольника ──────────────────────────────────────────────────

## Заряд фигуры: держать порог порог не меньше FigureCfg.CHARGE_TIME боя.
static func _charge_secs() -> float:
	return float(FigureCfg.CHARGE_TIME)


func _test_charge() -> void:
	print("— подготовка фигуры (заряд)")
	_fresh()
	var c := _tri()
	if c == null:
		_check(false, "договор-треугольник собран")
		return
	_check(c.posts.size() == 3 and c.corners_only, "треугольник: 3 места на углах")
	_check(c.charge_need() == 2, "заряд с двух мест (2/3): %d" % c.charge_need())
	_man(c, 0.66)
	_steps(_charge_secs() * 0.5)
	_check(not c.charge_ready() and c.charge_t > 0.0,
		"половина подготовки заряда — ульты нет (%.2f с)" % c.charge_t)
	_steps(_charge_secs())
	_check(c.charge_ready(), "полный срок непрерывного строя — заряд готов")
	# недобор сбрасывает подготовку
	var u: Legionnaire = c.posts[0]["unit"]
	u.take_damage(99999.0, u.position + Vector2(5, 0))
	_steps(0.1)
	_check(not c.charge_ready() and c.charge_t == 0.0,
		"потеря участника сбрасывает заряд (осталось %d из %d)" % [c.posted_posts(), c.charge_need()])
	# ранний выпуск — обычный натиск без ульты
	_fresh()
	c = _tri()
	if c == null:
		return
	_man(c, 0.66)
	_steps(0.2)
	w.contracts.release(c, 0)
	_check(_rites() == 0, "ранний выпуск (заряд %.2f с) — без обряда" % c.charge_t)
	_check(_live(c) == 0, "фигура всё равно сорвана")


func _test_rite() -> void:
	print("— «Обряд» треугольника")
	var fill := float(_cfg("RITE_FILL", 0.7))
	_check(absf(fill - 2.0 / 3.0) < 0.01, "порог заряда — двое из трёх: RITE_FILL = %.2f" % fill)
	# самотаяние заряженного строя
	_fresh()
	var c := _tri()
	_check(c != null, "договор-треугольник собран")
	if c == null:
		return
	var tips: PackedVector2Array = c.get("tips")
	_check(tips.size() == 3 and c.center.distance_to(FC) < 15.0,
		"3 вершины, центр у центра фигуры: %s" % c.center)
	var squad := _man(c, 0.66)
	var tough := _still_foe(c.center + Vector2(12, 4))
	var weak := _still_foe(c.center + Vector2(-20, 10), 20.0)
	var corpse := _still_foe(c.center + Vector2(0, -20), 5.0)
	corpse.take_damage(50.0, corpse.position)
	var outside := _still_foe(c.center + Vector2(300, 0))
	_steps(_charge_secs() + 0.1)
	var vassals0: int = w.hero.vassal_count()
	var hp0 := tough.hp
	_melt_all(c)
	_check(_rites() == 1, "самотаяние заряженного строя (%d из %d) — обряд"
		% [squad.size(), c.posts.size()])
	_check(hp0 - tough.hp >= float(_cfg("RITE_DMG", 45.0)) - 0.01 and tough.is_stunned(),
		"удар в центре: урон %.0f и оглушение" % (hp0 - tough.hp))
	_check(not weak.alive and w.hero.vassal_count() - vassals0 >= 1,
		"слабый погиб, свежие трупы встали внештатниками: +%d"
		% (w.hero.vassal_count() - vassals0))
	_check(outside.hp == outside.max_hp, "вне удара не задет")
	var reach := 0.0
	for t in tips:
		reach += t.distance_to(c.center)
	var want_r := maxf(float(_cfg("RITE_R_MIN", 90.0)),
		reach / 3.0 * float(_cfg("RITE_R_FRAC", 1.15)))
	var lr: Dictionary = w.figures.last_rite
	_check(absf(float(lr.get("r", -1.0)) - want_r) < 0.5,
		"радиус удара — от размера треугольника: %.0f (ждали %.0f)" % [float(lr.get("r", -1.0)),
		want_r])
	var buffed := not squad.is_empty()
	var inward := true
	for u in squad:
		buffed = buffed and float(u.get("rite_dmg_mult")) > 1.0
		inward = inward and u.state == Legionnaire.State.CHARGE \
			and u._charge_dir.dot((c.center - u.position).normalized()) > 0.95
	_check(buffed and inward, "участники усилены и бегут к центру")
	# ПКМ (щелчок), рогатка и Таб — тоже обряд, но только у ЗАРЯЖЕННОГО строя
	for how: String in ["ПКМ", "рогатка", "Таб"]:
		_fresh()
		c = _tri()
		if c == null:
			_check(false, "договор-треугольник собран (%s)" % how)
			continue
		_man(c, 0.66)
		_steps(_charge_secs() + 0.1)
		match how:
			"ПКМ":
				w.contracts.release(c, 1)
			"рогатка":
				w.contracts.release_aimed(c, 1, Vector2.UP, 0.8, false)
			"Таб":
				w.contracts.erase(c, 1)
		_check(_live(c) == 0 and _rites() == 1, "%s по заряженному треугольнику — обряд (обрядов %d)"
			% [how, _rites()])
	# потеря ОДНОГО бойца порог заряда не рвёт (2 из 3 ещё стоят)
	_fresh()
	c = _tri()
	if c == null:
		return
	squad = _man(c, 1.0)
	_steps(0.05)
	squad[1].take_damage(99999.0, squad[1].position + Vector2(5, 0))
	_steps(DT * 2.0)
	_check(_live(c) == c.seg_count(), "гибель бойца строя треугольник не рвёт")
	_steps(_charge_secs() + 0.1)
	_check(c.charge_ready(), "двое из трёх держат заряд после потери третьего")
	_melt_all(c)
	_check(_rites() == 1 and int(w.stats.get("rites_broken", 0)) == 0,
		"после потери — обряд всё равно (обрядов %d)" % _rites())
	# недобор
	_fresh()
	c = _tri()
	if c == null:
		return
	_man(c, 0.3)
	_steps(_charge_secs() + 0.2)
	_melt_all(c)
	_check(_live(c) == 0 and _rites() == 0, "занят один угол из трёх — заряда нет, обряда нет")
	_fresh()
	c = _tri()
	if c != null:
		_man(c, 0.3)
		_steps(_charge_secs() + 0.2)
		w.contracts.release(c, 0)
		_check(_rites() == 0, "ПКМ при одном занятом угле — без обряда")


# ── 3. «Каре» ────────────────────────────────────────────────────────────────

## Урон, полученный бойцом на месте p договора c от удара со спины (броня строя не в счёт).
func _hurt(c: Contract) -> float:
	var p: Dictionary = c.posts[0]
	var u := w.spawn_unit(c.kind, p["pos"])
	u.assign(c, p)
	u._arrive()
	u.hp = 1000.0
	u.max_hp = 1000.0
	var n: Vector2 = p["normal"]
	u.take_damage(10.0, u.position - n * 20.0)
	return 1000.0 - u.hp


func _bend_max(c: Contract) -> float:
	var b := 0.0
	for s in c.seg_count():
		b = maxf(b, c.seg_bend[s])
	return b


## Толпа неподвижных крепких врагов вплотную к участку 0 снаружи, лицом к нему (давят только
## идущие на участок — LegionGrid.press_scan); шагов sec секунд.
func _press(c: Contract, sec: float) -> void:
	_man(c)
	var at := c.seg_center(0)
	var out: Vector2 = (at - c.center) if c.shaped() else c.dir
	out = out.normalized()
	for i in 14:
		var pos := at + out * (22.0 + 12.0 * (i / 5)) + out.orthogonal() * (-24.0 + 12.0 * (i % 5))
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([pos, pos - out * 400.0]), pos)
		f.speed = 0.0
		f.hp = 1e9
		f.max_hp = 1e9
	for u in w.units:
		u.hp = 1e9
		u.max_hp = 1e9
	_steps(sec)


func _test_square() -> void:
	print("— «Каре» квадрата")
	_fresh()
	var line := w.contracts.add_contract(_open([Vector2(1060, 300), Vector2(1060, 520)]), 1,
		false)
	var base := _hurt(line)
	_fresh()
	var c := _sq()
	_check(c != null, "договор-квадрат собран")
	if c == null:
		return
	var tips: PackedVector2Array = c.get("tips")
	_check(tips.size() == 4, "4 вершины")
	var got := _hurt(c)
	var mult := float(_cfg("SQUARE_DMG_MULT", 1.0))
	_check(base > 0.0 and absf(got / base - mult) < 0.01 and mult <= 0.7,
		"боец каре получает меньше урона: %.1f против %.1f у линии (×%.2f)" % [got, base,
		got / maxf(base, 0.001)])
	_fresh()
	line = w.contracts.add_contract(_open([Vector2(1060, 300), Vector2(1060, 520)]), 1, false)
	var ttl_line := line.ttl
	c = _sq()
	if c == null:
		return
	_check(absf(c.ttl - ttl_line * float(_cfg("SQUARE_TTL_MULT", 1.0))) < 0.01 and c.ttl > ttl_line,
		"квадрат тает дольше: срок %.1f с против %.1f у линии" % [c.ttl, ttl_line])
	var out_ok := true
	for p in c.posts:
		var at: Vector2 = (p["pos"] as Vector2) - (p["offset"] as Vector2)
		out_ok = out_ok and (p["normal"] as Vector2).dot((at - c.center).normalized()) > 0.99
	_check(out_ok, "строй каре смотрит наружу (%d мест)" % c.posts.size())
	# давка: та же толпа прогибает линию, а каре — нет
	_fresh()
	line = w.contracts.add_contract(_open([Vector2(1060, 300), Vector2(1060, 520)]), 1, false)
	_press(line, 2.0)
	var line_bend := _bend_max(line)
	var line_breaks := int(w.stats.get("press_breaks", 0))
	_check(line_bend > 0.0 or line_breaks > 0, "толпа давит линию: прогиб %.1f, прорывов %d"
		% [line_bend, line_breaks])
	_fresh()
	c = _sq()
	if c == null:
		return
	_press(c, 2.0)
	_check(_bend_max(c) == 0.0 and int(w.stats.get("press_breaks", 0)) == 0,
		"та же толпа каре не прогибает и не прорывает: прогиб %.1f, прорывов %d"
		% [_bend_max(c), int(w.stats.get("press_breaks", 0))])
	# «Каре» — не «Обряд»: срыв без удара в центре
	_fresh()
	c = _sq()
	if c == null:
		return
	_man(c)
	_melt_all(c)
	_check(_live(c) == 0 and _rites() == 0, "квадрат растаял — без обряда")
	# заряженный выпуск каре: участники держат защиту (входящий урон ×SQUARE_GUARD_MULT)
	_fresh()
	c = _sq()
	if c == null:
		return
	_check(c.posts.size() == 4 and c.corners_only and c.charge_need() == 3,
		"каре: 4 угла, заряд с трёх")
	var sq := _man(c, 1.0)
	_steps(_charge_secs() + 0.1)
	_check(c.charge_ready(), "каре заряжено")
	w.contracts.release(c, 0)
	var guarded := true
	for u in sq:
		guarded = guarded and u.alive and float(u.get("guard_dmg_mult")) < 1.0
	_check(guarded and int(w.stats.get("guards", 0)) == 1,
		"заряженный срыв каре даёт защиту участникам (%d)" % int(w.stats.get("guards", 0)))


# ── 3а. Советы поля ──────────────────────────────────────────────────────────

func _hints(type: StringName) -> int:
	var o: Object = w.get("intuit")
	return int(o.call("hints_shown", type)) if o != null else -1


func _test_hints() -> void:
	print("— советы фигур")
	Settings.hints_override = "on"
	_fresh()
	var c := _tri()
	if c == null:
		_check(false, "договор-треугольник собран")
		return
	_man(c, 0.3)
	w.intuit.scan()
	_check(_hints(&"rite") == 0, "треугольник недобран — совета «Обряд» нет")
	_man(c, 0.66)
	w.intuit.scan()
	_check(_hints(&"rite") == 0, "двое из трёх, но без заряда — совета «Обряд» нет")
	_steps(_charge_secs() + 0.1)
	w.intuit.scan()
	_check(_hints(&"rite") == 1, "набрано и заряжено — совет «сорви: «Обряд!»» (%d)"
		% _hints(&"rite"))
	_fresh()
	var line := w.contracts.add_contract(_open([Vector2(1060, 300), Vector2(1060, 520)]), 1,
		false)
	_man(line)
	line.seg_bend[1] = LegionCfg.PRESS_BREAK * 0.9
	# на поле один совет за раз: «Е», «пружина» и «Каре» по очереди — каждый погас (HINT_SHOW) и
	# ушёл на откат, освобождая место следующему
	for i in 4:
		w.intuit.scan()
		w.now += 3.0
	_check(_hints(&"square") == 1, "линию продавливают — совет «Каре» (%d)" % _hints(&"square"))
	_sq()
	w.intuit.scan()
	_check(w.intuit.is_done(&"square"), "квадрат начерчен — совет «Каре» больше не нужен")
	Settings.hints_override = ""


## Перелёт конца за начало срезается и мест не даёт — его мана возвращается (D-1002-08).
func _test_overshoot_refund() -> void:
	print("— перелёт конца: мана за срезанный хвост возвращается")
	_fresh()
	var v := _ngon(FC, 3, 80, -PI * 0.5)
	var pts := _dense(PackedVector2Array([v[0], v[1], v[2], v[0], v[0].lerp(v[1], 0.25)]))
	var before := float(w.stats["mana_spent"])
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	w.contracts.begin(pts[0])
	for i in range(1, pts.size()):
		w.contracts.extend(pts[i])
	w.contracts.finish()
	var c := _last()
	_check(_fig_of(c) == &"triangle", "треугольник с перелётом ~35 px — треугольник")
	if c == null:
		return
	var spent := float(w.stats["mana_spent"]) - before
	var want := c.length * LegionCfg.MANA_PER_PX
	_check(absf(spent - want) < 0.6, "потрачено %.1f — по длине договора %.0f px (%.1f), без хвоста"
		% [spent, c.length, want])


# ── 4. Звезды нет; открытия ──────────────────────────────────────────────────

func _test_star_gone() -> void:
	print("— звезды больше нет")
	var consts: Dictionary = shape.get_script_constant_map() if shape != null else {}
	_check(not consts.has("STAR") and consts.has("TRIANGLE") and consts.has("SQUARE"),
		"ContractShape: STAR нет, TRIANGLE и SQUARE есть")
	_rng.seed = 7
	var tips := _ngon(Vector2(500, 380), 5, 70, -PI * 0.5)
	var star := PackedVector2Array()
	for k in 6:
		star.append(tips[posmod(2 * k, 5)])
	_check(_fig(_dense(star, 1.0)) == &"", "пентаграмма — обычная линия")
	var fc: Dictionary = fcfg.get_script_constant_map() if fcfg != null else {}
	_check(not fc.has("STAR_LABEL") and String(fc.get("TRI_LABEL", "")) == "Обряд"
		and String(fc.get("SQUARE_LABEL", "")) == "Каре", "подписи: «Обряд» и «Каре»")


func _test_unlocks() -> void:
	print("— открытия кампании")
	Campaign.reset()
	var upto_maze := ["gatehouse", "fork", "archive", "bridge", "maze"]
	Campaign._file().set_value("progress", "unlocked", upto_maze)
	Campaign._mods_cache_valid = false
	# D-1002: «Лабиринт» открывает ещё и «Комиссию» (пятиугольник) своим уроком
	_check(Campaign.stat(&"shape_unlocked_triangle") > 0.5
		and Campaign.stat(&"shape_unlocked_pentagon") > 0.5
		and Campaign.stat(&"shape_unlocked_square") < 0.5
		and Campaign.stat(&"shape_unlocked_star") < 0.5,
		"«Лабиринт» открыт — треугольник и комиссия есть, квадрата и звезды нет")
	# старое сохранение: звезду игроку уже показывали
	Campaign._file().set_value("meta", "unlocks_seen",
		["kind_guard", "aim", "rally", "ring", "hero_w", "hero_e", "eight", "kind_clerk", "items",
		"star"])
	var labels := Campaign.pending_unlock_labels()
	_check(labels.size() == 2 and labels[0].contains("треугольник")
		and labels[1].contains("пятиугольник"),
		"старый ключ «star» не мешает: новое — %s" % str(labels))
	Campaign.mark_unlocks_seen()
	_check(Campaign.pending_unlock_labels().is_empty(), "отмечено показанным")
	Campaign._file().set_value("progress", "unlocked", upto_maze + ["swamp"])
	Campaign._mods_cache_valid = false
	_check(Campaign.stat(&"shape_unlocked_square") > 0.5
		and Campaign.stat(&"shape_unlocked_d_shape") > 0.5,
		"«Болото» открыто — квадрат и неустойка есть")
	_check(Campaign.pending_unlock_labels() == ["Фигура «Каре»: квадрат",
			"Фигура «Неустойка»: полукруг"],
		"новое: %s" % str(Campaign.pending_unlock_labels()))
	Campaign.reset()


# ── 5. Уроки ─────────────────────────────────────────────────────────────────

func _lesson(map_id: String, id: String) -> Dictionary:
	for l: Dictionary in LegionWorld.load_map(map_id).get("lessons", []):
		if String(l.get("id", "")) == id:
			return l
	return {}


func _test_lessons() -> void:
	print("— уроки фигур")
	var tri := _lesson("bridge", "triangle")
	var sq := _lesson("swamp", "square")
	# D-1002: урок фигуры кончается ДЕЙСТВИЕМ — срывом заряженной фигуры, а не контуром
	_check(String(tri.get("done", "")) == "figure_ult:triangle"
		and String(tri.get("voice", "")) == "lg_tut_triangle",
		"«Мост»: урок треугольника кончается заряженным срывом")
	_check(String(sq.get("done", "")) == "figure_ult:square"
		and String(sq.get("voice", "")) == "lg_tut_square",
		"«Болото»: урок квадрата кончается заряженным срывом")
	for vid: String in ["lg_tut_triangle", "lg_tut_square"]:
		var vs := load("res://assets/legion/voice/%s.ogg" % vid) as AudioStream
		_check(vs != null and vs.get_length() > 3.0,
			"%s.ogg грузится и звучит (%.2f с)" % [vid, vs.get_length() if vs else 0.0])
	_check(_lesson("maze", "star").is_empty(), "урока звезды нет")
	# настоящий бой «Лабиринта»: стартовая армия, штрих по шаблону урока (как бот уроков)
	Campaign.reset()
	Campaign.unlock_all()
	Settings.scheme_override = ""
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.start_map("bridge")
	w.start_lessons(true)
	var tut := w.tutorial
	_check(tut != null and tut.step_id() == &"triangle", "«Мост»: первый урок — треугольник")
	if tut == null or tut.step_id() != &"triangle":
		return
	LegionLessonBot.act(tut)
	var c := _last()
	_check(_fig_of(c) == &"triangle", "штрих по шаблону урока — договор-треугольник")
	if _fig_of(c) != &"triangle":
		return
	var best := 0.0
	var t := 0.0
	while t < c.ttl + 1.0 and _rites() == 0:
		w._step(DT)
		t += DT
		if c.alive():
			best = maxf(best, c.fill())
	# зачёт урока приходит сигналом на том же шаге, что и ульта: движку нужен ещё кадр
	for i in 5:
		w._step(DT)
	_check(tut.passed(&"triangle"), "урок треугольника засчитан")
	_check(best >= float(_cfg("RITE_FILL", 0.7)),
		"строй набран стартовой армией: %.0f %% из %d мест (армия %d)" % [best * 100.0,
		c.posts.size(), w.units.size()])
	_check(_rites() == 1, "обряд сработал на таянии (через %.1f с)" % t)
	Campaign.reset()
	w.in_campaign = false
