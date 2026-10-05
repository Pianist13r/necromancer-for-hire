extends SceneTree
##
## Регресс D-0927-96 «Вызов дня — ОДНА попытка; рекорды по сложностям» на пути, которыми свежий
## verifier (27.09, пробы probe_a/probe_q1/probe_q2 в scratchpad/verify_mode3) обошёл реализацию
## 7a507b4. Водит настоящий LegionMain сигналами экранов, как клики:
##   1) пауза → «Как играть» → «Обучение» в бою дня уходил без подтверждения и без конца попытки;
##   2) закрытие окна / падение игры посреди боя дня — после перезапуска тот же объект заново;
##   3) смена даты туда-обратно — одна done_date затиралась, «сегодня» открывалось снова;
##   4) «Бесконечный подряд»: сложность меняли посреди забега, рекорд писался под последнюю.
## Плюс контроль, что выход МЕЖДУ объектами по-прежнему допустим (не засчитывается уходом), и
## B-113: пауза — над подсказкой карты и плашками боя (кадр координатора pause_collect.png).
## Сохранение — временный файл; Settings (сложность) — песочница APPDATA запуска.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_procgen_mode_guard_test.gd -- --mute
##

const TEST_PATH := "user://legion_procgen_mode_guard_test.cfg"

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


## Новый LegionMain — как новый запуск игры: Campaign.set_save_path сбрасывает кэш ConfigFile,
## так что всё читается заново с диска (то, что осталось бы после падения процесса).
func _fresh_main() -> void:
	if main != null:
		main.free()
	main = null
	Campaign.set_save_path(TEST_PATH)
	Campaign.use_campaign_scope()
	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)
	main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}


func _reset() -> void:
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()


func _obj(daily: bool) -> String:
	return LegionEndless.object_map_id(LegionRunStore.endless_seed(daily),
		LegionRunStore.endless_k(daily), true)


func _menu_daily_disabled() -> bool:
	for b in main.screen.find_children("*", "Button", true, false):
		var btn := b as Button
		if btn.text.contains("Вызов дня"):
			return btn.disabled
	return false


## В бой объекта 1 «Вызова дня» из меню, Котёл почти добит (проигрываемый объект).
func _enter_daily_battle() -> void:
	main.show_menu()
	await _frames(2)
	(main.screen as LegionMenu).daily_pressed.emit()
	await _frames(2)
	main.screen.start.emit(_obj(true))
	await _frames(3)
	main.world.damage_cauldron(main.world.cauldron_hp * 0.9, "lawyer")
	await _frames(2)


func _has_picker() -> bool:
	for c in main.screen.find_children("*", "", true, false):
		if c is DifficultyPicker:
			return true
	return false


func _saved(section: String, key: String, def: Variant) -> Variant:
	var f := ConfigFile.new()
	f.load(TEST_PATH)
	return f.get_value(section, key, def)


func _run() -> void:
	var diff_before := Settings.difficulty()
	await _test_tutorial_from_daily_pause()
	await _test_crash_mid_daily_battle()
	await _test_window_close_mid_daily_battle()
	await _test_between_objects_exit_allowed()
	await _test_date_back_and_forth()
	await _test_endless_difficulty_locked_per_run()
	await _test_pause_above_field_hints()
	Settings.set_difficulty(diff_before)
	print("LEGION PROCGEN MODE GUARD: %d/%d OK" % [_checks - _fails, _checks])
	if main != null:
		main.free()
	Campaign.use_campaign_scope()
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	quit(1 if _fails > 0 else 0)


## 1) пауза → «Как играть» → «Обучение» (probe_a, A1).
func _test_tutorial_from_daily_pause() -> void:
	await _fresh_main()
	_reset()
	await _enter_daily_battle()
	var today := LegionEndless.today_date()
	main.world.set_paused(true)
	await _frames(2)
	main._pause_screen.howto_pressed.emit()
	await _frames(2)
	var how: HowtoLegion = null
	for c in main.get_children():
		if c is HowtoLegion:
			how = c
	_check(how != null, "из паузы боя дня открылся «Как играть»")
	var has_tut := false
	for b in how.find_children("*", "Button", true, false):
		has_tut = has_tut or (b as Button).text == "Обучение"
	_check(not has_tut, "в бою дня кнопки «Обучение» в «Как играть» нет")
	# кнопку убрали, но сигнал всё равно подаём — страховка флоу должна засчитать уход.
	# 14ac08a6: посреди боя «Обучение» сперва спрашивает подтверждение (бой будет прерван) —
	# без него страховка не срабатывает, ровно как у выхода в меню (legion_endless_flow_test).
	how.tutorial_pressed.emit()
	await _frames(2)
	var confirm: ConfirmationDialog = null
	for c in how.get_children():
		if c is ConfirmationDialog:
			confirm = c
	_check(confirm != null, "«Обучение» посреди боя просит подтверждение")
	if confirm != null:
		confirm.confirmed.emit()
	await _frames(3)
	_check(main.screen is Necrolog, "«Обучение» из боя дня — некролог самовольного ухода, не обучение")
	_check(LegionRunStore.daily_attempt_done(today), "попытка дня засчитана оконченной")
	_check(not LegionRunStore.endless_active(true), "забег дня закрыт")
	_check(main.world.tutorial == null, "обучение поверх боя дня не стартовало")
	(main.screen as Necrolog).menu.emit()
	await _frames(2)
	_check(main.screen is LegionMenu and _menu_daily_disabled(), "в меню «Вызов дня» закрыт")
	(main.screen as LegionMenu).daily_pressed.emit()
	await _frames(2)
	_check(not (main.screen is EndlessBriefing), "тот же объект заново не открывается")


## 2) падение игры посреди боя дня (probe_q1 → probe_q2): процесс не успел ничего сделать.
func _test_crash_mid_daily_battle() -> void:
	await _fresh_main()
	_reset()
	await _enter_daily_battle()
	var today := LegionEndless.today_date()
	var obj := main.world.map_id
	_check(String(_saved("daily_run", LegionRunStore.OPEN_KEY, "")) == obj,
		"старт боя дня сразу записал в файл «бой дня открыт» (объект)")
	_check(int(_saved("daily_run", LegionRunStore.OPEN_AT_KEY, 0)) > 0, "и время открытия")
	# «падение»: узел уничтожен без выхода в меню и без уведомлений; перезапуск читает диск заново
	await _fresh_main()   # _ready() нового запуска сам входит в меню — там и ловится флаг
	_check(main.screen is Necrolog, "перезапуск после падения — некролог «самовольный уход»")
	_check(LegionRunStore.daily_attempt_done(today), "попытка дня засчитана оконченной")
	_check(LegionRunStore.daily_open_object() == "", "флаг открытого боя снят")
	var rec := LegionRunStore.daily_done_result(today)
	_check(not rec.is_empty() and int(rec.get("tenure", -1)) == 0,
		"стаж попытки — до этого объекта (0: объект 1 не сдан)")
	(main.screen as Necrolog).menu.emit()
	await _frames(2)
	_check(main.screen is LegionMenu and _menu_daily_disabled(), "в меню «Вызов дня» закрыт")
	(main.screen as LegionMenu).daily_pressed.emit()
	await _frames(2)
	_check(not (main.screen is EndlessBriefing), "тот же объект дня свежим не переигрывается")


## 2б) закрытие окна (NOTIFICATION_WM_CLOSE_REQUEST) — попытка закрыта ДО выхода.
func _test_window_close_mid_daily_battle() -> void:
	await _fresh_main()
	_reset()
	await _enter_daily_battle()
	var today := LegionEndless.today_date()
	main.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var done: Variant = _saved("daily_run", LegionRunStore.DONE_KEY, {})
	_check(done is Dictionary and (done as Dictionary).has(today),
		"закрытие окна посреди боя дня записало на диск сданную дату")
	_check(String(_saved("daily_run", LegionRunStore.OPEN_KEY, "x")) == "", "флаг открытого боя снят")


## Выход МЕЖДУ объектами (итог → «Меню») — можно, «Продолжить» ведёт к объекту 2.
func _test_between_objects_exit_allowed() -> void:
	await _fresh_main()
	_reset()
	await _enter_daily_battle()
	main.world.force_end(true)
	await _frames(3)
	_check(main.screen is LegionResult, "объект 1 сдан — итог")
	(main.screen as LegionResult).menu.emit()
	await _frames(2)
	_check(main.screen is LegionMenu, "с итога в меню — меню, не некролог")
	(main.screen as LegionMenu).daily_pressed.emit()
	await _frames(2)
	if main.screen is UpgradePicker:
		main.pick_upgrade(Campaign.offer_upgrades(main.world.rng)[0])
		await _frames(2)
	if main.screen is OfficeShop:
		main.screen.back.emit()
		await _frames(2)
	_check(main.screen is EndlessBriefing and LegionRunStore.endless_k(true) == 2,
		"«Продолжить» дня — брифинг объекта 2")
	_check(not LegionRunStore.daily_attempt_done(LegionEndless.today_date()),
		"выход между объектами попытку не закрыл")


## 3) смена даты туда-обратно (probe_a, A3): одна попытка на дату навсегда.
func _test_date_back_and_forth() -> void:
	await _fresh_main()
	_reset()
	await _enter_daily_battle()
	main.world.set_paused(true)
	await _frames(2)
	main._pause_screen.menu_pressed.emit()   # «Да, уйти» — конец попытки сегодня
	await _frames(3)
	var today := LegionEndless.today_date()
	_check(LegionRunStore.daily_attempt_done(today), "сегодняшняя попытка сдана")
	# «перевели часы вперёд»: попытка на другую дату, тем же входом, что флоу
	var other := "2099-01-01"
	Campaign.use_daily_scope()
	_check(LegionRunStore.daily_enter(other), "на другую дату попытка открывается")
	LegionRunStore.endless_end_run()
	Campaign.use_campaign_scope()
	_check(LegionRunStore.daily_attempt_done(today), "сдача другой даты не стёрла сегодняшнюю")
	main.show_menu()
	await _frames(2)
	_check(_menu_daily_disabled(), "вернули дату — «Вызов дня» сегодня всё ещё закрыт")
	var k_before := LegionRunStore.endless_k(true)
	main._start_endless_flow(true)
	await _frames(2)
	_check(not (main.screen is EndlessBriefing) and LegionRunStore.endless_k(true) == k_before,
		"флоу тоже не даёт вторую попытку сегодня")
	# незаконченный забег другой даты (вышли между объектами до полуночи) не затирается молча:
	# закрывается как сданный на свою дату, и туда уже не вернуться
	Campaign.use_daily_scope()
	var d1 := "2099-02-01"
	var d2 := "2099-02-02"
	LegionRunStore.daily_enter(d1)
	LegionRunStore.endless_object_won(10)
	_check(LegionRunStore.daily_enter(d2), "новая дата при незаконченном забеге старой — новая попытка")
	_check(LegionRunStore.daily_attempt_done(d1), "незаконченный забег старой даты засчитан сданным")
	_check(int(LegionRunStore.daily_done_result(d1).get("tenure", 0)) == 1, "со своим стажем (1)")
	LegionRunStore.endless_end_run()
	_check(not LegionRunStore.daily_enter(d1), "вернули старую дату — второй попытки нет")
	Campaign.use_campaign_scope()


## 4) «Бесконечный подряд»: сложность закреплена на забег (probe_a, A6).
func _test_endless_difficulty_locked_per_run() -> void:
	await _fresh_main()
	_reset()
	Settings.set_difficulty(LegionChallenge.INTERN)
	main.show_menu()
	await _frames(2)
	(main.screen as LegionMenu).endless_pressed.emit()
	await _frames(2)
	_check(_has_picker(),
		"брифинг объекта 1 — пикер сложности живой (сложность ещё не закреплена)")
	for i in 3:
		main._start_endless_battle(_obj(false))
		await _frames(3)
		_check(main.world.difficulty == LegionChallenge.INTERN, "объект %d идёт на Стажёре" % (i + 1))
		main.world.force_end(true)
		await _frames(3)
	Settings.set_difficulty(LegionChallenge.HELL)   # посреди забега переключили на «Ад»
	main.show_endless_briefing()
	await _frames(2)
	_check(main.screen is EndlessBriefing
		and not _has_picker(),
		"брифинг объекта 4 — пикера нет, сложность закреплена на забег")
	main._start_endless_battle(_obj(false))
	await _frames(3)
	_check(main.world.difficulty == LegionChallenge.INTERN,
		"смена Settings посреди забега не меняет сложность объекта (Стажёр)")
	main.world.damage_cauldron(1.0, "lawyer")
	main.world.force_end(false)
	await _frames(3)
	_check(LegionRunStore.endless_best_tenure("", LegionChallenge.INTERN) == 3,
		"рекорд стажа 3 записан под Стажёра — сложность забега")
	_check(LegionRunStore.endless_best_tenure("", LegionChallenge.HELL) == 0,
		"на «Аду» рекорда нет — стажёрский забег его не набил")
	# новый забег — снова живой выбор сложности
	(main.screen as Necrolog).restart.emit()
	await _frames(2)
	_check(main.screen is EndlessBriefing
		and _has_picker(),
		"новый забег — пикер сложности снова живой")


func _visible_battle_layers() -> int:
	var n := 0
	for c in main.world.find_children("*", "CanvasLayer", true, false):
		if (c as CanvasLayer).visible:
			n += 1
	return n


## B-113 (кадр координатора pause_collect.png): плашка подсказки карты (тост HUD, слой 5) и нижние
## панели (слой 6) ложились ПОВЕРХ паузы (Control на слое 0) — закрывали «Пауза»/«Продолжить».
func _test_pause_above_field_hints() -> void:
	await _fresh_main()
	_reset()
	main.start_battle(LegionTutorial.WASTELAND_MAP_ID)
	await _frames(3)
	var before := _visible_battle_layers()
	_check(main.world.hud.visible and main.world.hud._toasts.get_child_count() > 0,
		"в бою видны HUD и плашка подсказки карты")
	main.world.set_paused(true)
	await _frames(2)
	_check(main._pause_screen != null and _visible_battle_layers() == 0,
		"пауза: ни HUD, ни подсказка карты, ни плашки уроков не рисуются поверх неё")
	main.world.set_paused(false)
	await _frames(2)
	_check(_visible_battle_layers() == before, "снятие паузы вернуло ровно то, что было видно")
	main.world.set_paused(true)
	await _frames(2)
	main._pause_screen.menu_pressed.emit()
	await _frames(3)
	_check(main.screen is LegionMenu and not main.world.hud.visible,
		"пауза → «Меню»: HUD не вернулся поверх меню")
