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
## Поправка с легко проверяемым числовым эффектом (cauldron_hp_bonus = +30 к максимуму Котла).
const CHOSEN_UPGRADE := &"cauldron_insurance"

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
	# meta (задание meta п.2, правка чужого файла — координация с пакетом flow): после поправки
	# теперь экран «Контора», «Дальше» там ведёт на брифинг следующей карты.
	(main.screen as UpgradePicker).picked.emit(CHOSEN_UPGRADE)
	await _frames(2)
	_check(Campaign.upgrades().has(CHOSEN_UPGRADE), "поправка взята в прогресс кампании")
	_check(Campaign.is_unlocked(next_id), "следующая карта открыта")
	_check(main.screen is OfficeShop, "поправка → «Контора» (meta)")
	(main.screen as OfficeShop).back.emit()
	await _frames(2)
	_check(main.screen is Briefing, "«Контора» → брифинг следующей карты")

	# брифинг следующей карты → бой — поправка должна изменить число мира
	var base_hp := float(Campaign.map(next_id).get("cauldron_hp", LegionCfg.CAULDRON_HP))
	(main.screen as Briefing).start.emit(next_id)
	await _frames(2)
	_check(main.world.map_id == next_id and main.world.phase == LegionWorld.Phase.BATTLE,
		"брифинг следующей карты → бой")
	_check(absf(main.world.cauldron_hp - (base_hp + 30.0)) < 0.01,
		"cauldron_insurance реально прибавила 30 HP Котла в бою (%.1f ожидалось, %.1f получено)"
			% [base_hp + 30.0, main.world.cauldron_hp])

	await _test_defeat_retry_menu()
	await _test_settings_wired()
	await _test_pending_reward_survives_menu()
	await _test_empty_pool_skips_picker()
	await _test_reset_progress()   # последним: стирает прогресс

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
	main.pick_upgrade(&"aggressive_lawyers")
	await _frames(2)
	# meta: pick_upgrade теперь ведёт в «Контору», метка ожидающей награды снимается только
	# на выходе оттуда («Дальше»), не сразу при выборе поправки.
	_check(main.screen is OfficeShop, "pick_upgrade ведёт в «Контору» перед брифингом")
	(main.screen as OfficeShop).back.emit()
	await _frames(2)
	_check(Campaign.pending_reward() == "", "выход из «Конторы» снимает метку ожидающей награды")


## Ревью 2026-09-24, п.1: пул поправок исчерпан (взяты все) — экран поправок не открывается
## пустым и без выхода, «Дальше» сразу ведёт на брифинг следующей карты.
func _test_empty_pool_skips_picker() -> void:
	for id in LegionMetaCfg.UPGRADE_ORDER:
		Campaign.add_upgrade(StringName(id))
	_check(Campaign.offer_upgrades(main.world.rng).is_empty(), "пул поправок исчерпан")

	var target_map := String(Campaign.maps()[0].get("id", ""))
	main.show_menu()
	await _frames(2)
	(main.screen as LegionMenu).continue_pressed.emit(target_map)
	await _frames(2)
	(main.screen as Briefing).start.emit(target_map)
	await _frames(2)
	main.world.force_end(true)
	await _frames(2)
	_check(main.screen is LegionResult, "победа с пустым пулом → итог")
	(main.screen as LegionResult).next.emit()
	await _frames(2)
	_check(not (main.screen is UpgradePicker), "пустой пул поправок не открывает пустой экран")
	# meta: пустой пул ведёт сразу в «Контору» (премия за бой всё равно есть, что тратить),
	# «Дальше» оттуда — на брифинг следующей карты или в меню.
	_check(main.screen is OfficeShop, "пустой пул поправок сразу ведёт в «Контору»")
	(main.screen as OfficeShop).back.emit()
	await _frames(2)
	_check(main.screen is Briefing or main.screen is LegionMenu,
		"«Контора» → брифинг следующей карты или в меню")


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
