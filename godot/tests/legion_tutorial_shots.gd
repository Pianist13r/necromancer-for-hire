extends SceneTree
##
## Кадры плашки и метки каждого шага обучения в игровом масштабе 1280×720 — для приёмки глазами
## (не гейт: нужен настоящий рендер, поэтому запуск ОКНОМ, без --headless). Один процесс на все
## девять шагов: окно появляется один раз. Шаг ставится через API мира (force_step), как
## --dev tutorial_step=N, затем SHOT_FRAMES кадров — строй успевает встать, метка — запульсировать.
## Сохранение — во временный файл (Campaign.set_save_path), настоящее владельца не трогается.
##
##   "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720
##       --script res://tests/legion_tutorial_shots.gd -- --mute --out C:/AI/necro/batches/legion/tutorial
##
## Файлы step1_draw.png … step9_hero_e.png; итог — строка JSON {"shots": [...]}.
##

const TEST_PATH := "user://legion_tutorial_shots.cfg"
const SHOT_FRAMES := 150
const SIZE := Vector2i(1280, 720)

var _out := "C:/AI/necro/batches/legion/tutorial"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		_out = args[i + 1]
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	DisplayServer.window_set_size(SIZE)
	DirAccess.make_dir_recursive_absolute(_out)
	var saved: Array[String] = []
	var steps := LegionTutorial.parse(LegionWorld.load_map("wasteland"))
	for k in steps.size():
		Campaign.reset()
		var scene: PackedScene = load("res://scenes/legion_world.tscn")
		var w := scene.instantiate() as LegionWorld
		w.embedded = true
		root.add_child(w)
		await process_frame
		w.start_map("wasteland")
		w.start_tutorial()
		w.tutorial.force_step(k)
		for f in SHOT_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		if img.get_size() != SIZE:
			img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
		var path := "%s/step%d_%s.png" % [_out, k + 1, String(steps[k]["id"])]
		if img.save_png(path) == OK:
			saved.append(path)
		w.queue_free()
		await process_frame
	print(JSON.stringify({"shots": saved}))
	quit(0 if saved.size() == steps.size() else 1)
