extends SceneTree
## The briefing must present a loading frame before any cold character loading.

var checks := 0
var failures := 0


class FailedLoading extends Control:
	func prepare() -> bool:
		await get_tree().process_frame
		return false


class FailingMain extends LegionMain:
	func _make_battle_loading() -> Control:
		return FailedLoading.new()


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("  %s %s" % ["OK" if ok else "FAIL", message])


func _run() -> void:
	Campaign.set_save_path("user://loading_1012.cfg")
	Campaign.reset()
	var main := LegionMain.new()
	root.add_child(main)
	check(main.has_method("request_battle"), "briefing has a nonblocking entry point")
	if not main.has_method("request_battle"):
		main.free()
		finish()
		return
	main.call("request_battle", "gatehouse")
	check(main.get("_loading_battle"), "loading is immediately latched")
	check(main.world == null, "no synchronous world construction on click")
	check(main.screen != null and main.screen.name == "BattleLoading",
		"visible loading screen exists before yielding")
	var args := OS.get_cmdline_user_args()
	var shot_index := args.find("--loading-shot")
	if shot_index >= 0 and shot_index + 1 < args.size():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(args[shot_index + 1])
	main.call("request_battle", "fork")
	var frames := 0
	var deadline := Time.get_ticks_msec() + 60000
	while bool(main.get("_loading_battle")) and Time.get_ticks_msec() < deadline:
		await process_frame
		frames += 1
	check(frames > 1, "loading yields to the event loop")
	check(not bool(main.get("_loading_battle")), "loading completes")
	check(main.world != null, "one world created after loading")
	check(CharView._cache.size() == CfgAnim.CHARS.size(), "all characters remain prewarmed")
	if main.world != null:
		check(main.world.map_id == "gatehouse", "duplicate click cannot replace requested map")
	main.queue_free()
	await process_frame
	await process_frame
	var failing := FailingMain.new()
	root.add_child(failing)
	var returned := [false]
	failing.request_battle("gatehouse", func() -> void: returned[0] = true)
	for frame in 4:
		await process_frame
	check(not failing._loading_battle and failing.world == null,
		"failure unlocks retry without starting a battle")
	check(failing.screen is Briefing, "failure restores briefing")
	if failing.screen is Briefing:
		(failing.screen as Briefing).back.emit()
	check(returned[0], "failure preserves the original back navigation")
	failing.queue_free()
	await process_frame
	Campaign.reset()
	finish()


func finish() -> void:
	print("LEGION LOADING 1012: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)
