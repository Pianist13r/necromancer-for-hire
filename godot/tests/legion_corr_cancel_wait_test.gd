extends SceneTree
## B-544 GREEN-only: detach and free in the same call stack as each external wait.
## This probes the freed-instance window that post-await _active() cannot cover.

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


func _run() -> void:
	var probe_script := GDScript.new()
	probe_script.source_code = ("extends \"%s\"\n" % CORR
		+ "var witness: Dictionary\n"
		+ "func _ready() -> void:\n\tpass\n"
		+ "func begin_wait(target: Object, name: StringName) -> void:\n"
		+ "\twitness[\"ok\"] = await _await_external(target, name)\n")
	_check(probe_script.reload() == OK, "cancel wait probe compiles")
	if _fails > 0:
		_finish()
		return
	var cases := [
		{"name": "frame", "source": self, "signal": &"process_frame"},
		{"name": "timer", "source": create_timer(10.0), "signal": &"timeout"},
		{"name": "post_draw", "source": RenderingServer, "signal": &"frame_post_draw"},
	]
	for test_case: Dictionary in cases:
		var witness: Dictionary = {}
		var probe: Node = probe_script.new()
		probe.set("witness", witness)
		root.add_child(probe)
		probe.call("begin_wait", test_case["source"], test_case["signal"])
		root.remove_child(probe)
		_check(witness.has("ok") and witness["ok"] == false,
			"%s wait cancelled synchronously on detach" % test_case["name"])
		probe.free()
	await process_frame
	_finish()


func _finish() -> void:
	print("LEGION CORR CANCEL WAIT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
