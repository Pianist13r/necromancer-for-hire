extends SceneTree
## Потеря фокуса бережёт одиночный бой, но никогда не останавливает общий PvP-мир.

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
	Campaign.set_save_path("user://legion_focus_pause_test.cfg")
	Campaign.reset()
	var world := LegionWorld.new()
	world.embedded = true
	root.add_child(world)
	await process_frame
	world.start_map("wasteland")
	world.rally_aiming = true
	world.focus_lost()
	_check(world.paused and paused, "одиночный бой автоматически на паузе")
	_check(not world.rally_aiming, "незавершённый сбор отменён")
	var time_before := world.now
	await process_frame
	await process_frame
	_check(world.now == time_before, "бой не идёт под потерявшим фокус окном")
	world.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(world.paused, "возврат фокуса не снимает паузу без игрока")
	world.set_paused(false)
	world.start_map("pvp:duel")
	world.rally_aiming = true
	world.focus_lost()
	_check(not world.paused and not paused, "PvP не ставится на паузу")
	_check(not world.rally_aiming, "PvP отменяет только локальный незавершённый жест")
	world.queue_free()
	await process_frame
	print("FOCUS PAUSE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
