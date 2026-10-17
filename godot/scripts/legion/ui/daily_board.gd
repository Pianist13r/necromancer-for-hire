class_name DailyBoard
extends VBoxContainer
## Добровольная общая таблица. Публичного адреса пока нет: никаких фоновых запросов.
## QA задаёт NECRO_DAILY_BOARD_URL только в debug. UI не показывает детали транспорта.

var endpoint := ""
var board: Dictionary = {}
var _date: OptionButton
var _difficulty: OptionButton
var _status: Label
var _own: Label
var _rows: VBoxContainer
var _open: Button
var _send: Button
var _http: HTTPRequest
var _busy := false
var _posting := false
var _dates: Array[String] = []
var _request_focus: Control


func _ready() -> void:
	name = "DailyBoard"
	process_mode = Node.PROCESS_MODE_ALWAYS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	if endpoint.is_empty() and OS.is_debug_build():
		endpoint = OS.get_environment("NECRO_DAILY_BOARD_URL")
	# Локальная порция не разрешает произвольную отправку на внешний адрес.
	var endpoint_pattern := RegEx.new()
	endpoint_pattern.compile("^http://127[.]0[.]0[.]1:([0-9]{1,5})$")
	var match_endpoint := endpoint_pattern.search(endpoint)
	if match_endpoint == null or int(match_endpoint.get_string(1)) not in range(1, 65536):
		endpoint = ""
	add_child(UiStyle.label(I18n.t("Общая таблица «Вызова дня»"), 22,
		UiStyle.FONT_TITLE, UiStyle.GOLD))
	add_child(_label(I18n.t("Результаты игроков не проверены повтором боя.")))
	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 12)
	add_child(filters)
	_date = OptionButton.new()
	_date.name = "BoardDate"
	_date.custom_minimum_size = Vector2(170, 40)
	LegionUi.style_button(_date, LegionUi.INK, 18)
	_dates = DailyBoardData.dates()
	for date: String in _dates:
		_date.add_item(date)
	filters.add_child(_date)
	_difficulty = OptionButton.new()
	_difficulty.name = "BoardDifficulty"
	_difficulty.custom_minimum_size = Vector2(160, 40)
	LegionUi.style_button(_difficulty, LegionUi.INK, 18)
	for difficulty: String in LegionChallenge.ORDER:
		_difficulty.add_item(LegionChallenge.title(difficulty))
	_difficulty.select(LegionChallenge.ORDER.find(Settings.difficulty()))
	filters.add_child(_difficulty)
	filters.add_child(_label(I18n.t("Генератор v%d") % ProcGen.VERSION))
	_date.item_selected.connect(func(_index: int) -> void: _selection_changed())
	_difficulty.item_selected.connect(func(_index: int) -> void: _selection_changed())
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	add_child(actions)
	_open = _button("OpenBoard", I18n.t("Открыть таблицу"), _fetch)
	actions.add_child(_open)
	_send = _button("SendScore", I18n.t("Отправить мой результат"), _submit)
	actions.add_child(_send)
	add_child(_label(I18n.t("Отправляется только итог выбранной попытки: дата, версия, сид, ")
		+ I18n.t("сложность, стаж, души и случайный код попытки. Без имени и сохранения. ")
		+ I18n.t("Только по нажатию кнопки.")))
	_status = _label("")
	_status.name = "BoardStatus"
	add_child(_status)
	_own = _label("")
	_own.name = "OwnResult"
	add_child(_own)
	_rows = VBoxContainer.new()
	_rows.name = "BoardRows"
	add_child(_rows)
	_http = HTTPRequest.new()
	_http.timeout = 5.0
	_http.max_redirects = 0
	_http.body_size_limit = 32768
	add_child(_http)
	_http.request_completed.connect(_completed)
	_selection_changed()


func _selection_changed() -> void:
	board = DailyBoardData.key(_dates[_date.selected], LegionChallenge.ORDER[_difficulty.selected])
	_clear_rows()
	_status.text = I18n.t("Нажмите «Открыть таблицу», чтобы получить результаты.")
	if endpoint.is_empty():
		_status.text = I18n.t("Таблица пока недоступна. Личные рекорды сохранены.")
	_open.text = I18n.t("Открыть таблицу")
	var own := DailyBoardData.result(board)
	_own.text = I18n.t("Нет завершённой попытки на эту дату и сложность.")
	if not own.is_empty():
		_own.text = I18n.t("Ваш результат: стаж %d · души %d") % [own["tenure"], own["souls"]]
	_refresh_buttons()


func _refresh_buttons() -> void:
	_open.disabled = _busy
	_send.disabled = _busy or endpoint.is_empty() or DailyBoardData.result(board).is_empty()
	_date.disabled = _busy
	_difficulty.disabled = _busy


func _fetch() -> void:
	if _busy:
		return
	if endpoint.is_empty():
		_status.text = I18n.t("Таблица пока недоступна. Личные рекорды сохранены.")
		return
	_posting = false
	var query := "?version=%d&date=%s&seed=%d&difficulty=%s" % [board["version"],
		String(board["date"]).uri_encode(), board["seed"], board["difficulty"]]
	_start_request(endpoint + "/daily/v1" + query, HTTPClient.METHOD_GET)


func _submit() -> void:
	if _busy or endpoint.is_empty():
		return
	var payload := DailyBoardData.submission(board)
	if payload.is_empty():
		_status.text = I18n.t("Не удалось подготовить отправку. Личный результат сохранён.")
		return
	_posting = true
	_start_request(endpoint + "/daily/v1", HTTPClient.METHOD_POST, JSON.stringify(payload))


func _start_request(url: String, method: HTTPClient.Method, body: String = "") -> void:
	_request_focus = get_viewport().gui_get_focus_owner()
	_busy = true
	_clear_rows()
	_status.text = I18n.t("Отправляем результат…") if _posting else I18n.t("Загружаем таблицу…")
	_refresh_buttons()
	var error := _http.request(url, ["Content-Type: application/json"], method, body)
	if error != OK:
		_failed()


func _completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or code not in [200, 201]:
		_failed()
		return
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		_failed()
		return
	var data: Variant = parser.data
	if not data is Dictionary or data.get("schema") != 1 \
			or not data.get("verified") is bool or data["verified"]:
		_failed()
		return
	if _posting:
		if not data.get("accepted") is bool or not data["accepted"]:
			_failed()
			return
		_status.text = I18n.t("Результат принят без проверки боя. Откройте таблицу для просмотра.")
		_open.text = I18n.t("Обновить таблицу")
	else:
		if not _valid_response(data):
			_failed()
			return
		_status.text = I18n.t("Пока нет результатов.") if data["rows"].is_empty() \
			else I18n.t("По стажу, затем по душам. Все результаты не проверены.")
		var index := 0
		for row: Dictionary in data["rows"]:
			index += 1
			_rows.add_child(_label(I18n.t("%d. Игрок · стаж %d · души %d") % [index,
				int(row["tenure"]), int(row["souls"])]))
		_open.text = I18n.t("Обновить таблицу")
	_refresh_buttons()
	_restore_focus()


func _valid_response(data: Dictionary) -> bool:
	if not _valid_board(data.get("board")) or not data.get("rows") is Array:
		return false
	if data["rows"].size() > 50:
		return false
	for row: Variant in data["rows"]:
		if not row is Dictionary or not row.get("verified") is bool or row["verified"]:
			return false
		for field: String in ["tenure", "souls"]:
			var value: Variant = row.get(field)
			var maximum := 1000000.0 if field == "tenure" else 2147483647.0
			if not (value is float or value is int) or not is_finite(float(value)) \
					or float(value) < 0 or float(value) != floorf(float(value)) \
					or float(value) > maximum:
				return false
	return true


func _valid_board(returned: Variant) -> bool:
	if not returned is Dictionary or returned.size() != 4:
		return false
	for field: String in ["date", "difficulty"]:
		if returned.get(field) != board[field]:
			return false
	# JSON numbers become floats; dictionary equality would reject a valid integer key.
	for field: String in ["version", "seed"]:
		var value: Variant = returned.get(field)
		if not (value is float or value is int) or float(value) != float(board[field]):
			return false
	return true


func _failed() -> void:
	_busy = false
	_clear_rows()
	_status.text = I18n.t(
		"Не удалось связаться с таблицей. Личный результат сохранён. Повторите позже.")
	_open.text = I18n.t("Повторить загрузку")
	_refresh_buttons()
	_restore_focus()


func _restore_focus() -> void:
	# Не перетягиваем фокус, если игрок уже перешёл к другому разделу.
	if get_viewport().gui_get_focus_owner() == null and is_instance_valid(_request_focus) \
			and _request_focus.is_visible_in_tree():
		_request_focus.grab_focus()
	_request_focus = null


func _clear_rows() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()


static func _label(text: String) -> Label:
	var label := UiStyle.label(text, 17, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


static func _button(id: String, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = id
	button.text = text
	button.custom_minimum_size.y = 42
	LegionUi.style_button(button, LegionUi.INK, 18)
	button.pressed.connect(action)
	return button
