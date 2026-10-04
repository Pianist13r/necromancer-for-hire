extends SceneTree
##
## Зеркальная равноправность сторон «Схватки» (P3, docs/dev/PVP_PLAN_0929.md):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_mirror_test.gd -- --mute
##
## Поле PvP — зеркало x' = W − x (PvpMaps.duel, PgPvp). Проверяет, что и ЛОГИКА видит его
## зеркальным: сетка рельефа, пути A* (ими ходят бойцы и строит линии бот), первые рубежи
## обороны бота и точка первой перебежки у стороны 1 — отражение того же у стороны 0.
## Итог «LEGION PVP MIRROR: N/M OK»; выход 1 при провале.
##

const SAVE := "user://legion_pvp_mirror_test.cfg"
const MAPS := ["pvp:duel", "gen:7:3:pvp", "gen:11:3:pvp", "gen:23:3:pvp"]

var w: LegionWorld
var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	for id: String in MAPS:
		_map(id)
	_swap()
	_order()
	_seg_count()
	Campaign.reset()
	print("LEGION PVP MIRROR: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _start(id: String) -> void:
	w.dev = {"spawn_units": "0", "no_waves": "1"}
	w.args["pvp_bots"] = true
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 5
	w.start_map(id)


func _mx(p: Vector2) -> Vector2:
	return Vector2(w.world_size.x - p.x, p.y)


func _near(a: Vector2, b: Vector2, eps := 0.5) -> bool:
	return a.distance_to(b) <= eps


func _map(id: String) -> void:
	print("— %s" % id)
	_start(id)
	_check(w.pvp and w.sides.size() == 2, id + ": матч двух сторон")
	if not w.pvp:
		return
	var s0: PvpSide = w.sides[0]
	var s1: PvpSide = w.sides[1]
	_check(_near(_mx(s0.cauldron_pos), s1.cauldron_pos), id + ": Котлы зеркальны")
	_grid(id)
	_paths(id, s0.cauldron_pos, s1.cauldron_pos)
	_bots(id)
	_slip(id)
	_spawns(id)
	_rally(id)
	_carriers(id)
	_road_rocks(id)
	_densest(id)


## B-365: линия длиной k·SEG_LEN с шумом float — k участков, а не k+1 (последний — нулевой
## длины). Штрих бота идёт шагами 8 px, и длина 256 = 4·64 у зеркальных линий половин давала
## то 4, то 5 участков.
func _seg_count() -> void:
	print("— участки линии ровно k·SEG_LEN")
	var bad := 0
	for x0: float in [97.31, 401.7, 1199.17, 1503.9]:
		for k in range(1, 5):
			var d := Vector2(0.6, 0.8)
			var pts := PackedVector2Array()
			for i in k * 8 + 1:
				pts.append(Vector2(x0, 120.0) + d * (LegionCfg.SEG_LEN / 8.0) * float(i))
			var c := Contract.new().build(pts, 1)
			if c.seg_count() != k:
				bad += 1
	_check(bad == 0, "участков у линии k·SEG_LEN ровно k (16 линий, несовпадений %d)" % bad)


## B-365: контуры скал (края у дорог вырезает Clipper) — is_rock зеркален и в сотых долях px от
## контура, а не только «по 4000 случайных точек»: щель в сотые доли px у двери площадки (gen:23,
## сид 2) была скалой слева и землёй справа и меняла рождение бойца.
func _road_rocks(id: String) -> void:
	var bad := 0
	var n := 0
	for poly in w.terrain.rocks:
		for i in poly.size():
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % poly.size()]
			var nrm := (b - a).orthogonal().normalized()
			for k in 8:
				for off: float in [-0.03, -0.01, 0.01, 0.03]:
					var p := a.lerp(b, (k + 0.5) / 8.0) + nrm * off
					if p.x <= 0.0 or p.x >= w.world_size.x or absf(p.x - w.world_size.x * 0.5) < 1.0:
						continue
					n += 1
					if w.terrain.is_rock(p) != w.terrain.is_rock(_mx(p)):
						bad += 1
	_check(bad == 0, id + ": скалы у самого контура зеркальны (%d точек, несовпадений %d)" % [n, bad])


## B-365: печать нотариуса бьёт в «самую плотную кучку» из первых SIGNER_SAMPLES·4 бойцов обхода
## сетки — у зеркальной толпы зеркальная точка (обход справа налево на правой половине).
func _densest(id: String) -> void:
	var c0 := w.sides[0].cauldron_pos
	var probe := RandomNumberGenerator.new()
	probe.seed = 43
	var made := 0
	while made < 90:
		var p := c0 + Vector2(probe.randf_range(-200.0, 200.0), probe.randf_range(-200.0, 200.0))
		if p.x < 20.0 or p.x > w.world_size.x * 0.5 - 20.0 or p.y < 20.0 \
				or p.y > w.world_size.y - 20.0:
			continue
		w.spawn_unit(LegionCfg.KIND_LABORER, p, null, 0)
		w.spawn_unit(LegionCfg.KIND_LABORER, _mx(p), null, 1)
		made += 1
	w.grid.rebuild()
	var bad := 0
	for k in 30:
		var at := c0 + Vector2(probe.randf_range(-150.0, 150.0), probe.randf_range(-150.0, 150.0))
		var a := w.grid.densest_unit_point(at, 260.0, 40.0)
		var b := w.grid.densest_unit_point(_mx(at), 260.0, 40.0)
		if (a == Vector2.INF) != (b == Vector2.INF) \
				or (a != Vector2.INF and not _near(_mx(a), b, 0.01)):
			bad += 1
	_check(bad == 0,
		id + ": точка печати нотариуса у зеркальной толпы зеркальна (30, несовпадений %d)" % bad)


## B-365: точка рождения у Котла стороны 1 при том же состоянии ГСЧ мира — отражение точки у
## Котла стороны 0 (смещение от входа общим ГСЧ раньше было одно и то же, не отражённое).
func _spawns(id: String) -> void:
	var b0: LegionBuilding = w.sides[0].staff.cauldron
	var b1: LegionBuilding = w.sides[1].staff.cauldron
	var bad := 0
	var first := ""
	for k in 40:
		var st := w.rng.state
		var p0: Vector2 = b0._spawn_point()
		w.rng.state = st
		var p1: Vector2 = b1._spawn_point()
		if not _near(_mx(p0), p1, 0.01):
			bad += 1
			if first == "":
				first = "%s и %s" % [p0, p1]
	_check(bad == 0, id + ": рождение у Котла зеркально (40 точек, несовпадений %d %s)" % [bad, first])


## B-365: «Сбор» зеркальной кучки к зеркальной точке ставит бойцов зеркально (подсолнух точек
## «Сбора» не симметричен — у стороны справа он отражается).
func _rally(id: String) -> void:
	var c0 := w.sides[0].cauldron_pos
	var c1 := w.sides[1].cauldron_pos
	var at := c0.lerp(c1, 0.2)
	at = w.terrain.nearest_open(at)
	var units: Array = [[], []]
	var probe := RandomNumberGenerator.new()
	probe.seed = 31
	while (units[0] as Array).size() < 12:
		var p := at + Vector2(probe.randf_range(-120.0, 120.0), probe.randf_range(-120.0, 120.0))
		if not w.terrain.walkable(p) or not w.terrain.walkable(_mx(p)) \
				or not w.terrain.connected(p, at):
			continue
		(units[0] as Array).append(w.spawn_unit(LegionCfg.KIND_LABORER, p, null, 0))
		(units[1] as Array).append(w.spawn_unit(LegionCfg.KIND_LABORER, _mx(p), null, 1))
	w.sides[0].rally_cd = 0.0
	w.sides[1].rally_cd = 0.0
	var n0 := w.rally(at, 0)
	var n1 := w.rally(_mx(at), 1)
	var bad := 0
	for i in (units[0] as Array).size():
		var a: Legionnaire = units[0][i]
		var b: Legionnaire = units[1][i]
		var ea := a._path[a._path.size() - 1] if not a._path.is_empty() else Vector2.INF
		var eb := b._path[b._path.size() - 1] if not b._path.is_empty() else Vector2.INF
		if ea == Vector2.INF or eb == Vector2.INF or not _near(_mx(ea), eb, 0.01):
			bad += 1
	_check(n0 == 12 and n1 == 12 and bad == 0,
		id + ": «Сбор» ставит зеркальную кучку зеркально (позвал %d и %d, несовпадений %d)" % [
		n0, n1, bad])


## B-365: носители артефакта сторон рождаются и идут зеркально: «домашний» на дороге стыка, чей
## первый узел — сама ось поля, и спорный у прохода стыка.
func _carriers(id: String) -> void:
	for contested: bool in [false, true]:
		var f0: Foe = w._spawn_pvp_carrier(0, contested)
		var f1: Foe = w._spawn_pvp_carrier(1, contested)
		var ok := f0 != null and f1 != null and _near(_mx(f0.position), f1.position, 0.01)
		var why := "нет носителя"
		if f0 != null and f1 != null:
			why = "%s и %s" % [f0.position, f1.position]
			var pa := f0._path
			var pb := f1._path
			ok = ok and pa.size() == pb.size()
			for i in mini(pa.size(), pb.size()):
				ok = ok and _near(_mx(pa[i]), pb[i], 0.01)
			ok = ok and (f0.position.x < w.world_size.x * 0.5) \
				== (w.sides[0].cauldron_pos.x < w.world_size.x * 0.5)
		for f: Foe in [f0, f1]:
			if f != null:
				f.vanish()
		_check(ok, id + ": носитель %s зеркален и на своей половине (%s)" % [
			"спорный" if contested else "домашний", why])


## Сетка рельефа: флаги клетки (x, y) и (cols − 1 − x, y) равны.
func _grid(id: String) -> void:
	var t := w.terrain
	var bad := 0
	var first := ""
	for y in t.rows:
		for x in t.cols:
			var a: int = t._flags[y * t.cols + x]
			var b: int = t._flags[y * t.cols + t.cols - 1 - x]
			if a != b:
				bad += 1
				if first == "":
					first = "(%d,%d)" % [x, y]
	_check(bad == 0, id + ": сетка рельефа зеркальна (несовпадений %d, первое %s)" % [bad, first])
	# полигоны скал (по ним режется штрих и строится линия бота) — точной проверкой
	var probe := RandomNumberGenerator.new()
	probe.seed = 29
	var bad_rock := 0
	for i in 4000:
		var p := Vector2(probe.randf_range(0.0, w.world_size.x), probe.randf_range(0.0, w.world_size.y))
		if t.is_rock(p) != t.is_rock(_mx(p)):
			bad_rock += 1
	_check(bad_rock == 0, id + ": скалы зеркальны по полигонам (4000 точек, несовпадений %d)" % bad_rock)


## Путь A* стороны 1 к Котлу стороны 0 — отражение пути стороны 0 к Котлу стороны 1: иначе
## бойцы и линии бота сторон идут разными дорогами (другой проход стыка, другой бок валуна).
func _paths(id: String, c0: Vector2, c1: Vector2) -> void:
	# точки на сетке 16 (Котлы, участки процгена) — там клетка точки неоднозначна (B-290)
	var pairs: Array = [[c0, c1]]
	for pl: Dictionary in w.map.get("plots", []):
		if int(pl.get("side", 0)) == 0:
			pairs.append([Vector2(float(pl["pos"][0]), float(pl["pos"][1])), c1])
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var t := w.terrain
	while pairs.size() < 60:
		var a := Vector2(rng.randf_range(20.0, w.world_size.x - 20.0), rng.randf_range(20.0, w.world_size.y - 20.0))
		var b := Vector2(rng.randf_range(20.0, w.world_size.x - 20.0), rng.randf_range(20.0, w.world_size.y - 20.0))
		if t.walkable(a) and t.walkable(b) and t.walkable(_mx(a)) and t.walkable(_mx(b)):
			pairs.append([a, b])
	# Равные по цене пути AStarGrid2D выбирает по порядку соседей, а он не зеркален: без решения
	# «отражённым запросом» (B-292) совпадали бы только длины, а обходы — нет.
	var bad := 0
	var bad_len := 0
	var first := ""
	for pr: Array in pairs:
		var a: Vector2 = pr[0]
		var b: Vector2 = pr[1]
		var p := t.find_path(a, b)
		var q := t.find_path(_mx(a), _mx(b))
		if absf(_len(p, a) - _len(q, _mx(a))) > 0.5:
			bad_len += 1
		var same := p.size() == q.size()
		for i in mini(p.size(), q.size()):
			same = same and _near(_mx(p[i]), q[i])
		if not same:
			bad += 1
			if first == "":
				first = "%s→%s" % [a, b]
	_check(bad_len == 0, id + ": длины путей A* зеркальны (%d пар, несовпадений %d)" % [
		pairs.size(), bad_len])
	_check(bad == 0, id + ": сами пути A* зеркальны (%d пар, несовпадений %d, первое %s)" % [
		pairs.size(), bad, first])
	# ближайшая проходимая точка к точке в скале (враг, попавший в скалу; «Сбор» по ограде)
	var rocks := 0
	var bad_open := 0
	var probe := RandomNumberGenerator.new()
	probe.seed = 17
	for i in 400:
		var r := Vector2(probe.randf_range(20.0, w.world_size.x - 20.0), probe.randf_range(20.0, w.world_size.y - 20.0))
		if t.walkable(r) or absf(r.x - w.world_size.x * 0.5) < 1.0:
			continue
		rocks += 1
		if not _near(_mx(t.nearest_open(r)), t.nearest_open(_mx(r)), 0.01):
			bad_open += 1
	_check(bad_open == 0, id + ": ближайшая земля зеркальна (%d точек в скале, несовпадений %d)" % [
		rocks, bad_open])
	var p := t.find_path(c0, c1)
	var q := t.find_path(c1, c0)
	var same := p.size() == q.size()
	for i in mini(p.size(), q.size()):
		same = same and _near(_mx(p[i]), q[i])
	_check(same, id + ": путь Котёл 1 → Котёл 0 — отражение пути Котёл 0 → Котёл 1")


static func _len(path: PackedVector2Array, from: Vector2) -> float:
	var n := 0.0
	var at := from
	for v in path:
		n += at.distance_to(v)
		at = v
	return n


## Бот стороны 1 после setup: рубежи обороны — отражения рубежей стороны 0 (тот же порядок).
func _bots(id: String) -> void:
	var b0: PvpBot = w.sides[0].bot
	var b1: PvpBot = w.sides[1].bot
	_check(b0 != null and b1 != null, id + ": обе стороны — боты PvP")
	if b0 == null or b1 == null:
		return
	var ok := b0._defense.size() == b1._defense.size()
	var why := "рубежей %d и %d" % [b0._defense.size(), b1._defense.size()]
	if ok:
		for i in b0._defense.size():
			var p: PackedVector2Array = b0._defense[i]["pts"]
			var q: PackedVector2Array = b1._defense[i]["pts"]
			var d0: Vector2 = b0._defense[i]["dir"]
			var d1: Vector2 = b1._defense[i]["dir"]
			# по порядку, а не множеством: места и участки договора идут по порядку штриха (B-295)
			var mp := PackedVector2Array()
			for v in p:
				mp.append(_mx(v))
			var set_ok := mp.size() == q.size()
			for k in mini(mp.size(), q.size()):
				set_ok = set_ok and _near(mp[k], q[k])
			if not set_ok or not _near(Vector2(-d0.x, d0.y), d1, 0.01):
				ok = false
				why = "рубеж %d: %s против %s" % [i, str(mp), str(q)]
				break
	_check(ok, id + ": рубежи обороны ботов зеркальны (%s)" % why)
	# первая перебежка: точка на пути к чужому Котлу на LEAP_HOME от дома
	var r0 := w.sides[0].contracts.recruit_path(w.sides[0].cauldron_pos, w.sides[1].cauldron_pos)
	var r1 := w.sides[1].contracts.recruit_path(w.sides[1].cauldron_pos, w.sides[0].cauldron_pos)
	var a0 := PvpBot._route_point(w.sides[0].cauldron_pos, r0, PvpBot.LEAP_HOME)
	var a1 := PvpBot._route_point(w.sides[1].cauldron_pos, r1, PvpBot.LEAP_HOME)
	_check(_near(_mx(a0), a1, 1.0), id + ": точка первой перебежки зеркальна (%s и %s)" % [a0, a1])


## Жук, упёршийся в строй, уходит вбок (Foe._find_slip): у зеркальных жуков — зеркально (B-294).
func _slip(id: String) -> void:
	var road := String((w.map["roads"] as Array)[0]["id"])
	var path := w.road_path(road)
	var a := w.spawn_foe_on_path("beetle", path, path[0])
	var b := w.spawn_foe_on_path("beetle", path, path[0])
	w.grid.rebuild()   # мир не шагал после start_map: индексы сетки — от прошлой карты
	var bad := 0
	var n := 0
	var probe := RandomNumberGenerator.new()
	probe.seed = 23
	for i in 200:
		var p := Vector2(probe.randf_range(40.0, w.world_size.x * 0.5 - 40.0), probe.randf_range(40.0, w.world_size.y - 40.0))
		var d := Vector2.from_angle(probe.randf_range(0.0, TAU))
		if not w.terrain.walkable(p):
			continue
		a.position = p
		b.position = _mx(p)
		var sa: Vector2 = a._find_slip(d, 20.0)
		var sb: Vector2 = b._find_slip(Vector2(-d.x, d.y), 20.0)
		n += 1
		if (sa == Vector2.INF) != (sb == Vector2.INF) or (sa != Vector2.INF and not _near(_mx(sa), sb, 0.01)):
			bad += 1
	a.vanish()
	b.vanish()
	_check(n > 50 and bad == 0, id + ": жук уходит вбок зеркально (%d точек, несовпадений %d)" % [n, bad])


## Порядок хода в шаге (B-296): зеркальные пары бойцов сходятся лоб в лоб; кто ходит в шаге
## позже, тот первым видит врага в досягаемости и бьёт первым. С чередованием порядка побед
## поровну (плюс-минус пара), без него — все у одной стороны.
func _order() -> void:
	print("— порядок хода сторон")
	var wins := [0, 0]
	for k in 120:
		w.dev = {"spawn_units": "0", "no_waves": "1", "pvp_nobot": "1"}
		w.args.erase("pvp_bots")
		w._base_seed = 5
		w.start_map("pvp:duel")
		var gap := 60.0 + 0.77 * k
		var a := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(800.0 - gap, 450.0), null, 0)
		var b := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(800.0 + gap, 450.0), null, 1)
		a.rally_to(PackedVector2Array([b.position]))
		b.rally_to(PackedVector2Array([a.position]))
		# кто ударил первым: удар по чужому бойцу ложится в конце шага, так что «первым» —
		# это кто раньше заметил врага в досягаемости
		for i in 60 * 20:
			w._step(1.0 / 60.0)
			if a.hp < a.max_hp or b.hp < b.max_hp:
				break
		if (a.hp < a.max_hp) != (b.hp < b.max_hp):
			wins[1 if a.hp < a.max_hp else 0] += 1
	_check(wins[0] + wins[1] >= 6 and mini(wins[0], wins[1]) * 4 >= wins[0] + wins[1],
		"первый удар в зеркальных поединках: сторона 0 — %d, сторона 1 — %d (из 120, остальные — в один шаг)" % [
		wins[0], wins[1]])


## --dev pvp_swap=1 (серия со сменой сторон): сторона 0 — на правой половине, её площадки — там
## же; сложность генерированного поля — «Стажёр», как у «Дуэли» (B-230).
func _swap() -> void:
	print("— смена сторон")
	for id: String in ["pvp:duel", "gen:7:3:pvp"]:
		_start(id)
		_check(w.difficulty == PvpRules.DIFFICULTY, id + ": сложность волн — %s" % w.difficulty)
		var left := w.sides[0].cauldron_pos
		w.dev["pvp_swap"] = "1"
		w.start_map(id)
		var s0: PvpSide = w.sides[0]
		var s1: PvpSide = w.sides[1]
		_check(_near(s0.cauldron_pos, _mx(left)) and _near(s1.cauldron_pos, left),
			id + ": со сменой сторона 0 справа (%s), сторона 1 слева (%s)" % [s0.cauldron_pos, s1.cauldron_pos])
		var ok := s0.staff.plots.size() > 0 and s0.staff.plots.size() == s1.staff.plots.size()
		for p: Dictionary in s0.staff.plots:
			ok = ok and (p["pos"] as Vector2).x > w.world_size.x * 0.5
		for p: Dictionary in s1.staff.plots:
			ok = ok and (p["pos"] as Vector2).x < w.world_size.x * 0.5
		_check(ok, id + ": площадки каждой стороны — на её половине")
		# B-365: со сменой бой — отражение боя без неё: некромант стороны 0 снаружи своего
		# Котла (молния Ку бьёт от него), носители — на своей половине, волны — сначала по
		# дорогам стороны 0
		var n0: Vector2 = w._necro.position
		var n1: Vector2 = s1.necro.position
		_check(_near(_mx(n0), n1, 0.01) and n0.x > s0.cauldron_pos.x,
			id + ": со сменой некроманты зеркальны и снаружи Котлов (%s, %s)" % [n0, n1])
		_carriers(id + " со сменой")
		var first: Dictionary = ((w.map["waves"] as Array)[0]["groups"] as Array)[0]
		var road_end := w.road_path(String(first["road"]))
		road_end = road_end.slice(road_end.size() - 1)
		_check(road_end.size() == 1 and w.side_at(road_end[0]) == 0,
			id + ": со сменой первая группа волны — на дороге стороны 0 (%s)" % first["road"])
		w.dev.erase("pvp_swap")
