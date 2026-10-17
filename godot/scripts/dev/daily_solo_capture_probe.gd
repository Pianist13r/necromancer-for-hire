extends SceneTree
## SOURCE ONLY / runtime UNRUN. Requires a future pinned 8/6-GiB OwnedJob harness.
## One diagnostic semantic episode, not native UI/session capture or replay.

const CAPTURE = preload("res://scripts/dev/solo_input_capture.gd")
const SAVE := "user://daily_solo_capture.cfg"
const DATE := "2026-10-16"
const EPISODE_FRAMES := 12
const READY_MS := 45000
const QA_ROOT := "C:/Projects/Necromancer/local/qa/2026-10-16-solo-capture"
const SOURCE_FILES := ["scripts/dev/solo_input_capture.gd",
	"scripts/dev/daily_solo_capture_probe.gd", "tests/legion_solo_input_capture_test.gd",
	"scripts/legion/legion_world.gd", "scripts/legion/contract_field.gd",
	"scripts/legion/snap/snap_world.gd"]

var main: LegionMain
var recorder: Variant
var _out := ""
var _case: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _case_setup() -> bool:
	var argv := OS.get_cmdline_user_args()
	var index := argv.find("--qa-case")
	if index < 0 or index + 1 >= argv.size() or not argv[index + 1].is_absolute_path() \
			or not argv.has("--mute") or not _private_save_arg(argv):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(argv[index + 1]))
	if not parsed is Dictionary or parsed.get("kind") != "solo-capture-case-v1" \
			or parsed.get("date") != DATE or parsed.get("episode") != "plain_laborer_finish":
		return false
	_case = parsed
	_out = String(_case.get("out_dir", "")).replace("\\", "/").simplify_path()
	var appdata := OS.get_environment("APPDATA").replace("\\", "/").simplify_path()
	if not _out.is_absolute_path() or DirAccess.dir_exists_absolute(_out) \
			or not _out.begins_with(QA_ROOT + "/") or _out.get_file() != "capture" \
			or appdata != _out.get_base_dir().path_join("appdata") \
			or DirAccess.make_dir_recursive_absolute(_out) != OK:
		return false
	Campaign.set_save_path(SAVE)
	Settings.use_dev_save(SAVE)
	Settings.set_difficulty(LegionChallenge.NORMAL)
	AudioServer.set_bus_mute(0, true)
	return true


func _private_save_arg(argv: PackedStringArray) -> bool:
	for i: int in argv.size() - 1:
		if argv[i] == "--dev" and argv[i + 1] == "save=" + SAVE:
			return true
	return false


func _run() -> void:
	if not _case_setup():
		_fail("case/private-profile/output setup refused")
		return
	main = (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await process_frame
	Campaign.use_daily_scope()
	if not LegionRunStore.daily_enter(DATE):
		_fail("fresh daily_enter refused")
		return
	var seed := LegionRunStore.endless_seed(true)
	var map_id := LegionEndless.object_map_id(seed, 1, false)
	main._endless_daily = true
	var w := main._ensure_world()
	w.hold = true
	main._start_endless_battle(map_id)
	if not await _held_ready(w, map_id):
		_fail("actual Daily held-ready setup refused")
		return
	var lines: Array = w.map.get("bot_lines", [])
	if lines.is_empty() or not lines[0] is Dictionary \
			or not lines[0].get("a") is Array or not lines[0].get("b") is Array:
		_fail("fixed line0 absent; no fallback")
		return
	var a := Vector2(float(lines[0]["a"][0]), float(lines[0]["a"][1]))
	var b := Vector2(float(lines[0]["b"][0]), float(lines[0]["b"][1]))
	if not a.is_finite() or not b.is_finite() or a == b:
		_fail("fixed line0 endpoints invalid")
		return
	await _capture_ready_world(w, a, b)


func _capture_ready_world(w: LegionWorld, a: Vector2, b: Vector2) -> void:
	recorder = CAPTURE.new()
	if not recorder.attach(w, _identity(w, a, b)):
		_fail("recorder attach refused")
		return
	w.qa_solo_capture = Callable(recorder, "observe")
	w.hold = false
	if not recorder.record_hold_release():
		_fail("declared hold-release refused")
		return
	await _episode(w, a, b)


func _held_ready(w: LegionWorld, map_id: String) -> bool:
	var deadline := Time.get_ticks_msec() + READY_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if w.now != 0.0 or not w.hold:
			return false
		if w.phase == LegionWorld.Phase.BATTLE and not w.is_ground_loading() \
				and w.get_node_or_null("GroundLoading") == null:
			break
	return w.phase == LegionWorld.Phase.BATTLE and not w.is_ground_loading() \
		and w.get_node_or_null("GroundLoading") == null \
		and w.now == 0.0 and w.hold and main.world == w and main._in_endless_battle \
		and main._endless_daily and not w.net_mode and not w.pvp \
		and w.bot == null and w.tutorial == null and w.map_id == map_id \
		and map_id == ProcGen.make_id(LegionEndless.daily_seed(DATE), 1) \
		and w.difficulty == LegionChallenge.NORMAL and w.in_campaign and w.carry_items \
		and Campaign.is_daily_scope() and LegionRunStore.endless_daily_date() == DATE \
		and LegionRunStore.endless_k(true) == 1 \
		and LegionRunStore.procgen_version(true) == ProcGen.VERSION \
		and LegionRunStore.run_difficulty(true) == LegionChallenge.NORMAL \
		and LegionRunStore.daily_open_object() == map_id \
		and w.mods == Campaign.active_mods() and RunProgression.preparations().is_empty() \
		and w.battle_preparation.is_empty()


func _episode(w: LegionWorld, a: Vector2, b: Vector2) -> void:
	var initial_contracts := w.contracts.contracts.size()
	var initial_lines := int(w.stats.get("lines", 0))
	var observed: Dictionary = {"initial_contracts": initial_contracts,
		"initial_lines": initial_lines, "intermediate": {}}
	for index: int in EPISODE_FRAMES:
		await process_frame
		if recorder.first_error != "":
			break
		if recorder.frames != index + 1 or recorder.frame_open or recorder.step_open:
			recorder.invalidate("driver_not_between_completed_frames")
			break
		match index:
			0:
				_root_action(w, &"press", a)
			1:
				var before := w.contracts.mana
				_root_action(w, &"move", a.lerp(b, 0.5))
				observed["intermediate"] = {"drawing": w.contracts._drawing,
					"draft_points": w.contracts._draft.size(), "draft_cost": w.contracts._draft_cost,
					"mana_before": before, "mana_after": w.contracts.mana,
					"draft_raw": var_to_bytes(w.contracts._draft).hex_encode()}
			2:
				_root_action(w, &"move", b)
			3:
				_root_action(w, &"release", b)
	var mid: Dictionary = observed["intermediate"]
	observed["final_contracts"] = w.contracts.contracts.size()
	observed["final_lines"] = int(w.stats.get("lines", 0))
	observed["field_drawing"] = w.contracts._drawing
	var laborer_lines := 0
	for contract: Contract in w.contracts.contracts:
		if contract.kind == LegionCfg.KIND_LABORER and contract.points.size() >= 2:
			laborer_lines += 1
	observed["laborer_contracts"] = laborer_lines
	if not bool(mid.get("drawing", false)) or int(mid.get("draft_points", 0)) < 2 \
			or float(mid.get("draft_cost", 0)) <= 0.0 \
			or float(mid.get("mana_after", INF)) >= float(mid.get("mana_before", -INF)) \
			or w.contracts._drawing or w.contracts._pressing or laborer_lines != 1 \
			or w.contracts.contracts.size() != initial_contracts + 1 \
			or int(w.stats.get("lines", 0)) != initial_lines + 1:
		recorder.invalidate("fixed_stroke_refused_or_no_incremental_effect")
	var report: Dictionary = recorder.finish_episode(4, EPISODE_FRAMES)
	report["observed_episode_outcome"] = observed
	# This continuation resumes at process_frame, before the next world callback.
	# Detach only after the recorder attests the last observed frame closed.
	w.qa_solo_capture = Callable()
	w.hold = true
	var persisted: bool = recorder.persist(_out, report)
	if not persisted:
		_fail("artifact persistence failed: " + String(recorder.first_error))
		return
	print("SOLO_CAPTURE_DRAFT " + JSON.stringify(report))
	main.queue_free()
	await process_frame
	quit(0 if report["episode_complete"] else 1)


func _root_action(w: LegionWorld, action: StringName, at: Vector2) -> void:
	if not recorder.root_begin(action, at):
		return
	# Resolved ordinary input context belongs to the authored root, not an unexplained mutation.
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
	recorder.root_end()


func _identity(w: LegionWorld, a: Vector2, b: Vector2) -> Dictionary:
	var sources: Dictionary = {}
	for file: String in SOURCE_FILES:
		sources[file] = FileAccess.get_sha256("res://" + file)
	return {"date": DATE, "run_seed": str(LegionRunStore.endless_seed(true)),
		"battle_seed": str(w._base_seed), "rng_seed": str(w.rng.seed), "rng_state": str(w.rng.state),
		"map_id": w.map_id, "generator": ProcGen.VERSION, "snapshot_version": NetSnap.VERSION,
		"source_head_claimed": _case.get("source_head", ""), "source_files_sha256": sources,
		"engine_sha256": FileAccess.get_sha256(OS.get_executable_path()),
		"engine_version": Engine.get_version_info()["string"],
		"producer": "daily_solo_capture_probe.gd", "save": SAVE,
		"use_accumulated_input": Input.use_accumulated_input,
		"episode": {"line_index": 0, "a_raw": var_to_bytes(a).hex_encode(),
			"mid_raw": var_to_bytes(a.lerp(b, 0.5)).hex_encode(), "b_raw": var_to_bytes(b).hex_encode(),
			"schedule_after_frames": [1, 2, 3, 4], "stop_after_frames": EPISODE_FRAMES}}


func _fail(reason: String) -> void:
	if main != null and is_instance_valid(main) and main.world != null:
		main.world.qa_solo_capture = Callable()
		main.world.hold = true
	printerr("SOLO_CAPTURE_DRAFT incomplete: " + reason)
	quit(1)
