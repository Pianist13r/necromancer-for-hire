extends SceneTree
## A canceled asynchronous preparation cannot resurrect a battle from the menu.

var _checks := 0
var _fails := 0


class DelayedLoading extends Control:
	var completed := false

	func prepare() -> bool:
		await get_tree().create_timer(0.2).timeout
		completed = true
		return true


class DelayedMain extends LegionMain:
	var retained_loading: DelayedLoading = null

	func _make_battle_loading() -> Control:
		return DelayedLoading.new()

	func _teardown_screen() -> void:
		if screen is DelayedLoading:
			# Keep the test loader alive after menu so its late prepare result really arrives.
			retained_loading = screen as DelayedLoading
			remove_child(retained_loading)
			screen = null
			return
		super._teardown_screen()


class FailedLoading extends Control:
	func prepare() -> bool:
		await get_tree().process_frame
		return false


class FailingMain extends LegionMain:
	func _make_battle_loading() -> Control:
		return FailedLoading.new()


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


func _run() -> void:
	I18n.initialize("ru")
	Campaign.set_save_path("user://legion_battle_preparation_lifecycle_test.cfg")
	Campaign.reset()
	var delayed := DelayedMain.new()
	root.add_child(delayed)
	delayed.request_battle("gatehouse")
	_check(delayed._loading_battle and delayed.battle_preparation_pending(),
		"accepted request reports pending while loading")
	delayed.show_menu()
	_check(not delayed.battle_preparation_pending() and delayed.screen is LegionMenu,
		"return to menu cancels the pending request immediately")
	await _frames(30)
	_check(delayed.retained_loading != null and delayed.retained_loading.completed,
		"canceled loader's late prepare result was actually delivered")
	_check(delayed.world == null and delayed.screen is LegionMenu,
		"completed canceled loader cannot start a battle")
	if delayed.retained_loading != null:
		delayed.retained_loading.free()
	delayed.queue_free()
	await _frames(2)

	var failed := FailingMain.new()
	root.add_child(failed)
	failed.request_battle("gatehouse")
	_check(failed.battle_preparation_pending(), "failed request is pending before prepare yields")
	await _frames(4)
	_check(not failed.battle_preparation_pending() and failed.world == null,
		"failed preparation clears pending without creating a world")
	_check(failed.screen is Briefing, "failed preparation returns to briefing")
	failed.queue_free()
	await _frames(2)

	var boss := LegionMain.new()
	root.add_child(boss)
	boss.start_battle("boss")
	_check(boss.screen is LegionCutscene and boss.battle_preparation_pending(),
		"only an automatic boss introduction latches the pending battle")
	var stale_cutscene := boss.screen as LegionCutscene
	boss.show_menu()
	_check(not boss.battle_preparation_pending() and boss.screen is LegionMenu,
		"return to menu clears boss introduction latch")
	stale_cutscene.finished.emit()
	await _frames(2)
	_check(boss.world == null and boss.screen is LegionMenu,
		"stale boss introduction callback cannot start a battle after menu")
	boss.queue_free()
	await _frames(2)

	Campaign.reset()
	var other := LegionMain.new()
	root.add_child(other)
	var maps := Campaign.maps()
	if not maps.is_empty():
		other.show_briefing(String(maps[0].get("id", "")))
		_check(other.screen is LegionCutscene and not other.battle_preparation_pending(),
			"campaign introduction is outside the battle preparation gate")
	other.show_menu()
	other._play_cutscene(other._finale_frames(), other._ensure_audio(), func() -> void: pass)
	_check(other.screen is LegionCutscene and not other.battle_preparation_pending(),
		"finale cutscene is outside the battle preparation gate")
	other.queue_free()
	await _frames(2)
	Campaign.reset()
	print("LEGION BATTLE PREPARATION LIFECYCLE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
