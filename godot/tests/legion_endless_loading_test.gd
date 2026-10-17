extends SceneTree
## Проводка настоящего start брифинга; управляемая готовность загрузчика, не замер скорости.

class Gate extends RefCounted:
	signal completed(ok: bool)

class ControlledLoading extends Control:
	var gate: Gate
	func _ready() -> void:
		name = "BattleLoading"
	func prepare() -> bool:
		return await gate.completed

class ControlledMain extends LegionMain:
	var gate := Gate.new()
	var loading_count := 0
	func _make_battle_loading() -> Control:
		loading_count += 1
		var loading := ControlledLoading.new()
		loading.gate = gate
		return loading

var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("OK " if ok else "FAIL ", message)


func frames(count: int = 3) -> void:
	for _i in count:
		await process_frame


func fixture(daily: bool) -> ControlledMain:
	Campaign.reset()
	Settings.set_difficulty("hell")
	if daily:
		Campaign.use_daily_scope()
	else:
		Campaign.use_endless_scope()
	LegionRunStore.endless_start(61, LegionEndless.today_date() if daily else "")
	Campaign.add_bounty(100)
	check(RunProgression.buy_service("souls"), "подготовка куплена в своём забеге")
	var main := ControlledMain.new()
	root.add_child(main)
	main._args["dev"] = {"endless_stub": "1"}
	main._endless_daily = daily
	main.show_endless_briefing()
	await frames()
	return main


func _case(daily: bool) -> void:
	var main := await fixture(daily)
	var briefing := main.screen as EndlessBriefing
	var id := LegionEndless.object_map_id(61, 1, true)
	var disk := FileAccess.get_file_as_bytes(Campaign._path)
	briefing.start.emit(id)
	check(main._loading_battle, "start брифинга немедленно ставит latch")
	check(main.world == null, "start не создаёт холодный мир синхронно")
	check(main.screen != null and main.screen.name == "BattleLoading", "показан загрузчик")
	check(FileAccess.get_file_as_bytes(Campaign._path) == disk,
		"до готовности нет записи сложности, списания подготовки и daily open")
	# На RED останавливаем сценарий после доказанного обхода загрузчика.
	if not main._loading_battle:
		main.queue_free()
		await frames()
		return
	briefing.start.emit("fork")
	check(main.loading_count == 1, "повторный сигнал не запускает вторую подготовку")
	main.gate.completed.emit(false)
	await frames()
	check(main.screen is EndlessBriefing and main.world == null and not main._loading_battle,
		"ошибка возвращает собственный EndlessBriefing без мира")
	check(main._endless_daily == daily and FileAccess.get_file_as_bytes(Campaign._path) == disk,
		"ошибка сохраняет режим, подготовку, сложность и отметку дня")
	for node in main.get_children():
		if node is AcceptDialog:
			node.queue_free()
	(main.screen as EndlessBriefing).start.emit(id)
	main.show_menu()
	main.gate.completed.emit(true)
	await frames()
	check(main.screen is LegionMenu and main.world == null and not main._loading_battle,
		"отмена поколением запрещает поздний старт")
	main.show_endless_briefing()
	await frames()
	(main.screen as EndlessBriefing).start.emit(id)
	main.gate.completed.emit(true)
	await frames()
	check(main.world != null and main.world.map_id == id, "успех запускает запрошенную карту")
	check(not main._loading_battle and RunProgression.preparations().is_empty(),
		"успех снимает latch и расходует подготовку")
	check(LegionRunStore.is_difficulty_locked(daily)
		and LegionRunStore.run_difficulty(daily) == "hell"
		and main.world.dev.get("difficulty") == "hell", "сложность закреплена в своём режиме")
	check(is_equal_approx(float(main.world.battle_preparation.get("start_souls", 0)), 45.0),
		"подготовка передана в настоящий мир")
	check(LegionRunStore.daily_open_object() == (id if daily else ""),
		"daily open отмечается только успешному Daily")
	if not daily:
		var old_world := main.world
		var loads := main.loading_count
		main.show_endless_briefing()
		await frames()
		(main.screen as EndlessBriefing).start.emit(id)
		check(main.world == old_world and main.loading_count == loads and not main._loading_battle,
			"тёплый мир используется без нового загрузчика")
	main.queue_free()
	await frames()


func _run() -> void:
	Campaign.set_save_path("user://endless_loading.cfg")
	await _case(false)
	await _case(true)
	Campaign.reset()
	print("ENDLESS LOADING: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)
