extends SceneTree
##
## Флоу-самопроверка «Бесконечного подряда»/«Вызова дня» (mode line, BOOK §1–2): ведёт настоящий
## LegionMain через сигналы экранов — как реальные клики — тем же паттерном, что
## legion_flow_test.gd. Продюсирует находки свежего verifier (27.09.2026, пробы probe_leak.gd,
## probe2–5.gd в scratchpad/verify_mode): каждая проверка ниже падала на коде ДО правки.
## Campaign-уровневые проверки (детерминизм сида, изоляция поправок, рекорды) — отдельно в
## legion_procgen_mode_test.gd; здесь — именно ПРОВОДКА экранов реальным LegionMain.
## Сохранение — во временный файл, реальный user://legion.cfg владельца не трогает.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_endless_flow_test.gd -- --mute
##

const TEST_PATH := "user://legion_endless_flow_test_run.cfg"

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


func _fresh_main() -> void:
	if main != null:
		main.queue_free()
	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)
	main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}


func _menu() -> LegionMenu:
	return main.screen as LegionMenu


## Campaign.reset() стирает ВЕСЬ ConfigFile, включая intro_cutscene_seen/tutorial_done — без
## них show_briefing() на первой карте кампании уводит в катсцену вступления (main.screen на
## это время null, а не Briefing) вместо честного брифинга, которого ждут проверки ниже.
func _reset_progress() -> void:
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	_reset_progress()

	await _test_pause_menu_leak_does_not_infect_campaign()
	await _test_daily_and_normal_runs_dont_wipe_each_other()
	await _test_retry_after_victory_does_not_recount()
	await _test_bounty_earned_and_spendable_in_office()
	await _test_pending_reward_survives_fresh_session_world_null()
	await _test_owner_bug_campaign_pending_reward_world_null()
	await _test_daily_one_attempt_per_day()
	await _test_collection_save_from_pause_and_result_and_replay()

	print("LEGION ENDLESS FLOW: %d/%d OK" % [_checks - _fails, _checks])
	_cleanup()
	quit(1 if _fails > 0 else 0)


## verifier 27.09, probe_leak.gd: пауза → «Меню» ПОСРЕДИ боя забега (без исхода) — следующий бой
## КАМПАНИИ не должен уйти в endless-ветку матч-энда (не пишет некролог, реально засчитывает
## звёзды и открытие следующей карты).
func _test_pause_menu_leak_does_not_infect_campaign() -> void:
	await _fresh_main()
	_reset_progress()
	var maps := Campaign.maps()
	main.show_menu()
	await _frames(2)

	_menu().endless_pressed.emit()
	await _frames(2)
	_check(main._endless_daily == false, "нажата «Бесконечный подряд» — не daily")
	var mid := LegionEndless.object_map_id(
		LegionRunStore.endless_seed(false), LegionRunStore.endless_k(false), true)
	main.screen.start.emit(mid)
	await _frames(3)
	_check(main._in_endless_battle, "бой стартовал как забег (_in_endless_battle)")

	# пауза → «Меню» (Esc, «Меню») — БЕЗ исхода боя, минуя _on_match_ended.
	main.world.set_paused(true)
	await _frames(2)
	main._pause_screen.menu_pressed.emit()
	await _frames(2)
	_check(main.screen is LegionMenu, "пауза → «Меню» вернула в меню")
	_check(not main._in_endless_battle,
		"утечка (verifier п.1): _in_endless_battle сброшен после «Меню» посреди забега")
	_check(Campaign.is_endless_scope() == false, "scope вернулся к кампании")
	_check(LegionRunStore.endless_active(false), "сам забег НЕ прерван — просто вышли из боя паузой")

	# теперь бой КАМПАНИИ — не должен уйти в endless-ветку.
	var m0 := String(maps[0].get("id", ""))
	var stars_before := Campaign.stars(m0)
	(main.screen as LegionMenu).continue_pressed.emit(m0)
	await _frames(2)
	_check(main.screen is Briefing, "«Продолжить» после утечки — брифинг кампании (не некролог)")
	(main.screen as Briefing).start.emit(m0)
	await _frames(3)
	_check(not main._in_endless_battle, "бой кампании стартовал с _in_endless_battle == false")
	main.world.force_end(true)
	await _frames(3)
	_check(main.screen is LegionResult, "бой кампании закончился обычным итогом, не некрологом")
	_check(Campaign.stars(m0) > stars_before,
		"утечка (verifier п.1): победа кампании реально записала звёзды")
	var f := ConfigFile.new()
	f.load(TEST_PATH)
	_check(String(f.get_value("meta", "pending_reward", "")) != LegionEndless.PENDING_SENTINEL,
		"утечка (verifier п.1): [meta].pending_reward кампании — НЕ сентинел забега")

	# тот же путь утечки — «Как играть → Обучение» из паузы (start_battle("wasteland") напрямую,
	# минуя брифинг): не должен остаться endless-веткой, даже если позвать во время активного
	# флага (симулируем прямым вызовом start_battle, как это делает _show_howto()).
	main._in_endless_battle = true
	main.start_battle(m0)
	await _frames(2)
	_check(not main._in_endless_battle,
		"start_battle() всегда сбрасывает _in_endless_battle у себя (защита от прямого вызова)")


## verifier 27.09, probe2.gd (A): «Вызов дня» не должен стирать прогресс обычного забега (РАЗНЫЕ
## секции сохранения) и наоборот.
func _test_daily_and_normal_runs_dont_wipe_each_other() -> void:
	await _fresh_main()
	_reset_progress()
	main.show_menu()
	await _frames(2)

	_menu().endless_pressed.emit()
	await _frames(2)
	for i in 2:
		var mid := LegionEndless.object_map_id(LegionRunStore.endless_seed(false),
			LegionRunStore.endless_k(false), true)
		main.screen.start.emit(mid)
		await _frames(3)
		main.world.force_end(true)
		await _frames(3)
		(main.screen as LegionResult).next.emit()
		await _frames(2)
		if main.screen is UpgradePicker:
			var opts := Campaign.offer_upgrades(main.world.rng)
			main.pick_upgrade(opts[0])
			await _frames(2)
		main.screen.back.emit()   # «Дальше» из «Конторы»
		await _frames(2)
	_check(LegionRunStore.endless_k(false) == 3 and LegionRunStore.endless_tenure(false) == 2,
		"обычный забег: 2 победы -> k=3 стаж=2")

	main.show_menu()
	await _frames(2)
	_menu().daily_pressed.emit()
	await _frames(2)
	_check(LegionRunStore.endless_k(true) == 1,
		"«Вызов дня» начался со своего объекта 1 (не унаследовал k обычного забега)")
	_check(LegionRunStore.endless_k(false) == 3 and LegionRunStore.endless_tenure(false) == 2,
		"probe2 A (verifier п.2): «Вызов дня» НЕ стёр обычный забег (k=3 стаж=2 на месте)")

	main.show_menu()
	await _frames(2)
	_menu().endless_pressed.emit()
	await _frames(2)
	_check(LegionRunStore.endless_k(false) == 3 and LegionRunStore.endless_tenure(false) == 2,
		"повторное нажатие «Бесконечный подряд» продолжило тот же забег (k=3 стаж=2), не сбросило")


## verifier 27.09, probe5.gd: «Ещё раз» после ПОБЕДЫ засчитывала объект повторно (стаж рос
## 1→2→3 на одной и той же карте). Кнопки «Ещё раз» на экране победы объекта теперь нет.
func _test_retry_after_victory_does_not_recount() -> void:
	await _fresh_main()
	_reset_progress()
	main.show_menu()
	await _frames(2)
	_menu().endless_pressed.emit()
	await _frames(2)
	var mid := LegionEndless.object_map_id(
		LegionRunStore.endless_seed(false), LegionRunStore.endless_k(false), true)
	main.screen.start.emit(mid)
	await _frames(3)

	main.world.force_end(true)
	await _frames(3)
	_check(LegionRunStore.endless_tenure(false) == 1, "первая победа объекта -> стаж 1")
	# Кнопки «Ещё раз» на этом экране больше нет (show_retry=false), но сам сигнал в классе
	# остался — эмитируем его напрямую: LegionMain для забега его больше не слушает, счёт не
	# должен измениться.
	(main.screen as LegionResult).retry.emit()
	await _frames(3)
	_check(LegionRunStore.endless_tenure(false) == 1,
		"verifier п.3: emit(retry) после победы НЕ засчитал объект повторно (стаж всё ещё 1)")
	_check(main.screen is LegionResult,
		"экран не сменился от emit(retry) — «Дальше» остаётся единственным реальным действием")

	# «Дальше» по-прежнему исправно ведёт вперёд (не сломали основной путь).
	(main.screen as LegionResult).next.emit()
	await _frames(2)
	if main.screen is UpgradePicker:
		var opts := Campaign.offer_upgrades(main.world.rng)
		main.pick_upgrade(opts[0])
		await _frames(2)
	_check(main.screen is OfficeShop, "«Дальше» после победы объекта по-прежнему ведёт в «Контору»")


## verifier 27.09, probe3.gd: «Контора» в забеге была мертва — bounty() не рос. Премия должна
## начисляться за сданный объект и быть доступна к трате в «Конторе» ЗАБЕГА.
func _test_bounty_earned_and_spendable_in_office() -> void:
	await _fresh_main()
	_reset_progress()
	main.show_menu()
	await _frames(2)
	_menu().endless_pressed.emit()
	await _frames(2)
	_check(Campaign.bounty() == 0, "премия забега на старте — 0")
	var mid := LegionEndless.object_map_id(
		LegionRunStore.endless_seed(false), LegionRunStore.endless_k(false), true)
	main.screen.start.emit(mid)
	await _frames(3)
	main.world.force_end(true)
	await _frames(3)
	_check(Campaign.bounty() > 0,
		"verifier п.4: премия за сданный объект начислена (bounty=%d)" % Campaign.bounty())
	(main.screen as LegionResult).next.emit()
	await _frames(2)
	if main.screen is UpgradePicker:
		var opts := Campaign.offer_upgrades(main.world.rng)
		main.pick_upgrade(opts[0])
		await _frames(2)
	_check(main.screen is OfficeShop, "премия ведёт в «Контору» забега")
	var bounty_before := Campaign.bounty()
	var bought := Campaign.shop_buy("range", "laborer")
	_check(bought and Campaign.bounty() < bounty_before,
		"verifier п.4: в «Конторе» забега реально можно что-то купить на накопленную премию")


## verifier 27.09, probe4.gd: свежая сессия с уже стоящей ожидающей наградой ЗАБЕГА (world ==
## null) — раньше офер поправок падал (см. следующая проверка про баг мастера), убеждаемся, что
## endless-путь его тоже не наследует.
func _test_pending_reward_survives_fresh_session_world_null() -> void:
	Campaign.set_save_path(TEST_PATH)
	_reset_progress()
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(5)
	LegionRunStore.endless_object_won(10)
	Campaign.set_pending_reward(LegionEndless.PENDING_SENTINEL)
	Campaign.use_campaign_scope()

	await _fresh_main()
	_check(main.world == null, "свежая сессия — мир ещё не создан")
	main.show_menu()
	await _frames(2)
	_menu().endless_pressed.emit()
	await _frames(2)
	_check(main.world == null,
		"offer_upgrade_or_skip() с незабранной наградой забега не создаёт мир сам по себе")
	_check(main.screen is UpgradePicker or main.screen is OfficeShop,
		"verifier п.5 (мир null): дошли до выбора поправки/«Конторы», а не упали с ошибкой скрипта")


## verifier 27.09, probe3.gd (владельческая копия сохранения): реальный старый баг master —
## pending_reward карты КАМПАНИИ + свежий запуск (world == null) валил игру
## `Invalid access to property 'rng' on 'Nil'` в _offer_upgrade_or_skip(). Регресс на копии,
## похожей на настоящее сохранение владельца (bounty/pending_reward в [meta], без "endless_run").
func _test_owner_bug_campaign_pending_reward_world_null() -> void:
	Campaign.set_save_path(TEST_PATH)
	_reset_progress()
	Campaign.use_campaign_scope()
	var maps := Campaign.maps()
	var m0 := String(maps[0].get("id", ""))
	var m1 := String(maps[1].get("id", ""))
	Campaign.record_result(m0, true, 0.6)
	Campaign.set_pending_reward(m1)   # как «gatehouse» в реальном сохранении владельца

	await _fresh_main()
	_check(main.world == null, "свежая сессия — мир ещё не создан (owner bug воспроизводится так)")
	main.show_menu()
	await _frames(2)
	(main.screen as LegionMenu).continue_pressed.emit(m1)
	await _frames(2)
	_check(main.world == null, "«Продолжить» с pending_reward не создаёт мир сам по себе")
	_check(main.screen is UpgradePicker or main.screen is OfficeShop,
		"verifier п.5: ошибка доступа к 'rng' у Nil больше не валит игру — дошли до поправки/«Конторы»")


## D-0927-96: «Вызов дня» — ОДНА попытка в день. Проверяет: пауза без «Заново» и с подтверждением
## в бою «Вызова дня»; подтверждённый выход посреди объекта засчитывает конец попытки (некролог,
## причина «самовольный уход»); повторный старт в тот же день невозможен ни новой кнопкой, ни
## выходом+«Продолжить»; на следующий день — можно снова.
func _test_daily_one_attempt_per_day() -> void:
	await _fresh_main()
	_reset_progress()
	main.show_menu()
	await _frames(2)

	_menu().daily_pressed.emit()
	await _frames(2)
	var today := LegionEndless.today_date()
	_check(LegionRunStore.endless_daily_date() == today, "«Вызов дня» стартовал на сегодня")
	var mid := LegionEndless.object_map_id(
		LegionRunStore.endless_seed(true), LegionRunStore.endless_k(true), true)
	main.screen.start.emit(mid)
	await _frames(3)
	_check(main._pause_screen == null, "боя ещё не поставили на паузу")

	main.world.set_paused(true)
	await _frames(2)
	_check(main._pause_screen.hide_restart, "в бою «Вызова дня» нет «Заново» (D-0927-96)")
	_check(main._pause_screen.confirm_menu_text != "",
		"«Меню» в бою «Вызова дня» требует подтверждения")
	# первый клик «Меню» (без подтверждения ещё) не должен сразу уводить из боя.
	main._pause_screen._on_menu_pressed()
	await _frames(1)
	_check(main.world.phase == LegionWorld.Phase.BATTLE,
		"первый клик «Меню» только показал предупреждение, бой не прерван")
	_check(main._pause_screen._confirm_box != null, "предупреждение с подтверждением показано")
	# «Да, уйти» — тот же сигнал menu_pressed, эмитированный из подтверждения.
	main._pause_screen.menu_pressed.emit()
	await _frames(3)
	_check(main.screen is Necrolog,
		"подтверждённый выход посреди объекта «Вызова дня» показал некролог, не меню")
	_check(not LegionRunStore.endless_active(true), "попытка дня закрыта (забег больше не активен)")
	_check(LegionRunStore.daily_attempt_done(today), "сегодняшняя попытка отмечена сыгранной")
	(main.screen as Necrolog).menu.emit()
	await _frames(2)

	# повторный старт «Вызова дня» СЕГОДНЯ — невозможен ни новой кнопкой…
	_check(main.screen is LegionMenu, "после некролога — меню")
	var k_before := LegionRunStore.endless_k(true)
	_menu().daily_pressed.emit()
	await _frames(2)
	_check(LegionRunStore.endless_k(true) == k_before,
		"D-0927-96: повторное нажатие «Вызов дня» сегодня не начало новую попытку (k не изменился)")
	_check(main.screen is LegionMenu,
		"повторная попытка сегодня не открыла ни брифинг, ни бой — осталось меню")

	# …ни «выходом+продолжением»: пробуем «Продолжить» напрямую через _start_endless_flow(true).
	main._start_endless_flow(true)
	await _frames(2)
	_check(LegionRunStore.endless_k(true) == k_before,
		"прямой вызов _start_endless_flow(true) сегодня тоже не даёт вторую попытку")

	# Симулируем «на следующий день»: сегодняшняя дата не среди сданных (D-0927-122 — словарь
	# done_dates), вчерашняя — сдана; новая попытка должна получиться. Правим сохранение напрямую
	# (тот же приём, что verifier: ConfigFile мимо API).
	var f := ConfigFile.new()
	f.load(TEST_PATH)
	f.set_value("daily_run", LegionRunStore.DONE_KEY, {"2000-01-01": {"tenure": 0, "souls": 0}})
	f.save(TEST_PATH)
	Campaign.set_save_path(TEST_PATH)   # сбросить кэш ConfigFile — перечитать с диска
	_check(not LegionRunStore.daily_attempt_done(today),
		"после смены даты «на завтра» попытка не done")
	main._start_endless_flow(true)
	await _frames(2)
	_check(LegionRunStore.endless_k(true) == 1, "новый день — новая попытка «Вызова дня» (k == 1)")
	_check(LegionRunStore.endless_tenure(true) == 0, "новый день — стаж с нуля")


## D-0927-162: сохранение из паузы (главное место) и с итога объекта, переигровка из коллекции
## не трогает забег/кампанию/попытку дня, удаление.
func _test_collection_save_from_pause_and_result_and_replay() -> void:
	await _fresh_main()
	_reset_progress()
	main.show_menu()
	await _frames(2)
	_menu().endless_pressed.emit()
	await _frames(2)
	var mid := LegionEndless.object_map_id(LegionRunStore.endless_seed(false),
		LegionRunStore.endless_k(false), true)
	main.screen.start.emit(mid)
	await _frames(3)

	# сохранение из паузы — главное место (Игорь: «если проигрываешь или тебе надо бежать»).
	main.world.set_paused(true)
	await _frames(2)
	_check(main._pause_screen.show_collect,
		"в бою забега на сгенерированной (стаб) карте есть «В коллекцию»")
	main._pause_screen.collect_pressed.emit()
	await _frames(1)
	_check(LegionCollection.has(mid), "сохранение из паузы реально положило запись в коллекцию")
	_check(LegionCollection.entries().size() == 1, "ровно одна запись (не задвоилась)")
	main.world.set_paused(false)
	await _frames(1)

	# сохранение ещё раз с итога объекта — не дублирует запись, обновляет её.
	main.world.force_end(true)
	await _frames(3)
	_check(main.screen is LegionResult, "экран итога показан")
	(main.screen as LegionResult).collect_pressed.emit()
	await _frames(1)
	_check(LegionCollection.entries().size() == 1,
		"повторное сохранение с итога не задвоило запись (тот же map_id)")

	var k_before := LegionRunStore.endless_k(false)
	var tenure_before := LegionRunStore.endless_tenure(false)

	# «Дальше» → поправка/«Контора» → следующий объект — обычный флоу забега, коллекция не мешает.
	(main.screen as LegionResult).next.emit()
	await _frames(2)
	if main.screen is UpgradePicker:
		var opts := Campaign.offer_upgrades(main.world.rng)
		main.pick_upgrade(opts[0])
		await _frames(2)
	main.screen.back.emit()
	await _frames(2)
	_check(LegionRunStore.endless_k(false) == k_before,
		"брифинг следующего объекта — ещё не выигран, k не меняется (коллекция забег не трогала)")

	# «Играть» из коллекции — вне забега/дня: армия с нуля, поправки/«Контора» забега не
	# применяются, рекорды забега/дня не трогает.
	main.show_menu()
	await _frames(2)
	_check(main.screen is LegionMenu, "снова меню")
	(main.screen as LegionMenu).collection_pressed.emit()
	await _frames(2)
	_check(main.screen is LegionCollectionScreen, "меню → экран «Коллекция»")
	(main.screen as LegionCollectionScreen).play_requested.emit(mid)
	await _frames(3)
	_check(main._in_collection_battle, "переигровка идёт как collection-бой")
	_check(not main._in_endless_battle, "переигровка — НЕ endless-бой")
	_check(not Campaign.is_endless_scope(), "переигровка — НЕ endless/daily scope (своя песочница)")
	_check(main.world.map_id == mid, "переигровка стартовала ту же карту")
	_check(LegionRunStore.endless_k(false) == k_before,
		"переигровка не сдвинула сам забег (k тот же, что до неё)")
	_check(not LegionRunStore.daily_attempt_done(LegionEndless.today_date()),
		"переигровка не трогает «Вызов дня» (попытка дня не отмечена сыгранной)")

	main.world.force_end(true)
	await _frames(3)
	_check(main.screen is LegionResult, "итог переигровки — обычный win/lose экран")
	_check(LegionRunStore.endless_k(false) == k_before,
		"переигровка не сдвинула забег и ПОСЛЕ своего конца")
	var best: Dictionary = LegionCollection.entries()[0].get("best_result", {})
	_check(bool(best.get("victory", false)), "переигровка обновила лучший результат (победа)")

	(main.screen as LegionResult).retry.emit()
	await _frames(3)
	main.world.force_end(false)
	await _frames(3)
	var best2: Dictionary = LegionCollection.entries()[0].get("best_result", {})
	_check(bool(best2.get("victory", false)),
		"худшая переигровка (поражение) не портит уже сохранённый лучший результат (победа)")

	# удаление.
	LegionCollection.remove(mid)
	_check(not LegionCollection.has(mid), "«Убрать» реально удаляет запись из коллекции")


func _cleanup() -> void:
	Campaign.use_campaign_scope()
	var abs_path := ProjectSettings.globalize_path(TEST_PATH)
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(abs_path)
