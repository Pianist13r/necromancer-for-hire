extends SceneTree
## An unchanged corr move waits through real asynchronous loading and boss intro.

const CORR := preload("res://scripts/dev/corr_play.gd")
const MAIN := preload("res://scenes/legion.tscn")
const SAVE := "user://legion_corr_boss_readiness_test.cfg"
const DIR := "user://legion_corr_boss_readiness_test"
const WAIT := 0.5

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", description])


func _state(dir: String, n: int) -> Dictionary:
	var path := dir.path_join("turn_%03d.json" % n)
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path) \
				and FileAccess.get_file_as_string(dir.path_join("waiting.txt")) == str(n):
			var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			return value as Dictionary if value is Dictionary else {}
		await process_frame
	return {}


func _run() -> void:
	I18n.initialize("ru")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	var dir := ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var main := MAIN.instantiate() as LegionMain
	root.add_child(main)
	var corr := CORR.new()
	corr.setup_main(main, dir)
	# D-1014: ожидание подготовки включается только для точного повтора.
	corr._wait_loading = true
	main.add_child(corr)
	var first := await _state(dir, 0)
	_check(String(first.get("mode", "")) == "menu", "turn 0 is the campaign menu")
	if main.has_method("battle_preparation_pending"):
		_check(not bool(main.call("battle_preparation_pending")),
			"ordinary menu does not claim a battle preparation")
	main.request_battle("boss")
	_check(main._loading_battle and main.world == null,
		"real battle loading is asynchronous and has no world")
	if main.has_method("battle_preparation_pending"):
		_check(bool(main.call("battle_preparation_pending")),
			"pending query covers asynchronous loading")
	var move_path := dir.path_join("move_000.json")
	var file := FileAccess.open(move_path + ".tmp", FileAccess.WRITE)
	file.store_string('{"actions":[],"wait":0.5}')
	file.close()
	DirAccess.rename_absolute(move_path + ".tmp", move_path)
	var saw_boss_intro := false
	var premature := false
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		if main.screen is LegionCutscene:
			saw_boss_intro = true
			break
		if FileAccess.file_exists(dir.path_join("turn_001.json")):
			premature = true
			break
		await process_frame
	_check(saw_boss_intro, "real loading reaches the automatic boss introduction")
	_check(not premature, "no next turn during asynchronous loading")
	if not saw_boss_intro or premature:
		await _finish(main)
		return
	_check(main.world == null, "boss introduction precedes world construction")
	if main.has_method("battle_preparation_pending"):
		_check(bool(main.call("battle_preparation_pending")),
			"pending query stays true across the boss introduction")
	var intro_frames := 0
	deadline = Time.get_ticks_msec() + 60000
	while main.screen is LegionCutscene and Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("turn_001.json")):
			premature = true
			break
		if main.world != null:
			premature = true
			break
		intro_frames += 1
		await process_frame
	_check(intro_frames > 2, "boss introduction advances naturally for multiple frames")
	_check(not premature, "no turn or simulation world before boss introduction ends")
	if premature:
		await _finish(main)
		return
	var next := await _state(dir, 1)
	_check(String(next.get("mode", "")) == "battle", "next turn is the actual battle")
	_check(main.world != null and main.world.phase == LegionWorld.Phase.BATTLE,
		"battle world exists after introduction")
	if main.world != null:
		_check(main.world.now >= WAIT - 0.001 and main.world.now <= WAIT + 0.05,
			"unchanged move advances battle time by only its 0.5-second wait")
		_check(main.world.hold, "world is held again for the next turn")
	if main.has_method("battle_preparation_pending"):
		_check(not bool(main.call("battle_preparation_pending")),
			"pending query clears after start_map")
	await _finish(main)


func _finish(main: LegionMain) -> void:
	main.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION CORR BOSS READINESS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
