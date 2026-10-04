extends SceneTree
## Поиск «заглушек» в картинке процедурных карт — объектов словаря, которые PgArtCanvas рисует
## кодом вместо картинки библиотеки (сессия gen-art-polish, 03.10.2026). Только словарь карты,
## рендер не нужен — работает в headless.
##
##   "$GODOT" --headless --path godot --script res://tests/procgen_plug_scan.gd -- --mute \
##       --seeds 1-20 --k 1-12 [--out файл.json] [--verbose]
##
## Виды: marsh_flat (топь вне биома «Болото» — плоская заливка), rock_code (препятствие без
## спрайта — `_rock`), wall_code (звено без текстуры), prop_code (предмет без текстуры),
## decor_code (декор кодом). Печатает по виду: карт и объектов.

const KINDS := ["marsh_flat", "rock_code", "wall_code", "prop_code", "decor_code"]


func _initialize() -> void:
	var seeds := Vector2i(1, 20)
	var ks := Vector2i(1, 12)
	var out := ""
	var verbose := false
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		var nxt: String = argv[i + 1] if i + 1 < argv.size() else ""
		match argv[i]:
			"--seeds":
				seeds = _range(nxt)
			"--k":
				ks = _range(nxt)
			"--out":
				out = nxt
			"--verbose":
				verbose = true
	var ids: Array[String] = []
	for s in range(seeds.x, seeds.y + 1):
		for k in range(ks.x, ks.y + 1):
			ids.append("gen:%d:%d" % [s, k])
		ids.append("gen:%d:3:pvp" % s)
	ids.append("pvp:duel")
	var maps_with := {}
	var objs := {}
	var per_map := {}
	var total := 0
	for id in ids:
		var map := LegionWorld.load_map(id)
		if map.is_empty():
			continue
		total += 1
		var found := scan(map)
		for kind: String in found:
			maps_with[kind] = int(maps_with.get(kind, 0)) + 1
			objs[kind] = int(objs.get(kind, 0)) + int(found[kind])
		if not found.is_empty():
			per_map[id] = found
			if verbose:
				print("  ", id, " ", found, " ", map.get("biome", ""))
	print("PLUG SCAN: карт %d" % total)
	for kind: String in KINDS:
		print("  %s: карт %d, объектов %d" % [kind, int(maps_with.get(kind, 0)),
			int(objs.get(kind, 0))])
	if not out.is_empty():
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify({"total": total, "maps_with": maps_with, "objects": objs,
			"per_map": per_map}, "  "))
		f.close()
	quit(0)


## Объекты словаря карты, которые сборка нарисует кодом. {вид: число}.
static func scan(map: Dictionary) -> Dictionary:
	var found := {}
	var biome := String(map.get("biome", map.get("theme", "grave")))
	if biome != "swamp" and not PgArtMarsh.covers(biome):
		var n := (map.get("swamp", []) as Array).size()
		if n > 0:
			found["marsh_flat"] = n
	var covered := PgArtSprites.covered_rocks(map)
	var rocks: Array = map.get("rocks", [])
	var uncovered := 0
	for i in rocks.size():
		if not covered.has(i):
			uncovered += 1
	if uncovered > 0:
		found["rock_code"] = uncovered
	for entry: Dictionary in map.get("walls", []):
		var item := PgCatalog.by_id(String(entry.get("item", "")))
		if item.is_empty() or String(item.get("role", "")) != "wall":
			item = PgCatalog.wall(String(entry.get("kind", "stone")), biome)
		var tex := String(item.get("tex", ""))
		if tex.is_empty() or not ResourceLoader.exists(tex, "Texture2D"):
			found["wall_code"] = int(found.get("wall_code", 0)) + 1
	for prop: Dictionary in map.get("props", []):
		var item := PgCatalog.by_id(String(prop.get("item", "")))
		var tex := String(item.get("tex", ""))
		if item.is_empty() or tex.is_empty() or not ResourceLoader.exists(tex, "Texture2D"):
			found["prop_code"] = int(found.get("prop_code", 0)) + 1
	if (map.get("props", []) as Array).is_empty():
		for item: Dictionary in map.get("decor", []):
			var p := Vector2(item.pos[0], item.pos[1])
			if PgArtSprites.decor_item(String(item.get("kind", "grave")), biome, p).is_empty():
				found["decor_code"] = int(found.get("decor_code", 0)) + 1
	return found


static func _range(s: String) -> Vector2i:
	var p := s.split("-")
	return Vector2i(p[0].to_int(), p[p.size() - 1].to_int())
