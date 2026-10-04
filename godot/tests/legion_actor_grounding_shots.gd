extends SceneTree
## A/B/C: одна карта и неизменная группа из четырёх бойцов для сравнения artwork здания.

var _world: LegionWorld
var _out_dir := "C:/AI/necro/batches/actor-grounding"
var _baseline_building_state: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if String(args[i]) == "--out-dir" and i + 1 < args.size():
			_out_dir = String(args[i + 1])
	Campaign.set_save_path("user://actor_grounding_fixture.cfg")
	AudioServer.set_bus_mute(0, true)
	_world = LegionWorld.new()
	root.add_child(_world)
	_world.start_map("gen:12:5")
	var ground: TerrainView = null
	for _frame in 900:
		await process_frame
		ground = _world.ground_view()
		if ground != null and ground.background_texture() != null:
			break
	if ground == null or ground.background_texture() == null:
		push_error("gen:12:5 ground was not ready within 15 seconds")
		quit(1)
		return
	await RenderingServer.frame_post_draw
	_world.set_process(false)
	_world.set_physics_process(false)
	if is_instance_valid(_world.hud):
		_world.hud.hide()
	if is_instance_valid(_world.obstacle_hint):
		_world.obstacle_hint.hide()
		_world.obstacle_hint.modulate.a = 0.0
		_world.obstacle_hint.set_process(false)
	if is_instance_valid(_world.plot_menu):
		_world.plot_menu.hide()
	if is_instance_valid(_world.intuit):
		_world.intuit.hide()
	for foe: Foe in _world.foes:
		foe.hide()
		foe.set_process(false)
		foe.set_physics_process(false)
	var viewport := _world.get_viewport()
	var canvas_transform := viewport.get_canvas_transform()
	var view_rect := viewport.get_visible_rect()
	var safe_rect := Rect2(
		view_rect.position + Vector2(80.0, 120.0), view_rect.size - Vector2(160.0, 240.0)
	)
	var plot: Dictionary = _central_empty_plot(canvas_transform, safe_rect)
	if plot.is_empty():
		push_error("No visible empty plot on gen:12:5")
		quit(1)
		return
	_world.staff.add_souls(500)
	var building := _world.staff.build(plot, LegionCfg.KIND_LABORER)
	if building == null:
		push_error("Could not build the laborer hut for A/B/C")
		quit(1)
		return
	_baseline_building_state = {
		"kind": building.kind,
		"level": building.level,
		"cap": building.cap,
		"alive": building.alive_count(),
		"accent": LegionCfg.UNIT_KINDS[building.kind]["color"]
	}
	var artwork: Node = building.get_node_or_null("BuildingArtwork")
	if artwork == null:
		push_error("BuildingArtwork child is missing")
		quit(1)
		return
	artwork.call("set_display_width", 90.0)
	var checks_ok := _check_default_artwork(building, artwork)
	var actors := _place_four_actors(plot["pos"] as Vector2)
	if actors.size() != 4:
		push_error("Need four live units for the style comparison; got %d" % actors.size())
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out_dir)
	for variant: StringName in [&"original", &"shader", &"painterly"]:
		building.set_artwork_variant(variant)
		# set_artwork_variant() calls configure() and restores the production width (84 px).
		artwork.call("set_display_width", 90.0)
		await _wait_frames(3)
		await RenderingServer.frame_post_draw
		var variant_ok := _check_variant_invariants(building, artwork, variant)
		checks_ok = variant_ok and checks_ok
		var sprite := artwork.get_node_or_null("Artwork") as Sprite2D
		var suffix := String(variant)
		var path := _out_dir.path_join("building_%s.png" % suffix)
		var image := viewport.get_texture().get_image()
		var error := image.save_png(path)
		if error != OK:
			push_error("Could not save %s: %s" % [path, error_string(error)])
			quit(1)
			return
		print(
			JSON.stringify(
				{
					"variant": suffix,
					"path": path,
					"building_anchor": building.global_position,
					"actor_positions":
					actors.map(func(unit: Legionnaire) -> Vector2: return unit.global_position),
					"image_size": image.get_size(),
					"sprite_width": _measured_width(sprite),
					"alpha_passthrough": _alpha_is_passthrough(sprite),
					"invariants_passed": variant_ok
				}
			)
		)
	_world.free()
	await process_frame
	await process_frame
	quit(0 if checks_ok else 1)


func _check_default_artwork(building: LegionBuilding, artwork: Node) -> bool:
	var sprite := artwork.get_node_or_null("Artwork") as Sprite2D
	if sprite == null:
		push_error("Artwork sprite is missing")
		return false
	if not _expect(
		sprite.texture.resource_path.ends_with("laborer_1_painterly.png"),
		"default laborer level 1 must use painterly artwork"
	):
		return false
	for target_level in [2, 3]:
		building.level = target_level
		building.refresh_artwork()
		if not _expect(
			sprite.texture.resource_path.ends_with("laborer_%d.png" % target_level),
			"laborer upgrade must replace the previous level artwork"
		):
			return false
		if not _expect(
			(
				_named_sprite_count(artwork, "Artwork") == 1
				and is_equal_approx(_measured_width(sprite), LegionCfg.BUILDING_SPRITE_W)
			),
			"upgrade must keep one Artwork sprite at BUILDING_SPRITE_W"
		):
			return false
	building.kind = LegionCfg.KIND_GUARD
	building.level = 1
	building.set_artwork_variant(LegionBuilding.ARTWORK_DEFAULT)
	if not _expect(
		sprite.texture.resource_path.ends_with("guard_1.png"),
		"other building kinds must use original artwork"
	):
		return false
	building.kind = LegionCfg.KIND_LABORER
	building.level = 1
	building.set_artwork_variant(LegionBuilding.ARTWORK_DEFAULT)
	# refresh_artwork() restores the production width (84 px); the shot fixture deliberately
	# uses 90 px, so reapply that test setting after the upgrade and kind-switch smoke checks.
	artwork.call("set_display_width", 90.0)
	return _check_variant_invariants(building, artwork, &"painterly")


func _check_variant_invariants(
	building: LegionBuilding, artwork: Node, variant: StringName
) -> bool:
	var sprite := artwork.get_node_or_null("Artwork") as Sprite2D
	if sprite == null or sprite.texture == null:
		push_error("Artwork sprite or texture missing for %s" % variant)
		return false
	return (
		_check_footprint(sprite, variant)
		and _check_layer_isolation(building, sprite, variant)
		and _check_alpha_passthrough(sprite, variant)
	)


func _check_footprint(sprite: Sprite2D, variant: StringName) -> bool:
	var width := _measured_width(sprite)
	var anchor_y := -sprite.position.y / (float(sprite.texture.get_height()) * sprite.scale.y)
	if not _expect(is_equal_approx(width, 90.0), "%s footprint width changed" % variant):
		return false
	if not _expect(
		is_equal_approx(anchor_y, LegionCfg.BUILDING_SPRITE_ANCHOR_Y),
		"%s ground anchor changed" % variant
	):
		return false
	return true


func _measured_width(sprite: Sprite2D) -> float:
	if sprite == null or sprite.texture == null:
		return 0.0
	return float(sprite.texture.get_width()) * sprite.scale.x


func _alpha_is_passthrough(sprite: Sprite2D) -> bool:
	if sprite == null or not sprite.material is ShaderMaterial:
		return true
	var shader_code := (sprite.material as ShaderMaterial).shader.code
	return (
		shader_code.contains("vec4 sample_color = COLOR;")
		and shader_code.contains("sample_color.a);")
	)


func _check_layer_isolation(
	building: LegionBuilding, sprite: Sprite2D, variant: StringName
) -> bool:
	var wants_shader := variant == &"shader"
	return (
		_expect(
			(
				_named_sprite_count(sprite.get_parent(), "Artwork") == 1
				and _named_sprite_count(sprite.get_parent(), "ContactShadow") == 1
			),
			"artwork reconfiguration must not duplicate sprites or shadows"
		)
		and _expect(
			building.material == null and building.modulate == Color.WHITE,
			"artwork variant must not tint the parent label or team accent"
		)
		and _expect(
			(
				building.kind == _baseline_building_state["kind"]
				and building.level == _baseline_building_state["level"]
				and building.cap == _baseline_building_state["cap"]
				and building.alive_count() == _baseline_building_state["alive"]
				and (
					LegionCfg.UNIT_KINDS[building.kind]["color"]
					== _baseline_building_state["accent"]
				)
			),
			"artwork variant changed the label values or team accent"
		)
		and _expect(
			(sprite.material is ShaderMaterial) == wants_shader,
			"only the artwork sprite may receive the optional shader"
		)
	)


func _named_sprite_count(parent: Node, sprite_name: String) -> int:
	var count := 0
	for child in parent.get_children():
		if child is Sprite2D and child.name == sprite_name:
			count += 1
	return count


func _check_alpha_passthrough(sprite: Sprite2D, variant: StringName) -> bool:
	if variant != &"shader":
		return true
	var shader_code := (sprite.material as ShaderMaterial).shader.code
	return _expect(
		(
			shader_code.contains("vec4 sample_color = COLOR;")
			and shader_code.contains("sample_color.a);")
		),
		"shader must preserve sampled alpha"
	)


func _expect(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	return false


func _central_empty_plot(canvas_transform: Transform2D, safe_rect: Rect2) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := INF
	var center := safe_rect.get_center()
	for candidate: Dictionary in _world.staff.plots:
		if candidate["building"] != null:
			continue
		var screen := canvas_transform * (_world.to_global(candidate["pos"] as Vector2))
		if not safe_rect.has_point(screen):
			continue
		var distance := screen.distance_squared_to(center)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


func _place_four_actors(anchor: Vector2) -> Array[Legionnaire]:
	var chosen: Array[Legionnaire] = []
	for unit: Legionnaire in _world.units:
		if not unit.alive:
			continue
		chosen.append(unit)
		if chosen.size() == 4:
			break
	if chosen.size() != 4:
		return chosen
	var offsets := [Vector2(-44, 34), Vector2(-15, 44), Vector2(17, 42), Vector2(45, 32)]
	for unit: Legionnaire in _world.units:
		if chosen.has(unit):
			continue
		unit.hide()
		unit.set_process(false)
		unit.set_physics_process(false)
	for i in chosen.size():
		var unit := chosen[i]
		unit.show()
		unit.view.show()
		unit.set_process(false)
		unit.set_physics_process(false)
		unit.position = anchor + offsets[i]
	return chosen


func _wait_frames(count: int) -> void:
	for _i in count:
		await process_frame
