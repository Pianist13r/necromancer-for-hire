extends SceneTree
## Регресс независимого ревью: артефакт, премия и переход — одна запись.
## Проверяем настоящий путь через LegionWorld и новое меню после перезапуска.

const SAVE := "user://legion_outcome_transaction_test.cfg"
var checks := 0
var fails := 0
var main: LegionMain

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("PASS " if ok else "FAIL ", what)

func _frames(n := 2) -> void:
	for _i in n:
		await process_frame

func _new_main() -> void:
	main = LegionMain.new()
	root.add_child(main)
	await _frames()
	main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}

func _run() -> void:
	for scope: String in ["campaign", "endless", "daily"]:
		Campaign.set_save_path(SAVE)
		Campaign.reset()
		Campaign.use_campaign_scope()
		Campaign.set_intro_cutscene_seen()
		Campaign.set_tutorial_done()
		await _new_main()
		var daily := scope == "daily"
		var first_id := String(Campaign.maps()[0]["id"])
		if scope == "campaign":
			main.start_battle(first_id)
		else:
			main._start_endless_flow(daily)
			var mid := LegionEndless.object_map_id(LegionRunStore.endless_seed(daily),
				LegionRunStore.endless_k(daily), true)
			main._start_endless_battle(mid)
		await _frames(3)
		main.world.items.grant(&"clip_of_fate")
		var before_end := FileAccess.get_file_as_string(SAVE)
		main.world.force_end(true)
		if FileAccess.get_file_as_string(SAVE + ".bak") != before_end:
			print("BEFORE OUTCOME: ", before_end)
			print("BACKUP AFTER: ", FileAccess.get_file_as_string(SAVE + ".bak"))
			print("PRIMARY AFTER: ", FileAccess.get_file_as_string(SAVE))
		_check(FileAccess.get_file_as_string(SAVE + ".bak") == before_end,
			scope + ": battle outcome made one committed operation")
		await _frames()
		_check(Campaign.pending_reward() != "", scope + ": victory has pending reward")
		if daily:
			_check(LegionRunStore.daily_open_object() == "", "daily: victory cleared open marker")
		main._on_result_next()
		await _frames()
		_check(main.screen is UpgradePicker, scope + ": first claim shows picker")
		main.pick_upgrade((main.screen as UpgradePicker).offered()[0])
		await _frames()
		_check(Campaign.pending_reward() == "", scope + ": claim completes transition")
		main.queue_free()
		await _frames()
		Campaign.set_save_path(SAVE)
		await _new_main()
		_check(main.screen is LegionMenu, scope + ": restart reaches main menu")
		if scope == "campaign":
			main._on_continue_pressed(String(Campaign.maps()[1]["id"]))
		else:
			main._start_endless_flow(daily)
		await _frames()
		_check(not main.screen is UpgradePicker, scope + ": continue skips claimed picker")
		_check(Campaign.upgrades().size() == 1, scope + ": exactly one reward remains")
		_check(Campaign.pending_reward() == "", scope + ": claim clears transition")
		if scope == "campaign":
			_check(main.screen is Briefing, scope + ": next map briefing")
		else:
			_check(main.screen is EndlessBriefing, scope + ": next object briefing")
			_check(LegionRunStore.endless_k(daily) == 2, scope + ": resumed object remains 2")
		main.queue_free()
		await _frames()
	print("OUTCOME TRANSACTION: %d/%d OK" % [checks-fails, checks])
	quit(1 if fails else 0)
