extends SceneTree
## Пустота картинки процедурных карт: доля кадра, где до ближайшего объекта дальше PgArtFill.EMPTY_R
## (gen-art-polish, 03.10.2026). Собирает дерево узлов PgArt.compose без рендера (headless).
##
##   "$GODOT" --headless --path godot --script res://tests/procgen_empty_scan.gd -- --mute \
##       --seeds 1-20 --k 1-12 [--nofill] [--out файл.json]
## --nofill — группы выключены (замер «было»). Печатает среднее/медиану/максимум по биомам.


func _initialize() -> void:
	var seeds := Vector2i(1, 20)
	var ks := Vector2i(1, 12)
	var out := ""
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
			"--nofill":
				PgArtFill.enabled = false
	var ids: Array[String] = []
	for s in range(seeds.x, seeds.y + 1):
		for k in range(ks.x, ks.y + 1):
			ids.append("gen:%d:%d" % [s, k])
		ids.append("gen:%d:3:pvp" % s)
	ids.append("pvp:duel")
	var per := {}
	var by_biome := {}
	var groups := 0
	for id in ids:
		var map := LegionWorld.load_map(id)
		if map.is_empty():
			continue
		var root := Node2D.new()
		var stats := PgArt.compose(root, map, null, 0.4)
		var srcs: Array = []
		for nm in ["RoadEdge", "Scatter", "Sprites", "StillLife", "Marsh", "Fill"]:
			var n := root.get_node_or_null(nm)
			if n != null:
				srcs.append(n)
		var pts := PackedVector2Array()
		for e: Dictionary in stats.get("depth_entries", []):
			pts.append(e["pos"] as Vector2)
		# замер всегда по ВСЕМ источникам, включая Fill (при --nofill он пуст)
		var v := PgArtFill.emptiness(map, srcs, pts)
		per[id] = {"empty": v, "fill": int(stats.get("fill", 0))}
		groups += int(stats.get("fill", 0))
		var b := String(map.get("biome", "?"))
		if not by_biome.has(b):
			by_biome[b] = []
		(by_biome[b] as Array).append(v)
		root.free()
	var all: Array = []
	for b: String in by_biome:
		var arr: Array = by_biome[b]
		arr.sort()
		var sum := 0.0
		for x: float in arr:
			sum += x
		all.append_array(arr)
		print("  %s: карт %d, пустота среднее %.3f, медиана %.3f, максимум %.3f" % [b, arr.size(),
			sum / arr.size(), arr[arr.size() / 2], arr[-1]])
	all.sort()
	var total := 0.0
	for x: float in all:
		total += x
	print("EMPTY SCAN: карт %d, среднее %.4f, медиана %.4f, максимум %.4f, предметов групп %d" % [
		all.size(), total / all.size(), all[all.size() / 2], all[-1], groups])
	if not out.is_empty():
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify(per, "  "))
		f.close()
	quit(0)


static func _range(s: String) -> Vector2i:
	var p := s.split("-")
	return Vector2i(p[0].to_int(), p[p.size() - 1].to_int())
