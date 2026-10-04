extends SceneTree
## Настоящий ввод: быстрый пакет движений, точка отпускания и ограничения штриха.
## Не отключать накопление в тесте: это обязанность поля, иначе регресс маскируется.

const SAVE := "user://legion_drawing_input_test.cfg"
const DEVICE := 78
const CENTER := Vector2(600.0, 360.0)
const START := Vector2(200.0, 200.0)
var w: LegionWorld
var f: ContractField
var _checks := 0
var _fails := 0
var _taps := 0
var _sent: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  ok   ", label)
	else:
		_fails += 1
		print("  FAIL ", label)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_test_input_lifetime()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	w.start_map("_gray")
	f = w.contracts
	f.tap.connect(func(_p: Vector2) -> void: _taps += 1)
	_check(not Input.use_accumulated_input, "поле отключило накопление ДО нажатия ЛКМ")
	_test_bursts()
	_test_release()
	_test_arbitration()
	_test_cancel()
	_test_limits()
	_test_network()
	for side in w.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	w.queue_free()
	await process_frame
	await process_frame
	Campaign.reset()
	print("LEGION DRAWING INPUT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_input_lifetime() -> void:
	for previous: bool in [true, false]:
		Input.use_accumulated_input = previous
		var first := ContractField.new()
		var second := ContractField.new()
		root.add_child(first)
		root.add_child(second)
		_check(not Input.use_accumulated_input, "два поля отключают накопление (было %s)" % previous)
		root.remove_child(first)
		first.free()
		_check(not Input.use_accumulated_input, "удаление первого поля оставляет ввод точным")
		root.remove_child(second)
		second.free()
		_check(Input.use_accumulated_input == previous, "последнее поле вернуло исходное %s" % previous)
	Input.use_accumulated_input = true


func _fresh() -> void:
	Input.flush_buffered_events()
	w.set_paused(false)
	w.net_mode = false
	w.net_applying = false
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	f.cancel_gestures()
	f.setup(w)
	f.active = true
	f.human_input = true
	f.press_consumer = Callable()
	_taps = 0
	_sent.clear()


func _button(at: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _motion(at: Vector2, relative := Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.relative = relative
	event.screen_relative = relative
	Input.parse_input_event(event)


func _key(down: bool) -> void:
	var event := InputEventKey.new()
	event.device = DEVICE
	event.physical_keycode = KEY_SPACE
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _last() -> Contract:
	return f.contracts[-1] if not f.contracts.is_empty() else null


func _line_start() -> void:
	_button(START, true)
	for x: float in [30.0, 60.0, 90.0, 120.0]:
		_motion(START + Vector2(x, 0), Vector2(30, 0))
		Input.flush_buffered_events()


func _dense(vertices: PackedVector2Array, step := 8.0) -> PackedVector2Array:
	var points := PackedVector2Array([vertices[0]])
	for i in range(1, vertices.size()):
		var n := maxi(1, ceili(vertices[i - 1].distance_to(vertices[i]) / step))
		for k in range(1, n + 1):
			points.append(vertices[i - 1].lerp(vertices[i], float(k) / n))
	return points


func _triangle() -> PackedVector2Array:
	var corners := PackedVector2Array()
	for i in 4:
		corners.append(CENTER + Vector2.from_angle(-PI * 0.5 + TAU * (i % 3) / 3.0) * 80.0)
	return _dense(corners)


func _eight(samples := 80) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in samples + 1:
		var t := PI * 0.5 + TAU * float(i) / samples
		points.append(CENTER + Vector2(85.0 * sin(t), 130.0 * sin(t) * cos(t)))
	return points


func _burst(points: PackedVector2Array) -> void:
	_button(points[0], true)
	for i in range(1, points.size()):
		_motion(points[i], points[i] - points[i - 1])


func _test_bursts() -> void:
	for entry: Array in [[_triangle(), ContractShape.TRIANGLE], [_eight(), ContractShape.EIGHT]]:
		_fresh()
		var points: PackedVector2Array = entry[0]
		var kind: StringName = entry[1]
		_check(ContractShape.classify(points) == kind, "контрольная траектория %s распознаётся" % kind)
		_burst(points)
		_check(f._draft.size() >= 16, "%s: пакет мыши принят до flush, повороты сохранены" % kind)
		Input.flush_buffered_events()
		_button(points[-1], false)
		var c := _last()
		_check(c != null and c.figure == kind, "%s: настоящий быстрый ввод создал нужную фигуру" % kind)


func _test_release() -> void:
	_fresh()
	_line_start()
	_button(START + Vector2(160, 0), false)
	var c := _last()
	_check(c != null and c.points[-1].distance_to(START + Vector2(160, 0)) < 0.1,
		"отпускание сохраняет последние 40 px после движения")
	_check(c != null and is_equal_approx(f.mana_max - f.mana, 160.0 * c.mana_per_px()),
		"последние 40 px оплачены по обычной цене")
	_fresh()
	_button(START, true)
	_button(START + Vector2(160, 0), false)
	c = _last()
	_check(c != null and c.points[-1].distance_to(START + Vector2(160, 0)) < 0.1 and _taps == 0,
		"drag только press/release проходит порог, создаёт линию и не становится tap")


func _test_arbitration() -> void:
	_fresh()
	_button(START, true)
	_button(START + Vector2(3, 0), false)
	_check(_taps == 1 and f.contracts.is_empty() and is_equal_approx(f.mana, f.mana_max),
		"обычный щелчок остаётся tap без договора и траты")
	_fresh()
	f.press_consumer = func(_p: Vector2) -> bool: return true
	_button(START, true)
	_button(START + Vector2(160, 0), false)
	_check(_taps == 0 and f.contracts.is_empty() and not f.has_draft(),
		"consumer съел нажатие: далёкий release не создаёт хвост")
	_fresh()
	_line_start()
	_key(true)
	_button(START + Vector2(160, 100), false)
	var c := _last()
	_check(c != null and c.points[-1].distance_to(START + Vector2(120, 0)) < 0.1,
		"release под Пробелом целится, не дописывает ложный хвост")
	_key(false)
	_fresh()
	_line_start()
	_key(true)
	_key(false)
	_button(START + Vector2(160, 100), false)
	c = _last()
	_check(c != null and c.points[-1].distance_to(START + Vector2(120, 0)) < 0.1,
		"после Пробела далёкий release соблюдает возврат пера")


func _test_cancel() -> void:
	for started: bool in [true, false]:
		_fresh()
		if started:
			_line_start()
		else:
			_button(START, true)
		f.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
		_button(START + Vector2(160, 0), false)
		_check(not f.has_draft() and f.contracts.is_empty() and _taps == 0 \
				and is_equal_approx(f.mana, f.mana_max),
			"потеря фокуса: release не оживляет отменённый жест (%s)" % started)
	_fresh()
	_line_start()
	w.set_paused(true)
	w.set_paused(false)
	_button(START + Vector2(160, 0), false)
	_check(f.contracts.is_empty() and not f.has_draft() and is_equal_approx(f.mana, f.mana_max),
		"пауза снимает штрих, позднее отпускание не создаёт договора")


func _test_limits() -> void:
	_fresh()
	w.terrain.setup({"rocks": [[[350, 150], [380, 150], [380, 250], [350, 250]]]})
	_line_start()
	_button(START + Vector2(200, 0), false)
	var c := _last()
	_check(c != null and c.points[-1].x < 350.0 and c.points[-1].x >= 340.0,
		"последняя точка обрезана перед стеной")
	_check(c != null and not w.terrain.is_rock(c.points[-1]), "release не проводит линию через скалу")
	_check(f.wall_bumps > 0, "обрезание хвоста о стену даёт обратную связь")
	for endpoint: Vector2 in [Vector2(344, 200), Vector2(400, 200)]:
		_fresh()
		w.terrain.setup({"rocks": [[[350, 150], [380, 150], [380, 250], [350, 250]]]})
		f._wall_fx.clear()
		f._wall_ms = -1000000
		var bumps := f.wall_bumps
		_button(Vector2(300, 200), true)
		_motion(Vector2(320, 200))
		_button(endpoint, false)
		_check(f.contracts.is_empty() and f._wall_fx.size() == 1 \
				and f._wall_fx[0]["label"] == IntuitCfg.NARROW_LABEL,
			"короткий жест у стены сохраняет совет вести наискось: %s" % endpoint)
		_check(f.wall_bumps == bumps + 1, "уточнение причины не дублирует вспышку")
	_fresh()
	w.terrain.setup({"rocks": [[[350, 150], [380, 150], [380, 250], [350, 250]]]})
	f._wall_ms = -1000000
	f._wall_fx.clear()
	_button(Vector2(300, 200), true)
	_motion(Vector2(400, 200))
	f._wall_ms -= 600
	f._wall_fx[0]["ms"] -= 600
	f._draw_wall_fx()
	_check(f._wall_fx.is_empty(), "вспышка столкновения погасла раньше cooldown")
	_button(Vector2(400, 200), false)
	_check(f.contracts.is_empty() and f._wall_fx.size() == 1 \
			and f._wall_fx[0]["label"] == IntuitCfg.NARROW_LABEL,
		"позднее отпускание сохраняет совет после погасшей вспышки")
	_fresh()
	_line_start()
	var mana_before := 1.0
	f.mana = mana_before
	_button(START + Vector2(160, 0), false)
	c = _last()
	_check(c != null and c.points[-1].distance_to(START + Vector2(120, 0)) < 0.1 \
			and is_equal_approx(f.mana, mana_before),
		"при малой мане неподъёмный хвост не дописан и не списан")


func _test_network() -> void:
	_fresh()
	w.net_mode = true
	w.net_out = func(cmd: Dictionary) -> void: _sent.append(cmd)
	var points := _eight(320)
	_burst(points)
	Input.flush_buffered_events()
	_check(f.has_draft() and f._draft.size() >= 16, "плотный сетевой штрих не схлопнулся в пакет")
	_button(points[-1], false)
	_check(_sent.size() == 1 and f.contracts.is_empty() and is_equal_approx(f.mana, f.mana_max),
		"рука сети отправила одну команду без изменения мира и маны")
	if _sent.size() != 1:
		return
	var cmd: Dictionary = _sent[0].duplicate()
	var pts: PackedVector2Array = cmd["pts"]
	_check(pts.size() <= PvpCmd.STROKE_MAX_PTS and pts[0].distance_to(points[0]) < 0.1 \
			and pts[-1].distance_to(points[-1]) < LegionCfg.POINT_STEP,
		"321 сырое событие: команда ≤160 точек сохраняет конец в пределах POINT_STEP")
	var circle := PackedVector2Array()
	for i in 322:
		circle.append(CENTER + Vector2.from_angle(TAU * float(i) / 321.0) * 110.0)
	var bounded := PvpCmd.stroke_points(circle, w.world_size)
	_check(bounded.size() == PvpCmd.STROKE_MAX_PTS and bounded[0] == circle[0] \
			and bounded[-1] == circle[-1], "сетевое прореживание до 160 точек сохраняет точные концы")
	var first := w.net_apply(0, cmd)
	var c := _last()
	_check(bool(first.get("ok", false)) and c != null and c.figure == ContractShape.EIGHT,
		"сетевой replay плотной руки создал восьмёрку")
	if c == null:
		return
	var actual_points := c.points.duplicate()
	var actual_cost := f.mana_max - f.mana
	_fresh()
	var second := w.command(0, cmd)
	c = _last()
	_check(bool(second.get("ok", false)) and c != null and c.points == actual_points \
			and is_equal_approx(f.mana_max - f.mana, actual_cost),
		"сетевое и обычное применение одной команды совпадают по геометрии и цене")
