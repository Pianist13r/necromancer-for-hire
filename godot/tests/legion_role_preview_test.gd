extends SceneTree
## Настоящий ввод: короткая/дальняя оттяжка, отпускание и отмена, обе руки.

const SAVE := "user://role_preview_test.cfg"
const AT := Vector2(760.0, 220.0)
var w: LegionWorld
var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _run() -> void:
	I18n.initialize("ru")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Settings.scheme_override = Settings.SCHEME_SLING
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	for lefty: bool in [false, true]:
		Settings.lefty_override = "on" if lefty else "off"
		for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
			await _role(kind, lefty)
	Settings.lefty_override = "off"
	await _infantry()
	await _gold_lanes()
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		await _cohesive(kind)
	Settings.lefty_override = ""
	Settings.scheme_override = ""
	print("LEGION ROLE PREVIEW: %d/%d OK" % [checks - failures, checks])
	w.items.effects.items = null
	w.queue_free()
	await process_frame
	await process_frame
	quit(1 if failures > 0 else 0)


func _fresh(kind: StringName, shaped := false) -> Contract:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.hold = true
	while w.is_ground_loading():
		await process_frame
	await process_frame
	await process_frame
	var c: Contract
	if shaped:
		var pts := PackedVector2Array()
		for i in 4:
			var a := Vector2.from_angle(TAU * i / 4.0 - PI / 2.0) * 70.0
			var b := Vector2.from_angle(TAU * (i + 1) / 4.0 - PI / 2.0) * 70.0
			for j in 16:
				pts.append(AT + Vector2(0, 40) + a.lerp(b, j / 16.0))
		pts.append(pts[0])
		w.contracts._create(pts, 1, kind, false, ContractShape.SQUARE)
		c = w.contracts.contracts.back()
	else:
		c = w.contracts.add_contract(PackedVector2Array([AT, AT + Vector2(0.0, 64.0)]),
			1, false, kind)
		c.set_dir(Vector2.RIGHT)
	for post in c.posts:
		var u := w.spawn_unit(kind, post["pos"])
		u.assign(c, post)
		u._arrive()
	return c


func _event(at: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.device = 7
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_index = button
	event.pressed = pressed
	event.button_mask = (1 << (int(button) - 1)) if pressed else 0
	Input.parse_input_event(event)
	await process_frame


func _move(at: Vector2, button: MouseButton) -> void:
	var event := InputEventMouseMotion.new()
	event.device = 7
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_mask = 1 << (int(button) - 1)
	Input.parse_input_event(event)
	await process_frame


func _role(kind: StringName, lefty: bool) -> void:
	var c := await _fresh(kind)
	var at := c.seg_center(0)
	var button: MouseButton = MOUSE_BUTTON_LEFT if lefty else MOUSE_BUTTON_RIGHT
	await _event(at, button, true)
	await _move(at - Vector2(30.0, 0.0), button)
	var short := w.contracts.sling_aim()
	_check(short.has("role_geometries"), "%s actual input has role geometry lefty=%s" % [kind, lefty])
	if not short.has("role_geometries"):
		await _event(at - Vector2(30.0, 0.0), button, false)
		return
	var short_depth := float(short["role_geometries"][0]["depth"])
	await _move(at - Vector2(140.0, 0.0), button)
	var far := w.contracts.sling_aim()
	var geometry: Dictionary = far["role_geometries"][0]
	_check(float(geometry["depth"]) > short_depth + 50.0,
		"%s farther pull extends actual path" % kind)
	_check((far["dir"] as Vector2).is_equal_approx(Vector2.RIGHT), "opposite pull direction")
	_check(not bool(far["perfect"]), "empty strip never promises perfect hit")
	var before := PackedVector2Array()
	for u in w.units:
		before.append(u.position)
	await _shot(String(kind) + ("-lefty" if lefty else "-righty"))
	await _event(at - Vector2(140.0, 0.0), button, false)
	_check(not c.seg_alive(0), "release consumes the previewed section")
	for i in 30:
		w._step(1.0 / 60.0)
	var valid := not w.units.is_empty()
	for i in w.units.size():
		var delta := w.units[i].position - before[i]
		if kind == LegionCfg.KIND_CLERK:
			valid = valid and delta.length() < 0.1
		else:
			valid = valid and delta.x > 5.0 and absf(delta.y) < 0.1
	_check(valid, "archers stay / guards move along preview while retaining front")
	await _shot(String(kind) + "-released" + ("-lefty" if lefty else "-righty"))
	c = await _fresh(kind)
	at = c.seg_center(0)
	await _event(at, button, true)
	await _move(at - Vector2(50.0, 0.0), button)
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = KEY_ESCAPE
		event.keycode = KEY_ESCAPE
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await _event(at - Vector2(50.0, 0.0), button, false)
	_check(c.seg_alive(0), "Escape cancels without consuming the contract")


func _infantry() -> void:
	var c := await _fresh(LegionCfg.KIND_LABORER)
	var at := c.seg_center(0)
	await _event(at, MOUSE_BUTTON_RIGHT, true)
	await _move(at - Vector2(30.0, 0.0), MOUSE_BUTTON_RIGHT)
	var short := w.contracts.sling_aim()
	await _move(at - Vector2(140.0, 0.0), MOUSE_BUTTON_RIGHT)
	var far := w.contracts.sling_aim()
	_check(is_equal_approx(float(short["power"]), 1.0)
		and is_equal_approx(float(far["power"]), 1.0), "infantry keeps full charge at either pull")
	await _event(at - Vector2(140.0, 0.0), MOUSE_BUTTON_RIGHT, false)


func _gold_lanes() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		var c := await _fresh(kind)
		var foe_at := w.units[0].position + Vector2(25.0, 0.0)
		var foe := w.spawn_foe_on_path("ghost", PackedVector2Array([foe_at]), foe_at)
		foe.speed = 0.0
		var at := c.seg_center(0)
		await _event(at, MOUSE_BUTTON_RIGHT, true)
		await _move(at - Vector2(140.0, 0.0), MOUSE_BUTTON_RIGHT)
		var aim := w.contracts.sling_aim()
		_check(bool(aim["perfect"]) == (kind == LegionCfg.KIND_CLERK),
			"gold preview respects ghost: shields pass through / arrows can hit")
		w.contracts.cancel_sling()
		await _event(at - Vector2(140.0, 0.0), MOUSE_BUTTON_RIGHT, false)


func _cohesive(kind: StringName) -> void:
	var c := await _fresh(kind, true)
	var front: Legionnaire = w.units[0]
	for u in w.units:
		if (kind == LegionCfg.KIND_GUARD and u.position.x > front.position.x) \
				or (kind == LegionCfg.KIND_CLERK and u.position.x < front.position.x):
			front = u
	var foe_at := front.position + Vector2(25, 0)
	var foe := w.spawn_foe_on_path("zombie", PackedVector2Array([foe_at]), foe_at)
	foe.speed = 0.0
	var at := c.seg_center(0)
	await _event(at, MOUSE_BUTTON_RIGHT, true)
	await _move(at - Vector2(140, 0), MOUSE_BUTTON_RIGHT)
	var aim := w.contracts.sling_aim()
	var geometries: Array = aim.get("role_geometries", [])
	_check(geometries.size() == 1, "%s aimed square previews one coherent order" % kind)
	if geometries.is_empty():
		await _event(at - Vector2(140, 0), MOUSE_BUTTON_RIGHT, false)
		return
	var g: Dictionary = geometries[0]
	_check((g["origins"] as PackedVector2Array).size() == c.manned_posts(),
		"square preview contains every posted participant")
	_check(bool(aim["perfect"]), "target at the actual near edge is included in perfect window")
	await _shot(String(kind) + "-square")
	c.charge_t = FigureCfg.CHARGE_TIME
	await _shot(String(kind) + "-square-ready")
	await _event(at - Vector2(140, 0), MOUSE_BUTTON_RIGHT, false)
	var jobs := LegionRoleRelease.jobs(w)
	_check(jobs.size() == 1, "actual input releases the square as one job")
	if jobs.size() != 1:
		return
	var job := jobs[0]
	_check((job["center"] as Vector2).distance_to(g["center"]) < 0.01
		and is_equal_approx(float(job["depth"]), float(g["depth"])),
		"preview plane and depth match the actual released job")
	var same := true
	var origins: PackedVector2Array = g["origins"]
	var actual_origins: PackedVector2Array = job["origins"]
	for i in origins.size():
		var j := actual_origins.find(origins[i])
		if j < 0:
			same = false
			continue
		same = same and (g["ends"][i] as Vector2).distance_to(job["ends"][j]) < 0.01
		same = same and (g["facings"][i] as Vector2).is_equal_approx(job["facings"][j])
	_check(same, "every previewed endpoint and shield facing matches execution")


func _shot(label: String) -> void:
	var folder := OS.get_environment("ROLE_PREVIEW_SHOTS")
	if folder.is_empty() or DisplayServer.get_name() == "headless":
		return
	w.contracts._redraw_now()
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(folder)
	root.get_texture().get_image().save_png(folder.path_join(label + ".png"))
