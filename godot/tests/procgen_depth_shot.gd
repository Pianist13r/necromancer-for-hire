extends SceneTree
## Короткий runtime fixture: один и тот же боец за/перед живым high-prop на gen:12:5.

var _world: LegionWorld
var _out_dir := "C:/AI/necro/batches/procgen/depth"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if String(args[i]) == "--out-dir" and i + 1 < args.size():
			_out_dir = String(args[i + 1])
	Campaign.set_save_path("user://depth_fixture.cfg")
	_world = LegionWorld.new()
	root.add_child(_world)
	_world.set_process(false)
	var manager: Node = null
	var props: Array = []
	for frame in 600:
		await process_frame
		manager = _world.get("_depth_decor") as Node
		if manager != null:
			props = manager.get("_sprites") as Array
			if not props.is_empty():
				break
	if manager == null:
		push_error("Depth layer не появился за 10 секунд; проверь --dev и async PgArt")
		quit(1)
		return
	await RenderingServer.frame_post_draw
	var viewport := _world.get_viewport()
	var canvas_transform := viewport.get_canvas_transform()
	var viewport_rect := viewport.get_visible_rect()
	var safe_rect := Rect2(viewport_rect.position + Vector2(72.0, 112.0),
		viewport_rect.size - Vector2(144.0, 224.0))
	var prop: Sprite2D = null
	for candidate: Sprite2D in props:
		var id := String(candidate.get_meta("pgart_depth_id", ""))
		if (id.contains("tree") or id.contains("tomb") or id.contains("column") \
				or id.contains("rock")) and safe_rect.has_point(
				canvas_transform * candidate.global_position):
			prop = candidate
			break
	if prop == null or _world.units.is_empty():
		push_error("Нет high prop с anchor внутри viewport-safe area gen:12:5")
		quit(1)
		return
	if is_instance_valid(_world.obstacle_hint):
		_world.obstacle_hint.hide()
		_world.obstacle_hint.modulate.a = 0.0
		_world.obstacle_hint.set_process(false)
	_world.hud.hide()
	_world.plot_menu.hide()
	if is_instance_valid(_world.intuit):
		_world.intuit.hide()
	var actor: Legionnaire = _world.units[0]
	for i in _world.units.size():
		var unit: Legionnaire = _world.units[i]
		if i == 0:
			continue
		unit.visible = false
		unit.position = Vector2(-10000.0 - i * 100.0, -10000.0)
	for foe: Foe in _world.foes:
		foe.visible = false
		foe.position = Vector2(-12000.0, -12000.0)
	var anchor := prop.global_position
	actor.visible = true
	actor.view.position = Vector2.ZERO
	actor.position = Vector2(anchor.x, anchor.y - 3.0)
	await _wait_frames(2)
	manager.call("_refresh_occlusion")
	await _wait_frames(10)
	var shot_saved: bool = await _save("behind-high-prop.png")
	if not shot_saved:
		quit(1)
		return
	print(JSON.stringify({"fixture": "behind", "prop": prop.get_meta("pgart_depth_id"),
		"alpha": prop.modulate.a, "anchor_world": anchor,
		"actor_global": actor.global_position,
		"actor_visible": actor.is_visible_in_tree() and actor.view.is_visible_in_tree(),
		"actor_visual_rect": actor.view.call("occlusion_world_rect"),
		"prop_rect": manager.call("_sprite_world_rect", prop),
		"viewport": viewport_rect, "viewport_image": viewport.get_texture().get_image().get_size(),
		"canvas_transform": canvas_transform,
		"camera": viewport.get_camera_2d().name if viewport.get_camera_2d() != null else "none"}))
	var debug := _make_debug_overlay(actor, prop, canvas_transform, viewport_rect)
	root.add_child(debug)
	await _wait_frames(2)
	shot_saved = await _save("behind-debug.png")
	if not shot_saved:
		quit(1)
		return
	debug.queue_free()
	actor.position = Vector2(anchor.x, anchor.y + 3.0)
	manager.call("_refresh_occlusion")
	await _wait_frames(10)
	shot_saved = await _save("in-front-of-high-prop.png")
	if not shot_saved:
		quit(1)
		return
	print(JSON.stringify({"fixture": "in_front", "prop": prop.get_meta("pgart_depth_id"),
		"alpha": prop.modulate.a, "anchor": anchor}))
	_world.free()
	await process_frame
	await process_frame
	quit(0)


func _make_debug_overlay(actor: Legionnaire, prop: Sprite2D, canvas_transform: Transform2D,
		viewport_rect: Rect2) -> CanvasLayer:
	var overlay := CanvasLayer.new()
	overlay.layer = 100
	var actor_rect: Rect2 = actor.view.occlusion_world_rect()
	var manager: Node = _world.get("_depth_decor") as Node
	var prop_rect: Rect2 = manager.call("_sprite_world_rect", prop)
	_outline(overlay, _to_view_rect(actor_rect, canvas_transform), Color.CYAN)
	_outline(overlay, _to_view_rect(prop_rect, canvas_transform), Color.GOLD)
	var body: CanvasItem = actor.view.get("_body") as CanvasItem
	var caption := Label.new()
	caption.position = viewport_rect.position + Vector2(12.0, 12.0)
	caption.text = "ACTOR visible=%s view=%s pop_alpha=%.2f\nactor_world=%s\nprop=%s anchor=%s" % [
		str(actor.is_visible_in_tree()), str(actor.view.is_visible_in_tree()),
		body.modulate.a if body != null else -1.0, str(actor_rect),
		String(prop.get_meta("pgart_depth_id")), str(prop.global_position)]
	caption.add_theme_color_override("font_color", Color.WHITE)
	caption.add_theme_color_override("font_outline_color", Color.BLACK)
	caption.add_theme_constant_override("outline_size", 6)
	overlay.add_child(caption)
	return overlay


func _to_view_rect(rect: Rect2, transform: Transform2D) -> Rect2:
	var points := [transform * rect.position, transform * Vector2(rect.end.x, rect.position.y),
		transform * rect.end, transform * Vector2(rect.position.x, rect.end.y)]
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		bounds = bounds.expand(point)
	return bounds


func _outline(parent: Node, rect: Rect2, color: Color) -> void:
	var thickness := 3.0
	for piece: Rect2 in [Rect2(rect.position, Vector2(rect.size.x, thickness)),
		Rect2(Vector2(rect.position.x, rect.end.y - thickness), Vector2(rect.size.x, thickness)),
		Rect2(rect.position, Vector2(thickness, rect.size.y)),
		Rect2(Vector2(rect.end.x - thickness, rect.position.y), Vector2(thickness, rect.size.y))]:
		var edge := ColorRect.new()
		edge.position = piece.position
		edge.size = piece.size
		edge.color = color
		parent.add_child(edge)


func _wait_frames(count: int) -> void:
	for _i in count:
		await process_frame
		await RenderingServer.frame_post_draw


func _save(file_name: String) -> bool:
	var path := _out_dir.path_join(file_name)
	var error := DirAccess.make_dir_recursive_absolute(_out_dir)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_error("Не удалось создать папку кадров: " + _out_dir)
		return false
	var image := _world.get_viewport().get_texture().get_image()
	error = image.save_png(path)
	if error != OK:
		push_error("Не удалось сохранить кадр: " + path)
		return false
	print(JSON.stringify({"shot": path}))
	return true
