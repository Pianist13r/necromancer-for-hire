extends SceneTree
##
## Регресс B-370 и B-371 (ветка slow/pvp-menu-input): открытие меню Esc «Схватки» отменяет всё
## начатое боевое действие человека, как пауза в одиночке, — отпускание под меню (и после его
## закрытия) ничего не делает.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_menu_input_test.gd -- --mute
##
## 1) B-370: ЛКМ зажата на участке до Esc, отпущена под меню — tap не срабатывает, меню площадки
##    не открывается; после закрытия меню новый тап по участку открывает его как обычно;
## 2) B-371: Эр зажата до Esc, отпущена под меню — «Сбора» нет; после закрытия — Эр работает;
##    прицел Ку тоже снят открытием меню (отпускание Ку под меню не кастует);
## 3) штрих рисования и натяжка рогатки, начатые до меню, сняты; движение мыши под меню не ломает.
## 4) сеть (start_net_match), человек за любую сторону: нажатие на участке и штрих до меню,
##    отпускание под меню — меню площадки не открывается, команда STROKE в сеть не уходит
##    (за правую сторону поле человека — не w.contracts, B-370, находка verifier);
## Итог «LEGION PVP MENU INPUT: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pvp_menu_input_test.cfg"

var w: LegionWorld
var _fails := 0
var _checks := 0


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
	await process_frame
	w.set_process(false)
	_start("pvp:duel")
	_test_tap_under_menu()
	_test_rally_under_menu()
	_test_cast_under_menu()
	_test_stroke_and_motion()
	for side in [1, 0]:
		await _test_net_side(side)
	Campaign.reset()
	print("LEGION PVP MENU INPUT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _start(id: String) -> void:
	w.dev = {"spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 3
	w.start_map(id)


func _key(code: Key, pressed := true) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	return ev


func _mouse(at_world: Vector2, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = w.world_to_screen(at_world)
	ev.global_position = ev.position
	return ev


func _motion(at_world: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = w.world_to_screen(at_world)
	ev.global_position = ev.position
	return ev


## Первая площадка своей стороны — её центр для тапа.
func _plot_pos() -> Vector2:
	var plots: Array = w.my_side().staff.plots
	return plots[0]["pos"] if not plots.is_empty() else Vector2.INF


func _test_tap_under_menu() -> void:
	print("— B-370: отпускание ЛКМ под меню")
	var cf := w.contracts
	var at := _plot_pos()
	_check(at != Vector2.INF, "у своей стороны есть участок (%s)" % at)
	if at == Vector2.INF:
		return
	w.plot_menu.close()
	cf._unhandled_input(_mouse(at, true))
	_check(cf._pressing, "ЛКМ на участке — нажатие начато")
	w.pvp_menu.toggle()
	_check(w.pvp_menu_open(), "меню «Схватки» открыто")
	cf._unhandled_input(_mouse(at, false))
	_check(not w.plot_menu.is_open(), "отпускание под меню — меню площадки не открылось")
	w.pvp_menu.close()
	cf._unhandled_input(_mouse(at, false))
	_check(not w.plot_menu.is_open(), "и после закрытия меню лишнее отпускание ничего не открывает")
	# контроль: новый тап после закрытия работает
	cf._unhandled_input(_mouse(at, true))
	cf._unhandled_input(_mouse(at, false))
	_check(w.plot_menu.is_open(), "меню закрыто — новый тап по участку открывает меню площадки")
	w.plot_menu.close()


func _test_rally_under_menu() -> void:
	print("— B-371: отпускание Эр под меню")
	if not w.rally_unlocked():
		w.dev["rally"] = "1"
	_check(w.rally_unlocked(), "«Сбор» открыт на карте проверки")
	var n0 := w._rallies.size()
	w._unhandled_input(_key(KEY_R))
	_check(w.rally_aiming, "Эр зажата — прицел «Сбора»")
	w.pvp_menu.toggle()
	_check(not w.rally_aiming, "открытие меню снимает прицел «Сбора»")
	w._unhandled_input(_key(KEY_R, false))
	_check(w._rallies.size() == n0, "отпускание Эр под меню — «Сбора» нет")
	w.pvp_menu.close()
	w._unhandled_input(_key(KEY_R, false))
	_check(w._rallies.size() == n0, "и после закрытия меню отпускание Эр ничего не вызывает")
	# контроль: обычная Эр работает
	w._unhandled_input(_key(KEY_R))
	w._unhandled_input(_key(KEY_R, false))
	_check(w._rallies.size() == n0 + 1, "меню закрыто — Эр (нажал-отпустил) звонит «Сбор»")


func _test_cast_under_menu() -> void:
	print("— прицел Ку под меню")
	w._unhandled_input(_key(KEY_Q))
	_check(w.ability_aim.is_aiming(), "Ку зажата — прицел")
	w.pvp_menu.toggle()
	_check(not w.ability_aim.is_aiming(), "открытие меню снимает прицел Ку")
	w.pvp_menu.close()
	w._unhandled_input(_key(KEY_Q, false))
	_check(not w.ability_aim.is_aiming(), "отпускание Ку после меню — прицела нет")


func _test_stroke_and_motion() -> void:
	print("— штрих и рогатка при открытии меню")
	var cf := w.contracts
	var home := w.cauldron_of(0)
	var a := home + Vector2(150, 0)
	cf._unhandled_input(_mouse(a, true))
	for i in 6:
		cf._unhandled_input(_motion(a + Vector2(40 * (i + 1), 0)))
	_check(cf._drawing, "штрих начат (протяжка за порог)")
	w.pvp_menu.toggle()
	_check(not cf._drawing and not cf._pressing, "открытие меню снимает штрих")
	cf._unhandled_input(_motion(a + Vector2(10, 90)))
	cf._unhandled_input(_mouse(a + Vector2(10, 90), false))
	_check(not cf._drawing and cf.contracts.is_empty(), "движение и отпускание под меню — договора нет")
	w.pvp_menu.close()
	cf._grab = {"stub": true}
	cf._slinging = true
	w.pvp_menu.toggle()
	_check(cf._grab.is_empty() and not cf._slinging, "открытие меню снимает рогатку")
	w.pvp_menu.close()


func _net_world(side: int, sent: Array[Dictionary]) -> LegionWorld:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var nw := scene.instantiate() as LegionWorld
	root.add_child(nw)
	await process_frame
	nw.net_out = func(cmd: Dictionary) -> void: sent.append(cmd)
	nw.start_net_match(PvpMaps.DUEL, 4242, side)
	var n := 0
	while not nw.net_can_step() and n < 3000:
		await process_frame
		n += 1
	nw.set_process(false)
	return nw


func _test_net_side(side: int) -> void:
	print("— сеть, человек за сторону %d" % side)
	var old := w
	var sent: Array[Dictionary] = []
	w = await _net_world(side, sent)
	for i in 600:
		w.net_step()
	var f := w.my_field()
	var plot: Dictionary = w.sides[side].staff.plots[0]
	w.plot_menu.close()
	f._unhandled_input(_mouse(plot["pos"], true))
	_check(f._pressing, "нажатие на своём участке начато")
	w.pvp_menu.toggle()
	_check(not f._pressing, "открытие меню снимает нажатие на поле человека")
	f._unhandled_input(_mouse(plot["pos"], false))
	_check(not w.plot_menu.is_open(), "отпускание под меню — меню площадки не открылось")
	w.pvp_menu.close()
	var c := w.cauldron_of(side)
	var d := -1.0 if side == 1 else 1.0
	var p0 := Vector2(c.x + d * 260.0, c.y - 80.0)
	sent.clear()
	f._unhandled_input(_mouse(p0, true))
	for k in range(1, 15):
		f._unhandled_input(_motion(p0 + Vector2(0.0, k * 11.0)))
	_check(f.has_draft(), "штрих начат")
	w.pvp_menu.toggle()
	_check(not f.has_draft(), "открытие меню снимает штрих")
	f._unhandled_input(_mouse(p0 + Vector2(0.0, 154.0), false))
	var types: Array[String] = []
	for cmd in sent:
		types.append(String(cmd["type"]))
	_check(not types.has("stroke"), "отпускание под меню — STROKE в сеть не ушёл (%s)" % [types])
	w.pvp_menu.close()
	w.queue_free()
	await process_frame
	await process_frame
	w = old
