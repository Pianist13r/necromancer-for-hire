extends SceneTree
##
## Самопроверка проводки экранов режима «По истечении договора» (пакет flow, без окна):
## меню → брифинг → бой → принудительный итог → поправка → брифинг следующей карты → бой
## с применённой поправкой. Ведёт LegionMain, эмитируя сигналы экранов — как реальные клики.
## Сохранение — во временный файл (Campaign.set_save_path), реальный user://legion.cfg
## владельца не трогает.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_flow_test.gd -- --mute
##
## Итог «LEGION FLOW: N/N OK»; код выхода 1, если что-то упало.
##

const TEST_PATH := "user://legion_flow_test_run.cfg"
## Проверяем действующую поправку: стоимость чернил и встречная цена найма.
const CHOSEN_UPGRADE := &"bulk_ink"

var main: LegionMain
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


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	# Пакет cuts: вступительная катсцена реальному игроку блокирует показ брифинга до своего
	# конца (docs/legion/DESIGN_V15.md §9) — этот тест проверяет проводку ЭКРАНОВ кампании,
	# не катсцену, так что отмечаем её увиденной заранее (тот же приём, что TEST_PATH выше).
	# Чужой файл (пакет flow), правка минимальная — см. отчёт пакета cuts.
	Campaign.set_intro_cutscene_seen()

	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)

	_check(main.screen is LegionMenu, "старт: меню")

	var maps := Campaign.maps()
	_check(maps.size() >= 2, "кампания даёт минимум 2 карты (иначе цепочка «следующая» не проверить)")
	var map_id := String(maps[0].get("id", ""))
	var next_id := String(maps[1].get("id", ""))

	# меню → брифинг (как клик «Продолжить»)
	(main.screen as LegionMenu).continue_pressed.emit(map_id)
	await _frames(2)
	_check(main.screen is Briefing, "меню → брифинг")

	# брифинг → бой (как клик «В бой»)
	(main.screen as Briefing).start.emit(map_id)
	await _frames(2)
	_check(main.world != null and main.world.phase == LegionWorld.Phase.BATTLE
		and main.world.map_id == map_id, "брифинг → бой на выбранной карте")

	await _test_pause()

	# принудительный итог публичным API — реальный бой гонять незачем, проверяем проводку экранов
	main.world.force_end(true)
	await _frames(2)
	_check(main.screen is LegionResult, "бой → итог")
	_check(Campaign.stars(map_id) > 0, "победа записана в прогресс (звёзды > 0)")

	# итог → поправка (клик «Дальше»)
	(main.screen as LegionResult).next.emit()
	await _frames(2)
	_check(main.screen is UpgradePicker, "итог → выбор поправки")

	# выбор конкретной поправки (клик по карточке)
	# Поправка сразу открывает брифинг; подготовка — на нём же (D-1007-P1).
	(main.screen as UpgradePicker).picked.emit(CHOSEN_UPGRADE)
	await _frames(2)
	_check(Campaign.upgrades().has(CHOSEN_UPGRADE), "поправка взята в прогресс кампании")
	_check(Campaign.is_unlocked(next_id), "следующая карта открыта")
	_check(main.screen is Briefing, "поправка → брифинг следующей карты")

	# брифинг следующей карты → бой — поправка должна изменить число мира
	(main.screen as Briefing).start.emit(next_id)
	await _frames(2)
	_check(main.world.map_id == next_id and main.world.phase == LegionWorld.Phase.BATTLE,
		"брифинг следующей карты → бой")
	_check(is_equal_approx(Campaign.stat(&"mana_cost_mult"), 0.65)
		and is_equal_approx(Campaign.stat(&"recruit_r_laborer"), -60.0),
		"поправка и её цена применены на следующем объекте")

	await _test_defeat_retry_menu()
	await _test_settings_wired()
	await _test_pending_reward_survives_menu()
	await _test_empty_pool_skips_picker()
	await _test_reset_progress()   # последним: стирает прогресс
	await _test_victory_retry_reward()

	print("LEGION FLOW: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Esc внутри боя показывает экран паузы поверх мира, «Продолжить» его убирает.
func _test_pause() -> void:
	main.world.set_paused(true)
	await _frames(1)
	_check(_has_pause_screen(), "Esc/пауза показывает LegionPause")
	main.world.set_paused(false)
	await _frames(1)
	_check(not _has_pause_screen(), "снятие паузы убирает LegionPause")


func _has_pause_screen() -> bool:
	for c in main.get_children():
		if c is LegionPause:
			return true
	return false


## Поражение: итог без «Дальше», «Ещё раз» вновь ведёт в бой той же картой.
func _test_defeat_retry_menu() -> void:
	var map_id := main.world.map_id
	main.world.force_end(false)
	await _frames(2)
	_check(main.screen is LegionResult, "поражение → итог")
	(main.screen as LegionResult).retry.emit()
	await _frames(2)
	_check(main.screen is Briefing, "«Ещё раз» после поражения даёт подготовиться")
	if main.screen is Briefing:
		(main.screen as Briefing).start.emit(map_id)
		await _frames(2)
	_check(main.world.phase == LegionWorld.Phase.BATTLE and main.world.map_id == map_id,
		"«Ещё раз» после поражения вернул в бой той же картой")
	main.world.force_end(false)
	await _frames(2)
	(main.screen as LegionResult).menu.emit()
	await _frames(2)
	_check(main.screen is LegionMenu, "«Меню» после поражения вернул в меню")
	_check(main.world.phase == LegionWorld.Phase.MENU,
		"мир остановлен (go_to_menu), не тикает вхолостую")


## Ревью 2026-09-24, п.2: settings_pressed из меню и из паузы должен реально открывать
## SettingsScreen (сигнал раньше висел без обработчика).
func _test_settings_wired() -> void:
	main.show_menu()
	await _frames(2)
	(main.screen as LegionMenu).settings_pressed.emit()
	await _frames(2)
	var s := _find_settings_screen()
	_check(s != null, "settings_pressed из меню открывает SettingsScreen")
	if s != null:
		s.closed.emit()
		await _frames(1)
		_check(_find_settings_screen() == null, "SettingsScreen закрывается по closed")

	main.world.set_paused(true)
	await _frames(1)
	_check(_has_pause_screen(), "пауза открыта перед проверкой настроек")
	main._pause_screen.settings_pressed.emit()
	await _frames(2)
	var s2 := _find_settings_screen()
	_check(s2 != null, "settings_pressed из паузы открывает SettingsScreen")
	if s2 != null:
		_check(s2.find_child("ResetAsk", true, false) == null,
			"в настройках из паузы кнопки сброса прогресса нет")
		s2.closed.emit()
		await _frames(1)
	main.world.set_paused(false)
	await _frames(1)


## P1: две победы через настоящий клик «Ещё раз» должны дать две независимые поправки.
func _test_victory_retry_reward() -> void:
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	main.start_battle("wasteland")
	await _frames(3)
	main.world.force_end(true)
	await _frames(3)
	var retry_button: Button = null
	for btn in main.screen.find_children("*", "Button", true, false):
		if btn.text == "Ещё раз":
			retry_button = btn
	_check(retry_button != null, "победа: повтор доступен")
	if retry_button == null:
		return
	var point := root.get_final_transform() * retry_button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.device = 8
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	await _frames(1)
	for down: bool in [true, false]:
		var click := InputEventMouseButton.new()
		click.device = 8
		click.position = point
		click.global_position = point
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = down
		click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		Input.parse_input_event(click)
		await _frames(2)
	_check(main.screen is UpgradePicker, "победа → Ещё раз → выбор первой награды")
	if not main.screen is UpgradePicker:
		main.show_menu()
		await _frames(2)
		return
	var picker := main.screen as UpgradePicker
	picker.choose(picker.offered()[0])
	await _frames(3)
	_check(main.screen is Briefing and Campaign.upgrades().size() == 1,
		"первый выбор сохранён, повтор идёт через брифинг")
	(main.screen as Briefing).start.emit("wasteland")
	await _frames(3)
	main.world.force_end(true)
	await _frames(3)
	(main.screen as LegionResult).next.emit()
	await _frames(3)
	_check(main.screen is UpgradePicker and not Campaign.reward_claimed(),
		"вторая победа предлагает вторую награду")
	if main.screen is UpgradePicker:
		picker = main.screen as UpgradePicker
		picker.choose(picker.offered()[0])
		await _frames(3)
	_check(Campaign.upgrades().size() == 2, "две победы — две подписанные поправки")
	main.show_menu()
	await _frames(2)


func _find_settings_screen() -> SettingsScreen:
	for c in main.get_children():
		if c is SettingsScreen:
			return c
	return null


## Ревью 2026-09-24, п.4: незабранная награда переживает уход в «Меню» и предлагается при
## «Продолжить»; повторная победа на уже пройденной карте не плодит вторую ожидающую награду.
func _test_pending_reward_survives_menu() -> void:
	var target_map := String(Campaign.maps()[1].get("id", ""))
	main.show_menu()
	await _frames(2)
	(main.screen as LegionMenu).continue_pressed.emit(target_map)
	await _frames(2)
	(main.screen as Briefing).start.emit(target_map)
	await _frames(2)
	main.world.force_end(true)
	await _frames(2)
	(main.screen as LegionResult).menu.emit()
	await _frames(2)
	_check(main.screen is LegionMenu, "«Меню» вместо «Дальше» возвращает в меню")
	var pending := Campaign.pending_reward()
	_check(pending != "", "награда осталась ожидающей в Campaign после ухода в меню")

	# Повторная победа на этой же (уже пройденной) карте не плодит вторую ожидающую награду.
	main._on_match_ended(true, {"hp": main.world.cauldron_max})
	await _frames(2)
	_check(Campaign.pending_reward() == pending,
		"повторная победа на пройденной карте не даёт вторую ожидающую награду")

	(main.screen as LegionResult).menu.emit()
	await _frames(2)
	(main.screen as LegionMenu).continue_pressed.emit(target_map)
	await _frames(2)
	_check(main.screen is UpgradePicker,
		"«Продолжить» с ожидающей наградой открывает поправку, не брифинг")
	main.pick_upgrade((main.screen as UpgradePicker).offered()[0])
	await _frames(2)
	_check(main.screen is Briefing, "pick_upgrade сразу ведёт на следующий брифинг")
	_check(Campaign.pending_reward() == "", "награда забрана и переход завершён")



## Ревью 2026-09-24, п.1: пул поправок исчерпан (взяты все) — экран поправок не открывается
## пустым и без выхода, «Дальше» сразу ведёт на брифинг следующей карты.
func _test_empty_pool_skips_picker() -> void:
	# Пул больше не исчерпывается тремя активными: четвёртая поправка заменяет одну из них.
	# Проверяем мигрированное состояние «уже забрана», не подделывая невозможные десять слотов.
	var target := String(Campaign.maps()[1]["id"])
	Campaign.set_pending_reward(target)
	Campaign.raw_file().set_value(Campaign._meta_section(), "reward_claimed", true)
	Campaign.save_raw()
	main._pending_next_map = target
	var before := Campaign.upgrades().duplicate()
	main._offer_upgrade_or_skip()
	await _frames(2)
	_check(main.screen is Briefing, "забранная награда пропускает picker и Контору")
	_check(Campaign.upgrades() == before, "повторный переход не выдаёт поправку")



## Сброс сохранения из «Настроек» главного меню: «Отмена» ничего не стирает, «Стереть» — стирает
## прогресс (звёзды, премия, обучение, вступление) и возвращает в меню.
func _test_reset_progress() -> void:
	var first := String(Campaign.maps()[0].get("id", ""))
	Campaign.record_result(first, true, 1.0)
	Campaign.record_rewards(true, 3, 50)
	Campaign.set_tutorial_done()
	_check(Campaign.stars(first) > 0 and Campaign.bounty() > 0, "перед сбросом прогресс есть")

	main.show_menu()
	await _frames(2)
	(main.screen as LegionMenu).settings_pressed.emit()
	await _frames(2)
	var s := _find_settings_screen()
	var ask: Button = null if s == null else s.find_child("ResetAsk", true, false) as Button
	_check(ask != null, "в настройках из меню есть «Сбросить прогресс…»")
	if s == null or ask == null:
		return
	ask.pressed.emit()
	await _frames(1)
	var close_btn := s.find_child("SettingsClose", true, false) as Button
	var cancel: Button = null
	for b in s.find_children("*", "Button", true, false):
		if (b as Button).text == "Отмена":
			cancel = b
	_check(cancel != null and cancel.is_visible_in_tree(), "сброс спрашивает подтверждение")
	_check(close_btn != null and not close_btn.is_visible_in_tree(),
		"при подтверждении «Готово» скрыто, остаётся явный выбор действия")
	if cancel != null:
		cancel.pressed.emit()
		await _frames(1)
	_check(Campaign.stars(first) > 0, "«Отмена» прогресс не стирает")
	_check(ask.visible, "после «Отмена» снова видна кнопка сброса")
	_check(close_btn != null and close_btn.is_visible_in_tree(),
		"после отмены снова доступна кнопка «Готово»")

	ask.pressed.emit()
	await _frames(1)
	(s.find_child("ResetYes", true, false) as Button).pressed.emit()
	await _frames(2)
	_check(Campaign.stars(first) == 0 and Campaign.bounty() == 0,
		"«Стереть» обнуляет звёзды и премию")
	_check(not Campaign.tutorial_done() and not Campaign.intro_cutscene_seen(),
		"после сброса обучение и вступление снова не пройдены")
	_check(_find_settings_screen() == null and main.screen is LegionMenu,
		"после сброса настройки закрыты, на экране меню")
	_check(main.screen is LegionMenu and _menu_has_button("Начать смену"),
		"после сброса главная кнопка меню — «Начать смену», не «Продолжить»")


func _menu_has_button(text: String) -> bool:
	for b in main.screen.find_children("*", "Button", true, false):
		if (b as Button).text == text:
			return true
	return false
