extends SceneTree
## Шесть парных наборов: одна карточка и layout-RNG на три схемы.
## Производные волны не выравниваем: измеряем всё влияние схемы на генерацию.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[args.find("--out") + 1]
	DirAccess.make_dir_recursive_absolute(out)
	var rows: Array[Dictionary] = []
	for index in 6:
		var k: int = [2, 3, 5, 8, 3, 5][index]
		var found := false
		for seed_value in range(1101 + index * 100, 1201 + index * 100):
			var card: Dictionary = PgCard.chain(seed_value, k)[-1]
			var maps: Array[Dictionary] = []
			for pattern: String in ["", "cross_watch", "reserve_fan"]:
				var map := ProcGen._try(seed_value, k, card, 0,
					{"new_layout_schemes": true, "plot_pattern": pattern})
				if map.is_empty():
					break
				maps.append(map)
			if maps.size() != 3:
				continue
			for i in maps.size():
				var map := maps[i]
				var pattern: String = ["none", "cross_watch", "reserve_fan"][i]
				if not PgFilter.check(map).is_empty():
					push_error("Fixture full filter rejected map")
					quit(1)
					return
				var name := "gen_%d_%d_%s" % [seed_value, k, pattern]
				var path := out.path_join(name + ".json")
				FileAccess.open(path, FileAccess.WRITE).store_string(ProcGen.freeze(map))
				rows.append({"seed": seed_value, "k": k, "pattern": pattern,
					"path": path, "digest": ProcGen.digest(map), "name": name,
					"waves_equal": map.waves == maps[0].waves,
					"waves_digest": ProcGen.digest({"waves": map.waves})})
			found = true
			break
		if not found:
			push_error("No matched triple for k=%d" % k)
			quit(1)
			return
	FileAccess.open(out.path_join("manifest.json"), FileAccess.WRITE).store_string(
		JSON.stringify(rows, "\t"))
	print("FIXTURES %d/18 OK" % rows.size())
	quit(0)
