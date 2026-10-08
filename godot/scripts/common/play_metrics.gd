class_name PlayMetrics
extends Node
## Optional, memory-only session counter. Never reads user logs or identifiers.
## No telemetry in editors, headless tests, command-line QA, or without consent.

const ENDPOINT := "https://51-250-12-39.sslip.io/metrics/v1"
const VERSION := ReleaseInfo.VERSION
const SECTION := "privacy"
const KEY := "share_play_metrics"
## Скрытая пометка «внутренний запуск» (машина автора, свои проверки): в меню её нет,
## ставится строкой `internal=true` в [privacy] settings.cfg. Без неё запуски автора с
## согласием смешиваются с игроками рекламного теста (METRICS_AUDIT_1007 п.1).
const INTERNAL_KEY := "internal"
const INTERVAL := 60.0
const NOTICE := ("Помочь улучшить игру?\n\n"
	+ "Можно отправлять автору версию игры, систему, число сеансов и минуты "
	+ "активного боя. Без имени, постоянного идентификатора, сохранений и логов.\n\n"
	+ "Записи сеансов удаляются после 30 дней на сервере автора в России; "
	+ "общие итоги без кодов сеансов сохраняются. "
	+ "IP нужен для соединения, но в статистику и её журналы не записывается. "
	+ "Отключить отправку можно в настройках. Игра доступна при любом выборе.")

var main: Node = null
var session := ""
var seconds := 0.0
var seq := 0
var _elapsed := 0.0
var _last_tick := 0
var _http: HTTPRequest
var _busy := false
var _allowed := false
var _was_playing := false
var _pending: Dictionary = {}
var _endpoint := ENDPOINT  # Only test harnesses replace this with a loopback receiver.
var _last_send := -10000
var _played_once := false
var _offered := false
var _result_quiet := 0.0


static func consent() -> bool:
	return Settings.get_value(SECTION, KEY, false) == true


static func internal() -> bool:
	return Settings.get_value(SECTION, INTERNAL_KEY, false) == true


## Отправка возможна только из экспортной сборки, запущенной как у игрока. Пометка
## «внутренний» гасит и окно согласия: ответ игрока в settings.cfg не меняется.
static func may_send(ship: bool, display: String, user_args: PackedStringArray,
		no_metrics_env: String) -> bool:
	return ship and display != "headless" and user_args.is_empty() \
		and no_metrics_env != "1" and not internal()


static func active_play(world: Node, focused: bool) -> bool:
	return focused and is_instance_valid(world) and world is LegionWorld \
		and world.phase == LegionWorld.Phase.BATTLE and not world.paused \
		and not world.hold and not world.is_ground_loading() and world.is_visible_in_tree()


func _ready() -> void:
	main = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS
	_allowed = may_send(OS.has_feature("ship"), DisplayServer.get_name(),
		OS.get_cmdline_user_args(), OS.get_environment("NECRO_NO_METRICS"))
	if not _allowed:
		set_process(false)
		return
	_http = HTTPRequest.new()
	_http.timeout = 8.0
	_http.body_size_limit = 1024
	_http.max_redirects = 0
	add_child(_http)
	_http.request_completed.connect(_completed)
	_last_tick = Time.get_ticks_msec()


func show_consent() -> void:
	var answer: Variant = Settings.get_value(SECTION, KEY, "pending")
	if _offered or answer is bool:
		return
	_offered = true
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = NOTICE
	dialog.ok_button_text = "Да, отправлять статистику"
	dialog.cancel_button_text = "Нет, спасибо"
	dialog.min_size = Vector2i(580, 340)
	UiStyle.style_dialog(dialog, "Помочь игре стать лучше")
	dialog.confirmed.connect(func() -> void:
		Settings.set_value(SECTION, KEY, true)
		dialog.queue_free())
	dialog.canceled.connect(func() -> void:
		Settings.set_value(SECTION, KEY, false)
		dialog.queue_free())
	var later := dialog.add_button("Позже", true, "later")
	dialog.custom_action.connect(func(action: StringName) -> void:
		if action == &"later":
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()
	later.grab_focus()


## Только после сыгранного боя и трёх секунд на результате/в меню, не поверх обучения.
func consider_consent(playing: bool, resting: bool, wall: float) -> void:
	_played_once = _played_once or playing
	_result_quiet = _result_quiet + wall if resting and _played_once else 0.0
	if _allowed and _result_quiet >= 3.0:
		show_consent()


func _process(_delta: float) -> void:
	var tick := Time.get_ticks_msec()
	# Monotonic wall time, independent of slow motion; suspend gaps are not play.
	var wall := minf(float(tick - _last_tick) / 1000.0, 1.0)
	_last_tick = tick
	if main is LegionMain:
		var current_world: LegionWorld = main.world
		var resting: bool = main.screen is LegionResult or main.screen is LegionMenu
		consider_consent(active_play(current_world, get_window().has_focus()),
			resting and main.screen.is_visible_in_tree(), wall)
	if not consent():
		if _busy:
			_http.cancel_request()
		_busy = false
		session = ""
		seconds = 0.0
		_elapsed = 0.0
		seq = 0
		_pending.clear()
		_last_send = -10000
		_was_playing = false
		return
	if session.is_empty():
		session = Crypto.new().generate_random_bytes(16).hex_encode()
		_send()
	var world: Node = main.get("world")
	var playing := active_play(world, get_window().has_focus())
	if playing:
		seconds = minf(seconds + wall, 86400.0)
	if _was_playing and not playing:
		_send()  # Menu, pause and focus loss preserve the completed part of a short battle.
	_was_playing = playing
	_elapsed += wall
	if _elapsed >= INTERVAL:
		_elapsed = 0.0
		_send()


func _send() -> void:
	if _busy or not consent() or session.is_empty():
		return
	if Time.get_ticks_msec() - _last_send < 10000:
		return
	var platform := OS.get_name()
	if platform not in ["Windows", "Linux", "macOS"]:
		return
	if _pending.is_empty():
		_pending = {"schema": 1, "session": session, "seq": seq,
			"version": VERSION, "platform": platform,
			"play_seconds": 0 if seq == 0 else int(seconds)}
	_busy = _http.request(_endpoint, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(_pending)) == OK
	_last_send = Time.get_ticks_msec()


func _completed(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	_busy = false
	if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
		seq += 1
		_pending.clear()
	elif code == 409:
		# Retention expired or server lost its state. Never replay an old session.
		session = ""
		seconds = 0.0
		seq = 0
		_pending.clear()
