class_name AmendmentRuntime
extends Node2D
## Только одиночный бой: собственные часы и рисунок, без артефактных counts/таймеров.

const GHOST_LIMIT := 18
const GHOST_TICK := 0.25
const COLOR := Color(0.65, 0.78, 1.0)
var world: LegionWorld
var rules: Dictionary = {}
var _queue_cd := 0.0
var _echoes: Array[Dictionary] = []
var _ghosts: Array[Dictionary] = []
var _flashes: Array[Dictionary] = []
var _vassals: Dictionary = {}


func setup(w: LegionWorld) -> void:
	reset()
	world = w
	if w.pvp or not w.in_campaign:
		return
	rules = Campaign.active_rules()
	w.unit_died.connect(_on_unit_died)
	w.segment_released.connect(_on_segment_released)
	w.hero_cast.connect(_on_cast)
	w.foe_killed.connect(_on_foe_killed)


func reset() -> void:
	if is_instance_valid(world):
		for entry: Array in [[world.unit_died, _on_unit_died],
				[world.segment_released, _on_segment_released],
				[world.hero_cast, _on_cast], [world.foe_killed, _on_foe_killed]]:
			var event: Signal = entry[0]
			var handler: Callable = entry[1]
			if event.is_connected(handler):
				event.disconnect(handler)
	rules.clear()
	_queue_cd = 0.0
	_echoes.clear()
	_ghosts.clear()
	_flashes.clear()
	_vassals.clear()
	queue_redraw()


func _exit_tree() -> void:
	reset()


func _count(key: String, amount := 1.0) -> void:
	world.stats[key] = float(world.stats.get(key, 0.0)) + amount


func _flash(at: Vector2, text: String, color := COLOR) -> void:
	_flashes.append({"pos": at, "t": 0.8, "text": text, "color": color})
	if world.hud != null:
		world.hud.toast(text, &"info", 1.6)


func _on_unit_died(u: Legionnaire) -> void:
	if not rules.has("queue") or _queue_cd > 0.0 or u.side != 0:
		return
	var home := u.home as LegionBuilding
	if not is_instance_valid(home) or home.frozen or home.cap <= 0 \
			or world.army_alive() >= LegionCfg.ARMY_HARD_CAP:
		return
	var slot := home._waiting_slot()
	if slot < 0:
		return
	_queue_cd = float(rules["queue"]["cd"])
	home._spawn_into(slot, true)
	_count("amendment_replacements")
	_flash(home.entry, "Живая очередь: замена вышла", AmendmentDb.color(&"living_queue"))


func _on_segment_released(c: Contract, seg: int, _units: int) -> void:
	if not rules.has("ghost") or c == null or c.owner_side != 0 \
			or c.release_causes.get(seg, &"") != &"melt" or _ghosts.size() >= GHOST_LIMIT:
		return
	var poly := c.seg_polys[seg] if seg < c.seg_polys.size() else PackedVector2Array()
	if poly.size() < 2:
		return
	var p: Dictionary = rules["ghost"]
	_ghosts.append({"a": poly[0], "b": poly[poly.size() - 1], "t": float(p["t"]),
		"t0": float(p["t"]), "tick": 0.0})
	_count("amendment_ghosts")
	if int(world.stats.get("amendment_ghosts", 0)) <= 2:
		_flash(c.seg_center(seg), "Договор с привидением: ещё 3 с")


func _on_cast(slot: int, _at: Vector2) -> void:
	if slot == LegionHero.SLOT_Q and rules.has("echo"):
		var hits: Array = world.hero.last_cast.get("hits", [])
		if hits.is_empty():
			return
		var pos: Vector2 = hits[0]["pos"]
		var target: Foe = null
		for foe: Foe in world.foes_near(pos, 6.0):
			if foe.alive and (target == null or foe.position.distance_squared_to(pos)
					< target.position.distance_squared_to(pos)):
				target = foe
		if target != null:
			_echoes.append({"target": target, "t": float(rules["echo"]["delay"]),
				"damage": float(hits[0]["dmg"]) * float(rules["echo"]["frac"])})
	if slot == LegionHero.SLOT_W and rules.has("vassal_march"):
		for v: Node2D in world.hero._vassals:
			if is_instance_valid(v) and not _vassals.has(v):
				_vassals[v] = {"path": PackedVector2Array(), "refresh": 0.0}
				v.retint(Color(0.8, 1.0, 0.55))


## E-1005 (ошибка 3): призванные (свита Прораба, метка summoned) маны не платят — как у всех
## прочих потребителей убийств (staff.on_foe_killed, souls_counter, «Душеприказчик», комбо-души);
## без этой отсечки на волне с призывом мана за головы была бесконечной.
func _on_foe_killed(f: Foe, _pos: Vector2) -> void:
	if not rules.has("dividend") or (f != null and f.has_meta(&"summoned")):
		return
	var field := world.contracts
	var restored := minf(float(rules["dividend"]["mana"]), field.mana_max - field.mana)
	field.mana += restored
	_count("amendment_mana", restored)


func _damage(f: Foe, amount: float, at: Vector2) -> void:
	if not is_instance_valid(f) or not f.alive:
		return
	var before := f.hp
	f.last_hit_side = 0
	f.take_damage(amount, at)
	_count("amendment_damage", maxf(0.0, before - maxf(0.0, f.hp)))


func tick(dt: float) -> void:
	if not is_instance_valid(world) or world.pvp or rules.is_empty():
		return
	_queue_cd = maxf(0.0, _queue_cd - dt)
	for i in range(_echoes.size() - 1, -1, -1):
		_echoes[i]["t"] = float(_echoes[i]["t"]) - dt
		if float(_echoes[i]["t"]) <= 0.0:
			var echo := _echoes[i]
			_echoes.remove_at(i)
			var target := echo["target"] as Foe
			if is_instance_valid(target) and target.alive:
				_damage(target, float(echo["damage"]), target.position)
				_count("amendment_echoes")
				_flash(target.position, "Копия верна: молния бьёт ещё раз")
	_tick_ghosts(dt)
	_tick_vassals(dt)
	for i in range(_flashes.size() - 1, -1, -1):
		_flashes[i]["t"] = float(_flashes[i]["t"]) - dt
		if float(_flashes[i]["t"]) <= 0.0:
			_flashes.remove_at(i)
	queue_redraw()


## E-1005 (ошибка 9): синергия «Горячая линия» (ghost_burn) жжёт и призрак ПОПРАВКИ, не только
## артефактной «Пролонгации» — иначе текст синергии врал для половины призраков.
func _tick_ghosts(dt: float) -> void:
	var burn := 1.0
	if world.items != null:
		burn += world.items.value(&"ghost_burn")
	for i in range(_ghosts.size() - 1, -1, -1):
		var ghost := _ghosts[i]
		ghost["t"] = float(ghost["t"]) - dt
		ghost["tick"] = float(ghost["tick"]) - dt
		if float(ghost["tick"]) <= 0.0:
			ghost["tick"] = GHOST_TICK
			var a: Vector2 = ghost["a"]
			var b: Vector2 = ghost["b"]
			for f: Foe in world.foes_near((a + b) * 0.5, a.distance_to(b) * 0.5 + 18.0):
				if f.alive and Geometry2D.get_closest_point_to_segment(f.position, a, b) \
						.distance_to(f.position) <= 18.0:
					_damage(f, float(rules["ghost"]["dps"]) * burn * GHOST_TICK, (a + b) * 0.5)
					f.seal_slow_t = maxf(f.seal_slow_t, float(rules["ghost"]["slow"]))
		if float(ghost["t"]) <= 0.0:
			_ghosts.remove_at(i)


func _tick_vassals(dt: float) -> void:
	if not rules.has("vassal_march"):
		return
	for v: Variant in _vassals.keys():
		if not is_instance_valid(v) or v.is_queued_for_deletion():
			_vassals.erase(v)
			continue
		var p: Dictionary = rules["vassal_march"]
		var at: Vector2 = v.position
		var nearest: Foe = null
		for f: Foe in world.foes_near(at, float(p["seek"])):
			if f.alive and (nearest == null or at.distance_squared_to(f.position)
					< at.distance_squared_to(nearest.position)):
				nearest = f
		if nearest == null:
			continue
		var travel := at.distance_to(nearest.position) - LegionCfg.W_RADIUS * 0.7
		if travel > 0.0:
			var route: Dictionary = _vassals[v]
			route["refresh"] = float(route["refresh"]) - dt
			if float(route["refresh"]) <= 0.0:
				route["path"] = world.terrain.find_path(at, nearest.position)
				route["refresh"] = 0.7
			var path: PackedVector2Array = route["path"]
			while not path.is_empty() and at.distance_to(path[0]) < 2.0:
				path.remove_at(0)
			route["path"] = path
			if path.is_empty():
				continue
			var speed := float(p["speed"]) * world.terrain.speed_mult(at)
			var step := minf(at.distance_to(path[0]), speed * dt)
			var proposed := at + at.direction_to(path[0]) * step
			var next := world.terrain.segment_clear(at, proposed)
			if world.terrain.walkable(next):
				v.position = next
				_count("amendment_vassal_steps", at.distance_to(next))


func _draw() -> void:
	for ghost in _ghosts:
		var a: Vector2 = ghost["a"]
		var b: Vector2 = ghost["b"]
		var alpha := minf(0.65, float(ghost["t"]) / float(ghost["t0"]))
		draw_line(a, b, Color(COLOR, alpha * 0.3), 32.0, true)
		draw_line(a, b, Color(COLOR, alpha), 2.0, true)
		var mid := (a + b) * 0.5
		draw_arc(mid, 14.0, -PI * 0.5, -PI * 0.5 + TAU * float(ghost["t"])
			/ float(ghost["t0"]), 18, Color(COLOR, alpha), 2.0)
	for echo in _echoes:
		var target := echo["target"] as Foe
		if is_instance_valid(target) and target.alive:
			draw_circle(target.position + Vector2(0, -24), 10.0, Color(COLOR, 0.25))
			draw_arc(target.position + Vector2(0, -24), 10.0, 0.0, TAU, 18, COLOR, 2.0)
	for flash in _flashes:
		var c: Color = flash["color"]
		c.a = float(flash["t"]) / 0.8
		draw_arc(flash["pos"], 18.0 + (1.0 - c.a) * 32.0, 0.0, TAU, 24, c, 2.0)
