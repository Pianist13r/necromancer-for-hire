extends SceneTree
## Закрытие игры в Конторе после выбора не даёт вторую поправку за ту же победу.

const SAVE := "user://legion_reward_resume_test.cfg"
const UPGRADE := &"cauldron_insurance"
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fails += 1
		print("FAIL: ", message)


func _run() -> void:
	for scope: String in ["campaign", "endless", "daily"]:
		Campaign.set_save_path(SAVE)
		Campaign.reset()
		Campaign._scope = scope
		Campaign.set_intro_cutscene_seen()
		var next_id := "gatehouse" if scope == "campaign" else LegionEndless.PENDING_SENTINEL
		Campaign.set_pending_reward(next_id)
		var main := LegionMain.new()
		root.add_child(main)
		Campaign._scope = scope
		main.pick_upgrade(UPGRADE)
		await process_frame
		_check(Campaign.upgrades().has(UPGRADE), scope + ": поправка получена")
		main.queue_free()
		await process_frame
		Campaign.set_save_path(SAVE)
		Campaign._scope = scope
		main = LegionMain.new()
		root.add_child(main)
		Campaign._scope = scope
		main._offer_upgrade_or_skip()
		await process_frame
		_check(not main.screen is UpgradePicker, scope + ": после перезапуска сразу Контора")
		_check(Campaign.pending_reward() == next_id, scope + ": переход на следующую карту сохранён")
		_check(Campaign.upgrades().size() == 1, scope + ": ровно одна поправка")
		main.queue_free()
		await process_frame
	print("REWARD RESUME: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
