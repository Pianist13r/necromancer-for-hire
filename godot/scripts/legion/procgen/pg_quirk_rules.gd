class_name PgQuirkRules
extends RefCounted
##
## Правила изюминок BOOK §4.1, которые видны по данным карты, — часть фильтра годности PgFilter
## (вынесены отдельным файлом: фильтр целиком не влезает в предел длины файла линтера).
## Часть правил действует всегда (мост не уже 96 px, трещины разнесены, мимик не у дороги, склеп
## у участка), часть — только при изюминке в procgen.card.quirks (bridge1, inner_check, mimic_mine,
## recruit_link, coffee) или по архетипу procgen.card.archetype (id — как у линии layout).
##

## «Один мост»: мост не уже 96 px (как в кампании); у единственного моста — участок на своём
## берегу ≤ 200 px.
const BRIDGE_MIN := 96.0
const BRIDGE_PLOT_R := 200.0
## «Трещина в тылу»: трещина на последних 300 px дороги; резервный участок ≤ 250 px; выход только
## в кульминацию (последняя волна).
const REAR_TAIL := 300.0
const REAR_PLOT_R := 250.0
## «Трещина на слиянии»: трещина в первых 150 px после слияния; не вместе с тыловой.
const MERGE_BREACH_WIN := 150.0
## «Внутренняя проверка»: трещины разнесены ≥ 400 px (любые две — иначе портал на портале).
const BREACH_GAP_MIN := 400.0
## «Склепы у фронта»: склеп ≤ 200 px от участка (как на Болоте).
const CRYPT_PLOT_R := 200.0
## «Мина на развилке»: мимик у дороги допустим один и только у развилки/слияния.
const MINE_JUNCTION_R := 110.0
## «Взлётная полоса»: прямая ≥ 480 px (LINE_MAX) — не больше одной на карту.
const RUNWAY_LEN := 480.0
const RUNWAYS_MAX := 1
## «Найм-перемычка»: два участка на 210–240 px друг от друга.
const LINK_MIN := 210.0
const LINK_MAX := 240.0
## «Котёл в центре» (средняя треть кадра) — только у архетипов 9, 10, 17.
const CENTER_ARCHETYPES: Array[String] = ["spiral", "star", "hub"]
## «Объект особой важности» (Прораб) — только у архетипов «два фронта», «приёмная», «спираль».
const BOSS_ARCHETYPES: Array[String] = ["two_fronts", "hub", "spiral"]


## Изюминки карты (procgen.card.quirks) и архетип; у кампании — пусто.
static func quirks(map: Dictionary) -> Array:
	return map.get("procgen", {}).get("card", {}).get("quirks", [])


static func archetype(map: Dictionary) -> String:
	return String(map.get("procgen", {}).get("card", {}).get("archetype", ""))


## Развилки и слияния дорог: точка, где две дороги расходятся (общее начало до неё) или сходятся
## (общий путь от неё до Котла). [{"point", "kind": "fork"|"merge", "arcs": {id дороги: px}}].
static func junctions(roads: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ids: Array = roads.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: PackedVector2Array = roads[ids[i]]
			var b: PackedVector2Array = roads[ids[j]]
			# слияние: первая вершина a (не Котёл), от которой a и b идут одним путём
			for k in range(1, a.size() - 1):
				if _dist_to_path(a[k], b) <= PgFilter.MERGE_EPS \
						and PgFilter._same_route(PgFilter._tail(a, a[k]), PgFilter._tail(b, a[k])):
					out.append({"point": a[k], "kind": "merge",
						"arcs": {ids[i]: PgFilter._arc_of(a, a[k]), ids[j]: PgFilter._arc_of(b, a[k])}})
					break
			# развилка: последняя вершина a (не ворота), до которой a и b шли одним путём
			for k in range(a.size() - 2, 0, -1):
				if _dist_to_path(a[k], b) <= PgFilter.MERGE_EPS \
						and PgFilter._same_route(PgFilter._head(a, a[k]), PgFilter._head(b, a[k])):
					out.append({"point": a[k], "kind": "fork",
						"arcs": {ids[i]: PgFilter._arc_of(a, a[k]), ids[j]: PgFilter._arc_of(b, a[k])}})
					break
	return out


## Колени дорог: точки изломов зон поворота ≥ 60° (как У-7 их считает), без повторов.
static func knee_points(roads: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for road_id: String in roads:
		for t: Array in PgTurns.zones(roads[road_id]):
			if absf(float(t[2])) < PgFilter.SHARP_TURN:
				continue
			for q: Vector2 in t[4]:
				if not out.has(q):
					out.append(q)
	return out


static func _dist_to_path(p: Vector2, path: PackedVector2Array) -> float:
	var d := INF
	for i in range(1, path.size()):
		d = minf(d, p.distance_to(Geometry2D.get_closest_point_to_segment(p, path[i - 1], path[i])))
	return d


static func _inside_any(polys: Array[PackedVector2Array], p: Vector2) -> int:
	for i in polys.size():
		if Geometry2D.is_point_in_polygon(p, polys[i]):
			return i
	return -1


## «Один мост» (BOOK §4.1): любой мост по дороге не уже BRIDGE_MIN; при изюминке bridge1 у моста
## участок ≤ BRIDGE_PLOT_R на своём берегу (путь участок → Котёл не пересекает воду).
static func rule_bridges(ctx: Dictionary, problems: Array[String]) -> bool:
	var map: Dictionary = ctx["map"]
	var water := LegionTerrain._polys(map.get("water", []))
	var bridges := LegionTerrain._polys(map.get("bridges", []))
	if bridges.is_empty():
		return true
	var worst: Dictionary = {}
	for road_id: String in ctx["samples"]:
		var sm: Dictionary = ctx["samples"][road_id]
		var pos: PackedVector2Array = sm["pos"]
		for j in pos.size():
			var k := _inside_any(bridges, pos[j])
			if k < 0 or _inside_any(water, pos[j]) < 0:
				continue
			if not worst.has(k) or int(sm["span"][j]) < int(worst[k][0]):
				worst[k] = [int(sm["span"][j]), pos[j]]
	for k: int in worst:
		if float(worst[k][0]) < BRIDGE_MIN:
			var p: Vector2 = worst[k][1]
			problems.append("И-мост: мост у (%.0f,%.0f) шириной %d px по дороге (≥ %.0f)"
				% [p.x, p.y, worst[k][0], BRIDGE_MIN])
	if not quirks(map).has("bridge1"):
		return true
	var cauldron: Vector2 = ctx["cauldron"]
	for k in bridges.size():
		var center := Vector2.ZERO
		for q in bridges[k]:
			center += q
		center /= bridges[k].size()
		var found := false
		for plot: Dictionary in map.get("plots", []):
			var p := LegionMapChecks.v(plot.pos)
			if p.distance_to(center) <= BRIDGE_PLOT_R and not _crosses_water(p, cauldron, water, bridges):
				found = true
				break
		if not found:
			problems.append("И-мост: у моста (%.0f,%.0f) нет участка на своём берегу ≤ %.0f px"
				% [center.x, center.y, BRIDGE_PLOT_R])
	return true


static func _crosses_water(a: Vector2, b: Vector2, water: Array[PackedVector2Array],
		bridges: Array[PackedVector2Array]) -> bool:
	var steps := maxi(1, ceili(a.distance_to(b) / PgFilter.SAMPLE_STEP))
	for s in steps + 1:
		var p := a.lerp(b, float(s) / steps)
		if _inside_any(water, p) >= 0 and _inside_any(bridges, p) < 0:
			return true
	return false


## Трещины (BOOK §4.1): любые две разнесены ≥ 400 px («Внутренняя проверка»); тыловая (последние
## 300 px) — с участком ≤ 250 px и только в кульминацию; на слиянии — не вместе с тыловой; при
## inner_check ворот на краю одни.
static func rule_breaches(ctx: Dictionary, problems: Array[String]) -> bool:
	var map: Dictionary = ctx["map"]
	var roads: Dictionary = ctx["roads"]
	var pts: Array[Dictionary] = []
	for br: Dictionary in map.get("breaches", []):
		var road := String(br.get("road", ""))
		if not roads.has(road):
			continue
		var at := float(br.get("at", 0.0))
		var path: PackedVector2Array = roads[road]
		pts.append({"id": String(br.get("id", "?")), "road": road, "at": at,
			"p": LegionMapChecks.point_at(path, at), "tail": LegionMapChecks.path_length(path) - at})
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			var d: float = (pts[i].p as Vector2).distance_to(pts[j].p)
			if d < BREACH_GAP_MIN:
				problems.append("И-трещины: трещины %s и %s в %.0f px друг от друга (≥ %.0f)"
					% [pts[i].id, pts[j].id, d, BREACH_GAP_MIN])
	var waves: Array = map.get("waves", [])
	# кульминация — волна с "climax": true (PgWaves кладёт её предпоследней); без пометки — последняя.
	# Тыловая трещина открывается в кульминацию и позже (как «Пустырь»: кульминация и финал).
	var climax := maxi(waves.size() - 1, 0)
	for i in waves.size():
		if bool(waves[i].get("climax", false)):
			climax = i
			break
	var rear: Array[String] = []
	var merge: Array[String] = []
	for b: Dictionary in pts:
		for jn: Dictionary in ctx["junctions"]:
			var arcs: Dictionary = jn.arcs
			if jn.kind == "merge" and arcs.has(b.road) and float(b.at) >= float(arcs[b.road]) \
					and float(b.at) <= float(arcs[b.road]) + MERGE_BREACH_WIN:
				merge.append(String(b.id))
				break
		if float(b.tail) > REAR_TAIL:
			continue
		rear.append(String(b.id))
		var p: Vector2 = b.p
		var near := INF
		for plot: Dictionary in map.get("plots", []):
			near = minf(near, LegionMapChecks.v(plot.pos).distance_to(p))
		if near > REAR_PLOT_R:
			problems.append("И-тыл: у тыловой трещины %s ближайший участок в %.0f px (≤ %.0f)"
				% [b.id, near, REAR_PLOT_R])
		for i in climax:
			for g: Dictionary in waves[i].get("groups", []):
				if String(g.get("breach", "")) == String(b.id):
					problems.append(("И-тыл: тыловая трещина %s открывается в волне %d, раньше"
						+ " кульминации (волна %d)") % [b.id, i + 1, climax + 1])
					break
	for m in merge:
		for r in rear:
			if m != r:
				problems.append("И-трещины: трещина на слиянии %s вместе с тыловой %s" % [m, r])
	if quirks(map).has("inner_check"):
		var gates: Dictionary = {}
		for road_id: String in roads:
			var g := LegionMapChecks.gate_of(roads[road_id])
			if g != Vector2.INF:
				gates[Vector2i(roundi(g.x), roundi(g.y))] = true
		if gates.size() != 1:
			problems.append("И-проверка: ворот на краю %d (у «Внутренней проверки» — одни)" % gates.size())
	return true


## Мимики (BOOK §4.1: «не ближе 110 px к участку и дороге-колену»): не ближе радиуса пробуждения
## к участку (стройка будит) и к колену дороги — вершинам поворотов ≥ 60° и развилкам/слияниям
## (там встаёт строй). У колена допустим один, и только у развилки или слияния при изюминке
## mimic_mine («Мина на развилке»). Склеп ≤ 200 px от участка («Склепы у фронта»).
static func rule_sleepers_crypts(ctx: Dictionary, problems: Array[String]) -> bool:
	var map: Dictionary = ctx["map"]
	var wake := float(LegionCfg.FOES.get("mimic", {}).get("wake_radius", 110.0))
	var mine_ok := quirks(map).has("mimic_mine")
	var knees := knee_points(ctx["roads"])
	var mines := 0
	for e: Dictionary in map.get("sleepers", []):
		var p := LegionMapChecks.v(e.get("pos", [0, 0]))
		for plot: Dictionary in map.get("plots", []):
			var d := p.distance_to(LegionMapChecks.v(plot.pos))
			if d < wake:
				problems.append(("И-мимик: мимик (%.0f,%.0f) в %.0f px от участка %s"
					+ " — стройка его будит (≥ %.0f)")
					% [p.x, p.y, d, plot.id, wake])
		var at_junction := false
		var dj := INF
		for jn: Dictionary in ctx["junctions"]:
			dj = minf(dj, p.distance_to(jn.point))
		at_junction = dj <= MINE_JUNCTION_R
		var dk := dj
		var knee := Vector2.INF
		for q in knees:
			if p.distance_to(q) < dk:
				dk = p.distance_to(q)
				knee = q
		if dk >= wake:
			continue
		if mine_ok and at_junction and mines == 0:
			mines += 1
			continue
		var where := "развилки" if knee == Vector2.INF else "колена (%.0f,%.0f)" % [knee.x, knee.y]
		problems.append(("И-мимик: мимик (%.0f,%.0f) в %.0f px от %s дороги (≥ %.0f; у колена —"
			+ " только одна «мина на развилке»)") % [p.x, p.y, dk, where, wake])
	for e: Dictionary in map.get("crypts", []):
		var p := LegionMapChecks.v(e.get("pos", [0, 0]))
		var near := INF
		for plot: Dictionary in map.get("plots", []):
			near = minf(near, p.distance_to(LegionMapChecks.v(plot.pos)))
		if near > CRYPT_PLOT_R:
			problems.append("И-склеп: склеп (%.0f,%.0f) в %.0f px от ближайшего участка (≤ %.0f)"
				% [p.x, p.y, near, CRYPT_PLOT_R])
	return true


## Прочие изюминки §4.1, видимые в данных: Котёл в центре и Прораб — по архетипу (у кампании
## архетипа нет — не судим), взлётная полоса (при изюминке runway) — одна, найм-перемычка и кофе —
## по изюминке.
static func rule_layout_quirks(ctx: Dictionary, problems: Array[String]) -> bool:
	var map: Dictionary = ctx["map"]
	var arch := archetype(map)
	var qs := quirks(map)
	var size := LegionCfg.WORLD_SIZE
	var c: Vector2 = ctx["cauldron"]
	var middle := Rect2(size / 3.0, size / 3.0)
	if arch != "" and middle.has_point(c) and not CENTER_ARCHETYPES.has(arch):
		problems.append("И-центр: Котёл в средней трети кадра у архетипа %s (только %s)"
			% [arch, ", ".join(CENTER_ARCHETYPES)])
	if arch != "" and not BOSS_ARCHETYPES.has(arch):
		for wave: Dictionary in map.get("waves", []):
			if wave.get("groups", []).any(func(g: Dictionary) -> bool: return g.get("type", "") == "boss"):
				problems.append("И-прораб: Прораб у архетипа %s (только %s)"
					% [arch, ", ".join(BOSS_ARCHETYPES)])
				break
	# «Взлётная полоса» — изюминка: при ней прямая ≥ 480 одна; у «Эстафеты» (relay) прямых ≥ 480
	# несколько по замыслу архетипа (BOOK §3.2 №15), поэтому без изюминки правило не действует
	if qs.has("runway"):
		_rule_runway(ctx, problems)
	if qs.has("recruit_link"):
		var plots: Array = map.get("plots", [])
		var linked := false
		for i in plots.size():
			for j in range(i + 1, plots.size()):
				var d := LegionMapChecks.v(plots[i].pos).distance_to(LegionMapChecks.v(plots[j].pos))
				linked = linked or (d >= LINK_MIN and d <= LINK_MAX)
		if not linked:
			problems.append("И-перемычка: нет двух участков на %.0f–%.0f px друг от друга"
				% [LINK_MIN, LINK_MAX])
	if qs.has("coffee") and String(map.get("biome", "")) != "office":
		problems.append("И-кофе: «Пролитый кофе» вне конторы (биом %s)" % map.get("biome", ""))
	return true


## Прямые куски дороги в кадре: [[длина px, ключ начала Vector2i]] — ключ, чтобы общий кусок двух
## дорог считался один раз.
static func _straight_pieces(sm: Dictionary) -> Array:
	var dir: PackedVector2Array = sm["dir"]
	var arc: PackedFloat32Array = sm["arc"]
	var pos: PackedVector2Array = sm["pos"]
	var out := []
	var j := 0
	while j < dir.size():
		var start := j
		j += 1
		while j < dir.size() and absf(dir[j].angle_to(dir[j - 1])) < PgFilter.TURN_EPS \
				and arc[j] - arc[j - 1] <= PgFilter.SAMPLE_STEP + 0.01:
			j += 1
		out.append([arc[j - 1] - arc[start] + PgFilter.SAMPLE_STEP,
			Vector2i(roundi(pos[start].x), roundi(pos[start].y))])
	return out


## Горло по разметке (длина, участок охраны) и топь на последних 250 px дороги.
static func rule_throat_swamp(ctx: Dictionary, problems: Array[String]) -> bool:
	var map: Dictionary = ctx["map"]
	var throat: Dictionary = ctx["throat"]
	if not throat.is_empty():
		var length := float(throat["to"]) - float(throat["from"])
		var pos: Vector2 = throat["pos"]
		var missing: Array[String] = []
		for r: String in throat["roads"]:
			if not ctx["roads"].has(r):
				missing.append(r)
		if throat["roads"].is_empty() or not missing.is_empty() or pos == Vector2.INF:
			problems.append("И-горло: разметка горла на несуществующей дороге %s" % [missing])
		elif length <= 0.0 or length > PgFilter.THROAT_LEN_MAX:
			problems.append("И-горло: длина горла %.0f px (0 < длина ≤ %.0f)"
				% [length, PgFilter.THROAT_LEN_MAX])
		else:
			var near := INF
			for plot: Dictionary in map.get("plots", []):
				near = minf(near, LegionMapChecks.v(plot.pos).distance_to(pos))
			if near > PgFilter.THROAT_GUARD_R:
				problems.append("И-горло: участок охраны в %.0f px от горла (≤ %.0f, урок B-079)"
					% [near, PgFilter.THROAT_GUARD_R])
	var terrain: LegionTerrain = ctx["terrain"]
	for road_id: String in ctx["roads"]:
		var path: PackedVector2Array = ctx["roads"][road_id]
		var length := LegionMapChecks.path_length(path)
		# идём от Котла назад: первая найденная точка топи — ближайшая к Котлу
		var d := 0.0
		while d < PgFilter.SWAMP_TAIL and d <= length:
			var p := LegionMapChecks.point_at(path, length - d)
			if terrain.speed_mult(p) < 1.0:
				problems.append("И-топь: топь на дороге %s у (%.0f,%.0f), в %.0f px от Котла (≥ %.0f)"
					% [road_id, p.x, p.y, d, PgFilter.SWAMP_TAIL])
				break
			d += PgFilter.SAMPLE_STEP
	return true


## «Взлётная полоса»: прямых ≥ RUNWAY_LEN в кадре не больше RUNWAYS_MAX (общий кусок двух дорог —
## один раз).
static func _rule_runway(ctx: Dictionary, problems: Array[String]) -> bool:
	var runways: Dictionary = {}
	for road_id: String in ctx["samples"]:
		for piece: Array in _straight_pieces(ctx["samples"][road_id]):
			if float(piece[0]) >= RUNWAY_LEN:
				runways[piece[1]] = piece[0]
	if runways.size() > RUNWAYS_MAX:
		problems.append("И-полоса: прямых ≥ %.0f px на карте %d (≤ %d)"
			% [RUNWAY_LEN, runways.size(), RUNWAYS_MAX])
	return true
