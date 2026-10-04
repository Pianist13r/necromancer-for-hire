extends SceneTree
## Полный отклик send → _input → frame_post_draw, включая очередь до поля.
## Оконный запуск: --fixed-fps 60 --script res://tests/legion_drawing_input_bench.gd
## После --: --mute [--accumulated native|true|false] [--stalls 16,33,66] [--samples 15].
## native сохраняет политику игры; true/false принудительно включают контрольный режим.
## Задержка _process имитирует длинный кадр; это не измерение мыши ОС или вывода монитора.
## Каждая точка имеет ключ stroke:sample, отметка draw требует совпадения её конца.
## Окно должно сохранять фокус: отменённый жест помечается invalid и повторяется до 3 раз.

const SAVE := "user://legion_drawing_input_bench.cfg"
const DEVICE := 79
var w: LegionWorld
var f: ContractField
var _mode := "native"
var _stalls: Array[int] = [16, 33, 66]
var _samples := 15
var _stroke := 0
var _stall_usec := 0
var _records: Dictionary = {}
var _draw_keys: Array[String] = []
var _missing := 0
var _focus_outs := 0


class Observer:
	extends Node
	var probe: Object

	func _notification(what: int) -> void:
		if what == NOTIFICATION_APPLICATION_FOCUS_OUT and probe != null:
			probe.set("_focus_outs", int(probe.get("_focus_outs")) + 1)

	func _input(event: InputEvent) -> void:
		if event.device != DEVICE or not event is InputEventMouseMotion:
			return
		var key := String(event.get_meta("probe_key", ""))
		var records: Dictionary = probe.get("_records")
		if records.has(key):
			records[key]["emit_usec"] = Time.get_ticks_usec()
			records[key]["emit_frame"] = Engine.get_process_frames()

	func _process(_delta: float) -> void:
		var delay: int = probe.get("_stall_usec")
		if delay > 0:
			OS.delay_usec(delay)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_parse_options()
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	w.start_map("_gray")
	f = w.contracts
	while w.is_ground_loading() or w.phase != LegionWorld.Phase.BATTLE:
		await process_frame
	var observer := Observer.new()
	observer.probe = self
	observer.process_priority = 999999
	root.add_child(observer)
	f.overlay.draw.connect(_on_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	if _mode != "native":
		Input.use_accumulated_input = _mode == "true"
	print("DRAWING_INPUT_SETTINGS ", JSON.stringify({"mode": _mode,
		"accumulated": Input.use_accumulated_input, "samples": _samples,
		"agile": ProjectSettings.get_setting("input_devices/buffering/agile_event_flushing")}))
	for stall_ms: int in _stalls:
		var valid := false
		for attempt in 3:
			valid = await _measure(stall_ms)
			if valid:
				break
		if not valid:
			_missing += 1
	_stall_usec = 0
	observer.queue_free()
	for side in w.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	w.queue_free()
	await process_frame
	await process_frame
	Campaign.reset()
	quit(1 if _missing > 0 else 0)


func _parse_options() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--accumulated":
				_mode = args[i + 1] if args[i + 1] in ["native", "true", "false"] else "native"
			"--samples":
				_samples = clampi(int(args[i + 1]), 3, 20)
			"--stalls":
				_stalls.clear()
				for value in args[i + 1].split(","):
					_stalls.append(clampi(int(value), 0, 200))


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


func _send(at: Vector2, key: String) -> void:
	var event := InputEventMouseMotion.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.relative = Vector2(10, 0)
	event.screen_relative = event.relative
	event.set_meta("probe_key", key)
	_records[key] = {"sent_usec": Time.get_ticks_usec(), "target": at}
	Input.parse_input_event(event)


func _on_draw() -> void:
	if not f.has_draft() or f._draft.is_empty():
		return
	for key: String in _records:
		var record: Dictionary = _records[key]
		if record.has("emit_usec") and not record.has("draw_usec") \
				and f._draft[-1].distance_to(record["target"]) < 0.1:
			record["draw_usec"] = Time.get_ticks_usec()
			record["draw_frame"] = Engine.get_process_frames()
			_draw_keys.append(key)


func _on_post_draw() -> void:
	for key in _draw_keys:
		_records[key]["post_usec"] = Time.get_ticks_usec()
	_draw_keys.clear()


func _measure(stall_ms: int) -> bool:
	_stroke += 1
	var focus_before := _focus_outs
	f.cancel_gestures()
	f.contracts.clear()
	f.mana = f.mana_max
	f.press_consumer = Callable()
	_stall_usec = stall_ms * 1000
	var start := Vector2(1070, 405)
	_button(start, true)
	var keys: Array[String] = []
	for sample in range(1, _samples + 1):
		await process_frame
		var key := "%d:%d" % [_stroke, sample]
		keys.append(key)
		_send(start + Vector2(sample * 8.0 + 2.0, 0), key)
		await process_frame
		await process_frame
		_records[key]["drawing_after"] = f.has_draft()
	var queue: Array[float] = []
	var render: Array[float] = []
	var total: Array[float] = []
	var lag_frames: Array[float] = []
	for key in keys:
		var record: Dictionary = _records[key]
		if record.has("emit_usec"):
			queue.append(float(int(record["emit_usec"]) - int(record["sent_usec"])) / 1000.0)
		if not record.has("post_usec"):
			continue
		total.append(float(int(record["post_usec"]) - int(record["sent_usec"])) / 1000.0)
		render.append(float(int(record["post_usec"]) - int(record["emit_usec"])) / 1000.0)
		lag_frames.append(float(int(record["draw_frame"]) - int(record["emit_frame"])))
	print("DRAWING_INPUT ", JSON.stringify({"mode": _mode, "accumulated": Input.use_accumulated_input,
		"stroke": _stroke, "stall_ms": stall_ms, "sent": keys.size(), "emitted": queue.size(),
		"painted": total.size(), "missing": keys.size() - total.size(),
		"valid": total.size() == keys.size(), "drawing_at_end": f.has_draft(),
		"focus_outs": _focus_outs - focus_before,
		"queue_ms_p50": _pct(queue, 0.5), "queue_ms_p95": _pct(queue, 0.95),
		"emit_to_post_ms_p50": _pct(render, 0.5), "emit_to_post_ms_p95": _pct(render, 0.95),
		"send_to_post_ms_p50": _pct(total, 0.5), "send_to_post_ms_p95": _pct(total, 0.95),
		"emit_to_draw_frames_p50": _pct(lag_frames, 0.5)}))
	_stall_usec = 0
	_button(start + Vector2(_samples * 8.0 + 2.0, 0), false)
	await process_frame
	return total.size() == keys.size()


static func _pct(values: Array[float], q: float) -> float:
	if values.is_empty():
		return -1.0
	var copy := values.duplicate()
	copy.sort()
	return snappedf(copy[mini(copy.size() - 1, int(q * copy.size()))], 0.01)
