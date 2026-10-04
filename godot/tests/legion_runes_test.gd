extends SceneTree
##
## Фигура договора «Двойная смена» (восьмёрка) — просьба Игоря 26.09:
## «рисунков мышкой надо больше, ещё хотя бы восьмёрку и звёздочку… чтобы юниты, которые
## выстроились в эту фигуру, что-то особенное начинали делать».
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_runes_test.gd -- --mute
##
## Звезда «Обряд» (26.09) снята D-1002-03 (02.10): её место занял треугольник, добавлен квадрат —
## их корпус и механика в tests/legion_figures_test.gd. Здесь звезда — только в отрицательных:
## пентаграмма больше не фигура.
## 1) корпус штрихов: неровные восьмёрки мышью признаются; прямая, L, дуга вдоль дороги, U,
##    зигзаг, кольцо, спираль, двойной виток, пятиугольник, «петля в петле», звезда — не
##    восьмёрка; кольцо ≠ восьмёрка; окна вдоль дорог всех карт со смещением ±25 px — ни одной
##    фигуры (в том числе треугольника и квадрата);
## 2) восьмёрка НАСТОЯЩИМИ событиями мыши: подпись черновика до отпускания, договор-фигура
##    после; треугольник мышью — подпись «Обряд» и договор; линия длиннее LINE_MAX обрезается,
##    хвост возвращается маной;
## 3) восьмёрка: темп удара в строю ×1,5; выпуск крест-накрест; «Сверхурочные» — только при
##    самотаянии и наборе;
## 4) подновление фигуры — по длине всей фигуры;
## 5) бот фигур не чертит — его бой побайтно тот же, что до фигур (трасса на 3 сидах сверяется
##    с эталоном economy-mana: tests/data/legion_runes_bot_ref.txt; происхождение — docs/dev/CODEX_MANA.md).
## Новый API берётся через get()/call(): на старом коде тест не падает разбором, а честно
## проваливает проверки. Итог «LEGION RUNES: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_runes_test.cfg"
const SHAPE_PATH := "res://scripts/legion/contract_shape.gd"
const MAPS := ["_gray", "bridge", "fork", "maze", "swamp", "wasteland", "boss"]
const DEVICE := 7
const FIG_CFG_PATH := "res://scripts/legion/figure_cfg.gd"
const BOT_REF := "res://tests/data/legion_runes_bot_ref.txt"
## Бот: карта, сид, шагов по 1/60 с. Эталон снят на коде ДО фигур (486b977).
const BOT_RUNS := [["bridge", 1, 4800], ["fork", 2, 4800], ["wasteland", 3, 4800]]
## Свободное поле карты _gray: восточнее скалы (x ≤ 1000), между северной и южной дорогами.
const FC := Vector2(1130.0, 405.0)

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
	# бот — первым, пока мир ещё ни разу не видел фигур: порядок прогона тот же, что у эталона
	_test_bot_same()
	_test_corpus()
	_random_figures()
	_test_roads()
	await _test_draw_eight()
	await _test_draw_triangle()
	await _test_long_line()
	_test_eight_tempo()
	await _test_eight_cross()
	_test_eight_overtime()
	await _test_refresh_overshoot()
	_test_figure_refresh_price()
	_test_s_return()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION RUNES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Генераторы штрихов «рукой» ───────────────────────────────────────────────

func _jit(p: Vector2, j: float) -> Vector2:
	return p + Vector2(_rng.randf_range(-j, j), _rng.randf_range(-j, j))


## Уплотнить ломаную до шага ~6 px (шаг штриха мыши POINT_STEP).
func _dense(pts: PackedVector2Array, jit := 0.0) -> PackedVector2Array:
	var out := PackedVector2Array([_jit(pts[0], jit)])
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, ceili(a.distance_to(b) / 6.0))
		for k in range(1, n + 1):
			out.append(_jit(a.lerp(b, float(k) / n), jit))
	return out


func _poly(corners: Array[Vector2]) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for c in corners:
		pts.append(c)
	return _dense(pts)


func _arc(c: Vector2, rx: float, ry: float, a0: float, sweep: float, wob := 0.0,
		jit := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(8, ceili(absf(sweep) * maxf(rx, ry) / 6.0))
	for i in n + 1:
		var a := a0 + sweep * float(i) / n
		var k := 1.0 + wob * sin(a * 3.0 + 0.7)
		pts.append(_jit(c + Vector2(cos(a) * rx * k, sin(a) * ry * k), jit))
	return pts


## Восьмёрка (лемниската Жероно): a — полуширина, b — полувысота петли, rot — поворот,
## t0 — откуда начат штрих (0 — с перетяжки, PI/2 — с края петли), k2 — масштаб второй петли,
## dir — ±1 направление обхода, wob/jit — «рука».
func _eight(c: Vector2, a: float, b: float, rot := 0.0, t0 := PI * 0.5, k2 := 1.0,
		dir := 1.0, wob := 0.0, jit := 0.0, span := TAU) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := ceili((a + b) * 4.0 / 6.0)
	for i in n + 1:
		var t := t0 + dir * span * float(i) / n
		var s := sin(t)
		var k := k2 if s < 0.0 else 1.0
		var p := Vector2(a * s * k, b * s * cos(t) * k) * (1.0 + wob * sin(t * 3.0 + 1.1))
		pts.append(_jit(c + p.rotated(rot), jit))
	return pts


## Пентаграмма одним штрихом: R — радиус вершин, rot — поворот, start — с какой вершины
## начат (дробное — с середины ребра), vj — разброс вершин (доля R), round — скругление
## вершин (Чайкин), dir — ±1 обход, jit — дрожь точек.
func _star(c: Vector2, r: float, rot := -PI * 0.5, start := 0.0, vj := 0.0, round_n := 0,
		dir := 1.0, jit := 0.0, over := 0.0) -> PackedVector2Array:
	var tips: Array[Vector2] = []
	for i in 5:
		var a := rot + TAU * i / 5.0
		var rr := r * (1.0 + _rng.randf_range(-vj, vj))
		tips.append(c + Vector2(cos(a), sin(a)) * rr + Vector2(_rng.randf_range(-vj, vj),
			_rng.randf_range(-vj, vj)) * r)
	var order := PackedVector2Array()
	var s0 := int(start)
	for k in 6:
		order.append(tips[posmod(s0 + int(dir) * 2 * k, 5)])
	var frac := start - float(s0)
	if frac > 0.0:
		# начать с середины ребра: сдвигаем порядок и добавляем точку на ребре
		var mid := order[0].lerp(order[1], frac)
		var re := PackedVector2Array([mid])
		for k in range(1, 6):
			re.append(order[k])
		re.append(mid)
		order = re
	if over > 0.0:
		order.append(order[order.size() - 1].lerp(order[1], over))
	if round_n <= 0:
		return _dense(order, jit)
	# скругление рукой — у вершины, радиусом ~10–15 px: Чайкин по уже плотной ломаной
	var pts := _dense(order)
	for i in round_n:
		pts = _chaikin(pts)
	# обратно к шагу мыши ~6 px, дрожь — на каждой оставленной точке
	var out := PackedVector2Array([_jit(pts[0], jit)])
	var last := pts[0]
	for p in pts:
		if p.distance_to(last) >= 6.0:
			out.append(_jit(p, jit))
			last = p
	return out


func _chaikin(p: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([p[0]])
	for i in range(1, p.size()):
		out.append(p[i - 1].lerp(p[i], 0.25))
		out.append(p[i - 1].lerp(p[i], 0.75))
	out.append(p[p.size() - 1])
	return out


func _fig(pts: PackedVector2Array) -> StringName:
	if shape == null or not (shape as Script).get_script_method_list().any(
			func(m: Dictionary) -> bool: return m["name"] == "classify"):
		return &"?"
	return shape.call("classify", pts)


# ── 1. Корпус ────────────────────────────────────────────────────────────────

func _test_corpus() -> void:
	print("— корпус штрихов")
	_rng.seed = 2609
	var o := Vector2(500, 380)
	var eights := {
		"8 вертикальная с края петли": _eight(o, 45, 110, PI * 0.5),
		"∞ горизонтальная с перетяжки": _eight(o, 130, 55, 0.0, 0.0),
		"8 в обратную сторону": _eight(o, 50, 120, PI * 0.5, PI * 0.5, 1.0, -1.0),
		"8 наклонная, петли разные": _eight(o, 60, 120, 1.2, 2.0, 0.7),
		"8 мышью: волна и дрожь": _eight(o, 55, 115, PI * 0.45, 1.3, 1.0, 1.0, 0.07, 2.5),
		"∞ мышью с недотягом": _eight(o, 120, 60, 0.15, 0.4, 0.85, -1.0, 0.05, 2.0, TAU - 0.25),
		"8 крупная (~690 px)": _eight(o, 62, 145, PI * 0.5, 0.9, 1.0, 1.0, 0.03, 1.5),
		"8 мелкая (~330 px)": _eight(o, 30, 75, PI * 0.5, PI * 0.5, 1.0, 1.0, 0.0, 1.0),
	}
	eights["8 по подсказке corr-play (шаг 0,15)"] = _skill_eight()
	for name: String in eights:
		var f := _fig(eights[name])
		_check(f == &"eight", "восьмёрка: %s → «%s» (%.0f px)" % [name, f, _len(eights[name])])
	# бывшая фигура «Обряд» (D-1002-03): звёзды теперь — обычная линия
	var stars := {
		"звезда ровная с вершины": _star(o, 70),
		"звезда кривая мышью": _star(o, 70, -1.4, 1.0, 0.12, 0, 1.0, 2.0),
		"звезда по прежней подсказке corr-play (редкие точки)": _skill_star(),
	}
	for name: String in stars:
		var f := _fig(stars[name])
		_check(f == &"", "звезда больше не фигура: %s → «%s»" % [name, f])
	var s_road := PackedVector2Array()
	for i in 100:
		s_road.append(Vector2(100 + i * 6.0, 400 + 40.0 * sin(i * 6.0 / 300.0 * TAU)))
	var zig: Array[Vector2] = []
	for i in 10:
		zig.append(Vector2(100 + i * 50.0, 400 + (40.0 if i % 2 == 0 else -40.0)))
	var closed_zig: Array[Vector2] = [Vector2(300, 300), Vector2(420, 380), Vector2(300, 400),
		Vector2(420, 460), Vector2(300, 480), Vector2(250, 390), Vector2(300, 305)]
	var u_turn := _poly([Vector2(100, 400), Vector2(100, 200)])
	u_turn.append_array(_arc(Vector2(115, 200), 15, 15, PI, PI))
	u_turn.append_array(_poly([Vector2(130, 200), Vector2(130, 400)]))
	var loop_end := _poly([Vector2(100, 400), Vector2(360, 400)])
	loop_end.append_array(_arc(Vector2(360, 370), 30, 30, PI * 0.5, TAU))
	var loop_in_loop := _arc(o, 90, 90, 0.0, TAU)
	loop_in_loop.append_array(_arc(o + Vector2(40, 0), 50, 50, 0.0, TAU))
	var pentagon: Array[Vector2] = []
	for i in 6:
		pentagon.append(o + Vector2.from_angle(-PI * 0.5 + TAU * i / 5.0) * 100.0)
	var penta_pts := _poly(pentagon)
	var four: Array[Vector2] = []
	for i in 5:
		four.append(o + Vector2.from_angle(TAU * i * 3.0 / 8.0) * 110.0)
	var heptagram: Array[Vector2] = []
	for i in 8:
		heptagram.append(o + Vector2.from_angle(-PI * 0.5 + TAU * i * 3.0 / 7.0) * 100.0)
	var negatives := {
		"прямая 450": _poly([Vector2(100, 400), Vector2(550, 400)]),
		"L 240+240": _poly([Vector2(100, 160), Vector2(100, 400), Vector2(340, 400)]),
		"S-дуга вдоль дороги": s_road,
		"U-разворот": u_turn,
		"зигзаг": _poly(zig),
		"замкнутый зигзаг-«молния»": _poly(closed_zig),
		"линия с петлёй на конце": loop_end,
		"кольцо r75": _arc(o, 75, 75, 0.3, TAU, 0.05, 1.5),
		"овал 120×60": _arc(o, 120, 60, 1.0, TAU),
		"спираль полтора витка": _arc(o, 80, 80, 0.0, TAU * 1.5, 0.15),
		"двойной виток": _arc(o, 70, 70, 0.0, TAU * 2.0, 0.0, 1.0),
		"петля в петле (обе в одну сторону)": loop_in_loop,
		"пятиугольник": penta_pts,
		"четырёхконечная «звезда» {8/3} не замкнута": _poly(four),
		"семиконечная звезда {7/3}": _poly(heptagram),
		"недорисованная звезда (4 ребра)": _star_part(o, 90, 4),
		"недорисованная восьмёрка (¾)": _eight(o, 50, 120, PI * 0.5, PI * 0.5, 1.0, 1.0, 0.0,
			0.0, TAU * 0.75),
	}
	for name: String in negatives:
		var f := _fig(negatives[name])
		_check(f != &"eight" and f != &"?", "не восьмёрка: %s → «%s»" % [name, f])
	# кольцо остаётся кольцом, восьмёрка и звезда — не кольцо
	_check(_fig(_arc(o, 70, 66, 4.0, TAU + 0.1, 0.06, 1.5)) == &"ring", "кольцо мышью → «ring»")
	_check(shape != null and not bool(shape.call("is_ring", eights["8 вертикальная с края петли"])),
		"восьмёрка — не кольцо")
	_check(shape != null and not bool(shape.call("is_ring", stars["звезда ровная с вершины"])),
		"звезда — не кольцо")


## Ровно как в .claude/skills/corr-play/SKILL.md: агент чертит фигуры ломаной `draw`.
func _skill_eight() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var t := 0.0
	while t <= TAU + 0.001:
		pts.append(Vector2(1130 + 65 * sin(t) * cos(t), 405 + 95 * sin(t)))
		t += 0.15
	return pts


func _skill_star() -> PackedVector2Array:
	var tips: Array[Vector2] = []
	for i in 5:
		tips.append(Vector2(1130, 405) + Vector2.from_angle(-PI * 0.5 + TAU * i / 5.0) * 60.0)
	var pts := PackedVector2Array()
	var order := [0, 2, 4, 1, 3, 0]
	for k in range(1, order.size()):
		var a: Vector2 = tips[order[k - 1]]
		var b: Vector2 = tips[order[k]]
		for j in 5:
			pts.append(a.lerp(b, j / 5.0))
	pts.append(tips[0])
	return pts


## Серия случайных фигур «рукой»: признаётся не меньше 90 % (пропуск терпим, ложное — нет).
func _random_figures() -> void:
	_rng.seed = 4242
	var o := Vector2(500, 380)
	var hit_e := 0
	var n := 40
	for i in n:
		var e := _eight(o, _rng.randf_range(40, 75), _rng.randf_range(90, 140),
			_rng.randf_range(0, TAU), _rng.randf_range(0, TAU), _rng.randf_range(0.75, 1.0),
			1.0 if _rng.randf() < 0.5 else -1.0, _rng.randf_range(0, 0.07),
			_rng.randf_range(0, 2.5), TAU - _rng.randf_range(0, 0.2))
		hit_e += 1 if _fig(e) == &"eight" else 0
	_check(hit_e >= n * 0.9, "случайные восьмёрки «рукой»: признано %d из %d" % [hit_e, n])
	# случайные каракули: незамкнутые — ни одной фигуры; замкнутые прямым возвратом к началу —
	# единицы, и то те, что на глаз и есть восьмёрка (разбор 26.09: C:/AI/necro/batches/legion/
	# runes/dbg_scribbles.png — до ужесточения петель 14 из 300, из них 4 настоящие восьмёрки)
	var open_hits := 0
	var closed_hits := 0
	var n_closed := 0
	for i in 300:
		var pts := PackedVector2Array([o])
		var dir := Vector2.from_angle(_rng.randf_range(0, TAU))
		var turn := _rng.randf_range(-0.12, 0.12)
		for k in _rng.randi_range(40, 110):
			turn = clampf(turn + _rng.randf_range(-0.05, 0.05), -0.2, 0.2)
			dir = dir.rotated(turn)
			pts.append(pts[pts.size() - 1] + dir * 6.0)
		if i % 3 == 0:
			pts.append_array(_dense(PackedVector2Array([pts[pts.size() - 1], o])))
		var f := _fig(pts)
		var closed := pts[0].distance_to(pts[pts.size() - 1]) <= 40.0
		n_closed += 1 if closed else 0
		if f == &"eight":
			if closed:
				closed_hits += 1
			else:
				open_hits += 1
	_check(open_hits == 0, "%d случайных каракуль без замыкания: фигур %d"
		% [300 - n_closed, open_hits])
	_check(closed_hits <= 6, "%d замкнутых каракуль (почти все — прямым возвратом): признано %d (≤ 6)"
		% [n_closed, closed_hits])


func _star_part(c: Vector2, r: float, edges: int) -> PackedVector2Array:
	var pts: Array[Vector2] = []
	for k in edges + 1:
		pts.append(c + Vector2.from_angle(-PI * 0.5 + TAU * (2 * k) / 5.0) * r)
	return _poly(pts)


static func _len(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in range(1, pts.size()):
		s += pts[i].distance_to(pts[i - 1])
	return s


## Точка ломаной на расстоянии d от начала и касательная там.
static func _at(path: PackedVector2Array, d: float) -> Array:
	var run := 0.0
	for i in range(1, path.size()):
		var seg := path[i].distance_to(path[i - 1])
		if run + seg >= d or i == path.size() - 1:
			var t := clampf((d - run) / maxf(seg, 0.001), 0.0, 1.0)
			return [path[i - 1].lerp(path[i], t), (path[i] - path[i - 1]).normalized()]
		run += seg
	return [path[path.size() - 1], Vector2.RIGHT]


## Окна вдоль дорог всех карт: штрих «по дороге» длиной 300…720 px, сдвинутый вбок на
## −25/0/+25 px, — ни одной фигуры: восьмёрки, треугольника, квадрата и кольца (проверяющий
## кольца делал так же).
func _test_roads() -> void:
	print("— окна вдоль дорог всех карт")
	var total := 0
	var bad: Array[String] = []
	for map_id: String in MAPS:
		var f := FileAccess.open(LegionCfg.MAPS_DIR + map_id + ".json", FileAccess.READ)
		if f == null:
			continue
		var data: Dictionary = JSON.parse_string(f.get_as_text())
		for road: Dictionary in data.get("roads", []):
			var path := PackedVector2Array()
			for p: Array in road["path"]:
				path.append(Vector2(float(p[0]), float(p[1])))
			var road_len := _len(path)
			for win: float in [300.0, 400.0, 480.0, 600.0, 720.0]:
				var start := 0.0
				while start + win <= road_len:
					for off: float in [-25.0, 0.0, 25.0]:
						var stroke := PackedVector2Array()
						var d := start
						while d <= start + win:
							var at := _at(path, d)
							var tan: Vector2 = at[1]
							stroke.append((at[0] as Vector2) + tan.orthogonal() * off)
							d += 6.0
						total += 1
						var fig := _fig(stroke)
						if fig != &"":
							bad.append("%s/%s %d+%d%+d → %s" % [map_id, road["id"], start, win,
								off, fig])
					start += 20.0
	_check(total > 3000, "окон вдоль дорог проверено: %d (300–720 px, ±25 px)" % total)
	_check(bad.is_empty(), "ни одного ложного срабатывания вдоль дорог: %s" % str(bad.slice(0, 8)))


# ── Бот: бой побайтно прежний ────────────────────────────────────────────────

func _bot_digest(map_id: String, seed: int, steps: int) -> String:
	Settings.scheme_override = ""
	# «Стажёр» = прежние числа (D-0926-44, verify-challenge: 8/8 боёв до символа) — эталон снят до
	# уровней сложности, а агентный прогон по умолчанию идёт на «Штатном»
	w.dev = {"difficulty": "intern"}
	w.dev_invuln = false
	w.args["bot"] = "selective"
	w._base_seed = seed
	w.start_map(map_id)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for i in steps:
		w._step(1.0 / 60.0)
		if i % 30 != 0:
			continue
		var line := "%d|%.4f|%.4f|%d|" % [i, w.cauldron_hp, w.contracts.mana, w.souls]
		for u in w.units:
			line += "%.3f,%.3f,%.3f,%d;" % [u.position.x, u.position.y, u.hp, u.state]
		for f in w.foes:
			line += "%s:%.3f,%.3f,%.3f;" % [f.type_id, f.position.x, f.position.y, f.hp]
		for c in w.contracts.contracts:
			line += "c%d:%.2f:%s;" % [c.id, c.length, str(c.seg_age)]
		var keys := w.stats.keys()
		keys.sort()
		for k in keys:
			line += "%s=%s," % [k, str(w.stats[k])]
		ctx.update(line.to_utf8_buffer())
	w.args.erase("bot")
	return ctx.finish().hex_encode()


func _test_bot_same() -> void:
	print("— бот: бой побайтно прежний")
	var ref: Dictionary = {}
	var f := FileAccess.open(BOT_REF, FileAccess.READ)
	if f != null:
		for line in f.get_as_text().split("\n", false):
			var parts := line.strip_edges().split(" ")
			if parts.size() == 4:
				ref["%s %s %s" % [parts[0], parts[1], parts[2]]] = parts[3]
	for run: Array in BOT_RUNS:
		var t0 := Time.get_ticks_msec()
		var d := _bot_digest(run[0], run[1], run[2])
		var key := "%s %d %d" % [run[0], run[1], run[2]]
		print("  BOTREF %s %s  (%d мс)" % [key, d, Time.get_ticks_msec() - t0])
		_check(ref.get(key, "") == d, "бот %s: трасса совпала с эталоном economy-mana" % key)


# ── Ввод настоящими событиями ────────────────────────────────────────────────

func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2, mask: int = 0) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


## Протяжка ЛКМ по ломаной; возвращает, чем был признан черновик перед отпусканием.
func _stroke(pts: PackedVector2Array, release := true) -> StringName:
	await _move(pts[0])
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for i in range(1, pts.size()):
		await _move(pts[i], MOUSE_BUTTON_MASK_LEFT)
	var v: Variant = w.contracts.get("_draft_fig")
	var hinted: StringName = v if v is StringName else &""
	if release:
		await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	return hinted


func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


func _hand_eight() -> PackedVector2Array:
	_rng.seed = 88
	return _eight(FC, 85, 130, PI * 0.5, PI * 0.5 + 0.2, 0.9, 1.0, 0.04, 1.5)


## Треугольник «рукой» (D-1002-03) — для подписи черновика и цены подновления фигуры.
func _hand_triangle() -> PackedVector2Array:
	_rng.seed = 55
	var pts := PackedVector2Array()
	for k in 4:
		pts.append(FC + Vector2.from_angle(-PI * 0.5 + 0.15 + TAU * float(k % 3) / 3.0) * 80.0)
	return _dense(pts, 1.5)


func _last() -> Contract:
	var cs := w.contracts.contracts
	return cs[cs.size() - 1] if not cs.is_empty() else null


func _fig_of(c: Contract) -> StringName:
	if c == null:
		return &""
	var v: Variant = c.get("figure")
	return v if v is StringName else &""


func _man(c: Contract, frac := 1.0) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	var n := 0
	for p in c.posts:
		n += 1
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


func _popup_texts() -> Array[String]:
	var out: Array[String] = []
	for p in w.contracts._popups:
		out.append(String(p.get("text", "")))
	return out


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
	for i in roundi(sec * 60.0):
		w._step(1.0 / 60.0)


# ── Черчение фигур мышью ─────────────────────────────────────────────────────

func _test_draw_eight() -> void:
	print("— восьмёрка мышью")
	_fresh()
	var pts := _hand_eight()
	var hinted := await _stroke(pts, false)
	_check(hinted == &"eight", "до отпускания черновик признан восьмёркой (подпись «Двойная смена»): «%s», %.0f px"
		% [hinted, _len(pts)])
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	var c := _last()
	_check(_fig_of(c) == &"eight", "после отпускания — договор-восьмёрка")
	if _fig_of(c) != &"eight":
		return
	var lobes: PackedVector2Array = c.get("lobes")
	_check(lobes.size() == 2 and lobes[0].distance_to(lobes[1]) > 80.0,
		"две петли, центры порознь: %s" % str(lobes))
	var ok := true
	for p in c.posts:
		var at: Vector2 = (p["pos"] as Vector2) - (p["offset"] as Vector2)
		var other := lobes[1 - int(c.call("lobe_at", float(p["along"])))]
		ok = ok and (p["normal"] as Vector2).dot((other - at).normalized()) > 0.99
	_check(ok, "стрелка каждого места — к центру чужой петли (%d мест)" % c.posts.size())
	_check(_popup_texts().has("Двойная смена!"), "надпись «Двойная смена!» при заключении")


func _test_draw_triangle() -> void:
	print("— треугольник мышью")
	_fresh()
	var pts := _hand_triangle()
	var hinted := await _stroke(pts, false)
	_check(hinted == &"triangle",
		"до отпускания черновик признан треугольником (подпись «Обряд»): «%s», %.0f px"
		% [hinted, _len(pts)])
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	var c := _last()
	_check(_fig_of(c) == &"triangle", "после отпускания — договор-треугольник")
	if _fig_of(c) != &"triangle":
		return
	var tips: PackedVector2Array = c.get("tips")
	_check(tips.size() == 3 and c.center.distance_to(FC) < 15.0,
		"3 вершины, центр у центра фигуры: %s" % c.center)
	var ok := true
	for p in c.posts:
		var at: Vector2 = (p["pos"] as Vector2) - (p["offset"] as Vector2)
		ok = ok and (p["normal"] as Vector2).dot((c.center - at).normalized()) > 0.99
	_check(ok, "стрелка каждого места — к центру (%d мест)" % c.posts.size())


func _test_long_line() -> void:
	print("— линия длиннее LINE_MAX обрезается")
	_fresh()
	var before := float(w.stats["mana_spent"])
	var pts := _poly([Vector2(720, 300), Vector2(1270, 300)])
	var hinted := await _stroke(pts)
	var c := _last()
	_check(hinted == &"" and c != null and _fig_of(c) == &"", "прямая 550 px — обычный договор")
	if c == null:
		return
	_check(c.length <= LegionCfg.LINE_MAX + 0.5, "длина договора не больше LINE_MAX: %.1f" % c.length)
	var spent := float(w.stats["mana_spent"]) - before
	_check(absf(spent - LegionCfg.LINE_MAX * LegionCfg.MANA_PER_PX) < 1.0,
		"мана за хвост возвращена: потрачено %.1f (линия 480 px — %.1f)"
		% [spent, LegionCfg.LINE_MAX * LegionCfg.MANA_PER_PX])


# ── Восьмёрка ────────────────────────────────────────────────────────────────

## Договор-фигура в обход мыши (для механики); на старом коде — null.
func _make_fig(fig: StringName, pts: PackedVector2Array) -> Contract:
	var n := w.contracts.contracts.size()
	var args := w.contracts.get_method_list().filter(func(m: Dictionary) -> bool:
		return m["name"] == "_create")
	if args.is_empty() or (args[0]["args"] as Array).size() < 5:
		return null
	w.contracts.call("_create", pts, 1, LegionCfg.KIND_LABORER, false, fig)
	var c := _last() if w.contracts.contracts.size() > n else null
	return c if _fig_of(c) == fig else null


## Урон по неподвижному врагу от одного бойца строя за sec секунд.
func _strike_damage(c: Contract, sec: float) -> float:
	var p: Dictionary = c.posts[0]
	var u := w.spawn_unit(c.kind, p["pos"])
	u.assign(c, p)
	u._arrive()
	var n: Vector2 = p["normal"]
	var f := _still_foe((p["pos"] as Vector2) + n * 18.0)
	# боец не должен погибнуть (dev_invuln не годится: он глушит урон и по врагу)
	u.hp = 1e9
	u.max_hp = 1e9
	var hp0 := f.hp
	_steps(sec)
	return hp0 - f.hp


func _test_eight_tempo() -> void:
	print("— восьмёрка: темп удара в строю")
	_fresh()
	var line: Contract = w.contracts.add_contract(_poly([Vector2(1130, 290), Vector2(1130, 520)]),
		1, false)
	var base := _strike_damage(line, 4.0)
	_fresh()
	var c := _make_fig(&"eight", _hand_eight())
	_check(c != null, "договор-восьмёрка собран")
	if c == null:
		return
	var fast := _strike_damage(c, 4.0)
	_check(base > 0.0 and fast / base > 1.35 and fast / base < 1.65,
		"строй восьмёрки бьёт ×1,5: урон за 4 с %.0f против %.0f у линии (×%.2f)"
		% [fast, base, fast / maxf(base, 0.001)])


func _cross_ok(c: Contract, squad: Array[Legionnaire], home: Dictionary,
		origins: Dictionary = {}) -> bool:
	var lobes: PackedVector2Array = c.get("lobes")
	var ok := not squad.is_empty()
	for u in squad:
		var other := lobes[1 - int(home[u])]
		# При немедленном вводе _button уже пропустил кадр движения после выпуска.
		# Полный пробег задан от позиции выпуска, а не от позиции следующего кадра.
		var origin: Vector2 = origins.get(u, u.position)
		ok = ok and u.state == Legionnaire.State.CHARGE \
			and u._charge_dir.dot((other - origin).normalized()) > 0.95 \
			and absf(float(u.get("_charge_cap")) - (origin.distance_to(other) + 24.0)) < 1.0
	return ok


func _homes(c: Contract, squad: Array[Legionnaire]) -> Dictionary:
	var home := {}
	for u in squad:
		home[u] = int(c.call("lobe_at", float(u.post["along"])))
	return home


func _test_eight_cross() -> void:
	print("— восьмёрка: выпуск крест-накрест")
	_fresh()
	var c := _make_fig(&"eight", _hand_eight())
	if c == null:
		_check(false, "договор-восьмёрка собран")
		return
	var squad := _man(c)
	var home := _homes(c, squad)
	var at := c.seg_center(1)
	await _move(at)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	var origins := {}
	for u in squad:
		origins[u] = u.position
	await _button(at + Vector2(2, 1), MOUSE_BUTTON_RIGHT, false)
	_check(_live(c) == 0, "ПКМ по участку сорвал всю восьмёрку")
	_check(_cross_ok(c, squad, home, origins),
		"все %d бойцов — к центру ЧУЖОЙ петли, пробег до него + 24 px" % squad.size())
	_check(_popup_texts().has("Крест-накрест!"), "надпись «Крест-накрест!»")
	_steps(3.0)
	_check(int(w.stats.get("overtimes", 0)) == 0, "выпуск игроком — без «Сверхурочных»")


func _test_eight_overtime() -> void:
	print("— восьмёрка: «Сверхурочные»")
	_fresh()
	var c := _make_fig(&"eight", _hand_eight())
	if c == null:
		_check(false, "договор-восьмёрка собран")
		return
	var squad := _man(c)
	var home := _homes(c, squad)
	_melt_all(c)
	_check(_live(c) == 0, "восьмёрка растаяла целиком (один срок на фигуру)")
	_check(_cross_ok(c, squad, home), "таяние — тоже крест-накрест (%d)" % squad.size())
	var delay := float(_cfg("OVERTIME_DELAY", 1.2))
	var lobes: PackedVector2Array = c.get("lobes")
	var first_vol := {}
	for u in squad:
		first_vol[u] = u._volley
	var second := {}
	var early := false
	var t := 0.0
	while t < delay + 3.0:
		w._step(1.0 / 60.0)
		t += 1.0 / 60.0
		for u in squad:
			if second.has(u) or not u.alive or u.state != Legionnaire.State.CHARGE \
					or is_same(u._volley, first_vol[u]):
				continue
			early = early or t < delay - 0.02
			var own := lobes[int(home[u])]
			second[u] = u._charge_dir.dot((own - u.position).normalized()) > 0.95
	var toward := 0
	for u: Legionnaire in second:
		toward += 1 if second[u] else 0
	_check(int(w.stats.get("overtimes", 0)) == 1 and not early and toward >= squad.size() * 0.9,
		"после паузы %.1f с второй натиск — к центру своей петли: %d из %d"
		% [delay, toward, squad.size()])
	_check(_popup_texts().has("Сверхурочные!"), "надпись «Сверхурочные!»")
	# недобор: занято 40 % мест — таяние без второго натиска
	_fresh()
	c = _make_fig(&"eight", _hand_eight())
	_man(c, 0.4)
	_melt_all(c)
	_steps(delay + 0.5)
	_check(int(w.stats.get("overtimes", 0)) == 0, "строй не набран (40 %) — «Сверхурочных» нет")


# ── Правки после проверки f19b5b8 (проверяющий 26.09) ───────────────────────

## Обвод линии с перелётом: цена и подновление — как на базе 486b977, где черновик упирался
## в LINE_MAX. Эталон снят на базе (runes_old): {on, over} → {spent, lines, renewed}.
const REFRESH_CASES := [
	[480.0, 150.0], [300.0, 250.0], [400.0, 300.0],
]


func _refresh_case(on: float, over: float) -> Dictionary:
	_fresh()
	# линия 480 px справа налево по y = 300 (x 1250 → 770)
	await _stroke(_poly([Vector2(1250, 300), Vector2(770, 300)]))
	var c := _last()
	if c == null:
		return {}
	for s in c.seg_count():
		c.seg_age[s] = 5.0
	w.contracts.mana = w.contracts.mana_max
	var before := float(w.stats["mana_spent"])
	# обвод: on px по линии (от x = 770 + on к 770) и дальше over px за её конец
	var start := Vector2(770.0 + on, 301.0)
	await _stroke(_poly([start, Vector2(770, 301), Vector2(770.0 - over, 301)]))
	var renewed := 0
	for s in c.seg_count():
		# release обрабатывается до следующего _process: возраст уже один fixed60-кадр.
		renewed += 1 if c.seg_age[s] <= 1.0 / 60.0 + 0.00001 else 0
	return {"spent": snappedf(float(w.stats["mana_spent"]) - before, 0.1),
		"lines": w.contracts.contracts.size(), "renewed": renewed}


func _test_refresh_overshoot() -> void:
	print("— обвод линии с перелётом — как на базе")
	var ref := {}
	var f := FileAccess.open("res://tests/data/legion_runes_refresh_ref.txt", FileAccess.READ)
	if f != null:
		for line in f.get_as_text().split("\n", false):
			var parts := line.strip_edges().split(" ")
			if parts.size() == 5:
				ref["%s+%s" % [parts[0], parts[1]]] = {"spent": float(parts[2]),
					"lines": int(parts[3]), "renewed": int(parts[4])}
	for case: Array in REFRESH_CASES:
		var got := await _refresh_case(case[0], case[1])
		var key := "%d+%d" % [int(case[0]), int(case[1])]
		print("  REFRESHREF %d %d %.1f %d %d" % [int(case[0]), int(case[1]),
			float(got.get("spent", -1.0)), int(got.get("lines", -1)), int(got.get("renewed", -1))])
		var want: Dictionary = ref.get(key, {})
		_check(not want.is_empty() and absf(float(got.get("spent", -1.0)) - float(want["spent"])) < 1.0
			and int(got.get("lines", -1)) == int(want["lines"])
			and int(got.get("renewed", -1)) == int(want["renewed"]),
			"обвод %s: потрачено %.1f, договоров %d, подновлено %d (база: %s)" % [key,
			float(got.get("spent", -1.0)), int(got.get("lines", -1)), int(got.get("renewed", -1)),
			str(want)])


func _test_figure_refresh_price() -> void:
	print("— подновление фигуры — по длине всей фигуры")
	_fresh()
	var c := _make_fig(&"triangle", _hand_triangle())
	if c == null:
		_check(false, "договор-треугольник собран")
		return
	for s in c.seg_count():
		c.seg_age[s] = 5.0
	# короткий штрих по ребру: 3 точки ~18 px вдоль первого участка
	var a := c.point_at(20.0)
	var b := c.point_at(38.0)
	var stroke := PackedVector2Array([a, a.lerp(b, 0.5), b])
	w.contracts.mana = w.contracts.mana_max
	var before := float(w.stats["mana_spent"])
	w.contracts.begin(stroke[0])
	for p in stroke.slice(1):
		w.contracts.extend(p)
	w.contracts.finish()
	var spent := float(w.stats["mana_spent"]) - before
	var renewed := 0
	for s in c.seg_count():
		renewed += 1 if c.seg_age[s] == 0.0 else 0
	var full := c.length * LegionCfg.MANA_PER_PX
	_check(renewed == c.seg_count() and absf(spent - full) < 0.6,
		"18 px по треугольнику подновили все %d участков за %.1f маны (длина фигуры %.0f px — %.1f)"
		% [renewed, spent, c.length, full])
	# не хватает маны на всю фигуру — подновления нет, мана цела
	for s in c.seg_count():
		c.seg_age[s] = 5.0
	w.contracts.mana = full * 0.5
	var mana0 := w.contracts.mana
	w.contracts.begin(stroke[0])
	for p in stroke.slice(1):
		w.contracts.extend(p)
	w.contracts.finish()
	var kept := true
	for s in c.seg_count():
		kept = kept and c.seg_age[s] == 5.0
	_check(kept and absf(w.contracts.mana - mana0) < 0.01,
		"маны на всю фигуру нет — не подновлена, мана не тронута (%.1f → %.1f)"
		% [mana0, w.contracts.mana])


## «S-дуга и прямой возврат к началу» с дрожью точек — не восьмёрка (проверяющий: 16/50 и 43/50).
func _s_return(jit: float) -> PackedVector2Array:
	var o := Vector2(500, 380)
	var r := _rng.randf_range(40.0, 60.0)
	var rot := _rng.randf_range(0.0, TAU)
	var pts := PackedVector2Array()
	# S: полукруг вверх, полукруг вниз
	for i in 27:
		var a := PI - PI * i / 26.0
		pts.append(Vector2(-r, 0) + Vector2(cos(a), -sin(a)) * r)
	for i in range(1, 27):
		var a := PI - PI * i / 26.0
		pts.append(Vector2(r, 0) + Vector2(cos(a), sin(a)) * r)
	var back := _dense(PackedVector2Array([pts[pts.size() - 1], pts[0]]))
	pts.append_array(back.slice(1))
	var out := PackedVector2Array()
	for p in pts:
		out.append(_jit(o + p.rotated(rot), jit))
	return out


func _test_s_return() -> void:
	print("— «S-дуга + прямой возврат» с дрожью")
	_rng.seed = 77
	for jit: float in [0.0, 1.5, 2.0]:
		var hits := 0
		for i in 50:
			hits += 1 if _fig(_s_return(jit)) == &"eight" else 0
		# дыра B-073 закрыта признаком сглаженной кривизны (ContractShape.straight_share); порог
		# проверяет legion_newbie2_test, здесь счёт только печатается
		print("  ИНФО дрожь %.1f px: «S-дуга + прямой возврат» признана восьмёркой %d из 50"
			% [jit, hits])
