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
	print("LEGION DEBRIEF: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
