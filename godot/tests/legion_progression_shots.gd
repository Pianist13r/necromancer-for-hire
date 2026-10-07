extends SceneTree
##
## Кадры экранов меты ОДНИМ запуском движка (не по процессу на экран): выбор поправок,
## брифинг с подготовкой, досье (обе вкладки) — каждый на 1280×720 и 960×540, плюс досье
## среднего разряда. Окно меняет размер в процессе (DisplayServer.window_set_size), поэтому серия
## не дёргает фокус владельца многократно.
##
##   "$GODOT" --path godot --script res://tests/legion_progression_shots.gd -- --mute
## Путь вывода — OUT (по умолчанию batches под иконкой-сессией).
##

const TEST_PATH := "user://legion_progression_shots.cfg"
const OUT := "C:/AI/necro/batches/legion/progression-1006"
const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(960, 540)]
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_rng.seed = 1
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)

	Campaign.reset()
	Campaign.unlock_all()
	var picker := UpgradePicker.new()
	await _capture(picker, "upgrade", func() -> void:
		picker.offer(Campaign.offer_upgrades(_rng)))

	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_bounty(900)
	Campaign.add_upgrade(StringName(AmendmentDb.ORDER[0]))
	# Подготовка — на брифинге (D-1007-P1): кадр брифинга с панелью и полосой «Действует».
	var brief := Briefing.new()
	await _capture(brief, "briefing_prep", func() -> void:
		brief.populate(Campaign.maps()[1]))

	Campaign.reset()
	Campaign.unlock_all()
	Campaign._add_hero_xp(4000)
	await _capture(HeroScreen.new(), "hero")

	Campaign.reset()
	Campaign.unlock_all()
	Campaign._add_hero_xp(1180)
	await _capture(HeroScreen.new(), "hero_part")

	# D-1007-P2: та же «Досье» на вкладке «Артефакты» (артефакты кампании, синергия собрана).
	Campaign.reset()
	var arts: Array[StringName] = [&"clip_of_fate", &"lightning_rod", &"golden_pen"]
	Campaign.set_run_items(arts)
	var items_screen := HeroScreen.new()
	await _capture(items_screen, "dossier_items", func() -> void:
		items_screen.view.show_tab(DossierView.TAB_ITEMS))

	var abs_path := ProjectSettings.globalize_path(TEST_PATH)
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(abs_path)
	print("PROGRESSION SHOTS: done")
	quit()


func _capture(screen: Control, name: String, setup := Callable()) -> void:
	root.add_child(screen)
	await process_frame
	if setup.is_valid():
		setup.call()
	await process_frame
	for size: Vector2i in SIZES:
		DisplayServer.window_set_size(size)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		var path := "%s/%s_%d.png" % [OUT, name, size.x]
		var err := img.save_png(path)
		print(JSON.stringify({"shot": path, "error": err}))
	screen.queue_free()
	await process_frame
