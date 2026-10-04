extends SceneTree
##
## Регрессия экрана «Лицензии» (публикация игры): кнопка в настройках открывает модальный
## оверлей с текстами лицензий третьих сторон; Esc закрывает ТОЛЬКО его и возвращает фокус
## кнопке «Лицензии» (настройки остаются); круг Tab замкнут; текст листается клавишами.
## Настройки пишут в песочный user://legion_licenses_test.cfg.
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --fixed-fps 60 --path godot \
##       --script res://tests/legion_licenses_test.gd -- --mute
##
## Итог «LEGION LICENSES: N/N OK», код выхода 1 при провале.
##

const SAVE := "user://legion_licenses_test.cfg"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL ", what)


func _settle() -> void:
	await process_frame
	await process_frame


func _press(code: Key, shift := false) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = true
	k.shift_pressed = shift
	Input.parse_input_event(k)
	await process_frame
	var r := k.duplicate() as InputEventKey
	r.pressed = false
	Input.parse_input_event(r)
	await process_frame


func _run() -> void:
	Settings.path = SAVE
	Settings._cfg = null
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	await _settle()

	var s := SettingsScreen.new()
	s.process_mode = Node.PROCESS_MODE_ALWAYS
	var closes: Array[int] = [0]
	s.closed.connect(func() -> void: closes[0] += 1)
	root.add_child(s)
	await _settle()

	var btn := s.find_child("SettingsLicenses", true, false) as Button
	_check(btn != null, "кнопка «Лицензии» есть в настройках")
	_check(btn != null and btn.text == "Лицензии", "подпись кнопки — «Лицензии»")
	if btn == null:
		print("LEGION LICENSES: %d/%d OK" % [_checks - _fails, _checks])
		quit(1)
		return
	btn.grab_focus()
	await _settle()
	_check(s.get_node_or_null("LicensesScreen") == null, "до нажатия оверлея нет")

	var t0 := Time.get_ticks_msec()
	btn.pressed.emit()
	await _settle()
	var build_ms := Time.get_ticks_msec() - t0
	var ov := s.get_node_or_null("LicensesScreen") as LicensesScreen
	_check(ov != null, "нажатие открывает оверлей лицензий")
	if ov == null:
		print("LEGION LICENSES: %d/%d OK" % [_checks - _fails, _checks])
		quit(1)
		return
	print("licenses overlay built+laid out in ", build_ms, " ms")
	_check(build_ms < 3000, "оверлей строится быстро (%d мс)" % build_ms)

	var text := ov.full_text()
	print("licenses text length: ", text.length())
	for needle in [
		"PolyForm Noncommercial", "Губанов", "MIT License", "SIL Open Font License", "CC0",
		"Godot Engine", "Juicee", "godot-mcp", "Underdog", "Neucha", "Kenney",
		"kenney.nl", "github.com/Pianist13r/necromancer-for-hire", "товарные знаки",
	]:
		_check(text.contains(needle), "в тексте есть «%s»" % needle)
	var godot_text := Engine.get_license_text().strip_edges()
	_check(godot_text.length() > 200 and text.contains(godot_text.substr(0, 60)),
		"в тексте начало лицензии Godot («%s…»)" % godot_text.substr(0, 40).replace("\n", " "))
	_check(text.contains("Copyright (c) 2014-present Godot Engine contributors"),
		"в тексте copyright Godot Engine contributors")
	_check(not text.contains("файл не найден"), "все файлы лицензий из assets/legal найдены")
	var comps: Array = Engine.get_copyright_info()
	_check(comps.size() > 5 and text.contains(String((comps[0] as Dictionary)["name"])),
		"перечислены сторонние компоненты Godot (%d)" % comps.size())
	var info: Dictionary = Engine.get_license_info()
	_check(info.size() > 0 and text.contains(String(info.keys()[0])),
		"приведены тексты лицензий компонентов Godot (%d)" % info.size())

	var rt := ov.find_child("LicensesText", true, false) as RichTextLabel
	var close_btn := ov.find_child("LicensesClose", true, false) as Button
	var panel := ov.find_child("LicensesPanel", true, false) as Control
	var vp := Rect2(Vector2.ZERO, Vector2(root.size))
	_check(rt != null and close_btn != null and panel != null, "текст, «Закрыть» и панель на месте")
	_check(vp.encloses(panel.get_global_rect()), "панель целиком в 1280×720")
	_check(vp.encloses(close_btn.get_global_rect()), "«Закрыть» виден целиком")
	_check(not rt.is_ancestor_of(close_btn), "«Закрыть» вне прокрутки")
	_check(rt.get_v_scroll_bar().max_value > rt.size.y * 3.0, "текст длинный и листается")

	var focused := root.gui_get_focus_owner()
	_check(focused == rt, "начальный фокус — на тексте (клавиши листают)")
	# До первой клавиши: она уже настраивает круг фокуса и маскирует дефект геймпада.
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_DPAD_DOWN
	pad.pressed = true
	Input.parse_input_event(pad)
	await _settle()
	var pad_release := pad.duplicate() as InputEventJoypadButton
	pad_release.pressed = false
	Input.parse_input_event(pad_release)
	await _settle()
	var pad_focus := root.gui_get_focus_owner()
	_check(pad_focus != null and ov.is_ancestor_of(pad_focus),
		"первый ввод геймпада не уводит фокус в настройки")
	rt.grab_focus()
	var before := rt.get_v_scroll_bar().value
	await _press(KEY_PAGEDOWN)
	_check(rt.get_v_scroll_bar().value > before, "PageDown листает текст")
	before = rt.get_v_scroll_bar().value
	await _press(KEY_DOWN)
	_check(rt.get_v_scroll_bar().value > before, "стрелка вниз листает текст")

	var inside := true
	for i in 8:
		await _press(KEY_TAB, i >= 4)
		var f := root.gui_get_focus_owner()
		inside = inside and f != null and ov.is_ancestor_of(f)
	_check(inside, "круг Tab/Shift+Tab не уходит на кнопки настроек")

	# Колесо мыши листает текст (событие в позиции над текстом).
	var wheel_before := rt.get_v_scroll_bar().value
	var w := InputEventMouseButton.new()
	w.button_index = MOUSE_BUTTON_WHEEL_DOWN
	w.pressed = true
	w.position = rt.get_global_rect().get_center()
	w.global_position = w.position
	Input.parse_input_event(w)
	await _settle()
	_check(rt.get_v_scroll_bar().value > wheel_before, "колесо мыши листает текст")

	await _press(KEY_ESCAPE)
	await _settle()
	_check(s.get_node_or_null("LicensesScreen") == null, "Esc закрывает оверлей лицензий")
	_check(closes[0] == 0, "Esc лицензий не закрывает настройки")
	_check(root.gui_get_focus_owner() == btn, "фокус вернулся кнопке «Лицензии»")

	# Повторное открытие кнопкой с клавиатуры (Enter) и закрытие кнопкой «Закрыть».
	await _press(KEY_ENTER)
	await _settle()
	ov = s.get_node_or_null("LicensesScreen") as LicensesScreen
	_check(ov != null, "Enter на кнопке открывает оверлей повторно")
	if ov != null:
		(ov.find_child("LicensesClose", true, false) as Button).pressed.emit()
		await _settle()
		_check(s.get_node_or_null("LicensesScreen") == null, "«Закрыть» закрывает оверлей")
		_check(root.gui_get_focus_owner() == btn, "после «Закрыть» фокус у кнопки «Лицензии»")

	await _press(KEY_ESCAPE)
	_check(closes[0] == 1, "второй Esc закрывает настройки ровно раз")

	print("LEGION LICENSES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
