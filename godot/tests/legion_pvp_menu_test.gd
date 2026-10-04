extends SceneTree
##
## P6: вход в «Схватку» из главного меню (D-0927-199, D-0930-30…). Ведёт LegionMain настоящими
## нажатиями кнопок (сигнал pressed), без окна:
##   меню → «Схватка» → выбор поля → матч → Esc → «Сдаться» → итог «сдача» → «Ещё раз» → «В меню»
##   → случайное поле → «Назад» → кампания (камера ×1, одиночный HUD, сохранение цело).
## Только старые API и поиск узлов по имени: на коммите без P6 тест падает проверкой, а не разбором.
##
##   "$GODOT" --headless --path godot --fixed-fps 60 --script res://tests/legion_pvp_menu_test.gd
##       -- --mute
##

const TEST_PATH := "user://legion_pvp_menu_test_run.cfg"

var main: LegionMain
var _snap := ""
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _finish() -> void:
	print("LEGION PVP MENU: %d/%d OK" % [_checks - _fails, _checks])
	quit(0 if _fails == 0 else 1)


func _press(where: Node, btn_name: String) -> bool:
	var b := where.find_child(btn_name, true, false) as Button if where != null else null
	if b == null:
		return false
	b.pressed.emit()
	return true


func _press_text(where: Node, text: String) -> bool:
	if where == null:
		return false
	for b in where.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			(b as Button).pressed.emit()
			return true
	return false


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	var items: Array[StringName] = [&"clip_of_fate"]
	Campaign.set_run_items(items)
	_snap = _campaign_snapshot()
	main = (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await _frames(3)
	_check(main.screen is LegionMenu, "старт: главное меню")
	var btn := main.screen.find_child("PvpAction", true, false) as Button
	_check(btn != null and btn.text == "Схватка" and not btn.disabled,
		"в меню есть кнопка «Схватка», доступна сразу (кампания не пройдена)")
	_check(btn != null and not btn.pressed.get_connections().is_empty(), "кнопка подключена")
	if btn == null:
		_finish()
		return
	_check(_has_text(main.screen, "Против бота или по сети · разрушьте Котёл соперника"),
		"под кнопкой подпись про оба режима и Котёл")
	# кнопка открывает выбор поля
	btn.pressed.emit()
	await _frames(2)
	var select := main.screen
	_check(select != null and select.find_child("PvpFieldDuel", true, false) != null
		and select.find_child("PvpFieldRandom", true, false) != null
		and _has_button(select, "Назад"), "«Схватка» → выбор поля: Дуэль, Случайное поле, Назад")
	# Esc из выбора — в меню
	_key_escape()
	await _frames(2)
	_check(main.screen is LegionMenu, "Esc в выборе поля возвращает в меню")
	_press(main.screen, "PvpAction")
	await _frames(2)
	_check(_press_text(main.screen, "Назад") and await _frame_is_menu(), "«Назад» — в меню")

	await _duel_and_surrender()
	await _random_field()
	await _back_to_campaign()
	_finish()


## Всё, что бой кампании мог бы записать: звёзды, премия, опыт героя, награда, артефакты забега.
func _campaign_snapshot() -> String:
	var stars: Array = []
	for m in Campaign.maps():
		stars.append(Campaign.stars(String(m.get("id", ""))))
	return JSON.stringify([stars, Campaign.bounty(), Campaign.hero_xp(),
		Campaign.pending_reward(), Array(Campaign.run_items()).map(func(i: StringName) -> String:
			return String(i))])


func _has_text(where: Node, text: String) -> bool:
	for l in where.find_children("*", "Label", true, false):
		if (l as Label).text == text:
			return true
	return false


func _has_button(where: Node, text: String) -> bool:
	for b in where.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			return true
	return false


func _frame_is_menu() -> bool:
	await _frames(2)
	return main.screen is LegionMenu


func _key_escape() -> void:
	# pause включает P и Esc, а выход из меню — только ui_cancel (Esc).
	# Проверяем настоящую клавишу, не подменяем её общей командой паузы.
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)
	var release := ev.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)


func _duel_and_surrender() -> void:
	_press(main.screen, "PvpAction")
	await _frames(2)
	_press(main.screen, "PvpFieldDuel")
	await _frames(4)
	var w := main.world
	_check(w != null and w.pvp and w.map_id == "pvp:duel" and w.phase == LegionWorld.Phase.BATTLE,
		"«Дуэль» стартует матч pvp:duel в мире кампании")
	_check(main.screen == null, "экран выбора убран")
	_check(is_equal_approx(w.view_scale(), 0.8), "камера матча ×0,8")
	var cam := w.get_viewport().get_camera_2d()
	_check(cam != null and is_equal_approx(cam.zoom.x, 0.8), "Camera2D ×0,8")
	_check(w.sides.size() == 2 and w.sides[1].bot != null and w.sides[0].bot == null,
		"сторона 0 — человек, сторона 1 — бот")
	_check(w.hud.pvp_plate != null and w.hud.pvp_plate.visible, "HUD «Схватки» на месте")
	_check(not w.in_campaign and w.mods.is_empty() and not w.carry_items,
		"матч не читает поправки и артефакты кампании")
	await _frames(30)
	# Esc — меню боя с «Сдаться»
	_key_escape()
	await _frames(2)
	_check(w.pvp_menu != null and w.pvp_menu.visible, "Esc открывает меню боя")
	_check(_press_text(w.pvp_menu, "Сдаться"), "в меню боя есть «Сдаться»")
	await _frames(2)
	_check(_press_text(w.pvp_menu, "Да, сдаюсь"), "сдача просит подтверждение")
	await _frames(20)
	var st := w.pvp_stats()
	_check(int(st.get("winner", -2)) == 1 and String(st.get("reason", "")) == "surrender",
		"сдача: победила сторона 1, причина surrender")
	_check(w.hud.pvp_result != null and w.hud.pvp_result.is_open(), "экран итога открыт")
	var d := PvpResult.describe(st)
	_check(d["verdict"] == "lose" and d["reason"] == "Вы сдались", "итог: Поражение · Вы сдались")
	_check(main.screen == null and _campaign_snapshot() == _snap,
		"итог Схватки не идёт в кампанию (ни экрана, ни наград, ни звёзд)")
	# «Ещё раз» — тот же матч заново
	_check(w.hud.pvp_result.button("Ещё раз") != null, "кнопка «Ещё раз»")
	w.hud.pvp_result.button("Ещё раз").pressed.emit()
	await _frames(3)
	_check(w.pvp and w.map_id == "pvp:duel" and w.phase == LegionWorld.Phase.BATTLE
		and w.now < 1.0 and not w.hud.pvp_result.is_open(), "«Ещё раз» — тот же матч с нуля")
	# снова сдаёмся и уходим «В меню»
	w.command(0, PvpCmd.surrender())
	await _frames(20)
	_check(w.hud.pvp_result.is_open(), "второй итог открыт")
	w.hud.pvp_result.button("В меню").pressed.emit()
	await _frames(3)
	_check(main.screen is LegionMenu and w.phase == LegionWorld.Phase.MENU,
		"«В меню» ведёт в главное меню (не выход из игры)")
	_check(not w.hud.pvp_result.is_open(), "экран итога убран")
	_check_menu_view(w, "после «В меню»")


func _random_field() -> void:
	_press(main.screen, "PvpAction")
	await _frames(2)
	_press(main.screen, "PvpFieldRandom")
	await _frames(6)
	var w := main.world
	var id1 := w.map_id
	_check(w.pvp and id1.begins_with("gen:") and id1.ends_with(":3:pvp"),
		"«Случайное поле» — gen:<сид>:3:pvp (%s)" % id1)
	_check(w.phase == LegionWorld.Phase.BATTLE and is_equal_approx(w.view_scale(), 0.8),
		"случайное поле: матч идёт, камера ×0,8")
	w.command(0, PvpCmd.surrender())
	await _frames(20)
	w.hud.pvp_result.button("В меню").pressed.emit()
	await _frames(3)
	_press(main.screen, "PvpAction")
	await _frames(2)
	_press(main.screen, "PvpFieldRandom")
	await _frames(6)
	_check(main.world.map_id != id1, "сид новый при каждом входе")
	main.world.command(0, PvpCmd.surrender())
	await _frames(20)
	main.world.hud.pvp_result.button("В меню").pressed.emit()
	await _frames(3)
	_check_menu_view(main.world, "после второго «В меню»")


## Дефект 02.10.2026: после выхода из «Схватки» меню рисовалось сжатым в угол (камера ×0,8), а
## застывшее поле торчало из-под него. Экраны меню — Control на холсте 0: вид обязан быть ×1.
func _check_menu_view(w: LegionWorld, when: String) -> void:
	var plain := w.get_viewport().canvas_transform == Transform2D.IDENTITY
	_check(plain and w.view_xf == Transform2D.IDENTITY,
		"%s: вид меню без сжатия (canvas_transform = тождество)" % when)
	_check(not w.visible, "%s: мир «Схватки» спрятан под меню" % when)


func _back_to_campaign() -> void:
	var maps := Campaign.maps()
	var map_id := String(maps[0].get("id", ""))
	main.start_battle(map_id)
	await _frames(4)
	var w := main.world
	_check(not w.pvp and w.map_id == map_id and w.phase == LegionWorld.Phase.BATTLE,
		"после «Схватки» стартует кампания")
	_check(is_equal_approx(w.view_scale(), 1.0), "кампания: камера ×1")
	_check(w.visible and w.get_viewport().canvas_transform == Transform2D.IDENTITY,
		"кампания: мир виден, вид без сжатия")
	var cam := w.get_viewport().get_camera_2d()
	_check(cam == null or is_equal_approx(cam.zoom.x, 1.0), "кампания: Camera2D ×1")
	_check(w.in_campaign and w.carry_items, "кампания снова читает сохранение")
	_check(w.sides.size() == 1 and w.sides[0].bot == null, "одна сторона, боты Схватки сняты")
	_check(w.hud.pvp_plate == null or not w.hud.pvp_plate.visible, "плашки соперника нет")
	_check(w.hud.pvp_result == null or not w.hud.pvp_result.is_open(), "экрана итога Схватки нет")
	_check(w.pvp_menu == null or not w.pvp_menu.visible, "меню боя Схватки закрыто")
	_check(w.hud.preview_rect().size != Vector2.ZERO, "панель волн одиночки на месте")
	_check(_campaign_snapshot() == _snap, "сохранение кампании не тронуто Схваткой")
	main.show_menu()
	await _frames(2)
	_check(main.screen is LegionMenu, "и снова меню")
	Campaign.reset()
