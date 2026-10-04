extends SceneTree

var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL ", message)


func _run() -> void:
	Settings.path = "user://legion_metrics_test.cfg"
	Settings._cfg = ConfigFile.new()
	check(not PlayMetrics.consent(), "new player never opts in implicitly")
	Settings.set_value(PlayMetrics.SECTION, PlayMetrics.KEY, true)
	check(PlayMetrics.consent(), "explicit opt-in is read")
	var metrics := PlayMetrics.new()
	root.add_child(metrics)
	await process_frame
	check(not metrics.is_processing(), "headless/QA never sends, even with saved consent")
	check(metrics._http == null and metrics.session.is_empty(), "disabled client allocates no request or ID")
	check(not PlayMetrics.active_play(null, true), "menu without world is not playtime")
	var screen := SettingsScreen.new()
	root.add_child(screen)
	await process_frame
	var box := screen.find_child("SharePlayMetrics", true, false) as CheckBox
	check(box != null and box.button_pressed, "settings reflect current consent")
	if box != null:
		box.button_pressed = false
	check(not PlayMetrics.consent(), "settings revoke consent without GameBus")
	metrics.session = "0123456789abcdef0123456789abcdef"
	metrics.seconds = 18.0
	metrics._process(0.0)
	check(metrics.session.is_empty() and metrics.seconds == 0.0,
		"revocation discards counters and session in memory")
	metrics._pending = {"seq": 0}
	metrics._completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
	check(metrics.seq == 0 and not metrics._pending.is_empty(), "failure preserves initial handshake")
	metrics._completed(HTTPRequest.RESULT_SUCCESS, 204, PackedStringArray(), PackedByteArray())
	check(metrics.seq == 1 and metrics._pending.is_empty(), "only ACK advances sequence")
	metrics._pending = {"seq": 1}
	metrics._completed(HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(), PackedByteArray())
	check(metrics.seq == 1 and not metrics._pending.is_empty(), "rate limit preserves retry packet")
	metrics._completed(HTTPRequest.RESULT_SUCCESS, 409, PackedStringArray(), PackedByteArray())
	check(metrics.seq == 0 and metrics._pending.is_empty(), "expired session starts fresh")
	screen.queue_free()
	metrics.queue_free()
	await process_frame
	print("LEGION PLAY METRICS: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)
