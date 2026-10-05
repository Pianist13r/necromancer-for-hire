extends SceneTree
## Выход из выбора, перезапуск, отказ записи и ровно одна награда во всех режимах.

const SAVE := "user://legion_reward_resume_test.cfg"
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fails += 1
		print("FAIL: ", message)


func _frames() -> void:
	await process_frame
	await process_frame


func _run() -> void:
	for scope: String in ["campaign", "endless", "daily"]:
		Campaign.set_save_path(SAVE)
		Campaign.reset()
		Campaign.set_intro_cutscene_seen()
		Campaign.set_tutorial_done()
		var main := LegionMain.new()
		root.add_child(main)
		await _frames()
		main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}
		var daily := scope == "daily"
		if scope != "campaign":
			main._start_endless_flow(daily)
			LegionRunStore.endless_object_won(10)
		else:
			Campaign.record_result(String(Campaign.maps()[0]["id"]), true, 1.0)
		var next_id := String(Campaign.maps()[1]["id"]) if scope == "campaign" \
			else LegionEndless.PENDING_SENTINEL
		Campaign.set_pending_reward(next_id)
		main._pending_next_map = next_id
		main._offer_upgrade_or_skip()
		await _frames()
		var options := (main.screen as UpgradePicker).offered()
		(main.screen as UpgradePicker).back.emit()
		await _frames()
		main.queue_free()
		await _frames()
		Campaign.set_save_path(SAVE)
		main = LegionMain.new()
		root.add_child(main)
		await _frames()
		main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}
		if scope == "campaign":
			main._on_continue_pressed(next_id)
		else:
			main._start_endless_flow(daily)
		await _frames()
		_check(main.screen is UpgradePicker, scope + ": незабранная награда вернулась")
		_check((main.screen as UpgradePicker).offered() == options, scope + ": те же варианты")
		var blocked := ProjectSettings.globalize_path(SAVE + ".tmp")
		DirAccess.make_dir_recursive_absolute(blocked)
		main.pick_upgrade(options[0])
		_check(main.screen is UpgradePicker and Campaign.upgrades().is_empty(),
			scope + ": отказ записи оставил выбор и не выдал награду")
		DirAccess.remove_absolute(blocked)
		main.pick_upgrade(options[0])
		await _frames()
		_check(main.screen is Briefing if scope == "campaign" else main.screen is EndlessBriefing,
			scope + ": сразу брифинг")
		_check(Campaign.pending_reward() == "", scope + ": переход завершён")
		main.pick_upgrade(options[0])
		_check(Campaign.upgrades().size() == 1, scope + ": повторный клик не дублирует награду")
		Campaign.set_save_path(SAVE)
		Campaign._scope = scope
		_check(Campaign.upgrades().size() == 1, scope + ": ровно одна поправка на диске")
		main.queue_free()
		await _frames()
	print("REWARD RESUME: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
