extends SceneTree
##
## Кампания по переписке (сессия 180f1168, 27.09.2026): ход меню — кнопки, надписи, прогресс.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_corr_campaign_test.gd -- --mute
##
## Поддельный главный узел (world = null, screen — Control с кнопкой и надписью): corr_play в
## режиме кампании пишет turn_000.json с "mode": "menu", кнопкой «Начать кампанию» и её центром
## для tap, надписью экрана и прогрессом сохранения; мира ещё нет — это не ход боя. Скрытая кнопка
## и кнопка за экраном в список не попадают. Итог «LEGION CORR CAMPAIGN: N/M OK», код 1 при сбое.
##

const SAVE := "user://legion_corr_campaign_test.cfg"
const DIR := "user://legion_corr_campaign_test"
const CORR := "res://scripts/dev/corr_play.gd"

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var dir_abs := ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	for f in DirAccess.get_files_at(dir_abs):
		DirAccess.remove_absolute(dir_abs.path_join(f))

	var fake_src := GDScript.new()
	fake_src.source_code = "extends Node\nvar world = null\nvar screen: Control = null\n"
	fake_src.reload()
	var fake: Node = Node.new()
	fake.set_script(fake_src)
	root.add_child(fake)
	var screen := Control.new()
	screen.size = Vector2(1280, 720)
	fake.add_child(screen)
	fake.set("screen", screen)
	var title := Label.new()
	title.text = "Некромант по найму"
	title.position = Vector2(400, 150)
	screen.add_child(title)
	var start := Button.new()
	start.text = "Начать кампанию"
	start.position = Vector2(540, 320)
	start.size = Vector2(200, 40)
	screen.add_child(start)
	var hidden := Button.new()
	hidden.text = "Скрытая"
	hidden.position = Vector2(100, 100)
	hidden.size = Vector2(80, 30)
	hidden.visible = false
	screen.add_child(hidden)
	var offscreen := Button.new()
	offscreen.text = "За экраном"
	offscreen.position = Vector2(-500, -500)
	offscreen.size = Vector2(80, 30)
	screen.add_child(offscreen)

	var corr: Node = (load(CORR) as GDScript).new()
	_check(corr.has_method("setup_main"), "corr_play умеет режим кампании (setup_main)")
	if not corr.has_method("setup_main"):
		_finish()
		return
	corr.call("setup_main", fake, dir_abs)
	root.add_child(corr)

	var path := dir_abs.path_join("turn_000.json")
	for i in 600:
		if FileAccess.file_exists(path):
			break
		await process_frame
	_check(FileAccess.file_exists(path), "первый ход меню записан (turn_000.json)")
	if not FileAccess.file_exists(path):
		_finish()
		return
	await process_frame
	var st: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(String(st.get("mode", "")) == "menu", "мира нет — ход меню, а не боя")
	var btns: Array = st.get("buttons", [])
	var found := {}
	for b: Dictionary in btns:
		found[String(b.get("text", ""))] = b
	_check(found.has("Начать кампанию"), "кнопка экрана в списке")
	if found.has("Начать кампанию"):
		var at: Array = found["Начать кампанию"]["at"]
		_check(int(at[0]) == 640 and int(at[1]) == 340, "центр кнопки для tap = (640, 340): %s" % [at])
		_check(not bool(found["Начать кампанию"]["off"]), "кнопка не отмечена закрытой")
	_check(not found.has("Скрытая"), "скрытая кнопка не в списке")
	_check(not found.has("За экраном"), "кнопка за экраном не в списке")
	var texts: Array = st.get("texts", [])
	_check(texts.has("Некромант по найму"), "надпись экрана в texts")
	var camp: Dictionary = st.get("camp", {})
	_check(camp.has("stars") and camp.has("bounty") and camp.has("pending_reward"),
		"прогресс сохранения в camp")
	_check(int(Dictionary(camp.get("stars", {})).get("wasteland", -1)) == 0,
		"«Пустырь» открыт и без звёзд на чистом сохранении")
	corr.queue_free()
	# настоящее сохранение при любом написании пути — отказ (verifier 180f1168: обход стирал его)
	for pth: String in ["user://legion.cfg", "user://LEGION.cfg", "user://./legion.cfg",
			ProjectSettings.globalize_path("user://legion.cfg"), " user://legion.cfg "]:
		_check(Campaign.is_real_save_path(pth), "настоящее сохранение узнаётся: «%s»" % pth)
	_check(not Campaign.is_real_save_path("user://corr_x.cfg"), "своё сохранение — не настоящее")
	# белый список для --dev save (второй круг verifier: потоки NTFS, имена 8.3, длинный префикс)
	var bs := String.chr(92)
	for bad: String in ["user://legion.cfg", "user://LEGION.cfg", "user://settings.cfg",
			"user://legion.cfg::$DATA", "user://./legion.cfg", "user://../x/legion.cfg",
			bs + bs + "?" + bs + "C:" + bs + "x" + bs + "legion.cfg", "C:/x/corr.cfg",
			"user://corr x.cfg", "user://corr.cfg.", "",
			# B-386 (4): настоящие файлы игры — их стёр бы Campaign.reset()
			"user://net.cfg", "user://NET.cfg", "user://legion_standalone.cfg",
			"user://Legion_Standalone.cfg"]:
		_check(not Campaign.is_safe_dev_save(bad), "--dev save отклонён: «%s»" % bad)
	for good: String in ["user://corr_camp_s1.cfg", "user://exe_probe.cfg", " user://Corr-2.cfg "]:
		_check(Campaign.is_safe_dev_save(good), "--dev save принят: «%s»" % good)
	_finish()


func _finish() -> void:
	Campaign.reset()
	print("LEGION CORR CAMPAIGN: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
