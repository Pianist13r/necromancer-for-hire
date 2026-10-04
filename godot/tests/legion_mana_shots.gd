extends SceneTree
##
## Кадры приёмки линии economy-mana (D-0927-140, D-0927-135; не тест гейта): панель способностей
## с ценами в мане — всё по карману, часть красная, миг отказа; меню постройки со «Срочным
## наймом». Окном, не headless (headless кадр не снимает):
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_mana_shots.gd
##       -- --mute --out C:/AI/necro/batches/procgen/economy/shots
##
## Сохранение — свой файл: настоящий user://legion.cfg владельца не читается и не пишется.
##

const SAVE := "user://legion_mana_shots_test.cfg"

var w: LegionWorld
var out := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://"
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.start_map("fork")
	for f in 60:
		await process_frame
	w.contracts.mana = w.contracts.mana_max
	await _shot("abilities_full.png")
	# 22 маны: Ку (25) и Дубль-вэ (30) не по карману, Е и «Сбор» (20) — да
	w.contracts.mana_regen = 0.0
	w.contracts.mana = 22.0
	await _shot("abilities_short.png")
	w.hero.cast(LegionHero.SLOT_Q, w.cauldron_pos)
	w.rally(w.cauldron_pos)
	w.contracts.mana = 5.0
	w.hero.cast(LegionHero.SLOT_E, w.cauldron_pos)
	await _shot("abilities_denied.png")
	# меню постройки со «Срочным наймом» (D-0927-135): Бытовка, двое павших
	w.souls = 1000
	var st := w.staff
	var b := st.build(st.plots[0], LegionCfg.KIND_LABORER)
	for f in 240:
		await process_frame
	var n := 0
	for u in w.units:
		if u.alive and u.home == b and n < 2:
			u.take_damage(100000.0, u.position)
			n += 1
	for f in 5:
		await process_frame
	w.souls = 120
	w.souls_changed.emit(w.souls)
	w.plot_menu.open(st.plots[0], st.plots[0]["pos"])
	await _shot("plot_menu_rush.png")
	quit(0)


func _shot(file: String) -> void:
	for f in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := out.path_join(file)
	var err := root.get_texture().get_image().save_png(path)
	print(JSON.stringify({"shot": path, "error": err}))
