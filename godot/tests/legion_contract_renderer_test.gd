extends SceneTree
## Renderer boundary: callbacks use the original CanvasItems, both graphics modes and
## transformed PvP fields retain their draw counts, and rendering does not advance battle RNG.
## Optional NECRO_RENDER_SHOTS directory captures real battle frames at two resolutions.

var checks := 0
var fails := 0
var world: LegionWorld

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])

func _run() -> void:
	Settings.path = "user://contract_renderer_settings.cfg"
	Settings._cfg = ConfigFile.new()
	Campaign.set_save_path("user://contract_renderer_campaign.cfg")
	Campaign.reset()
	Campaign.unlock_all()
	world = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	root.add_child(world)
	await process_frame
	world.dev["spawn_units"] = "0"
	world.dev["no_waves"] = "1"
	world.dev["noview"] = "1"
	world.rng.seed = 91
	world.start_map("wasteland")
	world.set_process(false)
	world.grid.rebuild()
	var field := world.contracts
	for i in 3:
		var y := 210.0 + 110.0 * i
		var line := field.add_contract(PackedVector2Array([Vector2(300, y), Vector2(430, y - 8),
			Vector2(560, y + 6), Vector2(650, y)]), 1, false, LegionCfg.KIND_ORDER[i])
		check(line != null, "created line of kind %d" % i)
		for j in 4:
			world.spawn_unit(LegionCfg.KIND_ORDER[i], Vector2(360 + 60 * j, y + 35))
	if field.contracts.size() != 3:
		quit(1)
		return
	field.now = 2.0
	field.begin(Vector2(820, 590))
	field.extend(Vector2(930, 565))
	field.extend(Vector2(1060, 595))
	field.update_preview()
	var rng_before := world.rng.state
	var mana_before := field.mana
	var ages_before := field.contracts[0].seg_age.duplicate()
	for eco in [false, true]:
		Settings.economy_override = "on" if eco else "off"
		field.queue_redraw()
		field.overlay.queue_redraw()
		for j in 3:
			await process_frame
		check(field.drawn_lines == 3, "line count in graphics mode %s" % eco)
		check(field.drawn_flow == 0 if eco else field.drawn_flow > 0,
			"flow count in graphics mode %s" % eco)
		check(field.overlay.get_parent() == world and field.get_parent() == world,
			"draw callbacks retain original lower and upper CanvasItems")
		await _shots(field, eco)
	check(world.rng.state == rng_before, "drawing does not consume battle RNG")
	check(field.mana == mana_before and field.contracts[0].seg_age == ages_before,
		"drawing does not spend mana or age contracts")
	field.cancel()
	world.start_map("pvp:duel")
	world.set_process(false)
	var other: ContractField = world.sides[1].contracts
	other.add_contract(PackedVector2Array([Vector2(1000, 400), Vector2(1250, 400)]), 1, false)
	other.queue_redraw()
	other.overlay.queue_redraw()
	for j in 3:
		await process_frame
	check(other.drawn_lines == 1, "other PvP field renders its own contracts")
	check(world.view_scale() < 1.0, "PvP camera transform exercised")
	world.queue_free()
	await process_frame
	Settings.economy_override = ""
	Campaign.reset()
	print("LEGION CONTRACT RENDERER: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)

func _shots(field: ContractField, eco: bool) -> void:
	var out := OS.get_environment("NECRO_RENDER_SHOTS")
	if out.is_empty() or DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_position(Vector2i(-32000, -32000))
	for dimensions: Vector2i in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = dimensions
		DisplayServer.window_set_size(dimensions)
		field.queue_redraw()
		field.overlay.queue_redraw()
		for j in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(out.path_join("battle-%dx%d-%s.png"
			% [dimensions.x, dimensions.y, "economy" if eco else "full"])) == OK,
			"saved real battle screenshot")
