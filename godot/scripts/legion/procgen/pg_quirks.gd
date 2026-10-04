class_name PgQuirks
extends RefCounted
##
## Изюминки BOOK §4.1 на механиках движка: мост, трещины, мимики, склепы, пролёт призраков,
## горло, топь на дороге, золотая площадка, остров-площадка, «Котёл в центре» (его делает
## скелет), «тихая дорога», «состав» и Прораб (их делает PgWaves). Каждая изюминка либо
## встаёт по своим правилам, либо попытка раскладки проваливается (lay.fail) — неудобную карту
## генератор не выпускает, а берёт следующую попытку.
##

## Топь и горло не ставятся ближе этого к Котлу по дороге (§4.1: «не на последних 250 px»).
const NEAR_CAULDRON := 260.0
const SWAMP_HALF := Vector2i(64, 96)
const COFFEE_HALF := Vector2i(52, 72)
## Горло: пролёт 80–90 (здесь 86), длина ≤ 120; участок охраны ≤ 150 (урок B-079).
const THROAT_HALF := 43.0
const THROAT_LEN := 96.0
const THROAT_GUARD_R := 150.0
## Стена горла от соседнего колена своей дороги (за поворотом): ≥ 64 + полутолщина.
const THROAT_NEIGHBOUR := 64.0
## Трещина в тылу: на последних 300 px, не ближе 150 к Котлу; резервный участок ≤ 250.
const REAR_AT := Vector2i(160, 280)
const REAR_GUARD_R := 250.0
## Внутренняя проверка: трещины разнесены ≥ 400 px.
const INNER_GAP := 400.0
## Мимик: не ближе 110 (радиус пробуждения) к участкам и дороге-колену — берём 120.
const MIMIC_KEEP := 120.0
## Мина у развилки: ≤ 100 px от узла (фильтр: ≤ 110), от оси дороги — хотя бы 64 (не на ней).
const MINE_KNOT := 100.0
const MINE_ROAD := 64.0
## Кадр и отступы от края (У-13: ничего игрового ближе 16 px; склеп и мимик — с их телом).
const EDGE_INNER := Rect2(Vector2.ZERO, Vector2(1280, 720))
const CRYPT_EDGE := 56.0
const MIMIC_EDGE := 40.0
## Склеп ≤ 200 от участка (как на Болоте).
const CRYPT_PLOT_R := 200.0
## Пролёт призраков: последняя прямая ≥ 150 по открытому месту.
const FLIGHT_TAIL := Vector2i(176, 224)
## Проход трассы сквозь препятствие считается от 5 шагов по 8 px (≥ 32 px внутри).
const FLIGHT_CROSS_STEPS := 5
## Сколько точек излома трассы перебирать (карманы между коленами).
const FLIGHT_WAYPOINTS := 6
## Последняя прямая пролёта — не ближе клетки к «следам» препятствий.
const TAIL_CLEAR := 16.0
## Один мост: участок на своём берегу ≤ 200.
const BRIDGE_GUARD_R := 200.0
## Остров-площадка: внутренний квадрат и ширина рва (мост — с юга: вахтёры рождаются перед
## дверью, на 24–46 px ниже центра участка, — прямо на мост).
const ISLET_IN := 44.0
const ISLET_MOAT := 32.0
## Река «одного моста»: не ближе к чужим коленам (вода — непроходима; 120 − 40 = 80 px суши).
const RIVER_KEEP := 120.0
## Золотая площадка: полосы топи вокруг участка (от края фундамента, полутолщина, полудлина).
const PIT_OFFSET := 14.0
const PIT_HALF := 12.0
const PIT_ALONG := 60.0


static func _has(lay: PgLayout, q: String) -> bool:
	return (lay.card.get("quirks", []) as Array).has(q)


# ── до участков ──────────────────────────────────────────────────────────────

static func pre(lay: PgLayout) -> void:
	if _has(lay, "bridge1"):
		_bridge1(lay)
	if lay.fail.is_empty() and lay.nodes.has("twins_swamp"):
		_twins(lay)
	if lay.fail.is_empty() and (_has(lay, "swamp_road") or _has(lay, "coffee")):
		_swamp_road(lay, _has(lay, "coffee"))
	if lay.fail.is_empty() and _has(lay, "throat"):
		_throat(lay)
	if lay.fail.is_empty() and _has(lay, "island_plot"):
		_islet(lay)
	if lay.fail.is_empty():
		_breaches(lay)


## Точки дороги на прямом отрезке с запасом ≥ need по обе стороны, at в [lo, hi].
static func straight_spots(path: PackedVector2Array, lo: float, hi: float, need: float,
		step := 16.0) -> Array[float]:
	var out: Array[float] = []
	var acc := 0.0
	for i in range(1, path.size()):
		var seg := path[i].distance_to(path[i - 1])
		var at := acc + need
		while at <= acc + seg - need:
			if at >= lo and at <= hi:
				out.append(at)
			at += step
		acc += seg
	return out


## Общая часть всех дорог (для одного моста): начало, общее всем, и конец, общий всем.
static func _shared_segments(lay: PgLayout) -> Array:
	var first: PackedVector2Array = lay.roads[0]["pts"]
	var pre_n := first.size()
	var suf_n := first.size()
	for r in lay.roads:
		var p: PackedVector2Array = r["pts"]
		var k := 0
		while k < mini(p.size(), first.size()) and p[k] == first[k]:
			k += 1
		pre_n = mini(pre_n, k)
		k = 0
		while k < mini(p.size(), first.size()) and p[p.size() - 1 - k] == first[
				first.size() - 1 - k]:
			k += 1
		suf_n = mini(suf_n, k)
	var out: Array = []
	for i in range(1, pre_n):
		out.append([first[i - 1], first[i]])
	for i in range(first.size() - suf_n + 1, first.size()):
		out.append([first[i - 1], first[i]])
	return out


## «Один мост»: река поперёк общего ствола через весь кадр, единственный мост 96 px.
static func _bridge1(lay: PgLayout) -> void:
	var cands: Array = []
	for seg: Array in _shared_segments(lay):
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		if a.distance_to(b) < 2.0 * RIVER_KEEP + 16.0 or (a.x != b.x and a.y != b.y):
			continue
		var d := (b - a).normalized()
		var at := RIVER_KEEP + 8.0
		while at <= a.distance_to(b) - RIVER_KEEP - 8.0:
			cands.append([PgGeom.snap(a + d * at), a.y == b.y])
			at += 32.0
	cands = PgRng.shuffled(lay.rng, cands)
	for cand: Array in cands:
		var p: Vector2 = cand[0]
		var horizontal: bool = cand[1]
		if p.distance_to(lay.cauldron) < 220.0 or not Rect2(Vector2(96, 96),
				PgGeom.world - Vector2(192, 192)).has_point(p):
			continue
		if not _river_clear(lay, p, horizontal):
			continue
		var poly := PgArch._river_v(lay.rng, int(p.x), [int(p.y)]) if horizontal \
			else PgArch._river_h(lay.rng, int(p.y), [int(p.x)])
		var bridge := PgArch._bridge(p, horizontal)
		lay.water.append(poly)
		lay.bridges.append(bridge)
		lay.field.mark_poly(poly, lay.field.block)
		lay.boxes.append({"box": PgGeom.poly_box(poly), "kind": "water"})
		lay._unblock(bridge)
		lay.field.mark_rect(PgGeom.poly_box(bridge).grow(40.0), lay.field.reserve)
		lay.nodes["bridge1"] = p
		# участок на «своём» (Котла) берегу у моста
		lay.needs.append({"pos": p, "r": BRIDGE_GUARD_R, "why": "мост", "side": horizontal,
			"toward": lay.cauldron})
		lay.quirk_fx.append({"kind": "bridge_lights", "pos": PgGeom.arr(p)})
		return
	lay.fail = "один мост: нет общего ствола под реку"


## Река через p (поперёк дороги) должна пересечь каждую дорогу ровно один раз и не подходить к
## прочим коленам ближе RIVER_KEEP (вода — непроходима, пролёт у колена сузился бы).
static func _river_clear(lay: PgLayout, p: Vector2, horizontal: bool) -> bool:
	var off := absf(lay.cauldron.x - p.x) if horizontal else absf(lay.cauldron.y - p.y)
	if off < PgLayout.CAULDRON_FREE + 60.0:
		return false
	for r in lay.roads:
		var path: PackedVector2Array = r["pts"]
		var crossings := 0
		for i in range(1, path.size()):
			var a := path[i - 1]
			var b := path[i]
			var u := a.x if horizontal else a.y
			var v := b.x if horizontal else b.y
			var line := p.x if horizontal else p.y
			if (u - line) * (v - line) < 0.0:
				crossings += 1
				var cross_at := a.lerp(b, (line - u) / (v - u))
				if cross_at.distance_to(p) > 1.0:
					return false
			elif minf(absf(u - line), absf(v - line)) < RIVER_KEEP and not (
					_on_seg(p, a, b)):
				return false
		if crossings != 1:
			return false
	return true


static func _on_seg(p: Vector2, a: Vector2, b: Vector2) -> bool:
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) < 1.0


## Ложные близнецы: топь на короткой дороге такой длины, чтобы группы пришли вместе.
static func _twins(lay: PgLayout) -> void:
	var short := {}
	for r in lay.roads:
		if String(r["tag"]) == "short":
			short = r
	if short.is_empty():
		lay.fail = "близнецы: нет короткой дороги"
		return
	var path: PackedVector2Array = short["pts"]
	var span := float(lay.nodes["twins_swamp"])
	var vis := PgGeom.visible_range(path)
	var lo := vis.x + 96.0
	var hi := vis.y - NEAR_CAULDRON - span
	if hi < lo:
		lay.fail = "близнецы: дорога коротка для топи"
		return
	var start := (lo + hi) * 0.5
	var sub := PackedVector2Array()
	var n := maxi(2, ceili(span / 16.0))
	for s in n + 1:
		sub.append(PgGeom.point_at(path, start + span * s / n))
	var polys := Geometry2D.offset_polyline(sub, 58.0, Geometry2D.JOIN_ROUND,
		Geometry2D.END_ROUND)
	if polys.is_empty():
		lay.fail = "близнецы: топь не сложилась"
		return
	var poly := _simplify(polys[0])
	for r in lay.roads:
		if r != short and _poly_near_path(poly, r["pts"], 40.0):
			lay.fail = "близнецы: топь задевает длинную дорогу"
			return
	lay.swamp.append(poly)
	lay.field.mark_poly(poly, lay.field.reserve)
	lay.extra["twins"] = {"road": short["id"], "from": int(start), "to": int(start + span)}
	lay.quirk_fx.append({"kind": "swamp_road", "poly": PgGeom.arr_path(poly)})


static func _simplify(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in poly.size():
		if i % 2 == 0 or poly.size() < 24:
			out.append(poly[i].round())
	return out


static func _poly_near_path(poly: PackedVector2Array, path: PackedVector2Array,
		r: float) -> bool:
	for p in poly:
		if PgGeom.dist_to_path(p, path) < r:
			return true
	for i in range(1, path.size()):
		if not Geometry2D.intersect_polyline_with_polygon(
				PackedVector2Array([path[i - 1], path[i]]), poly).is_empty():
			return true
	return false


## Топь на дороге / пролитый кофе: клякса поперёк прямого отрезка, не у Котла.
static func _swamp_road(lay: PgLayout, coffee: bool) -> void:
	var half := COFFEE_HALF if coffee else SWAMP_HALF
	var spots: Array = []
	for r in lay.roads:
		var path: PackedVector2Array = r["pts"]
		var vis := PgGeom.visible_range(path)
		for at in straight_spots(path, vis.x + 120.0, vis.y - NEAR_CAULDRON - 60.0, 80.0, 32.0):
			spots.append([r, at])
	spots = PgRng.shuffled(lay.rng, spots)
	for sp: Array in spots:
		var r: Dictionary = sp[0]
		var at: float = sp[1]
		var path: PackedVector2Array = r["pts"]
		var c := PgGeom.point_at(path, at)
		var t := PgGeom.tangent_at(path, at)
		var hx := float(PgRng.grid(lay.rng, half.x, half.y, 8))
		var poly := PgGeom.blob_along(c, t, Vector2(hx, 62.0 if not coffee else 54.0), lay.rng)
		var bad := lay.field.any_rect(PgGeom.poly_box(poly), lay.field.block) \
			or PgGeom.in_hud(c, 40.0)
		for other in lay.roads:
			if other["pts"] != path and _poly_near_path(poly, other["pts"], 30.0):
				bad = true
		if bad:
			continue
		lay.swamp.append(poly)
		lay.field.mark_poly(poly, lay.field.reserve)
		lay.quirk_fx.append({"kind": "coffee" if coffee else "swamp_road",
			"poly": PgGeom.arr_path(poly)})
		return
	lay.fail = "топь на дороге: нет места"


## Узкое горло: два блока стены по бокам прямого отрезка, пролёт 86, длина 96 (турникет у
## «Проходной» делает сам скелет — там только запись для фильтра).
static func _throat(lay: PgLayout) -> void:
	if lay.nodes.has("throat"):
		var p: Vector2 = lay.nodes["throat"]
		var r: Dictionary = lay.roads[0]
		var at := PgGeom.project(r["pts"], p)
		_note_throat(lay, r, at, p)
		return
	var kind := "fence" if lay.biome == "office" or lay.biome == "site" else "stone"
	var w := 24.0 if kind == "stone" else 18.0
	var spots: Array = []
	for r in lay.roads:
		var path: PackedVector2Array = r["pts"]
		var vis := PgGeom.visible_range(path)
		for at in straight_spots(path, vis.x + 120.0, vis.y - NEAR_CAULDRON, 96.0, 32.0):
			if not _shared_by_others(lay, r, PgGeom.point_at(path, at)):
				spots.append([r, at])
	spots = PgRng.shuffled(lay.rng, spots)
	for sp: Array in spots:
		var r: Dictionary = sp[0]
		var at: float = sp[1]
		var path: PackedVector2Array = r["pts"]
		var c := PgGeom.snap(PgGeom.point_at(path, at))
		var t := PgGeom.tangent_at(path, at)
		var n := t.orthogonal()
		var off := THROAT_HALF + w * 0.5
		var parts: Array[PackedVector2Array] = []
		var ok := not PgGeom.in_hud(c, 60.0)
		for s: float in [1.0, -1.0]:
			var base := c + n * s * off
			var seg := PgGeom.seg_at(path, at).x
			var block := PackedVector2Array([base - t * THROAT_LEN * 0.5,
				base + t * THROAT_LEN * 0.5])
			if not _throat_part_ok(lay, block, w, r, seg):
				ok = false
			parts.append(block)
			# крыло наружу от середины блока: воронка, а не столбик в поле; где рядом другое
			# колено — крыло короче или без него (блоки и есть турникет)
			for wl: int in [PgRng.grid(lay.rng, 80, 128, 16), 48]:
				var wing := PackedVector2Array([base + n * s * (w * 0.5),
					base + n * s * (w * 0.5 + float(wl))])
				if _throat_part_ok(lay, wing, w, r, seg):
					parts.append(wing)
					break
		if not ok:
			continue
		for part in parts:
			lay.add_wall(part, w, kind, "throat")
		_note_throat(lay, r, at, c)
		return
	lay.fail = "горло: нет прямого отрезка"


static func _throat_part_ok(lay: PgLayout, part: PackedVector2Array, w: float, r: Dictionary,
		seg: int) -> bool:
	var box := Rect2(part[0], Vector2.ZERO).expand(part[1]).grow(w * 0.5)
	# box_fits: и зазор ≥ 64 до края кадра (щель у края — тоже узкий проход, У-12)
	return not lay.field.any_rect(box, lay.field.block) \
		and not lay.field.any_rect(box, lay.field.reserve) and lay.box_fits(box, false) \
		and PgGeom.box_gap(box, Rect2(lay.cauldron, Vector2.ZERO)) >= PgLayout.CAULDRON_FREE + 8.0 \
		and _part_clear(lay, part, w, r, seg)


## Кусок стены горла не заходит на чужие колена: всё, кроме своего отрезка дороги (он в 43 px —
## это и есть горло), — не ближе коридора ROAD_KEEP от оси; сам кусок не пересекает ни одну ось
## (verifier 27.09: крыло горла эстафеты легло поперёк соседнего колена в 176 px).
static func _part_clear(lay: PgLayout, part: PackedVector2Array, w: float, r: Dictionary,
		seg: int) -> bool:
	var n := ceili(part[0].distance_to(part[1]) / 8.0)
	for s in n + 1:
		var q := part[0].lerp(part[1], float(s) / n)
		for other in lay.roads:
			var p: PackedVector2Array = other["pts"]
			for i in range(1, p.size()):
				var own := other == r and i - 1 == seg
				# соседние колена той же дороги (за поворотом) — ближе коридора можно: горло
				# у самого поворота, пролёт там ≥ 90 держится и так
				var near := other == r and absi(i - 1 - seg) == 1
				var keep := THROAT_HALF + w * 0.5 - 2.0 if own \
					else (THROAT_NEIGHBOUR + w * 0.5 if near else PgLayout.ROAD_KEEP + w * 0.5)
				var d := q.distance_to(Geometry2D.get_closest_point_to_segment(q, p[i - 1], p[i]))
				if d < keep:
					return false
	return true


## Точка лежит и на другой дороге (общий кусок развилки или слияния): горло там мерили бы
## обе дороги, а фильтру обещано одно горло на одной дороге.
static func _shared_by_others(lay: PgLayout, r: Dictionary, p: Vector2) -> bool:
	for other in lay.roads:
		if other != r and PgGeom.dist_to_path(p, other["pts"]) < 2.0:
			return true
	return false


static func _note_throat(lay: PgLayout, r: Dictionary, at: float, p: Vector2) -> void:
	var ids: Array = []
	for other in lay.roads:
		if PgGeom.dist_to_path(p, other["pts"]) < 2.0:
			ids.append(other["id"])
	lay.extra["throat"] = {"road": r["id"], "roads": ids, "from": int(at - 60.0),
		"to": int(at + 60.0), "pos": PgGeom.arr(p)}
	lay.needs.append({"pos": p, "r": THROAT_GUARD_R, "why": "горло"})
	lay.quirk_fx.append({"kind": "throat_lights", "pos": PgGeom.arr(p)})


## Остров-площадка: участок в квадрате воды, мост с юга (у двери участка).
static func _islet(lay: PgLayout) -> void:
	var outer := ISLET_IN + ISLET_MOAT
	var cells := lay.field.open_cells(124.0, 140.0)
	cells = PackedVector2Array(PgRng.shuffled(lay.rng, Array(cells)))
	for c0 in cells:
		var q := PgGeom.snap(c0)
		var er := lay.exact_road_dist(q)
		if er < 118.0 or er > 140.0 or q.distance_to(lay.cauldron) < 220.0:
			continue
		var box := Rect2(q - Vector2(outer, outer), Vector2(outer, outer) * 2.0)
		if not Rect2(Vector2(40, 40), PgGeom.world - Vector2(80, 80)).encloses(box) \
				or PgGeom.in_hud(q, outer + 20.0):
			continue
		if lay.field.any_rect(box.grow(16.0), lay.field.block) \
				or lay.field.any_rect(box, lay.field.reserve) or not lay.box_fits(box, false):
			continue
		var near_ok := true
		for corner in [box.position, box.end, Vector2(box.end.x, box.position.y),
				Vector2(box.position.x, box.end.y)]:
			near_ok = near_ok and lay.exact_road_dist(corner) >= 48.0
		# выход с моста на юг — на свободную сушу, не под HUD
		var exit := q + Vector2(0.0, outer + 40.0)
		if not near_ok or lay.field.at(exit, lay.field.block) or PgGeom.in_hud(exit, 16.0) \
				or exit.y > PgGeom.world.y - 40.0:
			continue
		var best := Vector2.DOWN
		var strips: Array[Rect2] = [Rect2(box.position, Vector2(box.size.x, ISLET_MOAT)),
			Rect2(Vector2(box.position.x, box.end.y - ISLET_MOAT), Vector2(box.size.x,
			ISLET_MOAT)), Rect2(box.position, Vector2(ISLET_MOAT, box.size.y)),
			Rect2(Vector2(box.end.x - ISLET_MOAT, box.position.y), Vector2(ISLET_MOAT,
			box.size.y))]
		for s in strips:
			var poly := PgGeom.rect_poly(s)
			lay.water.append(poly)
			lay.field.mark_poly(poly, lay.field.block)
		var bc := q + best * (ISLET_IN + ISLET_MOAT * 0.5)
		var bsize := Vector2(ISLET_MOAT + 32.0, 96.0) if best.x != 0.0 \
			else Vector2(96.0, ISLET_MOAT + 32.0)
		var bridge := PgGeom.rect_poly(Rect2(bc - bsize * 0.5, bsize))
		lay.bridges.append(bridge)
		lay._unblock(bridge)
		lay.boxes.append({"box": box, "kind": "water"})
		lay.field.mark_rect(box, lay.field.reserve)
		lay.nodes["islet"] = q
		lay.quirk_fx.append({"kind": "islet", "pos": PgGeom.arr(q)})
		return
	lay.fail = "остров-площадка: нет места"


## Трещины: в тылу (последние 300 px), на слиянии (сразу за узлом), внутренняя проверка (2–3
## трещины посреди дорог, разнесены ≥ 400).
static func _breaches(lay: PgLayout) -> void:
	if _has(lay, "rear_breach"):
		var r: Dictionary = lay.roads[0]
		var path: PackedVector2Array = r["pts"]
		var at := PgGeom.length(path) - float(PgRng.grid(lay.rng, REAR_AT.x, REAR_AT.y, 8))
		var p := PgGeom.point_at(path, at)
		if p.distance_to(lay.cauldron) < 140.0 or PgGeom.in_hud(p, 40.0):
			lay.fail = "трещина в тылу: у самого Котла"
			return
		lay.breaches.append({"id": "crack", "road": r["id"], "at": int(at)})
		lay.needs.append({"pos": p, "r": REAR_GUARD_R, "why": "трещина"})
		lay.quirk_fx.append({"kind": "breach", "id": "crack", "pos": PgGeom.arr(p)})
	elif _has(lay, "merge_breach"):
		# у лабиринта дальнее слияние — где верхняя дорога врезается в ветвь
		var m: Vector2 = lay.nodes.get("merge2", lay.nodes.get("merge", lay.cauldron))
		var r: Dictionary = lay.roads[0]
		for other in lay.roads:
			if PgGeom.dist_to_path(m, other["pts"]) < 1.0:
				r = other
				break
		var path: PackedVector2Array = r["pts"]
		var at := PgGeom.project(path, m) + float(PgRng.grid(lay.rng, 48, 96, 16))
		var p := PgGeom.point_at(path, at)
		if PgGeom.length(path) - at < 150.0 or PgGeom.in_hud(p, 40.0):
			lay.fail = "трещина на слиянии: слияние у самого Котла"
			return
		lay.breaches.append({"id": "crack", "road": r["id"], "at": int(at)})
		lay.quirk_fx.append({"kind": "breach", "id": "crack", "pos": PgGeom.arr(p)})
	elif _has(lay, "inner_check"):
		var cands: Array = []
		for r in lay.roads:
			var path: PackedVector2Array = r["pts"]
			var vis := PgGeom.visible_range(path)
			var at := vis.x + (vis.y - vis.x) * 0.28
			while at <= vis.x + (vis.y - vis.x) * 0.78:
				cands.append([r, at])
				at += 48.0
		cands = PgRng.shuffled(lay.rng, cands)
		var want := lay.rng.randi_range(2, 3)
		var got: Array[Vector2] = []
		for cand: Array in cands:
			var r: Dictionary = cand[0]
			var p := PgGeom.point_at(r["pts"], cand[1])
			var far := not PgGeom.in_hud(p, 40.0) and p.distance_to(lay.cauldron) > 250.0
			for g in got:
				far = far and g.distance_to(p) >= INNER_GAP
			if not far:
				continue
			var id := "crack" if got.is_empty() else "crack%d" % (got.size() + 1)
			lay.breaches.append({"id": id, "road": r["id"], "at": int(cand[1])})
			lay.quirk_fx.append({"kind": "breach", "id": id, "pos": PgGeom.arr(p)})
			got.append(p)
			if got.size() >= want:
				break
		if got.size() < 2:
			lay.fail = "внутренняя проверка: нет места для двух трещин"


# ── после участков ───────────────────────────────────────────────────────────

static func post(lay: PgLayout) -> void:
	if _has(lay, "golden_pit"):
		_golden_pit(lay)
	var n_crypts := 0
	if lay.nodes.has("crypts"):
		n_crypts = int(lay.nodes["crypts"])
	elif _has(lay, "crypts_front"):
		n_crypts = lay.rng.randi_range(1, 2)
	if lay.fail.is_empty() and n_crypts > 0:
		_crypts(lay, n_crypts)
	if lay.fail.is_empty() and lay.nodes.has("bog"):
		_bog(lay)
	if lay.fail.is_empty() and _has(lay, "mimic_best"):
		_mimic(lay, false)
	if lay.fail.is_empty() and _has(lay, "mimic_mine"):
		_mimic(lay, true)


## Золотая площадка в яме: лучший участок (у узла дорог) обнесён топью со стороны дороги.
static func _golden_pit(lay: PgLayout) -> void:
	var knot: Vector2 = lay.nodes.get("merge", lay.nodes.get("split", lay.nodes.get("hub",
		Vector2.INF)))
	var best := {}
	var best_d := INF
	for p in lay.plots:
		if String(p.get("tag", "")) in ["rear", "island"]:
			continue
		var pos: Vector2 = p["pos"]
		var d := pos.distance_to(knot) if knot != Vector2.INF else pos.distance_to(lay.cauldron)
		if d < best_d:
			best_d = d
			best = p
	if best.is_empty():
		lay.fail = "золотая площадка: нет участка"
		return
	var pos: Vector2 = best["pos"]
	var toward := Vector2.ZERO
	var dmin := INF
	for dir: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var d := lay.exact_road_dist(pos + dir * 60.0)
		if d < dmin:
			dmin = d
			toward = dir
	# три полосы топи: к дороге и по бокам; с дальней стороны — сухой проход
	var side := toward.orthogonal()
	var half := LegionCfg.MAP_PLOT_SIZE * 0.5
	var strips: Array[Rect2] = []
	for spec: Array in [[toward, side], [side, toward], [-side, toward]]:
		var d: Vector2 = spec[0]
		var along: Vector2 = spec[1]
		var c: Vector2 = pos + d * (absf(d.x) * half.x + absf(d.y) * half.y + PIT_OFFSET)
		var ext := along.abs() * PIT_ALONG + d.abs() * PIT_HALF
		strips.append(Rect2(c - ext, ext * 2.0))
	for s in strips:
		var poly := PgGeom.rect_poly(s)
		lay.swamp.append(poly)
	best["tag"] = "golden"
	lay.quirk_fx.append({"kind": "golden_pit", "pos": PgGeom.arr(pos)})


## Склепы у дальних петель: ≤ 200 от участка, не у дороги, не у Котла.
static func _crypts(lay: PgLayout, n: int) -> void:
	var cells := PackedVector2Array(PgRng.shuffled(lay.rng, Array(lay.field.open_cells(96.0, 170.0))))
	for c0 in cells:
		if lay.crypts.size() >= n:
			break
		var q := PgGeom.snap(c0)
		# склеп целиком в кадре (У-13: ничего игрового ближе 16 px к краю; камень склепа ±40)
		if q.distance_to(lay.cauldron) < 320.0 or PgGeom.in_hud(q, 70.0) \
				or not EDGE_INNER.grow(-CRYPT_EDGE).has_point(q):
			continue
		var near_plot := false
		var clash := false
		for p in lay.plots:
			var d := q.distance_to(p["pos"])
			near_plot = near_plot or d <= CRYPT_PLOT_R
			clash = clash or d < 110.0
		for c in lay.crypts:
			clash = clash or q.distance_to(c) < 260.0
		var box := Rect2(q - Vector2(40, 56), Vector2(80, 80))
		if not near_plot or clash or lay.field.any_rect(box, lay.field.block) \
				or lay.field.any_rect(box, lay.field.reserve) or lay.exact_road_dist(q) < 90.0:
			continue
		lay.crypts.append(q)
		lay.field.mark_circle(q, 64.0, lay.field.reserve)
		lay.quirk_fx.append({"kind": "crypt", "pos": PgGeom.arr(q)})
	if lay.crypts.size() < mini(n, 1):
		lay.fail = "склепы: нет места у участков"


## Болото со склепами: топь в карманах петель (вне дороги).
static func _bog(lay: PgLayout) -> void:
	var cells := PackedVector2Array(PgRng.shuffled(lay.rng, Array(lay.field.open_cells(120.0, INF))))
	var want := lay.rng.randi_range(2, 3)
	var got := 0
	for c0 in cells:
		if got >= want:
			return
		var q := PgGeom.snap(c0)
		var half := Vector2(PgRng.grid(lay.rng, 64, 104, 8), PgRng.grid(lay.rng, 44, 64, 4))
		var poly := PgGeom.blob(q, half, lay.rng)
		if lay.field.any_rect(PgGeom.poly_box(poly), lay.field.reserve) \
				or lay.field.any_rect(PgGeom.poly_box(poly), lay.field.block) \
				or lay.field.poly_road_dist(poly) < 48.0 \
				or q.distance_to(lay.cauldron) < PgLayout.CAULDRON_FREE + half.x:
			continue
		lay.swamp.append(poly)
		lay.field.mark_poly(poly, lay.field.reserve)
		got += 1


static func _nearest(q: Vector2, pts: Array[Vector2]) -> float:
	var best := INF
	for p in pts:
		best = minf(best, q.distance_to(p))
	return best


## Мимик на лучшем месте (у колена, куда просится кольцо) или мина у развилки.
static func _mimic(lay: PgLayout, mine: bool) -> void:
	var knots: Array[Vector2] = []
	if mine:
		for key: String in ["merge", "split", "hub", "merge2"]:
			if lay.nodes.has(key):
				knots.append(lay.nodes[key])
	else:
		for r in lay.roads:
			var p: PackedVector2Array = r["pts"]
			for i in range(1, p.size() - 1):
				if PgGeom.turn_at(p, i) > 1.0 and PgGeom.world.x > p[i].x and p[i].x > 0.0:
					knots.append(p[i])
	var best := Vector2.INF
	var best_s := INF
	# мина — у самой развилки (≤ 100 от узла), можно ближе к дороге: её будят нарочно, когда
	# рядом строй (§4.1); лучшее место — в кармане колена, не ближе 120 к дорогам
	var keep := MINE_ROAD if mine else MIMIC_KEEP
	for c0 in lay.field.open_cells(keep + 4.0, 220.0):
		var q := PgGeom.snap(c0)
		if lay.exact_road_dist(q) < keep or PgGeom.in_hud(q, 40.0) \
				or q.distance_to(lay.cauldron) < 200.0 \
				or not EDGE_INNER.grow(-MIMIC_EDGE).has_point(q):
			continue
		if mine and lay.exact_road_dist(q) < MIMIC_KEEP and _nearest(q, knots) > MINE_KNOT:
			continue
		var ok := true
		for p in lay.plots:
			ok = ok and q.distance_to(p["pos"]) >= MIMIC_KEEP + 10.0
		if not ok:
			continue
		var s := INF
		for k in knots:
			s = minf(s, q.distance_to(k))
		s += lay.rng.randf() * 24.0
		if s < best_s and (not mine or s <= 240.0):
			best_s = s
			best = q
	if best == Vector2.INF:
		lay.fail = "мимик: нет места"
		return
	lay.sleepers.append(best)
	lay.field.mark_circle(best, 40.0, lay.field.reserve)
	lay.quirk_fx.append({"kind": "sleeper", "pos": PgGeom.arr(best)})


# ── пролёт призраков ─────────────────────────────────────────────────────────

## Трасса из ворот дороги к Котлу сквозь ≥ 2 препятствия, короче дороги < 0,8; последняя
## прямая ≥ 150 по открытому месту (У-9). Идёт после общей расстановки: трасса сперва ищет уже
## стоящие препятствия и лишь недостающие ставит сама.
static func flight(lay: PgLayout) -> void:
	if not _has(lay, "flight"):
		return
	var order := PgRng.shuffled(lay.rng, lay.roads)
	for r: Dictionary in order:
		var path: PackedVector2Array = r["pts"]
		var gate := path[0]
		var h := (gate - lay.cauldron).normalized()
		for turn: float in PgRng.shuffled(lay.rng, [0.0, 0.35, -0.35, 0.7, -0.7]):
			var m := (lay.cauldron + h.rotated(turn) * float(PgRng.grid(lay.rng, FLIGHT_TAIL.x,
				FLIGHT_TAIL.y))).round()
			if not Rect2(Vector2(40, 40), PgGeom.world - Vector2(80, 80)).has_point(m) \
					or not lay.field.seg_clear(m, lay.cauldron.move_toward(m, 40.0)) \
					or _in_water(lay, m, lay.cauldron):
				continue
			if not _tail_clear(lay, m):
				continue
			# прямая от ворот или с изломом через карман между коленами: прямая от ворот часто
			# идёт вдоль внутренних колен двух ветвей, где препятствиям нет места
			for w: Vector2 in _waypoints(lay, gate, m):
				var fpath := PackedVector2Array([gate, m, lay.cauldron]) if w == Vector2.INF \
					else PackedVector2Array([gate, w, m, lay.cauldron])
				if PgGeom.length(fpath) / PgGeom.length(path) >= 0.78:
					continue
				var head := fpath.slice(0, fpath.size() - 1)
				if _path_solids(lay, head) < 2:
					for i in range(1, head.size()):
						_flight_blocks(lay, head[i - 1], head[i])
				if _path_solids(lay, head) < 2 or not _tail_clear(lay, m):
					continue
				var id := String(r["id"]) + "_air"
				lay.flights.append({"id": id, "path": PgGeom.arr_path(fpath)})
				lay.field.mark_band(m, lay.cauldron, 24.0, lay.field.reserve)
				lay.quirk_fx.append({"kind": "flight", "id": id, "path": PgGeom.arr_path(fpath)})
				return
	lay.fail = "пролёт призраков: нет трассы сквозь два препятствия"


## Точки излома трассы: сперва без излома (INF), затем центры свободных карманов между
## воротами и M (далеко от дорог — есть место под препятствие на трассе).
static func _waypoints(lay: PgLayout, gate: Vector2, m: Vector2) -> Array:
	var out: Array = [Vector2.INF]
	var lo := minf(gate.x, m.x) + 120.0
	var hi := maxf(gate.x, m.x) - 120.0
	var cells := Array(lay.field.open_cells(PgLayout.ROAD_KEEP + 50.0, INF))
	for c: Vector2 in PgRng.shuffled(lay.rng, cells):
		if c.x >= lo and c.x <= hi and Rect2(Vector2(64, 64), PgGeom.world - Vector2(128,
				128)).has_point(c):
			out.append(c.round())
			if out.size() > FLIGHT_WAYPOINTS:
				break
	return out


## Входы в твёрдое по всей ломаной одним проходом: препятствие на изломе — один вход, а не два.
static func _path_solids(lay: PgLayout, pts: PackedVector2Array) -> int:
	var samples := PackedVector2Array()
	for i in range(1, pts.size()):
		var n := ceili(pts[i - 1].distance_to(pts[i]) / 8.0)
		for s in range(0 if i == 1 else 1, n + 1):
			samples.append(pts[i - 1].lerp(pts[i], float(s) / n))
	return _count_entries(lay, samples)


static func _count_entries(lay: PgLayout, samples: PackedVector2Array) -> int:
	var run := 0
	var entries := 0
	for q in samples:
		# как сетка движка: клетка 16 px твёрдая, если её центр внутри препятствия
		var cell := (q / 16.0).floor() * 16.0 + Vector2(8, 8)
		var solid := Rect2(Vector2.ZERO, PgGeom.world).has_point(q) and _solid_at(lay, cell)
		# в счёт — только проход сквозь препятствие хотя бы на FLIGHT_CROSS_STEPS шагов: по
		# краешку сетка движка твёрдого не увидит
		run = run + 1 if solid else 0
		if run == FLIGHT_CROSS_STEPS:
			entries += 1
	return entries


## Последняя прямая пролёта (M → Котёл) — по открытому месту: точно по «следам» препятствий и
## рамкам стен (растр клеток пропускал углы — verifier 27.09, У-9).
static func _tail_clear(lay: PgLayout, m: Vector2) -> bool:
	var tail := PackedVector2Array([m, lay.cauldron])
	# с запасом в клетку: фильтр меряет по растру, край «следа» ложится в клетку целиком
	var band := Geometry2D.offset_polyline(tail, TAIL_CLEAR)
	for s in lay.solids:
		for poly in band:
			if not Geometry2D.intersect_polygons(poly, s["foot"]).is_empty():
				return false
	for b: Dictionary in lay.boxes:
		if String(b["kind"]) != "solid" and not Geometry2D.intersect_polyline_with_polygon(tail,
				PgGeom.rect_poly(b["box"])).is_empty():
			return false
	return true


static func _in_water(lay: PgLayout, a: Vector2, b: Vector2) -> bool:
	for poly in lay.water:
		if not Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a, b]),
				poly).is_empty():
			return true
	return false


## Сколько раз трасса входит в твёрдое (так же считает тест карт).
static func _flight_solids(lay: PgLayout, a: Vector2, b: Vector2) -> int:
	return _path_solids(lay, PackedVector2Array([a, b]))


static func _solid_at(lay: PgLayout, q: Vector2) -> bool:
	for s in lay.solids:
		if (s["box"] as Rect2).has_point(q) and Geometry2D.is_point_in_polygon(q, s["foot"]):
			return true
	for b: Dictionary in lay.boxes:
		if String(b["kind"]) == "wall" and (b["box"] as Rect2).has_point(q):
			return true
	for poly in lay.water:
		if Geometry2D.is_point_in_polygon(q, poly):
			var on_bridge := false
			for br in lay.bridges:
				on_bridge = on_bridge or Geometry2D.is_point_in_polygon(q, br)
			return not on_bridge
	return false


## Поставить препятствия прямо на трассу, где коридор дороги позволяет.
static func _flight_blocks(lay: PgLayout, a: Vector2, b: Vector2) -> void:
	var len_ab := a.distance_to(b)
	var t := 0.0
	var last := Vector2.INF
	# пересчёт входов — только после удачной постановки (пересчёт на каждом шаге стоил секунды)
	var have := _flight_solids(lay, a, b)
	while t <= 1.0 and have < 2:
		var q := a.lerp(b, t).round()
		t += 16.0 / len_ab
		if not Rect2(Vector2(40, 40), PgGeom.world - Vector2(80, 80)).has_point(q) \
				or (last != Vector2.INF and last.distance_to(q) < 110.0) \
				or lay.field.road_dist(q) < PgLayout.ROAD_KEEP + 20.0 or _solid_at(lay, q):
			continue
		for size: String in ["L", "M", "S"]:
			var item := PgCatalog.pick(lay.rng, lay.biome, "obstacle", size)
			if PgProps.try_solid(lay, item, q, lay.rng.randf() < 0.5, false):
				last = q
				have = _flight_solids(lay, a, b)
				break
