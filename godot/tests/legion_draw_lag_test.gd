extends SceneTree
##
## Регресс отклика штриха (slow/draw-lag, 29.09.2026; Игорь: «не очень удобно рисовать. Иногда
## почему-то рисуется линия с задержкой, это сильно мешает»).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_draw_lag_test.gd -- --mute
##
## 1) точка штриха, принятая полем, нарисована в ТОМ ЖЕ кадре (и слой черновика поверх бойцов,
##    и полоса набора под ними) — в обычном кадре и во время стоп-кадра мира. Раньше поле
##    перерисовывалось только из шага мира (contracts.tick), а стоп-кадр натиска, Ку, ритуала
##    фигуры и находки (world.impact_stop, 45–160 мс) шаг пропускает: линия стояла, курсор уходил;
## 2) стоп-кадр по-прежнему стоит только для мира: время боя не идёт (геймплей тот же);
## 3) B-056: окно потеряло фокус посреди штриха (Alt+Tab) — отпускание ЛКМ сюда уже не придёт:
##    штрих снимается с возвратом маны, а не тянется дальше за курсором без кнопки.
## Итог «LEGION DRAW LAG: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_draw_lag_test.cfg"
const DEVICE := 0

var w: LegionWorld
var f: ContractField
var _fails := 0
var _checks := 0
## кадр (Engine.get_process_frames) -> наибольший размер черновика, нарисованный в нём
var _overlay_drawn: Dictionary = {}
var _field_drawn: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.dev["spawn_foes"] = "0"
	w.start_map("fork")
	f = w.contracts
	f.overlay.draw.connect(func() -> void: _mark(_overlay_drawn))
	f.draw.connect(func() -> void: _mark(_field_drawn))
	var guard := 0
	while (w.is_ground_loading() or w.phase != LegionWorld.Phase.BATTLE) and guard < 600:
		await process_frame
		guard += 1
	await _test_same_frame()
	await _test_same_frame_in_stop()
	await _test_focus_out()
	Campaign.reset()
	print("LEGION DRAW LAG: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _mark(into: Dictionary) -> void:
	if f._drawing:
		var fr := Engine.get_process_frames()
		into[fr] = maxi(int(into.get(fr, 0)), f._draft.size())


func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _motion(p: Vector2, mask: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)


func _button(p: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(ev)


## Начало полосы без скалы (±16 px, 260 px вправо: штрих не обрезается о камень) — ближе к y.
func _open_start(y: float) -> Vector2:
	for dy in range(0, 300, 10):
		for yy: float in [y + dy, y - dy]:
			if yy < 60.0 or yy > 640.0:
				continue
			for x0 in range(80, 940, 20):
				if _band_clear(float(x0), yy):
					return Vector2(x0 + 10.0, yy)
	return Vector2(430.0, y)


func _band_clear(x0: float, y: float) -> bool:
	for band: float in [-16.0, 0.0, 16.0]:
		for x in range(int(x0), int(x0) + 260, 4):
			var p := Vector2(x, y + band)
			if w.terrain.is_rock(p) or not w.terrain.walkable(p):
				return false
	return true


## Штрих начат: нажатие и первые шаги за порог щелчка (TAP_SLOP). Возвращает конец.
func _start_stroke(y: float) -> Vector2:
	var at := _open_start(y)
	_motion(at, 0)
	await process_frame
	_button(at, true)
	await process_frame
	for i in 3:
		at += Vector2(14.0, 0.0)
		_motion(at, MOUSE_BUTTON_MASK_LEFT)
		await process_frame
	return at


## Шаг курсора: кадр, в котором поле приняло точку, и кадр, в котором она нарисована.
## Событие разбирается в начале следующего кадра (до process_frame), рисуется — в его конце.
func _step_and_frames(at: Vector2) -> Array[int]:
	var before := f._draft.size()
	_motion(at, MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	var accepted := Engine.get_process_frames()
	var got := f._draft.size()
	await process_frame   # отрисовка кадра accepted уже прошла
	await process_frame
	if got == before:
		print("    DEBUG at=", at, " draft=", f._draft, " mana=", f.mana, " len=", f._draft_len,
			" clear=", w.terrain.segment_clear(f._draft[f._draft.size() - 1], at), " fig=", f._draft_fig)
	var drawn_over := -1
	var drawn_field := -1
	for fr: int in range(accepted, accepted + 3):
		if drawn_over < 0 and int(_overlay_drawn.get(fr, 0)) >= got:
			drawn_over = fr
		if drawn_field < 0 and int(_field_drawn.get(fr, 0)) >= got:
			drawn_field = fr
	return [before, got, accepted, drawn_over, drawn_field]


func _test_same_frame() -> void:
	print("— штрих: точка нарисована в кадре, в котором принята")
	var at := await _start_stroke(330.0)
	_check(f.has_draft(), "штрих начат настоящими событиями мыши")
	for i in 3:
		at += Vector2(20.0, 0.0)
		var r := await _step_and_frames(at)
		_check(r[1] > r[0], "шаг %d: поле приняло точку (%d → %d)" % [i + 1, r[0], r[1]])
		_check(r[3] == r[2], "шаг %d: слой черновика нарисован в том же кадре (%d, нарисован %d)"
			% [i + 1, r[2], r[3]])
	_button(at, false)
	await process_frame
	await process_frame


func _test_same_frame_in_stop() -> void:
	print("— стоп-кадр мира (натиск, Ку, ритуал): линия всё равно идёт за курсором")
	var at := await _start_stroke(430.0)
	w.impact_stop(1.0)   # дольше любого настоящего (ритуал — 0.16 с): весь замер внутри
	await process_frame
	var t0 := w.now
	for i in 3:
		at += Vector2(20.0, 0.0)
		var r := await _step_and_frames(at)
		_check(r[1] > r[0], "в стопе, шаг %d: поле приняло точку (%d → %d)" % [i + 1, r[0], r[1]])
		_check(r[3] == r[2], "в стопе, шаг %d: слой черновика в том же кадре (%d, нарисован %d)"
			% [i + 1, r[2], r[3]])
		_check(r[4] == r[2], "в стопе, шаг %d: полоса набора в том же кадре (%d, нарисована %d)"
			% [i + 1, r[2], r[4]])
	_check(is_equal_approx(w.now, t0), "стоп-кадр держит мир: время боя стоит (%.3f → %.3f)"
		% [t0, w.now])
	w.impact_stop(0.0)
	w._hitstop_left = 0.0
	_button(at, false)
	await process_frame
	await process_frame


func _test_focus_out() -> void:
	print("— B-056: Alt+Tab посреди штриха — штрих снят, мана вернулась")
	var n0 := f.contracts.size()
	f.mana = f.mana_max
	await process_frame
	var mana0 := f.mana
	var at := await _start_stroke(530.0)
	for i in 3:
		at += Vector2(20.0, 0.0)
		_motion(at, MOUSE_BUTTON_MASK_LEFT)
		await process_frame
	_check(f.has_draft() and f.mana < mana0, "штрих идёт и тратит ману")
	f.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not f.has_draft(), "фокус ушёл — штрих снят")
	_check(f.mana >= mana0 - 0.01, "мана штриха вернулась (%.2f из %.2f)" % [f.mana, mana0])
	# вернулся в окно: курсор ходит без кнопки (отпускание ушло в другое окно)
	for i in 4:
		at += Vector2(20.0, 0.0)
		_motion(at, 0)
		await process_frame
	_check(not f.has_draft(), "курсор без кнопки после возврата — штрих не тянется")
	_check(f.contracts.size() == n0, "договор из брошенного штриха не заключён")
	print("— B-056: Alt+Tab между нажатием и порогом щелчка — штрих не начнётся")
	at = _open_start(620.0)
	_motion(at, 0)
	await process_frame
	_button(at, true)
	await process_frame
	f.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	for i in 4:
		at += Vector2(20.0, 0.0)
		_motion(at, 0)
		await process_frame
	_check(not f.has_draft(), "после потери фокуса движение без кнопки не начинает штрих")
