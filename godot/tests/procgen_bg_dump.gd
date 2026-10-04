extends SceneTree
##
## Готовая картинка земли PgArt (сборка + пост-шейдер, как в бою) в PNG — для сравнения «до/после»
## побайтно и приёмки глазами (P5b). Не тест: нужен настоящий рендер (окно).
##
##   "$GODOT" --path godot --script res://tests/procgen_bg_dump.gd -- --mute \
##       --out C:/AI/necro/batches/x --maps gen:7:3,gen:23:3,gen:7:3:pvp
##
## Файл на карту: <out>/<id с «:» → «_»>.png; строка JSON с размером и md5 данных картинки.
##

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := "user://bg_dump"
	var ids := PackedStringArray(["gen:7:3"])
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		var next: String = argv[i + 1] if i + 1 < argv.size() else ""
		match argv[i]:
			"--out":
				out = next
			"--maps":
				ids = next.split(",")
	DirAccess.make_dir_recursive_absolute(out)
	var host := Node.new()
	root.add_child(host)
	var code := 0
	for id in ids:
		var map := LegionWorld.load_map(id)
		if map.is_empty():
			print("нет карты ", id)
			code = 1
			continue
		var req := PgArt.build(map, host)
		if req == null:
			print("headless — PgArt не рисует")
			quit(1)
			return
		var tex: Texture2D = await req.ready
		if tex == null:
			print("сборка не удалась ", id)
			code = 1
			continue
		var img := tex.get_image()
		var path := out.path_join(id.replace(":", "_") + ".png")
		img.save_png(path)
		var md5 := img.get_data().hex_encode().md5_text()
		print(JSON.stringify({"map": id, "out": path, "size": [img.get_width(),
			img.get_height()], "md5": md5}))
	quit(code)
