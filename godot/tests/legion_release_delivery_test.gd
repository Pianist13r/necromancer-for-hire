extends SceneTree
## B-404: реальные виджеты и обработчики, без запросов сети и открытия браузера.

class OfflineSession extends NetSession:
	var connected_url := ""
	var online := false

	func connect_lobby(url: String, _player_name: String) -> void:
		connected_url = url
		stage = Stage.CONNECTING
		status.emit("Подключение к серверу…")

	func is_online() -> bool:
		return online


class OfflineLobby extends NetLobby:
	var requested_url := ""
	var requests := 0
	var request_error: Error = OK

	func _request_server_address(url: String) -> Error:
		requested_url = url
		requests += 1
		return request_error


class OfflineSettings extends SettingsScreen:
	var opened_url := ""

	func _open_release_page(url: String) -> void:
		opened_url = url


const NEW_RELAY := "wss://relay.example.com:443/lobby"
var _fails := 0
var _checks := 0
var _shots := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == "--shots":
			_shots = args[i + 1]
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fails += 1
	print("  %s %s" % ["ok" if condition else "FAIL", message])


func _payload(value: Variant) -> PackedByteArray:
	return JSON.stringify({"relay": value}).to_utf8_buffer()


func _reply(lobby: OfflineLobby, value: Variant = NEW_RELAY,
		code: int = 200, result: int = HTTPRequest.RESULT_SUCCESS) -> void:
	lobby._on_server_info(result, code, [], _payload(value))


func _saved_url() -> String:
	var cfg := ConfigFile.new()
	cfg.load(NetLobby.CFG)
	return String(cfg.get_value("net", "url", ""))


func _write_url(url: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "url", url)
	cfg.set_value("net", "name", "Тест")
	cfg.save(NetLobby.CFG)


func _validation() -> void:
	for valid: String in [ReleaseInfo.DEFAULT_RELAY, NEW_RELAY, "wss://relay.example.com/"]:
		_check(ReleaseInfo.relay_from_body(_payload(valid)) == valid, "валидный wss: " + valid)
	for invalid: Variant in [null, 42, [], {}, "", "ws://relay.example.com",
		"https://relay.example.com", "file:///secret", "wss://user:pass@relay.example.com",
		"wss://relay.example.com@evil.com", "wss://localhost", "wss://127.0.0.1",
		"wss://relay.example.com:0", "wss://relay.example.com:65536",
		"wss://relay..example.com", "wss://-relay.example.com", "wss://relay-.example.com",
		"wss://relay.example.com#fragment", "wss://relay.example.com?query=1",
		" wss://relay.example.com", "wss://relay.example.com\n",
		"wss://relay.example.com/\tpath", "wss://relay.example.com/\\evil",
		"wss://relay.example.com/💀", "wss://relay.example.com/" + "a".repeat(512)]:
		_check(ReleaseInfo.relay_from_body(_payload(invalid)) == "", "отклонён: " + str(invalid))
	for raw: String in ["", "{broken", "[]", '"text"', "{}", '{"other":"wss://example.com"}']:
		_check(ReleaseInfo.relay_from_body(raw.to_utf8_buffer()) == "", "невалидный JSON/схема")
	_check(ReleaseInfo.relay_from_body(" ".repeat(4097).to_utf8_buffer()) == "",
		"ответ свыше лимита не принимается")


func _shot_sizes(screen: Control, prefix: String) -> void:
	if _shots == "":
		return
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	for dimensions: Vector2i in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = dimensions
		await process_frame
		await process_frame
		var scroll := screen.find_child("SettingsScroll", true, false) as ScrollContainer
		if scroll != null:
			scroll.scroll_vertical = 10000
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("%s/%s-%dx%d.png" % [
			_shots, prefix, dimensions.x, dimensions.y])


func _run() -> void:
	_validation()
	_write_url("")
	var session := OfflineSession.new()
	root.add_child(session)
	var lobby := OfflineLobby.new()
	lobby.setup(session)
	root.add_child(lobby)
	await process_frame
	_check(lobby.requests == 0, "при открытии нет фонового запроса")
	_check(lobby._url_edit.text == ReleaseInfo.DEFAULT_RELAY, "пустой сохранённый адрес → default")
	_check(lobby._server_http.timeout == 8.0 and lobby._server_http.body_size_limit == 4096
		and lobby._server_http.max_redirects == 0, "timeout/body/redirect policy применены")
	lobby._on_update_address()
	_check(lobby.requested_url == ReleaseInfo.SERVER_INFO_URL and lobby.requests == 1,
		"явная кнопка запрашивает фиксированный raw URL main")
	_check(lobby._update_address_btn.disabled, "повторная кнопка недоступна во время запроса")
	lobby._on_update_address()
	_check(lobby.requests == 1, "повторный запрос не запущен")
	_reply(lobby)
	_check(lobby._url_edit.text == NEW_RELAY and _saved_url() == NEW_RELAY,
		"валидный явный ответ применён и сохранён")
	_check(not lobby._update_address_btn.disabled, "после ответа кнопку можно повторить")
	await _shot_sizes(lobby, "lobby")

	for failure: Array in [[404, HTTPRequest.RESULT_SUCCESS], [0, HTTPRequest.RESULT_TIMEOUT],
		[0, HTTPRequest.RESULT_CANT_RESOLVE], [302, HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED],
		[200, HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED]]:
		lobby._on_update_address()
		_reply(lobby, NEW_RELAY, failure[0], failure[1])
		_check(lobby._url_edit.text == NEW_RELAY and _saved_url() == NEW_RELAY,
			"ошибка HTTP/сети сохраняет адрес")
		_check(lobby._address_status.text.contains("Текущий адрес сохранён"), "понятный fallback")
	lobby._on_update_address()
	_reply(lobby, "javascript:alert(1)")
	_check(_saved_url() == NEW_RELAY and lobby._address_status.text.contains("корректного"),
		"невалидный relay не применяется")
	lobby.request_error = ERR_CANT_CONNECT
	lobby._on_update_address()
	_check(not lobby._address_pending and not lobby._update_address_btn.disabled,
		"синхронная ошибка запуска освобождает кнопку")
	lobby.request_error = OK

	lobby._on_update_address()
	lobby._url_edit.text = "ws://localhost:18799"
	lobby._url_edit.text_changed.emit(lobby._url_edit.text)
	_reply(lobby)
	_check(lobby._url_edit.text == "ws://localhost:18799" and _saved_url() == NEW_RELAY,
		"запоздалый ответ не перезаписывает ручной ввод или сохранение")
	lobby._on_update_address()
	var before := lobby._url_edit.text
	lobby._url_edit.text_changed.emit("different")
	lobby._url_edit.text_changed.emit(before)
	_reply(lobby)
	_check(lobby._url_edit.text == before and lobby._address_status.text.contains("вручную"),
		"редактирование с возвратом прежнего текста тоже защищено")
	lobby._on_update_address()
	lobby._on_connect()
	_reply(lobby)
	_check(session.connected_url == "ws://localhost:18799" and _saved_url() == before,
		"ручной локальный ws подключается и сохраняется")
	_check(not lobby._address_pending and lobby._url_edit.text == before,
		"подключение отменяет прежний запрос")
	session.stage = NetSession.Stage.IDLE
	_reply(lobby)
	_check(_saved_url() == before, "старый ответ после неудачного подключения игнорируется")
	for active: int in [NetSession.Stage.CONNECTING, NetSession.Stage.LOBBY,
		NetSession.Stage.LOADING, NetSession.Stage.PLAYING, NetSession.Stage.OVER]:
		session.stage = NetSession.Stage.IDLE
		lobby._on_update_address()
		session.stage = active
		_reply(lobby)
		_check(lobby._url_edit.text == before and _saved_url() == before,
			"активная стадия %d защищена от ответа" % active)
		var requests := lobby.requests
		lobby._on_update_address()
		_check(lobby.requests == requests, "активная стадия блокирует новый запрос")
	session.stage = NetSession.Stage.IDLE
	lobby._on_update_address()
	session.online = true
	_reply(lobby)
	_check(lobby._url_edit.text == before and _saved_url() == before,
		"открытый сокет защищает даже при стадии IDLE")
	session.online = true
	lobby._on_update_address()
	_check(not lobby._address_pending, "открытый сокет блокирует обновление даже в IDLE")
	session.online = false
	lobby.free()
	var restored := OfflineLobby.new()
	restored.setup(session)
	root.add_child(restored)
	_check(restored._url_edit.text == before and restored.requests == 0,
		"после открытия сохранённый ручной адрес сохранён без запроса")
	restored._on_update_address()
	restored.free()
	_check(true, "закрытие лобби с запросом безопасно")
	session.free()

	var settings := OfflineSettings.new()
	root.add_child(settings)
	await process_frame
	var version := settings.find_child("SettingsVersion", true, false) as Label
	_check(version != null and version.text == "Версия " + ReleaseInfo.VERSION,
		"версия видна в О игре")
	var button := settings.find_child("SettingsReleases", true, false) as Button
	_check(button != null, "кнопка Версии и обновления доступна")
	button.pressed.emit()
	_check(settings.opened_url == "https://github.com/Pianist13r/necromancer-for-hire/releases",
		"нажатие открывает фиксированный Releases, браузер заменён тестовым double")
	await _shot_sizes(settings, "settings-about")
	settings.free()
	print("LEGION RELEASE DELIVERY: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
