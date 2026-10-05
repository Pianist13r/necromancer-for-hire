extends SceneTree
##
## Самопроверка Campaign (без окна): сохранение/загрузка прогресса, открытие следующей карты,
## звёзды, offer_upgrades без повторов, active_mods суммирует. Пишет во временный файл —
## реальный user://legion.cfg владельца не трогает (Campaign.set_save_path).
##
##   "$GODOT" --headless --path godot --script res://tests/legion_campaign_test.gd -- --mute
##

const TEST_PATH := "user://legion_campaign_test_run.cfg"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run()
	print("Campaign test: %d/%d OK" % [_checks - _fails, _checks])
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

	var maps := Campaign.maps()
	# кампания v20 растёт картами между существующими («Архив», «Проходная») — не меньше шести
	_check(maps.size() >= 6, "не меньше 6 карт (%d)" % maps.size())

	var first_id := String(maps[0].get("id", ""))
	var second_id := String(maps[1].get("id", ""))
	var third_id := String(maps[2].get("id", ""))

	_check(Campaign.is_unlocked(first_id), "первая карта открыта на свежем прогрессе")
	_check(not Campaign.is_unlocked(second_id), "вторая карта закрыта на свежем прогрессе")
	_check(Campaign.stars(first_id) == 0, "звёзд ещё нет")

	# Победа с высокой долей HP → 3★, открывает вторую карту.
	var earned := Campaign.record_result(first_id, true, 0.95)
	_check(earned == 3, "ratio 0.95 → 3★ (earned=%d)" % earned)
	_check(Campaign.stars(first_id) == 3, "3★ сохранились")
	_check(Campaign.is_unlocked(second_id), "вторая карта открылась после победы")
	_check(not Campaign.is_unlocked(third_id), "третья карта ещё закрыта")

	# Средняя доля → 2★; худший повторный результат не портит лучший сохранённый.
	Campaign.record_result(second_id, true, 0.5)
	_check(Campaign.stars(second_id) == 2, "ratio 0.5 → 2★")
	Campaign.record_result(second_id, true, 0.1)
	_check(Campaign.stars(second_id) == 2, "худший повтор (1★) не портит сохранённые 2★")

	# Поражение не даёт звёзд и не открывает следующую карту.
	var lost := Campaign.record_result(third_id, false, 0.0)
	_check(lost == 0, "поражение → 0★ (earned=%d)" % lost)
	_check(Campaign.stars(third_id) == 0, "поражение не пишет звёзды")

	# offer_upgrades: три разных, ещё не взятых.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var offer1 := Campaign.offer_upgrades(rng)
	_check(offer1.size() == 3, "offer_upgrades даёт 3 варианта на пустом прогрессе")
	_check(_all_unique(offer1), "3 варианта различны")

	Campaign.add_upgrade(offer1[0])
	Campaign.add_upgrade(offer1[1])
	var offer2 := Campaign.offer_upgrades(rng)
	_check(not offer2.has(offer1[0]) and not offer2.has(offer1[1]),
		"offer_upgrades не предлагает уже взятые поправки")

	# active_mods суммирует эффекты взятых поправок по ключу. Пул — карточки AmendmentDb: их
	# действие лежит в mods (словарь ключ боя → прибавка), поля effect старого пула постоянных
	# процентов больше нет, поэтому сумму сверяем по всем ключам обеих карточек.
	var mods := Campaign.active_mods()
	var want := {}
	for id in [offer1[0], offer1[1]]:
		var card_mods: Dictionary = AmendmentDb.card(id).get("mods", {})
		for k: String in card_mods:
			want[k] = float(want.get(k, 0.0)) + float(card_mods[k])
	var sum_ok := not want.is_empty() and mods.size() == want.size()
	for k: String in want:
		sum_ok = sum_ok and is_equal_approx(float(mods.get(k, 0.0)), float(want[k]))
	_check(sum_ok, "active_mods = сумма mods обеих взятых карточек")

	# Повторное добавление той же поправки не задваивает эффект.
	var key0 := String(AmendmentDb.card(offer1[0]).get("mods", {}).keys()[0])
	var mods_before := float(mods.get(key0, 0.0))
	Campaign.add_upgrade(offer1[0])
	var mods_after := Campaign.active_mods()
	_check(is_equal_approx(float(mods_after.get(key0, 0.0)), mods_before),
		"повторный add_upgrade не задваивает эффект")

	# Сохранение/загрузка: сброс кэша (как новая сессия) не теряет прогресс.
	Campaign.set_save_path(TEST_PATH)
	_check(Campaign.stars(first_id) == 3, "3★ пережили перезагрузку кэша")
	_check(Campaign.stars(second_id) == 2, "2★ пережили перезагрузку кэша")
	_check(Campaign.upgrades().has(offer1[0]), "взятая поправка пережила перезагрузку кэша")
	_check(Campaign.is_unlocked(second_id), "разблокировка пережила перезагрузку кэша")

	# unlock_all открывает всё сразу.
	Campaign.unlock_all()
	for m in maps:
		_check(Campaign.is_unlocked(String(m.get("id", ""))), "unlock_all открыл %s" % m.get("id"))

	# reset возвращает к чистому состоянию.
	Campaign.reset()
	_check(Campaign.stars(first_id) == 0, "reset обнулил звёзды")
	_check(not Campaign.is_unlocked(second_id), "reset закрыл вторую карту")
	_check(Campaign.upgrades().is_empty(), "reset снял поправки")

	_cleanup()


func _all_unique(arr: Array) -> bool:
	var seen := {}
	for v in arr:
		if seen.has(v):
			return false
		seen[v] = true
	return true


func _cleanup() -> void:
	var abs_path := ProjectSettings.globalize_path(TEST_PATH)
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(abs_path)
