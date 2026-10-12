extends SceneTree
## Корпус одного жеста при разных скоростях мыши. Углы не подставляются в события:
## мышь семплирует контур по расстоянию и может перескочить через вершину.

const SAVE := "user://legion_figures_usability_test.cfg"
const CENTER := Vector2(600, 360)
const KINDS: Array[StringName] = [&"ring", &"eight", &"triangle", &"square", &"pentagon",
	&"d_shape"]
const STEPS := [2.0, 6.0, 14.0, 18.0, 26.0, 30.0]
var w: LegionWorld
var f: ContractField
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	w.start_map("_gray")
	f = w.contracts
	for kind in KINDS:
		for step: float in STEPS:
			var correct := 0
			var raw_correct := 0
			var got := {}
			for trial in 24:
				var scale := [0.7, 1.0, 1.2][trial % 3] as float
				var pts := trace(kind, step, scale, 0.071 * trial, 20.0, 0.137 * trial)
				raw_correct += int(ContractShape.classify(pts) == kind)
				_fresh()
				var c := _draw(pts)
				var actual := c.figure if c != null else &"none"
				if c != null and c.ring:
					actual = &"ring"
				correct += int(actual == kind)
				got[actual] = int(got.get(actual, 0)) + 1
			_check(correct >= 22, "%s step %d: input %d/24, raw %d/24 %s" %
				[kind, step, correct, raw_correct, got])
	_test_lines()
	for side in w.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	w.queue_free()
	await process_frame
	await process_frame
	Campaign.reset()
	print("LEGION FIGURES USABILITY: %d/%d OK" % [_checks - _fails, _checks])
	quit(int(_fails > 0))


func _fresh() -> void:
	Input.flush_buffered_events()
	f.cancel_gestures()
	f.setup(w)
	f.active = true
	f.human_input = true
	f.press_consumer = Callable()
	f.mana = f.mana_max
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})


func _button(at: Vector2, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = 79
	ev.position = root.get_final_transform() * at
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	ev.pressed = down
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _draw(pts: PackedVector2Array) -> Contract:
	var before := f._next_id
	_button(pts[0], true)
	for i in range(1, pts.size() - 1):
		var ev := InputEventMouseMotion.new()
		ev.device = 79
		ev.position = root.get_final_transform() * pts[i]
		ev.global_position = ev.position
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
		ev.relative = pts[i] - pts[i - 1]
		ev.screen_relative = ev.relative
		Input.parse_input_event(ev)
	Input.flush_buffered_events()
	_button(pts[-1], false)
	return f.contracts[-1] if f._next_id > before else null


static func trace(kind: StringName, step: float, scale: float, start: float, gap: float,
		rotation: float) -> PackedVector2Array:
	var loop := PackedVector2Array()
	if kind in [&"triangle", &"square", &"pentagon"]:
		var n := 3 if kind == &"triangle" else (4 if kind == &"square" else 5)
		for i in n:
			var a := TAU * i / n
			loop.append(Vector2.from_angle(a) * 78.0)
	elif kind == &"d_shape":
		loop.append(Vector2(0, -78))
		for i in 81:
			loop.append(Vector2.from_angle(-PI * 0.5 + PI * i / 80.0) * 78.0)
	else:
		for i in 160:
			var a := TAU * i / 160.0
			loop.append(Vector2(88.0 * sin(a), 70.0 * sin(a) * cos(a))
				if kind == &"eight" else Vector2.from_angle(a) * 78.0)
	loop.append(loop[0])
	var length := ContractShape.poly_len(loop)
	var out := PackedVector2Array()
	var count := maxi(2, ceili((length * scale - gap) / step))
	for i in count + 1:
		var at := fposmod(start * length + (length - gap / scale) * i / count, length)
		var p := _at(loop, at)
		# Небольшой плавный прогиб рёбер и несовпадение осей руки.
		p = Vector2(p.x * 1.06, p.y * 0.96)
		out.append(CENTER + p.rotated(rotation) * scale)
	return out


static func _at(path: PackedVector2Array, at: float) -> Vector2:
	for i in range(1, path.size()):
		var ln := path[i - 1].distance_to(path[i])
		if at <= ln:
			return path[i - 1].lerp(path[i], at / ln) if ln > 0 else path[i]
		at -= ln
	return path[-1]


func _test_lines() -> void:
	var controls: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(200, 220), Vector2(580, 220)]),
		PackedVector2Array([Vector2(200, 220), Vector2(200, 360), Vector2(420, 360)]),
		PackedVector2Array([Vector2(200, 220), Vector2(380, 220), Vector2(200, 360), Vector2(380, 360)]),
		PackedVector2Array([Vector2(200, 220), Vector2(280, 360), Vector2(360, 220), Vector2(440, 360)]),
		PackedVector2Array([Vector2(200, 220), Vector2(340, 220), Vector2(340, 340), Vector2(210, 340)]),
	]
	for i in controls.size():
		_fresh()
		var c := _draw(controls[i])
		_check(c != null and not c.ring and c.figure == &"", "open line %d stays position" % i)


