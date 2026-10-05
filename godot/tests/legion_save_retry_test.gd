# gdlint: disable=max-file-lines
extends SceneTree
##
## Регресс независимого ревью J, находки J2, J3, J9 и проверка J10 (05.10.2026).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_save_retry_test.gd -- --mute
##
## J2 — итог боя при отказе записи: показанная награда не теряется и не выдаётся дважды, игрок
##      видит сообщение, а кнопка «Повторить запись» доводит запись до диска.
## J3 — подготовка «Конторы» не уходит в бой без списания: иначе отказ записи выдавал бонус
##      бесплатно и оставлял услугу в сохранении — следующий старт применил бы её второй раз.
## J9 — после освобождения диска повторная миграция в этой же сессии доводит профиль до конца
##      (раньше до перезапуска новые итоги сохранить было нельзя).
## J10 — восемь старых поправок без переноса премии не возвращают: возврат считается только по
##      ценам уровней «Конторы» и ровно один раз (проверка, не правка).
##
## Итог «LEGION SAVE RETRY: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_save_retry_test.cfg"
const DT := 1.0 / 60.0

var checks := 0
var fails := 0
var main: LegionMain = null


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])


func _frames(n := 2) -> void:
	for i in n:
		await process_frame


func _raise_barrier() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE + ".tmp"))


func _drop_barrier() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE + ".tmp"))


func _disk(section: String, key: String, fallback: Variant) -> Variant:
	var probe := ConfigFile.new()
	if probe.parse(FileAccess.get_file_as_string(SAVE)) != OK:
		return fallback
	return probe.get_value(section, key, fallback)


func _write_legacy(text: String) -> void:
	_drop_barrier()
	var file := FileAccess.open(SAVE, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	for suffix: String in [".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE + suffix))


func _new_main() -> void:
	main = LegionMain.new()
	root.add_child(main)
	await _frames()
	main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}


func _run() -> void:
	_test_migration_resumes()
	_test_unmapped_amendments()
	await _test_preparation_needs_write()
	await _test_outcome_retry()
	_cleanup()
	print("LEGION SAVE RETRY: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


# ── J9: миграция оживает после освобождения диска ────────────────────────────

func _test_migration_resumes() -> void:
	print("— J9: повтор миграции после отказа записи")
	var refund := 0
	var costs: Array = LegionMetaCfg.LEGACY_OFFICE_SHOP["range"]["costs"]
	for i in 2:
		refund += int(costs[i])
	_write_legacy("[meta]\nbounty=17\nshop_range_laborer=2\n")
	Campaign.set_save_path(SAVE)
	Campaign.use_campaign_scope()
	_raise_barrier()
	Campaign.set_save_path(SAVE)   # перечитать: миграция попробует записать и откажет
	check(int(Campaign.raw_file().get_value(RunProgression.SECTION, "version", 0)) == 0,
		"миграция не прошла: профиль остался старой версии")
	# диск освободился — любая следующая запись обязана довести миграцию до конца
	_drop_barrier()
	Campaign.add_bounty(5)
	check(int(_disk(RunProgression.SECTION, "version", 0)) == RunProgression.VERSION,
		"после освобождения диска миграция дописана в этой же сессии")
	check(int(_disk("meta", "bounty", 0)) == 17 + refund + 5,
		"премия с возвратом легла на диск один раз (%d)" % int(_disk("meta", "bounty", 0)))
	Campaign.set_save_path(SAVE)
	check(Campaign.bounty() == 17 + refund + 5, "повторное чтение не вернуло премию второй раз")


# ── J10: восемь старых поправок без переноса ─────────────────────────────────

func _test_unmapped_amendments() -> void:
	print("— J10: старые поправки без переноса")
	var unmapped: Array[String] = []
	for id: String in LegionMetaCfg.LEGACY_UPGRADES:
		if not AmendmentDb.LEGACY_MAP.has(id):
			unmapped.append(id)
	check(unmapped.size() == 8, "старых поправок без переноса ровно 8 (найдено %d)" % unmapped.size())
	var refund := 0
	var costs: Array = LegionMetaCfg.LEGACY_OFFICE_SHOP["mana"]["costs"]
	for i in 1:
		refund += int(costs[i])
	var ids_list := "\", \"".join(unmapped)
	_write_legacy("[meta]\nbounty=40\nshop_mana=1\nupgrades=[\"%s\"]\n" % ids_list)
	Campaign.set_save_path(SAVE)
	Campaign.use_campaign_scope()
	Campaign.raw_file()   # первое чтение запускает миграцию
	check(int(_disk("meta", "bounty", 0)) == 40 + refund,
		"за поправки без переноса премия НЕ возвращается: возврат только за уровни «Конторы» (%d)"
		% int(_disk("meta", "bounty", 0)))
	check(Array(_disk("meta", "legacy_upgrades", [])).size() == 8,
		"все восемь поправок сохранены в архиве профиля")
	check(Array(_disk("meta", "upgrades", [])).is_empty(),
		"в активной колоде их нет — переноса не существует")
	Campaign.set_save_path(SAVE)
	check(Campaign.bounty() == 40 + refund, "повторное чтение не вернуло премию второй раз")


# ── J3: подготовка без списания в бой не уходит ──────────────────────────────

func _test_preparation_needs_write() -> void:
	print("— J3: подготовка «Конторы» и отказ записи")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	Campaign.add_bounty(200)
	check(RunProgression.buy_service("souls"), "подготовка куплена")
	await _new_main()
	var map_id := String(Campaign.maps()[0]["id"])
	_raise_barrier()
	main.start_battle(map_id)
	await _frames(3)
	check(main.world != null and main.world.battle_preparation.is_empty(),
		"отказ записи: бонус в бой НЕ ушёл (J3)")
	check(RunProgression.preparation() == "souls", "услуга осталась в сохранении — не потеряна")
	_drop_barrier()
	main.start_battle(map_id)
	await _frames(3)
	check(not main.world.battle_preparation.is_empty(),
		"после освобождения диска подготовка применилась")
	check(RunProgression.preparation() == "", "и списалась ровно один раз")
	main.queue_free()
	main = null
	await _frames()


# ── J2: итог боя при отказе записи ───────────────────────────────────────────

func _test_outcome_retry() -> void:
	print("— J2: итог боя, отказ записи и повтор кнопкой")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	await _new_main()
	var path := SAVE   # Campaign._path: тем же путём живут извещения SafeConfig
	var map_id := String(Campaign.maps()[0]["id"])
	_raise_barrier()
	main.start_battle(map_id)
	await _frames(3)
	main.world.force_end(true)
	await _frames(2)
	var bounty_ram := Campaign.bounty()
	var shown := Campaign.pending_reward()
	check(shown != "", "победа дала показанную награду-переход")
	check(bounty_ram > 0, "награда в памяти есть — из-за отказа записи её не сбросили")
	check(SafeConfig.notices.has(path), "игрок видит сообщение об отказе диска")
	check(int(_disk("meta", "bounty", 0)) != bounty_ram, "на диск награда ещё не легла")
	# повтор кнопкой на плашке: причина ушла — выдача завершается
	_drop_barrier()
	var notice := SaveNotice.new()
	root.add_child(notice)
	await _frames(2)
	var retry: Variant = notice.get("_retry")
	check(retry != null, "плашка предлагает повторить запись")
	if retry != null:
		(retry as Button).pressed.emit()
		await _frames(2)
		check(int(_disk("meta", "bounty", 0)) == bounty_ram,
			"повтор записал ровно ту же премию — второй раз её не выдал")
		check(String(_disk("meta", "pending_reward", "")) == shown,
			"и переход к следующей карте лёг на диск")
		check(not SafeConfig.notices.has(path), "извещение об отказе снято")
	notice.queue_free()
	main.queue_free()
	main = null
	await _frames()


func _cleanup() -> void:
	_drop_barrier()
	if main != null and is_instance_valid(main):
		main.queue_free()
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Settings._cfg = null
	SafeConfig.notices.erase(SAVE)
	for suffix: String in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE + suffix))
