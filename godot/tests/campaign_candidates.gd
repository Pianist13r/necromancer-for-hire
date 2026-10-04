extends SceneTree
## Offline candidates only: --out must be outside res:// and user://.
## Generated waves are candidates, not an approved replacement of campaign balance.
const IDS := ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze", "swamp", "boss"]
const BIOMES := ["ash", "office", "grave", "office", "grave", "grave", "swamp", "site"]
const ARCHS := ["snake", "turnstile", "fork", "shelves", "crossing", "maze", "crypts", "two_fronts"]
const KEEP := ["id", "order", "title", "subtitle", "unlocks", "lessons", "lessons_outro"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := ""
	for i in args.size() - 1:
		if args[i] == "--out":
			out = args[i + 1].replace("\\", "/").simplify_path()
	if not out.is_absolute_path() or out.begins_with("res:") or out.begins_with("user:") \
			or out.to_lower().contains("/assets/legion/maps"):
		push_error("--out requires a separate absolute candidate directory")
		quit(1)
		return
	var mkdir_error := DirAccess.make_dir_recursive_absolute(out)
	if mkdir_error != OK:
		push_error("Cannot create candidate directory: " + out)
		quit(1)
		return
	var report: Array = []
	var failures := 0
	for i in IDS.size():
		var source := ProcGen.thaw(FileAccess.get_file_as_string(
			"res://assets/legion/maps/%s.json" % IDS[i]))
		var card := {"biome": BIOMES[i], "archetype": ARCHS[i], "mirror": false,
			"flip": false, "quirks": ["boss"] if IDS[i] == "boss" else []}
		var seed_value := 927200 + i
		var candidate := ProcGen.generate(seed_value, i + 1, {"card": card})
		if candidate.is_empty():
			report.append({"id": IDS[i], "error": ProcGen.last_error,
				"blocking_errors": [ProcGen.last_error], "status": "blocked"})
			failures += 1
			continue
		var issues: Array[String] = []
		var review_notes: Array[String] = []
		for key: String in KEEP:
			if source.has(key):
				candidate[key] = source[key].duplicate(true) if source[key] is Array \
					or source[key] is Dictionary else source[key]
		_validate_identity(source, candidate, issues)
		_remap_lessons(candidate, issues)
		_ensure_lesson_triggers(candidate, source, issues, review_notes)
		var path := "%s/%s.json" % [out, IDS[i]]
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			var error := "Cannot write candidate: " + path
			push_error(error)
			report.append({"id": IDS[i], "path": path, "blocking_errors": [error],
				"status": "blocked"})
			failures += 1
			continue
		file.store_string(ProcGen.freeze(candidate))
		var write_error := file.get_error()
		file.close()
		if write_error != OK:
			var error := "Candidate write failed (%d): %s" % [write_error, path]
			issues.append(error)
			push_error(error)
		if not issues.is_empty():
			failures += 1
		report.append({"id": IDS[i], "seed": seed_value, "k": i + 1, "card": card,
			"path": path, "digest": ProcGen.digest(candidate), "blocking_errors": issues,
			"lesson_issues": issues, "review_notes": review_notes,
			"status": "blocked" if not issues.is_empty() \
				else "candidate_requires_visual_and_gameplay_review"})
		print("CANDIDATE ", IDS[i], " blocking=", issues, " review=", review_notes)
	var manifest := FileAccess.open(out + "/manifest.json", FileAccess.WRITE)
	if manifest == null:
		push_error("Cannot write candidate manifest: " + out + "/manifest.json")
		quit(1)
		return
	manifest.store_string(JSON.stringify(report, "\t"))
	var manifest_error := manifest.get_error()
	manifest.close()
	if manifest_error != OK:
		push_error("Candidate manifest write failed: %d" % manifest_error)
		failures += 1
	quit(1 if failures else 0)


func _validate_identity(source: Dictionary, candidate: Dictionary, issues: Array[String]) -> void:
	for key: String in ["id", "order", "title", "subtitle", "unlocks", "lessons_outro"]:
		if source.has(key) != candidate.has(key) or source.get(key) != candidate.get(key):
			issues.append("Identity changed: " + key)
	var before: Array = source.get("lessons", [])
	var after: Array = candidate.get("lessons", [])
	if before.size() != after.size():
		issues.append("Identity changed: lessons count")
		return
	for i in before.size():
		var old_lesson: Dictionary = before[i]
		var new_lesson: Dictionary = after[i]
		for key: String in old_lesson:
			# Mark coordinates are intentionally remapped; lesson identity and trigger stay canonical.
			if key == "mark":
				continue
			if old_lesson[key] != new_lesson.get(key):
				issues.append("Identity changed: lesson %s.%s" % [old_lesson.get("id", i), key])


func _remap_lessons(map: Dictionary, issues: Array[String]) -> void:
	var lines: Array = map.get("bot_lines", [])
	var plots: Array = map.get("plots", [])
	for lesson: Dictionary in map.get("lessons", []):
		var mark: Dictionary = lesson.get("mark", {})
		if mark.has("line"):
			if lines.is_empty():
				issues.append("No defence line for " + String(lesson.id))
			else:
				mark["line"] = [lines[0]["a"].duplicate(), lines[0]["b"].duplicate()]
		if mark.has("plot"):
			var wanted := "laborer"
			if String(lesson.id) in ["guard", "clerk"]:
				wanted = String(lesson.id)
			var found := false
			for plot: Dictionary in plots:
				if wanted in plot.get("preferred_kinds", []):
					mark["plot"] = plot["id"]
					found = true
					break
			if not found:
				issues.append("No preferred plot for " + wanted)
		if mark.has("at"):
			# A figure needs free area, not simply the closest point on a road.
			var found := _figure_area(map, float(mark.get("r", 60.0)))
			if found == Vector2.INF:
				issues.append("No figure area for " + String(lesson.id))
			else:
				mark["at"] = PgGeom.arr(found)


func _ensure_lesson_triggers(map: Dictionary, source: Dictionary, issues: Array[String],
		review_notes: Array[String]) -> void:
	var waves: Array = map.get("waves", [])
	var source_waves: Array = source.get("waves", [])
	var roads: Array = map.get("roads", [])
	for lesson: Dictionary in map.get("lessons", []):
		var trigger := String(lesson.get("when", ""))
		if trigger.begins_with("first_foe:"):
			var foe_type := trigger.get_slice(":", 1)
			if not LegionCfg.FOES.has(foe_type):
				issues.append("Unknown lesson foe: " + trigger)
			elif not _has_wave_type(waves, foe_type):
				if roads.is_empty() or waves.is_empty():
					issues.append("Cannot place lesson foe: " + trigger)
				else:
					var source_event := _source_foe_group(source_waves, foe_type)
					var wave_i := int(source_event.get("wave", 1))
					wave_i = clampi(wave_i, 0, waves.size() - 1)
					var road_id := String((roads[0] as Dictionary).get("id", ""))
					if road_id.is_empty():
						issues.append("No candidate road for lesson foe: " + trigger)
					else:
						var source_group: Dictionary = source_event.get("group", {})
						var group := {"road": road_id, "type": foe_type, "count": 1,
							"interval": float(source_group.get("interval", 1.0)),
							"delay": float(source_group.get("delay", 0.0))}
						(waves[wave_i]["groups"] as Array).append(group)
						_add_card_foe(map, foe_type)
						if not _has_wave_type(waves, foe_type):
							issues.append("Generated waves omit lesson foe: " + trigger)
		elif trigger == "first_elite":
			if not _ensure_guaranteed_elite(map, source_waves, roads):
				issues.append("No guaranteed elite for lesson: " + String(lesson.get("id", "item")))
		elif trigger == "pressed":
			review_notes.append("Gameplay check: pressed requires a live segment at PRESS_TRIGGER")


func _has_wave_type(waves: Array, foe_type: String) -> bool:
	for wave: Dictionary in waves:
		for group: Dictionary in wave.get("groups", []):
			if String(group.get("type", "")) == foe_type and int(group.get("count", 1)) > 0:
				return true
	return false


func _source_foe_group(waves: Array, foe_type: String) -> Dictionary:
	for i in waves.size():
		for group: Dictionary in waves[i].get("groups", []):
			if String(group.get("type", "")) == foe_type and int(group.get("count", 1)) > 0:
				return {"wave": i, "group": group}
	return {"wave": mini(1, waves.size() - 1)}


func _ensure_guaranteed_elite(map: Dictionary, source_waves: Array, roads: Array) -> bool:
	var elite_source: Dictionary = {}
	var source_wave_i := 1
	for i in source_waves.size():
		for group: Dictionary in source_waves[i].get("groups", []):
			if int(group.get("elite", 0)) > 0:
				elite_source = group
				source_wave_i = i
				break
		if not elite_source.is_empty():
			break
	var foe_type := String(elite_source.get("type", "zombie"))
	if not CfgItems.ELITE_TYPES.has(foe_type):
		foe_type = "zombie"
	var waves: Array = map.get("waves", [])
	if roads.is_empty() or waves.is_empty():
		return false
	var wave_i := clampi(source_wave_i, 0, waves.size() - 1)
	for group: Dictionary in waves[wave_i].get("groups", []):
		if String(group.get("type", "")) == foe_type and int(group.get("count", 1)) > 0 \
				and int(group.get("elite", 0)) > 0:
			return true
	var road_id := String((roads[0] as Dictionary).get("id", ""))
	if road_id.is_empty():
		return false
	var source_group: Dictionary = elite_source.get("group", elite_source)
	# Preserve the authored Archive guarantee fields; only its road id belongs to the old layout.
	var guaranteed := {"road": road_id, "type": foe_type,
		"count": maxi(1, int(source_group.get("count", 1))),
		"elite": maxi(1, int(source_group.get("elite", 1))),
		"delay": float(source_group.get("delay", 3.0))}
	if source_group.has("interval"):
		guaranteed["interval"] = float(source_group["interval"])
	(waves[wave_i]["groups"] as Array).append(guaranteed)
	_add_card_foe(map, foe_type)
	return true


func _add_card_foe(map: Dictionary, foe_type: String) -> void:
	var procgen: Dictionary = map.get("procgen", {})
	var card: Dictionary = procgen.get("card", {})
	var foes: Array = card.get("foes", [])
	if not foes.has(foe_type):
		foes.append(foe_type)
	card["foes"] = foes
	procgen["card"] = card
	map["procgen"] = procgen


func _figure_area(map: Dictionary, radius: float) -> Vector2:
	# Reuse conservative clearance; roads are permitted for contracts/figures.
	var c: Array = map["cauldron"]
	var free := PgArtScatter.Free.new(map, Vector2(c[0], c[1]))
	free.roads.clear()
	var target := Vector2(c[0], c[1]) + Vector2(180, 0)
	var best := Vector2.INF
	var score := INF
	for y in range(150, 630, 20):
		for x in range(100, 1180, 20):
			var p := Vector2(x, y)
			if free.ok(p, radius) and p.distance_squared_to(target) < score:
				best = p
				score = p.distance_squared_to(target)
	return best
