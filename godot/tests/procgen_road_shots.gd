extends SceneTree
## Кадры приёмки дороги сборки (сессия road-1003): для каждой карты — картинка PgArt целиком
## (art_<имя>.png, 1920×1080, без боя и HUD — для крупных кропов дороги) и кадр боя с HUD
## (game_<имя>.png, 1280×720, кадр SHOT_FRAME после готовности картинки). Нужен настоящий
## рендер (окно), --fixed-fps 60 и --mute.
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/procgen_road_shots.gd -- --mute \
##       --out C:/AI/necro/batches/procgen/road-1003/after \
##       [--candidate-dir C:/AI/necro/batches/campaign-gen/v2] [--maps gen:7:5,pvp:duel]
##
## --candidate-dir — замороженные кандидаты кампании (<id>.json, их id — имена кадров);
## --maps — id карт через запятую (gen:<сид>:<k>, pvp:duel, …). Печатает строку JSON на карту.

const SIZE := Vector2i(1280, 720)
const SHOT_FRAME := 120
const ART_TIMEOUT_MSEC := 30000
const CANDIDATES := ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze", "swamp",
	"boss"]

var _art: Texture2D = null
var _art_done := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var out := _arg(argv, "--out")
	var cand_dir := _arg(argv, "--candidate-dir")
	var maps := _arg(argv, "--maps")
	if out.is_empty():
		push_error("--out required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://procgen_road_shots.cfg")
	DisplayServer.window_set_size(SIZE)
	var jobs: Array[Dictionary] = []
	if not cand_dir.is_empty():
		for id: String in CANDIDATES:
			var path := cand_dir.path_join(id + ".json")
			var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if data is Dictionary:
				jobs.append({"id": id, "name": id, "data": data})
	if not maps.is_empty():
		for id in maps.split(","):
			jobs.append({"id": id, "name": id.replace(":", "_"), "data": {}})
	var failed := 0
	for job in jobs:
		if not await _capture(job, out):
			failed += 1
	quit(1 if failed > 0 else 0)


func _capture(job: Dictionary, out: String) -> bool:
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world := scene.instantiate() as LegionWorld
	world.embedded = true
	world.hold = true
	root.add_child(world)
	await process_frame
	var t0 := Time.get_ticks_msec()
	world.start_map(String(job.id), job.data)
	var terrain := world.ground_view()
	if terrain == null or terrain._pgart_req == null:
		push_error("нет запроса PgArt: " + String(job.id))
		world.queue_free()
		return false
	_art_done = false
	_art = null
	terrain._pgart_req.ready.connect(_on_art, CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + ART_TIMEOUT_MSEC
	while not _art_done and Time.get_ticks_msec() < deadline:
		await process_frame
	var ms := Time.get_ticks_msec() - t0
	if _art == null:
		push_error("PgArt не собрал картинку: " + String(job.id))
		world.queue_free()
		return false
	_art.get_image().save_png(out.path_join("art_%s.png" % job.name))
	var first := world._frames
	world.hold = false
	while world._frames - first < SHOT_FRAME:
		await process_frame
	world.hold = true
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img.get_size() != SIZE:
		img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	img.save_png(out.path_join("game_%s.png" % job.name))
	print(JSON.stringify({"map": job.id, "art_ms": ms}))
	world.queue_free()
	await process_frame
	return true


func _on_art(tex: Texture2D) -> void:
	_art = tex
	_art_done = true


func _arg(args: PackedStringArray, key: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""
