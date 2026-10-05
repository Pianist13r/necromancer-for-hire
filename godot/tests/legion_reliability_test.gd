extends SceneTree
## B-396/B-397/B-398: настоящий API команд, неизменный повторный снимок и продолжение следа.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _world() -> LegionWorld:
	var w := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
	w.start_net_match("pvp:duel", 7, 0)
	return w


func _run() -> void:
	Campaign.set_save_path("user://legion_reliability_test.cfg")
	Campaign.reset()
	await _snapshot_isolation()
	await _trail_restore()
	await _natural_trail_restore()
	await _blocked_rally(0)
	await _blocked_rally(1)
	Campaign.reset()
	print("LEGION RELIABILITY: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _snapshot_isolation() -> void:
	var w := await _world()
	var c := Contract.new().build(PackedVector2Array([Vector2(160, 160), Vector2(260, 160)]), 1)
	c.id = 1
	w.contracts.contracts.append(c)
	var snap := w.snapshot()
	var original := var_to_bytes(snap)
	w.net_step()
	_check(var_to_bytes(snap) == original, "B-396 save: шаг исходного мира не старит снимок")
	c.seg_polys[0][0] += Vector2(1, 0)
	_check(var_to_bytes(snap) == original, "B-396 вложенная геометрия не меняет снимок")
	# wire-копия возвращает исходное состояние даже при дефекте save.
	snap = bytes_to_var(original)
	w.load_snapshot(snap)
	for i in 30:
		w.net_step()
	var expected := var_to_bytes(w.snapshot())
	var digest := w.net_digest()
	_check(var_to_bytes(snap) == original, "B-396 load: 30 шагов не меняют входной снимок")
	w.load_snapshot(snap)
	for i in 30:
		w.net_step()
	_check(var_to_bytes(w.snapshot()) == expected and w.net_digest() == digest,
		"B-396 один словарь дважды восстанавливает идентичное состояние и digest")
	w.queue_free()
	await process_frame


func _trail_restore() -> void:
	var a := await _world()
	var b := await _world()
	for side in 2:
		a.items_of(side).grant(&"burning_seal")
		var u := a.spawn_unit(LegionCfg.KIND_LABORER, Vector2(320, 320 + side * 96), null, side)
		u.state = Legionnaire.State.CHARGE
		u._charge_t = 2.0
		u._charge_dir = Vector2.RIGHT
	# Первый tick запоминает начало следа, следующие — часть шага до первого пятна.
	for i in 5:
		a.net_step()
	var snap: Dictionary = bytes_to_var(var_to_bytes(a.snapshot()))
	var reg := b.load_snapshot(snap)
	_check(reg.errors.is_empty() and reg.misses.is_empty(),
		"B-398 след восстановлен без потерь ссылок")
	_check(a.units[0].get_instance_id() != b.units[0].get_instance_id(),
		"B-398 свежий клиент имеет другие instance_id")
	var equal := true
	var why := ""
	for i in 30:
		a.net_step()
		b.net_step()
		why = NetSnap.diff(a.snapshot(), b.snapshot())
		if why != "" or a.net_digest() != b.net_digest():
			equal = false
			break
	_check(equal, "B-398 30 net_step: след, stats, полное состояние и digest совпадают " + why)
	_check(int(a.stats.get("item_trail", 0)) > 0, "B-398 fixture действительно оставляет пятна")
	a.queue_free()
	b.queue_free()
	await process_frame


func _natural_trail_restore() -> void:
	var a := await _world()
	a.dev = {"noview": "1"}
	a.args["pvp_bots"] = true
	a._base_seed = 7
	a.start_map("gen:7:3:pvp")
	for i in 20 * 60:
		a._step(1.0 / 60.0)
		await process_frame
	for side in 2:
		a.items_of(side).grant(&"burning_seal")
		a.items_of(side).grant(&"exploding_stamp")
	var ready := false
	for i in 90 * 60:
		a._step(1.0 / 60.0)
		await process_frame
		for side in 2:
			var it := a.items_of(side)
			if not (it.state.get(&"trail", {}) as Dictionary).is_empty() \
					and it.hazard_count(&"trail") > 0:
				ready = true
		if ready or a.phase != LegionWorld.Phase.BATTLE:
			break
	_check(ready, "B-398 бой ботов: снимок застал активный след и горящие пятна")
	if ready:
		var b := await _world()
		var snap: Dictionary = bytes_to_var(var_to_bytes(a.snapshot()))
		b.load_snapshot(snap)
		var why := ""
		for i in 30:
			a._step(1.0 / 60.0)
			b._step(1.0 / 60.0)
			await process_frame
			why = NetSnap.diff(a.snapshot(), b.snapshot())
			if why != "":
				break
		_check(why == "" and a.net_digest() == b.net_digest(),
			"B-398 бой ботов: 30 шагов полного состояния/следа/stats/digest совпали " + why)
		b.queue_free()
	a.queue_free()
	await process_frame


func _blocked_rally(side: int) -> void:
	var w := await _world()
	# 8 передовых и один отставший: точка прямого сбора глубоко в скале.
	var front := Vector2(720, 320)
	var back := Vector2(300, 320)
	var rock := [[380, 220], [540, 220], [540, 420], [380, 420]]
	if side == 1:
		front.x = w.world_size.x - front.x
		back.x = w.world_size.x - back.x
		for pt: Array in rock:
			pt[0] = w.world_size.x - pt[0]
	w.terrain.setup({"size": [int(w.world_size.x), int(w.world_size.y)], "rocks": [rock]})
	var enemy := w.sides[1 - side].cauldron_pos
	# Независимо от координат Котлов fixture наступает вправо.
	w.sides[1 - side].cauldron_pos = Vector2(w.world_size.x - 100 if side == 0 else 100, 320)
	for i in PvpBot.ASSAULT_MIN:
		w.spawn_unit(LegionCfg.KIND_LABORER, front + Vector2(0, i), null, side)
	var stray := w.spawn_unit(LegionCfg.KIND_LABORER, back, null, side)
	var blocked := back + (front - back).normalized() * PvpBot.STRAY_PULL
	_check(w.rally_center(blocked) == Vector2.INF,
		"B-397 side %d fixture: прежняя точка сбора в глубокой скале" % side)
	var bot := PvpBot.new()
	bot.setup(w, side)
	for i in 4:
		bot._consolidate()
	_check(int(bot.counts["rejects"]) == 0 and stray.state == Legionnaire.State.RALLY,
		"B-397 side %d бот обходит скалу без повторных отказов (%d)" % [side, bot.counts["rejects"]])
	w.sides[1 - side].cauldron_pos = enemy
	w.queue_free()
	await process_frame
