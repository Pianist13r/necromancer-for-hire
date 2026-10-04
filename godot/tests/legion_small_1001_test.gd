extends SceneTree
##
## Регресс мелких находок 01.10.2026 (ветка slow/small-1001; B-361, B-363; B-366 — в
## legion_gate_jam_test). Проверки B-360 и B-362 были про «Донос» — он убран (D-1002-09), их
## заменяет legion_no_donos_test:
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_small_1001_test.gd -- --mute
##
## 1) B-361: под открытым меню Esc «Схватки» не срабатывают Ку и нажатия поля договоров
##    (1/2/3, Пробел, колесо, Таб, ЛКМ); меню закрыто — срабатывают;
## 2) B-363: номера договоров с 1 на каждой карте (ContractField._next_id сбрасывается в
##    start_map), у всех сторон «Схватки».
## Итог «LEGION SMALL 1001: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_small_1001_test.cfg"

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
	await _test_key_under_menu()
	_test_contract_ids()
	Campaign.reset()
	print("LEGION SMALL 1001: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _start(id: String) -> void:
	w.dev = {"spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 3
	w.start_map(id)


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	return ev


func _test_key_under_menu() -> void:
	print("— B-361: Ку под меню Esc")
	_start("pvp:duel")
	w.now = 60.0
	w.pvp_menu.toggle()
	_check(w.pvp_menu.visible, "меню «Схватки» открыто")
	# Ку под меню прицел не начинает (паузы нет — смотрим меню)
	w._unhandled_input(_key(KEY_Q))
	_check(not w.ability_aim.is_aiming(), "Ку под меню — прицела нет")
	w.pvp_menu.close()
	w._unhandled_input(_key(KEY_Q))
	_check(w.ability_aim.is_aiming(), "меню закрыто — Ку начинает прицел")
	w.ability_aim.cancel()
	await _test_field_under_menu()


func _release_of(ev: InputEvent) -> InputEvent:
	var up := ev.duplicate() as InputEvent
	if up is InputEventKey:
		(up as InputEventKey).pressed = false
	elif up is InputEventMouseButton:
		(up as InputEventMouseButton).pressed = false
	return up


func _mouse(at_world: Vector2, button: MouseButton) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	ev.position = w.world_to_screen(at_world)
	ev.global_position = ev.position
	return ev


## Поле договоров (ContractField: свой _input/_unhandled_input) под меню «Схватки» нажатий не
## берёт: вид 1/2/3, Пробел, колесо, Таб (стирание), кнопки мыши; меню закрыто — берёт.
func _test_field_under_menu() -> void:
	print("— B-361: поле договоров под меню Esc")
	var cf := w.contracts
	var kind0 := cf.current_kind
	w.pvp_menu.toggle()
	for code: Key in [KEY_1, KEY_2, KEY_3]:
		cf._unhandled_input(_key(code))
	_check(cf.current_kind == kind0, "1/2/3 под меню — вид прежний (%s)" % cf.current_kind)
	cf._unhandled_input(_key(KEY_SPACE))
	_check(not cf._space, "Пробел под меню — прицела нет")
	cf._unhandled_input(_release_of(_key(KEY_SPACE)))
	var home := w.cauldron_of(0)
	var wheel := _mouse(home + Vector2(150, 0), MOUSE_BUTTON_WHEEL_DOWN)
	var kind1 := cf.current_kind
	cf._wheel_quiet_ms = 0
	cf._unhandled_input(wheel)
	_check(cf.current_kind == kind1, "колесо под меню — вид прежний (%s)" % cf.current_kind)
	var lmb := _mouse(home + Vector2(150, 0), MOUSE_BUTTON_LEFT)
	cf._unhandled_input(lmb)
	_check(not cf._pressing, "ЛКМ по полю под меню (мимо интерфейса) — штрих не начат")
	cf._unhandled_input(_release_of(lmb))
	# Таб — стирание участка под курсором: договор, курсор над его серединой
	var pts := PackedVector2Array()
	for i in 7:
		pts.append(home + Vector2(150, -150 + 50 * i))
	w.pvp_menu.close()
	var res := cf.stroke(pts, LegionCfg.KIND_LABORER)
	var c: Contract = res.get("contract")
	_check(c != null, "договор для проверки Таба начерчен (%s)" % [res.get("reason", "")])
	if c == null:
		return
	cf._pointer = home + Vector2(150, 0)
	var live := ContractErase.live_count(c)
	w.pvp_menu.toggle()
	cf._input(_key(KEY_TAB))
	_check(ContractErase.live_count(c) == live, "Таб под меню — участок цел (%d → %d)"
		% [live, ContractErase.live_count(c)])
	w.pvp_menu.close()
	# контроль: меню закрыто — те же нажатия работают
	cf._input(_key(KEY_TAB))
	_check(ContractErase.live_count(c) < live, "меню закрыто — Таб стирает (%d → %d)"
		% [live, ContractErase.live_count(c)])
	cf._unhandled_input(_key(KEY_2))
	_check(cf.current_kind == LegionCfg.KIND_ORDER[1], "меню закрыто — 2 переключает вид (%s)"
		% cf.current_kind)
	cf._unhandled_input(_key(KEY_SPACE))
	_check(cf._space, "меню закрыто — Пробел включает прицел")
	cf._unhandled_input(_release_of(_key(KEY_SPACE)))
	cf._unhandled_input(lmb)
	_check(cf._pressing or cf._press_eaten, "меню закрыто — ЛКМ по полю начинает нажатие")
	cf._unhandled_input(_release_of(lmb))
	await process_frame


func _test_contract_ids() -> void:
	print("— B-363: номера договоров с 1 на каждой карте")
	_start("pvp:duel")
	for s in w.sides:
		s.contracts._next_id = 17
	_start("pvp:duel")
	var ok := true
	for s in w.sides:
		ok = ok and s.contracts._next_id == 1
	_check(ok, "«Схватка» заново: у всех сторон счёт договоров с 1")
	w.contracts._next_id = 9
	_start("wasteland")
	_check(w.contracts._next_id == 1, "одиночная карта после другой: счёт с 1 (%d)"
		% w.contracts._next_id)
