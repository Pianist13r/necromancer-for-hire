extends SceneTree
## Частичная terrain-стена закрывает ровно два горизонтальных луча настоящего каре.
## Headless проверяет production predicate, CLERK_OBSTACLE_SHOTS включает пиксели/PNG.

var w: LegionWorld
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	_fails += int(not ok)
	print("  %s %s" % ["ok" if ok else "FAIL", what])


func _square(side: int) -> Contract:
	w.dev = {"spawn_units": "0", "no_waves": "1", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.start_map("pvp:duel")
	w.hold = true
	w.terrain.setup({"size": [1600, 900]})
	var center := Vector2(450 if side == 0 else 1150, 350)
	var points := PackedVector2Array()
	for i in 4:
		var a := Vector2.from_angle(TAU * i / 4.0 - PI / 2.0) * 70.0
		var b := Vector2.from_angle(TAU * (i + 1) / 4.0 - PI / 2.0) * 70.0
		for j in 16:
			points.append(center + a.lerp(b, j / 16.0))
	points.append(points[0])
	var field := w.sides[side].contracts
	field._create(points, 1, LegionCfg.KIND_CLERK, false, ContractShape.SQUARE)
	var c: Contract = field.contracts.back()
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"], null, side)
		u.assign(c, p)
		u._arrive()
	return c


func _fixture(side: int, axis: Vector2, mode: String) -> void:
	var c := _square(side)
	var g := w.role_release_geometry(c, 0, axis, 1.0, true)
	var center_y := 350.0
	var far := (g["center"] as Vector2).dot(axis) + float(g["depth"])
	var wall_x := (far + (40.0 if mode == "beyond" else -48.0)) * axis.x
	var edge := wall_x + axis.x * 12.0
	var wall := PackedVector2Array([Vector2(minf(wall_x, edge), center_y - 5),
		Vector2(maxf(wall_x, edge), center_y - 5),
		Vector2(maxf(wall_x, edge), center_y + 5),
		Vector2(minf(wall_x, edge), center_y + 5)])
	if mode != "none":
		w.terrain.setup({"size": [1600, 900], "rocks": [wall]})
		g = w.role_release_geometry(c, 0, axis, 1.0, true)
	var label := "s%d-%s-%s" % [side, "right" if axis == Vector2.RIGHT else "left", mode]
	_check(c.figure == ContractShape.SQUARE and (g["origins"] as PackedVector2Array).size() == 4,
		"%s: действующее каре с четырьмя занятыми местами" % label)
	_check(bool(g["blocked"]) == (mode == "inside"),
		"%s: только внутренняя частичная стена ограничивает приказ" % label)
	var expected := PackedByteArray()
	var origins: PackedVector2Array = g["origins"]
	for i in origins.size():
		# Независимый oracle: два луча на y350 пересекают узкую стену, y280/y420 свободны.
		var crosses := absf(origins[i].y - center_y) < 5.0
		var blocked := mode == "inside" and crosses
		expected.append(int(blocked))
		_check(RoleReleasePreview.clerk_lane_blocked(g, i) == blocked,
			"%s: lane%d %s" % [label, i, "blocked" if blocked else "open"])
		if mode == "inside":
			var ray_point := Vector2(wall_x + axis.x * 6, origins[i].y)
			_check(w.terrain.is_rock(ray_point) == crosses,
				"%s: terrain подтверждает пересечение луча%d со стеной" % [label, i])
	await _pixels(w.sides[side].contracts, g, wall if mode != "none" else
		PackedVector2Array(), expected, label)


func _draw_fixture(canvas: Node2D, field: ContractField, g: Dictionary,
		wall: PackedVector2Array) -> void:
	if not wall.is_empty():
		canvas.draw_colored_polygon(wall, Color(0.3, 0.3, 0.35))
	var overlay := field.overlay
	field.overlay = canvas
	RoleReleasePreview._draw_lane(field, g, Color(0.25, 0.8, 1), false, LegionCfg.KIND_CLERK)
	field.overlay = overlay


func _red_pixels(frame: Image, at: Vector2) -> int:
	var count := 0
	for y in range(roundi(at.y) - 2, roundi(at.y) + 3):
		for x in range(roundi(at.x) - 2, roundi(at.x) + 3):
			var pixel := frame.get_pixel(x, y)
			if pixel.r > 0.9 and pixel.g > 0.35 and pixel.g < 0.55 and pixel.b < 0.4:
				count += 1
	return count


func _pixels(field: ContractField, g: Dictionary, wall: PackedVector2Array,
		expected: PackedByteArray, label: String) -> void:
	var folder := OS.get_environment("CLERK_OBSTACLE_SHOTS")
	if folder.is_empty() or DisplayServer.get_name() == "headless":
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 900)
	viewport.world_2d = World2D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var canvas := Node2D.new()
	viewport.add_child(canvas)
	canvas.draw.connect(_draw_fixture.bind(canvas, field, g, wall))
	canvas.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	var frame := viewport.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(folder)
	frame.save_png(folder.path_join(label + ".png"))
	for i in expected.size():
		var count := _red_pixels(frame, g["ends"][i])
		_check((count > 0) == bool(expected[i]), "%s: lane%d real red pixels=%d"
			% [label, i, count])
	viewport.queue_free()
	await process_frame


func _run() -> void:
	Campaign.set_save_path("user://legion_clerk_preview_obstacle_test.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	for side in 2:
		for axis: Vector2 in [Vector2.RIGHT, Vector2.LEFT]:
			for mode: String in ["none", "beyond", "inside"]:
				await _fixture(side, axis, mode)
	Campaign.reset()
	for s in w.sides:
		s.items.effects.items = null
	w.queue_free()
	await process_frame
	print("LEGION CLERK PREVIEW OBSTACLE: %d/%d OK" % [_checks - _fails, _checks])
	quit(int(_fails > 0))
