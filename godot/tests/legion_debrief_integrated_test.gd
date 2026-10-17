extends SceneTree
## Main/World integration of debrief advice; isolated campaign save and optional GPU captures.

const SAVE := "user://debrief_integrated_campaign.cfg"
const SETTINGS := "user://debrief_integrated_settings.cfg"
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(960, 540)]

var checks := 0
var failures := 0
var main: LegionMain
var out := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL ", label)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _ready_main() -> void:
	if main != null:
		main.queue_free()
		await _frames(3)
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	main = LegionMain.new()
	root.add_child(main)
	await _frames(3)
	main._args["dev"] = {"endless_stub": "1", "endless_open": "1"}
	main._ensure_world().dev["no_waves"] = "1"


func _screen_texts(screen: Control) -> Array[String]:
	var texts: Array[String] = []
	for node in screen.find_children("*", "Label", true, false):
		if (node as CanvasItem).is_visible_in_tree():
			texts.append(String((node as Label).text))
	return texts


func _advice(screen: Control) -> String:
	for line in _screen_texts(screen):
		if line.begins_with(I18n.t("Вариант для повтора: %s").trim_suffix("%s")):
			return line
	return ""


func _capture(screen: Control, title: String) -> void:
	if out.is_empty():
		return
	for locale in ["ru", "en"]:
		I18n.language = locale
		TranslationServer.set_locale(locale)
		Controls.revision += 1
		# The real Main outcome has already established the stats/context. Re-render its
		# visible screen in the other locale without changing rewards or save state.
		if screen is LegionResult:
			var r := screen as LegionResult
			var data: Dictionary = r.get_meta("qa_result_data")
			r.show_result(data["victory"], data["stats"], data["stars"], data["has_next"],
				data["complete"], data["rewards"], data["show_retry"], data["show_maps"])
		elif screen is Necrolog:
			var n := screen as Necrolog
			var data: Dictionary = n.get_meta("qa_necrolog_data")
			n.show_report(data["report"], data["foe"], data["map_title"])
		await _frames(5)
		for size in SIZES:
			DisplayServer.window_set_size(size)
			await _frames(35)
			await RenderingServer.frame_post_draw
			var path := "%s/%s_%s_%dx%d.png" % [out, title, locale, size.x, size.y]
			_check(root.get_texture().get_image().save_png(path) == OK, "capture " + path)
			var proof := {"case": title, "locale": locale, "window": [size.x, size.y],
				"texts": _screen_texts(screen), "advice": _advice(screen)}
			var nav := screen.find_child("Navigation", true, false) as Control
			var debrief := screen.find_child("BattleDebrief", true, false) as Control
			if nav != null and debrief != null:
				proof["navigation_rect"] = str(nav.get_global_rect())
				proof["debrief_rect"] = str(debrief.get_global_rect())
				_check(debrief.get_global_rect().end.y < nav.get_global_rect().position.y,
					"debrief above navigation " + path)
			if screen is LegionResult:
				var reward := screen.find_child("RewardPanel", true, false) as Control
				var scroll := screen.find_children("*", "ScrollContainer", true, false)[0] as ScrollContainer
				var heading := reward.find_child("PanelHeading", true, false) as Control
				proof["reward_rect"] = str(reward.get_global_rect())
				proof["reward_heading_rect"] = str(heading.get_global_rect())
				proof["scroll_rect"] = str(scroll.get_global_rect())
				_check(heading.get_global_rect().end.y <= scroll.get_global_rect().end.y,
					"reward heading visible " + path)
			var file := FileAccess.open(path.get_basename() + ".json", FileAccess.WRITE)
			if file != null:
				file.store_string(JSON.stringify(proof, "\t"))
				file.close()
	I18n.language = "ru"
	TranslationServer.set_locale("ru")


func _run() -> void:
	Settings.path = SETTINGS
	Settings._cfg = ConfigFile.new()
	Settings.apply()
	Controls.reset()
	I18n.language = "ru"
	TranslationServer.set_locale("ru")
	if not out.is_empty():
		out = ProjectSettings.globalize_path(out).simplify_path()
		_check(DirAccess.make_dir_recursive_absolute(out) == OK, "capture directory")
	await _campaign_fork()
	await _campaign_wasteland()
	await _endless(true)
	await _endless(false)
	await _legacy_no_context()
	if main != null:
		main.queue_free()
		await _frames(3)
	print("DEBRIEF INTEGRATED: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)


func _campaign_fork() -> void:
	await _ready_main()
	Campaign.record_result("wasteland", true, 1.0)
	Campaign.record_result("gatehouse", true, 1.0)
	main.start_battle("fork")
	await _frames(4)
	var world := main.world
	var available := main._debrief_available()
	_check(available == {"kind_unlocked_guard": true, "ability_unlocked_e": true,
		"kind_unlocked_clerk": false, "ability_unlocked_q": true},
		"fork real unlocks: guard/E/Q yes, clerk no")
	var road := String(world.map["roads"][0]["id"])
	world.damage_cauldron(40.0, "ghost", 0, {"road": road, "wave": 2})
	world.damage_cauldron(20.0, "zombie", 0, {"road": road, "wave": 2})
	var actual := world.final_stats(true)
	_check(BattleDebrief.lines(actual["debrief"]).size() == 3,
		"World.final_stats carries measured source, road, wave")
	world.force_end(true)
	await _frames(5)
	_check(main.screen is LegionResult, "campaign victory reaches result")
	_check(Campaign.stat(&"kind_unlocked_clerk") > 0.5,
		"victory opens archive clerk after battle snapshot")
	if main.screen is LegionResult:
		var screen := main.screen as LegionResult
		var advice := _advice(screen)
		_check(advice.contains("призраки — Ку") and not advice.contains("аудит"),
			"campaign result advises available Q, never locked clerk")
		var debrief := screen.find_child("BattleDebrief", true, false) as Control
		_check(debrief != null and debrief.get_child_count() == 5,
			"campaign result shows three facts plus one advice")
		_check(screen.find_child("RewardPanel", true, false) != null
			and screen.find_child("NavPrimary", true, false) != null,
			"reward and navigation remain")
		var stats := {"map_title": String(world.map["title"]), "debrief": actual["debrief"],
			"debrief_available": available, "cauldron_hp": world.cauldron_hp,
			"cauldron_max": world.cauldron_max, "aftermath": world.map.get("aftermath", "")}
		screen.set_meta("qa_result_data", {"victory": true, "stats": stats, "stars": 3,
			"has_next": true, "complete": false,
			"rewards": {"bounty": 45, "xp": 134, "xp_before": 0, "xp_after": 134},
			"show_retry": true, "show_maps": true})
		await _capture(screen, "campaign_ghost")


func _campaign_wasteland() -> void:
	await _ready_main()
	main.start_battle("wasteland")
	await _frames(4)
	var world := main.world
	var available := main._debrief_available()
	_check(not available["kind_unlocked_guard"] and not available["ability_unlocked_e"]
		and not available["kind_unlocked_clerk"] and available["ability_unlocked_q"],
		"wasteland real unlocks: guard/E/clerk locked")
	var road := String(world.map["roads"][0]["id"])
	world.damage_cauldron(40.0, "shield_inspector", 0, {"road": road, "wave": 1})
	world.force_end(false)
	await _frames(5)
	_check(main.screen is LegionResult and _advice(main.screen).contains("щиты — с фланга"),
		"campaign defeat never advises locked guard/E")


func _endless(victory: bool) -> void:
	await _ready_main()
	main._start_endless_flow(false)
	var map_id := LegionEndless.object_map_id(LegionRunStore.endless_seed(false),
		LegionRunStore.endless_k(false), true)
	main._start_endless_battle(map_id)
	await _frames(4)
	var world := main.world
	var available := main._debrief_available()
	_check(available["ability_unlocked_q"] and not available["kind_unlocked_clerk"],
		"endless fresh-save tools match world campaign unlocks")
	var road := String(world.map["roads"][0]["id"])
	world.damage_cauldron(40.0, "ghost", 0, {"road": road, "wave": 1})
	var actual := world.final_stats(victory)
	world.force_end(victory)
	await _frames(5)
	_check(main.screen is LegionResult if victory else main.screen is Necrolog,
		"endless reaches expected result/necrolog")
	if main.screen == null:
		return
	_check(not _advice(main.screen).is_empty(), "endless advice visible after outcome")
	if victory and main.screen is LegionResult:
		var screen := main.screen as LegionResult
		var stats := {"map_title": String(world.map["title"]), "debrief": actual["debrief"],
			"debrief_available": available, "cauldron_hp": world.cauldron_hp,
			"cauldron_max": world.cauldron_max, "tenure": 1, "souls": 0}
		screen.set_meta("qa_result_data", {"victory": true, "stats": stats, "stars": 0,
			"has_next": true, "complete": false, "rewards": {},
			"show_retry": false, "show_maps": false})
		await _capture(screen, "endless_victory")
	elif not victory and main.screen is Necrolog:
		var screen := main.screen as Necrolog
		var report := {"tenure": 0, "souls": 0, "debrief": actual["debrief"],
			"debrief_available": available}
		screen.set_meta("qa_necrolog_data", {"report": report, "foe": "ghost",
			"map_title": String(world.map["title"])})
		await _capture(screen, "endless_necrolog")


func _legacy_no_context() -> void:
	var report := {"damage": 20.0, "sources": {"ghost": 20.0},
		"roads": {"west": 20.0}, "waves": {"2": 20.0}, "first_at": 40.0}
	var screen := LegionResult.new()
	root.add_child(screen)
	await _frames(2)
	screen.show_result(true, {"map_title": "Пустырь", "debrief": report}, 3, true)
	await _frames(2)
	var debrief := screen.find_child("BattleDebrief", true, false) as Control
	_check(debrief != null and debrief.get_child_count() == 4 and _advice(screen).is_empty(),
		"legacy no-availability screen keeps only three facts")
	var locked := {"kind_unlocked_guard": false, "ability_unlocked_e": false,
		"kind_unlocked_clerk": false, "ability_unlocked_q": false}
	screen.show_result(true, {"map_title": "Пустырь", "debrief": report,
		"debrief_available": locked}, 3, true)
	await _frames(2)
	_check(_advice(screen).contains("призраки — свободные бойцы")
		and not _advice(screen).contains("Ку") and not _advice(screen).contains("аудит"),
		"synthetic locked Q/clerk UI falls back to available free fighters")
	screen.queue_free()
	await _frames(2)
