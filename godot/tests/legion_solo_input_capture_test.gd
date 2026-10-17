extends SceneTree
## AUTHORED, UNRUN: future isolated/muted 8/6-GiB OwnedJob execution only.
## Same-process native collateral checks do not replace separate-process parity or UI input.

const CAPTURE = preload("res://scripts/dev/solo_input_capture.gd")
const DATE := "2026-10-16"

var checks := 0
var fails := 0
var _fixture_index := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])


func _run() -> void:
	AudioServer.set_bus_mute(0, true)
	_test_detached_cancel()
	var main: LegionMain = await _fixture()
	if main == null:
		quit(1)
		return
	_test_collector_refusals(main.world)
	await _test_no_step_frame(main.world)
	await _dispose(main)
	var off: Dictionary = await _draw_case(false, false)
	var on: Dictionary = await _draw_case(true, false)
	check(not off.is_empty() and not on.is_empty() and off["state"] == on["state"] \
		and off["control"] == on["control"], "native recorder-off/on world and control parity")
	var cancelled: Dictionary = await _draw_case(true, true)
	check(not cancelled.is_empty() and cancelled.get("cancelled", false),
		"separate authored cancel refunds the actual normal draft and commits no line")
	print("Solo input capture native: %d/%d" % [checks - fails, checks])
	quit(0 if fails == 0 else 1)


func _test_detached_cancel() -> void:
	var detached := ContractField.new()
	var old_world := LegionWorld.new()
	detached.world = old_world
	old_world.free()
	detached.cancel()
	check(not detached._drawing, "default-off cancel tolerates already freed field owner")
	detached.free()


func _fixture() -> LegionMain:
	_fixture_index += 1
	var save := "user://solo_capture_native_%d.cfg" % _fixture_index
	Campaign.set_save_path(save)
	Settings.use_dev_save(save)
	Settings.set_difficulty(LegionChallenge.NORMAL)
	Campaign.reset()
	var main := (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await process_frame
	Campaign.use_daily_scope()
	if not LegionRunStore.daily_enter(DATE):
		check(false, "native fresh Daily fixture accepted")
		await _dispose(main)
		return null
	main._endless_daily = true
	var w := main._ensure_world()
	w.hold = true
	main._start_endless_battle(LegionEndless.object_map_id(LegionEndless.daily_seed(DATE), 1, false))
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if w.phase == LegionWorld.Phase.BATTLE and not w.is_ground_loading() \
				and w.get_node_or_null("GroundLoading") == null:
			break
	if w.now != 0.0 or not w.hold or w.is_ground_loading() \
			or w.get_node_or_null("GroundLoading") != null or w.phase != LegionWorld.Phase.BATTLE:
		check(false, "native held-ready fixture")
		await _dispose(main)
		return null
	return main


func _collector(w: LegionWorld) -> Variant:
	w.hold = true
	var recorder: Variant = CAPTURE.new()
	check(recorder.attach(w, {"test": "native UNRUN source"}), "collector actual held fixture attach")
	w.hold = false
	check(recorder.record_hold_release(), "collector explicit hold-release")
	return recorder


func _test_collector_refusals(w: LegionWorld) -> void:
	var recorder: Variant = _collector(w)
	recorder.observe(&"child_entry", &"extend", Vector2(1, 2))
	check(recorder.first_error == "unexpected_child_entry", "child outside a root fails closed")
	recorder.observe(&"frame_enter", 1.0 / 60.0)
	check(recorder.first_error == "unexpected_child_entry",
		"first incomplete reason is permanent")
	recorder = _collector(w)
	recorder.observe(&"local_cmd", {"type": "plot"})
	check(recorder.first_error == "unsupported_local_cmd",
		"plot remains deferred, not silently accepted")
	recorder = _collector(w)
	check(not recorder.root_begin(&"press", Vector2(INF, 0)),
		"nonfinite root coordinate refused")
	recorder = _collector(w)
	recorder.observe(&"frame_enter", NAN)
	check(recorder.first_error == "invalid_frame_enter", "nonfinite actual delta refused")
	recorder = _collector(w)
	recorder.observe(&"step_enter", 0.1)
	check(recorder.first_error == "step_outside_normal_frame",
		"direct step cannot invent a normal frame")
	recorder = _collector(w)
	recorder.observe(&"frame_enter", 0.1)
	recorder.observe(&"real_tick", 0.5)
	recorder.observe(&"step_enter", 0.1)
	check(recorder.first_error == "step_outside_normal_frame",
		"step dt must equal real delta times scale")
	recorder = _collector(w)
	recorder.observe(&"frame_enter", 0.1)
	recorder.observe(&"real_tick", 1.0)
	recorder.observe(&"step_enter", 0.1)
	recorder.observe(&"step_exit", 0.2)
	check(recorder.first_error == "step_exit_without_entry", "paired step dt mismatch refused")
	recorder = _collector(w)
	recorder.observe(&"frame_enter", 0.1)
	recorder.observe(&"real_tick", 1.0)
	recorder.observe(&"frame_exit", 0.2)
	check(recorder.first_error == "invalid_frame_exit", "paired frame delta mismatch refused")
	recorder = _collector(w)
	recorder.frames = CAPTURE.MAX_FRAMES
	recorder.observe(&"frame_enter", 0.1)
	check(recorder.first_error == "frame_cap", "frame overflow incomplete")
	recorder = _collector(w)
	recorder.entry_count = CAPTURE.MAX_ENTRIES
	recorder.observe(&"frame_enter", 0.1)
	check(recorder.first_error == "entry_or_byte_cap", "entry overflow incomplete")
	recorder = _collector(w)
	recorder._estimated_bytes = CAPTURE.MAX_BYTES
	recorder.observe(&"frame_enter", 0.1)
	check(recorder.first_error == "entry_or_byte_cap", "byte overflow incomplete")
	recorder = _collector(w)
	w.contracts._pointer += Vector2.ONE
	check(not recorder.root_begin(&"press", Vector2.ZERO)
		and recorder.first_error == "unknown_between_boundaries", "control tail drift captured")
	w.contracts._pointer -= Vector2.ONE
	recorder = _collector(w)
	var report: Dictionary = recorder.finish_episode(0, 0)
	check(not report["verified"] and not report["score_eligible"] and not report["replay_ready"],
		"episode flags never confer replay or score trust")
	check(not recorder.persist("user://uncreated_solo_capture_test/child", report)
		and not report["episode_complete"] and not report["complete"],
		"write failure invalidates an already computed report")
	w.hold = true


func _test_no_step_frame(w: LegionWorld) -> void:
	# Controlled branch fixture, not a claim that the plain diagnostic stroke naturally hit-stops.
	w._hitstop_left = 0.05
	var recorder: Variant = _collector(w)
	w.qa_solo_capture = Callable(recorder, "observe")
	await process_frame
	var report: Dictionary = recorder.finish_episode(0, 1)
	check(report["episode_complete"] and recorder.frames == 1 and recorder.steps == 0 \
		and w.now == 0.0 and w._hitstop_left < 0.05,
		"actual normal hit-stop frame records real time and zero simulation steps")
	w.qa_solo_capture = Callable()
	w.hold = true


func _draw_case(enabled: bool, cancel_case: bool) -> Dictionary:
	var main: LegionMain = await _fixture()
	if main == null:
		return {}
	var w := main.world
	var lines: Array = w.map.get("bot_lines", [])
	if lines.is_empty():
		check(false, "fixed line0 exists, no fallback")
		await _dispose(main)
		return {}
	var a := Vector2(float(lines[0]["a"][0]), float(lines[0]["a"][1]))
	var b := Vector2(float(lines[0]["b"][0]), float(lines[0]["b"][1]))
	var recorder: Variant = null
	if enabled:
		recorder = CAPTURE.new()
		check(recorder.attach(w, {"test": "authored native episode"}), "native episode attached held")
		w.qa_solo_capture = Callable(recorder, "observe")
	w.hold = false
	if enabled:
		check(recorder.record_hold_release(), "native episode declared hold-release")
	var cost := 0.0
	var incremental := false
	var refund := false
	for index: int in 12:
		await process_frame
		match index:
			0:
				_action(w, recorder, &"press", a)
			1:
				var mana := w.contracts.mana
				_action(w, recorder, &"move", a.lerp(b, 0.5))
				incremental = w.contracts._drawing and w.contracts._draft.size() >= 2 \
					and w.contracts._draft_cost > 0 and w.contracts.mana < mana
			2:
				_action(w, recorder, &"move", b)
				cost = w.contracts._draft_cost
			3:
				var mana := w.contracts.mana
				_action(w, recorder, &"authored_cancel" if cancel_case else &"release", b)
				refund = w.contracts.mana == minf(w.contracts.mana_max, mana + cost)
	check(incremental, "intermediate draft spends mana before finish")
	if enabled:
		var report: Dictionary = recorder.finish_episode(4, 12)
		check(report["episode_complete"], "native sequence and frame boundaries captured")
		var children: Array = []
		for row: Dictionary in recorder._entries.slice(0, recorder.entry_count):
			if row.get("event") == &"child_entry":
				children.append(row["name"])
		var expected: Array = [&"cancel", &"begin", &"cancel", &"extend", &"extend"]
		if cancel_case:
			expected.append(&"cancel")
		else:
			expected.append_array([&"extend", &"finish"])
		check(children == expected,
			"actual nested child entries observed without duplicate action execution")
	w.qa_solo_capture = Callable()
	w.hold = true
	var state := LegionInputReplay.state_bytes(w)
	var projection: Variant = CAPTURE.new()
	projection.world = w
	var control := var_to_bytes(projection._control())
	var no_line := w.contracts.contracts.is_empty() and not w.contracts._drawing
	check(no_line if cancel_case else w.contracts.contracts.size() == 1,
		"authored fixed stroke has its required normal finish/cancel outcome")
	await _dispose(main)
	return {"state": state, "control": control, "cancelled": cancel_case and refund and no_line}


func _action(w: LegionWorld, recorder: Variant, action: StringName, at: Vector2) -> void:
	if recorder != null and not recorder.root_begin(action, at):
		return
	w.contracts._pointer = at
	w.contracts._stack = false
	match action:
		&"press":
			w.contracts._press(at)
		&"move":
			if w.contracts._pressing:
				w.contracts._press_move(at)
			elif w.contracts._drawing:
				w.contracts.extend(at)
		&"release":
			w.contracts._release(at)
		&"authored_cancel":
			w.contracts.cancel()
	if recorder != null:
		recorder.root_end()


func _dispose(main: LegionMain) -> void:
	if main != null and is_instance_valid(main):
		if main.world != null:
			main.world.qa_solo_capture = Callable()
			main.world.hold = true
		main.queue_free()
		await process_frame
