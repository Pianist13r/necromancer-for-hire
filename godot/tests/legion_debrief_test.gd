extends SceneTree
## Разбор боя должен считать действительный урон, а не приписывать исход последнему врагу.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL: ", label)


func _run() -> void:
	Campaign.set_save_path("user://debrief_test.cfg")
	Campaign.reset()
	var w := LegionWorld.new()
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.start_map("wasteland")
	w.set_process(false)
	w.dev_invuln = false
	w.cauldron_hp = 100.0
	w.damage_cauldron(70.0, "zombie")
	w.damage_cauldron(90.0, "ghost")
	var final := w.final_stats(false)
	var report: Dictionary = final.get("debrief", {})
	_check(not report.is_empty(), "итог содержит разбор боя")
	_check(is_equal_approx(float(report.get("damage", -1)), 100.0),
		"избыточный урон не записан как потерянное HP")
	var sources: Dictionary = report.get("sources", {})
	_check(is_equal_approx(float(sources.get("zombie", 0)), 70.0), "главный урон — зомби")
	_check(is_equal_approx(float(sources.get("ghost", 0)), 30.0),
		"последний удар — только оставшееся HP")
	var available := _available()
	var mixed := report.duplicate(true)
	mixed["roads"] = {"north": 90.0, "south": 10.0}
	mixed["waves"] = {"3": 100.0}
	var mixed_before := mixed.duplicate(true)
	var mixed_plan := BattleDebrief.next_plan(mixed, available)
	_check(mixed_plan.contains("проверьте ближайший подход")
		and not mixed_plan.contains("призраки") and not mixed_plan.contains("север"),
		"план берёт крупнейший фактический источник, не склеивает маргинальные дороги/волны")
	_check(mixed == mixed_before and available == _available(), "план не меняет входные словари")
	w.start_map("wasteland")
	w.set_process(false)
	w.dev_invuln = true
	w.damage_cauldron(80.0, "ghost")
	var protected: Dictionary = w.final_stats(true).get("debrief", {})
	_check(is_zero_approx(float(protected.get("damage", 0))),
		"учебная неуязвимость не создаёт выдуманный прорыв")
	w.dev_invuln = false
	w.cauldron_hp = 100.0
	var road := String(w.map["roads"][0]["id"])
	var foe := w.spawn_foe("zombie", road, {"origin": {"wave": 3, "road": road}})
	if foe != null:
		w.foe_reached_cauldron(foe)
		var real: Dictionary = w.final_stats(false).get("debrief", {})
		_check(not Dictionary(real.get("roads", {})).is_empty(), "настоящий прорыв сохраняет дорогу")
		_check(Dictionary(real.get("waves", {})).has("3"), "настоящий прорыв сохраняет волну рождения")
		var lines := BattleDebrief.lines(real)
		_check(lines.size() == 3, "три коротких наблюдения из записанного боя")
		_check(lines[0].contains("Инспектор"), "название главного источника из словаря игры")
		_check(lines[2].contains("волны 3"), "волна в тексте соответствует данным")
		var plain := BattleDebrief.panel(real)
		var guided := BattleDebrief.panel(real, UiStyle.TEXT_DIM, available)
		_check(plain.get_child_count() == 4 and guided.get_child_count() == 5,
			"старый panel сохраняет три факта, явный контекст добавляет совет")
		plain.free()
		guided.free()
		var saved := Dictionary(w.stats["debrief"]).duplicate(true)
		real["sources"]["zombie"] = 999.0
		_check(w.stats["debrief"] == saved, "экран не может изменить статистику живого мира")
	else:
		_check(false, "тестовая дорога существует")
	w.start_map("wasteland")
	w.set_process(false)
	for i in 30:
		w.wave_runner.tick(1.0)
	var wave_foes := 0
	for enemy in w.foes:
		if int(enemy.origin.get("wave", 0)) > 0:
			wave_foes += 1
			_check(String(enemy.origin.get("road", "")) != "", "настоящая очередь волн знает дорогу")
	_check(wave_foes > 0, "очередь действительно породила врагов")
	w.start_map("pvp:duel")
	w.set_process(false)
	w.damage_cauldron(20.0, "zombie", 0, {"road": "west", "wave": 2})
	_check(not w.stats.has("debrief"), "одиночный разбор не меняет сетевое состояние")
	w.queue_free()
	await process_frame
	_check(BattleDebrief.lines({}).is_empty(), "нет фактов — нет выдуманного совета")
	_next_plan_checks()
	print("LEGION DEBRIEF: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _available() -> Dictionary:
	return {"kind_unlocked_guard": true, "ability_unlocked_e": true,
		"kind_unlocked_clerk": false, "ability_unlocked_q": true}


func _next_plan_checks() -> void:
	var available := _available()
	var ghost := {"damage": 40.0, "sources": {"ghost": 40.0}}
	var saved_ghost := ghost.duplicate(true)
	var saved_available := available.duplicate(true)
	_check(BattleDebrief.next_plan(ghost, {}).is_empty(), "нет явного контекста — нет совета")
	_check(BattleDebrief.next_plan(ghost, {"ability_unlocked_q": true}).is_empty(),
		"неполный контекст — нет совета")
	_check(BattleDebrief.next_plan({"damage": 0.0, "sources": {"ghost": 5.0}}, available).is_empty(),
		"нулевой фактический урон — нет совета")
	_check(BattleDebrief.next_plan({"damage": 40.0, "sources": {}}, available).is_empty(),
		"пустой источник — нет совета")
	_check(BattleDebrief.next_plan({"damage": 40.0,
		"sources": {"unknown": 30.0, "ghost": 10.0}}, available).is_empty(),
		"крупнейший неизвестный источник не заменяется догадкой о втором")
	for bad_total: float in [NAN, INF, -INF, -1.0]:
		_check(BattleDebrief.next_plan({"damage": bad_total,
			"sources": {"ghost": 40.0}}, available).is_empty(),
			"нечисловой или отрицательный итог не порождает совет")
	for bad_source: float in [NAN, INF, -INF, 0.0, -1.0]:
		_check(BattleDebrief.next_plan({"damage": 40.0,
			"sources": {"ghost": bad_source}}, available).is_empty(),
			"нечисловой или неположительный источник не порождает совет")
	_check(BattleDebrief.next_plan({"damage": 40.0,
		"sources": {"unrecognized_foe": 40.0}}, available).is_empty(),
		"неизвестному виду не приписывается знакомая тактика")
	var invalid_available := available.duplicate()
	invalid_available["ability_unlocked_q"] = 1
	_check(BattleDebrief.next_plan(ghost, invalid_available).is_empty(),
		"число вместо явного boolean открытия не принимается")
	var previous_language := I18n.language
	I18n.language = "ru"
	Settings.path = "user://debrief_next_plan_settings.cfg"
	Settings._cfg = ConfigFile.new()
	Settings.apply()
	Controls.reset()
	var plan := BattleDebrief.next_plan(ghost, available)
	_check(plan.contains("Вариант для повтора: призраки — Ку") and not plan.contains("аудит"),
		"закрытый аудит не советуется, открытая Ку доступна: %s" % plan)
	_check(Controls.swap(&"cast_q", KEY_W).is_empty(), "переназначение Ку на Дубль-вэ")
	plan = BattleDebrief.next_plan(ghost, available)
	_check(plan.contains("призраки — Дубль-вэ") and not plan.contains("призраки — Ку"),
		"совет показывает текущую клавишу один раз: %s" % plan)
	I18n.language = "en"
	plan = BattleDebrief.next_plan(ghost, available)
	_check(plan.contains("Option for a retry: ghosts — W") and not plan.contains("Audit"),
		"EN и текущая клавиша без закрытого аудита: %s" % plan)
	_check(ghost == saved_ghost and available == saved_available,
		"локализованный совет не меняет входные словари")
	available["ability_unlocked_q"] = false
	plan = BattleDebrief.next_plan(ghost, available)
	_check(plan.contains("ghosts — free fighters") and not plan.contains("Audit"),
		"оба специальных ответа закрыты — остаётся свободный боец: %s" % plan)
	var shield := {"damage": 20.0, "sources": {"shield_inspector": 20.0}}
	available["kind_unlocked_guard"] = false
	available["ability_unlocked_e"] = false
	plan = BattleDebrief.next_plan(shield, available)
	_check(plan.contains("shields — from the flank"),
		"щит без охраны и Е — доступный фланг: %s" % plan)
	plan = BattleDebrief.next_plan({"damage": 12.0, "sources": {"beetle": 12.0}}, available)
	_check(plan.contains("check the nearest approach") and plan.contains("keep some fighters free"),
		"курьеру — сдержанный вариант для повтора: %s" % plan)
	plan = BattleDebrief.next_plan({"damage": 12.0, "sources": {"signer": 12.0}}, available)
	_check(plan.contains("notaries — charge"), "нотариусу — существующий ответ: %s" % plan)
	plan = BattleDebrief.next_plan({"damage": 12.0, "sources": {"boss": 12.0}}, available)
	_check(plan.contains("Foreman — release before the ram"),
		"Прорабу — существующий ответ: %s" % plan)
	_check(ghost == saved_ghost, "отчёт остался прежним после всех вариантов")
	I18n.language = previous_language
	Controls.reset()
	Settings.path = Settings.PATH
	Settings._cfg = null
