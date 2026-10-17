extends SceneTree
## Реальный HTTP → локальный сервис; UI через штатный ввод, отдельный профиль.

var checks := 0
var fails := 0
var screen: HeroScreen
var board_ui: DailyBoard
var before_save := ""
var out := ""


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		fails += 1
	print("PASS " if value else "FAIL ", message)


func _frames(count: int = 3) -> void:
	for _i in count:
		OS.delay_msec(16)  # HTTP живёт по настенным часам, fixed-fps ускоряет headless.
		await process_frame


func _click(button: Button) -> void:
	var pos := root.get_final_transform() * button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await _frames()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = pos
		event.global_position = pos
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		event.pressed = pressed
		Input.parse_input_event(event)
		await _frames(2)


func _wait_request() -> void:
	var start := Time.get_ticks_msec()
	while board_ui._busy and Time.get_ticks_msec() - start < 15000:
		OS.delay_msec(16)
		await process_frame
	await _frames()
	_check(not board_ui._busy, "HTTP request completes within bound")


func _shot(id: String) -> void:
	if DisplayServer.get_name() == "headless" or out.is_empty():
		return
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(out.path_join(id + ".png"))
	_check(error == OK, "capture " + id)


func _run() -> void:
	out = OS.get_environment("NECRO_BOARD_FRAMES")
	if not out.is_empty():
		DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://daily_board_test.cfg")
	Campaign.reset()
	Settings.path = "user://daily_board_settings.cfg"
	I18n.initialize("ru")
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--language="):
			I18n.select(arg.trim_prefix("--language="))
	var today := LegionEndless.today_date()
	# Сохраняем настоящий конечный путь RunStore, не сочиняем формат done_dates.
	Campaign.use_daily_scope()
	LegionRunStore.endless_start(LegionEndless.daily_seed(today), today)
	LegionRunStore.lock_difficulty(true, "normal")
	LegionRunStore.endless_object_won(170)
	LegionRunStore.endless_end_run()
	Campaign.use_campaign_scope()
	var key := DailyBoardData.key(today, "normal")
	_check(DailyBoardData.result(key) == {"tenure": 1, "souls": 170}, "real finished daily read")
	var mismatch := key.duplicate()
	mismatch["difficulty"] = "hell"
	_check(DailyBoardData.result(mismatch).is_empty(), "difficulty isolation")
	mismatch = key.duplicate()
	mismatch["version"] = ProcGen.VERSION - 1
	_check(DailyBoardData.result(mismatch).is_empty(), "old version not submitted as current")
	mismatch = key.duplicate()
	mismatch["seed"] = 7
	_check(DailyBoardData.result(mismatch).is_empty(), "seed mismatch refused")
	before_save = FileAccess.get_file_as_string(Campaign._path)
	_check(not FileAccess.file_exists(DailyBoardData.OUTBOX), "no receipt before consent")
	screen = HeroScreen.new()
	root.add_child(screen)
	await _frames()
	await _click(screen.view.find_child("TabRecords", true, false) as Button)
	await _frames(5)
	board_ui = screen.find_child("DailyBoard", true, false) as DailyBoard
	_check(board_ui != null, "actual dossier Records tab opens shared board")
	if board_ui == null:
		print("RECORDS INPUT DEBUG ", screen.view.tab(), " viewport ", root.get_visible_rect())
		quit(1)
		return
	_check(not board_ui.endpoint.is_empty(), "explicit loopback QA endpoint")
	board_ui._http.request_completed.connect(func(result: int, code: int,
			_headers: PackedStringArray, body: PackedByteArray) -> void:
		print("HTTP OBSERVED ", result, " ", code, " ", body.get_string_from_utf8()))
	_check(not board_ui._busy and board_ui._rows.get_child_count() == 0, "no automatic request")
	_check(not FileAccess.file_exists(DailyBoardData.OUTBOX), "opening UI does not create receipt")
	_check(not board_ui._send.disabled, "finished result can be voluntarily submitted")
	await _shot("ready")
	await _click(board_ui._open)
	await _wait_request()
	_check(board_ui._status.text == I18n.t("Пока нет результатов."), "empty real server board")
	await _click(board_ui._send)
	await _wait_request()
	_check(board_ui._status.text == I18n.t(
		"Результат принят без проверки боя. Откройте таблицу для просмотра."),
		"real POST accepted explicitly unverified")
	var receipt := DailyBoardData.submission(key)
	_check(not receipt.is_empty() and FileAccess.file_exists(DailyBoardData.OUTBOX),
		"receipt persisted")
	_check(DailyBoardData.submission(key) == receipt, "retry reuses exact durable payload")
	await _click(board_ui._send)
	await _wait_request()
	await _click(board_ui._open)
	await _wait_request()
	_check(board_ui._rows.get_child_count() == 1, "duplicate POST has one server row")
	_check(root.gui_get_focus_owner() == board_ui._open, "request restores button keyboard focus")
	await _shot("loaded")
	# Ошибочный путь даёт настоящий HTTP404; повтор возвращает правильную таблицу.
	var endpoint := board_ui.endpoint
	board_ui.endpoint += "/missing"
	await _click(board_ui._open)
	await _wait_request()
	_check(board_ui._open.text == I18n.t("Повторить загрузку"), "HTTP error offers retry")
	_check(board_ui._rows.get_child_count() == 0, "error never presents stale rows as current")
	await _shot("error")
	board_ui.endpoint = endpoint
	await _click(board_ui._open)
	await _wait_request()
	_check(board_ui._rows.get_child_count() == 1, "retry after error recovers board")
	board_ui.endpoint = OS.get_environment("NECRO_BOARD_OFFLINE_URL")
	await _click(board_ui._open)
	await _wait_request()
	_check(board_ui._open.text == I18n.t("Повторить загрузку"), "connection refusal offers retry")
	board_ui.endpoint = endpoint
	await _click(board_ui._open)
	await _wait_request()
	_check(board_ui._rows.get_child_count() == 1, "retry after connection refusal recovers")
	var wrong_response := {"board": DailyBoardData.key("2026-01-01", "normal"), "rows": []}
	_check(not board_ui._valid_response(wrong_response), "response from different board rejected")
	wrong_response = {"board": key, "rows": [{"tenure": 1, "souls": 1, "verified": true}]}
	_check(not board_ui._valid_response(wrong_response), "unsupported verified claim rejected")
	board_ui._difficulty.select(2)
	board_ui._difficulty.item_selected.emit(2)
	_check(board_ui._send.disabled, "different difficulty cannot submit own result")
	await _click(board_ui._open)
	await _wait_request()
	_check(board_ui._rows.get_child_count() == 0, "server separates difficulty")
	board_ui.endpoint = ""
	board_ui._selection_changed()
	await _click(board_ui._open)
	_check(board_ui._status.text == I18n.t("Таблица пока недоступна. Личные рекорды сохранены."),
		"unconfigured/offline state is honest")
	await _shot("offline")
	_check(FileAccess.get_file_as_string(Campaign._path) == before_save,
		"reading/submitting/retrying leaves campaign and personal records byte-identical")
	_check(Campaign._scope == "campaign", "daily board never changes campaign scope")
	screen.queue_free()
	await _frames(5)
	print("DAILY BOARD: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)
