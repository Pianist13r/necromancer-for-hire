extends SceneTree
## Полная колода: «Ещё раз» после победы сначала предлагает незабранную награду.
## Выход в меню отменяет переигровку; «Продолжить» возвращает то же предложение
## и ведёт к следующему брифингу. Замена без выхода в меню ведёт обратно на Мост.
## Победа задана через force_end как условие проверки переходов, а не выиграна в бою.
## Проверяем сигналы, синтетический ввод и диск; баланс и нативный ввод не оцениваем.
## Запуск: headless, fixed-fps 60, --mute и отдельный APPDATA.

const SAVE := "user://legion_reward_retry_replace_flow_test.cfg"
const DECK: Array[StringName] = [&"living_queue", &"ghost_clause", &"carbon_copy"]

var main: LegionMain
var _checks := 0
var _fails := 0
var _escape_device := 8


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> bool:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])
	return ok


func _ready_when(condition: Callable, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + 60000
	while not condition.call():
		if Time.get_ticks_msec() >= deadline:
			return _check(false, message + ": timeout")
		await process_frame
	return _check(true, message)


func _disk_state() -> Dictionary:
	# Свежий ConfigFile читает диск независимо от кэша Campaign.
	var file := ConfigFile.new()
	if not _check(file.load(SAVE) == OK, "independent save read succeeds"):
		return {}
	return {
		"deck": file.get_value("meta", "upgrades", []),
		"pending": file.get_value("meta", "pending_reward", ""),
		"claimed": file.get_value("meta", "reward_claimed", false),
		"bounty": file.get_value("meta", "bounty", 0),
		"options": file.get_value("meta", "draft_options", []),
	}


func _expect_disk(deck: Array, pending: String, bounty: int, options: Array) -> void:
	var state := _disk_state()
	# Колода хранит StringName, предложение — String. Сравниваем идентификаторы
	# обеих сторон в одном типе, без множества и без потери порядка.
	var actual_deck: Array = state.get("deck", [])
	actual_deck = actual_deck.map(func(id: Variant) -> String: return String(id))
	var actual_options: Array = state.get("options", [])
	actual_options = actual_options.map(func(id: Variant) -> String: return String(id))
	var expected_deck := deck.map(func(id: Variant) -> String: return String(id))
	var expected_options := options.map(func(id: Variant) -> String: return String(id))
	_check(actual_deck == expected_deck,
		"disk deck: actual=%s expected=%s" % [state.get("deck"), expected_deck])
	_check(state.get("pending") == pending and state.get("claimed") == false,
		"disk transition: actual=%s/%s expected=%s/false"
		% [state.get("pending"), state.get("claimed"), pending])
	_check(state.get("bounty") == bounty,
		"disk bounty: actual=%s expected=%d" % [state.get("bounty"), bounty])
	_check(actual_options == expected_options,
		"disk offer: actual=%s expected=%s" % [state.get("options"), expected_options])


func _dispose_main() -> void:
	if is_instance_valid(main):
		main.queue_free()
	main = null
	await process_frame
	await process_frame


func _scenario(via_menu: bool, keyboard := false) -> void:
	print("— full deck victory Retry, via menu = ", via_menu)
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	for id in DECK:
		Campaign.add_upgrade(id)
	if not _check(Campaign.upgrades() == DECK, "fixture has three active amendments"):
		return
	var maps := Campaign.maps()
	var bridge_index := -1
	for i in maps.size():
		if String(maps[i].get("id", "")) == "bridge":
			bridge_index = i
	if not _check(bridge_index >= 0 and bridge_index + 1 < maps.size(),
			"bridge has a next campaign map"):
		return
	var next_id := String(maps[bridge_index + 1]["id"])
	# Ранние победы задаём как исходные данные. Итог Моста пройдёт через Main
	# после force_end ниже: это постановка исхода для теста, не прохождение боя.
	for i in bridge_index:
		Campaign.record_result(String(maps[i]["id"]), true, 1.0)
	main = LegionMain.new()
	root.add_child(main)
	await process_frame
	await process_frame
	main.start_battle("bridge")
	if not await _ready_when(func() -> bool:
		return not main._loading_battle and main.world != null \
		and main.world.map_id == "bridge" and main.world.phase == LegionWorld.Phase.BATTLE,
		"bridge battle is ready"):
		return
	main.world.hold = true
	main.world.force_end(true)
	if not await _ready_when(func() -> bool: return main.screen is LegionResult,
		"real victory result is visible"):
		return
	_check(Campaign.stars("bridge") > 0 and Campaign.pending_reward() == next_id,
		"bridge victory records stars and next-map reward")
	var bounty := Campaign.bounty()
	(main.screen as LegionResult).retry.emit()
	if not await _ready_when(func() -> bool:
		return main.screen is UpgradePicker and not (main.screen as UpgradePicker).offered().is_empty(),
		"victory Retry offers the unclaimed reward before replay"):
		return
	await _reward_flow(via_menu, next_id, bounty, keyboard)


func _reward_flow(via_menu: bool, next_id: String, bounty: int, keyboard: bool) -> void:
	var picker := main.screen as UpgradePicker
	var options := picker.offered()
	if not _check(options.size() == 3 and not DECK.has(options[0]),
			"real offer contains a fourth amendment"):
		return
	var chosen := options[0]
	_expect_disk(DECK, next_id, bounty, options)
	picker.choose(chosen)
	_check(main.screen == picker and Campaign.upgrades() == DECK,
		"fourth choice waits for an explicit slot, without granting")
	_expect_disk(DECK, next_id, bounty, options)
	if keyboard:
		await _escape_flow(picker, options, next_id, bounty)
		return
	if via_menu:
		# Сигнал настоящей кнопки проверяет её подключение к отмене замены.
		var cancel: Button = null
		for node in picker.find_children("*", "Button", true, false):
			if (node as Button).text == I18n.t("Вернуться к предложению"):
				cancel = node as Button
		if not _check(cancel != null, "replacement exposes its cancel action"):
			return
		cancel.pressed.emit()
		await process_frame
		_check(main.screen == picker and picker.offered() == options,
			"cancel preserves the same proposal")
		_expect_disk(DECK, next_id, bounty, options)
		picker.back.emit()
		if not await _ready_when(func() -> bool: return main.screen is LegionMenu,
			"picker back opens main menu"):
			return
		_expect_disk(DECK, next_id, bounty, options)
		var menu := main.screen as LegionMenu
		menu.continue_pressed.emit(menu._next_map_id())
		if not await _ready_when(func() -> bool:
			return main.screen is UpgradePicker and not (main.screen as UpgradePicker).offered().is_empty(),
			"Continue resumes the reward"):
			return
		picker = main.screen as UpgradePicker
		_check(picker.offered() == options, "Continue does not redraw the saved proposal")
		picker.choose(chosen)
	picker.replace(1)
	# populate вызывается отложенно: появление узла ещё не означает готовый брифинг.
	# Ждём любой непустой id, затем отдельно проверяем правильность маршрута.
	if not await _ready_when(func() -> bool:
		return main.screen is Briefing and (main.screen as Briefing)._map_id != "",
		"explicit replacement reaches a populated briefing"):
		return
	var target := next_id if via_menu else "bridge"
	_check((main.screen as Briefing)._map_id == target,
		"briefing destination: actual=%s expected=%s"
		% [(main.screen as Briefing)._map_id, target])
	var expected := DECK.duplicate()
	expected[1] = chosen
	_check(Campaign.upgrades() == expected and Campaign.upgrades().size() == 3,
		"only the selected middle slot is replaced")
	_expect_disk(expected, "", bounty, [])
	# Повторная доставка не должна снова выдать награду или сменить готовый брифинг.
	main.pick_upgrade(chosen)
	_check(main.screen is Briefing and (main.screen as Briefing)._map_id == target,
		"duplicate delivery destination: actual=%s expected=%s"
		% [(main.screen as Briefing)._map_id if main.screen is Briefing else "not Briefing", target])
	_expect_disk(expected, "", bounty, [])
	Campaign.set_save_path(SAVE)
	Campaign.use_campaign_scope()
	_check(Campaign.upgrades() == expected and Campaign.pending_reward() == ""
		and not Campaign.reward_claimed() and Campaign.bounty() == bounty,
		"fresh Campaign read agrees with independent disk state")


func _escape() -> void:
	var event := InputEventKey.new()
	event.device = _escape_device
	event.keycode = KEY_ESCAPE
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	_check(event.is_action_pressed("ui_cancel"), "real Escape matches ui_cancel")
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	event = event.duplicate() as InputEventKey
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
	await process_frame


func _escape_flow(picker: UpgradePicker, options: Array, next_id: String, bounty: int) -> void:
	# Событие проходит обычный маршрут ввода; прямой вызов отмены скрыл бы перехват Esc.
	await process_frame
	await process_frame
	print("ESC diagnostic: processing=", picker.is_processing_unhandled_key_input(),
		" focus=", root.gui_get_focus_owner(), " visible=", picker.is_visible_in_tree())
	await _escape()
	var restored := main.screen == picker and picker._cards_box.visible
	_check(restored, "first real Escape restores proposal without leaving picker")
	_expect_disk(DECK, next_id, bounty, options)
	if not restored:
		return
	_check(picker.offered() == options, "Escape preserves exact proposal")
	await _escape()
	_check(main.screen is LegionMenu, "second real Escape opens main menu")
	_expect_disk(DECK, next_id, bounty, options)


func _run() -> void:
	I18n.initialize("ru")
	for via_menu: bool in [true, false]:
		await _scenario(via_menu)
		await _dispose_main()
	# Дубль привязки живёт только вместе с corr; повторная установка не плодит события.
	var original := InputMap.action_get_events(&"ui_cancel")
	var corr := preload("res://scripts/dev/corr_play.gd").new()
	corr._install_cancel_alias()
	var installed := InputMap.action_get_events(&"ui_cancel")
	corr._install_cancel_alias()
	_check(InputMap.action_get_events(&"ui_cancel") == installed, "corr setup is idempotent")
	await _scenario(true, true)
	await _dispose_main()
	corr._cleanup_input()
	_check(InputMap.action_get_events(&"ui_cancel") == original, "corr cleanup restores bindings")
	corr._install_cancel_alias()
	_check(InputMap.action_get_events(&"ui_cancel").size() == installed.size(),
		"corr reinstall has exactly one alias")
	corr._cleanup_input()
	corr._cleanup_input()
	_check(InputMap.action_get_events(&"ui_cancel") == original, "repeated cleanup is harmless")
	# Предсуществующий дубль принадлежит другому потребителю: corr не должен его удалять.
	var existing := original[0].duplicate() as InputEventKey
	existing.device = 8
	InputMap.action_add_event(&"ui_cancel", existing)
	var shared := InputMap.action_get_events(&"ui_cancel")
	corr._install_cancel_alias()
	corr._cleanup_input()
	_check(InputMap.action_get_events(&"ui_cancel") == shared, "cleanup preserves existing alias")
	InputMap.action_erase_event(&"ui_cancel", existing)
	_check(InputMap.action_get_events(&"ui_cancel") == original, "test removes only its own alias")
	corr.free()
	_escape_device = InputEventKey.new().device
	await _scenario(true, true)
	await _dispose_main()
	# Отдельное тестовое сохранение оставляем для проверки; профиль владельца не трогаем.
	print("LEGION REWARD RETRY REPLACE FLOW: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
