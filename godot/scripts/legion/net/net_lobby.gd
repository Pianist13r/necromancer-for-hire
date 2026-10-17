class_name NetLobby
extends Control
##
## Общее лобби онлайн-«Схватки» (Игорь 01.10: «чтобы любой с любым мог зайти поиграть»):
## имя и адрес сервера → кто онлайн и открытые комнаты → «Играть» в чужой комнате или своя
## комната с ожиданием. Адрес и имя запоминаются в user://net.cfg; актуальный адрес можно
## получить по явной кнопке из публичного server.json, ручной ввод сохраняется.
##
## Экран без ссылок на LegionMain: сессия (NetSession) живёт у PvpFlow и переживает экран, матч
## запускает PvpFlow по сигналу сессии match_start.
##
## Без тупиков (slow/lobby-ux): строка состояния — словами этого экрана по стадии сессии
## («Подключаемся…», «Открытых комнат нет», «Ждём соперника · 0:37»), отказ — красным до
## следующего действия игрока. Сервер недоступен или соперника нет дольше
## LegionCfg.LOBBY_BOT_OFFER_S — кнопка «Никого нет — сыграть с ботом» (сама матч не начинает).
##

signal back
## «Никого нет — сыграть с ботом»: поле своей комнаты («pvp:duel» / «gen:…») или «Дуэль».
## Свою комнату лобби уже закрыло (cancel_room); соединение закрывает PvpFlow.
signal play_bot(map: String)

const CARD_W := 640.0
const CFG := "user://net.cfg"
const MAP_TITLES := {"pvp:duel": "Дуэль", "gen:": "Случайное поле"}
const BOT_TEXT := "Никого нет — сыграть с ботом"
const SERVER_DOWN := "Сервер недоступен — проверьте адрес или играйте с ботом"
## Отказы, которые присылает сам сервер: их слова точнее, чем «сервер недоступен».
const SERVER_CODES: Array[String] = ["proto", "full", "rate_limit", "idle_timeout", "build",
	"busy", "no_room"]

var session: NetSession

var _name_edit: LineEdit
var _url_edit: LineEdit
var _connect_btn: Button
var _status: Label
var _online: Label
var _rooms_box: VBoxContainer
var _create_row: HBoxContainer
var _code_row: HBoxContainer
var _code_edit: LineEdit
var _direct: CheckBox
var _update_address_btn: Button
var _address_status: Label
var _server_http: HTTPRequest
var _address_pending := false
var _address_at_request := ""
var _url_revision := 0
var _revision_at_request := 0
var _bot_btn: Button
## Отказ (красным) — держится до следующего действия игрока или нового слова сессии.
var _note := ""
var _note_shown := false
## Последнее слово сессии (загрузка матча и т. п.) — для стадий, которые экран сам не называет.
var _session_text := ""
## Подключение доходило до лобби: обрыв после этого — «связь потеряна», а не «сервер недоступен».
var _reached_lobby := false
var _had_failure := false
## По последнему списку: чужих открытых комнат и поле своей ожидающей ("" — своей нет).
var _foreign_rooms := 0
var _my_room_map := ""
## Секунд в лобби без чужих комнат (порог предложения бота) и в ожидании в своей комнате.
var _alone_t := 0.0
var _wait_t := 0.0


func setup(s: NetSession) -> NetLobby:
	session = s
	return self


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.92)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	var box := UiStyle.card_box(self, CARD_W, 10)
	var title := UiStyle.label(I18n.t("Схватка по сети"), 40, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	_name_edit = _edit(box, I18n.t("Имя"), String(cfg.get_value("net", "name", "")), I18n.t(
		"Как вас видят другие"))
	var saved_url := String(cfg.get_value("net", "url", "")).strip_edges()
	_url_edit = _edit(box, I18n.t("Сервер"),
		saved_url if saved_url != "" else ReleaseInfo.DEFAULT_RELAY,
		I18n.t("Адрес сервера, например wss://example.com"))
	_url_edit.text_changed.connect(func(_text: String) -> void: _url_revision += 1)
	_update_address_btn = _btn(I18n.t("Обновить адрес"), 240.0)
	_update_address_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_update_address_btn.pressed.connect(_on_update_address)
	box.add_child(_update_address_btn)
	_address_status = UiStyle.label("", 16, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	_address_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_address_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_address_status)
	_server_http = HTTPRequest.new()
	_server_http.timeout = ReleaseInfo.SERVER_TIMEOUT
	_server_http.body_size_limit = ReleaseInfo.SERVER_BODY_LIMIT
	_server_http.download_chunk_size = ReleaseInfo.SERVER_BODY_LIMIT
	# Источник фиксирован: перенаправление на другой сайт не выполняем.
	_server_http.max_redirects = 0
	_server_http.accept_gzip = false
	_server_http.request_completed.connect(_on_server_info)
	add_child(_server_http)
	# прямое соединение быстрее сервера, но соперник узнаёт ваш IP-адрес — выбор за игроком
	_direct = CheckBox.new()
	_direct.text = I18n.t("Прямое соединение (видны ваш IP и адреса домашней сети)")
	_direct.button_pressed = bool(cfg.get_value("net", "direct", false))
	_direct.add_theme_font_override("font", UiStyle.FONT_TEXT)
	_direct.add_theme_font_size_override("font_size", 16)
	_direct.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_direct.toggled.connect(_on_direct)
	box.add_child(_direct)
	session.direct_enabled = _direct.button_pressed
	_connect_btn = _btn(I18n.t("Подключиться"), 260.0)
	_connect_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_connect_btn.pressed.connect(_on_connect)
	box.add_child(_connect_btn)
	_status = UiStyle.label("", 18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	_status.name = "LobbyStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_bot_btn = _btn(I18n.t(BOT_TEXT), 400.0)
	_bot_btn.name = "LobbyBot"
	_bot_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bot_btn.visible = false
	_bot_btn.pressed.connect(_on_bot)
	box.add_child(_bot_btn)
	_online = UiStyle.label("", 16, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	_online.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_online.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_online)
	_rooms_box = VBoxContainer.new()
	_rooms_box.add_theme_constant_override("separation", 6)
	box.add_child(_rooms_box)
	_create_row = HBoxContainer.new()
	_create_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_create_row.add_theme_constant_override("separation", 12)
	box.add_child(_create_row)
	for map: String in ["pvp:duel", "gen:"]:
		var b := _btn(I18n.t("Открыть: %s") % I18n.t(String(MAP_TITLES[map])), 280.0)
		b.pressed.connect(func() -> void:
			_note = ""
			session.create_room(map))
		_create_row.add_child(b)
	_code_row = HBoxContainer.new()
	_code_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_code_row.add_theme_constant_override("separation", 8)
	box.add_child(_code_row)
	_code_row.add_child(UiStyle.label(I18n.t("Код комнаты:"), 16, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM))
	_code_edit = LineEdit.new()
	_code_edit.custom_minimum_size = Vector2(110.0, 36.0)
	_code_edit.max_length = 8
	_code_row.add_child(_code_edit)
	var join := _btn(I18n.t("Войти"), 120.0)
	join.pressed.connect(func() -> void:
		_note = ""
		session.join_room(_code_edit.text))
	_code_row.add_child(join)
	LegionUi.nav_bar(self, I18n.t("← Назад"), func() -> void: back.emit())
	# status раньше не был подключён вовсе: «Подключение…» и код своей комнаты не показывались
	session.status.connect(_on_status)
	session.failed.connect(_on_failed)
	session.lobby.connect(_on_lobby)
	_reached_lobby = session.is_online() or session.last_error != ""   # из матча — уже были в лобби
	_refresh_mode()
	# в лобби строку состояния соберёт _process по стадии сессии
	if session.last_error != "":
		_on_failed(session.last_error)
		session.last_error = ""
	elif not session.is_online():
		if _name_edit.text == "":
			_name_edit.grab_focus.call_deferred()
		else:
			_connect_btn.grab_focus.call_deferred()
	_process(0.0)


func _exit_tree() -> void:
	_cancel_address_update()
	if session != null:
		for pair: Array in [[session.status, _on_status], [session.failed, _on_failed],
				[session.lobby, _on_lobby]]:
			var sig: Signal = pair[0]
			if sig.is_connected(pair[1]):
				sig.disconnect(pair[1])


## Esc — «Назад». ui_cancel, а не «pause»: в «pause» замаплена и латинская P, а _input идёт
## РАНЬШЕ GUI — буква P закрывала лобби прямо при наборе имени и адреса (https…), до LineEdit
## событие не доходило. echo гасим — автоповтор Esc не дублирует «Назад». Потребляем: мир под
## экраном тоже слушает «pause».
func _input(event: InputEvent) -> void:
	if visible and not event.is_echo() and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		back.emit()


func _on_connect() -> void:
	# Запрос, начатый до подключения, уже не вправе менять адрес следующего подключения.
	_cancel_address_update()
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value("net", "name", _name_edit.text.strip_edges())
	cfg.set_value("net", "url", _url_edit.text.strip_edges())
	cfg.save(CFG)
	# новое подключение — с чистого листа (отказ сессии может прийти прямо из connect_lobby)
	_note = ""
	_had_failure = false
	_reached_lobby = false
	_foreign_rooms = 0
	_my_room_map = ""
	session.connect_lobby(_url_edit.text, _name_edit.text)
	_refresh_mode()
	_process(0.0)


func _on_update_address() -> void:
	if _address_pending or session.stage != NetSession.Stage.IDLE or session.is_online():
		return
	_address_pending = true
	_address_at_request = _url_edit.text
	_revision_at_request = _url_revision
	_address_status.text = I18n.t("Получаем актуальный адрес…")
	_refresh_mode()
	var error := _request_server_address(ReleaseInfo.SERVER_INFO_URL)
	if error != OK:
		_on_server_info(HTTPRequest.RESULT_CANT_CONNECT, 0, [], PackedByteArray())


func _request_server_address(url: String) -> Error:
	return _server_http.request(url, ["Accept: application/json"])


func _cancel_address_update() -> void:
	if _address_pending and _address_status != null:
		_address_status.text = I18n.t("Обновление адреса отменено — текущий адрес сохранён.")
	_address_pending = false
	if _server_http != null:
		_server_http.cancel_request()


func _on_server_info(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if not _address_pending:
		return
	_address_pending = false
	_refresh_mode()
	if session.stage != NetSession.Stage.IDLE or session.is_online():
		_address_status.text = I18n.t("Подключение уже началось — адрес оставлен прежним.")
		return
	if _revision_at_request != _url_revision or _address_at_request != _url_edit.text:
		_address_status.text = I18n.t("Адрес изменён вручную — ваш ввод сохранён.")
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_address_status.text = I18n.t(
			"Не удалось обновить адрес. Текущий адрес сохранён; попробуйте позже.")
		return
	var relay := ReleaseInfo.relay_from_body(body)
	if relay == "":
		_address_status.text = I18n.t("В ответе нет корректного адреса. Текущий адрес сохранён.")
		return
	_url_edit.text = relay
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value("net", "url", relay)
	var error := cfg.save(CFG)
	_address_status.text = I18n.t("Адрес обновлён. Теперь можно подключиться.") if error == OK else (
		I18n.t("Адрес обновлён для этого запуска, но сохранить его не удалось."))


## Галочка действует и в лобби (на следующий матч) и запоминается рядом с адресом и именем.
func _on_direct(on: bool) -> void:
	session.direct_enabled = on
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value("net", "direct", on)
	cfg.save(CFG)


func _on_status(text: String) -> void:
	if session.stage != NetSession.Stage.IDLE:
		_cancel_address_update()
	_session_text = text
	_note = ""
	_refresh_mode()


## Отказ: транспортный до входа в лобби — «сервер недоступен» с выходом на бота; отказ самого
## сервера (версия, занят, нет комнаты) и обрыв уже из лобби — словами сессии.
func _on_failed(text: String) -> void:
	_had_failure = true
	_note = I18n.t(SERVER_DOWN) if not _reached_lobby and not _server_text(text) else text
	_refresh_mode()
	_process(0.0)


static func _server_text(text: String) -> bool:
	for code in SERVER_CODES:
		if text == NetSession._error_text(code):
			return true
	return text.begins_with(NetSession._error_text("").get_slice(":", 0))


## Каждый кадр: часы ожидания, порог предложения бота и строка состояния.
func _process(delta: float) -> void:
	var in_lobby := session.is_online() and session.stage == NetSession.Stage.LOBBY
	_reached_lobby = _reached_lobby or in_lobby
	_alone_t = _alone_t + delta if in_lobby and _foreign_rooms == 0 else 0.0
	_wait_t = _wait_t + delta if in_lobby and _my_room_map != "" else 0.0
	var dead := _had_failure and not session.is_online() and session.stage == NetSession.Stage.IDLE
	_bot_btn.visible = dead or (in_lobby and _alone_t >= LegionCfg.LOBBY_BOT_OFFER_S)
	var bad := _note != ""
	_status.text = _note if bad else _live_status()
	if bad != _note_shown:
		_note_shown = bad
		_status.add_theme_color_override("font_color", UiStyle.BAD if bad else UiStyle.TEXT_DIM)


func _live_status() -> String:
	match session.stage:
		NetSession.Stage.IDLE:
			return ""
		NetSession.Stage.CONNECTING:
			return I18n.t("Подключаемся…")
		NetSession.Stage.LOBBY:
			if _my_room_map != "":
				return I18n.t("Ждём соперника · %d:%02d") % [floori(_wait_t / 60.0), int(_wait_t) % 60]
			if _foreign_rooms == 0:
				return I18n.t("Открытых комнат нет")
			return I18n.t("Вы в лобби как «%s»") % session.my_name
	return _session_text   # загрузка матча — словами сессии («Соперник — …, загрузка…»)


## «Никого нет — сыграть с ботом»: свою комнату закрываем как «Закрыть», поле — её же.
func _on_bot() -> void:
	var map := _my_room_map if _my_room_map != "" else PvpMaps.DUEL
	if _my_room_map != "" and session.is_online():
		session.cancel_room()
	play_bot.emit(map)


func _on_lobby(rooms: Array, players: Array, in_game: int) -> void:
	var focused := get_viewport().gui_get_focus_owner()
	var room_focus: Array = []
	if focused != null and _rooms_box.is_ancestor_of(focused):
		room_focus = focused.get_meta("room_focus", [])
	var names: Array[String] = []
	for n: Variant in players:
		names.append(String(n))
	_online.text = I18n.t("В лобби: %s%s") % [", ".join(names),
		(I18n.t(" · в бою: %d") % in_game) if in_game > 0 else ""]
	for c in _rooms_box.get_children():
		c.queue_free()
	var waiting_mine := false
	_foreign_rooms = 0
	_my_room_map = ""
	for r: Variant in rooms:
		if not (r is Dictionary):
			continue
		var room: Dictionary = r
		var map := String(room.get("map", ""))
		var map_title: String = MAP_TITLES.get(map, MAP_TITLES["gen:"] if map.begins_with("gen:")
			else map)
		map_title = I18n.t(map_title)
		if bool(room.get("mine", false)):
			waiting_mine = true
			_my_room_map = map if map != "" else PvpMaps.DUEL
			# код — чтобы позвать знакомого («Код комнаты» у него); время ожидания — в строке состояния
			var my_code := String(room.get("code", session.room_code))
			var row := _room_row(I18n.t("Ваша комната %s · %s") % [my_code, map_title],
				I18n.t("Закрыть"), [my_code, "cancel"])
			(row.get_child(1) as Button).pressed.connect(func() -> void:
				_note = ""
				session.cancel_room())
			continue
		_foreign_rooms += 1
		var host := String(room.get("host", "?"))
		var code := String(room.get("code", ""))
		var row2 := _room_row("«%s» · %s" % [host, map_title], I18n.t("Играть"), [code, "join"])
		(row2.get_child(1) as Button).pressed.connect(func() -> void: session.join_room(code))
	# пустой список называет строка состояния («Открытых комнат нет»)
	_create_row.visible = session.is_online() and not waiting_mine
	if not room_focus.is_empty():
		_restore_room_focus(room_focus)


func _restore_room_focus(key: Array) -> void:
	# Only replace focus that belonged to a room action. Never select another room.
	for row: Node in _rooms_box.get_children():
		if row.is_queued_for_deletion():
			continue
		var button := row.get_child(1) as Button
		if button.get_meta("room_focus", []) == key:
			button.grab_focus()
			return
	var back_button := find_child("NavBack", true, false) as Button
	if back_button != null and back_button.is_visible_in_tree():
		back_button.grab_focus()


func _room_row(text: String, action: String, key: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UiStyle.label(text, 20, UiStyle.FONT_TEXT, UiStyle.TEXT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var button := _btn(action, 150.0)
	button.set_meta("room_focus", key)
	row.add_child(button)
	_rooms_box.add_child(row)
	return row


## Пока не подключены — поля имени и адреса; в лобби — комнаты и кнопки создания.
func _refresh_mode() -> void:
	var online := session.is_online() and session.stage != NetSession.Stage.CONNECTING
	_name_edit.get_parent().visible = not online
	_url_edit.get_parent().visible = not online
	_update_address_btn.visible = not online
	_update_address_btn.disabled = _address_pending or session.stage != NetSession.Stage.IDLE
	_address_status.visible = not online
	_connect_btn.visible = not online and session.stage != NetSession.Stage.CONNECTING
	_create_row.visible = online
	_code_row.visible = online
	_rooms_box.visible = online
	_online.visible = online


func _edit(box: VBoxContainer, caption: String, value: String, hint: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var l := UiStyle.label(caption, 20, UiStyle.FONT_TEXT, UiStyle.TEXT)
	l.custom_minimum_size = Vector2(90.0, 0.0)
	row.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.placeholder_text = hint
	e.custom_minimum_size = Vector2(480.0, 38.0)
	e.add_theme_font_override("font", UiStyle.FONT_TEXT)
	e.add_theme_font_size_override("font_size", 18)
	e.text_submitted.connect(func(_t: String) -> void: _on_connect())
	row.add_child(e)
	return e


func _btn(text: String, w: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, 44.0)
	b.add_theme_font_override("font", UiStyle.FONT_TITLE)
	b.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(b)
	return b
