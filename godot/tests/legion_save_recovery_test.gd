extends SceneTree
## Повреждение единственного файла не должно уничтожать кампанию и настройки.

const SAVE := "user://legion_save_recovery_test.cfg"
const PREFS := "user://legion_save_recovery_settings_test.cfg"
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run()
	print("SAVE RECOVERY: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fails += 1
		print("FAIL: ", message)


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(contents)
	file.close()


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.add_bounty(123)
	Campaign.set_tutorial_done()
	_check(FileAccess.file_exists(SAVE + ".bak"), "есть резервная копия прогресса")
	_write(SAVE, "[meta\nbounty=999")
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 123, "битый файл: премия восстановлена из копии")
	Campaign.mark_hint_seen(&"recovery_probe")
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 123, "следующая запись не теряет восстановленную премию")
	_check(Campaign.hint_seen(&"recovery_probe"), "новые достижения сохраняются после восстановления")
	# Даже синтаксически корректный обрыв файла надо отличать от полного сохранения.
	Campaign.set_tutorial_done()
	var complete := FileAccess.get_file_as_string(SAVE)
	_write(SAVE, complete.substr(0, complete.find("[")))
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 123, "обрыв перед первой секцией обнаружен")
	Campaign.set_tutorial_done()
	var good_backup := FileAccess.get_file_as_string(SAVE + ".bak")
	_write(SAVE, "; necro")
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 123, "обрыв внутри заголовка не становится пустым профилем")
	Campaign.mark_hint_seen(&"short_header")
	_check(FileAccess.get_file_as_string(SAVE + ".bak") == good_backup,
		"обрыв заголовка не уничтожает резервную копию")
	# Старые профили без служебного заголовка по-прежнему читаются.
	_write(SAVE, "[meta]\nbounty=77\n[hero]\nxp=42\n")
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 77 and Campaign.hero_xp() == 42, "совместимость старого профиля")
	Campaign.add_bounty(1)
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 78, "старый профиль обновляется без потери данных")
	Campaign.reset()
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 0, "явный сброс не возвращает старый прогресс")
	Settings.path = PREFS
	Settings._cfg = null
	Settings.set_value("audio", "Music", 0.35)
	Settings.set_value("video", "vsync", false)
	_write(PREFS, "[audio\nMusic=1")
	Settings._cfg = null
	_check(is_equal_approx(Settings.get_bus_volume(&"Music"), 0.35), "настройки тоже восстанавливаются")
	_test_transactions()
	_test_unreadable()


## Транзакции записи (сбой не оставляет полузаписи, повтор после снятия барьера работает) —
## проверка прежняя, но покупки теперь другие: уровни «Конторы» заменены услугами подготовки
## (RunProgression.buy_service: souls/mana/reroll) и поправками-карточками AmendmentDb, которые
## забирают через Campaign.claim_reward (OVERHAUL 05.10). Старого shop_buy с уровнями в игре
## больше нет, поэтому проверка идёт по новым покупкам — сами гарантии те же.
func _test_transactions() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.add_bounty(100)
	var original := FileAccess.get_file_as_string(SAVE)
	Campaign.begin_update()
	Campaign.add_bounty(20)
	Campaign.set_pending_reward("gatehouse")
	_check(FileAccess.get_file_as_string(SAVE) == original, "незавершённая операция не пишет часть данных")
	_check(Campaign.end_update(), "операция записана")
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 120 and Campaign.pending_reward() == "gatehouse", "операция целиком пережила запуск")
	_check(FileAccess.get_file_as_string(SAVE + ".bak") == original, "копия содержит целую предыдущую операцию")
	# Каталог вместо временного файла надёжно имитирует отказ записи без прав администратора.
	var before_buy := FileAccess.get_file_as_string(SAVE)
	_check(DirAccess.make_dir_absolute(SAVE + ".tmp") == OK, "создан барьер записи")
	_check(not RunProgression.buy_service("souls"), "неудачная запись не выдаёт успешную покупку")
	_check(Campaign.bounty() == 120 and RunProgression.preparation() == "",
		"неудачная покупка подготовки не отнимает премию и не выдаёт услугу")
	_check(FileAccess.get_file_as_string(SAVE) == before_buy, "отказ записи не портит основной профиль")
	DirAccess.remove_absolute(SAVE + ".tmp")
	_check(RunProgression.buy_service("souls"), "повтор покупки после устранения сбоя работает")
	Campaign.set_save_path(SAVE)
	_check(RunProgression.preparation() == "souls"
			and is_equal_approx(float(RunProgression.preparation_mods().get("start_souls", 0.0)), 45.0),
		"купленная подготовка пережила загрузку")
	# Вторая половина прежней проверки — про улучшение, которое остаётся в профиле. Теперь это
	# взятая поправка к договору: тот же путь транзакции (claim_reward).
	_check(DirAccess.make_dir_absolute(SAVE + ".tmp") == OK, "создан барьер записи для поправки")
	var before_card := FileAccess.get_file_as_string(SAVE)
	_check(not Campaign.claim_reward(&"bulk_ink"), "неудачная запись не выдаёт поправку")
	_check(Campaign.upgrades().is_empty() and not Campaign.reward_claimed(),
		"отказ записи не выдаёт поправку и не закрывает награду")
	_check(FileAccess.get_file_as_string(SAVE) == before_card, "отказ записи не портит профиль")
	DirAccess.remove_absolute(SAVE + ".tmp")
	_check(Campaign.claim_reward(&"bulk_ink"), "повтор взятия поправки после устранения сбоя работает")
	Campaign.set_save_path(SAVE)
	_check(Campaign.upgrades().size() == 1 and Campaign.upgrades().has(&"bulk_ink"),
		"взятая поправка пережила загрузку")


func _test_unreadable() -> void:
	var path := "user://legion_save_broken_test.cfg"
	_write(path, "; necro-save-v1 invalid\n[meta]\nbounty=999\n")
	_write(path + ".bak", "; necro-save-v1 invalid\n")
	var original := FileAccess.get_file_as_string(path)
	Campaign.set_save_path(path)
	_check(Campaign.bounty() == 0, "нечитаемый профиль не отдаёт частичные данные")
	Campaign.add_bounty(12)
	_check(FileAccess.get_file_as_string(path) == original, "оба файла повреждены: оригинал не затёрт")
	_check(SafeConfig.notices.has(path), "ошибка загрузки доступна интерфейсу")
	Campaign.reset()
	Campaign.set_save_path(path)
	_check(Campaign.bounty() == 0, "явный сброс разрешает новое сохранение")
	_write(path, "; necro-save-v9 newer-version\n[meta]\nbounty=100\n")
	Campaign.set_save_path(path)
	Campaign.add_bounty(12)
	_check(FileAccess.get_file_as_string(path).begins_with("; necro-save-v9"),
		"более новый формат нельзя перезаписать старой игрой")
