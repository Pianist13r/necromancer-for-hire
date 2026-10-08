extends SceneTree
##
## Регресс пакета «ввод» (slow/input, 26.09.2026). Игорь: «Зажатое колесо = Пробел»; «когда не
## прямо на линии ты или на кружочке… чтобы было поудобнее. Но это надо рассчитать».
##
##   "$GODOT" --headless --path godot --script res://tests/legion_input_pick_test.gd -- --mute
##
## Ввод — НАСТОЯЩИЙ: Input.parse_input_event в координатах окна при заданном размере окна
## (root.size 1280/1920/2560 — масштаб ×1/×1,5/×2 растяжения canvas_items), тот же путь, что у ОС.
## Проверки:
##  1) зажатое колесо целится как Пробел (готовая линия и черновик), перекрытие Пробел+колесо;
##  2) тики прокрутки при зажатом колесе и сразу после — вид договора не меняют;
##  3) пауза и потеря фокуса с зажатым Пробелом не оставляют прицел «залипшим» (линия чертится);
##  4) площадь захвата: от экрана (×1 — 34 px экрана ловит), по строю над линией, по прогнутому
##     участку, ближайшая линия побеждает, ПКМ — тем же радиусом;
##  5) подсветка того, что возьмут Пробел/колесо/ПКМ.
## Итог «LEGION INPUT PICK: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_input_pick_test.cfg"
const WORLD := Vector2(1280.0, 720.0)
## Больше окна тишины прокрутки (LegionCfg.WHEEL_CLICK_QUIET) с запасом на медленный кадр.
const QUIET_WAIT_MS := 500

var w: LegionWorld
var f: ContractField
var _fails := 0
var _checks := 0
var _scale := 1.0


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
	Input.use_accumulated_input = false
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	f = w.contracts
	await _test_wheel_aims()
	await _test_overlap()
	await _test_scroll_quiet()
	await _test_pause_focus()
	await _test_radius()
	await _test_body_and_bend()
	await _test_nearest()
	await _test_tie_and_band()
	await _test_right_same_radius()
	await _test_hover()
	Campaign.reset()
	print("LEGION INPUT PICK: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Настоящий ввод ──────────────────────────────────────────────────────────

func _set_scale(s: float) -> void:
	_scale = s
	root.size = Vector2i(roundi(WORLD.x * s), roundi(WORLD.y * s))
	await process_frame


func _win(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = _win(p)
	m.global_position = m.position
	Input.parse_input_event(m)
	await process_frame


func _btn(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var b := InputEventMouseButton.new()
	b.position = _win(p)
	b.global_position = b.position
	b.button_index = button
	b.pressed = pressed
	Input.parse_input_event(b)
	await process_frame


func _key(code: Key, pressed: bool) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.keycode = code
	k.pressed = pressed
	Input.parse_input_event(k)
	await process_frame


## Чистое поле: плоская земля без скал (как legion_core_v15_test), полная мана, без волн.
func _fresh() -> void:
	if w.paused:
		w.set_paused(false)
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	f.active = true
	f.human_input = true
	f.mana = f.mana_max
	f.set_kind(LegionCfg.KIND_LABORER)


## Горизонтальный договор, узлы через POINT_STEP, как у штриха мыши (иначе изгиб давки
## нарисовался бы сдвигом двух концов, а не дугой). Стрелка — явно вверх.
func _hline(y: float, x0 := 440.0, x1 := 760.0) -> Contract:
	var pts := PackedVector2Array()
	var x := x0
	while x < x1:
		pts.append(Vector2(x, y))
		x += LegionCfg.POINT_STEP
	pts.append(Vector2(x1, y))
	var c := f.add_contract(pts, 1, false)
	c.set_dir(Vector2.UP)
	return c


func _man(c: Contract) -> void:
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()


## Жмёт «прицел» (Пробел или колесо) в точке at, ведёт мышь вбок-вниз, отпускает. Прицел взял
## договор c, если его стрелка повернулась к курсору.
func _aim_grabs(c: Contract, at: Vector2, wheel := false) -> bool:
	c.set_dir(Vector2.UP)
	await _move(at)
	if wheel:
		await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	else:
		await _key(KEY_SPACE, true)
	var mid := c.point_at(c.length * 0.5)
	await _move(mid + Vector2(90, 90))
	if wheel:
		await _btn(mid + Vector2(90, 90), MOUSE_BUTTON_MIDDLE, false)
	else:
		await _key(KEY_SPACE, false)
	return c.dir.dot(Vector2(1, 1).normalized()) > 0.99


# ── 1. Колесо = Пробел ──────────────────────────────────────────────────────

func _test_wheel_aims() -> void:
	print("— зажатое колесо целится как Пробел")
	await _set_scale(1.5)
	_fresh()
	var c := _hline(360)
	_check(await _aim_grabs(c, c.seg_center(1), true), "колесо над линией: стрелка готового договора за курсором")
	_check(await _aim_grabs(c, c.seg_center(1), false), "Пробел над линией — как раньше")
	# черновик: ЛКМ зажата, чертим, колесо — стрелка черновика за курсором, перо стоит
	await _move(Vector2(400, 200))
	await _btn(Vector2(400, 200), MOUSE_BUTTON_LEFT, true)
	for i in range(1, 11):
		await _move(Vector2(400, 200 + 10 * i))
	var drawn := f._draft_len
	await _btn(Vector2(400, 300), MOUSE_BUTTON_MIDDLE, true)
	await _move(Vector2(500, 380))
	var aimed := f._draft_dir.is_equal_approx(Vector2(100, 130).normalized())
	_check(f.has_draft() and aimed and is_equal_approx(f._draft_len, drawn),
		"колесо при штрихе: стрелка черновика за курсором, перо стоит (%.2f, %.0f→%.0f)" % [
			f._draft_dir.angle(), drawn, f._draft_len])
	await _btn(Vector2(500, 380), MOUSE_BUTTON_MIDDLE, false)
	await _btn(Vector2(500, 380), MOUSE_BUTTON_LEFT, false)
	var made := f.contracts.size() == 2 and f.contracts[1].dir.is_equal_approx(Vector2(100, 130).normalized())
	_check(made, "договор создан со стрелкой колеса")


func _test_overlap() -> void:
	print("— Пробел и колесо вместе")
	_fresh()
	var c := _hline(360)
	c.set_dir(Vector2.UP)
	var at := c.seg_center(2)
	await _move(at)
	await _key(KEY_SPACE, true)
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	await _key(KEY_SPACE, false)
	var mid := c.point_at(c.length * 0.5)
	await _move(mid + Vector2(-80, 80))
	_check(c.dir.is_equal_approx(Vector2(-1, 1).normalized()),
		"отпустил Пробел при зажатом колесе — прицел жив")
	await _btn(mid + Vector2(-80, 80), MOUSE_BUTTON_MIDDLE, false)
	await _move(mid + Vector2(80, 80))
	_check(c.dir.is_equal_approx(Vector2(-1, 1).normalized()), "отпустил и колесо — прицел погас")
	# наоборот: колесо первым, Пробел вторым, колесо отпущено
	await _move(at)
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	await _key(KEY_SPACE, true)
	await _btn(at, MOUSE_BUTTON_MIDDLE, false)
	await _move(mid + Vector2(80, 80))
	_check(c.dir.is_equal_approx(Vector2(1, 1).normalized()), "отпустил колесо при зажатом Пробеле — прицел жив")
	await _key(KEY_SPACE, false)


func _wheel_tick(down: bool) -> void:
	var at := Vector2(640, 600)
	var b := MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
	await _btn(at, b, true)
	await _btn(at, b, false)


func _test_scroll_quiet() -> void:
	print("— тики прокрутки при нажатии колеса")
	_fresh()
	var at := Vector2(640, 600)
	await _move(at)
	OS.delay_msec(QUIET_WAIT_MS)   # прошлая проверка отпустила колесо только что
	await _wheel_tick(true)
	_check(f.current_kind == LegionCfg.KIND_GUARD, "прокрутка по-прежнему меняет вид: подряд → охрана")
	# B-057 (slow/controls-1008): тик в пределах окна ДО нажатия колеса откатывается — нажатие
	# здесь осознанное, после паузы, иначе оно вернуло бы «подряд»
	OS.delay_msec(QUIET_WAIT_MS)
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	await _wheel_tick(true)
	await _wheel_tick(false)
	await _wheel_tick(true)
	_check(f.current_kind == LegionCfg.KIND_GUARD, "колесо зажато: тики вид не меняют")
	OS.delay_msec(400)
	await _wheel_tick(true)
	_check(f.current_kind == LegionCfg.KIND_GUARD, "колесо зажато долго: тики вид не меняют")
	await _btn(at, MOUSE_BUTTON_MIDDLE, false)
	await _wheel_tick(true)
	_check(f.current_kind == LegionCfg.KIND_GUARD, "тик сразу после отпускания колеса вид не меняет")
	OS.delay_msec(QUIET_WAIT_MS)
	await _wheel_tick(true)
	_check(f.current_kind == LegionCfg.KIND_CLERK, "после окна прокрутка снова меняет вид: охрана → аудит")


## Пробел зажат, пауза (или Alt+Tab), отпущен вне игры — прицел не должен залипнуть: иначе
## следующий штрих ЛКМ не чертится (extend уходит в aim_at).
func _test_pause_focus() -> void:
	print("— пауза и потеря фокуса гасят прицел")
	for how: String in ["пауза", "фокус"]:
		_fresh()
		var c := _hline(360)
		await _move(c.seg_center(1))
		await _key(KEY_SPACE, true)
		await _btn(c.seg_center(1), MOUSE_BUTTON_MIDDLE, true)
		if how == "пауза":
			w.set_paused(true)
			await _key(KEY_SPACE, false)       # отпускание на паузе игра не видит
			await _btn(c.seg_center(1), MOUSE_BUTTON_MIDDLE, false)
			w.set_paused(false)
			await process_frame
		else:
			root.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
			await process_frame   # отпускание ушло в другое окно — сюда не придёт
		var before := f.contracts.size()
		var a := Vector2(420, 520)
		await _move(a)
		await _btn(a, MOUSE_BUTTON_LEFT, true)
		for i in range(1, 16):
			await _move(a + Vector2(10 * i, 0))
		await _btn(a + Vector2(150, 0), MOUSE_BUTTON_LEFT, false)
		_check(f.contracts.size() == before + 1, "%s с зажатыми Пробелом и колесом — потом линия чертится (%d → %d)" % [
			how, before, f.contracts.size()])


# ── 4. Площадь захвата ──────────────────────────────────────────────────────

func _test_radius() -> void:
	print("— радиус захвата от экрана")
	for sc: Array in [[1.0, 34.0, true], [1.5, 30.0, true], [1.5, 36.0, true], [2.0, 38.0, true],
			[1.0, 50.0, false], [2.0, 56.0, false]]:
		await _set_scale(float(sc[0]))
		_fresh()
		var c := _hline(360)
		var off := float(sc[1]) / _scale      # px экрана → px мира
		var got := await _aim_grabs(c, c.seg_center(2) + Vector2(0, off))
		_check(got == bool(sc[2]), "×%.1f, Пробел в %d px экрана под пустой линией — %s" % [
			_scale, int(sc[1]), "ловит" if sc[2] else "мимо"])
	await _set_scale(1.5)


func _test_body_and_bend() -> void:
	print("— строй над линией и прогнутый участок")
	await _set_scale(1.5)
	_fresh()
	var c := _hline(400)
	_man(c)
	# туловище скелета: ступни на местах ±8 px от линии, фигура 46 px вверх — курсор на груди
	var chest := c.seg_center(2) + Vector2(0, -LegionCfg.UNIT_BODY_H * 0.6)
	_check(await _aim_grabs(c, chest), "Пробел по груди бойца (28 px мира над линией) берёт договор")
	_fresh()
	var b := _hline(400)
	b.seg_bend[2] = LegionCfg.PRESS_BREAK * 0.95
	b.seg_bend_dir[2] = Vector2.DOWN
	var bent := b.bent_poly(2)
	var tip := bent[bent.size() / 2]
	_check(await _aim_grabs(b, tip + Vector2(0, 4)), "прогнутый давкой участок ловится по нарисованному изгибу")


func _test_nearest() -> void:
	print("— ближайшая линия побеждает")
	await _set_scale(1.5)
	_fresh()
	var a := _hline(340)
	var b := _hline(376)
	var hit := f.pick_segment(Vector2(600, 354))
	_check(not hit.is_empty() and hit["contract"] == a, "между пустыми: 14 px до верхней, 22 до нижней — верхняя")
	hit = f.pick_segment(Vector2(600, 362))
	_check(not hit.is_empty() and hit["contract"] == b, "между пустыми: 22 до верхней, 14 до нижней — нижняя")
	_man(a)
	_man(b)
	hit = f.pick_segment(Vector2(600, 340))
	_check(not hit.is_empty() and hit["contract"] == a, "со строем: курсор на верхней линии — верхняя")
	hit = f.pick_segment(Vector2(600, 376))
	_check(not hit.is_empty() and hit["contract"] == b, "со строем: курсор на нижней линии — нижняя")
	hit = f.pick_segment(Vector2(600, 352))
	# здесь уже грудь бойцов нижней линии, но сама верхняя линия ближе — берём её
	_check(not hit.is_empty() and hit["contract"] == a, "со строем: 12 px под верхней — верхняя")
	hit = f.pick_segment(Vector2(600, 330))
	_check(not hit.is_empty() and hit["contract"] == a, "со строем: 10 px над верхней — верхняя")


## verifier 26.09 (1): ничья «линия в 14 px» против «грудь соседнего строя, 0 + штраф 14» —
## побеждает прямое попадание по линии, в любом порядке создания договоров.
## (2): полоса строя кончается у верха голов (+ запас), радиус к ней не прибавляется.
func _test_tie_and_band() -> void:
	print("— ничья по очкам и высота полосы строя")
	await _set_scale(1.5)
	for upper_first: bool in [true, false]:
		_fresh()
		var a: Contract
		var b: Contract
		if upper_first:
			a = _hline(340)
			b = _hline(376)
		else:
			b = _hline(376)
			a = _hline(340)
		_man(a)
		_man(b)
		var hit := f.pick_segment(Vector2(600, 354))
		_check(not hit.is_empty() and hit["contract"] == a,
			"ничья 14 = 0 + 14: берётся линия, а не строй соседа (верхняя создана %s)" % [
				"первой" if upper_first else "второй"])
	await _set_scale(1.0)
	_fresh()
	var c := _hline(400)
	_man(c)
	var head := c.seg_center(2) + Vector2(0, -50)
	var above := c.seg_center(2) + Vector2(0, -64)
	_check(await _aim_grabs(c, head), "×1: Пробел по голове бойца (50 px над линией) берёт договор")
	_check(not await _aim_grabs(c, above), "×1: Пробел в 64 px над линией (выше голов) — мимо")
	await _move(above)
	await _btn(above, MOUSE_BUTTON_RIGHT, true)
	await _btn(above, MOUSE_BUTTON_RIGHT, false)
	_check(c.seg_alive(2), "×1: ПКМ по пустой земле над строем участок не срывает")
	await _set_scale(2.0)
	_fresh()
	c = _hline(400)
	_man(c)
	_check(f.pick_segment(c.seg_center(2) + Vector2(0, -60)).is_empty(),
		"×2: 60 px мира над линией (120 px экрана) — мимо")
	await _set_scale(1.5)


func _test_right_same_radius() -> void:
	print("— ПКМ берёт тем же радиусом")
	await _set_scale(1.0)
	_fresh()
	var c := _hline(360)
	var at := c.seg_center(1) + Vector2(0, 32)      # 32 px экрана при ×1
	await _move(at)
	await _btn(at, MOUSE_BUTTON_RIGHT, true)
	await _btn(at, MOUSE_BUTTON_RIGHT, false)
	_check(not c.seg_alive(1), "ПКМ в 32 px экрана (×1) расторгает участок")
	await _set_scale(1.5)


func _test_hover() -> void:
	print("— подсветка того, что возьмут")
	await _set_scale(1.5)
	_fresh()
	var c := _hline(360)
	var has := f.has_method("hover_pick")
	await _move(c.seg_center(3) + Vector2(0, 12))
	var h: Dictionary = f.call("hover_pick") if has else {}
	_check(has and h.get("contract") == c and int(h.get("seg", -1)) == 3, "курсор у участка 3 — подсвечен он")
	await _move(Vector2(600, 600))
	h = f.call("hover_pick") if has else {"x": 1}
	_check(h.is_empty(), "курсор вдали — подсветки нет")
	await _move(c.seg_center(0))
	await _key(KEY_SPACE, true)
	await _move(c.seg_center(0) + Vector2(0, 200))
	h = f.call("hover_pick") if has else {}
	_check(h.get("contract") == c, "идёт прицел — подсвечен прицельный договор, хоть курсор и ушёл")
	await _key(KEY_SPACE, false)
	await _move(Vector2(400, 200))
	await _btn(Vector2(400, 200), MOUSE_BUTTON_LEFT, true)
	for i in range(1, 6):
		await _move(Vector2(400, 200 + 30 * i))
	h = f.call("hover_pick") if has else {"x": 1}
	_check(h.is_empty(), "идёт штрих — подсветки договоров нет")
	await _btn(Vector2(400, 350), MOUSE_BUTTON_LEFT, false)
