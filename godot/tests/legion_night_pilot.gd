extends SceneTree
## Исполнитель ограниченного JSON-сценария. Правила проверки живут в game_runner.py.

const SAVE := "user://legion_night_pilot.cfg"
const DT := 1.0 / 60.0
const DEVICE := 79

var world: LegionWorld
var _events: Array[Dictionary] = []
var _trace: Array[Dictionary] = []
var _case: Dictionary = {}
var _fault_skip_cancel := false


func _initialize() -> void:
	_run.call_deferred()


func _finish(ok: bool, reason := "") -> void:
	print("NIGHT_PILOT_JSON:" + JSON.stringify({
		"ok": ok, "reason": reason, "trace": _trace, "events": _events,
	}))
	quit(0 if ok else 1)


func _run() -> void:
	var case_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			case_path = arg.trim_prefix("--case=")
		elif arg == "--fault=skip_cancel":
			_fault_skip_cancel = true
	if case_path.is_empty():
		_finish(false, "missing_case")
		return
	var raw := FileAccess.get_file_as_string(case_path)
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary:
		_finish(false, "invalid_json")
		return
	_case = parsed
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	world = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	world.embedded = true
	root.add_child(world)
	await process_frame
	world.set_process(false)
	world.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	world._base_seed = int(_case.get("seed", 1))
	world.start_map(String(_case.get("map", "_gray")))
	world.contracts.tap.connect(func(_p: Vector2) -> void: _events.append({"event": "tap"}))
	_trace.append(_state("initial", -1))
	var ops: Array = _case.get("ops", [])
	for i in ops.size():
		var op: Dictionary = ops[i]
		_execute(op)
		_trace.append(_state(String(op["op"]), i))
	world.set_paused(false)
	world.queue_free()
	await process_frame
	Campaign.reset()
	_finish(true)


func _state(name: String, index: int) -> Dictionary:
	var field := world.contracts
	return {
		"op": name, "index": index, "now": snappedf(world.now, 0.000001),
		"phase": world.phase, "paused": world.paused, "tree_paused": paused,
		"draft": field.has_draft(), "pending_press": field._pressing,
		"draft_points": field._draft.size(),
		"contracts": field.contracts.size(), "mana": snappedf(field.mana, 0.000001),
		"mana_max": snappedf(field.mana_max, 0.000001),
		"event_count": _events.size(),
	}


func _execute(op: Dictionary) -> void:
	var name := String(op["op"])
	if name == "press" or name == "release":
		_button(Vector2(float(op["x"]), float(op["y"])), name == "press")
	elif name == "move":
		_motion(Vector2(float(op["x"]), float(op["y"])))
	elif name == "cancel":
		if not _fault_skip_cancel:
			_key(KEY_ESCAPE, true)
			_key(KEY_ESCAPE, false)
	elif name == "focus_out":
		# Headless намеренно подавляет уведомление ОС; вызываем тот же обработчик мира.
		world.focus_lost()
	elif name == "pause":
		world.set_paused(true)
	elif name == "resume":
		world.set_paused(false)
	elif name == "restart":
		world.restart()
	elif name == "step":
		if not world.paused:
			for frame in int(op["frames"]):
				# Тот же кадр, что у активного узла: real_tick, hit-stop, затем tick мира.
				world._process(DT)


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


func _motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.device = DEVICE
	event.physical_keycode = code
	event.keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()
