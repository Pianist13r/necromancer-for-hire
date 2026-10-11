extends SceneTree
## Личная таблица рекордов (slow/records 10.10.2026, фундамент B-120): хранилище LegionRecords
## (правило «лучше», сложности, переживает перезапуск, сброс), запись в транзакции итога боя
## (B-442), строка на экране итога, подпись на карточке выбора карт, вкладка «Рекорды» «Досье»,
## счёт «Схватки» с ботом. Свой файл сохранения; в конце удаляется вместе с .bak.

const SAVE := "user://legion_records_1010_test.cfg"
var checks := 0
var fails := 0
var main: LegionMain


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("PASS " if ok else "FAIL ", what)


func _frames(n := 2) -> void:
	for _i in n:
		await process_frame


func _stats(hp: float, t: float, difficulty: String) -> Dictionary:
	return {"hp": hp, "t": t, "wave": 5, "lost": 3, "kills": 40, "seed": 77,
		"difficulty": difficulty}


func _labels_text(node: Node) -> String:
	var out := PackedStringArray()
	for l in node.find_children("*", "Label", true, false):
		out.append((l as Label).text)
	return "\n".join(out)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.use_campaign_scope()
	_test_store()
	_test_persist_and_reset()
	await _test_battle_flow()
	await _test_ui()
	await _test_pvp()
	_cleanup()
	print("RECORDS 1010: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _test_store() -> void:
	var c := LegionRecords.MODE_CAMPAIGN
	var r := LegionRecords.record_run(c, "m1", true, _stats(100.0, 200.0, "normal"), 2)
	_check(bool(r["is_new"]) and int(r["best"]["hp"]) == 100, "первая победа — рекорд")
	r = LegionRecords.record_run(c, "m1", true, _stats(90.0, 100.0, "normal"), 2)
	_check(not bool(r["is_new"]) and int(r["best"]["hp"]) == 100, "меньше HP — не рекорд")
	r = LegionRecords.record_run(c, "m1", true, _stats(100.0, 150.0, "normal"), 3)
	_check(bool(r["is_new"]) and is_equal_approx(float(r["best"]["t"]), 150.0),
		"равный HP и быстрее — рекорд")
	r = LegionRecords.record_run(c, "m1", false, _stats(300.0, 10.0, "normal"))
	_check(not bool(r["is_new"]) and int(r["best"]["hp"]) == 100, "поражение рекорд не меняет")
	r = LegionRecords.record_run(c, "m1", true, _stats(50.0, 300.0, "hell"), 1)
	_check(bool(r["is_new"]), "своя сложность — свой рекорд")
	_check(int(LegionRecords.best(c, "m1", "normal")["hp"]) == 100
		and int(LegionRecords.best(c, "m1", "hell")["hp"]) == 50
		and LegionRecords.best(c, "m1", "intern").is_empty(), "сложности не смешиваются")
	var b := LegionRecords.best(c, "m1", "normal")
	var has_all := true
	for k: String in LegionRecords.FIELDS:
		has_all = has_all and b.has(k)
	_check(has_all and int(b["stars"]) == 3 and int(b["seed"]) == 77 and int(b["date"]) > 0,
		"рекорд хранит hp, t, wave, lost, kills, seed, date, stars")
	_check(LegionRecords.short_text(b) == "HP 100 · 2:30", "подпись «HP 100 · 2:30»")
	LegionRecords.record_run(LegionRecords.MODE_COLLECTION, "gen:123:3:x", true,
		_stats(70.0, 61.0, "intern"), 0, "Свалка")
	var rows := LegionRecords.rows(LegionRecords.MODE_COLLECTION)
	_check(rows.size() == 1 and String(rows[0]["map"]) == "gen:123:3:x"
		and String(rows[0]["title"]) == "Свалка", "рекорд коллекции с id процгена")
	LegionRecords.record_pvp("pvp:duel", "win")
	LegionRecords.record_pvp("pvp:duel", "lose")
	LegionRecords.record_pvp("gen:5:3:pvp", "draw")
	var duel := LegionRecords.pvp_tally(LegionRecords.PVP_DUEL)
	var rnd := LegionRecords.pvp_tally(LegionRecords.PVP_RANDOM)
	_check(int(duel["wins"]) == 1 and int(duel["losses"]) == 1 and int(rnd["draws"]) == 1,
		"счёт «Схватки» по полю")
	_check(LegionRecords.pvp_verdict(false, {"pvp": {"winner": 0}}) == "win"
		and LegionRecords.pvp_verdict(true, {"pvp": {"winner": -1}}) == "draw"
		and LegionRecords.pvp_verdict(false, {"pvp": {"winner": -2}}) == "lose",
		"исход «Схватки» от лица стороны 0")
	# «Подряд»/«Вызов дня» не дублируются — читаются из endless_records.
	var f := Campaign.raw_file()
	var rs := Campaign.ENDLESS_RECORDS_SECTION
	f.set_value(rs, "endless_normal_tenure", 4)
	f.set_value(rs, "endless_normal_souls", 210)
	f.set_value(rs, "daily_2026-10-09|v3_hell_tenure", 2)
	f.set_value(rs, "daily_2026-10-09|v3_hell_souls", 90)
	f.set_value(rs, "daily_2026-10-10|v3_hell_tenure", 5)
	f.set_value(rs, "daily_2026-10-10|v3_hell_souls", 300)
	Campaign.save_raw()
	var e := LegionRecords.endless_rows(false)
	var d := LegionRecords.endless_rows(true)
	_check(int(e.get("normal", {}).get("tenure", 0)) == 4 and not e.has("hell"),
		"«Подряд» из endless_records")
	_check(int(d.get("hell", {}).get("tenure", 0)) == 5
		and String(d["hell"].get("date", "")) == "2026-10-10", "«Вызов дня» — лучшая дата")
	var dup := false
	for k: String in f.get_section_keys(LegionRecords.RECORDS_SECTION):
		dup = dup or k.begins_with("endless") or k.begins_with("daily")
	_check(not dup, "забег в records не дублируется")


func _test_persist_and_reset() -> void:
	var text := FileAccess.get_file_as_string(SAVE)
	_check(text.contains("[records]"), "секция records на диске")
	Campaign.set_save_path(SAVE)   # сбрасывает кэш: следующее чтение — с диска
	_check(int(LegionRecords.best(LegionRecords.MODE_CAMPAIGN, "m1", "normal").get("hp", 0)) == 100,
		"рекорд пережил перезапуск")
	_check(LegionRecords.rows(LegionRecords.MODE_COLLECTION).size() == 1,
		"рекорд коллекции пережил перезапуск")
	_check(int(LegionRecords.pvp_tally(LegionRecords.PVP_DUEL)["wins"]) == 1,
		"счёт «Схватки» пережил перезапуск")
	Campaign.reset()
	Campaign.set_save_path(SAVE)
	_check(LegionRecords.best(LegionRecords.MODE_CAMPAIGN, "m1", "normal").is_empty()
		and LegionRecords.rows(LegionRecords.MODE_COLLECTION).is_empty()
		and int(LegionRecords.pvp_tally(LegionRecords.PVP_DUEL)["wins"]) == 0,
		"«Удалить весь прогресс» чистит рекорды")


func _new_main() -> void:
	main = LegionMain.new()
	root.add_child(main)
	await _frames()


func _test_battle_flow() -> void:
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	await _new_main()
	var first_id := String(Campaign.maps()[0]["id"])
	main.start_battle(first_id)
	await _frames(3)
	var before := FileAccess.get_file_as_string(SAVE)
	main.world.force_end(true)
	_check(FileAccess.get_file_as_string(SAVE + ".bak") == before,
		"итог с рекордом — одна запись (B-442)")
	var diff := String(main.world.final_stats(true).get("difficulty", ""))
	var rec := LegionRecords.best(LegionRecords.MODE_CAMPAIGN, first_id, diff)
	_check(not rec.is_empty(), "победа в кампании записала рекорд (%s)" % diff)
	await _frames(3)
	_check(main.screen is LegionResult, "экран итога")
	var line := main.screen.find_child("PersonalRecord", true, false) as Label
	_check(line != null and line.text.begins_with("Новый личный рекорд!"),
		"итог: «Новый личный рекорд!» — %s" % (line.text if line else "нет строки"))
	_check(line != null and line.get_theme_color("font_color").is_equal_approx(UiStyle.GOLD),
		"новый рекорд — золотом")
	# Второй бой: Котёл тот же, время больше — рекорд прежний.
	main.start_battle(first_id)
	await _frames(6)
	main.world.force_end(true)
	await _frames(3)
	line = main.screen.find_child("PersonalRecord", true, false) as Label
	_check(line != null and line.text.begins_with("Личный рекорд: HP"),
		"повтор хуже: «Личный рекорд: HP …» — %s" % (line.text if line else "нет строки"))
	main.queue_free()
	await _frames()


func _test_ui() -> void:
	var second := String(Campaign.maps()[1]["id"])
	LegionRecords.record_run(LegionRecords.MODE_CAMPAIGN, second, true,
		_stats(180.0, 187.0, Settings.difficulty()), 3)
	Campaign.unlock_all()
	var ms := MapSelect.new()
	root.add_child(ms)
	await _frames()
	var texts := PackedStringArray()
	for l in ms.find_children("CardRecord", "Label", true, false):
		texts.append((l as Label).text)
	_check(texts.has("лучшее: HP 180 · 3:07"), "карточка карты: «лучшее: HP 180 · 3:07»")
	ms.queue_free()
	var dv := DossierView.new()
	root.add_child(dv)
	dv.configure()
	dv.show_tab(DossierView.TAB_RECORDS)
	await _frames()
	_check(dv.tab() == DossierView.TAB_RECORDS and dv.find_child("RecordsTab", true, false) != null,
		"вкладка «Рекорды» строится")
	var all := _labels_text(dv)
	_check(all.contains("HP 180 · 3:07") and all.contains("Подряд")
		and all.contains("Вызов дня") and all.contains("Схватка"),
		"вкладка: карты, «Подряд», «Вызов дня», «Схватка»")
	dv.show_tab(DossierView.TAB_UPGRADES)
	await _frames()
	_check(dv.find_child("RecordsTab", true, false) == null, "вкладка переключается обратно")
	dv.queue_free()
	await _frames()


func _test_pvp() -> void:
	await _new_main()
	PvpFlow.start(main, PvpMaps.DUEL)
	await _frames(3)
	main.world.force_end(true)
	await _frames()
	_check(int(LegionRecords.pvp_tally(LegionRecords.PVP_DUEL)["wins"]) == 1,
		"победа в «Схватке» с ботом засчитана")
	main.queue_free()
	await _frames()


func _cleanup() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".bak.tmp"]:
		var p := SAVE + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
