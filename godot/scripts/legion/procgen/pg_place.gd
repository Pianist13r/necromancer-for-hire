class_name PgPlace
extends RefCounted
##
## Участки и рубежи бота. Участки (§7 У-4, У-5): 3–8, в 70–140 px от оси дороги, на суше, не
## под HUD, хотя бы один в 250 px от Котла; плюс участки, которых требуют изюминки (у горла,
## у трещины в тылу, у моста, остров-площадка, найм-перемычка). Рубежи (§10): поперёк дороги
## там, где пролёт ≥ 200 px и место в радиусе набора площадки (вахтёры дотягиваются), плюс
## фланг на стволе за слиянием или тыловой у Котла — формат полей как в кампании.
##

## Расстояние центра участка до оси дороги (У-4: 70–140; поле точно до ~10 px — берём уже).
const PLOT_ROAD := Vector2(80.0, 136.0)
const PLOT_OFFSETS: Array[float] = [92.0, 108.0, 124.0]
const PLOT_STEP := 24.0
## Между участками — не теснее (спрайт постройки ≈ 72 px, двери и вахта).
const PLOT_GAP := 136.0
## Тыловой участок (У-5): ≤ 250 от Котла; целимся в середину.
const REAR_R := Vector2(120.0, 236.0)
const COUNT := Vector2i(4, 7)
const COUNT_RELAY := Vector2i(3, 4)
const MAX_PLOTS := 8
## Найм-перемычка: два участка на 210–240 px, между ними — узел дорог.
const LINK := Vector2(210.0, 240.0)
## Рубеж: длина поперёк дороги (как в кампании 100–140) и запас пролёта с каждой стороны.
const LINE_LEN := 112.0
const LINE_SPAN := 100.0
const LINE_SPAN_MIN := 64.0
## Вахтёры рождаются у двери: центр участка + (0, 46) (legion_maps_test._check_post_reach).
const DOOR := Vector2(0.0, 46.0)
const RECRUIT := 196.0
const LINE_KEEP_SLEEPER := 140.0
const RING_DIRS := 16
## Рубежи: первый — на середине собственной части дороги, второй — ближе к Котлу; всего ≤ 5.
const FRONT_FRAC := 0.5
const SECOND_FRAC := 0.8
const MAX_LINES := 5


static func plots(lay: PgLayout) -> void:
	var cands := _candidates(lay)
	var chosen: Array[Dictionary] = []
	if lay.nodes.has("islet"):
		chosen.append({"pos": lay.nodes["islet"], "tag": "island", "road": "", "at": 0.0})
	# тыл (У-5)
	var rear := {}
	var best := INF
	for c in cands:
		var d: float = (c["pos"] as Vector2).distance_to(lay.cauldron)
		if d >= REAR_R.x and d <= REAR_R.y and absf(d - 180.0) < best and _free(c, chosen) \
				and _exact_ok(lay, c["pos"]):
			best = absf(d - 180.0)
			rear = c
	if rear.is_empty():
		for p in chosen:
			if (p["pos"] as Vector2).distance_to(lay.cauldron) <= REAR_R.y:
				rear = p
	if rear.is_empty():
		lay.fail = "нет тылового участка у Котла"
		return
	if not chosen.has(rear):
		rear["tag"] = "rear"
		chosen.append(rear)
	# требования изюминок
	for need: Dictionary in lay.needs:
		if not _serve_need(lay, need, cands, chosen):
			lay.fail = "нет участка для: " + String(need["why"])
			return
	if (lay.card.get("quirks", []) as Array).has("recruit_link") and not _link(lay, cands, chosen):
		lay.fail = "найм-перемычка: нет пары участков у узла"
		return
	if not PgPlotPatterns.apply(lay, cands, chosen):
		return
	var want := lay.rng.randi_range(COUNT.x, COUNT.y)
	if String(lay.card["archetype"]) == "relay":
		want = lay.rng.randi_range(COUNT_RELAY.x, COUNT_RELAY.y)
	want = clampi(maxi(want, chosen.size()), 3, MAX_PLOTS)
	# по участку у каждой дороги в её средней части — «фронт»
	for r in lay.roads:
		if chosen.size() >= want:
			break
		var pick := _farthest(lay, cands, chosen, String(r["id"]), Vector2(0.3, 0.7))
		if not pick.is_empty():
			pick["tag"] = "front"
			chosen.append(pick)
	while chosen.size() < want:
		var pick := _farthest(lay, cands, chosen, "", Vector2(0.12, 0.92))
		if pick.is_empty():
			break
		chosen.append(pick)
	if chosen.size() < 3:
		lay.fail = "меньше трёх участков"
		return
	for i in chosen.size():
		var p := chosen[i]
		lay.plots.append({"id": "p%d" % (i + 1), "pos": p["pos"], "tag": String(p.get("tag", "")),
			"bot_priority": 0, "serves_lines": [], "preferred_kinds": []})
		lay.field.mark_rect(Rect2(p["pos"] - Vector2(40, 34), Vector2(80, 104)), lay.field.reserve)


## Кандидаты: вдоль каждой дороги, по обе стороны, в 92–124 px от оси.
static func _candidates(lay: PgLayout) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	var world := Rect2(Vector2(56, 56), PgGeom.world - Vector2(112, 112))
	for r in lay.roads:
		var path: PackedVector2Array = r["pts"]
		var vis := PgGeom.visible_range(path)
		var total := vis.y - vis.x
		var at := vis.x + 32.0
		while at < vis.y - 24.0:
			var p := PgGeom.point_at(path, at)
			var n := PgGeom.tangent_at(path, at).orthogonal()
			for s: float in [1.0, -1.0]:
				for off in PLOT_OFFSETS:
					var q := (p + n * s * off).snapped(Vector2(8, 8))
					if not seen.has(q) and _cand_ok(lay, q, world):
						out.append({"pos": q, "road": String(r["id"]), "at": at,
							"frac": (at - vis.x) / maxf(total, 1.0)})
					seen[q] = true
			at += PLOT_STEP
	# кольцо вокруг Котла: тыл у острова и у звезды не всегда лежит «сбоку от дороги»
	for i in RING_DIRS:
		for rad: float in [128.0, 160.0, 192.0]:
			var q := (lay.cauldron + Vector2.RIGHT.rotated(TAU * i / RING_DIRS) * rad).snapped(
				Vector2(8, 8))
			if not seen.has(q) and _cand_ok(lay, q, world):
				out.append({"pos": q, "road": "", "at": 0.0, "frac": 1.0})
			seen[q] = true
	return out


static func _cand_ok(lay: PgLayout, q: Vector2, world: Rect2) -> bool:
	if not world.has_point(q) or PgGeom.in_hud(q, 44.0) or q.distance_to(lay.cauldron) < 112.0:
		return false
	var rd := lay.field.road_dist(q)
	if rd < PLOT_ROAD.x or rd > PLOT_ROAD.y:
		return false
	var foot := Rect2(q - Vector2(34, 28), Vector2(68, 84))
	return not lay.field.any_rect(foot, lay.field.block) \
		and not lay.field.any_rect(foot, lay.field.reserve) and not _in_swamp(lay, q)


static func _in_swamp(lay: PgLayout, q: Vector2) -> bool:
	for poly in lay.swamp:
		if Geometry2D.is_point_in_polygon(q, poly):
			return true
	return false


static func _free(c: Dictionary, chosen: Array[Dictionary]) -> bool:
	for p in chosen:
		if (c["pos"] as Vector2).distance_to(p["pos"]) < PLOT_GAP:
			return false
	return true


## Точная проверка кандидата: поле не меньше точного расстояния, так что верхняя граница по
## полю верна сразу, нижняя — через road_at_least.
static func _exact_ok(lay: PgLayout, q: Vector2) -> bool:
	if lay.field.road_dist(q) > 140.0 and lay.exact_road_dist(q) > 140.0:
		return false
	return lay.road_at_least(q, 72.0)


static func _serve_need(lay: PgLayout, need: Dictionary, cands: Array[Dictionary],
		chosen: Array[Dictionary]) -> bool:
	var at: Vector2 = need["pos"]
	var r: float = need["r"]
	for p in chosen:
		if (p["pos"] as Vector2).distance_to(at) <= r and _on_side(need, p["pos"]):
			return true
	var best := {}
	var best_d := INF
	for c in cands:
		var d: float = (c["pos"] as Vector2).distance_to(at)
		if d <= r and d < best_d and _free(c, chosen) and _on_side(need, c["pos"]) \
				and _exact_ok(lay, c["pos"]):
			best_d = d
			best = c
	if best.is_empty():
		return false
	best["tag"] = "need"
	chosen.append(best)
	return true


## «Свой берег» у одного моста: участок по ту же сторону реки, что Котёл.
static func _on_side(need: Dictionary, q: Vector2) -> bool:
	if not need.has("toward"):
		return true
	var p: Vector2 = need["pos"]
	var c: Vector2 = need["toward"]
	if bool(need["side"]):
		return signf(q.x - p.x) == signf(c.x - p.x)
	return signf(q.y - p.y) == signf(c.y - p.y)


static func _link(lay: PgLayout, cands: Array[Dictionary], chosen: Array[Dictionary]) -> bool:
	var knots: Array[Vector2] = []
	for key: String in ["merge", "split", "hub", "merge2"]:
		if lay.nodes.has(key):
			knots.append(lay.nodes[key])
	for r in lay.roads:
		var p: PackedVector2Array = r["pts"]
		for i in range(1, p.size() - 1):
			if PgGeom.turn_at(p, i) > 1.0 and Rect2(Vector2.ZERO, PgGeom.world).has_point(p[i]):
				knots.append(p[i])
	var order := PgRng.shuffled(lay.rng, cands)
	for a: Dictionary in order:
		if not _free(a, chosen) or not _exact_ok(lay, a["pos"]):
			continue
		for b: Dictionary in cands:
			var d: float = (a["pos"] as Vector2).distance_to(b["pos"])
			if d < LINK.x or d > LINK.y or not _free(b, chosen):
				continue
			var mid: Vector2 = ((a["pos"] as Vector2) + (b["pos"] as Vector2)) * 0.5
			var near := false
			for k in knots:
				near = near or mid.distance_to(k) <= 64.0
			if near and _exact_ok(lay, b["pos"]):
				a["tag"] = "link"
				b["tag"] = "link"
				chosen.append(a)
				chosen.append(b)
				lay.quirk_fx.append({"kind": "recruit_link",
					"pos": [PgGeom.arr(a["pos"]), PgGeom.arr(b["pos"])]})
				return true
	return false


## Самый удалённый от выбранных кандидат (на дороге road, если задана, в доле пути frac).
static func _farthest(lay: PgLayout, cands: Array[Dictionary], chosen: Array[Dictionary],
		road: String, frac: Vector2) -> Dictionary:
	var best := {}
	var best_s := -INF
	for c in cands:
		if road != "" and String(c["road"]) != road:
			continue
		var f: float = c["frac"]
		if f < frac.x or f > frac.y or not _free(c, chosen):
			continue
		var s := INF
		for p in chosen:
			s = minf(s, (c["pos"] as Vector2).distance_to(p["pos"]))
		s += lay.rng.randf() * 40.0
		if s > best_s and _exact_ok(lay, c["pos"]):
			best_s = s
			best = c
	return best


# ── рубежи бота ──────────────────────────────────────────────────────────────

static func lines(lay: PgLayout) -> void:
	var ghosts := (lay.card.get("foes", []) as Array).has("ghost")
	var fronts: Array[Dictionary] = []
	# фронт — по рубежу на каждой дороге, на её собственной (не общей) части
	for r in lay.roads:
		var ln := _front(lay, r, fronts, FRONT_FRAC)
		if not ln.is_empty():
			fronts.append(ln)
	if fronts.is_empty():
		lay.fail = "нет места для рубежа поперёк дороги"
		return
	# второй рубеж ближе к Котлу на каждой дороге: смоук ботом (27.09) — с одним рубежом на
	# середине дороги бойцы простаивали (idle ≈ 5000 боец·с против ≈ 2000 на «Пустыре»), а
	# прорвавшиеся шли к Котлу без встречи
	for r in lay.roads:
		if fronts.size() >= MAX_LINES - 1:
			break
		var ln := _front(lay, r, fronts, SECOND_FRAC)
		if not ln.is_empty():
			ln["role"] = "front"
			fronts.append(ln)
	var out := fronts.duplicate()
	var back := _back(lay, out, ghosts)
	if not back.is_empty():
		out.append(back)
	for i in out.size():
		out[i]["id"] = "line_%d" % i
	for i in out.size():
		var others: Array = []
		for j in out.size():
			if j != i:
				others.append(out[j]["id"])
		out[i]["next_ids"] = others
		out[i]["support_id"] = out[(i + 1) % out.size()]["id"]
		lay.field.mark_band(_v(out[i]["a"]), _v(out[i]["b"]), 20.0, lay.field.reserve)
	lay.lines.assign(out)
	_serve(lay)


static func _v(a: Array) -> Vector2:
	return Vector2(a[0], a[1])


static func _on_other(lay: PgLayout, r: Dictionary, p: Vector2) -> bool:
	for other in lay.roads:
		if other != r and PgGeom.dist_to_path(p, other["pts"]) < 2.0:
			return true
	return false


## Лучшее место поперёк дороги r: середина её собственной части, пролёт ≥ 200, вахтёры
## ближайшей площадки дотягиваются (для охраны).
static func _front(lay: PgLayout, r: Dictionary, have: Array[Dictionary], want: float) \
		-> Dictionary:
	var path: PackedVector2Array = r["pts"]
	var vis := PgGeom.visible_range(path)
	var best := {}
	var best_s := INF
	for span: float in [LINE_SPAN, LINE_SPAN_MIN]:
		for at in PgQuirks.straight_spots(path, vis.x + 64.0, vis.y - 150.0, 64.0, 16.0):
			var p := PgGeom.point_at(path, at)
			if _on_other(lay, r, p):
				continue
			var ln := _line_at(lay, r, at, span, "guard")
			if ln.is_empty():
				continue
			var frac := (at - vis.x) / maxf(vis.y - vis.x, 1.0)
			var s := absf(frac - want) * 400.0 + _door_dist(lay, p) * 0.5
			var clash := false
			for h in have:
				clash = clash or p.distance_to(_mid(h)) < 200.0
			if clash:
				continue
			if s < best_s:
				best_s = s
				best = ln
		if not best.is_empty():
			return best
	return best


static func _mid(ln: Dictionary) -> Vector2:
	return (_v(ln["a"]) + _v(ln["b"])) * 0.5


static func _door_dist(lay: PgLayout, p: Vector2) -> float:
	var best := INF
	for pl in lay.plots:
		best = minf(best, ((pl["pos"] as Vector2) + DOOR).distance_to(p))
	return best


## Рубеж поперёк дороги в точке at или {}: проходим, не под HUD, пролёт ≥ span с каждой
## стороны, не у спящих мимиков; у охраны/аудита — площадка в радиусе набора.
static func _line_at(lay: PgLayout, r: Dictionary, at: float, span: float,
		kind: String) -> Dictionary:
	var path: PackedVector2Array = r["pts"]
	var p := PgGeom.point_at(path, at)
	var t := PgGeom.tangent_at(path, at)
	var n := t.orthogonal()
	var a := (p - n * LINE_LEN * 0.5).round()
	var b := (p + n * LINE_LEN * 0.5).round()
	for q in [a, b, p]:
		if PgGeom.in_hud(q, 16.0) or not Rect2(Vector2(24, 24), PgGeom.world - Vector2(48,
				48)).has_point(q):
			return {}
	if not lay.field.seg_clear(p - n * span, p + n * span):
		return {}
	for s in lay.sleepers:
		if s.distance_to(p) < LINE_KEEP_SLEEPER:
			return {}
	for c in lay.crypts:
		if c.distance_to(p) < 80.0:
			return {}
	if kind != "laborer" and _door_dist(lay, p) > RECRUIT:
		return {}
	# стрелка рубежа — навстречу врагу: против хода дороги
	var u := (b - a).normalized()
	var n0 := Vector2(u.y, -u.x)
	var release := 1 if n0.dot(-t) > 0.0 else -1
	var dir := n0 * release
	return {"road": String(r["id"]), "a": PgGeom.arr(a), "b": PgGeom.arr(b),
		"release": release, "kind": kind, "id": "", "role": "front",
		"dir": [snappedf(dir.x, 0.001), snappedf(dir.y, 0.001)], "min_units": 3,
		"next_ids": [], "support_id": ""}


## Фланг на стволе сразу за слиянием или тыловой рубеж у Котла.
static func _back(lay: PgLayout, have: Array, ghosts: bool) -> Dictionary:
	var r: Dictionary = lay.roads[0]
	var path: PackedVector2Array = r["pts"]
	var total := PgGeom.length(path)
	var ats: Array[float] = []
	var role := "rear"
	if lay.nodes.has("merge"):
		var m := PgGeom.project(path, lay.nodes["merge"])
		var at := m + 48.0
		while at < minf(m + 240.0, total - 140.0):
			ats.append(at)
			at += 16.0
		role = "flank"
	var at2 := total - 260.0
	while at2 <= total - 130.0:
		ats.append(at2)
		at2 += 16.0
	var kind := "clerk" if ghosts else "laborer"
	for k: String in [kind, "laborer"]:
		for span: float in [LINE_SPAN, LINE_SPAN_MIN]:
			for at in ats:
				var seg := PgGeom.seg_at(path, at)
				var a := path[seg.x]
				var b := path[seg.x + 1]
				if at - seg.y < 48.0 or seg.y + a.distance_to(b) - at < 48.0:
					continue
				var ln := _line_at(lay, r, at, span, k)
				if ln.is_empty():
					continue
				var clash := false
				for h: Dictionary in have:
					clash = clash or _mid(ln).distance_to(_mid(h)) < 110.0
				if clash:
					continue
				ln["role"] = role
				return ln
	return {}


## Участки: чьи рубежи обслуживают, приоритет бота (ближе к Котлу — выше), любимые виды.
static func _serve(lay: PgLayout) -> void:
	var ghosts := (lay.card.get("foes", []) as Array).has("ghost")
	var order := range(lay.plots.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		return (lay.plots[a]["pos"] as Vector2).distance_to(lay.cauldron) \
			< (lay.plots[b]["pos"] as Vector2).distance_to(lay.cauldron))
	for rank in order.size():
		var p: Dictionary = lay.plots[order[rank]]
		p["bot_priority"] = order.size() - rank
		var pos: Vector2 = p["pos"]
		var by := lay.lines.duplicate()
		by.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return pos.distance_to(_mid(a)) < pos.distance_to(_mid(b)))
		var serves: Array = []
		for ln: Dictionary in by:
			if serves.size() < 2:
				serves.append(ln["id"])
		p["serves_lines"] = serves
		var k := String(by[0]["kind"])
		var first := "guard" if k == "guard" else ("clerk" if k == "clerk" else "laborer")
		if ghosts and rank % 3 == 1:
			first = "clerk"
		p["preferred_kinds"] = [first, "laborer"]
