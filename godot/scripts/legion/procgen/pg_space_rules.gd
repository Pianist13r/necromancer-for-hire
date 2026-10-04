class_name PgSpaceRules
extends RefCounted
##
## Правила пространства фильтра годности (PgFilter): У-12 — проходы вне дорог (щели между
## препятствиями и у края кадра) и У-13 — ничего игрового у края кадра и под панелями HUD.
## Вынесены отдельным файлом: фильтр целиком не влезает в предел длины файла линтера. Пороги —
## константы PgFilter (все числа У-правил в одном месте).
##


# ── У-12: проходы вне дорог ─────────────────────────────────────────────────

## Щель между двумя препятствиями уже PASSAGE_MIN, сквозь которую сетка марша пропускает бойца, —
## давка гуськом. Препятствия — как их видит движок (скалы и стены после подрезки дорог) и вода.
## Сомкнутые (пересекаются или касаются) и непроходимые для сетки щели не в счёт. Щель уже клетки
## (16 px), середина которой проходима по сетке, считается: боец там протискивается сквозь
## «сплошной» рисунок — тот же класс дефекта, что стены v19.
static func passages(ctx: Dictionary, problems: Array[String]) -> bool:
	var terrain: LegionTerrain = ctx["terrain"]
	var polys: Array[PackedVector2Array] = terrain.rocks.duplicate()
	polys.append_array(terrain.water)
	var real := polys.size()
	# край кадра — тоже стена: коридор между скалой и краем так же тесен (полосы за кадром)
	var w := LegionCfg.WORLD_SIZE.x
	var h := LegionCfg.WORLD_SIZE.y
	var o := PgFilter.FRAME_BAND
	for r: Rect2 in [Rect2(-o, -o, o, h + 2 * o), Rect2(w, -o, o, h + 2 * o),
			Rect2(-o, -o, w + 2 * o, o), Rect2(-o, h, w + 2 * o, o)]:
		polys.append(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end,
			Vector2(r.position.x, r.end.y)]))
	var boxes: Array[Rect2] = []
	for poly in polys:
		var box := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			box = box.expand(p)
		boxes.append(box)
	var play := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).grow(-PgFilter.EDGE_KEEP)
	var frame := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE)
	var reported := 0
	for i in real:
		for j in range(i + 1, polys.size()):
			if not boxes[i].grow(PgFilter.PASSAGE_MIN).intersects(boxes[j]):
				continue
			var gap := _gap(polys[i], polys[j])
			if gap.is_empty():
				continue
			var a: Vector2 = gap[0]
			var b: Vector2 = gap[1]
			var width := a.distance_to(b)
			var mid := (a + b) * 0.5
			var at_edge := j >= real
			# щель за кадром или у самой кромки меж скал — там никто не ходит (У-13); у края кадра
			# щель мерится до края, её середина может лежать ближе 16 px
			if width >= PgFilter.PASSAGE_MIN or width < PgFilter.GAP_TOUCH \
					or not (frame if at_edge else play).has_point(mid) or not terrain.walkable(mid):
				continue
			# у края скала, подрезанная дорогой, — обочина ворот: тесноту у дороги меряют У-1/У-2,
			# а закуток между обочиной и краем никуда не ведёт
			if at_edge and _flanks_road(polys[i], ctx["roads"]):
				continue
			if not Geometry2D.intersect_polygons(polys[i], polys[j]).is_empty():
				continue
			problems.append("У-12: проход %.0f px между %s у (%.0f,%.0f) (≥ %.0f)"
				% [width, "препятствием и краем кадра" if at_edge else "препятствиями", mid.x, mid.y,
					PgFilter.PASSAGE_MIN])
			reported += 1
			if reported >= 3:
				return true
	return true


## Препятствие — обочина дороги: вершина ближе ROAD_CLEAR (+2 px) к оси (подрезка terrain.gd).
static func _flanks_road(poly: PackedVector2Array, roads: Dictionary) -> bool:
	for p in poly:
		if LegionMapChecks.dist_to_roads(p, roads) <= LegionCfg.ROAD_CLEAR + 2.0:
			return true
	return false


## Ближайшие точки двух многоугольников [на a, на b] (по вершинам и рёбрам); [] — вырожденные.
static func _gap(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	if a.size() < 3 or b.size() < 3:
		return []
	var best := INF
	var out := []
	for pair: Array in [[a, b, false], [b, a, true]]:
		var src: PackedVector2Array = pair[0]
		var dst: PackedVector2Array = pair[1]
		var n := dst.size()
		for p in src:
			for k in n:
				var q := Geometry2D.get_closest_point_to_segment(p, dst[k], dst[(k + 1) % n])
				var d := p.distance_squared_to(q)
				if d < best:
					best = d
					out = [q, p] if pair[2] else [p, q]
	return out


# ── У-13: края и HUD ────────────────────────────────────────────────────────

## Ничего игрового ближе PgFilter.EDGE_KEEP к краю; рубежи бота, участки, Котёл, склепы и мимики —
## не под HUD.
static func edges_hud(ctx: Dictionary, problems: Array[String]) -> bool:
	var map: Dictionary = ctx["map"]
	var things: Array = []
	var half := LegionCfg.MAP_PLOT_SIZE * 0.5
	for plot: Dictionary in map.get("plots", []):
		var p := LegionMapChecks.v(plot.pos)
		things.append(["участок " + String(plot.id), Rect2(p - half, half * 2.0)])
	var c: Vector2 = ctx["cauldron"]
	things.append(["Котёл", Rect2(c, Vector2.ZERO)])
	for kind: String in ["crypts", "sleepers"]:
		for e: Dictionary in map.get(kind, []):
			var p := LegionMapChecks.v(e.get("pos", [0, 0]))
			things.append([("склеп" if kind == "crypts" else "мимик") + " (%.0f,%.0f)" % [p.x, p.y],
				Rect2(p, Vector2.ZERO)])
	var world := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).grow(-PgFilter.EDGE_KEEP)
	for th: Array in things:
		var box: Rect2 = th[1]
		if not world.encloses(box):
			problems.append("У-13: %s ближе %.0f px к краю кадра" % [th[0], PgFilter.EDGE_KEEP])
		for r in PgFilter.HUD_RECTS:
			if r.intersects(box, true) or r.has_point(box.position):
				problems.append("У-13: %s под панелью HUD" % th[0])
				break
	# рубеж — отрезок, а не его рамка: косая линия рядом с панелью под неё не заходит
	for bl: Dictionary in map.get("bot_lines", []):
		var a := LegionMapChecks.v(bl.a)
		var b := LegionMapChecks.v(bl.b)
		var label := "рубеж " + String(bl.get("id", "?"))
		if not world.has_point(a) or not world.has_point(b):
			problems.append("У-13: %s ближе %.0f px к краю кадра" % [label, PgFilter.EDGE_KEEP])
		for r in PgFilter.HUD_RECTS:
			if _segment_hits_rect(a, b, r):
				problems.append("У-13: %s под панелью HUD" % label)
				break
	return true


static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	if r.has_point(a) or r.has_point(b):
		return true
	var c := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	for k in 4:
		if Geometry2D.segment_intersects_segment(a, b, c[k], c[(k + 1) % 4]) != null:
			return true
	return false
