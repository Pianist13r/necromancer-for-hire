extends SceneTree
## Regression first: Archive clerk plot and quieter generated-map introduction.
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL ", label)


func _run() -> void:
	Campaign.set_save_path("user://legion_procgen_1008_test.cfg")
	var candidate_script := load("res://tests/campaign_candidates.gd")
	var source := ProcGen.thaw(FileAccess.get_file_as_string("res://assets/legion/maps/archive.json"))
	var map := ProcGen.generate(927203, 4, {"card": {"biome": "office",
		"archetype": "shelves", "mirror": false, "flip": false, "quirks": []}})
	check(not map.is_empty(), "Archive seed 927203 generates")
	if not map.is_empty():
		map["id"] = "archive"
		map["lessons"] = source["lessons"].duplicate(true)
		var issues: Array[String] = []
		candidate_script._remap_lessons(map, issues)
		check(issues.is_empty(), "Archive lessons remap: " + str(issues))
		for lesson: Dictionary in map.lessons:
			if lesson.id == "clerk":
				for plot: Dictionary in map.plots:
					if plot.id == lesson.mark.plot:
						check(plot.preferred_kinds[0] == "clerk", "Archive bot chooses clerk first")
		for point in PgArtHarmony.contact_points(map):
			check(point.k != "plot", "empty PvE plots have no baked stain")
	Campaign.reset()
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(7)
	var saved: Dictionary = Campaign.raw_file().get_value(Campaign.ENDLESS_SECTION, "procgen", {})
	check(saved.get("version", 0) == ProcGen.VERSION, "run persists procgen.version")
	Campaign.raw_file().erase_section_key(Campaign.ENDLESS_SECTION, "procgen")
	check("Карта собрана новой версией генератора" in LegionWorld.load_map("gen:7:1").hint,
		"legacy run warns through displayed map hint")
	Campaign.use_daily_scope()
	LegionRunStore.endless_start(1, "2026-10-08")
	LegionRunStore.endless_end_run()
	var done: Dictionary = Campaign.raw_file().get_value(Campaign.DAILY_SECTION, "done_dates", {})
	check(done.has("2026-10-08|v2"), "daily completion key includes version")
	Campaign.reset()
	Campaign.use_campaign_scope()
	var w := LegionWorld.new()
	w.embedded = true
	root.add_child(w)
	await process_frame
	if not map.is_empty():
		map["unlocks"] = source["unlocks"].duplicate()
		Campaign.record_result("fork", true, 1.0)  # Штатный доступ к Архиву и его видам.
		w.in_campaign = true
		w.start_map("archive", map)
		w.set_process(false)
		check(w.staff.kind_unlocked(&"clerk"), "Archive campaign progression unlocks clerk")
		w.start_lessons(true)
		w.tutorial.force_lesson(&"clerk")
		check(not Campaign.hint_seen(LegionTutorial.flag("archive", &"clerk")),
			"clerk lesson is unfinished before bot construction")
		var bot := LegionBot.new()
		bot.setup(w, &"selective", w.map)
		w.souls = 10000  # Проверяем выбор постройки и сигнал, не экономику полного боя.
		for i in w.staff.plots.size():
			bot._build_step()
		var clerk_built := false
		for plot: Dictionary in w.staff.plots:
			var building: LegionBuilding = plot["building"]
			clerk_built = clerk_built or (building != null and building.kind == &"clerk")
		check(clerk_built, "real bot builds clerk on Archive candidate")
		w.tutorial.tick(1.0 / 60.0)
		check(Campaign.hint_seen(LegionTutorial.flag("archive", &"clerk")),
			"building_built:clerk completes the real lesson")
		w.in_campaign = false
	w.start_map("gen:7:3")
	w.set_process(false)
	var hint := w.obstacle_hint
	hint.tick(0.2)
	var first := hint.modulate.a
	hint.tick(0.8)
	check(first <= 0.25, "generated intro stays quiet")
	check(hint.modulate.a < first, "generated intro fades during flash")
	w.queue_free()
	await process_frame
	check(LegionEndless.daily_seed("2026-10-08") == 4280396687, "daily seed v2 golden value")
	# Fast rejection must agree with the diagnostic filter, including broken dictionaries.
	for fixture: Dictionary in [{}, {"roads": []}, map]:
		check(PgFilter.accepts(fixture) == PgFilter.evaluate(fixture).problems.is_empty(),
			"filter agrees with full diagnostics")
	var rerolled := ProcGen._reroll(927203, 4, {})
	check(not rerolled.is_empty(), "deterministic reroll gives a map")
	if not rerolled.is_empty():
		check(rerolled.id == "gen:927203:4" and rerolled.procgen.seed == 927203 \
			and rerolled.procgen.has("layout_seed"), "reroll preserves request and names source seed")
		check(ProcGen.digest(rerolled) == ProcGen.digest(ProcGen._reroll(927203, 4, {})),
			"reroll repeats exactly")
		check(PgFilter.check(rerolled).is_empty(), "reroll passes full filter")
	var patterns := {}
	var timings: Array[float] = []
	for seed_value in range(1001, 1033):
		var start := Time.get_ticks_usec()
		var plain := ProcGen.generate(seed_value, 3)
		check(plain.procgen.card.get("plot_pattern", "") == "", "schemes disabled by default")
		var generated := ProcGen.generate(seed_value, 3, {"new_layout_schemes": true})
		timings.append((Time.get_ticks_usec() - start) / 1000.0)
		check(not generated.is_empty(), "series seed %d" % seed_value)
		if generated.is_empty():
			continue
		check(PgFilter.check(generated).is_empty(), "full filter seed %d" % seed_value)
		for base in [plain, generated]:
			for mutation in ["valid", "plots", "roads", "bot_lines"]:
				var fixture: Dictionary = base.duplicate(true)
				if mutation != "valid":
					fixture[mutation] = []
				var full: bool = PgFilter.evaluate(fixture).problems.is_empty()
				# Без bot_lines встреча иногда остаётся допустимой: это сравнение путей,
				# а пустые plots/roads — гарантированно негодные словари.
				if mutation != "bot_lines":
					check(full == (mutation == "valid"),
						"filter expected verdict %d %s" % [seed_value, mutation])
				check(PgFilter.accepts(fixture) == full,
					"fast/full %d %s" % [seed_value, mutation])
		check(PgArtSprites.covered_rocks(generated).size() == generated.get("rocks", []).size(),
			"every generated obstacle has a catalog sprite")
		var pattern := String(generated.procgen.card.get("plot_pattern", ""))
		if pattern.is_empty():
			continue
		patterns[pattern] = true
		var broken := generated.duplicate(true)
		broken.procgen.layout.plot_pattern.points[0] = [0, 0]
		check(not PgFilter.accepts(broken), "filter rejects fabricated pattern " + pattern)
		check(ProcGen.digest(generated) == ProcGen.digest(ProcGen.generate(seed_value, 3,
			{"new_layout_schemes": true})),
			"pattern remains deterministic")
	check(patterns.has("cross_watch") and patterns.has("reserve_fan"), "both patterns occur")
	timings.sort()
	print("GENERATION median=%.1fms max=%.1fms" % [timings[timings.size() / 2], timings[-1]])
	check(timings[timings.size() / 2] < 5000.0, "no multi-second median regression")
	var pvp := ProcGen.generate(7, 3, {"pvp": true})
	check(not pvp.is_empty(), "PvP control seed generates")
	if not pvp.is_empty():
		var before := ProcGen.digest(pvp)
		var art := Node2D.new()
		var texture := load(PgArtCanvas.resolve_ground_path(pvp)) as Texture2D
		PgArt.compose(art, pvp, texture, 0.4)
		var band := art.get_node_or_null("GroundSeam") as Polygon2D
		check(band != null and band.material is ShaderMaterial, "PvP seam is feathered under objects")
		check(before == ProcGen.digest(pvp), "art never changes PvP gameplay geometry")
		for point in PgArtHarmony.contact_points(pvp):
			check(point.k != "plot", "hidden PvP plots are not revealed by ground stains")
		art.free()
	print("LEGION PROCGEN 1008: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)
