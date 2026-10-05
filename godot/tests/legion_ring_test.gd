extends SceneTree
##
## «Оцепление» — договор-кольцо (идея Игоря 26.09, жесты «Робин Гуд: Легенда Шервуда»).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_ring_test.gd -- --mute
##
## 1) корпус штрихов: кольца признаются, прямая/L/S-дуга/U/зигзаг/петля/короткая дуга/«C»/
##    восьмёрка — нет (ложное срабатывание хуже пропуска);
## 2) кольцо, начерченное НАСТОЯЩИМИ событиями мыши (Input.parse_input_event): подсказка черновика
##    до отпускания, договор-кольцо после; стрелки мест — к центру, передний ряд внутри;
## 3) таяние участка — натиск к центру и не дальше центра; ПКМ-щелчок и рогатка по участку
##    срывают ВСЁ кольцо; комбо за сжатие растёт один раз;
## 4) Пробел: курсор снаружи — стрелки наружу, внутри — к центру;
## 5) линия (не кольцо) — прежняя: одна стрелка dir, залп без ограничения пробега.
## Новый API берётся через get()/call(): на старом коде тест не падает разбором, а честно
## проваливает проверки. Итог «LEGION RING: N/M OK»; код выхода 1, если что-то упало.
## Схема управления — только в памяти (Settings.scheme_override), сохранение — временное.
##

const SAVE := "user://legion_ring_test.cfg"
const SHAPE_PATH := "res://scripts/legion/contract_shape.gd"
## Полоса карты _gray между рекой (x 620–706) и скалой (x 870+), выше северной дороги.
const RC := Vector2(790.0, 112.0)
## Радиус кольца пробы: D = 2·RR = 120 — ОБЫЧНОЕ кольцо (D > 112). Мини-кольцо (48…112) держит
## четыре места НА контуре и одного ряда — его проверяет legion_corners_test.
const RR := 60.0
const DEVICE := 7

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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	if ResourceLoader.exists(SHAPE_PATH):
		shape = load(SHAPE_PATH)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	_test_corpus()
	_test_mini_ring()
	await _test_draw_ring()
	await _test_melt()
	await _test_click_squeeze()
	await _test_sling_squeeze()
	await _test_space()
	await _test_line_unchanged()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION RING: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## D-1002 §3: мини-кольцо (D = 90) — четыре места НА контуре, одного ряда; стрелки мест
## по-прежнему к центру. Места ездят по контуру (offset нулевой), а не в два ряда вокруг него.
func _test_mini_ring() -> void:
	print("— мини-кольцо: четыре места на контуре")
	_fresh()
	var pts := _arc(RC, 45.0, 45.0, 0.0, TAU - 0.1, 0.0, 1.0)
	var cls: StringName = shape.call("classify", pts) if shape != null else &"?"
	_check(cls == &"ring", "круг D=90 — кольцо (классификация «%s»)" % str(cls))
	var c: Contract = w.contracts.call("_create", pts, 1, LegionCfg.KIND_LABORER, true, &"")
	_check(c != null and c.ring, "мини-кольцо собрано")
	if c == null or not c.ring:
		return
	_check(c.posts.size() == 4, "мини-кольцо: четыре места (%d)" % c.posts.size())
	var on_line := true
	var one_row := true
	for p in c.posts:
		on_line = on_line and c.live_distance(p["pos"]) < 1.0
		one_row = one_row and int(p["row"]) == 0 and (p["offset"] as Vector2).length() < 0.5
	_check(on_line and one_row, "места стоят НА контуре, второго ряда нет")
	var normals := true
	for p in c.posts:
		var to_center := (_center(c) - (p["pos"] as Vector2)).normalized()
		normals = normals and (p["normal"] as Vector2).dot(to_center) > 0.99
	_check(normals, "стрелки мест — к центру")


# ── Корпус штрихов ───────────────────────────────────────────────────────────

## Дуга окружности от угла a0 на sweep радиан, точки через ~6 px (шаг штриха POINT_STEP),
## радиус с «рукой»: волна wob и дрожь jit.
func _arc(c: Vector2, rx: float, ry: float, a0: float, sweep: float, wob := 0.0,
		jit := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(8, ceili(absf(sweep) * maxf(rx, ry) / 6.0))
	for i in n + 1:
		var a := a0 + sweep * float(i) / n
		var k := 1.0 + wob * sin(a * 3.0 + 0.7)
		var p := c + Vector2(cos(a) * rx * k, sin(a) * ry * k)
		p += Vector2(_rng.randf_range(-jit, jit), _rng.randf_range(-jit, jit))
		pts.append(p)
	return pts


func _poly(corners: Array[Vector2]) -> PackedVector2Array:
	var pts := PackedVector2Array([corners[0]])
	for i in range(1, corners.size()):
		var a := corners[i - 1]
		var b := corners[i]
		var n := maxi(1, ceili(a.distance_to(b) / 6.0))
		for k in range(1, n + 1):
			pts.append(a.lerp(b, float(k) / n))
	return pts


func _is_ring(pts: PackedVector2Array) -> bool:
	return shape != null and bool(shape.call("is_ring", pts))


func _test_corpus() -> void:
	print("— корпус штрихов")
	_rng.seed = 26
	_check(shape != null, "есть распознавание фигур (contract_shape.gd)")
	var o := Vector2(400, 400)
	var rings := {
		"круг r60": _arc(o, 60, 60, 0.3, TAU),
		"круг против часовой": _arc(o, 60, 60, 2.0, -TAU),
		"овал 80×40": _arc(o, 80, 40, 1.0, TAU),
		"круг с зазором 20 px": _arc(o, 60, 60, 0.0, TAU - 20.0 / 60.0),
		"неровный круг мышью": _arc(o, 58, 54, 4.0, TAU + 0.15, 0.08, 2.0),
		"малый круг r38": _arc(o, 38, 38, 0.0, TAU, 0.0, 1.0),
		"большой круг до потолка длины": _arc(o, 74, 74, 1.0, TAU - 0.2, 0.05, 1.5),
	}
	for name: String in rings:
		_check(_is_ring(rings[name]), "кольцо: " + name)
	var loop_end := _poly([Vector2(100, 400), Vector2(300, 400)])
	loop_end.append_array(_arc(Vector2(300, 375), 25, 25, PI * 0.5, TAU))
	var u_turn := _poly([Vector2(100, 400), Vector2(100, 250)])
	u_turn.append_array(_arc(Vector2(115, 250), 15, 15, PI, PI))
	u_turn.append_array(_poly([Vector2(130, 250), Vector2(130, 400)]))
	var eight := _arc(Vector2(400, 360), 40, 40, PI * 0.5, TAU)
	eight.append_array(_arc(Vector2(400, 440), 40, 40, -PI * 0.5, -TAU))
	var s_road := PackedVector2Array()
	for i in 60:
		s_road.append(Vector2(100 + i * 6.0, 400 + 40.0 * sin(i * 6.0 / 300.0 * TAU)))
	var zig: Array[Vector2] = []
	for i in 8:
		zig.append(Vector2(100 + i * 40.0, 400 + (30.0 if i % 2 == 0 else -30.0)))
	var not_rings := {
		"прямая 300": _poly([Vector2(100, 400), Vector2(400, 400)]),
		"L 150+150": _poly([Vector2(100, 250), Vector2(100, 400), Vector2(250, 400)]),
		"S-дуга вдоль дороги": s_road,
		"U-разворот": u_turn,
		"зигзаг": _poly(zig),
		"линия с петлёй на конце": loop_end,
		"короткая дуга 3/4 r25": _arc(o, 25, 25, 0.0, TAU * 0.75),
		"«C» 300°": _arc(o, 60, 60, 0.0, TAU * 300.0 / 360.0),
		"восьмёрка": eight,
		"треугольник-клин 150": _poly([Vector2(100, 400), Vector2(250, 380), Vector2(110, 360),
			Vector2(105, 395)]),
	}
	for name: String in not_rings:
		_check(not _is_ring(not_rings[name]), "не кольцо: " + name)


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


func _button(p: Vector2, button: MouseButton, pressed: bool, settle_frames := 1) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(settle_frames)


func _space(pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.device = DEVICE
	ev.keycode = KEY_SPACE
	ev.physical_keycode = KEY_SPACE
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(1)


## Протяжка ЛКМ по ломаной; release — отпустить в конце. Возвращает, был ли черновик кольцом
## перед отпусканием (подсказка «Оцепление»).
func _stroke(pts: PackedVector2Array, release := true) -> bool:
	await _move(pts[0])
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for i in range(1, pts.size()):
		await _move(pts[i], MOUSE_BUTTON_MASK_LEFT)
	var hinted: bool = w.contracts.get("_draft_ring") == true
	if release:
		await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	return hinted


func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


## Кольцо рукой: неровный круг против часовой с недотянутым концом, как чертит мышь.
func _hand_ring() -> PackedVector2Array:
	_rng.seed = 7
	return _arc(RC, RR, RR - 4.0, -2.2, TAU - 0.3, 0.05, 1.5)


func _draw_ring() -> Contract:
	await _stroke(_hand_ring())
	var cs := w.contracts.contracts
	return cs[cs.size() - 1] if not cs.is_empty() else null


func _is_ring_contract(c: Contract) -> bool:
	return c != null and c.get("ring") == true


func _seg_dir(c: Contract, s: int) -> Vector2:
	return c.call("seg_dir", s) if c.has_method("seg_dir") else c.dir


func _center(c: Contract) -> Vector2:
	var v: Variant = c.get("center")
	return v if v is Vector2 else RC


func _man(c: Contract) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if p["unit"] != null or p["dead"]:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _still_foe(at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = f.hp
	return f


## Все бойцы, кто стоял на кольце, бегут к центру (по стрелке своего участка).
func _all_charge_in(squad: Array[Legionnaire], c: Contract) -> bool:
	var ok := not squad.is_empty()
	for u in squad:
		var to_c := (_center(c) - u.position).normalized()
		ok = ok and u.state == Legionnaire.State.CHARGE and u._charge_dir.dot(to_c) > 0.8
	return ok


func _live(c: Contract) -> int:
	var n := 0
	for s in c.seg_count():
		if c.seg_alive(s):
			n += 1
	return n


# ── Кольцо ───────────────────────────────────────────────────────────────────

func _test_draw_ring() -> void:
	print("— кольцо мышью")
	_fresh()
	var hinted := await _stroke(_hand_ring(), false)
	_check(hinted, "до отпускания черновик замкнут в кольцо (подсказка «Оцепление»)")
	await _button(_hand_ring()[_hand_ring().size() - 1], MOUSE_BUTTON_LEFT, false)
	var cs := w.contracts.contracts
	var c: Contract = cs[0] if cs.size() == 1 else null
	_check(_is_ring_contract(c), "после отпускания — договор-кольцо")
	if not _is_ring_contract(c):
		return
	_check(_center(c).distance_to(RC) < 8.0, "центр кольца у центра фигуры: %s" % _center(c))
	var ok := true
	for s in c.seg_count():
		ok = ok and _seg_dir(c, s).dot((_center(c) - c.seg_center(s)).normalized()) > 0.99
	_check(ok, "стрелка каждого участка — к центру (%d участков)" % c.seg_count())
	var normals := true
	var front_in := true
	for p in c.posts:
		var at: Vector2 = (p["pos"] as Vector2) - (p["offset"] as Vector2)
		normals = normals and (p["normal"] as Vector2).dot((_center(c) - at).normalized()) > 0.99
		var inner := (p["pos"] as Vector2).distance_to(_center(c)) < at.distance_to(_center(c))
		front_in = front_in and (int(p["row"]) == 0) == inner
	_check(normals, "стрелка каждого места — к центру (%d мест)" % c.posts.size())
	_check(front_in, "передний ряд — внутри кольца")
	var closed := c.points[0].distance_to(c.points[c.points.size() - 1]) < 1.0
	_check(closed, "зазор недотянутого круга закрыт")
	# штрих вдоль живого кольца — подновление, а не второе кольцо
	for s in c.seg_count():
		c.seg_age[s] = 5.0
	w.contracts.mana = w.contracts.mana_max
	await _stroke(_arc(RC, RR, RR - 4.0, -2.2, 1.6, 0.05, 1.0))
	var renewed := 0
	for s in c.seg_count():
		# Немедленный release уже обработан до следующего fixed60-кадра.
		if c.seg_age[s] <= 1.0 / 60.0 + 0.00001:
			renewed += 1
	_check(w.contracts.contracts.size() == 1 and renewed > 0,
		"штрих вдоль кольца подновляет его участки (%d), новый договор не рождается" % renewed)


func _test_melt() -> void:
	print("— таяние участка кольца")
	_fresh()
	var c := await _draw_ring()
	if not _is_ring_contract(c):
		_check(false, "кольцо для таяния начерчено")
		return
	var squad := _man(c)
	var seg0: Array[Legionnaire] = []
	for u in squad:
		if int(u.post["seg"]) == 0:
			seg0.append(u)
	c.seg_age[0] = c.ttl - 0.01
	w.contracts.tick(0.05, w.now)
	_check(not c.seg_alive(0) and _live(c) == c.seg_count() - 1, "растаял ровно участок 0")
	_check(_all_charge_in(seg0, c), "отряд растаявшего участка — натиск к центру (%d)" % seg0.size())
	var cap := float(seg0[0]._volley.get("cap", INF)) if not seg0.is_empty() else INF
	_check(cap < RR + 30.0, "натиск кольца не дальше центра: предел %.0f px" % cap)
	for i in 150:
		w._step(1.0 / 60.0)
	var far := 0.0
	for u in seg0:
		far = maxf(far, u.position.distance_to(_center(c)))
	_check(far < RR, "бойцы остановились у центра, не проскочили за кольцо: %.0f px" % far)


func _test_click_squeeze() -> void:
	print("— ПКМ-щелчок: «Сжать кольцо!»")
	_fresh()
	var c := await _draw_ring()
	if not _is_ring_contract(c):
		_check(false, "кольцо для щелчка начерчено")
		return
	var squad := _man(c)
	var at := c.seg_center(2)
	await _move(at)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _button(at + Vector2(2, 1), MOUSE_BUTTON_RIGHT, false)
	_check(_live(c) == 0, "щелчок по участку 2 сорвал все участки кольца")
	_check(_all_charge_in(squad, c), "все %d бойцов — натиск к центру" % squad.size())
	_check(int(w.stats.get("ring_squeezes", 0)) == 1, "сжатие посчитано одно")
	var said := false
	for p in w.contracts._popups:
		said = said or String(p.get("text", "")) == ContractField.RING_SQUEEZE_LABEL
	_check(said, "к центру — «%s»" % ContractField.RING_SQUEEZE_LABEL)


func _test_sling_squeeze() -> void:
	print("— рогатка: «Сжать кольцо!» с силой и «Точно!»")
	_fresh()
	var c := await _draw_ring()
	if not _is_ring_contract(c):
		_check(false, "кольцо для рогатки начерчено")
		return
	var squad := _man(c)
	var foes: Array[Foe] = []
	for s in [0, 2, 4]:
		foes.append(_still_foe(c.seg_center(s).lerp(_center(c), 0.45)))
	var at := c.seg_center(1)
	var away := (at - _center(c)).normalized()
	await _move(at)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	for i in range(1, 9):
		await _move(at + away * 90.0 * float(i) / 8.0, MOUSE_BUTTON_MASK_RIGHT)
	# Проверяем параметры выпуска до первого удара: он завершит натиск и очистит залп.
	await _button(at + away * 90.0, MOUSE_BUTTON_RIGHT, false, 0)
	_check(_live(c) == 0, "натяжка по участку 1 сорвала всё кольцо")
	_check(_all_charge_in(squad, c), "натиск всех к центру, а не против оттяжки")
	var ok := not squad.is_empty()
	for u in squad:
		ok = ok and float(u._volley.get("range", 1.0)) > 1.0 and bool(u._volley.get("perfect", false))
	_check(ok, "сила рогатки — общая (дальность > 1.0), «Точно!» — враг в зоне участка")
	_check(int(w.stats.get("sling_releases", 0)) == 1, "рогатка посчитана один раз, не по участкам")
	await _frames(1)
	for i in 90:
		w._step(1.0 / 60.0)
	_check(w.combo == 1, "комбо за одно сжатие растёт один раз: %d" % w.combo)


func _test_space() -> void:
	print("— Пробел над кольцом")
	_fresh()
	var c := await _draw_ring()
	if not _is_ring_contract(c):
		_check(false, "кольцо для Пробела начерчено")
		return
	var edge := c.seg_center(3)
	var out_dir := (edge - _center(c)).normalized()
	await _move(edge + out_dir * 6.0)
	await _space(true)
	await _move(edge + out_dir * 60.0)
	var outward := true
	for s in c.seg_count():
		outward = outward and _seg_dir(c, s).dot((c.seg_center(s) - _center(c)).normalized()) > 0.99
	var posts_out := true
	for p in c.posts:
		var at: Vector2 = (p["pos"] as Vector2) - (p["offset"] as Vector2)
		posts_out = posts_out and (p["normal"] as Vector2).dot((at - _center(c)).normalized()) > 0.99
	_check(outward and posts_out, "курсор снаружи — стрелки участков и мест наружу")
	await _move(_center(c) + Vector2(5, 3))
	var inward := true
	for s in c.seg_count():
		inward = inward and _seg_dir(c, s).dot((_center(c) - c.seg_center(s)).normalized()) > 0.99
	_check(inward, "курсор внутри — стрелки к центру")
	await _move(edge + out_dir * 60.0)
	await _space(false)
	var squad := _man(c)
	w.contracts.release(c, 0)
	var ok := not squad.is_empty()
	for u in squad:
		ok = ok and u._charge_dir.dot((u.position - _center(c)).normalized()) > 0.8 \
			and not u._volley.has("cap")
	_check(ok, "круговая оборона: сжатие наружу — все бегут от центра, без предела пробега")
	# надпись по направлению (Игорь 26.09: наружу было написано «Сжать кольцо!»)
	var texts: Array[String] = []
	for p in w.contracts._popups:
		texts.append(String(p.get("text", "")))
	_check(texts.has(ContractField.RING_BURST_LABEL) and not texts.has(ContractField.RING_SQUEEZE_LABEL),
		"наружу — «%s», не «%s»: %s" % [ContractField.RING_BURST_LABEL,
			ContractField.RING_SQUEEZE_LABEL, str(texts)])


func _test_line_unchanged() -> void:
	print("— линия прежняя")
	_fresh()
	await _stroke(_poly([Vector2(760, 60), Vector2(760, 200)]))
	var cs := w.contracts.contracts
	var c: Contract = cs[0] if cs.size() == 1 else null
	_check(c != null and not _is_ring_contract(c), "прямая — обычный договор")
	if c == null:
		return
	var same := true
	for s in c.seg_count():
		same = same and _seg_dir(c, s) == c.dir
	for p in c.posts:
		same = same and p["normal"] == c.dir
	_check(same, "у линии одна стрелка dir на всех участках и местах")
	var squad := _man(c)
	w.contracts.release(c, 0)
	var ok := true
	var n := 0
	for u in squad:
		if u.state != Legionnaire.State.CHARGE:
			continue
		n += 1
		ok = ok and u._charge_dir == c.dir and not u._volley.has("cap") and not u._volley.has("group")
	_check(ok and n > 0 and c.seg_alive(1),
		"щелчок по линии — один участок, по dir, без предела (%d)" % n)
