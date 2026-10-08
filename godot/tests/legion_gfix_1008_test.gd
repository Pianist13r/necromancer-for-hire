extends SceneTree
## Доводка verifier 08.10: B-043 (предупреждение «у дороги» по доле настоящих рождений) и
## B-442 (тряска Juicee при освобождении камеры во время эффекта).

var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _run() -> void:
	Campaign.set_save_path("user://gfix_1008.cfg")
	Campaign.reset()
	await test_shake_camera_freed()
	await test_shake_stop_after_free()
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	test_plot_shares()
	test_road_note()
	Campaign.reset()
	print("LEGION GFIX 1008: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


## Все площадки 8 карт кампании: id → доля безопасных рождений.
func shares() -> Dictionary:
	var out := {}
	for map_id in ["gatehouse", "archive", "bridge", "fork", "maze", "swamp", "wasteland", "boss"]:
		w.start_map(map_id)
		var rng_before := w.rng.state
		for p in w.staff.plots:
			out["%s/%s" % [map_id, p["id"]]] = w.staff.plot_safe_share(p)
		check(w.rng.state == rng_before, "оценка площадок не расходует боевой RNG: " + map_id)
	return out


func test_plot_shares() -> void:
	var a := shares()
	var b := shares()
	check(a == b, "доли (и список предупреждений) одинаковы между загрузками карт")
	var warned: Array[String] = []
	for key: String in a:
		if a[key] < LegionCfg.PLOT_SAFE_WARN:
			warned.append(key)
	print("PLOTS warned=%d/%d %s" % [warned.size(), a.size(), warned])
	for key: String in ["bridge/p6", "maze/p6", "maze/p1", "wasteland/p3", "archive/p1"]:
		print("SHARE %s %.3f" % [key, a[key]])
	# probe_plots2.log (1500 настоящих рождений): bridge/p6 11,7 %, maze/p6 28,7 %, maze/p1 20,8 %,
	# wasteland/p3 57,8 %, archive/p1 76,1 %.
	check(warned.has("bridge/p6"), "bridge/p6 (12 % безопасных, веер-полоска 66 px) предупреждается")
	check(warned.has("maze/p6"), "maze/p6 (29 % безопасных) предупреждается")
	check(not warned.has("wasteland/p3") and not warned.has("archive/p1"),
		"пограничные wasteland/p3 и archive/p1 (>50 % безопасных) не предупреждаются")
	check(absf(a["bridge/p6"] - 0.117) < 0.06 and absf(a["maze/p6"] - 0.287) < 0.06
		and absf(a["wasteland/p3"] - 0.578) < 0.06 and absf(a["archive/p1"] - 0.761) < 0.06,
		"выборка 300 рождений сходится с пробой verifier на 1500")
	var expected: Array[String] = ["bridge/p5", "bridge/p6", "fork/p2", "fork/p5", "maze/p1",
		"maze/p2", "maze/p3", "maze/p5", "maze/p6", "maze/p7", "swamp/p4", "boss/p1", "boss/p3",
		"boss/p6"]
	check(a.size() == 47 and warned == expected, "список предупреждений = доля < 50 % по пробе")
	# в бою площадка рождает тем же _plot_spawn — по-прежнему от world.rng
	w.start_map("bridge")
	var before := w.rng.state
	var p: Dictionary = w.staff.plots[5]
	w.souls = 1000
	var bld := w.staff.build(p, LegionCfg.KIND_LABORER)
	bld._spawn_point()
	check(w.rng.state != before, "рождение в бою по-прежнему берёт world.rng")


func test_road_note() -> void:
	var note := PlotMenu.road_note(0.287)
	print("NOTE ", note)
	check(note.contains("около 70 %"), "предупреждение называет долю рождений под удар")
	check(PlotMenu.road_note(0.0).contains("почти все"), "все рождения под удар — без «около 100 %»")


## Проба verifier (batches/verifier-1008/probe_shake.gd): камера освобождается посреди тряски.
## До правки: SCRIPT ERROR `_release_state` (shake_effect.gd:86), запись StateStack оставалась.
func test_shake_camera_freed() -> void:
	JuiceeStateStack.reset()
	var cam := Camera2D.new()
	root.add_child(cam)
	cam.make_current()
	await process_frame
	var effect := JuiceeShakeEffect.new()
	var done := [false]
	_run_shake(effect, cam, done)
	check(JuiceeStateStack.active_count() == 1, "тряска взяла смещение камеры")
	cam.queue_free()
	await create_timer(0.5).timeout
	check(done[0], "корутина тряски вернулась после освобождения камеры")
	check(JuiceeStateStack.active_count() == 0, "StateStack очищен от освобождённой камеры")


func _run_shake(effect: JuiceeShakeEffect, cam: Camera2D, done: Array) -> void:
	await effect._apply(cam, 1.0)
	done[0] = true


## Juice.sync_accessibility() зовёт stop() у живых эффектов: камера уже освобождена — stop()
## отпускает её запись без ошибки типа. Контекст — не камера (как у Juice.shake из мира), иначе
## эффект сам остановится по tree_exiting камеры, пока она ещё жива.
func test_shake_stop_after_free() -> void:
	JuiceeStateStack.reset()
	var ctx := Node2D.new()
	root.add_child(ctx)
	var cam := Camera2D.new()
	root.add_child(cam)
	cam.make_current()
	await process_frame
	var effect := JuiceeShakeEffect.new()
	effect.apply(ctx)
	await process_frame
	check(JuiceeStateStack.active_count() == 1, "тряска через apply() взяла смещение камеры")
	cam.free()
	effect.stop()
	check(JuiceeStateStack.active_count() == 0, "stop() после освобождения камеры чистит StateStack")
	await create_timer(0.5).timeout
	check(JuiceeStateStack.active_count() == 0, "эффект доработал без следов")
	ctx.queue_free()
