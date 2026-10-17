extends SceneTree
## Fixed half-field front contract: every incoming road crosses a usable role-front.

const SEEDS: Array[int] = [1, 2, 3]


func _initialize() -> void:
	_run.call_deferred()


func _v(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


func _run() -> void:
	var cases: Array[Dictionary] = []
	var failures: Array[String] = []
	var role_strip_rejected := false
	for arch: String in PgHalf.ARCHETYPES:
		for seed in SEEDS:
			var map := ProcGen.generate(seed, 1, {"pvp": true, "archetype": arch})
			var tag := "%s:%d" % [arch, seed]
			if map.is_empty():
				failures.append("%s: empty (%s)" % [tag, ProcGen.last_error])
				continue
			var issues := PgPvp.check(map)
			if not issues.is_empty():
				failures.append("%s: %s" % [tag, issues])
			if arch == PgHalf.ARCHETYPES[0] and seed == SEEDS[0]:
				var stripped := map.duplicate(true)
				for line: Dictionary in stripped["bot_lines"]:
					line["role"] = "rear"
				for issue: String in PgPvp.check(stripped):
					role_strip_rejected = role_strip_rejected or issue.contains(
						"без доступного переднего рубежа")
			var lines: Array = map["bot_lines"]
			var paths := LegionMapChecks.road_paths(map)
			var case := {"archetype": arch, "seed": seed, "attempt": map["procgen"]["attempt"],
				"reroll": map["procgen"].get("reroll", 0),
				"layout_seed": map["procgen"].get("layout_seed", seed), "roads": []}
			for road: Dictionary in map["roads"]:
				var id := String(road["id"])
				var path: PackedVector2Array = paths[id]
				var total := PgGeom.length(path)
				var candidates: Array[Dictionary] = []
				for line: Dictionary in lines:
					if String(line.get("role", "")) != "front" or int(line["side"]) != int(road["side"]):
						continue
					var a := _v(line["a"])
					var b := _v(line["b"])
					var hit: Variant = LegionMapChecks.line_cross(a, b, path)
					if hit == null:
						continue
					var at := PgGeom.project(path, hit)
					var tangent := PgGeom.tangent_at(path, at)
					var direction := _v(line["dir"]).normalized()
					var dot := direction.dot(tangent)
					var closest_door := INF
					var assigned := false
					for plot: Dictionary in map["plots"]:
						if int(plot["side"]) != int(road["side"]):
							continue
						closest_door = minf(closest_door, _v(plot["pos"]).distance_to(hit))
						assigned = assigned or (line["id"] in plot["serves_lines"])
					candidates.append({"line": line["id"], "labeled_road": line["road"],
						"at": at, "total": total, "direction_dot_tangent": dot,
						"plot_center_distance": closest_door, "assigned_to_plot": assigned})
				var usable := false
				for candidate: Dictionary in candidates:
					if float(candidate["at"]) > 64.0 and float(candidate["at"]) < total - 130.0 \
							and float(candidate["direction_dot_tangent"]) < -0.7 \
							and bool(candidate["assigned_to_plot"]):
						usable = true
				if not usable:
					failures.append("%s %s: no same-side forward-route front" % [tag, id])
				case["roads"].append({"id": id, "side": road["side"], "usable": usable,
					"candidates": candidates})
			cases.append(case)
	if not role_strip_rejected:
		failures.append("PgPvp.check accepts a map after every role-front is removed")
	var result := {"version": ProcGen.VERSION, "cases": cases, "failures": failures,
		"role_strip_rejected": role_strip_rejected}
	var road_count := 0
	for c: Dictionary in cases:
		road_count += c["roads"].size()
	var qa_out := OS.get_environment("QA_OUT")
	if qa_out != "":
		var file := FileAccess.open(qa_out.path_join("physical.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(result, "  "))
		file.close()
	print("PVP HALF FRONT PHYSICAL: %d/%d roads OK, %d failures" % [
		road_count - failures.size(), road_count, failures.size()])
	for failure in failures:
		print("  FAIL ", failure)
	quit(0 if failures.is_empty() else 1)
