extends SceneTree
## Muted isolated visual acceptance; --out names an absolute PNG output.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path("user://projectile_read_shots.cfg")
	Campaign.reset()
	var world := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	world.embedded = true
	root.add_child(world)
	world.dev["no_waves"] = "1"
	world.dev["spawn_units"] = "0"
	world.start_map("archive")
	world.set_process(false)
	for index in 4:
		var at := Vector2(450, 320 + index * 42)
		var target_at := at + Vector2(140, -10)
		var unit := world.spawn_unit(LegionCfg.KIND_CLERK, at)
		var foe := world.spawn_foe_on_path("zombie",
			PackedVector2Array([target_at, world.cauldron_pos]), target_at)
		world.projectiles.fire(unit, foe, 5.0)
	world.projectiles.tick(0.16)
	world._fx.queue_redraw()
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	if index >= 0:
		root.get_texture().get_image().save_png(args[index + 1])
	world.queue_free()
	await process_frame
	quit()
