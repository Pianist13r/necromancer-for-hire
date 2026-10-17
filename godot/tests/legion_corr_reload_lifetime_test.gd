extends SceneTree
## B-544: a menu action can remove corr_play while its mouse-up awaits a frame.
## Run with a private APPDATA and --mute; reject any engine/script diagnostic.

const SAVE := "user://legion_corr_reload_lifetime_test.cfg"
const DIR := "user://legion_corr_reload_lifetime_test"
const CORR := "res://scripts/dev/corr_play.gd"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _folder(name: String) -> String:
	var path := ProjectSettings.globalize_path(DIR).path_join(name)
	DirAccess.make_dir_recursive_absolute(path)
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	return path


func _fake_main() -> Node:
	var source := GDScript.new()
	source.source_code = "extends Node\nvar world = null\nvar screen: Control = null\n"
	assert(source.reload() == OK)
	var fake := Node.new()
	fake.set_script(source)
	root.add_child(fake)
	var screen := Control.new()
	screen.size = Vector2(1280, 720)
	fake.add_child(screen)
	fake.set("screen", screen)
	var button := Button.new()
	button.text = "Настройки"
	button.position = Vector2(540, 320)
	button.size = Vector2(200, 40)
	screen.add_child(button)
	return fake


func _wait_file(path: String, limit: int = 600) -> bool:
	for i in limit:
		if FileAccess.file_exists(path):
			return true
		await process_frame
	return FileAccess.file_exists(path)


func _move(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	var fake := _fake_main()
	var old_dir := _folder("old")
	# Override only the input sink; _run_campaign → _act → _click → _button and
	# SceneTree frame awaits remain the real implementation. Removal models the
	# old scene being detached by settings_screen.reload_current_scene().
	var probe_script := GDScript.new()
	probe_script.source_code = ("extends \"%s\"\n" % CORR
		+ "var detach_enabled := true\nvar detach_requested := false\nvar detached := false\nvar input_after_detach := 0\nvar input_count := 0\nvar quit_called := false\n"
		+ "func _quit(_code: int) -> void:\n\tquit_called = true\n\t_cleanup_input()\n"
		+ "func _detach_from_scene() -> void:\n\tif is_inside_tree():\n\t\tdetached = true\n\t\tget_parent().remove_child(self)\n"
		+ "func _send_input(event: InputEvent) -> void:\n"
		+ "\tif not is_inside_tree():\n\t\tinput_after_detach += 1\n"
		+ "\tinput_count += 1\n\tsuper._send_input(event)\n"
		+ "\tif detach_enabled and not detach_requested and event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and not (event as InputEventMouseButton).pressed:\n"
		+ "\t\tdetach_requested = true\n\t\tcall_deferred(\"_detach_from_scene\")\n")
	_check(probe_script.reload() == OK, "reload probe compiles")
	if _fails > 0:
		_finish(fake)
		return
	var old: Node = probe_script.new()
	old.call("setup_main", fake, old_dir)
	fake.add_child(old)
	var old_turn := old_dir.path_join("turn_000.json")
	_check(await _wait_file(old_turn), "old scene produced menu turn 0")
	if _fails > 0:
		old.queue_free()
		_finish(fake)
		return
	var old_move := old_dir.path_join("move_000.json")
	_move(old_move, {"actions": [
		{"tap": [640, 340]}], "wait": 0.05})
	for i in 180:
		if bool(old.get("detached")):
			break
		await process_frame
	_check(bool(old.get("detached")) and not old.is_inside_tree(),
		"mouse-up detached old corr during async menu action")
	var count_after_detach := int(old.get("input_count"))
	for i in 90:
		await process_frame
	_check(int(old.get("input_after_detach")) == 0 and int(old.get("input_count")) == count_after_detach,
		"old corr emitted no stale synthetic input after detach")
	_check(int(old.get("turn")) == 0 and not FileAccess.file_exists(old_dir.path_join("turn_001.json")),
		"old corr wrote no next turn after detach")
	# Explicit terminal-reuse stress after the real async detach: Godot does not
	# rerun _ready on readd unless requested. A cleanly cancelled instance must
	# stay dead even then; the baseline reruns _ready and writes turn_000 again.
	_check(DirAccess.remove_absolute(old_turn) == OK, "removed old turn 0 for reuse probe")
	_check(DirAccess.remove_absolute(old_move) == OK, "removed consumed move for reuse probe")
	old.request_ready()
	fake.add_child(old)
	for i in 180:
		await process_frame
	_check(not FileAccess.file_exists(old_turn),
		"cancelled instance cannot resume after request_ready")
	var resumed := FileAccess.file_exists(old_turn)
	if resumed:
		# Baseline's second loop is real; let it consume a controlled quit before
		# freeing its node, so fixture cleanup does not strand an await.
		_move(old_move, {"quit": true})
		for i in 180:
			if bool(old.get("quit_called")):
				break
			await process_frame
	_check(not resumed or bool(old.get("quit_called")), "reused loop stopped before free")
	old.free()
	# A fresh scene/corr instance still completes an ordinary menu wait/next turn.
	var new_dir := _folder("new")
	var fresh: Node = probe_script.new()
	fresh.set("detach_enabled", false)
	fresh.call("setup_main", fake, new_dir)
	fake.add_child(fresh)
	_check(await _wait_file(new_dir.path_join("turn_000.json")), "new corr produced menu turn 0")
	_move(new_dir.path_join("move_000.json"), {"actions": [], "wait": 0.05})
	_check(await _wait_file(new_dir.path_join("turn_001.json")),
		"new corr completed ordinary menu wait and turn 1")
	if FileAccess.file_exists(new_dir.path_join("turn_001.json")):
		var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(new_dir.path_join("turn_001.json")))
		_check(String(state.get("mode", "")) == "menu", "new turn remains a normal menu turn")
	_move(new_dir.path_join("move_001.json"), {"quit": true})
	for i in 180:
		if bool(fresh.get("quit_called")):
			break
		await process_frame
	_check(bool(fresh.get("quit_called")), "new corr consumed controlled quit before free")
	fresh.free()
	_finish(fake)


func _finish(fake: Node) -> void:
	fake.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION CORR RELOAD LIFETIME: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
