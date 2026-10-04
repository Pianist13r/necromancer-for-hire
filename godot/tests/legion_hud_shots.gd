extends SceneTree
##
## Кадры приёмки HUD v17 (не тест гейта, DESIGN_V17 §1): телеграф угрозы у края до волны и на
## выходе группы, виньетка урона Котлу, тосты-бумажки, меню участка (пустого и с постройкой),
## обучение первой карты с тостом. Окном, не headless (headless кадр не снимает):
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_hud_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/v17/hud
##
## Сохранение — свой файл: настоящий user://legion.cfg владельца не читается и не пишется.
##

const SAVE := "user://legion_hud_shots_test.cfg"

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
	await _battle_shots()
	await _tutorial_shot()
	quit(0)


func _new_world(map_id: String) -> void:
	if w != null:
		w.queue_free()
		await process_frame
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.start_map(map_id)


func _battle_shots() -> void:
	await _new_world("fork")
	# до первой волны — за 2.5 с загорается край со стороны ворот
	var wr := w.wave_runner
	var guard := 0
	while wr.next_start_in() > 2.5 and guard < 6000:
		await process_frame
		guard += 1
	await _shot("threat_before_wave.png")
	# группа выходит: край горит, пока идёт выход
	for f in 180:
		await process_frame
	await _shot("threat_spawning.png")
	# урон Котлу: виньетка, вспышка блока «Котёл», хвост на полосе
	# 10 кадров: общая красная вспышка мира (LegionAudio, Juice.flash) уже спала, виньетка HUD —
	# ещё видна; так кадр показывает именно HUD-часть отклика
	w.damage_cauldron(24.0)
	for f in 7:
		await process_frame
	await _shot("cauldron_hit.png")
	# тосты трёх видов
	w.toast("Договор подписан — строй держит рубеж", &"info")
	w.toast("Мало маны: договор длиннее, чем хватает чернил", &"warn")
	w.toast("Волна 2: зомби и курьеры с севера", &"wave")
	for f in 20:
		await process_frame
	await _shot("toasts.png")
	# меню участка: пустая площадка и постройка
	w.souls = 60
	w.souls_changed.emit(w.souls)
	var st := w.staff
	var p0: Dictionary = st.plots[0]
	w.plot_menu.open(p0, p0["pos"])
	await _shot("plot_menu_empty.png")
	w.souls = 1000
	st.build(st.plots[1], LegionCfg.KIND_GUARD)
	w.souls = 25
	w.souls_changed.emit(w.souls)
	var p1: Dictionary = st.plots[1]
	w.plot_menu.open(p1, p1["pos"])
	await _shot("plot_menu_building.png")
	w.plot_menu.close()


func _tutorial_shot() -> void:
	await _new_world("wasteland")
	w.start_tutorial()
	for f in 90:
		await process_frame
	w.toast("Подсказка: договор — это линия, которую держит строй", &"info")
	for f in 20:
		await process_frame
	await _shot("tutorial_toast.png")


func _shot(file: String) -> void:
	for f in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := out.path_join(file)
	var err := root.get_texture().get_image().save_png(path)
	print(JSON.stringify({"shot": path, "error": err}))
