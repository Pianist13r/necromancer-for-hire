extends SceneTree
## A loading-menu move must wait for a real battle before choosing its clock.

const CORR := preload("res://scripts/dev/corr_play.gd")
const WORLD := preload("res://scenes/legion_world.tscn")
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


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _fake_main(with_loading_state: bool = true) -> Node:
	var source := GDScript.new()
	source.source_code = (
		"extends Node\nvar world: LegionWorld = null\n"
		+ "var screen: Control = null\n"
		+ ("var _loading_battle := true\n" if with_loading_state else "")
	)
	if source.reload() != OK:
		return null
	var main := Node.new()
	main.set_script(source)
	root.add_child(main)
	var screen := Control.new()
	screen.size = Vector2(1280, 720)
	main.add_child(screen)
	main.set("screen", screen)
	var label := Label.new()
	label.text = "Подготовка боя…"
	screen.add_child(label)
	return main


func _state(dir: String, n: int) -> Dictionary:
	var path := dir.path_join("turn_%03d.json" % n)
	for frame in 1200:
		if FileAccess.file_exists(path) \
				and FileAccess.get_file_as_string(dir.path_join("waiting.txt")) == str(n):
			var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			return value as Dictionary if value is Dictionary else {}
		await process_frame
	return {}


func _move(dir: String, n: int, value: Dictionary) -> void:
	var path := dir.path_join("move_%03d.json" % n)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)


func _run_default_off() -> void:
	var dir := ProjectSettings.globalize_path("user://legion_corr_readiness_default")
	DirAccess.make_dir_recursive_absolute(dir)
	var main := _fake_main()
	var corr := CORR.new()
	corr.setup_main(main, dir)
	main.add_child(corr)
	_check(not bool(corr.get("_wait_loading")), "readiness gate defaults off")
	var first := await _state(dir, 0)
	_check(String(first.get("mode", "")) == "menu", "default turn 0 is loading menu")
	_move(dir, 0, {"actions": [], "wait": 0.1})
	var next := await _state(dir, 1)
	_check(String(next.get("mode", "")) == "menu" and bool(main.get("_loading_battle")),
		"default path emits next menu turn before loading finishes")
	corr.queue_free()
	main.queue_free()
	await _frames(2)
	Campaign.reset()
	print("LEGION CORR READINESS DEFAULT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _run() -> void:
	Campaign.set_save_path("user://legion_corr_readiness_test.cfg")
	Campaign.reset()
	var args := LegionWorld.parse_args()
	var dev: Dictionary = args.get("dev", {})
	if String(dev.get("corr_wait_loading", "0")) != "1":
		await _run_default_off()
		return
	var dir := ProjectSettings.globalize_path("user://legion_corr_readiness_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var main := _fake_main()
	_check(main != null, "fake campaign main compiles")
	if main == null:
		quit(1)
		return
	var corr := CORR.new()
	corr.setup_main(main, dir)
	main.add_child(corr)
	var first := await _state(dir, 0)
	_check(String(first.get("mode", "")) == "menu", "turn 0 shows the loading menu")
	_move(dir, 0, {"actions": [], "wait": WAIT})
	await _frames(90)
	_check(not FileAccess.file_exists(dir.path_join("turn_001.json")),
		"same move has not produced turn 1 while loading")
	_check(FileAccess.get_file_as_string(dir.path_join("waiting.txt")) == "0",
		"corr has not requested another historical move")

	var world := WORLD.instantiate() as LegionWorld
	world.embedded = true
	main.add_child(world)
	main.set("world", world)
	world.dev = {"no_waves": "1", "spawn_units": "0"}
	world.start_map("_gray")
	await _frames(90)
	_check(world.hold and world.now == 0.0,
		"new world has zero simulation ticks while loading is latched")
	_check(not FileAccess.file_exists(dir.path_join("turn_001.json")),
		"battle transition still waits for readiness")
	main.set("_loading_battle", false)
	var next := await _state(dir, 1)
	_check(String(next.get("mode", "")) == "battle", "turn 1 is battle")
	_check(world.now >= WAIT - 0.001 and world.now <= WAIT + 0.05,
		"unchanged menu move advances the battle by its 0.5-second wait")
	_check(absf(float(next.get("t", -1.0)) - world.now) <= 0.051,
		"snapshot reports the same battle clock")
	var t := world.now
	await _frames(30)
	_check(world.hold and world.now == t, "battle pauses again for turn 1")

	corr.queue_free()
	main.queue_free()
	await _frames(2)
	var failure_dir := ProjectSettings.globalize_path("user://legion_corr_readiness_failure")
	DirAccess.make_dir_recursive_absolute(failure_dir)
	var failed := _fake_main()
	var failed_corr := CORR.new()
	failed_corr.setup_main(failed, failure_dir)
	failed.add_child(failed_corr)
	var failed_first := await _state(failure_dir, 0)
	_check(String(failed_first.get("mode", "")) == "menu", "failure case begins in menu")
	_move(failure_dir, 0, {"actions": [], "wait": WAIT})
	await _frames(90)
	_check(not FileAccess.file_exists(failure_dir.path_join("turn_001.json")),
		"failed load is not mistaken for a ready battle")
	failed.set("_loading_battle", false)
	var failed_next := await _state(failure_dir, 1)
	_check(String(failed_next.get("mode", "")) == "menu",
		"failed loading returns to menu instead of waiting forever")
	failed_corr.queue_free()
	failed.queue_free()
	await _frames(2)
	var plain_dir := ProjectSettings.globalize_path("user://legion_corr_readiness_plain")
	DirAccess.make_dir_recursive_absolute(plain_dir)
	var plain := _fake_main(false)
	var plain_corr := CORR.new()
	plain_corr.setup_main(plain, plain_dir)
	plain.add_child(plain_corr)
	var plain_first := await _state(plain_dir, 0)
	_check(String(plain_first.get("mode", "")) == "menu", "plain fake main begins in menu")
	_move(plain_dir, 0, {"actions": [], "wait": 0.1})
	var plain_next := await _state(plain_dir, 1)
	_check(String(plain_next.get("mode", "")) == "menu",
		"missing loading property retains ordinary menu behavior")
	plain_corr.queue_free()
	plain.queue_free()
	await _frames(2)
	Campaign.reset()
	print("LEGION CORR READINESS: %d/%d OK" % [_checks - _fails, _checks])
	if _fails > 0:
		quit(1)
		return
	# The top-level quit command must bypass the loading gate. It exits this process;
	# the external runner's short deadline catches a blocked quit.
	var quit_dir := ProjectSettings.globalize_path("user://legion_corr_readiness_quit")
	DirAccess.make_dir_recursive_absolute(quit_dir)
	var quitting := _fake_main()
	var quit_corr := CORR.new()
	quit_corr.setup_main(quitting, quit_dir)
	quitting.add_child(quit_corr)
	var quit_first := await _state(quit_dir, 0)
	if String(quit_first.get("mode", "")) != "menu":
		quit(1)
		return
	print("  OK top-level quit sent while loading remains latched")
	_move(quit_dir, 0, {"quit": true})
