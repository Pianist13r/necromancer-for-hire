extends SceneTree
## Real autostart, bot and renderer. Captures without overlays or fabricated gameplay.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[args.find("--out") + 1]
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	Campaign.set_save_path("user://procgen_1008_entry.cfg")
	var main := (load("res://scenes/legion.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var seen_loading := false
	var violation := false
	var captured := {}
	for frame in 480:
		await process_frame
		var world: LegionWorld = main.world
		if world == null:
			continue
		if world._ground_loading:
			seen_loading = true
			violation = violation or world.now > 0.0
		for threshold: float in [0.1, 0.8, 2.0, 5.0]:
			if world.now >= threshold and not captured.has(threshold):
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(out.path_join("%.1fs.png" % threshold))
				captured[threshold] = true
	print(JSON.stringify({"loading_seen": seen_loading, "advanced_during_loading": violation,
		"captures": captured.size()}))
	quit(1 if violation or captured.size() < 4 else 0)
