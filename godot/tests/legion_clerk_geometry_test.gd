extends SceneTree
## Общая дальняя плоскость фигуры: ложная стена за полосой не закрывает огневой вал.

const DT := 1.0 / 60.0
var w: LegionWorld
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	_fails += int(not ok)
	print("  %s %s" % ["ok" if ok else "FAIL", what])


func _square(kind: StringName, side: int) -> Contract:
	w.dev = {"spawn_units": "0", "no_waves": "1", "ctl_off": "1", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.start_map("pvp:duel")
	w.terrain.setup({"size": [1600, 900]})
	var points := PackedVector2Array()
	var center := Vector2(450 if side == 0 else 1150, 350)
	for i in 4:
		var a := Vector2.from_angle(TAU * i / 4.0 - PI / 2.0) * 70.0
		var b := Vector2.from_angle(TAU * (i + 1) / 4.0 - PI / 2.0) * 70.0
		for j in 16:
			points.append(center + a.lerp(b, j / 16.0))
	points.append(points[0])
	var field := w.sides[side].contracts
	field._create(points, 1, kind, false, ContractShape.SQUARE)
	var c: Contract = field.contracts.back()
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"], null, side)
		u.assign(c, p)
		u._arrive()
	return c


func _wall(mode: String, far: float, axis: Vector2) -> void:
	if mode == "no_wall":
		return
	var wall := far + (40.0 if mode == "beyond_plane" else -36.0)
	var wall_x := wall * axis.x
	var edge := wall_x + axis.x * 8.0
	var x0 := minf(wall_x, edge)
	var x1 := maxf(wall_x, edge)
	w.terrain.setup({"size": [1600, 900], "rocks": [[[x0, 0], [x1, 0],
		[x1, 900], [x0, 900]]]})


func _clerk(side: int, axis: Vector2, mode: String) -> float:
	var c := _square(LegionCfg.KIND_CLERK, side)
	var before := w.role_release_geometry(c, 0, axis, 1.0, true)
	var center: Vector2 = before["center"]
	var depth := float(before["depth"])
	var far := center.dot(axis) + depth
	_wall(mode, far, axis)
	var g := w.role_release_geometry(c, 0, axis, 1.0, true)
	var origins: PackedVector2Array = g["origins"]
	var ends: PackedVector2Array = g["ends"]
	var correct_ends := true
	var shared_clear := depth
	var front := origins[0]
	for i in origins.size():
		var p := origins[i]
		var projected := (p - center).dot(axis)
		var remaining := maxf(0.0, depth - projected)
		var run := LegionRoleRelease.clear_fire(w, p, axis, remaining)
		shared_clear = minf(shared_clear, projected + run)
		correct_ends = correct_ends and ends[i].distance_to(p + axis * run) < 0.001
		if p.dot(axis) > front.dot(axis):
			front = p
	var label := "сторона %d/ось %s/%s" % [side, axis, mode]
	_check(c.figure == ContractShape.SQUARE and origins.size() == 4,
		"%s: настоящая фигура с разными проекциями четырёх стрелков" % label)
	_check(bool(g["blocked"]) == (mode == "inside_plane"),
		"%s: только стена внутри общей полосы включает предупреждение" % label)
	_check(is_equal_approx(float(g["clear_depth"]), shared_clear),
		"%s: clear_depth отсчитывается от общей ближней плоскости" % label)
	_check(correct_ends, "%s: endpoints заканчиваются у общей дальней плоскости или реальной стены"
		% label)
	var at := center + axis * (depth - 12.0)
	at += axis.orthogonal() * (front - center).dot(axis.orthogonal())
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = f.hp
	f.def = f.def.duplicate()
	f.def["dmg"] = 0.0
	var seg := -1
	for p in c.posts:
		if (p["pos"] as Vector2).is_equal_approx(front):
			seg = int(p["seg"])
			break
	_check(LegionRoleRelease.strike_clear(w, c, seg, axis, depth, [f], g)
		== (mode != "inside_plane"), "%s: прицел видит только доступную цель" % label)
	w.figures.release(c, 1.0, false, axis)
	var jobs := LegionRoleRelease.jobs(w)
	var job := jobs[0]
	_check(jobs.size() == 1 and (job["center"] as Vector2).distance_to(center) < 0.001,
		"%s: действующий вал использует ту же общую плоскость" % label)
	_check(bool(job["blocked"]) == bool(g["blocked"])
		and is_equal_approx(float(job["clear_depth"]), float(g["clear_depth"])),
		"%s: metadata действующего приказа согласована с прицелом" % label)
	for i in 75:
		w._step(DT)
	var damage := f.max_hp - f.hp
	_check(int(job["band"]) == LegionCfg.CLERK_BARRAGE_BANDS,
		"%s: приказ выпускает все конечные полосы" % label)
	print("  CLERK PLANE %s blocked=%s clear=%.3f damage=%.3f"
		% [label, g["blocked"], g["clear_depth"], damage])
	return damage


func _guard(side: int, axis: Vector2, mode: String) -> void:
	var c := _square(LegionCfg.KIND_GUARD, side)
	var before := w.role_release_geometry(c, 0, axis, 1.0, true)
	var depth := float(before["depth"])
	_wall(mode, (before["center"] as Vector2).dot(axis) + depth, axis)
	var g := w.role_release_geometry(c, 0, axis, 1.0, true)
	var origins: PackedVector2Array = g["origins"]
	var ends: PackedVector2Array = g["ends"]
	var clear := depth
	for p in origins:
		clear = minf(clear, LegionRoleRelease.clear_run(w, p, axis, depth))
	var old_translation := true
	for i in origins.size():
		old_translation = old_translation and ends[i].distance_to(origins[i] + axis * clear) < 0.001
	_check(old_translation and is_equal_approx(float(g["clear_depth"]), clear)
		and bool(g["blocked"]) == (clear + LegionCfg.GUARD_FRONT_STEP < depth),
		"сторона %d/ось %s/%s: геометрия вахтёров сохраняет общий перевод каждого тела"
		% [side, axis, mode])


func _run() -> void:
	Campaign.set_save_path("user://legion_clerk_geometry_test.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	for side in 2:
		for axis: Vector2 in [Vector2.RIGHT, Vector2.LEFT]:
			var no_wall := _clerk(side, axis, "no_wall")
			var beyond := _clerk(side, axis, "beyond_plane")
			var inside := _clerk(side, axis, "inside_plane")
			_check(no_wall > 0.0 and is_equal_approx(no_wall, beyond) and inside == 0.0,
				"сторона %d/ось %s: внешняя стена не меняет урон, внутренняя закрывает огонь"
				% [side, axis])
			for mode: String in ["no_wall", "beyond_plane", "inside_plane"]:
				_guard(side, axis, mode)
	Campaign.reset()
	for s in w.sides:
		s.items.effects.items = null
	w.queue_free()
	await process_frame
	print("LEGION CLERK GEOMETRY: %d/%d OK" % [_checks - _fails, _checks])
	quit(int(_fails > 0))
