extends SceneTree
##
## Самопроверка меты (без окна): премия и опыт за бой, услуги подготовки «Конторы» и потолки
## (одна подготовка на объект, два жетона переброса), Campaign.stat() складывает поправки-карточки
## и умножает по правилу имени ключа, сборка ограничена тремя карточками, уровень героя открывает
## карточки, а его собственные ранги/перки в бой не идут, открытия по порядку карт, старое
## сохранение (без секций [meta]/[hero]) читается значениями по умолчанию. Пишет во временный
## файл — реальный user://legion.cfg владельца не трогает (Campaign.set_save_path).
##
## OVERHAUL 05.10: старый пул постоянных процентов (уровни покупок «Конторы», ранги и перки
## героя) заменён колодой AmendmentDb — проверки этого файла переехали на новые покупки и
## карточки, старые проценты в игру не возвращаются.
##
##   "$GODOT" --headless --path godot --script res://tests/legion_meta_test.gd -- --mute
##

const TEST_PATH := "user://legion_meta_test_run.cfg"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run()
	print("Meta test: %d/%d OK" % [_checks - _fails, _checks])
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

	_test_bounty_and_xp()
	_test_preparation()
	_test_stat_sum_and_mult()
	_test_slots()
	_test_legacy_keys_dead()
	_test_hero_profile()
	_test_hero_reset()
	_test_unlocks()
	_test_old_save_without_sections()

	_cleanup()


func _test_bounty_and_xp() -> void:
	_check(Campaign.bounty() == 0, "премия 0 на свежем прогрессе")
	_check(Campaign.hero_level() == 1, "герой начинает с уровня 1")

	# Победа, 3 звезды, 12 убийств: премия 30+15*3=75, опыт 12+50+20*3=122.
	var r1 := Campaign.record_rewards(true, 3, 12)
	_check(int(r1["bounty"]) == 75, "победа 3★: премия 75 (получили %d)" % int(r1["bounty"]))
	_check(int(r1["xp"]) == 122, "победа 3★, 12 убийств: опыт 122 (получили %d)" % int(r1["xp"]))
	_check(Campaign.bounty() == 75, "премия сохранилась")

	# Поражение, 23 убийства: премия 10 + 23/10 (целочисленно) = 12, опыт = 23 (без бонуса победы).
	var r2 := Campaign.record_rewards(false, 0, 23)
	_check(int(r2["bounty"]) == 12, "поражение 23 убийства: премия 12 (получили %d)" % int(r2["bounty"]))
	_check(int(r2["xp"]) == 23, "поражение: опыт = убийствам (получили %d)" % int(r2["xp"]))
	_check(Campaign.bounty() == 87, "премия накопилась (75+12=87, получили %d)" % Campaign.bounty())


## «Контора» стала короткой подготовкой следующего боя (OVERHAUL 05.10): уровней покупок
## («Дальность» ×3 и т.п.) больше нет — есть разовые услуги AmendmentDb.PREPARATIONS
## (souls/mana, 35 премии) и жетоны переброса чертежа (30, не больше двух). Прежние проверки
## уровней и потолка 3 заменены на цены, списание и потолки новых услуг — сами гарантии те же.
func _test_preparation() -> void:
	Campaign.set_save_path(TEST_PATH)   # свежий кэш, но прогресс тот же файл
	Campaign.reset()
	_check(RunProgression.preparation() == "", "подготовка на свежем прогрессе не выбрана")
	_check(Campaign.stat(&"start_souls") == 0.0, "start_souls нейтрален без подготовки")

	# Провал покупки без хватающей премии не списывает премию и не выдаёт услугу.
	_check(not RunProgression.buy_service("souls"), "покупка без хватающей премии отклонена")
	_check(Campaign.bounty() == 0 and RunProgression.preparation() == "",
		"премия не списалась при провале покупки")

	var cost := int(AmendmentDb.PREPARATIONS["souls"]["cost"])
	Campaign.add_bounty(cost + 65)
	var before := Campaign.bounty()
	_check(RunProgression.buy_service("souls"), "услуга подготовки куплена")
	_check(Campaign.bounty() == before - cost, "премия списана на цену услуги (%d)" % cost)
	_check(not Campaign.active_mods().has("start_souls"),
		"подготовка не попадает в постоянную сборку — она на один объект")
	_check(is_equal_approx(float(RunProgression.preparation_mods().get("start_souls", 0.0)), 45.0),
		"подготовка несёт +45 душ на следующий объект")
	_check(not RunProgression.buy_service("mana"), "вторая подготовка поверх первой не берётся")
	_check(RunProgression.consume_preparation(), "подготовка потреблена стартом боя")
	_check(RunProgression.preparation() == "" and RunProgression.preparation_mods().is_empty(),
		"после старта боя подготовка пуста")

	# Потолок перебросов: два жетона за премию, третий не берётся.
	var banked := 0
	while RunProgression.buy_service("reroll"):
		banked += 1
	_check(banked == 2 and RunProgression.reroll_tokens() == 2, "перебросов в банке: %d" % banked)
	_check(not RunProgression.buy_service("reroll"), "третий переброс не берётся")


## Campaign.stat() — один котёл меты: поправки-карточки складываются по ключу, а ключ-множитель
## (по имени `_mult`/`_mult_`) отдаётся как 1 + сумма. Покупок «Конторы» и перков героя в этом
## котле больше нет (OVERHAUL 05.10) — их заменили карточки.
func _test_stat_sum_and_mult() -> void:
	Campaign.reset()
	_check(is_equal_approx(Campaign.stat(&"cap_mult_laborer"), 1.0),
		"cap_mult_laborer нейтрален (1.0) на свежем прогрессе")
	_check(Campaign.stat(&"recruit_r_laborer") == 0.0, "recruit_r_laborer нейтрален без карточек")

	Campaign.add_upgrade(&"bulk_ink")   # mana_cost_mult −0.35, recruit_r_* −60
	_check(is_equal_approx(Campaign.stat(&"mana_cost_mult"), 0.65),
		"mana_cost_mult = 1 + (−0.35) — множитель по правилу имени")
	_check(is_equal_approx(Campaign.stat(&"recruit_r_laborer"), -60.0),
		"recruit_r_laborer = −60 — прибавка отдаётся как есть")

	Campaign.add_upgrade(&"living_queue")     # cap_mult_* −0.2
	Campaign.add_upgrade(&"overtime_cycle")   # mana_max_bonus −25
	_check(Campaign.upgrades().size() == AmendmentDb.MAX_ACTIVE,
		"активная сборка — %d карточки" % AmendmentDb.MAX_ACTIVE)
	Campaign.add_upgrade(&"high_voltage")
	_check(not Campaign.upgrades().has(&"high_voltage"),
		"четвёртая карточка в сборку не влезает — только заменой")
	_check(is_equal_approx(Campaign.stat(&"cap_mult_laborer"), 0.8),
		"cap_mult_laborer = 0.8 рядом с чужими ключами сборки")
	_check(is_equal_approx(Campaign.stat(&"mana_max_bonus"), -25.0),
		"mana_max_bonus = −25 у «Ненормированного дня»")


## Правило «поправки-правила требуют замены» проверяет progression-тест; здесь — что карточка
## со слотом действительно попадает в свою сборку, а не в чужую.
func _test_slots() -> void:
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"ghost_clause")
	_check(Campaign.upgrades().size() == 1 and Campaign.upgrades().has(&"ghost_clause"),
		"взятая карточка — та, что просили")
	_check(Campaign.active_rules().has("ghost") and not Campaign.active_rules().has("queue"),
		"боевое правило активной карточки поднялось, чужое — нет")
	Campaign.add_upgrade(&"ghost_clause")
	_check(Campaign.upgrades().size() == 1, "повторный add_upgrade не задваивает карточку")


## Согласование v15 держало перевод production_mult/army_cap_bonus/start_army_bonus в
## respawn_mult_/cap_mult_laborer: мир их напрямую не читал. Тех ключей теперь не пишет никто —
## старый пул постоянных процентов заменён колодой AmendmentDb (OVERHAUL 05.10), а старые id из
## сохранения миграция переводит в карточки. Проверяем, что мёртвые ключи в бой не вернулись,
## а старый id работает через свою карточку.
func _test_legacy_keys_dead() -> void:
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"night_shift_hr")    # старый id: production_mult +0.2
	Campaign.add_upgrade(&"outstaff_partner")  # старый id: army_cap_bonus +20
	var mods := Campaign.active_mods()
	var legacy_alive := false
	for key: String in ["production_mult", "army_cap_bonus", "start_army_bonus"]:
		legacy_alive = legacy_alive or mods.has(key)
	_check(not legacy_alive, "мёртвые ключи старой меты в бой не идут: %s" % str(mods.keys()))
	_check(Campaign.upgrades().has(&"lean_staff") and Campaign.upgrades().has(&"living_queue"),
		"старые id переведены в карточки: %s" % str(Campaign.upgrades()))


## OVERHAUL 05.10: постоянный опыт героя открывает ВАРИАНТЫ карточек, а не покупает проценты.
## Ранги и перки остались в профиле (экран героя, коллекция), но бой их не читает — это и
## проверяем (регресс-охрана от возврата покупок в бой через Campaign._hero_mods).
func _test_hero_profile() -> void:
	Campaign.reset()
	_check(Campaign.hero_level() == 1 and not RunProgression.available(&"moving_office"),
		"«Выездная канцелярия» ждёт уровня героя (сейчас %d)" % Campaign.hero_level())
	Campaign.record_rewards(true, 3, 1000)   # опыт с большим запасом — герой высокого уровня
	_check(Campaign.hero_points_available() > 0, "после большого опыта есть свободные очки героя")
	_check(RunProgression.available(&"moving_office"), "уровень героя открыл карточку")

	_check(Campaign.hero_rank(&"q") == 0, "ранг Ку — 0 до покупки")
	_check(Campaign.hero_rank_up(&"q"), "ранг Ку куплен")
	_check(Campaign.hero_rank(&"q") == 1, "ранг Ку стал 1")
	_check(is_equal_approx(Campaign.stat(&"ability_rank_q"), 0.0),
		"ранг героя в бой не идёт: ability_rank_q в stat() нейтрален")
	Campaign.hero_rank_up(&"q")
	_check(Campaign.hero_rank(&"q") == 2, "ранг Ку дошёл до потолка (2)")
	_check(not Campaign.hero_rank_up(&"q"), "третий ранг Ку не покупается — потолок 2")

	# Перк второго ряда ветки без первого не берётся.
	_check(not Campaign.hero_take_perk(&"perk_big_staff"),
		"«Раздутый штат» не берётся без «Быстрого найма»")
	_check(Campaign.hero_take_perk(&"perk_fast_hire"), "«Быстрый найм» берётся первым")
	_check(Campaign.hero_take_perk(&"perk_big_staff"),
		"«Раздутый штат» берётся после «Быстрого найма»")
	_check(is_equal_approx(Campaign.stat(&"perk_perk_fast_hire"), 0.0),
		"ключ perk_<id> без второго префикса — perk_fast_hire, не perk_perk_fast_hire")
	_check(is_equal_approx(Campaign.stat(&"perk_fast_hire"), 0.0),
		"перк героя в бой не идёт: perk_fast_hire в stat() нейтрален")
	_check(not Campaign.hero_take_perk(&"perk_fast_hire"), "повторно тот же перк не берётся")


func _test_hero_reset() -> void:
	_check(not Campaign.hero_perks().is_empty(), "к моменту сброса перки уже взяты")
	var level_before := Campaign.hero_level()
	Campaign.hero_reset()
	_check(Campaign.hero_perks().is_empty(), "сброс снял все перки")
	_check(Campaign.hero_rank(&"q") == 0, "сброс обнулил ранг Ку")
	_check(Campaign.hero_level() == level_before, "сброс не трогает уровень/опыт")
	_check(Campaign.hero_points_available() == Campaign.hero_points_earned(),
		"после сброса все очки снова свободны")


func _test_unlocks() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	var all := Campaign.maps()
	_check(is_equal_approx(Campaign.stat(&"kind_unlocked_guard"), 0.0),
		"вахтёр закрыт на свежем прогрессе")
	# кампания v20 (D-0926-46): открытия по картам лестницы — Ку с первой, Дубль-вэ и Е с «Развилки»
	_check(is_equal_approx(Campaign.stat(&"ability_unlocked_q"), 1.0), "Ку открыта сразу")
	_check(is_equal_approx(Campaign.stat(&"ability_unlocked_w"), 0.0), "Дубль-вэ закрыта до «Развилки»")
	_check(is_equal_approx(Campaign.stat(&"ability_unlocked_e"), 0.0), "Е закрыта до «Развилки»")
	_check(Campaign.pending_unlock_labels().is_empty(),
		"на брифинге первой карты плашки «Новое» нет (Ку — урок самой карты)")

	# Открытие идёт по ПОРЯДКУ карт (all[1]/all[2]), а не по id — бьём первую карту.
	Campaign.record_result(String(all[0].get("id", "")), true, 0.9)
	_check(is_equal_approx(Campaign.stat(&"kind_unlocked_guard"), 1.0),
		"вахтёр открылся после первой карты (открыта вторая — «Проходная»)")
	_check(is_equal_approx(Campaign.stat(&"kind_unlocked_clerk"), 0.0),
		"счетовод ещё закрыт (его открывает «Архив»)")

	var labels := Campaign.pending_unlock_labels()
	_check(labels == ["Новый вид бойца: Вахтёр", "Стрелка отряда: Пробел или зажатое колесо",
			"«Сбор»: Эр (R)"],
		"плашка «Новое» после первой карты — вахтёр, стрелка и «Сбор»: %s" % str(labels))
	Campaign.mark_unlocks_seen()
	_check(Campaign.pending_unlock_labels().is_empty(), "после mark_unlocks_seen плашка пуста")

	Campaign.record_result(String(all[1].get("id", "")), true, 0.9)
	Campaign.record_result(String(all[2].get("id", "")), true, 0.9)
	_check(is_equal_approx(Campaign.stat(&"kind_unlocked_clerk"), 1.0),
		"счетовод открылся с «Архивом» (четвёртая карта)")
	# Лестница идёт по порядку карт, и каждая открывает СЛЕДУЮЩУЮ: отметку ставим после каждого
	# шага, поэтому плашка показывает ровно то, что принесла эта карта. Фигур стало две
	# (D-1002: «Мост» — треугольник «Обряда», «Лабиринт» — пятиугольник «Комиссии»).
	Campaign.mark_unlocks_seen()
	Campaign.record_result(String(all[3].get("id", "")), true, 0.9)
	_check(Campaign.pending_unlock_labels() == ["Фигура «Обряд»: треугольник"],
		"«Мост» открыл треугольник «Обряда»: %s" % str(Campaign.pending_unlock_labels()))
	Campaign.mark_unlocks_seen()
	Campaign.record_result(String(all[4].get("id", "")), true, 0.9)
	_check(Campaign.pending_unlock_labels() == ["Фигура «Комиссия по упокоению»: пятиугольник"],
		"«Лабиринт» открыл пятиугольник «Комиссии»: %s" % str(Campaign.pending_unlock_labels()))


## Старое сохранение (до пакета meta) без секций [meta]/[hero] — читается значениями
## по умолчанию, не падает (задание meta п.6).
func _test_old_save_without_sections() -> void:
	const OLD_PATH := "user://legion_meta_test_old.cfg"
	var abs_path := ProjectSettings.globalize_path(OLD_PATH)
	if FileAccess.file_exists(OLD_PATH):
		DirAccess.remove_absolute(abs_path)
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "wasteland_stars", 2)   # секция из ДО-мета сохранения — есть
	cfg.save(OLD_PATH)                                 # [meta] и [hero] отсутствуют вовсе

	Campaign.set_save_path(OLD_PATH)
	_check(Campaign.stars("wasteland") == 2, "старое поле progress читается как прежде")
	_check(Campaign.bounty() == 0, "премия по умолчанию 0 без секции [meta]")
	_check(Campaign.hero_level() == 1, "уровень героя по умолчанию 1 без секции [hero]")
	_check(Campaign.hero_perks().is_empty(), "перков нет без секции [hero]")
	_check(is_equal_approx(Campaign.stat(&"cap_mult_laborer"), 1.0),
		"cap_mult_laborer нейтрален (1.0) без покупок в старом сохранении")

	if FileAccess.file_exists(OLD_PATH):
		DirAccess.remove_absolute(abs_path)


func _cleanup() -> void:
	var abs_path := ProjectSettings.globalize_path(TEST_PATH)
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(abs_path)
