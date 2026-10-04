extends SceneTree
##
## Кадр сборки картинки карты PgArt без боя и HUD — для приёмки глазами (линия art3). Не тест:
## нужен настоящий рендер (окно), в headless SubViewport не рисует.
##
##   "$GODOT" --path godot --script res://tests/procgen_art_shot.gd -- --mute \
##       --map gen:7:5 --out C:/AI/necro/batches/procgen/art3/art.png [--hide Sprites,CanvasTOP]
##
## --map — id карты (gen:<сид>:<k> или id кампании: тогда собирается из её геометрии, как в
## `--dev pgart=1`); --hide — имена слоёв стопки PgArt.compose, которые спрятать (отладка:
## Ground, CanvasUNDER, Roads, CanvasMID, Sprites, CanvasTOP). Картинка — до пост-шейдера.
##

const FRAMES := 4


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var id := "gen:7:5"
	var out := "user://procgen_art_shot.png"
	var hide := PackedStringArray()
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		var next: String = argv[i + 1] if i + 1 < argv.size() else ""
		match argv[i]:
			"--map":
				id = next
			"--out":
				out = next
			"--hide":
				hide = next.split(",")
	var map := LegionWorld.load_map(id)
	if map.is_empty():
		print("нет карты ", id)
		quit(1)
		return
	var ground_tex: Texture2D = null
	var luma := 0.0
	var gp := PgArtCanvas.resolve_ground_path(map)
	if not gp.is_empty() and ResourceLoader.exists(gp, "Texture2D"):
		ground_tex = load(gp) as Texture2D
		luma = PgArt._sample_grid_luma(ground_tex.get_image())
	var vp := SubViewport.new()
	vp.size = Vector2i(PgArt.TEX_SIZE)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var art := Node2D.new()
	vp.add_child(art)
	var t0 := Time.get_ticks_usec()
	var stats := PgArt.compose(art, map, ground_tex, luma)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	for n in hide:
		var node := art.get_node_or_null(n)
		if node != null:
			(node as CanvasItem).visible = false
	for i in FRAMES:
		await process_frame
	var img := vp.get_texture().get_image()
	img.save_png(out)
	stats.erase("canvas")
	print(JSON.stringify({"shot": out, "compose_ms": snappedf(ms, 0.1), "stats": stats}))
	quit(0)
