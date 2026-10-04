extends SceneTree
##
## Самопроверка пакета meta (без окна): премия и опыт за бой, покупки «Конторы» и потолок
## уровней, Campaign.stat() суммирует и умножает по порядку источников, перк второго ряда
## без первого не берётся, сброс очков, открытия по порядку карт, старое сохранение (без
## секций [meta]/[hero]) читается значениями по умолчанию. Пишет во временный файл — реальный
## user://legion.cfg владельца не трогает (Campaign.set_save_path).
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
	_test_shop()
	_test_stat_sum_and_mult()
	_test_legacy_army_mods()
	_test_hero_ranks_and_perks()
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


func _test_shop() -> void:
	Campaign.set_save_path(TEST_PATH)   # свежий кэш, но прогресс тот же файл
	var before := Campaign.bounty()
	_check(Campaign.shop_level("range", "laborer") == 0, "покупка «Дальность» на нуле")
	_check(Campaign.stat(&"recruit_r_laborer") == 0.0, "recruit_r_laborer нейтрален без покупки")

	var cost1 := Campaign.shop_cost("range", "laborer")
	_check(cost1 == 40, "первая покупка «Дальность» стоит 40 (получили %d)" % cost1)
	var bought := Campaign.shop_buy("range", "laborer")
	_check(bought, "покупка прошла (премии хватает)")
	_check(Campaign.bounty() == before - 40, "премия списана")
	_check(Campaign.shop_level("range", "laborer") == 1, "уровень покупки вырос")
	_check(is_equal_approx(Campaign.stat(&"recruit_r_laborer"), 40.0),
		"recruit_r_laborer = 40 после первого уровня")

	# Потолок уровней: докупаем до максимума (3 у «Дальности», ещё 70+110=180 премии),
	# дальше стоимость -1 (уже макс). Бой без kills на победу не влияет на премию (только
	# звёзды) — несколько побед подряд, а не один большой kills.
	for i in 4:
		Campaign.record_rewards(true, 3, 0)   # 4×75=300 премии — с запасом на оставшиеся уровни
	Campaign.shop_buy("range", "laborer")
	Campaign.shop_buy("range", "laborer")
	_check(Campaign.shop_level("range", "laborer") == 3, "потолок уровня покупки — 3")
	_check(Campaign.shop_cost("range", "laborer") == -1, "цена -1 на максимуме (кнопка скрыта)")
	_check(not Campaign.shop_buy("range", "laborer"), "покупка сверх максимума не проходит")
	_check(is_equal_approx(Campaign.stat(&"recruit_r_laborer"), 120.0),
		"recruit_r_laborer = 120 на максимуме уровня")

	_check(Campaign.stat(&"cap_mult_guard") == 1.0, "cap_mult_guard нейтрален (вид ещё закрыт)")

	# Провал покупки без хватающей премии не списывает и не поднимает уровень: докупаем
	# «Расчёт» до упора (2 уровня), пока хватает премии, затем бьём тест на последней попытке.
	while Campaign.shop_cost("settlement") > 0 and Campaign.bounty() >= Campaign.shop_cost("settlement"):
		Campaign.shop_buy("settlement")
	var cost_now := Campaign.shop_cost("settlement")
	if cost_now > 0:
		var bounty_before := Campaign.bounty()
		var lvl_before := Campaign.shop_level("settlement")
		_check(not Campaign.shop_buy("settlement"), "покупка без хватающей премии отклонена")
		_check(Campaign.bounty() == bounty_before, "премия не списалась при провале покупки")
		_check(Campaign.shop_level("settlement") == lvl_before, "уровень не вырос при провале")
	else:
		_check(Campaign.shop_level("settlement") == Campaign.shop_max_level("settlement"),
			"«Расчёт» довели до максимума премии хватило — потолок уровня достигнут")


func _test_stat_sum_and_mult() -> void:
	# mana: per_level [20, 2] — общий (не per_kind), один уровень уже куплен по ходу теста?
	# нет — покупаем явно и проверяем аддитивный ключ mana_max_bonus.
	var before_mana := Campaign.stat(&"mana_max_bonus")
	Campaign.record_rewards(true, 3, 200)
	Campaign.shop_buy("mana")
	_check(is_equal_approx(Campaign.stat(&"mana_max_bonus") - before_mana, 20.0),
		"mana_max_bonus +20 за уровень «Мана»")
	_check(is_equal_approx(Campaign.stat(&"mana_regen_bonus"),
			float(Campaign.shop_level("mana")) * 2.0),
		"mana_regen_bonus = уровень × 2")

	# cap_mult_laborer — множитель: 1 + сумма по правилу is_mult_key (staff даёт +0.2 за уровень).
	Campaign.shop_buy("staff", "laborer")
	var lvl := Campaign.shop_level("staff", "laborer")
	_check(is_equal_approx(Campaign.stat(&"cap_mult_laborer"), 1.0 + 0.2 * lvl),
		"cap_mult_laborer = 1 + 0.2×уровень (множитель)")

	# active_mods (поправки к договору) и покупки складываются в один и тот же Campaign.stat —
	# берём произвольную поправку и проверяем именно ДЕЛЬТУ до/после (ключ поправки может
	# случайно совпасть с ключом уже купленного в «Конторе» — например, обе трогают
	# mana_max_bonus — важно, что поправка добавляет РОВНО свою величину, а не перетирает чужую).
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var offer := Campaign.offer_upgrades(rng)
	# три поправки армии проверяет _test_legacy_army_mods ниже — взятая здесь, она там уже не
	# добавилась бы (пул расширен 26.09, и сид 3 стал предлагать outstaff_partner первой)
	offer = offer.filter(func(id: StringName) -> bool:
		return not [&"night_shift_hr", &"outstaff_partner", &"signing_bonus"].has(id))
	if not offer.is_empty():
		var eff: Dictionary = LegionMetaCfg.UPGRADE_POOL[String(offer[0])]["effect"]
		var key := StringName(eff["key"])
		var value: float = float(eff["value"])
		var before_stat := Campaign.stat(key)
		Campaign.add_upgrade(offer[0])
		_check(is_equal_approx(Campaign.stat(key) - before_stat, value),
			"поправка к договору добавляет свою величину рядом с покупками (ключ %s)" % key)


## Согласование с координатором v15 (2026-09-25): мир больше не читает production_mult/
## army_cap_bonus/start_army_bonus напрямую — они должны перевестись в
## respawn_mult_laborer/cap_mult_laborer (Котёл — постройка вида laborer), иначе молча
## перестанут работать. Проверяем ДЕЛЬТУ (до этого момента уже куплен уровень «Штат: Подрядчик»
## в _test_stat_sum_and_mult — он тоже трогает cap_mult_laborer).
func _test_legacy_army_mods() -> void:
	var respawn_before := Campaign.stat(&"respawn_mult_laborer")
	Campaign.add_upgrade(&"night_shift_hr")   # production_mult +0.2
	var respawn_after := Campaign.stat(&"respawn_mult_laborer")
	_check(is_equal_approx(respawn_after - respawn_before, (1.0 / 1.2) - 1.0),
		"production_mult +20%% переводится в прибавку respawn_mult_laborer = 1/1.2 − 1")

	var cap_before := Campaign.stat(&"cap_mult_laborer")
	Campaign.add_upgrade(&"outstaff_partner")   # army_cap_bonus +20 → +0.15 cap_mult_laborer
	Campaign.add_upgrade(&"signing_bonus")      # start_army_bonus +15 → +0.10 cap_mult_laborer
	var cap_after := Campaign.stat(&"cap_mult_laborer")
	_check(is_equal_approx(cap_after - cap_before, 0.25),
		"army_cap_bonus+start_army_bonus дают +0.25 cap_mult_laborer суммарно (получили %.3f)"
			% (cap_after - cap_before))


func _test_hero_ranks_and_perks() -> void:
	Campaign.record_rewards(true, 3, 1000)   # опыт с большим запасом — герой высокого уровня
	var points_before := Campaign.hero_points_available()
	_check(points_before > 0, "после большого опыта есть свободные очки героя")

	_check(Campaign.hero_rank(&"q") == 0, "ранг Ку — 0 до покупки")
	_check(Campaign.hero_rank_up(&"q"), "ранг Ку куплен")
	_check(Campaign.hero_rank(&"q") == 1, "ранг Ку стал 1")
	_check(is_equal_approx(Campaign.stat(&"ability_rank_q"), 1.0), "ability_rank_q = 1 в stat()")
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
	_check(is_equal_approx(Campaign.stat(&"perk_fast_hire"), 1.0), "perk_fast_hire = 1 в stat()")
	_check(not Campaign.hero_take_perk(&"perk_fast_hire"), "повторно тот же перк не берётся")


func _test_hero_reset() -> void:
	var perks_before := Campaign.hero_perks().size()
	_check(perks_before > 0, "к моменту сброса перки уже взяты")
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
	Campaign.mark_unlocks_seen()
	Campaign.record_result(String(all[3].get("id", "")), true, 0.9)
	Campaign.record_result(String(all[4].get("id", "")), true, 0.9)
	_check(Campaign.pending_unlock_labels() == ["Фигура «Обряд»: треугольник"],
		"новое открытие (только треугольник «Лабиринта») видно после того, как прошлое отметили: %s"
			% str(Campaign.pending_unlock_labels()))


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
