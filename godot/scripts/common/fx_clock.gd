class_name FxClock
extends RefCounted
##
## Часы визуальных эффектов и звуковых ограничителей (REC-01, аудит записи 08.10.2026).
##
## Вспышки фигур, пульсации, «стена», окна реплик и лимиты частоты звуков считали
## Time.get_ticks_msec() — настенные часы. В живой игре это то же, что время кадров, но Movie Maker
## (--write-movie) рендерит не в реальном времени: запись 1080p идёт ~в 4 раза медленнее жизни,
## и эффект в 420 мс занимал в ролике 5 кадров вместо 25, а звуки накладывались.
##
## Режим кадров: сумма delta кадров (без Engine.time_scale) — ровно 1000/fps мс на кадр,
## детерминированно; включается сам в Movie Maker (OS.has_feature("movie")) или вызовом
## use_frames() (режиссёр записи — его прогон без записи совпадает с записью; регресс-тест).
## Иначе — настенные часы, как было: живая игра и прежние тесты не меняются. Как и настенные
## часы, режим кадров идёт и на паузе дерева и не стоит в стоп-кадре мира.
##
## Сетевые таймауты и замеры остаются на Time.get_ticks_msec(): им нужно настоящее время, а не
## вид. Тишина и откат колеса и прореживание стрелки AIM в ContractField — на FxClock (режиссёр
## записи подаёт ввод по кадрам; в живой игре это те же настенные часы, slow/controls-1008).
##

static var _frames := false
static var _checked := false
static var _acc_ms := 0.0
static var _ticker: Node = null


## Миллисекунды часов эффектов (сравнивать только разности).
static func ms() -> int:
	if not _checked:
		_checked = true
		if OS.has_feature("movie"):
			use_frames()
	if not _frames:
		return Time.get_ticks_msec()
	if _ticker == null or not is_instance_valid(_ticker):
		_ensure_ticker()
	return int(_acc_ms)


## Перейти на часы кадров. Отсчёт продолжается с текущих настенных миллисекунд — метки, уже
## поставленные по настенным часам, остаются сравнимыми.
static func use_frames() -> void:
	_checked = true
	if _frames:
		return
	_frames = true
	_acc_ms = float(Time.get_ticks_msec())
	_ensure_ticker()


static func frames_mode() -> bool:
	return _frames


static func _ensure_ticker() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	_ticker = _Ticker.new()
	_ticker.name = "FxClockTicker"
	tree.root.add_child.call_deferred(_ticker)


class _Ticker:
	extends Node

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = -1000   # раньше всех в кадре: эффекты кадра видят одно время

	func _process(delta: float) -> void:
		var scale := Engine.time_scale
		FxClock._acc_ms += (delta / scale if scale > 0.0 else delta) * 1000.0
