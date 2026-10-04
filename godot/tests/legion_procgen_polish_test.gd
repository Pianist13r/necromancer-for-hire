extends SceneTree
## Доводка картинки процедурных карт (gen-art-polish, 03.10.2026, D-1003-06):
## 1) заглушек нет — ни один объект словаря не рисуется кодом без картинки: топь вне «Болота»
##    (раньше — плоская заливка, gen:4:12, gen:10:3) собирает PgArtMarsh из спрайтов библиотеки;
##    препятствия, стены, предметы, декор — со спрайтом;
## 2) пустота: крупные группы PgArtFill уменьшают долю «голой» земли, детерминированы, не заходят
##    на дорогу, участки, Котёл и за край, у PvP зеркальны; словарь карты и digest не меняются.
## Headless: compose() собирает дерево узлов без рендера.
const SAMPLE_SEEDS := [2, 4, 5, 8, 10, 11, 13, 16]
const MARSH_MAPS := ["gen:4:12", "gen:10:3", "gen:2:7", "gen:11:1", "gen:5:9", "gen:1:2"]
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, why: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", why])


func _run() -> void:
	_test_no_plugs()
	_test_marsh_picture()
	_test_fill()
	_test_fill_kinds()
	print("LEGION PROCGEN POLISH: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _ids() -> Array[String]:
	var ids: Array[String] = []
	for s: int in SAMPLE_SEEDS:
		for k in range(1, 13):
			ids.append("gen:%d:%d" % [s, k])
		ids.append("gen:%d:3:pvp" % s)
	ids.append("pvp:duel")
	return ids


func _test_no_plugs() -> void:
	var scan := load("res://tests/procgen_plug_scan.gd") as GDScript
	var bad := 0
	var with_swamp := 0
	for id in _ids():
		var map := LegionWorld.load_map(id)
		if map.is_empty():
			continue
		if not (map.get("swamp", []) as Array).is_empty():
			with_swamp += 1
		var found: Dictionary = scan.call("scan", map)
		if not found.is_empty():
			bad += 1
			print("    заглушка: ", id, " ", found)
	check(with_swamp >= 8, "в выборке есть карты с топью (%d)" % with_swamp)
	check(bad == 0, "нет объектов, нарисованных кодом без картинки (карт с заглушками: %d)" % bad)


func _test_marsh_picture() -> void:
	for id in MARSH_MAPS:
		var map := LegionWorld.load_map(id).duplicate(true)
		var before := ProcGen.digest(map)
		var root := Node2D.new()
		var stats := PgArt.compose(root, map, null, 0.4)
		var marsh := root.get_node("Marsh")
		var sprites := 0
		var polys := 0
		for c in marsh.get_children():
			sprites += 1 if c is Sprite2D else 0
			polys += 1 if c is Polygon2D else 0
		var zones := (map.swamp as Array).size()
		check(polys >= zones and sprites >= 4 and int(stats["marsh"]) == sprites,
			"%s: топь — тело и спрайты библиотеки (тел %d, спрайтов %d)" % [id, polys, sprites])
		check(ProcGen.digest(map) == before, "%s: словарь карты не менялся" % id)
		var again := Node2D.new()
		PgArt.compose(again, map, null, 0.4)
		var a := _positions(root.get_node("Marsh"))
		var b := _positions(again.get_node("Marsh"))
		check(a == b, "%s: топь повторяема" % id)
		root.free()
		again.free()


func _positions(n: Node) -> PackedVector2Array:
	var out := PackedVector2Array()
	for c in n.get_children():
		if c is Sprite2D:
			out.append((c as Sprite2D).position)
		for cc in c.get_children():
			if cc is Sprite2D:
				out.append((cc as Sprite2D).position)
	return out


func _test_fill() -> void:
	var drop := 0.0
	var maps := 0
	var res_ok := true
	var clear_ok := true
	var det_ok := true
	var total_items := 0
	for id in _ids():
		var map := LegionWorld.load_map(id)
		if map.is_empty():
			continue
		var before := ProcGen.digest(map)
		PgArtFill.enabled = false
		var off := Node2D.new()
		var s_off := PgArt.compose(off, map, null, 0.4)
		var e_off := _empty(map, off, s_off)
		PgArtFill.enabled = true
		var on := Node2D.new()
		var s_on := PgArt.compose(on, map, null, 0.4)
		var e_on := _empty(map, on, s_on)
		var on2 := Node2D.new()
		PgArt.compose(on2, map, null, 0.4)
		det_ok = det_ok and _positions(on.get_node("Fill")) == _positions(on2.get_node("Fill"))
		res_ok = res_ok and ProcGen.digest(map) == before
		drop += e_off - e_on
		maps += 1
		total_items += int(s_on["fill"])
		clear_ok = clear_ok and _fill_clear(map, on.get_node("Fill"), id)
		off.free()
		on.free()
		on2.free()
	check(res_ok, "сборка не меняет словарь карты (digest)")
	check(det_ok, "группы повторяемы от id карты")
	check(clear_ok, "группы не заходят на дорогу, участки, Котёл и за край кадра")
	check(total_items >= maps * 20, "группы есть почти везде (предметов %d на %d карт)"
		% [total_items, maps])
	check(drop / maxf(maps, 1.0) >= 0.02, "средняя пустота снижена на %.3f" % (drop / maxf(maps, 1.0)))
	var pvp := LegionWorld.load_map("pvp:duel")
	var root := Node2D.new()
	PgArt.compose(root, pvp, null, 0.4)
	var mw := LegionTerrain.mirror_width(pvp)
	var pos := _positions(root.get_node("Fill"))
	var mirrored := mw > 0.0 and not pos.is_empty()
	for p in pos:
		var twin := Vector2(mw - p.x, p.y)
		var found := false
		for q in pos:
			if q.distance_to(twin) < 0.6:
				found = true
				break
		mirrored = mirrored and found
	check(mirrored, "pvp:duel — группы зеркальны (%d предметов)" % pos.size())
	root.free()


func _empty(map: Dictionary, root: Node2D, stats: Dictionary) -> float:
	var srcs: Array = []
	for nm in ["RoadEdge", "Scatter", "Sprites", "StillLife", "Marsh", "Fill"]:
		srcs.append(root.get_node(nm))
	var pts := PackedVector2Array()
	for e: Dictionary in stats.get("depth_entries", []):
		pts.append(e["pos"] as Vector2)
	return PgArtFill.emptiness(map, srcs, pts)


func _fill_clear(map: Dictionary, fill: Node, id: String) -> bool:
	var free := PgArtScatter.Free.new(map, PgArtScatter._cauldron(map))
	var world := LegionTerrain.map_size(map)
	var ok := true
	for p in _positions(fill):
		if not Rect2(Vector2.ZERO, world).has_point(p):
			ok = false
		for road: Dictionary in map.get("roads", []):
			var pts := PgArtRoad._points(road.path)
			for j in pts.size() - 1:
				if p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[j], pts[j + 1])) \
						< LegionCfg.MAP_ROAD_WIDTH * 0.5:
					ok = false
		for c in PgArtScatter.cauldrons(map):
			if p.distance_to(c) < 45.0:
				ok = false
		for plot: Dictionary in map.get("plots", []):
			if p.distance_to(Vector2(float(plot.pos[0]), float(plot.pos[1]))) < 30.0:
				ok = false
	if not ok:
		print("    группа мешает: ", id)
	return ok and free != null


## Группа однородна по роду: вертикальные предметы и плоское пятно — только из одного рода KINDS,
## никаких кристаллов, цепей, углей и россыпи; ряд лежит на одной прямой (поставлено, не рассыпано).
func _test_fill_kinds() -> void:
	var forbidden := ["crystalslab", "chain", "embercrack", "burn", "oil", "puddle", "moss_"]
	var mixed := 0
	var stray := 0
	var crooked := 0
	var groups := 0
	var biomes := {}
	for id in _ids():
		var map := LegionWorld.load_map(id)
		if map.is_empty():
			continue
		var root := Node2D.new()
		PgArt.compose(root, map, null, 0.4)
		var by_group := {}
		for holder in root.get_node("Fill").get_children():
			var g := int(holder.get_meta("group", -1))
			if not by_group.has(g):
				by_group[g] = []
			(by_group[g] as Array).append(holder)
		for g in by_group:
			groups += 1
			var holders: Array = by_group[g]
			var kind := String(holders[0].get_meta("kind"))
			var parts := kind.split("|")
			var allowed := PackedStringArray([parts[0]])
			allowed.append_array(parts[1].split(","))
			var row := PackedVector2Array()
			for holder: Node2D in holders:
				if String(holder.get_meta("kind")) != kind:
					mixed += 1
				for c in holder.get_children():
					if c is Sprite2D:
						var name := (c as Sprite2D).texture.resource_path.get_file().get_basename()
						if not allowed.has(name):
							stray += 1
						for bad: String in forbidden:
							if name.contains(bad) and not allowed.has(name):
								stray += 1
						if holder.get_child_count() > 1 and (c as Sprite2D).position.x < 5000.0:
							row.append((c as Sprite2D).position)
			# ряд: левая половина поля (без зеркала) — отклонение от прямой через крайние точки
			if row.size() >= 3 and LegionTerrain.mirror_width(map) <= 0.0:
				var a := row[0]
				var b := row[0]
				for p in row:
					if p.x < a.x:
						a = p
					if p.x > b.x:
						b = p
				for p in row:
					var cp := Geometry2D.get_closest_point_to_segment(p, a, b)
					if p.distance_to(cp) > 7.0:
						crooked += 1
		for k: String in [String(map.get("biome", ""))]:
			biomes[k] = true
		root.free()
	check(groups >= 100, "групп в выборке достаточно (%d)" % groups)
	check(mixed == 0, "группа не смешивает роды (смешанных предметов %d)" % mixed)
	check(stray == 0, "в группах только предметы своего рода, без россыпи (чужих %d)" % stray)
	check(crooked == 0, "ряд лежит на одной прямой (выбившихся предметов %d)" % crooked)
	check(biomes.has("ash") and biomes.has("site") and biomes.has("office"),
		"в выборке пустырь, стройка и контора")
