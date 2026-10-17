extends SceneTree
## Кадры итога победы со следствием (этап 5 ROADMAP): карты 1–7 × RU/EN × 1280×720 и 960×540
## поверх настоящего мира той же карты. С --guards — контрольные случаи прежнего потока:
## карта без поля, поражение с полем, финал Прораба с полем, победа с новым разрядом (самый
## высокий итог). Рядом с каждым PNG — JSON: видимые тексты, прямоугольники строки/кнопок,
## метрики прокрутки и найденные нарушения (кириллица/токены в EN, строка в чужом случае,
## перекрытие ряда кнопок). Один процесс, окно меняет размер.
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_victory_aftermath_shots.gd \
##       -- --mute --out=<каталог> [--maps=wasteland,swamp] [--guards] [--locales=ru,en]
## Нужны отдельный APPDATA и NECRO_NO_DEV_BRIDGE=1; кадры требуют окна (не --headless).

const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(960, 540)]
const CAMPAIGN_MAPS: Array[String] = ["wasteland", "gatehouse", "fork", "archive", "bridge",
	"maze", "swamp"]
const REWARDS := {"bounty": 45, "xp": 134, "xp_before": 0, "xp_after": 134}
const RANK_UP := {"bounty": 45, "xp": 134, "xp_before": 0, "xp_after": 134,
	"leveled_up": true, "level": 2, "level_before": 1}

var _out := "res://../local/qa/victory-aftermath-shots"
var _maps: Array[String] = []
var _locales: Array[String] = ["ru", "en"]
var _guards := false
var _failures: Array[String] = []
var _cyrillic := RegEx.create_from_string("[А-Яа-яЁё]")


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--maps="):
			_maps.assign(Array(arg.trim_prefix("--maps=").split(",", false)))
		elif arg.begins_with("--locales="):
			_locales.assign(Array(arg.trim_prefix("--locales=").split(",", false)))
		elif arg == "--guards":
			_guards = true
	if _maps.is_empty():
		_maps.assign(CAMPAIGN_MAPS)
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path("user://victory_aftermath_shots.cfg")
	Settings.path = "user://victory_aftermath_shots_settings.cfg"
	Settings._cfg = null
	Controls.reset()
	_out = ProjectSettings.globalize_path(_out).simplify_path()
	if DirAccess.make_dir_recursive_absolute(_out) != OK:
		push_error("Не удалось создать каталог кадров: " + _out)
		quit(1)
		return
	Campaign.reset()
	for locale in _locales:
		I18n.language = locale
		TranslationServer.set_locale(locale)
		Controls.revision += 1
		for map_id in _maps:
			var m := Campaign.map(map_id)
			if m.is_empty():
				_failures.append("unknown map " + map_id)
				continue
			await _capture(locale, map_id, "victory", true, _stats(m, true), false, REWARDS, true)
		if _guards:
			var first := Campaign.map("wasteland")
			var stats := _stats(first, true)
			var bare := _stats(first, false)
			await _capture(locale, "wasteland", "no_field", true, bare, false, REWARDS, false)
			await _capture(locale, "wasteland", "defeat", false, stats, false, REWARDS, false)
			await _capture(locale, "wasteland", "rank_up", true, stats, false, RANK_UP, true)
			var boss := Campaign.map("boss")
			var complete := _stats(boss, false)
			complete["aftermath"] = String(stats["aftermath"])   # поле подсунуто, показа быть не должно
			await _capture(locale, "boss", "complete", true, complete, true, REWARDS, false)
	I18n.language = "ru"
	TranslationServer.set_locale("ru")
	for failure in _failures:
		print("FAIL ", failure)
	print("VICTORY AFTERMATH SHOTS: %d failures" % _failures.size())
	quit(1 if not _failures.is_empty() else 0)


func _stats(m: Dictionary, with_field: bool) -> Dictionary:
	var stats := {"map_title": String(m.get("title", "")), "cauldron_hp": 160.0,
		"cauldron_max": 200.0, "kills": 84, "lost": 12, "charges": 9, "refreshes": 21,
		"releases_manual": 2, "time": 187.0}
	if with_field:
		stats["aftermath"] = String(m.get("aftermath", ""))
	return stats


## Итог — оверлей над настоящим миром карты (как LegionMain._set_screen/_cover_battle: слои
## мира спрятаны), иначе кадр не показывал бы, как строка читается поверх поля боя.
func _capture(locale: String, map_id: String, kind: String, victory: bool, stats: Dictionary,
		complete: bool, rewards: Dictionary, expect_story: bool) -> void:
	DisplayServer.window_set_size(SIZES[0])
	var scene := load("res://scenes/legion_world.tscn") as PackedScene
	var battle := scene.instantiate() as LegionWorld
	battle.embedded = true
	root.add_child(battle)
	battle.dev["no_waves"] = "1"
	battle.start_map(map_id)
	battle.hold = true
	battle.phase = LegionWorld.Phase.VICTORY if victory else LegionWorld.Phase.DEFEAT
	for layer in battle.find_children("*", "CanvasLayer", true, false):
		(layer as CanvasLayer).visible = false
	var screen := LegionResult.new()
	screen.z_index = LegionMain.OVERLAY_Z
	root.add_child(screen)
	await _frames(4)
	screen.show_result(victory, stats, 3 if victory else 0, victory and not complete, complete,
		rewards)
	await _frames(4)
	var title := "%s_%s_%s" % [locale, map_id, kind]
	for size: Vector2i in SIZES:
		DisplayServer.window_set_size(size)
		await _frames(65)
		await RenderingServer.frame_post_draw
		var path := "%s/%s_%dx%d.png" % [_out, title, size.x, size.y]
		var err := root.get_texture().get_image().save_png(path)
		if err != OK:
			_failures.append("png %s: %d" % [path, err])
		var proof := _proof(screen, locale, map_id, kind, size, expect_story)
		proof["shot"] = path
		proof["png_error"] = err
		var file := FileAccess.open(path.get_basename() + ".json", FileAccess.WRITE)
		file.store_string(JSON.stringify(proof, "\t"))
		file.close()
		print(JSON.stringify({"shot": path, "error": err, "story": proof["story_present"],
			"scrollbar": proof["scrollbar"], "reward_heading_visible": proof["reward_heading_visible"],
			"failures": proof["failures"]}))
	screen.queue_free()
	battle.queue_free()
	await _frames(2)


func _proof(screen: LegionResult, locale: String, map_id: String, kind: String, size: Vector2i,
		expect_story: bool) -> Dictionary:
	var failures: Array[String] = []
	var texts: Array[String] = []
	for node in screen.find_children("*", "", true, false):
		if (node is Label or node is Button) and (node as CanvasItem).is_visible_in_tree():
			var value := String(node.get("text"))
			texts.append(value)
			if locale == "en" and _cyrillic.search(value) != null:
				failures.append("cyrillic: " + value.left(80))
			if value.contains("{key") or value.contains("{mouse:"):
				failures.append("raw token: " + value.left(80))
	var story := screen.find_child("VictoryAftermath", true, false) as Label
	if (story != null) != expect_story:
		failures.append("story %s but expected %s" % ["shown" if story != null else "absent",
			"shown" if expect_story else "absent"])
	var scroll := screen.find_children("*", "ScrollContainer", true, false)[0] as ScrollContainer
	var nav := screen.find_child("Navigation", true, false) as Control
	var reward := screen.find_child("RewardPanel", true, false) as Control
	var viewport := screen.get_viewport_rect()
	var story_rect := Rect2()
	if story != null:
		story_rect = story.get_global_rect()
		if nav != null and story_rect.end.y > nav.get_global_rect().position.y:
			failures.append("story overlaps navigation row")
		if not viewport.encloses(story_rect):
			failures.append("story leaves viewport")
		if story.get_line_count() > 3:
			failures.append("story wraps into %d lines" % story.get_line_count())
	# Награда видна без прокрутки: заголовок панели выше нижней кромки видимой области.
	var reward_visible := false
	if reward != null:
		var heading := reward.find_child("PanelHeading", true, false) as Control
		var scroll_rect := scroll.get_global_rect()
		reward_visible = heading != null \
			and heading.get_global_rect().end.y <= scroll_rect.end.y + 0.5
		if not reward_visible:
			failures.append("reward heading hidden below the fold")
	for failure in failures:
		_failures.append("%s/%s/%s/%d: %s" % [locale, map_id, kind, size.x, failure])
	return {
		"locale": locale, "map": map_id, "case": kind, "window": str(size),
		"viewport": str(viewport.size), "story_present": story != null,
		"story_text": story.text if story != null else "",
		"story_rect": str(story_rect), "story_lines": story.get_line_count() if story != null else 0,
		"navigation_rect": str(nav.get_global_rect()) if nav != null else "",
		"content": (scroll.get_child(0) as Control).size.y, "visible": scroll.size.y,
		"scrollbar": scroll.get_v_scroll_bar().visible,
		"reward_heading_visible": reward_visible,
		"texts": texts, "failures": failures,
		"campaign": Campaign._path, "settings": Settings.path,
		"appdata": OS.get_environment("APPDATA"),
	}


func _frames(count: int) -> void:
	for i in count:
		await process_frame
