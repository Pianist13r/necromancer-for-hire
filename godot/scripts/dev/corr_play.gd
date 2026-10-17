extends Node
##
## Игра по переписке: мир стоит, пока игрок-агент смотрит кадр и пишет ход в файл.
## Нужна инстансу, который играет сам, но не в реальном времени (сессия 3d5683fc, 25.09.2026).
##
##   --dev corr=C:/путь/к/папке   (в паре с --map <id> --mute; только отладочная сборка)
##
## Цикл хода N: мир на удержании → кадр turn_N.png + состояние turn_N.json + waiting.txt (N) →
## ждём move_N.json → выполняем действия НАСТОЯЩИМИ событиями ввода (Input.parse_input_event,
## как legion_tutorial_driver.gd) → мир идёт `wait` игровых секунд → ход N+1.
## Бой кончился → кадр и состояние с "over": true, затем выход.
##
## «С часами» (--dev corr_clock=1.5, сессия 9ef4ccac): мир НЕ стоит, пока выполняются действия
## хода (рука чертит и жмёт в живом мире), и каждый ход — ровно столько игровых секунд от начала
## действий; `wait` хода не действует. Думать дольше можно, но мир всё равно ушёл на эти секунды —
## ближе к живой игре, чем замерший мир (B-045: темп «Лабиринта» для человека).
##
## move_N.json: {"actions": [...], "wait": 3.0}. Действия (координаты мировые, 1280×720):
##   {"kind": 1|2|3} — клавиша типа договора
##   {"draw": [[x,y], ...], "toward": [x,y], "peek": true} — протяжка ЛКМ по ломаной;
##       toward — перед отпусканием держать Пробел и повести указатель к точке (стрелка
##       договора смотрит туда); peek — кадр turn_N_peek.png до отпускания ЛКМ (видно, кого
##       захватит линия). Замкнутый круг (конец у начала, длина от 220 px, 12+ точек по
##       окружности) — «Оцепление»: договор-кольцо, стрелки к центру; rtap/sling по любому его
##       участку срывает всё кольцо разом, aim изнутри/снаружи — стрелки к центру/наружу
##   {"aim": [[x,y], [x,y]]} — Пробел над участком живой линии, указатель к цели: повернуть
##       стрелку готового договора
##   {"sling": [[x,y], [x,y]]} — ПКМ на участке, оттянуть ко второй точке, отпустить
##   {"tap": [x,y]} / {"rtap": [x,y]} — щелчок ЛКМ / ПКМ
##   {"key": "Q"|"W"|"E"|"R"|"F"|"N"|"SPACE", "at": [x,y]} — клавиша, мышь заранее в at (прицел;
##       R — «Сбор» к at, F/N — вызвать волну; "TAB" — стереть кусок линии под at, бойцы в натиск;
##       "D" — «Касса» одиночного боя, at не нужен; в «Схватке» Дэ ничего не делает)
##   {"wheel": 1|-1} — прокрутка колеса (вид договора по кругу; 1 — вниз)
##   {"quit": true} — выйти: верхним ключом хода (move_N.json = {"quit": true}; actions того же
##       хода тогда НЕ выполняются) или действием в actions (после действий, стоящих до него)
## Настоящие мышь и клавиатура на время прогона глушатся, как у водителя обучения.
##
## «Схватка» (P7, 30.09.2026): тот же режим — `res://scenes/legion_world.tscn -- --mute
## --map pvp:duel --dev corr=папка` (или gen:<сид>:3:pvp); ты — сторона 0, соперник — PvpBot.
## Поле 1600×900 на экране 1280×720 (камера ×0,8): ВСЕ координаты ходов и состояния — МИРОВЫЕ
## (1600×900); мышь переводится в экран тем же `LegionWorld.world_to_screen`, что у человека;
## кнопки и пункты меню в состоянии тоже даны в мировых координатах (tap — как есть).
## Кадр — экран целиком (вид игрока). Своя половина слева (x < 800), Котёл соперника справа.
## В состоянии хода: pvp {clock, limit, left, wave, foe{hp,max,army,souls,at}, result}, foe_army —
## армия соперника кучками [x, y, сколько], near — соперник в 110 px от каждого твоего участка
## (по id договора и участку), buildings — с полем side; army/souls/mana/hp — стороны 0.
##
## turn_N.json, кроме боя и врагов: free_at — кучки СВОИХ свободных бойцов [x, y, сколько] (они
## стоят, где кончили натиск, и сами не ходят), buildings — постройки (уровень, живые/штат, дверь),
## menu — пункты открытого меню площадки с центрами для tap, cd — откаты Q/W/E, combo — [счёт,
## множитель]. Второй peek за ход пишется в turn_N_peek2.png, третий — peek3 (сессия a660c562).
##
## Кампания по переписке (сессия 180f1168, 27.09.2026) — вся кампания как у игрока: меню,
## брифинги, уроки и открытия по лестнице, поправки, подготовка на брифинге, «Досье»:
##   --dev corr=C:/папка --dev save=user://файл.cfg [--dev save_keep=1] --mute   (без --map)
## Сохранение — только своё (настоящее legion.cfg владельца отказом: error.txt и выход);
## save_keep=1 — продолжить это сохранение, а не начать с чистого листа. Ходы идут одной
## нумерацией. В бою — как выше; вне боя (меню, брифинг, итог, досье, пауза) — ход «меню»:
## "mode": "menu", buttons — видимые кнопки с текстом и центром для tap, texts — видимые
## надписи экрана, camp — прогресс сохранения; `wait` — реальные секунды после действий (0,5).
## Бой кончился — не выход, а следующий ход меню (экран итога). Выход — только {"quit": true}.
## Бой, начавшийся во время хода меню (кончилась «Подготовка боя…», пока агент думал, или бой
## начал сам ход), стоит до первого хода боя; ход, написанный к кадру меню, после такой загрузки
## исполняется уже как ход боя (B-504).
##

const DEVICE := 8
const STEP_PX := 10.0
const DEFAULT_WAIT := 3.0
## Клетка, по которой свободные бойцы собираются в кучки для состояния хода.
const FREE_CELL := 80.0
## «Схватка»: радиус, в котором соперник считается «у участка» (состав в `near` участка).
const NEAR_R := 110.0
const KEYS := {"Q": KEY_Q, "W": KEY_W, "E": KEY_E, "N": KEY_N, "SPACE": KEY_SPACE, "R": KEY_R,
	"F": KEY_F, "D": KEY_D,
	"TAB": KEY_TAB, "1": KEY_1, "2": KEY_2, "3": KEY_3, "ESC": KEY_ESCAPE, "ENTER": KEY_ENTER}
## Ход меню: сколько реальных секунд дать экрану после действий (анимации, смена экрана).
const MENU_WAIT := 0.5
## Ход меню: пауза перед кадром, пока экран проявляется (реальные секунды).
const MENU_SETTLE := 0.6
## Потолок надписей меню в состоянии хода: экран «Как играть» длинный, остальное — короткое.
const MENU_TEXTS_MAX := 80


## Each external wait has its own completion signal. On detach the node can
## settle it before Godot frees the suspended GDScript instance.
class PendingWait:
	extends RefCounted
	signal resolved(ok: bool)
	var source: Object = null
	var signal_name: StringName
	var callback: Callable
	var settled := false

	func listen(target: Object, name: StringName) -> Error:
		source = target
		signal_name = name
		callback = Callable(self, "_on_source")
		return source.connect(signal_name, callback, Object.CONNECT_ONE_SHOT)

	func _on_source() -> void:
		_settle(true)

	func cancel() -> void:
		_settle(false)

	func _settle(ok: bool) -> void:
		if settled:
			return
		settled = true
		if is_instance_valid(source) and source.is_connected(signal_name, callback):
			source.disconnect(signal_name, callback)
		source = null
		resolved.emit(ok)

var world: LegionWorld = null
## Кампания по переписке: главный узел (legion_main.gd), world берётся у него каждый ход —
## мир появляется только с первым боем.
var main: Node = null
var dir := ""
var turn := 0
var _last_screen := Vector2.ZERO
var _log: Array[String] = []
## Предупреждения хода (способность в откате), уходят в состояние следующего хода и стираются.
var _warns: Array[String] = []
## Сколько peek-кадров снято за текущий ход: второй не должен затирать первый.
var _peeks := 0
## Опционально для точного повтора: ход, полученный на экране загрузки, ждёт исхода
## подготовки до выбора часов меню/боя. Обычная партия по переписке не меняется.
var _wait_loading := false
var _main_has_loading_state := false
var _main_has_preparation_query := false
## Кампания (B-504): пока corr не исполняет ход боя, мир в бою стоит. Флаг держит не один объект
## мира, а каждый кадр — тот, что сейчас у главного узла: первый бой создаёт мир уже после кадра
## меню, пока агент думает, и прежний hold его не касался (бой уходил на 66 с вперёд).
var _guard := false
## Мир, которому corr последним выставил удержание: сменился объект — прежний отпустить.
var _held: LegionWorld = null
var _pressed_keys: Dictionary = {}
var _pressed_buttons: Dictionary = {}
var _cancel_aliases: Array[InputEventKey] = []
## Scene reload can detach this node while an input coroutine awaits a frame.
## Detach is terminal for this corr instance even if another scene is added.
var _cancelled := false
var _pending_waits: Array[PendingWait] = []


func setup(w: LegionWorld, out_dir: String) -> void:
	world = w
	_mark_synthetic(w)
	dir = out_dir.replace("\\", "/").trim_suffix("/")


## B-505: события corr идут устройством DEVICE — APPLICATION_FOCUS_OUT не должен отменять
## начатый синтетический штрих. Механизм проверен; причина исторического PS не установлена.
## Мир кампании появляется позже setup_main и может смениться — отмечаем каждый, кого держим.
func _mark_synthetic(w: LegionWorld) -> void:
	if w != null and not w.synthetic_input:
		w.synthetic_input = true


## Диагностика B-505: фокус окна приходит и уходит независимо от хода — пишем в журнал состояния,
## что именно было на поле в этот момент (черновик, натяжка), чтобы пропавший штрих был виден.
func _notification(what: int) -> void:
	var name := ""
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			name = "APPLICATION_FOCUS_OUT"
		NOTIFICATION_APPLICATION_FOCUS_IN:
			name = "APPLICATION_FOCUS_IN"
		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			name = "WM_WINDOW_FOCUS_OUT"
		NOTIFICATION_WM_WINDOW_FOCUS_IN:
			name = "WM_WINDOW_FOCUS_IN"
		_:
			return
	var w := _current_world()
	var field := ""
	if w != null and w.contracts != null:
		field = " черновик=%s натяжка=%s" % [w.contracts.has_draft(), w.contracts.is_slinging()]
	_note("ход %d: окно %s%s" % [turn, name, field])


## Кампания по переписке (legion_main.gd, ключ --dev corr без --map).
func setup_main(m: Node, out_dir: String) -> void:
	main = m
	dir = out_dir.replace("\\", "/").trim_suffix("/")
	var args := LegionWorld.parse_args()
	var dev: Dictionary = args.get("dev", {})
	_wait_loading = String(dev.get("corr_wait_loading", "0")) == "1"
	_main_has_preparation_query = m.has_method("battle_preparation_pending")
	_main_has_loading_state = false
	for property: Dictionary in m.get_property_list():
		if String(property.get("name", "")) == "_loading_battle":
			_main_has_loading_state = true
			break


func _ready() -> void:
	if not _active():
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_install_cancel_alias()
	# удержание (_process) ставится раньше шага мира в том же кадре, где бой начался, —
	# независимо от того, где в дереве окажется новый мир
	process_priority = -1
	DirAccess.make_dir_recursive_absolute(dir)
	if main != null:
		_run_campaign()
	else:
		_run()


## Выход верхним ключом хода: {"quit": true} — так пишут скилл и докстринг. До B-354 (30.09)
## выход искался только внутри actions, верхний ключ молча становился пустым ходом и игра висела.
## {"actions": [..., {"quit": true}]} тоже выходит — после действий, стоящих до него.
static func top_quit(move: Dictionary) -> bool:
	return bool(move.get("quit", false))


## Выход из игры (тест подменяет, чтобы не закрыть самого себя).
func _quit(code: int) -> void:
	if not _active():
		return
	_cleanup_input()
	get_tree().quit(code)


## Ход боя, если мир в бою и не на паузе; иначе — ход меню. Бой кончился — экран итога
## придёт следующим ходом меню.
func _in_battle() -> bool:
	world = main.get("world") as LegionWorld
	return world != null and world.phase == LegionWorld.Phase.BATTLE and not world.paused


func _process(_delta: float) -> void:
	if _guard:
		_set_guard(true)


## Удержание кампании (B-504). on — corr ждёт ход или исполняет ход меню / действия хода боя без
## часов: мир, который сейчас в бою и не на паузе, стоит. off — ход боя идёт (wait или часы
## corr_clock), corr ушёл или выходит. Прежний объект мира, если главный узел его сменил,
## отпускается: удержание не должно пережить свой мир.
func _set_guard(on: bool) -> void:
	_guard = on
	var w := _current_world()
	if is_instance_valid(_held) and _held != w:
		_held.hold = false
		_unmark_synthetic(_held)
	_held = w
	if w != null:
		_mark_synthetic(w)
		w.hold = on and w.phase == LegionWorld.Phase.BATTLE and not w.paused


## Мир главного узла прямо сейчас; поле world не трогает — его обновляет ход (_in_battle).
func _current_world() -> LegionWorld:
	var w: LegionWorld = world
	if is_instance_valid(main):
		w = main.get("world") as LegionWorld
	return w if is_instance_valid(w) else null


func _battle_preparation_pending() -> bool:
	if _main_has_preparation_query:
		return bool(main.call("battle_preparation_pending"))
	return _main_has_loading_state and bool(main.get("_loading_battle"))


func _exit_tree() -> void:
	_cancelled = true
	# Signal emission resumes nested awaits synchronously while this node still
	# exists. Clear before emitting because resumed continuations erase tokens.
	var pending := _pending_waits.duplicate()
	_pending_waits.clear()
	for token: PendingWait in pending:
		token.cancel()
	_cleanup_input()


func _active() -> bool:
	return not _cancelled and is_inside_tree() and not is_queued_for_deletion()


func _await_external(source: Object, signal_name: StringName) -> bool:
	if not _active() or not is_instance_valid(source):
		return false
	var token := PendingWait.new()
	_pending_waits.append(token)
	if token.listen(source, signal_name) != OK:
		_pending_waits.erase(token)
		return false
	var ok: bool = await token.resolved
	_pending_waits.erase(token)
	return ok and _active()


func _unmark_synthetic(w: LegionWorld) -> void:
	if is_instance_valid(w) and w.synthetic_input:
		w.cancel_human_gestures()
		w.synthetic_input = false


## Detach/quit must restore a live world's human focus policy. Cancel first: sending mouse-up
## before cancellation would commit a half-drawn contract. Release only this corr's own keys.
func _cleanup_input() -> void:
	_guard = false
	if is_instance_valid(_held):
		_held.hold = false
		_unmark_synthetic(_held)
	var w := _current_world()
	if w != null:
		w.hold = false
		_unmark_synthetic(w)
	_held = null
	for event: InputEvent in _pressed_keys.values() + _pressed_buttons.values():
		var release := event.duplicate() as InputEvent
		release.set("pressed", false)
		if release is InputEventMouseButton:
			(release as InputEventMouseButton).button_mask = 0
		Input.parse_input_event(release)
	_pressed_keys.clear()
	_pressed_buttons.clear()
	for alias in _cancel_aliases:
		InputMap.action_erase_event(&"ui_cancel", alias)
	_cancel_aliases.clear()


## Встроенный ui_cancel ограничен устройством клавиатуры движка (16 в 4.7.2).
## Corr сохраняет DEVICE для защиты жестов от потери фокуса; временный дубль
## привязки разрешает тот же Esc, не меняя обычную клавиатуру или настройки игрока.
func _install_cancel_alias() -> void:
	if not _cancel_aliases.is_empty():
		return
	for event in InputMap.action_get_events(&"ui_cancel"):
		if event is not InputEventKey or event.device == -1 or event.device == DEVICE:
			continue
		var alias := event.duplicate() as InputEventKey
		alias.device = DEVICE
		if not InputMap.action_has_event(&"ui_cancel", alias):
			InputMap.action_add_event(&"ui_cancel", alias)
			_cancel_aliases.append(alias)


func _send_input(event: InputEvent) -> void:
	if not _active():
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed:
			_pressed_keys[key.physical_keycode] = key
		else:
			_pressed_keys.erase(key.physical_keycode)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed:
			_pressed_buttons[button.button_index] = button
		else:
			_pressed_buttons.erase(button.button_index)
	Input.parse_input_event(event)


func _run_campaign() -> void:
	if not await _frames(30):
		return
	while _active():
		# мир в бою стоит до исполнения хода, в меню, итоге и паузе — нет (удержание прошлого боя
		# не морозит экраны); бой, начавшийся позже, удержание догонит в _process (B-504)
		_set_guard(true)
		var battle := _in_battle()
		if not battle:
			# экраны меню появляются плавно: без паузы кадр и список кнопок снимаются на
			# прозрачном экране итога (кнопок нет, сессия 180f1168)
			if not await _await_external(
					get_tree().create_timer(MENU_SETTLE, true, false, true), &"timeout"):
				return
		if not await _frames(3):
			return
		if not await _snapshot(false):
			return
		var move: Dictionary = await _wait_move()
		if not _active():
			return
		_peeks = 0
		if top_quit(move):
			_set_guard(false)
			_quit(0)
			return
		# Загрузка и начатый ею выход Прораба могут пережить menu-wait. Пока они идут,
		# guard уже держит появившийся мир, поэтому ожидание не расходует игровые тики.
		if _wait_loading:
			while _active() and is_instance_valid(main) and _battle_preparation_pending():
				if not await _frames(1):
					return
		if not _active():
			return
		# экран мог смениться, пока агент думал: кончилась загрузка боя — ход меню исполняется
		# как ход боя (мир всё это время стоял)
		battle = _in_battle()
		var clock := float(world.dev.get("corr_clock", "0")) if battle else 0.0
		var t0 := world.now if battle else 0.0
		if battle and clock > 0.0:
			_set_guard(false)
		for a in move.get("actions", []):
			if bool((a as Dictionary).get("quit", false)):
				_set_guard(false)
				_quit(0)
				return
			if not await _act(a as Dictionary):
				return
		if battle:
			var wait := clock if clock > 0.0 else float(move.get("wait", DEFAULT_WAIT))
			var t_end := (t0 if clock > 0.0 else world.now) + maxf(wait, 0.0)
			_set_guard(false)
			while _active() and _in_battle() and world.now < t_end:
				if not await _frames(1):
					return
		else:
			var w := float(move.get("wait", MENU_WAIT))
			if not await _await_external(
					get_tree().create_timer(maxf(w, 0.05), true, false, true), &"timeout"):
				return
		turn += 1


func _input(event: InputEvent) -> void:
	if _active() and (event is InputEventMouse or event is InputEventKey) and event.device != DEVICE:
		get_viewport().set_input_as_handled()


func _run() -> void:
	if not await _frames(20):
		return
	# чужой id карты (id кампании вместо имени файла): мира нет, _state() упал бы на пустом
	# wave_runner, а агент ждал бы ход 0 до таймаута — пишем причину файлом и выходим
	if world.map.is_empty() or world.wave_runner == null:
		var msg := "карта '%s' не загрузилась: --map — имя файла в assets/legion/maps" % world.map_id
		_note(msg)
		var ef := FileAccess.open(dir + "/error.txt", FileAccess.WRITE)
		ef.store_string(msg)
		ef.close()
		get_tree().quit(1)
		return
	while _active():
		world.hold = true
		if not await _frames(3):
			return
		var over := world.phase != LegionWorld.Phase.BATTLE
		if not await _snapshot(over):
			return
		if over:
			if not await _frames(2):
				return
			get_tree().quit(0)
			return
		var move: Dictionary = await _wait_move()
		if not _active():
			return
		_peeks = 0
		var clock := float(world.dev.get("corr_clock", "0"))
		var t0 := world.now
		if top_quit(move):
			_quit(0)
			return
		if clock > 0.0:
			world.hold = false   # часы: мир идёт и пока рука чертит
		for a in move.get("actions", []):
			if bool((a as Dictionary).get("quit", false)):
				_quit(0)
				return
			if not await _act(a as Dictionary):
				return
		var wait := clock if clock > 0.0 else float(move.get("wait", DEFAULT_WAIT))
		var t_end := (t0 if clock > 0.0 else world.now) + maxf(wait, 0.0)
		world.hold = false
		# пауза (ESC) останавливает часы мира — не ждать их вечно (verifier 180f1168)
		while _active() and world.now < t_end and world.phase == LegionWorld.Phase.BATTLE and not world.paused:
			if not await _frames(1):
				return
		turn += 1


# ── Файлы ───────────────────────────────────────────────────────────────────

func _path(stem: String, ext: String) -> String:
	return "%s/%s_%03d.%s" % [dir, stem, turn, ext]


func _snapshot(over: bool) -> bool:
	if not _active():
		return false
	# без окна (headless — самотест) кадра нет и frame_post_draw не приходит: только состояние
	if DisplayServer.get_name() != "headless":
		if not await _await_external(RenderingServer, &"frame_post_draw"):
			return false
		var img := get_viewport().get_texture().get_image()
		img.save_png(_path("turn", "png"))
	var st: Dictionary
	if main == null:
		st = _state(over)
	elif _in_battle():
		st = _state(false)
		st["mode"] = "battle"
		st["buttons"] = _buttons()   # плашки уроков, «Понятно» и прочее поверх боя
		st["texts"] = _texts()       # corr_turn.sh печатает только новые против прошлого хода
	else:
		st = _menu_state()
	var f := FileAccess.open(_path("turn", "json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(st, "  "))
	f.close()
	_warns.clear()
	var wf :=FileAccess.open(dir + "/waiting.txt", FileAccess.WRITE)
	wf.store_string(str(turn))
	wf.close()
	return true


func _wait_move() -> Dictionary:
	var p := _path("move", "json")
	while _active():
		if FileAccess.file_exists(p):
			if not await _frames(2):  # дать дописать файл
				return {}
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
			if parsed is Dictionary:
				return parsed as Dictionary
			_note("ход %d: не разобрал %s" % [turn, p])
			DirAccess.rename_absolute(p, p + ".bad")
		if not await _frames(6):
			return {}
	return {}


func _note(line: String) -> void:
	_log.append(line)
	print("CORR ", line)


## Способность в откате молча не сработает, а мир на время действий стоит и откат не тикает
## (P7: в «Схватке» 10+ Ку/Е пропали так, агент не видел причины) — предупреждение в состоянии
## следующего хода (`warn`, corr_turn.sh печатает WARN), до боя — только для боя.
func _warn_cooldown(k: String) -> void:
	if world == null or world.hero == null:
		return
	var left := 0.0
	if k in ["Q", "W", "E"]:
		left = world.hero.cd_left("QWE".find(k))
	elif k == "R":
		left = world.rally_left()
	if left > 0.05:
		_warns.append(("ход %d: %s в откате ещё %.1f с — не сработает "
			+ "(откат не тикает, пока идут действия хода)")
			% [turn, k, left])


## Ход меню кампании: что на экране (кнопки, надписи) и прогресс сохранения.
func _menu_state() -> Dictionary:
	var stars := {}
	for m in Campaign.maps():
		var id := String(m.get("id", ""))
		stars[id] = Campaign.stars(id) if Campaign.is_unlocked(id) else -1
	var amendments := []
	for id in Campaign.upgrades():
		amendments.append({"id": String(id),
			"title": String(AmendmentDb.card(id).get("title", id))})
	return {
		"turn": turn, "mode": "menu", "over": false,
		"screen": main.get("screen").get_class() if main.get("screen") != null else "",
		"buttons": _buttons(), "texts": _texts(),
		"camp": {"stars": stars, "bounty": Campaign.bounty(),
			"rank": Campaign.hero_level(), "xp": Campaign.hero_xp(),
			"amendments": amendments, "upgrades": Campaign.upgrades(),
			"preparations": RunProgression.preparations(),
			"pending_reward": Campaign.pending_reward()},
		"log": _log,
	}


## Видимые на экране элементы интерфейса (Control в видимых слоях, в пределах окна).
func _visible_controls() -> Array[Control]:
	var out: Array[Control] = []
	var view := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CanvasLayer and not (n as CanvasLayer).visible:
			continue
		if n is CanvasItem and not (n as CanvasItem).visible:
			continue
		if n is Control:
			var c := n as Control
			if c.get_global_rect().intersects(view) and c.modulate.a > 0.05:
				out.append(c)
		var kids := n.get_children()
		kids.reverse()   # pop_back снимает с конца — так обход идёт в порядке дерева
		for ch in kids:
			stack.append(ch)
	return out


func _buttons() -> Array:
	var out: Array = []
	for c in _visible_controls():
		if not (c is BaseButton):
			continue
		var label := ""
		if c is Button:
			label = (c as Button).text
		if label.strip_edges() == "":
			# карточка без своего текста: надписи внутри неё
			var parts: Array[String] = []
			for l in c.find_children("*", "Label", true, false):
				if (l as Label).is_visible_in_tree() and (l as Label).text.strip_edges() != "":
					parts.append((l as Label).text.strip_edges())
			label = " | ".join(parts) if not parts.is_empty() else c.tooltip_text
		if label.strip_edges() == "":
			label = "<%s>" % c.name
		var r := c.get_global_rect()
		out.append({"text": label.replace("\n", " "), "off": (c as BaseButton).disabled,
			"at": _out(r.get_center())})
	return out


func _texts() -> Array:
	var out: Array = []
	for c in _visible_controls():
		var t := ""
		if c is Label:
			t = (c as Label).text
		elif c is RichTextLabel:
			t = (c as RichTextLabel).get_parsed_text()
		t = t.strip_edges()
		if t == "":
			continue
		out.append(t.replace("\n", " / "))
		if out.size() >= MENU_TEXTS_MAX:
			break
	return out


func _state(over: bool) -> Dictionary:
	var free := 0
	var march := 0
	var posted := 0
	var charge := 0
	# свободный боец сам не ходит (unit.gd _tick_free) — без мест кучек агент не знает, из кого
	# чертить линию; сумма координат и счёт по клетке — x, y, n в Vector3
	var cells: Dictionary = {}
	var foe_cells: Dictionary = {}   # «Схватка»: армия соперника кучками
	for u in world.units:
		if not u.alive:
			continue
		if u.side != 0:
			var fk := Vector2i(floori(u.position.x / FREE_CELL), floori(u.position.y / FREE_CELL))
			foe_cells[fk] = (foe_cells.get(fk, Vector3.ZERO) as Vector3) \
				+ Vector3(u.position.x, u.position.y, 1.0)
			continue
		match u.state:
			Legionnaire.State.FREE:
				free += 1
				var key := Vector2i(floori(u.position.x / FREE_CELL), floori(u.position.y / FREE_CELL))
				var acc: Vector3 = cells.get(key, Vector3.ZERO)
				cells[key] = acc + Vector3(u.position.x, u.position.y, 1.0)
			Legionnaire.State.MARCH, Legionnaire.State.RALLY:
				march += 1      # «Сбор» (R) — тоже в пути, мест не держит
			Legionnaire.State.POSTED:
				posted += 1
			Legionnaire.State.CHARGE:
				charge += 1
	var cs: Array = []
	for c in world.contracts.contracts:
		var segs: Array = []
		for i in c.seg_count():
			if not c.seg_alive(i):
				continue
			var m := c.seg_center(i)
			# давка (v18): человек видит прогиб красной дугой вокруг кольца срока, агенту нужно
			# то же числом — bend (доля прорыва 0..1) и press (масса толпы у участка)
			var mass := c.press_mass[i] if i < c.press_mass.size() else 0.0
			var seg := {"i": i, "at": [roundi(m.x), roundi(m.y)],
				"left": snappedf(c.seg_left(i), 0.1), "men": c.seg_manned(i),
				"bend": snappedf(c.bend_frac(i), 0.01), "press": snappedf(mass, 0.1)}
			if world.pvp:
				# состав соперника у участка: {вид: сколько} его бойцов в 110 px
				var near: Dictionary = {}
				for u in world.units:
					if u.alive and u.side != 0 and u.position.distance_to(m) <= NEAR_R:
						near[String(u.kind)] = int(near.get(String(u.kind), 0)) + 1
				if not near.is_empty():
					seg["near"] = near
			segs.append(seg)
		var entry := {"id": c.id, "kind": String(c.kind), "dir": [snappedf(c.dir.x, 0.01),
			snappedf(c.dir.y, 0.01)], "segs": segs}
		if c.ring:
			# «Оцепление»: у кольца стрелка своя у участка — к центру (out — наружу), dir не читать
			entry["ring"] = {"center": [roundi(c.center.x), roundi(c.center.y)], "out": c.ring_out}
		elif c.figure != &"":
			# восьмёрка / треугольник / квадрат: сколько стоит в строю и сколько надо ради награды
			# (квадрат — need 0: награды нет)
			entry["figure"] = {"kind": String(c.figure),
				"center": [roundi(c.center.x), roundi(c.center.y)],
				"men": roundi(c.fill() * c.posts.size()), "need": ContractField.fig_need(c)}
		cs.append(entry)
	var fs: Array = []
	for fo in world.foes:
		if fo.alive:
			fs.append([fo.type_id, roundi(fo.position.x), roundi(fo.position.y)])
	var groups: Array = []
	for acc: Vector3 in cells.values():
		groups.append([roundi(acc.x / acc.z), roundi(acc.y / acc.z), int(acc.z)])
	groups.sort_custom(func(a: Array, b: Array) -> bool: return int(a[2]) > int(b[2]))
	# двери построек: бойцы рождаются стопкой ровно у двери — туда и чертить «магазин» рогатки
	var bs: Array = []
	for b: LegionBuilding in world.buildings:
		if not is_instance_valid(b):
			continue
		bs.append({"kind": String(b.kind), "src": String(b.source), "side": b.side, "lvl": b.level,
			"alive": b.alive_count(), "cap": b.cap,
			"at": [roundi(b.position.x), roundi(b.position.y)],
			"door": [roundi(b.entry.x), roundi(b.entry.y)]})
	# пункты меню площадки: высота карточки зависит от пояснений и прижатия к краю, офсеты врут
	var menu: Array = []
	if world.plot_menu != null and world.plot_menu.is_open():
		for btn in world.plot_menu.buttons():
			var r := btn.get_global_rect()
			menu.append({"text": btn.text, "off": btn.disabled, "at": _out(r.get_center())})
	var cd: Dictionary = {}
	if world.hero != null:
		for i in 3:
			cd["QWE"[i]] = snappedf(world.hero.cd_left(i), 0.1)
	cd["R"] = snappedf(world.rally_left(), 0.1)
	var st := {
		"turn": turn, "over": over, "t": snappedf(world.now, 0.1),
		"wave": world.wave_runner.wave_no(), "hp": snappedf(world.cauldron_hp, 0.1),
		"cauldron": [roundi(world.cauldron_pos.x), roundi(world.cauldron_pos.y)],
		"mana": snappedf(world.contracts.mana, 1.0), "souls": world.souls,
		"army": {"total": world.army_alive(), "free": free, "march": march, "posted": posted,
			"charge": charge},
		"contracts": cs, "foes": fs, "free_at": groups, "buildings": bs, "menu": menu, "cd": cd,
		"combo": [world.combo, snappedf(world.combo_mult(), 0.01)], "log": _log,
		"warn": _warns.duplicate(),
	}
	if world.pvp:
		var foe_groups: Array = []
		for acc: Vector3 in foe_cells.values():
			foe_groups.append([roundi(acc.x / acc.z), roundi(acc.y / acc.z), int(acc.z)])
		foe_groups.sort_custom(func(a: Array, b: Array) -> bool: return int(a[2]) > int(b[2]))
		var other: PvpSide = world.sides[1]
		var res: Dictionary = world.pvp_match.result if world.pvp_match != null else {}
		st["foe_army"] = foe_groups
		st["pvp"] = {"clock": snappedf(world.now, 0.1), "limit": world.pvp_match.limit,
			"left": snappedf(world.pvp_match.limit - world.now, 0.1), "wave": st["wave"],
			"me": {"hp": snappedf(world.cauldron_hp, 0.1), "max": snappedf(world.cauldron_max, 0.1),
				"army": world.army_alive(0), "souls": world.souls, "mana": st["mana"],
				"at": st["cauldron"]},
			"foe": {"hp": snappedf(other.cauldron_hp, 0.1), "max": snappedf(other.cauldron_max, 0.1),
				"army": world.army_alive(1), "souls": other.souls,
				"mana": snappedf(other.contracts.mana, 1.0),
				"at": [roundi(other.cauldron_pos.x), roundi(other.cauldron_pos.y)]},
			"result": res}
	return st


# ── Действия ────────────────────────────────────────────────────────────────

func _act(a: Dictionary) -> bool:
	if not _active():
		return false
	if a.has("kind"):
		return await _key(KEYS[str(int(a["kind"]))])
	elif a.has("draw"):
		var toward: Variant = _pt(a["toward"]) if a.has("toward") else null
		return await _draw(_pts(a["draw"]), toward, bool(a.get("peek", false)))
	elif a.has("aim"):
		var ap := _pts(a["aim"])
		if not await _move(ap[0]):
			return false
		if not await _key_state(KEY_SPACE, true):
			return false
		if not await _move(ap[1]):
			return false
		return await _key_state(KEY_SPACE, false)
	elif a.has("sling"):
		var pts := _pts(a["sling"])
		return await _drag(pts[0], pts[1], MOUSE_BUTTON_RIGHT, false)
	elif a.has("tap"):
		return await _click(_pt(a["tap"]), MOUSE_BUTTON_LEFT)
	elif a.has("move"):
		return await _move(_pt(a["move"]))   # навести указатель: подсказки меню, дерево героя
	elif a.has("rtap"):
		return await _click(_pt(a["rtap"]), MOUSE_BUTTON_RIGHT)
	elif a.has("wheel"):
		var btn := MOUSE_BUTTON_WHEEL_DOWN if int(a["wheel"]) > 0 else MOUSE_BUTTON_WHEEL_UP
		var at := get_viewport().get_final_transform().affine_inverse() * _last_screen
		if _world_mode():
			at = world.screen_to_world(at)   # _button переводит мир → экран
		if not await _button(at, btn, true):
			return false
		return await _button(at, btn, false)
	elif a.has("key"):
		if a.has("at"):
			if not await _move(_pt(a["at"])):
				return false
		_warn_cooldown(String(a["key"]).to_upper())
		return await _key(KEYS[String(a["key"]).to_upper()])
	else:
		_note("ход %d: неизвестное действие %s" % [turn, JSON.stringify(a)])
	return _active()


func _pt(v: Variant) -> Vector2:
	var arr := v as Array
	return Vector2(float(arr[0]), float(arr[1]))


func _pts(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in (v as Array):
		out.append(_pt(p))
	return out


func _draw(pts: PackedVector2Array, toward: Variant, peek: bool) -> bool:
	if not _active():
		return false
	if pts.size() < 2:
		return true
	if not await _move(pts[0]):
		return false
	if not await _button(pts[0], MOUSE_BUTTON_LEFT, true):
		return false
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, ceili(a.distance_to(b) / STEP_PX))
		for k in range(1, n + 1):
			if not await _move(a.lerp(b, float(k) / n), MOUSE_BUTTON_MASK_LEFT):
				return false
	var end := pts[pts.size() - 1]
	if toward != null:
		# стрелка черновика: Пробел держим, указатель к цели (contract_field.aim_at), Пробел отпускаем
		if not await _key_state(KEY_SPACE, true):
			return false
		if not await _move(toward as Vector2, MOUSE_BUTTON_MASK_LEFT):
			return false
		if not await _key_state(KEY_SPACE, false):
			return false
		end = toward as Vector2
	if peek:
		# мир на удержании не тикает поле договоров — превью захвата и черновик обновляем сами
		var cf := world.contracts
		cf.update_preview()
		cf.queue_redraw()
		if cf.overlay != null:
			cf.overlay.queue_redraw()
		for u in world.units:
			u.queue_redraw()
			if u.view != null:
				u.view.queue_redraw()
		if not await _frames(2):
			return false
		if not await _await_external(RenderingServer, &"frame_post_draw"):
			return false
		_peeks += 1
		var suffix := "_peek.png" if _peeks == 1 else "_peek%d.png" % _peeks
		get_viewport().get_texture().get_image().save_png(_path("turn", "png").replace(".png", suffix))
	# B-505: штрих, у которого перед отпусканием нет черновика, молча не даст договора — пишем в
	# журнал (log состояния), что именно случилось, вместо «договор просто не появился»
	var before := world.contracts.contracts.size() if _world_mode() else -1
	var had_draft := world.contracts.has_draft() if _world_mode() else false
	if not await _button(end, MOUSE_BUTTON_LEFT, false):
		return false
	if before >= 0 and not had_draft:
		_note("ход %d: штрих из %d точек (вид %s) отпущен без черновика: договоров %d → %d"
			% [turn, pts.size(), world.contracts.current_kind,
				before, world.contracts.contracts.size()])
	return true


func _drag(a: Vector2, b: Vector2, button: MouseButton, _unused: bool) -> bool:
	if not _active():
		return false
	var mask := MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT
	if not await _move(a):
		return false
	if not await _button(a, button, true):
		return false
	var n := maxi(2, ceili(a.distance_to(b) / STEP_PX))
	for k in range(1, n + 1):
		if not await _move(a.lerp(b, float(k) / n), mask):
			return false
	return await _button(b, button, false)


# ── Ввод (как в legion_tutorial_driver.gd) ──────────────────────────────────

## Координаты действий боя — мировые (в одиночке вид тождествен экрану); вне боя (меню кампании,
## пауза) — экранные, как раньше. «Схватка»: мир 1600×900 на экране 1280×720 (view_xf, камера ×0,8).
func _world_mode() -> bool:
	if world == null:
		return false
	if main == null:
		return true
	return world.phase == LegionWorld.Phase.BATTLE and not world.paused


func _screen(p: Vector2) -> Vector2:
	var vp := world.world_to_screen(p) if _world_mode() else p
	return get_viewport().get_final_transform() * vp


## Экранная точка интерфейса (кнопка, пункт меню) → координата хода: в бою мировая.
func _out(sp: Vector2) -> Array:
	var p := world.screen_to_world(sp) if _world_mode() else sp
	return [roundi(p.x), roundi(p.y)]


func _move(p: Vector2, mask: int = 0) -> bool:
	if not _active():
		return false
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.relative = sp - _last_screen
	ev.button_mask = mask
	_last_screen = sp
	_send_input(ev)
	return await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> bool:
	if not _active():
		return false
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	_send_input(ev)
	return await _frames(1)


func _click(p: Vector2, button: MouseButton) -> bool:
	if not await _move(p):
		return false
	if not await _button(p, button, true):
		return false
	if not await _frames(2):
		return false
	return await _button(p, button, false)


func _key_state(code: Key, pressed: bool) -> bool:
	if not _active():
		return false
	var ev := InputEventKey.new()
	ev.device = DEVICE
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	_send_input(ev)
	return await _frames(2)


func _key(code: Key) -> bool:
	if not _active():
		return false
	var ev := InputEventKey.new()
	ev.device = DEVICE
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	_send_input(ev)
	if not await _frames(2):
		return false
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	_send_input(up)
	return await _frames(1)


func _frames(n: int) -> bool:
	for i in n:
		if not _active():
			return false
		if not await _await_external(get_tree(), &"process_frame"):
			return false
	return true
