extends SceneTree
## Узкий baseline: отмена сброса должна вернуть клавиатуру кнопке ResetAsk.
## Нет Main/мира, reset или прямой эмиссии pressed: Enter/Tab идут через Input.

const SAVE := "user://reset_focus.cfg"
var _checks: Array[Dictionary] = []
var _cases: Array[Dictionary] = []
var _route_proof: Dictionary = {}


class InputProbe:
	extends Node
	var keys := 0

	func _input(event: InputEvent) -> void:
		if event is InputEventKey:
			keys += 1


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks.append({"ok": ok, "message": message})
	print("RESET_FOCUS ", "OK " if ok else "FAIL ", message)


func _frames(count := 5) -> void:
	for _i in count:
		await process_frame


func _press(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		Input.parse_input_event(event)
		await _frames(2)
	await _frames()


func _focus() -> Dictionary:
	var node := root.gui_get_focus_owner()
	return {"path": str(node.get_path()) if node != null else "", "name": str(node.name)
		if node != null else "", "visible": node.is_visible_in_tree() if node != null else false}


func _prove_route() -> Dictionary:
	var probe := InputProbe.new()
	root.add_child(probe)
	var holder := VBoxContainer.new()
	var first := Button.new()
	var second := Button.new()
	first.text = "Input route probe"
	second.text = "Tab target"
	holder.add_child(first)
	holder.add_child(second)
	root.add_child(holder)
	var counts: Array[int] = [0, 0]
	first.pressed.connect(func() -> void: counts[0] += 1)
	first.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey:
			counts[1] += 1)
	first.grab_focus()
	await _frames()
	var mapping := InputEventKey.new()
	mapping.keycode = KEY_ENTER
	mapping.physical_keycode = KEY_ENTER
	mapping.pressed = true
	await _press(KEY_ENTER)
	var enter_ok := (counts[0] == 1 and counts[1] >= 2 and probe.keys >= 2
		and mapping.is_action_pressed(&"ui_accept"))
	await _press(KEY_TAB)
	var tab_ok := root.gui_get_focus_owner() == second
	var bindings := {}
	for action: StringName in [&"ui_accept", &"ui_focus_next"]:
		bindings[String(action)] = []
		for event: InputEvent in InputMap.action_get_events(action):
			bindings[String(action)].append({"text": event.as_text(), "device": event.device})
	var result := {"route": "parse", "pressed_count": counts[0], "input_keys": probe.keys,
		"event_device": mapping.device, "bindings": bindings,
		"gui_key_events": counts[1], "enter_ok": enter_ok, "tab_ok": tab_ok,
		"matches_ui_accept": mapping.is_action_pressed(&"ui_accept"),
		"window_id": root.get_window_id(), "headless": DisplayServer.get_name() == "headless",
		"no_focus": root.get_flag(Window.FLAG_NO_FOCUS), "gui_disabled": root.gui_disable_input}
	holder.queue_free()
	probe.queue_free()
	await _frames()
	return result


func _case(locale: String) -> void:
	I18n.select(locale)
	var settings_before := FileAccess.get_sha256(Settings.path)
	var save_before := FileAccess.get_sha256(SAVE)
	var screen := SettingsScreen.new()
	screen.allow_reset = true
	var counts: Array[int] = [0, 0]
	screen.reset_confirmed.connect(func() -> void: counts[0] += 1)
	screen.closed.connect(func() -> void: counts[1] += 1)
	root.add_child(screen)
	await _frames()
	var ask := screen.find_child("ResetAsk", true, false) as Button
	var close := screen.find_child("SettingsClose", true, false) as Button
	var scroll := screen.find_child("SettingsScroll", true, false) as ScrollContainer
	_check(ask != null and close != null and scroll != null, locale + ": controls exist")
	if ask == null or close == null or scroll == null:
		screen.queue_free()
		await _frames()
		return
	ask.grab_focus()
	await _frames()
	var record := {"locale": locale, "before": _focus(), "scroll_before": scroll.scroll_vertical}
	await _press(KEY_ENTER)
	var cancel := root.gui_get_focus_owner() as Button
	_check(cancel != null and cancel.text == I18n.t("Отмена") and cancel.is_visible_in_tree(),
		locale + ": Enter opens confirmation and focuses Cancel")
	var yes := screen.find_child("ResetYes", true, false) as Button
	var warning: Control = null
	if cancel != null:
		warning = cancel.get_parent().get_parent().get_child(0) as Control
	var clip := scroll.get_global_rect()
	_check(cancel != null and yes != null and warning != null
		and clip.encloses(cancel.get_global_rect()) and clip.encloses(yes.get_global_rect())
		and clip.encloses(warning.get_global_rect()),
		locale + ": reset warning and both choices fit inside SettingsScroll")
	_check(not ask.is_visible_in_tree() and not close.is_visible_in_tree(),
		locale + ": confirmation replaces ResetAsk and Done")
	record["confirm"] = _focus()
	if cancel == null or cancel.text != I18n.t("Отмена"):
		_cases.append(record)
		screen.queue_free()
		await _frames()
		return
	await _press(KEY_ENTER)
	record["after_cancel"] = _focus()
	record["scroll_after_cancel"] = scroll.scroll_vertical
	_check(ask.is_visible_in_tree() and close.is_visible_in_tree(),
		locale + ": cancellation restores controls")
	_check(root.gui_get_focus_owner() == ask, locale + ": cancellation restores focus to ResetAsk")
	_check(scroll.get_global_rect().encloses(ask.get_global_rect()),
		locale + ": returned ResetAsk is visible inside scroll viewport")
	await _press(KEY_TAB)
	record["after_tab"] = _focus()
	var focused := root.gui_get_focus_owner()
	_check(focused != null and focused != ask and focused.is_visible_in_tree()
		and screen.is_ancestor_of(focused), locale + ": next Tab stays on a visible settings control")
	_check(counts == [0, 0], locale + ": no reset or close signal")
	_check(FileAccess.get_sha256(SAVE) == save_before, locale + ": progress bytes unchanged")
	_check(FileAccess.get_sha256(Settings.path) == settings_before,
		locale + ": settings bytes unchanged")
	record["signals"] = counts.duplicate()
	_cases.append(record)
	screen.queue_free()
	await _frames()


func _run() -> void:
	Settings.use_dev_save(SAVE)
	Settings.apply()
	AudioServer.set_bus_mute(0, true)
	# Контролируемый CFG-маркер: экран не должен писать в прогресс при отмене.
	var sentinel := ConfigFile.new()
	sentinel.set_value("qa", "marker", "reset-cancel-must-not-write")
	_check(sentinel.save(SAVE) == OK, "isolated sentinel created")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(960, 540)
	await _frames()
	var attempts: Array[Dictionary] = [await _prove_route()]
	var chosen: Dictionary = attempts.back()
	var route_ok := bool(chosen["enter_ok"]) and bool(chosen["tab_ok"])
	_route_proof = {"attempts": attempts, "selected_route": "parse", "success": route_ok}
	_check(route_ok, "input route: native Button Enter and Tab work")
	if route_ok:
		await _case("ru")
		await _case("en")
	var success := true
	for entry in _checks:
		success = success and bool(entry["ok"])
	var outcome := {"success": success, "checks": _checks, "cases": _cases,
		"size": [root.size.x, root.size.y], "user_data_dir": OS.get_user_data_dir(),
		"main_or_world_instantiated": false, "input_route_proof": _route_proof}
	var out_dir := OS.get_environment("QA_OUT")
	if not out_dir.is_empty():
		var output := FileAccess.open(out_dir.path_join("outcome.json"), FileAccess.WRITE)
		if output == null:
			quit(2)
			return
		output.store_string(JSON.stringify(outcome, "\t"))
		output.close()
	quit(0 if success else 1)
