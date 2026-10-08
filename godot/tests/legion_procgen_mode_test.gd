extends SceneTree
##
## Самопроверка режима «Бесконечный подряд»/«Вызов дня» (mode line, BOOK docs/procgen/BOOK.md
## §1–2, docs/procgen/STAGE2.md): доступность по прогрессу кампании, детерминизм сида дня,
## цепочка объектов с накоплением поправок ЗАБЕГА без вреда реальному прогрессу кампании,
## причина некролога по виду врага, запись рекордов. Пишет во временный файл сохранения —
## реальный user://legion.cfg владельца не трогает (Campaign.set_save_path).
##
##   "$GODOT" --headless --path godot --script res://tests/legion_procgen_mode_test.gd -- --mute
##

const TEST_PATH := "user://legion_procgen_mode_test_run.cfg"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run()
	print("Procgen mode test: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	Campaign.use_campaign_scope()

	_check_availability()
	_check_daily_seed()
	_check_generator_version()
	_check_object_map_id()
	_check_chain_and_isolation()
	_check_daily_storage_isolation()
	_check_necrolog_reason()
	_check_records()
	_check_difficulty_locking()
	_check_difficulty_records()

	_cleanup()


## 1. Доступность — только после кампании (BOOK §1, §13 вопрос 1).
func _check_availability() -> void:
	Campaign.reset()
	_check(not LegionRunStore.campaign_completed(), "свежий прогресс — кампания не пройдена")
	var all := Campaign.maps()
	_check(all.size() >= 6, "не меньше 6 карт (%d)" % all.size())
	for i in all.size() - 1:
		Campaign.record_result(String(all[i].get("id", "")), true, 0.9)
	_check(not LegionRunStore.campaign_completed(),
		"пройдены все, кроме последней — ещё не «пройдена»")
	Campaign.record_result(String(all[all.size() - 1].get("id", "")), true, 0.5)
	_check(LegionRunStore.campaign_completed(), "последняя карта выиграна — кампания пройдена")


## 2. Сид «Вызова дня»: одинаковый для одной даты, разный для разных дат.
func _check_daily_seed() -> void:
	var s1 := LegionEndless.daily_seed("2026-09-27")
	var s2 := LegionEndless.daily_seed("2026-09-27")
	var s3 := LegionEndless.daily_seed("2026-09-28")
	_check(s1 == s2, "daily_seed одинаков для одной и той же даты")
	_check(s1 != s3, "daily_seed различается для разных дат")
	_check(LegionEndless.daily_seed("2026-10-08") == 4280396687,
		"эталон сида 08.10 для генератора 2")


func _check_generator_version() -> void:
	Campaign.reset()
	for daily in [false, true]:
		if daily:
			Campaign.use_daily_scope()
		else:
			Campaign.use_endless_scope()
		LegionRunStore.endless_start(7, "2026-10-08" if daily else "")
		Campaign.set_save_path(TEST_PATH)  # перечитать с диска, а не из кэша
		_check(LegionRunStore.procgen_version(daily) == 2, "версия забега пережила загрузку")
		var fixture := {"id": "gen:7:1", "hint": "Подсказка."}
		_check(LegionRunStore.annotate_generated(fixture.duplicate()).hint == "Подсказка.",
			"совпавшая версия не создаёт предупреждения")
		var sec := Campaign._run_section_for(daily)
		Campaign.raw_file().erase_section_key(sec, "procgen")
		Campaign.save_raw()
		Campaign.set_save_path(TEST_PATH)
		_check(LegionRunStore.procgen_version(daily) == 1, "старое сохранение читается как v1")
		_check("Карта собрана новой версией генератора" in
			LegionRunStore.annotate_generated(fixture.duplicate()).hint, "видимое предупреждение v1")
		_check(LegionRunStore.endless_seed(daily) == 7 and LegionRunStore.endless_k(daily) == 1,
			"предупреждение не сбрасывает прогресс")
		_check(LegionRunStore.procgen_version(daily) == 1, "старую версию не затираем")
		_check(LegionRunStore.annotate_generated({"id": "gen:8:1", "hint": "x"}).hint == "x",
			"предупреждение не попадает в чужую карту")
	Campaign.use_replay_scope()
	_check(LegionRunStore.annotate_generated({"id": "gen:7:1", "hint": "x"}).hint == "x",
		"предупреждение не попадает в коллекцию")
	Campaign.use_daily_scope()
	# Дневная попытка v1 продолжается: вход в тот же день v2 закрывает именно старую.
	LegionRunStore.endless_object_won(25)
	_check(LegionRunStore.daily_enter("2026-10-08"), "версия 2 открывает собственную попытку дня")
	var done: Dictionary = Campaign.raw_file().get_value(Campaign.DAILY_SECTION, "done_dates", {})
	_check(done.has("2026-10-08|v1") and not done.has("2026-10-08|v2"),
		"незавершённый старый день записан под старой версией")
	_check(LegionRunStore.endless_seed(true) == 4280396687, "новая попытка получила эталонный сид")
	_check(not LegionRunStore.daily_attempt_done("2026-10-08"), "v1 не закрыла v2")
	LegionRunStore.endless_object_won(50)
	LegionRunStore.endless_end_run()
	Campaign.set_save_path(TEST_PATH)
	_check(LegionRunStore.daily_attempt_done("2026-10-08"), "v2 закрыта после перезагрузки")
	_check(not LegionRunStore.daily_enter("2026-10-08"), "повтор v2 в тот же день запрещён")
	_check(LegionRunStore.daily_done_result("2026-10-08").souls == 50, "итог относится к v2")
	_check(LegionRunStore.endless_best_souls("2026-10-08") == 50, "рекорд относится к v2")
	_check(LegionRunStore._record_key(true, "2026-10-08", "normal", 1)
		!= LegionRunStore._record_key(true, "2026-10-08", "normal", 2), "ключи рекордов разделены")
	Campaign.reset()
	Campaign.use_campaign_scope()


## id объекта: --dev endless_stub=1 цикл по кампанийным картам; иначе "gen:<сид>:<k>".
func _check_object_map_id() -> void:
	var camp := Campaign.maps()
	var first := LegionEndless.object_map_id(7, 1, true)
	var wrapped := LegionEndless.object_map_id(7, camp.size() + 1, true)
	_check(first == String(camp[0].get("id", "")), "стаб: объект 1 — первая карта кампании")
	_check(wrapped == first, "стаб: объект (N+1) карт — снова первая (цикл по кругу)")
	_check(LegionEndless.object_map_id(7, 3, false) == "gen:7:3",
		"без стаба — формат id генератора gen:<сид>:<k>")


## 3. Цепочка k → k+1 с накоплением поправок ЗАБЕГА и без вреда прогрессу/поправкам кампании.
func _check_chain_and_isolation() -> void:
	Campaign.reset()
	# реальный прогресс и поправка кампании — до входа в забег
	var camp_maps := Campaign.maps()
	Campaign.record_result(String(camp_maps[0].get("id", "")), true, 0.95)
	var camp_upgrade := AmendmentDb.ORDER[0]
	Campaign.add_upgrade(StringName(camp_upgrade))
	var camp_stars_before := Campaign.stars(String(camp_maps[0].get("id", "")))
	var camp_mods_before := Campaign.active_mods()

	Campaign.use_endless_scope()
	LegionRunStore.endless_start(42)
	_check(LegionRunStore.endless_active(), "endless_start запускает забег (k ≥ 1)")
	_check(LegionRunStore.endless_k() == 1, "новый забег начинается с объекта 1")
	_check(LegionRunStore.endless_tenure() == 0, "стаж забега — 0 на старте")
	_check(Campaign.upgrades().is_empty(), "поправок забега на старте нет (отдельно от кампании)")

	var endless_upgrade := AmendmentDb.ORDER[1]
	Campaign.add_upgrade(StringName(endless_upgrade))
	_check(Campaign.upgrades().has(StringName(endless_upgrade)),
		"поправка забега сохранилась в endless-scope")

	LegionRunStore.endless_object_won(120)
	_check(LegionRunStore.endless_k() == 2, "объект 1 сдан — следующий k == 2")
	_check(LegionRunStore.endless_tenure() == 1, "стаж вырос на 1")
	_check(LegionRunStore.endless_souls() == 120, "души забега накопились")
	# поправка забега остаётся взятой на следующем объекте (копится ВНУТРИ забега)
	_check(Campaign.upgrades().has(StringName(endless_upgrade)),
		"поправка забега пережила переход к объекту 2 (копится в заходе)")

	LegionRunStore.endless_object_won(80)
	_check(LegionRunStore.endless_k() == 3, "объект 2 сдан — k == 3")
	_check(LegionRunStore.endless_souls() == 200, "души забега суммируются по объектам (120+80)")

	Campaign.use_campaign_scope()
	_check(Campaign.stars(String(camp_maps[0].get("id", ""))) == camp_stars_before,
		"звёзды кампании не изменились после забега")
	_check(Campaign.upgrades().has(StringName(camp_upgrade)),
		"поправка кампании осталась на месте")
	_check(not Campaign.upgrades().has(StringName(endless_upgrade)),
		"поправка забега НЕ просочилась в реальные поправки кампании")
	var camp_mods_after := Campaign.active_mods()
	_check(camp_mods_after.hash() == camp_mods_before.hash(),
		"active_mods() кампании не изменился забегом")


## Обычный забег и «Вызов дня» хранятся в РАЗНЫХ секциях (verifier 27.09, п.2: раньше делили
## одну — старт одного молча стирал прогресс другого).
func _check_daily_storage_isolation() -> void:
	Campaign.reset()
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(11)
	LegionRunStore.endless_object_won(30)
	LegionRunStore.endless_object_won(30)
	_check(LegionRunStore.endless_k(false) == 3, "обычный забег: k == 3 после двух побед")
	_check(LegionRunStore.endless_tenure(false) == 2, "обычный забег: стаж == 2")

	Campaign.use_daily_scope()
	LegionRunStore.endless_start(LegionEndless.daily_seed("2026-09-27"), "2026-09-27")
	_check(LegionRunStore.endless_k(true) == 1, "«Вызов дня»: свой отдельный объект 1")
	_check(LegionRunStore.endless_tenure(true) == 0, "«Вызов дня»: свой отдельный стаж 0")
	_check(LegionRunStore.endless_k(false) == 3,
		"старт «Вызова дня» НЕ стёр обычный забег (k всё ещё 3)")
	_check(LegionRunStore.endless_tenure(false) == 2,
		"старт «Вызова дня» НЕ стёр стаж обычного забега (всё ещё 2)")

	LegionRunStore.endless_object_won(50)
	_check(LegionRunStore.endless_k(true) == 2, "«Вызов дня» продвинулся сам по себе (k == 2)")
	_check(LegionRunStore.endless_k(false) == 3, "обычный забег по-прежнему не тронут (k == 3)")

	Campaign.use_endless_scope()
	_check(LegionRunStore.endless_k(false) == 3,
		"возврат к обычному забегу — прежнее состояние на месте")


## 4. Некролог — причина по виду врага (BOOK §1), рекорды считаются и сбрасывают активный забег.
func _check_necrolog_reason() -> void:
	_check(LegionEndless.death_reason("signer") == "нотариальное заверение",
		"причина «signer» — нотариальное заверение")
	_check(LegionEndless.death_reason("boss") != "", "у Прораба есть своя причина")
	_check(LegionEndless.death_reason("unknown_type_xyz") == LegionEndless.DEFAULT_DEATH_REASON,
		"неизвестный вид — общая фраза, не пусто")

	Campaign.use_endless_scope()
	LegionRunStore.endless_start(9)
	LegionRunStore.endless_object_won(50)
	LegionRunStore.endless_object_won(50)
	var report := LegionRunStore.endless_end_run()
	_check(int(report.get("tenure", -1)) == 2, "некролог: стаж = 2 сданных объекта")
	_check(int(report.get("souls", -1)) == 100, "некролог: души = 100")
	_check(not LegionRunStore.endless_active(), "endless_end_run() закрывает забег (k → 0)")


## 5. Рекорды — по стажу и душам, отдельно для обычного забега и «Вызова дня» на разные даты.
## Свой reset() (предыдущая проверка уже оставила запись рекорда обычного забега) — рекорды
## живут в отдельной секции, но не сбрасываются endless_start()/endless_end_run() нарочно
## (иначе смысла в них не было бы), поэтому изоляция теста — единственный способ проверить
## «первый забег — новый рекорд» на чистом месте.
func _check_records() -> void:
	Campaign.reset()
	Campaign.use_endless_scope()

	LegionRunStore.endless_start(1)
	LegionRunStore.endless_object_won(10)
	var r1 := LegionRunStore.endless_end_run()
	_check(bool(r1.get("is_new_tenure_record", false)), "первый забег — новый рекорд стажа")
	_check(LegionRunStore.endless_best_tenure() == 1, "рекорд стажа обычного забега — 1")

	LegionRunStore.endless_start(2)
	LegionRunStore.endless_object_won(5)
	var r2 := LegionRunStore.endless_end_run()
	_check(not bool(r2.get("is_new_tenure_record", false)),
		"худший повтор (тот же стаж) не считается новым рекордом")
	_check(LegionRunStore.endless_best_souls() == 10,
		"рекорд душ не портится худшим повтором (10 > 5)")

	# «Вызов дня» — свой рекорд, отдельно от обычного забега и от другой даты (СВОЯ секция —
	# use_daily_scope(), verifier 27.09 п.2).
	Campaign.use_daily_scope()
	LegionRunStore.endless_start(LegionEndless.daily_seed("2026-09-27"), "2026-09-27")
	LegionRunStore.endless_object_won(999)
	LegionRunStore.endless_object_won(999)
	LegionRunStore.endless_object_won(999)
	var rd := LegionRunStore.endless_end_run()
	_check(int(rd.get("tenure", 0)) == 3, "«Вызов дня» считает стаж как обычный забег")
	_check(LegionRunStore.endless_best_tenure("2026-09-27") == 3,
		"рекорд «Вызова дня» на дату 2026-09-27 — свой")
	_check(LegionRunStore.endless_best_tenure() == 1,
		"рекорд обычного забега не задет «Вызовом дня» (по-прежнему 1)")
	_check(LegionRunStore.endless_best_tenure("2026-09-28") == 0,
		"«Вызов дня» другой даты рекорда не имеет")


## 6. D-0927-96: сложность «Вызова дня» выбирается ДО старта и фиксируется на всю попытку —
## пикер живой, пока daily_difficulty() == "", закрепляется lock_daily_difficulty() один раз.
func _check_difficulty_locking() -> void:
	Campaign.reset()
	Campaign.use_daily_scope()
	LegionRunStore.endless_start(1, "2026-09-27")
	_check(not LegionRunStore.is_daily_difficulty_locked(),
		"свежий «Вызов дня» — сложность не закреплена")
	_check(LegionRunStore.daily_difficulty() == "", "daily_difficulty() пуст до первого боя")

	LegionRunStore.lock_daily_difficulty(LegionChallenge.HELL)
	_check(LegionRunStore.is_daily_difficulty_locked(),
		"первый вызов lock_daily_difficulty() закрепил")
	_check(LegionRunStore.daily_difficulty() == LegionChallenge.HELL, "закреплённая сложность — Ад")

	LegionRunStore.lock_daily_difficulty(LegionChallenge.INTERN)
	_check(LegionRunStore.daily_difficulty() == LegionChallenge.HELL,
		"повторный вызов lock_daily_difficulty() — no-op (сложность попытки не меняется)")

	LegionRunStore.endless_start(2, "2026-09-28")
	_check(LegionRunStore.daily_difficulty() == "", "новый забег дня сбрасывает закрепление")


## 7. D-0927-96: рекорды раздельны по сложности — верифайер нашёл, что рекорд набивался на
## «Стажёре» и выдавался за общий. Обычный забег: рекорд считается по Settings.difficulty() на
## момент конца; «Вызов дня»: по закреплённой сложности попытки.
func _check_difficulty_records() -> void:
	Campaign.reset()
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(1)
	LegionRunStore.endless_object_won(10)
	LegionRunStore.endless_object_won(10)
	Settings.set_difficulty(LegionChallenge.INTERN)
	var r_intern := LegionRunStore.endless_end_run()
	_check(String(r_intern.get("difficulty", "")) == LegionChallenge.INTERN,
		"конец забега на Стажёре — difficulty в отчёте это отражает")
	_check(LegionRunStore.endless_best_tenure("", LegionChallenge.INTERN) == 2,
		"рекорд обычного забега на Стажёре — 2")
	_check(LegionRunStore.endless_best_tenure("", LegionChallenge.NORMAL) == 0,
		"рекорд на Штатном НЕ выдан за рекорд Стажёра (всё ещё 0)")

	LegionRunStore.endless_start(2)
	LegionRunStore.endless_object_won(5)
	Settings.set_difficulty(LegionChallenge.NORMAL)
	LegionRunStore.endless_end_run()
	_check(LegionRunStore.endless_best_tenure("", LegionChallenge.NORMAL) == 1,
		"рекорд на Штатном — свой (1), не унаследован со Стажёра")
	_check(LegionRunStore.endless_best_tenure("", LegionChallenge.INTERN) == 2,
		"рекорд на Стажёре не испорчен последующей игрой на Штатном")

	# «Вызов дня»: рекорд по закреплённой сложности попытки, не по Settings в момент конца.
	Campaign.use_daily_scope()
	LegionRunStore.endless_start(3, "2026-09-27")
	LegionRunStore.lock_daily_difficulty(LegionChallenge.HELL)
	LegionRunStore.endless_object_won(1)
	Settings.set_difficulty(LegionChallenge.INTERN)   # сменил бы рекорд, если бы читали Settings
	var rd_hell := LegionRunStore.endless_end_run()
	_check(String(rd_hell.get("difficulty", "")) == LegionChallenge.HELL,
		"«Вызов дня»: рекорд по ЗАКРЕПЛЁННОЙ сложности (Ад), не по Settings на момент конца")
	_check(LegionRunStore.endless_best_tenure("2026-09-27", LegionChallenge.HELL) == 1,
		"рекорд «Вызова дня» 2026-09-27 на Аду — 1")
	_check(LegionRunStore.endless_best_tenure("2026-09-27", LegionChallenge.INTERN) == 0,
		"тот же день на Стажёре рекорда не имеет (были на Аду)")
	Settings.difficulty_override = ""   # не тащить override в другие функции этого прогона


func _cleanup() -> void:
	Campaign.use_campaign_scope()
	var abs_path := ProjectSettings.globalize_path(TEST_PATH)
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(abs_path)
