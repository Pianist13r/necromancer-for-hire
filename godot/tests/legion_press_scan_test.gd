extends SceneTree
##
## Регресс трека оптимизации (10.10.2026, B-036): скан давки LegionGrid.press_scan.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_press_scan_test.gd -- --mute
##
## 1) Точность: на живом бое (карта boss, 300 зомби, 6 договоров — прямые, волнистая, с мёртвым
##    участком) press_mass и press_sum совпадают ПОБАЙТНО с эталонной копией прежнего скана
##    (ниже, _ref_scan) на каждом из STEPS шагов. Давка — симуляция «Схватки» (lockstep): любой
##    сдвиг в последнем бите разведёт клиентов, поэтому сравнение строгое, без допуска.
## 2) Скорость: медиана из ROUNDS замеров нового скана не больше SPEED_RATIO от эталонного в
##    том же процессе (отношение, а не микросекунды — машина и фоновый Defender шумят).
## Итог «LEGION PRESS SCAN: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_press_scan_test.cfg"
const DT := 1.0 / 60.0
const N_FOES := 300
const STEPS := 180
const ROUNDS := 7
const REPS := 20
## Новый скан — не дольше 3/4 прежнего: замер 10.10 — ×0,53–0,60 (отсев кусков), прежний сам с
## собой ×0,88–1,15; запас от шума машины в обе стороны.
const SPEED_RATIO := 0.75

var w: LegionWorld
var _fails := 0
var _checks := 0


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
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_setup()
	_test_exact()
	_test_speed()
	Campaign.reset()
	print("LEGION PRESS SCAN: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Карта boss без волн (предел — 6 договоров): 4 прямых по 386 px (точки через 4,5 px, как у
## штриха мыши — проба verifier 26.09 press_probe.gd), одна волнистая линия и один договор с
## мёртвым участком; 300 зомби в рамке договоров, идут вниз — к линиям.
func _setup() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("boss")
	w.dev_invuln = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 1010
	for y0 in [150.0, 230.0, 310.0, 550.0]:
		var pts := PackedVector2Array()
		var x := 300.0
		var i := 0
		while x < 686.0:
			pts.append(Vector2(x, y0 + (1.5 if i % 2 == 0 else -1.5)))
			x += 4.5
			i += 1
		_add(pts)
	var wave := PackedVector2Array()
	for i in 70:
		wave.append(Vector2(300.0 + 5.0 * i, 430.0 + 30.0 * sin(float(i) * 0.12)))
	_add(wave)
	var cut := _add(PackedVector2Array([Vector2(720, 200), Vector2(760, 330), Vector2(800, 470)]))
	if cut != null and cut.seg_count() > 1:
		cut.seg_dead[1] = 1
	for j in N_FOES:
		var at := Vector2(rng.randf_range(280.0, 820.0), rng.randf_range(110.0, 600.0))
		w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + Vector2(0, 400)]), at)
	w._step(DT)


func _add(pts: PackedVector2Array) -> Contract:
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false,
		LegionCfg.KIND_LABORER)
	if c != null:
		c.ttl = 9999.0
	return c


func _test_exact() -> void:
	var cs := w.all_contracts()
	_check(cs.size() == 6, "договоров на поле %d (нужно 6)" % cs.size())
	var pairs := 0
	var bad := 0
	var pressed := 0
	var first_bad := ""
	for step in STEPS:
		w._step(DT)
		for c in cs:
			var ref := _ref_scan(c, LegionCfg.PRESS_BAND)
			w.grid.press_scan(c, LegionCfg.PRESS_BAND)
			pairs += 1
			var same: bool = ref[0] == c.press_mass and ref[1] == c.press_sum
			if not same:
				bad += 1
				if first_bad == "":
					first_bad = "шаг %d: эталон %s / %s, новый %s / %s" % [step, ref[0], ref[1],
						c.press_mass, c.press_sum]
			for m in c.press_mass:
				if m > 0.0:
					pressed += 1
	_check(pressed > STEPS, "давка вообще есть: участков под напором за прогон %d" % pressed)
	_check(bad == 0, "press_mass/press_sum побайтно как у прежнего скана: %d/%d расхождений %s"
		% [bad, pairs, first_bad])


func _test_speed() -> void:
	var cs := w.all_contracts()
	# старый и новый — вперемешку по шагам: фоновая нагрузка машины ложится на оба поровну
	var t_ref := PackedInt64Array()
	var t_new := PackedInt64Array()
	var ratios := PackedFloat64Array()
	for r in ROUNDS:
		var sr := 0
		var sn := 0
		for k in REPS:
			var a := Time.get_ticks_usec()
			for c in cs:
				_ref_scan(c, LegionCfg.PRESS_BAND)
			var b := Time.get_ticks_usec()
			for c in cs:
				w.grid.press_scan(c, LegionCfg.PRESS_BAND)
			var e := Time.get_ticks_usec()
			sr += b - a
			sn += e - b
		t_ref.append(sr)
		t_new.append(sn)
		ratios.append(float(sn) / float(maxi(1, sr)))
	t_ref.sort()
	t_new.sort()
	ratios.sort()
	var ref_ms := float(t_ref[ROUNDS / 2]) / REPS / 1000.0
	var new_ms := float(t_new[ROUNDS / 2]) / REPS / 1000.0
	var ratio := ratios[ROUNDS / 2]
	print("  скан давки за шаг (%d врагов, %d договоров): прежний %.3f мс, новый %.3f мс, ×%.2f"
		% [w.active_foes(), cs.size(), ref_ms, new_ms, ratio])
	_check(ratio <= SPEED_RATIO, "новый скан ≤ %.2f прежнего (медиана отношений из %d)"
		% [SPEED_RATIO, ROUNDS])


## Эталон: скан давки ДО трека оптимизации (legion_grid.gd на 06fbdd10), дословно, но в свои
## массивы — [press_mass, press_sum]. Не править: это мерка «симуляция не изменилась».
func _ref_scan(c: Contract, band: float) -> Array:
	var g := w.grid
	var n_seg := c.seg_count()
	var mass := PackedFloat32Array()
	mass.resize(n_seg)
	mass.fill(0.0)
	var sum := PackedVector2Array()
	sum.resize(n_seg)
	sum.fill(Vector2.ZERO)
	if c.points.is_empty():
		return [mass, sum]
	var box := Rect2(c.points[0], Vector2.ZERO)
	for p in c.points:
		box = box.expand(p)
	box = box.grow(band)
	var band2 := band * band
	for gy in range(g._gy(box.position.y), g._gy(box.end.y) + 1):
		for gx in range(g._gx(box.position.x), g._gx(box.end.x) + 1):
			var i := g._f_head[gy * g._gw + gx]
			while i != -1:
				var f := w.foes[i]
				i = g._f_next[i]
				if not f.is_active() or f.ghost or f.holding or f.stun_t > 0.0 \
						or not box.has_point(f.position):
					continue
				var best := band2
				var best_s := -1
				var best_q := Vector2.ZERO
				for s in n_seg:
					if not c.seg_alive(s) or not c.seg_press_box[s].has_point(f.position):
						continue
					var poly := c.seg_polys[s]
					for k in range(1, poly.size()):
						var q := Geometry2D.get_closest_point_to_segment(f.position, poly[k - 1],
							poly[k])
						var d2 := q.distance_squared_to(f.position)
						if d2 <= best:
							best = d2
							best_s = s
							best_q = q
				if best_s < 0:
					continue
				var to_seg := best_q - f.position
				if to_seg.length_squared() > 1.0 \
						and f.heading().dot(to_seg.normalized()) < LegionCfg.PRESS_FACING:
					continue
				var m := float(LegionCfg.PRESS_MASS.get(f.type_id, LegionCfg.PRESS_MASS_DEFAULT)) \
					* LegionChallenge.press_mult(f, c.kind)
				mass[best_s] += m
				sum[best_s] += f.position * m
	return [mass, sum]
