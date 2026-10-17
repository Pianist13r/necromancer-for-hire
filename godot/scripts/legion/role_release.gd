class_name LegionRoleRelease
extends RefCounted
## Общая команда хранится в уже сериализуемом залпе: никто не ищет себе маршрут после срыва.
## Живые участники держат исходные смещения; потеря бойца оставляет дыру, а не перестроение.


static func pull_power(kind: StringName, length: float) -> float:
	if kind == LegionCfg.KIND_LABORER:
		return 1.0
	return clampf((length - LegionCfg.SLING_ARM)
		/ (LegionCfg.ROLE_PULL_FULL - LegionCfg.SLING_ARM), 0.0, 1.0)


static func geometry(w: LegionWorld, c: Contract, seg: int, dir: Vector2,
		power := -1.0, cohesive := false) -> Dictionary:
	var origins := PackedVector2Array()
	var facings := PackedVector2Array()
	for p in c.posts:
		if (not cohesive and int(p["seg"]) != seg) or bool(p["dead"]):
			continue
		var u := _member(p["unit"])
		if u != null and u.alive and u.state == Legionnaire.State.POSTED:
			origins.append(u.position)
			facings.append(p["normal"])
	if origins.is_empty():
		for p in c.posts:
			if (cohesive or int(p["seg"]) == seg) and not bool(p["dead"]):
				origins.append(p["pos"])
				facings.append(p["normal"])
	var center := c.seg_center(seg)
	var axis := dir.normalized() if not dir.is_zero_approx() else c.seg_dir(seg)
	var facing := c.seg_dir(seg)
	var depth := depth_for(c.kind, power)
	# Кольцо и геометрия обряда не проходят насквозь через свою середину.
	if c.ring and not c.ring_out:
		depth = minf(depth, center.distance_to(c.center) + ContractShape.RING_OVERRUN)
	elif not cohesive and c.figure == ContractShape.TRIANGLE and power < 0.0 \
			and dir.is_equal_approx(facing):
		depth = minf(depth, center.distance_to(c.center) + FigureCfg.RITE_OVERRUN)
	elif not cohesive and c.figure == ContractShape.EIGHT and power < 0.0 \
			and dir.is_equal_approx(facing):
		depth = minf(depth, center.distance_to(c.lobes[1 - c.lobe_at(minf(c.length,
			(seg + 0.5) * LegionCfg.SEG_LEN))])
			+ FigureCfg.EIGHT_OVERRUN)
	var g := {"role": c.kind, "dir": axis, "facing": facing, "center": center,
		"depth": depth, "duration": duration_for(c.kind), "origins": origins,
		"facings": facings, "cohesive": cohesive}
	return _finish_geometry(w, g)


static func depth_for(kind: StringName, power: float) -> float:
	match kind:
		LegionCfg.KIND_GUARD:
			return LegionCfg.GUARD_FRONT_DEFAULT if power < 0.0 else lerpf(
				LegionCfg.GUARD_FRONT_DEPTH.x, LegionCfg.GUARD_FRONT_DEPTH.y, power)
		LegionCfg.KIND_CLERK:
			return LegionCfg.CLERK_BARRAGE_DEFAULT if power < 0.0 else lerpf(
				LegionCfg.CLERK_BARRAGE_DEPTH.x, LegionCfg.CLERK_BARRAGE_DEPTH.y, power)
	return float(LegionCfg.UNIT_KINDS[kind]["charge_dist"]) * (1.0 if power < 0.0 else
		lerpf(LegionCfg.SLING_RANGE.x, LegionCfg.SLING_RANGE.y, power))


static func duration_for(kind: StringName) -> float:
	if kind == LegionCfg.KIND_GUARD:
		return LegionCfg.GUARD_FRONT_TIME
	return LegionCfg.CLERK_BARRAGE_WINDUP \
		+ LegionCfg.CLERK_BARRAGE_INTERVAL * LegionCfg.CLERK_BARRAGE_BANDS


static func _finish_geometry(w: LegionWorld, g: Dictionary) -> Dictionary:
	var dir: Vector2 = g["dir"]
	var depth := float(g["depth"])
	var origins: PackedVector2Array = g["origins"]
	var center: Vector2 = g["center"]
	if not origins.is_empty():
		center = Vector2.ZERO
		var near := INF
		for p in origins:
			center += p
			near = minf(near, p.dot(dir))
		center /= origins.size()
		center += dir * (near - center.dot(dir))
	g["center"] = center
	var kind: StringName = g["role"]
	var half_w := 0.0
	var clear := depth
	var ends := PackedVector2Array()
	for p in origins:
		half_w = maxf(half_w, absf((p - center).dot(dir.orthogonal())))
		# Общий огневой вал кончается у одной плоскости, а не на depth перед каждым стрелком.
		var projected := (p - center).dot(dir) if kind == LegionCfg.KIND_CLERK else 0.0
		var remaining := maxf(0.0, depth - projected)
		var limit := clear_fire(w, p, dir, remaining) if kind == LegionCfg.KIND_CLERK \
			else clear_run(w, p, dir, depth)
		clear = minf(clear, projected + limit)
		ends.append(p + dir * limit)
	if kind == LegionCfg.KIND_GUARD:
		for i in origins.size():
			ends[i] = origins[i] + dir * clear
	half_w += LegionCfg.CLERK_BARRAGE_LANE_PAD if kind == LegionCfg.KIND_CLERK \
		else LegionCfg.UNIT_RADIUS
	g["ends"] = ends
	g["half_w"] = half_w
	g["clear_depth"] = clear
	g["blocked"] = clear + LegionCfg.GUARD_FRONT_STEP < depth
	return g


static func clear_run(w: LegionWorld, at: Vector2, dir: Vector2, depth: float) -> float:
	var run := 0.0
	while run < depth:
		var next := minf(depth, run + LegionCfg.GUARD_FRONT_STEP)
		var p := at + dir * next
		if not w.terrain.walkable(p) or w.terrain.is_rock(p) \
				or not _edge_clear(at, p, w.world_size):
			return run
		run = next
	return depth


## Вода ограничивает перевод ног, но не огонь. Непрозрачные стены и скалы закрывают полосу.
static func clear_fire(w: LegionWorld, at: Vector2, dir: Vector2, depth: float) -> float:
	var run := 0.0
	while run < depth:
		var next := minf(depth, run + LegionCfg.GUARD_FRONT_STEP)
		var p := at + dir * next
		if w.terrain.is_rock(p) or not _edge_clear(at, p, w.world_size):
			return run
		run = next
	return depth


static func _edge_clear(before: Vector2, after: Vector2, size: Vector2) -> bool:
	var old := Legionnaire._edge_out(before, size)
	var now := Legionnaire._edge_out(after, size)
	return now.x <= old.x + 0.001 and now.y <= old.y + 0.001


static func strike_clear(w: LegionWorld, c: Contract, seg: int, dir: Vector2,
		depth: float, zone: Array[Foe], g: Dictionary = {}) -> bool:
	if g.is_empty():
		g = geometry(w, c, seg, dir)
	var center: Vector2 = g["center"]
	for f in zone:
		if not f.is_active() or (f.ghost and c.kind == LegionCfg.KIND_GUARD):
			continue
		for p in c.posts:
			var u := _member(p["unit"])
			if int(p["seg"]) != seg or u == null or u.state != Legionnaire.State.POSTED:
				continue
			var d := f.position - u.position
			var along := (f.position - center).dot(dir) if c.kind == LegionCfg.KIND_CLERK \
				else d.dot(dir)
			var lateral := absf(d.dot(dir.orthogonal()))
			var lane := LegionCfg.CLERK_BARRAGE_LANE_PAD if c.kind == LegionCfg.KIND_CLERK \
				else u._reach()
			# Общая плоскость полос задаёт очередь огня, но каждый стреляет только вперёд.
			if c.kind == LegionCfg.KIND_CLERK and d.dot(dir) < -f.radius:
				continue
			if along < -f.radius or along > depth + f.radius or lateral > lane + f.radius:
				continue
			var travel := maxf(0.0, along - (u._reach() + f.radius)) \
				if c.kind == LegionCfg.KIND_GUARD else maxf(0.0, d.dot(dir))
			var clear := float(g["clear_depth"]) if c.kind == LegionCfg.KIND_GUARD \
				else clear_fire(w, u.position, dir, travel)
			if clear + 0.001 >= travel:
				return true
	return false


static func attach(w: LegionWorld, u: Legionnaire, volley: Dictionary,
		g: Dictionary = {}, facing := Vector2.ZERO) -> void:
	if u.kind == LegionCfg.KIND_LABORER:
		return
	var job: Dictionary = volley.get("role_job", {})
	if job.is_empty():
		if g.is_empty():
			g = {"role": u.kind, "dir": u._charge_dir, "facing": u._charge_dir,
				"center": u.position, "origins": PackedVector2Array([u.position]),
				"depth": minf(depth_for(u.kind, float(volley.get("input_power", -1.0))),
					u._charge_cap), "duration": duration_for(u.kind)}
			g = _finish_geometry(w, g)
		var group: Dictionary = volley.get("group", {})
		var jobs: Array = group.get("role_jobs", [])
		g["cohesive"] = volley.has("axis")
		# Одним жестом параллельные участки — один фронт. Радиальные стороны фигур различны.
		for other: Dictionary in jobs:
			if other["role"] == g["role"] and (other["dir"] as Vector2).is_equal_approx(g["dir"]) \
					and ((bool(g["cohesive"]) and bool(other.get("cohesive", false))) \
					or (other["facing"] as Vector2).is_equal_approx(g["facing"])):
				job = other
				break
		if job.is_empty():
			job = g.duplicate(true)
			job.merge({"members": [], "origins": PackedVector2Array(), "elapsed": 0.0,
				"facings": PackedVector2Array(), "run": 0.0, "band": 0, "hits": {},
				"blocked": false, "side": u.side}, true)
			jobs.append(job)
			if not group.is_empty():
				group["role_jobs"] = jobs
		volley["role_job"] = job
		# Глубина меняет место команды; ущерб остаётся прежним, включая пружину и точный срыв.
		volley["dmg"] = float(volley["dmg"]) / lerpf(LegionCfg.SLING_DMG.x,
			LegionCfg.SLING_DMG.y, maxf(0.0, float(volley.get("input_power", -1.0))))
	(job["members"] as Array).append(u)
	var origins: PackedVector2Array = job["origins"]
	origins.append(u.position)
	job["origins"] = origins
	var facings: PackedVector2Array = job["facings"]
	facings.append(facing if not facing.is_zero_approx() else g.get("facing", u._charge_dir))
	job["facings"] = facings
	job["depth"] = minf(float(job["depth"]), float(g.get("depth", job["depth"])))
	_finish_geometry(w, job)
	u._charge_t = float(job["duration"])
	u.role_recruit_hold_t = LegionCfg.ROLE_COMMAND_HOLD


static func jobs(w: LegionWorld) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for u in w.units:
		if not u.alive or u.state != Legionnaire.State.CHARGE or not u._volley.has("role_job"):
			continue
		var job: Dictionary = u._volley["role_job"]
		var seen := false
		for old in out:
			seen = seen or is_same(job, old)
		if not seen:
			out.append(job)
	return out


static func tick(w: LegionWorld, dt: float) -> void:
	for job in jobs(w):
		job["elapsed"] = float(job["elapsed"]) + dt
		if job["role"] == LegionCfg.KIND_GUARD:
			_tick_front(w, job, dt)
		else:
			_tick_barrage(w, job)
		if float(job["elapsed"]) + 0.00001 >= float(job["duration"]):
			_end(job)


static func _live(u: Legionnaire, job: Dictionary) -> bool:
	return is_instance_valid(u) and u.alive and u.state == Legionnaire.State.CHARGE \
		and is_same(u._volley.get("role_job", {}), job)


## В общем приказе павший оставляет исходное место. Его Node уже может быть снят из мира;
## проверяем Variant до приведения типа, иначе Godot выбрасывает ошибку на самом присваивании.
static func _member(value: Variant) -> Legionnaire:
	return value as Legionnaire if is_instance_valid(value) else null


static func facing_of(u: Legionnaire) -> Vector2:
	var job: Dictionary = u._volley["role_job"]
	var i := (job["members"] as Array).find(u)
	return (job["facings"] as PackedVector2Array)[i] if i >= 0 else job["facing"]


static func _tick_front(w: LegionWorld, job: Dictionary, dt: float) -> void:
	var members: Array = job["members"]
	var origins: PackedVector2Array = job["origins"]
	var facings: PackedVector2Array = job["facings"]
	var dir: Vector2 = job["dir"]
	var force := 0.0
	var speed := INF
	job["blocked"] = false
	for value: Variant in members:
		var u := _member(value)
		if not _live(u, job):
			continue
		force += LegionCfg.GUARD_FRONT_FORCE
		speed = minf(speed, float(u.spec["speed"]) * u._item_speed()
			* LegionCfg.CHARGE_SPEED_MULT * w.mod_mult("charge_speed_mult")
			* w.terrain.speed_mult(u.position))
	var mass := 0.0
	var flank := 0.0
	var contacts: Array[Node2D] = []
	for target in _targets(w, int(job["side"]), false):
		var closest: Legionnaire = null
		var facing := Vector2.ZERO
		var distance := INF
		for i in members.size():
			var u := _member(members[i])
			if _live(u, job):
				var d := u.position.distance_squared_to(target.position)
				if d < distance:
					distance = d
					closest = u
					facing = facings[i]
		if closest == null or distance > pow(Legionnaire.body_r(target)
				+ LegionCfg.UNIT_RADIUS + LegionCfg.GUARD_FRONT_CONTACT_PAD, 2):
			continue
		var toward := (target.position - closest.position).normalized()
		var weight := _mass(target)
		if toward.dot(facing) < LegionCfg.GUARD_FRONT_FACING_DOT:
			flank += weight
		# Противник на пути тела ограничивает перевод и при отходе/сдвиге боком.
		# Личная ориентация щита отдельно определяет уязвимость и давление с фланга.
		if toward.dot(dir) > LegionCfg.GUARD_FRONT_FACING_DOT:
			mass += weight
			contacts.append(target)
			if weight >= LegionCfg.GUARD_FRONT_HEAVY:
				job["blocked"] = true
	var factor := force / maxf(force + mass, 0.001)
	factor *= maxf(0.0, 1.0 - flank * LegionCfg.GUARD_FRONT_FLANK_DRAG / maxf(force, 0.001))
	var step := minf(speed * factor * dt, float(job["depth"]) - float(job["run"]))
	if bool(job["blocked"]) or step <= 0.0:
		step = 0.0
	var left := step
	var before := float(job["run"])
	while left > 0.0:
		var part := minf(left, LegionCfg.GUARD_FRONT_STEP)
		var offset := dir * (float(job["run"]) + part)
		var clear := true
		for i in members.size():
			var u := _member(members[i])
			if _live(u, job):
				var p := origins[i] + offset
				clear = clear and w.terrain.walkable(p) and not w.terrain.is_rock(p) \
					and _edge_clear(u.position, p, w.world_size)
		for target in contacts:
			clear = clear and _can_push(w, target, dir * part)
		if not clear:
			job["blocked"] = true
			break
		for target in contacts:
			_push(target, dir * part)
			# Урок наблюдает реальное смещение, не меняя приказ или численные правила боя.
			if w.tutorial != null and w.tutorial.guard_lesson != null:
				w.tutorial.guard_lesson.observe(job, target, dir * part)
		job["run"] = float(job["run"]) + part
		left -= part
	job["moving"] = float(job["run"]) > before
	for i in members.size():
		var u := _member(members[i])
		if _live(u, job):
			u.position = origins[i] + dir * float(job["run"])
			u._charge_run = float(job["run"])
			u._charge_t = maxf(0.0, float(job["duration"]) - float(job["elapsed"]))
			u._face(facings[i])
			var target := u._target_near(u._reach() + LegionCfg.CORE_FOE_RADIUS_MAX, false)
			if target != null and u._in_reach(target):
				u.strike_release_target(target)
				u._face(facings[i])


static func _targets(w: LegionWorld, side: int, ghosts: bool) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for f in w.foes:
		if f.is_active() and (ghosts or not f.ghost):
			out.append(f)
	if w.pvp:
		for u in w.units:
			if u.alive and u.side != side:
				out.append(u)
		for s in w.sides:
			if s.index != side and s.alive():
				out.append(s.staff.cauldron)
	return out


static func _mass(target: Node2D) -> float:
	if target is Foe:
		return float(LegionCfg.PRESS_MASS.get((target as Foe).type_id, LegionCfg.PRESS_MASS_DEFAULT))
	if target is Legionnaire:
		return LegionCfg.GUARD_FRONT_FORCE \
			if (target as Legionnaire).kind == LegionCfg.KIND_GUARD else 1.0
	return LegionCfg.GUARD_FRONT_HEAVY


static func _can_push(w: LegionWorld, target: Node2D, move: Vector2) -> bool:
	if _mass(target) >= LegionCfg.GUARD_FRONT_HEAVY:
		return false
	if target is Legionnaire:
		var u := target as Legionnaire
		if u.kind == LegionCfg.KIND_GUARD and u.role_command_active():
			return false
	var to := target.position + move
	return w.terrain.walkable(to) and not w.terrain.is_rock(to) \
		and _edge_clear(target.position, to, w.world_size)


static func _push(target: Node2D, move: Vector2) -> void:
	if target is Legionnaire:
		var u := target as Legionnaire
		# Чужой строй теряет место, когда фронт действительно вытеснил его с позиции.
		if u.state in [Legionnaire.State.POSTED, Legionnaire.State.MARCH] \
				or u.role_command_active():
			u.set_free()
			u.role_recruit_hold_t = LegionCfg.ROLE_COMMAND_HOLD
	target.position += move


static func _tick_barrage(w: LegionWorld, job: Dictionary) -> void:
	var band := int(job["band"])
	while band < LegionCfg.CLERK_BARRAGE_BANDS and float(job["elapsed"]) >= \
			LegionCfg.CLERK_BARRAGE_WINDUP + band * LegionCfg.CLERK_BARRAGE_INTERVAL:
		_fire_band(w, job, band)
		band += 1
	job["band"] = band
	for value: Variant in job["members"]:
		var u := _member(value)
		if _live(u, job):
			u._charge_t = maxf(0.0, float(job["duration"]) - float(job["elapsed"]))
			u._face(job["dir"])


static func _fire_band(w: LegionWorld, job: Dictionary, band: int) -> void:
	var members: Array = job["members"]
	var origins: PackedVector2Array = job["origins"]
	var axis: Vector2 = job["dir"]
	var depth := float(job["depth"])
	var lo := depth * band / LegionCfg.CLERK_BARRAGE_BANDS
	var hi := depth * (band + 1) / LegionCfg.CLERK_BARRAGE_BANDS
	var center: Vector2 = job["center"]
	var hits: Dictionary = job["hits"]
	for target in _targets(w, int(job["side"]), true):
		if hits.has(target):
			continue
		var shooter: Legionnaire = null
		var best := INF
		for i in members.size():
			var u := _member(members[i])
			if not _live(u, job):
				continue
			var d := target.position - origins[i]
			var along := (target.position - center).dot(axis)
			var lateral := absf(d.dot(axis.orthogonal()))
			var radius := Legionnaire.body_r(target)
			if d.dot(axis) < -radius or along < lo - radius or along > hi + radius \
					or lateral > LegionCfg.CLERK_BARRAGE_LANE_PAD + radius or lateral >= best:
				continue
			var travel := maxf(0.0, d.dot(axis))
			if clear_fire(w, origins[i], axis, travel) + 0.001 < travel:
				continue
			best = lateral
			shooter = u
		if shooter != null:
			# Отметка — при выпуске, а не по прилёту: HP цели меняется только после полёта печати,
			# и следующая полоса того же вала не должна послать в неё второй выстрел.
			hits[target] = true
			shooter._atk_cd = 0.0
			shooter.strike_release_target(target, true)


static func _end(job: Dictionary) -> void:
	for value: Variant in job["members"]:
		var u := _member(value)
		if _live(u, job):
			u._end_charge()
			u.role_recruit_hold_t = LegionCfg.ROLE_COMMAND_HOLD


static func draw(w: LegionWorld, ci: CanvasItem) -> void:
	for job in jobs(w):
		if job["role"] == LegionCfg.KIND_CLERK:
			# B-494: прежний бегущий фронт полос показывал зону, но не выстрел и попадание.
			# Огневой вал виден настоящими печатями и вспышками попаданий (LegionProjectiles).
			continue
		var axis: Vector2 = job["dir"]
		var color: Color = LegionCfg.UNIT_KINDS[job["role"]]["color"]
		color.a = LegionCfg.ROLE_DRAW_ALPHA
		var origins: PackedVector2Array = job["origins"]
		var members: Array = job["members"]
		var run := float(job["run"])
		for i in members.size():
			var u := _member(members[i])
			if not _live(u, job):
				continue
			var p := origins[i] + axis * run
			if bool(job["blocked"]):
				color = LegionCfg.PRESS_COLOR
			ci.draw_line(origins[i], p, Color(color, 0.15), LegionCfg.ROLE_DRAW_LINE, true)
			ci.draw_line(p - axis.orthogonal() * LegionCfg.CLERK_BARRAGE_LANE_PAD,
				p + axis.orthogonal() * LegionCfg.CLERK_BARRAGE_LANE_PAD,
				color, LegionCfg.ROLE_DRAW_LINE, true)
			if job["role"] == LegionCfg.KIND_GUARD and i > 0 \
					and _live(_member(members[i - 1]), job):
				ci.draw_line(_member(members[i - 1]).position, u.position, color,
					LegionCfg.ROLE_DRAW_LINE, true)
