extends RefCounted
## Passive, bounded diagnostic observations. Never commands, restores or changes the world.

const MAX_FRAMES := 120
const MAX_ENTRIES := 1024
const MAX_BYTES := 16 * 1024 * 1024
const CONTROL := ["current_kind", "_stack", "_pointer", "_drawing", "_draft",
	"_draft_len", "_draft_cost", "_draft_dir", "_draft_ring", "_draft_fig", "_draft_shape",
	"_pen_sample", "_begin_raw", "_draft_block", "_pen_wait", "_pressing", "_press_pos",
	"_press_pts", "_press_eaten", "active", "human_input", "_draft_net", "_space",
	"_aim_held", "_grab", "_slinging"]
const ROOTS := [&"press", &"move", &"release", &"authored_cancel"]
const CHILDREN := [&"begin", &"extend", &"finish", &"cancel"]

var world: LegionWorld
var identity: Dictionary = {}
var first_error := ""
var first_error_seq := -1
var entry_count := 0
var frames := 0
var steps := 0
var root_seq := -1
var root_count := 0
var child_order := 0
var frame_open := false
var step_open := false
var released := false
var _busy := false
var _frame_steps := 0
var _real_ticks := 0
var _frame_delta := 0.0
var _frame_scale := 0.0
var _step_dt := 0.0
var _estimated_bytes := 65536
var _entries: Array = []
var _tail := PackedByteArray()
var _initial := PackedByteArray()
var _fixed_config := PackedByteArray()


func attach(w: LegionWorld, source: Dictionary) -> bool:
	world = w
	identity = source.duplicate(true)
	_entries.resize(MAX_ENTRIES)
	if w.qa_solo_capture.is_valid() or w.now != 0.0 or not w.hold or not _supported():
		invalidate("unsupported_attach")
		return false
	_fixed_config = var_to_bytes(_config())
	_initial = LegionInputReplay.state_bytes(world)
	if _initial.is_empty():
		invalidate("empty_initial_state")
		return false
	_checkpoint(&"attached_held", false)
	return first_error == ""


## Driver makes the one declared hold change; sink only observes its before/after states.
func record_hold_release() -> bool:
	if released or world == null or world.hold or world.now != 0.0 or frame_open:
		invalidate("invalid_hold_release_boundary")
		return false
	released = true
	_checkpoint(&"diagnostic_hold_released", false)
	return first_error == ""


func root_begin(action: StringName, at: Vector2) -> bool:
	if first_error != "":
		return false
	if not released or root_seq != -1 or frame_open or not action in ROOTS or not at.is_finite():
		invalidate("unsupported_root_or_phase")
		return false
	_checkpoint(&"root_pre", true)
	if first_error != "":
		return false
	root_seq = entry_count
	root_count += 1
	child_order = 0
	_append({"event": &"root_begin", "action": action, "at": at,
		"parent_root_seq": root_seq})
	return first_error == ""


func root_end() -> void:
	if first_error != "":
		return
	if root_seq == -1 or frame_open:
		invalidate("root_end_without_root")
		return
	_checkpoint(&"root_post", false)
	_append({"event": &"root_end", "parent_root_seq": root_seq,
		"child_entries": child_order, "child_outcomes_captured": false})
	root_seq = -1


## Child path only buffers entries. Snapshot work is restricted to explicit boundaries.
func observe(event: StringName, argument: Variant = null, extra: Variant = null) -> void:
	if first_error != "":
		return
	if _busy:
		invalidate("sink_reentrancy")
		return
	_busy = true
	match event:
		&"child_entry":
			_child(argument, extra)
		&"local_cmd":
			_append({"event": &"unsupported_local_cmd", "payload": argument})
			invalidate("unsupported_local_cmd")
		&"frame_enter":
			_frame_enter(argument)
		&"real_tick":
			if not frame_open or step_open or not _finite_nonnegative(argument):
				invalidate("invalid_real_tick")
			else:
				_real_ticks += 1
				_frame_scale = float(argument)
				_append({"event": event, "scale": argument})
		&"step_enter":
			if not frame_open or step_open or _real_ticks != 1 \
					or not _finite_nonnegative(argument) \
					or float(argument) != _frame_delta * _frame_scale:
				invalidate("step_outside_normal_frame")
			else:
				step_open = true
				_step_dt = float(argument)
				steps += 1
				_frame_steps += 1
				_append({"event": event, "dt": argument, "step": steps})
		&"step_exit":
			if not step_open or not _finite_nonnegative(argument) or float(argument) != _step_dt:
				invalidate("step_exit_without_entry")
			else:
				_append({"event": event, "dt": argument, "step": steps})
				step_open = false
		&"frame_exit":
			_frame_exit(argument)
		_:
			invalidate("unsupported_sink_event")
	_busy = false


func _child(name: Variant, at: Variant) -> void:
	if root_seq == -1 or frame_open or not name in CHILDREN \
			or (at != null and (not at is Vector2 or not at.is_finite())):
		invalidate("unexpected_child_entry")
		return
	_append({"event": &"child_entry", "name": name, "at": at,
		"parent_root_seq": root_seq, "child_entry_order": child_order,
		"child_outcomes_captured": false})
	child_order += 1


func _frame_enter(delta: Variant) -> void:
	if not released or frame_open or root_seq != -1 or not _finite_nonnegative(delta):
		invalidate("invalid_frame_enter")
		return
	if frames >= MAX_FRAMES:
		invalidate("frame_cap")
		return
	_checkpoint(&"frame_pre", true)
	frame_open = true
	frames += 1
	_frame_steps = 0
	_real_ticks = 0
	_frame_delta = float(delta)
	_append({"event": &"frame_enter", "delta": delta,
		"simulation_enabled": world._battle_simulation_enabled()})


func _frame_exit(delta: Variant) -> void:
	if not frame_open or step_open or root_seq != -1 or not _finite_nonnegative(delta) \
			or float(delta) != _frame_delta or _frame_steps > 1 or _real_ticks != 1:
		invalidate("invalid_frame_exit")
		return
	_append({"event": &"frame_exit", "delta": delta, "actual_steps": _frame_steps,
		"no_step": _frame_steps == 0})
	_checkpoint(&"frame_post", false)
	frame_open = false


func _checkpoint(phase: StringName, compare_tail: bool) -> void:
	if not _supported() or var_to_bytes(_config()) != _fixed_config:
		invalidate("unsupported_lifecycle_config_or_modifier")
		return
	var state := LegionInputReplay.state_bytes(world)
	var control := var_to_bytes(_control())
	var combined := var_to_bytes([state, control])
	if state.is_empty():
		invalidate("empty_boundary_state")
		return
	if compare_tail and combined != _tail:
		_append({"event": &"unknown_between_boundaries", "phase": phase,
			"observed_state": state, "observed_control": control, "expected_tail_sha256": _sha(_tail)})
		invalidate("unknown_between_boundaries")
		return
	_append({"event": &"checkpoint", "phase": phase, "parent_root_seq": root_seq,
		"state": state, "state_sha256": _sha(state), "control": control,
		"control_sha256": _sha(control)})
	_tail = combined


func _control() -> Dictionary:
	var field: Dictionary = {}
	for key: String in CONTROL:
		field[key] = world.contracts.get(key)
	return {"field": field, "hold": world.hold, "paused": world.paused,
		"phase": int(world.phase), "net_mode": world.net_mode,
		"bot": world.bot != null, "tutorial": world.tutorial != null,
		"mana": world.contracts.mana, "config": _config(),
		"use_accumulated_input": Input.use_accumulated_input}


func _config() -> Dictionary:
	return {"scope": Campaign._scope, "date": LegionRunStore.endless_daily_date(),
		"k": LegionRunStore.endless_k(true), "map": world.map_id,
		"difficulty": world.difficulty, "difficulty_lock": LegionRunStore.run_difficulty(true),
		"open_object": LegionRunStore.daily_open_object(), "carry": world.carry_items,
		"campaign": world.in_campaign, "preparation": world.battle_preparation.duplicate(true),
		"mods": world.mods.duplicate(true), "base_seed": str(world._base_seed),
		"dev": world.dev.duplicate(true), "args": world.args.duplicate(true),
		"generator": ProcGen.VERSION, "run_seed": str(LegionRunStore.endless_seed(true))}


func _supported() -> bool:
	if world == null or not is_instance_valid(world) or world.contracts == null:
		return false
	var field := world.contracts
	return not world.net_mode and not world.pvp and world.bot == null and world.tutorial == null \
		and world.phase == LegionWorld.Phase.BATTLE and not world.paused \
		and not world.is_ground_loading() and Campaign.is_daily_scope() \
		and world.in_campaign and world.carry_items and (world.hold != released) \
		and field.active and field.human_input and field.current_kind == LegionCfg.KIND_LABORER \
		and not field._stack and not field._space and field._aim_held == 0 \
		and field._grab.is_empty() and not field._slinging and not field._draft_net \
		and not field._draft_ring and field._draft_fig == &"" and field._draft_shape == &""


func _finite_nonnegative(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= 0.0


func _append(row: Dictionary) -> void:
	if first_error != "":
		return
	row["seq"] = entry_count
	row["frame"] = frames
	var size := var_to_bytes(row).size()
	if size <= 0 or _estimated_bytes + size > MAX_BYTES or entry_count >= MAX_ENTRIES:
		invalidate("entry_or_byte_cap")
		return
	_entries[entry_count] = row
	entry_count += 1
	_estimated_bytes += size


func invalidate(reason: String) -> void:
	if first_error == "":
		first_error = reason
		first_error_seq = entry_count


func finish_episode(expected_roots: int, expected_frames: int) -> Dictionary:
	if root_seq != -1 or frame_open or step_open or not released \
			or root_count != expected_roots or frames != expected_frames:
		invalidate("episode_not_at_closed_boundary")
	return {"kind": "solo-capture-draft-v1", "origin": "diagnostic_resolved_actions",
		"normal_solo": true, "episode_complete": first_error == "", "complete": first_error == "",
		"verified": false, "score_eligible": false, "replay_ready": false,
		"child_outcomes_captured": false, "first_incomplete_reason": first_error,
		"first_incomplete_seq": first_error_seq, "frames": frames, "steps": steps,
		"root_count": root_count, "entries": entry_count, "identity": identity,
		"initial_probe_runtime": "UNRUN", "unknown_detection": "limited_boundary_projection"}


func persist(directory: String, report: Dictionary) -> bool:
	var envelope := {"report": report, "initial_state": _initial,
		"entries": _entries.slice(0, entry_count)}
	var payload := var_to_bytes(envelope)
	if payload.is_empty() or payload.size() + _initial.size() + _tail.size() + 65536 > MAX_BYTES:
		invalidate("serialized_artifact_cap")
		_reflect_error(report)
		return false
	report["artifacts"] = {"capture.bin": _sha(payload), "initial.bin": _sha(_initial),
		"tail.bin": _sha(_tail)}
	var text := (JSON.stringify(report, "\t") + "\n").to_utf8_buffer()
	if payload.size() + _initial.size() + _tail.size() + text.size() > MAX_BYTES:
		invalidate("serialized_report_cap")
		_reflect_error(report)
		return false
	var ok := _write_fresh(directory.path_join("initial.bin"), _initial) \
		and _write_fresh(directory.path_join("tail.bin"), _tail) \
		and _write_fresh(directory.path_join("capture.bin"), payload) \
		and _write_fresh(directory.path_join("report.json"), text)
	_reflect_error(report)
	return ok


func _reflect_error(report: Dictionary) -> void:
	if first_error != "":
		report["episode_complete"] = false
		report["complete"] = false
		report["first_incomplete_reason"] = first_error
		report["first_incomplete_seq"] = first_error_seq


func _write_fresh(path: String, bytes: PackedByteArray) -> bool:
	if FileAccess.file_exists(path):
		invalidate("refuse_artifact_overwrite")
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		invalidate("artifact_open_failed")
		return false
	file.store_buffer(bytes)
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	if not ok:
		invalidate("artifact_write_failed")
	return ok


func _sha(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()
