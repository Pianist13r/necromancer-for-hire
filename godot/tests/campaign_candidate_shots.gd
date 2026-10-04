extends SceneTree
# gdlint: disable=max-returns
## Парные кадры исходной карты и замороженного кандидата на одинаковом кадре и размере.
## До снимка кандидата PgArt должен успешно завершить сборку.

const IDS := ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze", "swamp", "boss"]
const SAVE := "user://campaign_candidate_shots.cfg"
const SIZE := Vector2i(1280, 720)
const SHOT_FRAME := 180
const ART_TIMEOUT_MSEC := 30000

var _out := ""
var _candidate_dir := ""
var _seed := 1
var _art_done := false
var _art_ok := false


func _initialize() -> void:
	# Манифест жёстко пишет fixed_fps: 60, поэтому принимаем только запуск с точной
	# парой --fixed-fps 60: иначе кадры сняты на другой временной базе, а метаданные лгут.
	var fps_declared := false
	var launch_args := OS.get_cmdline_args()
	var fps_flags := 0
	for i: int in range(launch_args.size()):
		if launch_args[i] == "--fixed-fps":
			fps_flags += 1
			fps_declared = i + 1 < launch_args.size() and launch_args[i + 1] == "60"
	fps_declared = fps_declared and fps_flags == 1
	if not fps_declared:
		push_error("Run with --fixed-fps 60: shots manifest hardcodes fixed_fps 60")
		quit(2)
		return
	var args := OS.get_cmdline_user_args()
	_out = _arg(args, "--out")
	_candidate_dir = _arg(args, "--candidate-dir")
	_seed = int(LegionWorld.parse_args().get("seed", 1))
	_run.call_deferred()


func _run() -> void:
	if _out.is_empty() or _candidate_dir.is_empty() or not _out.is_absolute_path() \
			or not _candidate_dir.is_absolute_path():
		push_error("--out and --candidate-dir must be absolute paths")
		quit(2)
		return
	Campaign.set_save_path(SAVE)
	DisplayServer.window_set_size(SIZE)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(_out)
	if mkdir_error != OK:
		push_error("Cannot create shot directory: " + _out)
		quit(2)
		return
	var manifest := _read_manifest()
	if manifest.is_empty():
		quit(2)
		return
	var shots: Array[Dictionary] = []
	for id: String in IDS:
		var candidate := _load_candidate(id, manifest)
		if candidate.is_empty():
			quit(2)
			return
		var before_path := _out.path_join(id + "_before.png")
		if not await _capture(id, {}, before_path, false):
			quit(3)
			return
		shots.append({"id": id, "variant": "before", "path": before_path,
			"side": "canonical", "seed": _seed, "profile": "base",
			"frame": SHOT_FRAME, "size": [SIZE.x, SIZE.y]})
		var after_path := _out.path_join(id + "_after.png")
		if not await _capture(id, candidate, after_path, true):
			quit(3)
			return
		shots.append({"id": id, "variant": "after", "path": after_path,
			"side": "candidate", "seed": _seed, "profile": "base",
			"frame": SHOT_FRAME, "size": [SIZE.x, SIZE.y],
			"digest": ProcGen.digest(candidate)})
	var shot_manifest := FileAccess.open(_out.path_join("shots.json"), FileAccess.WRITE)
	if shot_manifest == null:
		push_error("Cannot write shots.json")
		quit(4)
		return
	shot_manifest.store_string(JSON.stringify({"shots": shots, "frame": SHOT_FRAME,
		"frame_basis": "after_art_ready", "fixed_fps": 60,
		"resolution": [SIZE.x, SIZE.y]}, "\t"))
	var write_error := shot_manifest.get_error()
	shot_manifest.close()
	print(JSON.stringify({"shots": shots, "manifest_error": write_error}))
	quit(0 if write_error == OK and shots.size() == IDS.size() * 2 else 4)


func _capture(id: String, data: Dictionary, path: String, require_art: bool) -> bool:
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world := scene.instantiate() as LegionWorld
	world.embedded = true
	# В обеих версиях отсчёт боя начинается после готовности изображения.
	world.hold = true
	root.add_child(world)
	await process_frame
	if world._base_seed != _seed:
		push_error("World seed differs from shot manifest")
		world.queue_free()
		return false
	world.start_map(id, data)
	if world.map.is_empty() or String(world.map.get("id", "")) != id:
		push_error("World rejected map " + id)
		world.queue_free()
		return false
	_art_done = not require_art
	_art_ok = not require_art
	var terrain := world.ground_view()
	if require_art:
		if terrain == null or terrain._pgart_req == null:
			push_error("PgArt request unavailable for candidate " + id)
			world.queue_free()
			return false
		terrain._pgart_req.ready.connect(_on_art_ready, CONNECT_ONE_SHOT)
		var deadline := Time.get_ticks_msec() + ART_TIMEOUT_MSEC
		while not _art_done and Time.get_ticks_msec() < deadline:
			await process_frame
		if not _art_done or not _art_ok:
			push_error("PgArt failed or timed out for candidate " + id)
			world.queue_free()
			return false
	var first_frame := world._frames
	world.hold = false
	while world._frames - first_frame < SHOT_FRAME:
		await process_frame
	world.hold = true
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		world.queue_free()
		return false
	if image.get_size() != SIZE:
		image.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	var save_error := image.save_png(path)
	world.queue_free()
	await process_frame
	if save_error != OK:
		push_error("PNG write failed (%d): %s" % [save_error, path])
	return save_error == OK


func _on_art_ready(texture: Texture2D) -> void:
	_art_done = true
	_art_ok = texture != null


func _read_manifest() -> Array:
	var path := _candidate_dir.path_join("manifest.json")
	if not FileAccess.file_exists(path):
		push_error("Missing candidate manifest: " + path)
		return []
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not value is Array:
		push_error("Candidate manifest must be an array")
		return []
	return value


func _load_candidate(id: String, manifest: Array) -> Dictionary:
	var row: Dictionary = {}
	for item: Variant in manifest:
		if item is Dictionary and String(item.get("id", "")) == id:
			if not row.is_empty():
				push_error("Duplicate candidate manifest entry: " + id)
				return {}
			row = item
	if row.is_empty() or String(row.get("status", "")) != \
			"candidate_requires_visual_and_gameplay_review" \
			or not row.get("blocking_errors", []).is_empty():
		push_error("Manifest entry missing or blocked: " + id)
		return {}
	var path := _candidate_dir.path_join(id + ".json")
	if not FileAccess.file_exists(path):
		push_error("Missing candidate: " + path)
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not value is Dictionary or String(value.get("id", "")) != id:
		push_error("Candidate id / JSON invalid: " + id)
		return {}
	if ProcGen.digest(value) != String(row.get("digest", "")):
		push_error("Candidate digest mismatch: " + id)
		return {}
	return value


func _arg(args: PackedStringArray, key: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""
