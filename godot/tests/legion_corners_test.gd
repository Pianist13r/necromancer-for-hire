extends SceneTree
##
## Угловые фигуры, мини-размер, подготовка и направленная рогатка (D-1002, 05.10.2026).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_corners_test.gd -- --mute
##
## 1) места: у «Обряда» 3 угла, у «Каре» 4, у «Комиссии» 4 из 5, у «Неустойки» 2 — по одному
##    бойцу на угол, без мест на рёбрах и второго ряда; непроходимый угол фигуру НЕ заключает;
## 2) размер: D 48…112 — мини (кольцо и восьмёрка по четыре места), меньше 48 — не фигура,
##    больше 112 — обычная; у мини-обряда ослабленные числа;
## 3) подготовка: заряд копится 1,5 с непрерывного заполнения порога и сбрасывается недобором;
##    ранний выпуск — обычный натиск без ульты;
## 4) рогатка: ПКМ берёт ОДНУ фигуру, соседняя не выпускается, выпуск идёт по оси оттяжки;
## 5) отрицательный корпус: обычные линии, круги и восьмёрки угловыми фигурами не становятся;
##    «D» не путается с кругом и треугольником.
## Итог «LEGION CORNERS: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_corners_test.cfg"
const SHAPE_PATH := "res://scripts/legion/contract_shape.gd"
const FC := Vector2(1130.0, 405.0)
const DT := 1.0 / 60.0

var w: LegionWorld
var shape: Script = null
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


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	if ResourceLoader.exists(SHAPE_PATH):
		shape = load(SHAPE_PATH)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	_test_posts()
	_test_size()
	_test_charge()
	_test_sling_one()
	_test_negatives()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION CORNERS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Помощники ────────────────────────────────────────────────────────────────

func _jit(p: Vector2, j: float) -> Vector2:
	return p + Vector2(_rng.randf_range(-j, j), _rng.randf_range(-j, j))


func _dense(pts: PackedVector2Array, jit := 0.0) -> PackedVector2Array:
	var out := PackedVector2Array([_jit(pts[0], jit)])
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, ceili(a.distance_to(b) / 6.0))
		for k in range(1, n + 1):
			out.append(_jit(a.lerp(b, float(k) / n), jit))
	return out


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


func _shape(corners: Array[Vector2], start := 0.0, jit := 0.0) -> PackedVector2Array:
	var m := corners.size()
	var s0 := corners[0].lerp(corners[1 % m], start)
	var path := PackedVector2Array([s0])
	for i in range(1, m + 1):
		path.append(corners[i % m])
	if start > 0.0:
		path.append(s0)
	return _dense(path, jit)


func _arc(c: Vector2, rx: float, ry: float, a0: float, sweep: float,
		jit := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(8, ceili(absf(sweep) * maxf(rx, ry) / 6.0))
	for i in n + 1:
		var a := a0 + sweep * float(i) / n
		pts.append(_jit(c + Vector2(cos(a) * rx, sin(a) * ry), jit))
	return pts


## Штрих «D»: прямая сторона снизу вверх и полукруг вправо (та же форма, что у шаблона урока).
func _d_shape(c: Vector2, r: float, jit := 0.0) -> PackedVector2Array:
	var path := PackedVector2Array([c + Vector2(0, r), c + Vector2(0, -r)])
	path.append_array(_arc(c, r, r, -PI * 0.5, PI, jit))
	return _dense(path, 0.0)


func _fig(pts: PackedVector2Array) -> StringName:
	if shape == null:
		return &"?"
	return shape.call("classify", pts)


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


func _make_fig(fig: StringName, pts: PackedVector2Array) -> Contract:
	var n := w.contracts.contracts.size()
	w.contracts.call("_create", pts, 1, LegionCfg.KIND_LABORER, false, fig)
	var c := _last() if w.contracts.contracts.size() > n else null
	if c == null or String(c.figure) != String(fig):
		return null
	return c


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


static func _len(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in range(1, pts.size()):
		s += pts[i].distance_to(pts[i - 1])
	return s


func _steps(sec: float) -> void:
	for i in roundi(sec / DT):
		w._step(DT)


func _cfg(key: String, fallback: Variant) -> Variant:
	var fcfg: Script = load("res://scripts/legion/figure_cfg.gd")
	return fcfg.get_script_constant_map().get(key, fallback) if fcfg != null else fallback


# ── 1. Места по углам ────────────────────────────────────────────────────────

func _test_posts() -> void:
	print("— места только на углах")
	_rng.seed = 2003
	var cases := [
		{"fig": &"triangle", "n": 3, "pts": _shape(_ngon(FC, 3, 80, -PI * 0.5), 0.2, 1.5)},
		{"fig": &"square", "n": 4, "pts": _shape(_rect(FC, 130, 130, 0.1), 0.3, 1.5)},
		{"fig": &"pentagon", "n": 4, "pts": _shape(_ngon(FC, 5, 85, -PI * 0.5), 0.0, 1.5)},
		{"fig": &"d_shape", "n": 2, "pts": _d_shape(FC, 90.0, 1.0)},
	]
	for case: Dictionary in cases:
		_fresh()
		var c := _make_fig(case["fig"], case["pts"])
		_check(c != null, "%s собран" % str(case["fig"]))
		if c == null:
			continue
		_check(c.posts.size() == int(case["n"]) and c.corners_only,
			"%s: %d места, только углы" % [str(case["fig"]), c.posts.size()])
		var on_tips := true
		for p in c.posts:
			var near := INF
			for t in c.tips:
				near = minf(near, (p["pos"] as Vector2).distance_to(t))
			on_tips = on_tips and near < 0.5
		_check(on_tips, "%s: каждое место — вершина" % str(case["fig"]))
		_check(c.tips.size() >= int(case["n"]), "%s: вершин не меньше мест (%d)"
			% [str(case["fig"]), c.tips.size()])
	# «Комиссия»: пятый угол пуст, выбор детерминирован и не зависит от начала штриха
	_fresh()
	var tips_plain := _ngon(FC, 5, 85, -PI * 0.5)
	var pent_a := _make_fig(&"pentagon", _shape(tips_plain, 0.0, 0.5))
	_fresh()
	var rotated: Array[Vector2] = []
	for i in 5:
		rotated.append(tips_plain[(i + 2) % 5])
	var pent_b := _make_fig(&"pentagon", _shape(rotated, 0.0, 0.5))
	if pent_a != null and pent_b != null:
		var same := pent_a.tips.size() == pent_b.tips.size()
		for t_a in pent_a.tips:
			var near := INF
			for t_b in pent_b.tips:
				near = minf(near, t_a.distance_to(t_b))
			same = same and near < 3.0
		_check(same, "«Комиссия»: выбор четырёх углов не зависит от начала штриха (%d и %d)"
			% [pent_a.tips.size(), pent_b.tips.size()])
	else:
		_check(false, "«Комиссия»: оба пятиугольника собрались")
	# непроходимый угол фигуру не заключает: ищем настоящую скалу сеткой и ставим в неё вершину
	_fresh()
	var rock := Vector2.INF
	for gy in range(40, 700, 8):
		for gx in range(40, 1240, 8):
			if w.terrain.is_rock(Vector2(float(gx), float(gy))):
				rock = Vector2(float(gx), float(gy))
				break
		if rock != Vector2.INF:
			break
	_check(rock != Vector2.INF, "на _gray нашлась скала для проверки угла")
	if rock != Vector2.INF:
		var apex := rock + Vector2(70.0, -30.0)
		var bad := _make_fig(&"triangle", _shape(_ngon(apex, 3, 70, PI * 0.5), 0.0, 0.5))
		_check(bad == null, "угол в стене — фигура не заключена (скала %s)" % str(rock))


# ── 2. Размер: мини и обычная ────────────────────────────────────────────────

func _test_size() -> void:
	print("— мини-размер (48…112 px)")
	_rng.seed = 4501
	# западнее реки _gray (x 620–706): иначе места мини-кольца встают в воду
	var o := Vector2(500, 360)
	# круг: D = 2r; мини 24 ≤ r ≤ 56, мельче 24 — не фигура
	var mini_ring := _arc(o, 45, 45, 0.0, TAU, 1.0)
	var big_ring := _arc(o, 80, 80, 0.0, TAU, 1.0)
	var tiny_ring := _arc(o, 20, 20, 0.0, TAU, 0.5)
	_check(shape.call("size_class", mini_ring) == &"mini", "круг D=90 — мини")
	_check(shape.call("size_class", big_ring) == &"normal", "круг D=160 — обычный")
	_check(shape.call("size_class", tiny_ring) == &"", "круг D=40 — не фигура")
	_check(_fig(mini_ring) == &"ring", "мини-круг — «Оцепление»")
	_fresh()
	var c: Contract = w.contracts.call("_create", mini_ring, 1, LegionCfg.KIND_LABORER,
		true, &"")
	_check(c != null and c.ring and c.posts.size() == 4, "мини-круг: 4 места (%d)"
		% (c.posts.size() if c != null else -1))
	# восьмёрка: четыре места только с D ≥ 96
	_fresh()
	var e8 := LegionLessonBot.template("eight", o, 100.0)
	_check(_fig(e8) == &"eight", "восьмёрка D=100 — фигура")
	var e8_mini: Contract = w.contracts.call("_create", e8, 1, LegionCfg.KIND_LABORER,
		false, &"eight")
	_check(e8_mini != null and e8_mini.posts.size() == 4, "мини-восьмёрка: 4 места (%d)"
		% (e8_mini.posts.size() if e8_mini != null else -1))
	_fresh()
	var e8_small := LegionLessonBot.template("eight", o, 80.0)
	var c8: Contract = w.contracts.call("_create", e8_small, 1, LegionCfg.KIND_LABORER,
		false, &"eight")
	_check(c8 == null or c8.figure == &"" or c8.posts.size() > 4,
		"восьмёрка мельче 96 px не получает четыре места")
	# мини-обряд: ослабленные числа
	_fresh()
	var tri_mini := _shape(_ngon(FC, 3, 45, -PI * 0.5), 0.0, 1.0)
	var ct := _make_fig(&"triangle", tri_mini)
	_check(ct != null and ct.size_mini, "мини-треугольник отмечен мини (%s)"
		% ("да" if ct != null and ct.size_mini else "нет"))
	if ct != null:
		var squad := _man(ct, 0.66)
		var near := w.spawn_foe_on_path("zombie",
			PackedVector2Array([ct.center, ct.center + Vector2(0, 300)]), ct.center)
		near.speed = 0.0
		near.hp = 100000.0
		near.max_hp = 100000.0
		_steps(float(_cfg("CHARGE_TIME", 1.5)) + 0.1)
		var hp0 := near.hp
		w.contracts.release(ct, 0)
		var dealt := hp0 - near.hp
		_check(absf(dealt - float(_cfg("RITE_DMG_MINI", 25.0))) < 0.01 and near.is_stunned(),
			"мини-обряд: урон %.0f и оглушение" % dealt)
		var lr: Dictionary = w.figures.last_rite
		_check(float(lr.get("r", 1e9)) <= ContractShape.fig_span(ct.points) \
			* float(_cfg("RITE_MINI_R_FRAC", 0.65)) + 0.5,
			"мини-обряд: радиус не больше 0,65·D (%.0f)" % float(lr.get("r", -1.0)))
		_check(squad.size() == 2, "мини-обряд: два бойца в строю")
	# цена фигуры — max(контур, floor эффекта): у самого мелкого мини-обряда контур дешевле floor
	_fresh()
	# точки через 8 px: у шага ровно POINT_STEP рука теста «теряет» углы при extend
	var small := PackedVector2Array()
	var sv := _ngon(FC, 3, 30, -PI * 0.5)
	for i in 3:
		var sa: Vector2 = sv[i]
		var sb: Vector2 = sv[(i + 1) % 3]
		var sn := maxi(1, ceili(sa.distance_to(sb) / 8.0))
		for k in sn:
			small.append(sa.lerp(sb, float(k) / sn))
	small.append(sv[0])
	_check(shape.call("size_class", small) == &"mini", "мелкий треугольник — мини")
	var before := float(w.stats["mana_spent"])
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	w.contracts.begin(small[0])
	for i in range(1, small.size()):
		w.contracts.extend(small[i])
	w.contracts.finish()
	var csmall := _last()
	var spent := float(w.stats["mana_spent"]) - before
	_check(csmall != null and String(csmall.figure) == "triangle" and spent >= 19.99,
		"цена мини-обряда не ниже floor 20 (потрачено %.1f, контур %.0f, «%s»)" % [spent,
		csmall.length if csmall != null else 0.0,
		str(csmall.figure) if csmall != null else "-"])


# ── 3. Подготовка ────────────────────────────────────────────────────────────

func _test_charge() -> void:
	print("— подготовка 1,5 с и ранний выпуск")
	_rng.seed = 777
	var charge := float(_cfg("CHARGE_TIME", 1.5))
	_check(absf(charge - 1.5) < 0.01, "время заряда — 1,5 с (%.2f)" % charge)
	_fresh()
	var c := _make_fig(&"square", _shape(_rect(FC, 130, 130, 0.1), 0.3, 1.0))
	_check(c != null, "квадрат собран")
	if c == null:
		return
	_check(c.charge_need() == 3, "каре: заряд с трёх углов из четырёх")
	_man(c, 0.75)
	_steps(charge - 0.3)
	_check(not c.charge_ready(), "раньше срока заряд не готов")
	w.contracts.release(c, 0)   # ранний выпуск
	_check(int(w.stats.get("guards", 0)) == 0, "ранний выпуск каре — без защиты")
	_fresh()
	c = _make_fig(&"square", _shape(_rect(FC, 130, 130, 0.1), 0.3, 1.0))
	if c == null:
		return
	var sq := _man(c, 0.75)
	_steps(charge + 0.1)
	_check(c.charge_ready(), "трое из четырёх за 1,5 с — каре заряжено")
	w.contracts.release(c, 0)
	_check(int(w.stats.get("guards", 0)) == 1, "заряженный выпуск каре — защита группы")
	var buffed := not sq.is_empty()
	for u in sq:
		buffed = buffed and float(u.get("guard_dmg_mult")) < 1.0
	_check(buffed, "участники каре получили защиту")


# ── 4. Рогатка: одна группа ──────────────────────────────────────────────────

func _test_sling_one() -> void:
	print("— рогатка берёт одну группу")
	_rng.seed = 991
	_fresh()
	var left := _make_fig(&"triangle",
		_shape(_ngon(Vector2(FC.x - 90.0, FC.y), 3, 45, -PI * 0.5), 0.0, 1.0))
	var right := _make_fig(&"square",
		_shape(_rect(Vector2(FC.x + 90.0, FC.y), 80, 80, 0.0), 0.0, 1.0))
	_check(left != null and right != null, "две соседние фигуры собраны")
	if left == null or right == null:
		return
	var hits := {"left": 0, "right": 0}
	for id: String in hits:
		var c: Contract = left if id == "left" else right
		hits[id] = 0
		_man(c, 1.0)
	_steps(0.2)
	# ПКМ по левой: захват и рогатка — выпускается только она
	var picked: Dictionary = w.contracts.pick_segment(left.center)
	_check(not picked.is_empty() and picked["contract"] == left,
		"ПКМ над левой берёт именно её")
	if picked.is_empty():
		return
	var axis := Vector2.UP
	var moved := w.contracts.sling_release(left, int(picked["seg"]), Vector2(0.0, 60.0))
	_steps(0.1)
	_check(moved, "рогатка выпустила выбранную фигуру")
	var left_live := 0
	var right_live := 0
	for u in w.units:
		if u.state == Legionnaire.State.CHARGE:
			if left.posts.size() > 0 and u.position.distance_to(left.center) < 200.0:
				left_live += 1
			else:
				right_live += 1
	_check(left_live > 0 and right_live == 0,
		"ушла одна группа: слева %d, справа %d" % [left_live, right_live])
	var along := true
	for u in w.units:
		if u.state == Legionnaire.State.CHARGE:
			along = along and u._charge_dir.dot(axis) > 0.9
	_check(along, "выпуск идёт по оси оттяжки")
	_check(right.alive() and left.alive() == false or left.seg_dead[0] != 0,
		"соседняя фигура осталась на месте")


# ── 5. Отрицательный корпус ──────────────────────────────────────────────────

func _test_negatives() -> void:
	print("— обычные линии угловыми фигурами не становятся")
	_rng.seed = 5150
	var o := Vector2(600, 360)
	var negatives := {
		"прямая 400": _dense(PackedVector2Array([o + Vector2(-200, 0), o + Vector2(200, 0)]), 1.5),
		"L": _dense(PackedVector2Array([o + Vector2(0, -120), o + Vector2(0, 40),
			o + Vector2(140, 40)]), 1.5),
		"U-разворот": _dense(PackedVector2Array([o + Vector2(-60, -100), o + Vector2(-60, 60),
			o + Vector2(60, 60), o + Vector2(60, -100)]), 1.5),
		"S-дуга": _arc(o, 120, 40, 0.0, PI, 1.0),
		"дуга 3/4 r30": _arc(o, 30, 30, 0.0, TAU * 0.75, 1.0),
		"зигзаг": _dense(PackedVector2Array([o + Vector2(-120, -40), o + Vector2(-60, 40),
			o + Vector2(0, -40), o + Vector2(60, 40), o + Vector2(120, -40)]), 1.0),
		"короткая прямая 70": _dense(PackedVector2Array([o, o + Vector2(70, 0)]), 1.0),
	}
	for name: String in negatives:
		var f := _fig(negatives[name])
		_check(f != &"triangle" and f != &"square" and f != &"pentagon" and f != &"d_shape",
			"не угловая фигура: %s → «%s»" % [name, f])
	# круг и восьмёрка остаются собой, мелочь фигурой не становится
	_check(_fig(_arc(o, 70, 70, 0.5, TAU, 1.5)) == &"ring", "круг — кольцо, не угловая")
	var eight := PackedVector2Array()
	for i in 105:
		var t := PI * 0.5 + TAU * i / 104.0
		eight.append(_jit(o + Vector2(45 * sin(t), 110 * sin(t) * cos(t)).rotated(PI * 0.5), 1.0))
	_check(_fig(eight) == &"eight", "восьмёрка — восьмёрка, не угловая")
	var hex := _fig(_shape(_ngon(o, 6, 80, 0.0), 0.0, 1.5))
	_check(hex != &"pentagon" and hex != &"d_shape" and hex != &"triangle" and hex != &"square",
		"шестиугольник — не угловая фигура («%s»)" % str(hex))
	_check(_fig(_arc(o, 20, 20, 0.0, TAU, 0.5)) == &"", "круг D=40 — не фигура")
	# «D» не путается с кругом и треугольником
	var d1 := _d_shape(o, 80.0, 1.0)
	_check(_fig(d1) == &"d_shape", "полукруг — «Неустойка»")
	_check(_fig(_arc(o, 80, 80, 0.0, TAU, 1.0)) == &"ring", "круг рядом с «D» — кольцо")
	var tri := _shape(_ngon(o, 3, 80, -PI * 0.5), 0.0, 1.5)
	_check(_fig(tri) == &"triangle", "треугольник рядом с «D» — «Обряд»")
	_check(_fig(_d_shape(o, 80.0, 2.5)) == &"d_shape", "«D» с дрожью 2,5 px — всё ещё «D»")
