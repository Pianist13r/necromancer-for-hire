extends "res://tests/legion_figures_usability_test.gd"
## Приёмка цепочки руки: причина до отпускания, атомарная цена, следующий жест,
## сетевое применение и готовность участников. Не вызывает finish напрямую.

var _sent: Array[Dictionary] = []


func _run() -> void:
	Campaign.set_save_path("user://legion_figures_feedback_test.cfg")
	Campaign.reset()
	Settings.scheme_override = Settings.SCHEME_SLING
	Settings.lefty_override = "off"
	I18n.initialize("ru")
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	w.start_map("_gray")
	w.grid.rebuild()
	f = w.contracts
	_test_corner()
	_test_open_loop()
	_test_closure_price()
	_test_floor_refund()
	_test_next_stroke()
	_test_redraw()
	_test_replacement()
	_test_net_price()
	_test_status()
	_test_round_controls()
	_test_open_controls()
	for side in w.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	w.queue_free()
	await process_frame
	await process_frame
	Campaign.reset()
	print("LEGION FIGURES FEEDBACK: %d/%d OK" % [_checks - _fails, _checks])
	quit(int(_fails > 0))


func _motion(to: Vector2, from: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = 79
	ev.position = root.get_final_transform() * to
	ev.global_position = ev.position
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.relative = to - from
	ev.screen_relative = ev.relative
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _hold(pts: PackedVector2Array) -> void:
	_button(pts[0], true)
	for i in range(1, pts.size()):
		_motion(pts[i], pts[i - 1])


func _hint() -> String:
	return String(f.call("draft_shape_hint")) if f.has_method("draft_shape_hint") else ""


func _last_reason() -> String:
	return String(f._wall_fx[-1]["label"]) if not f._wall_fx.is_empty() else ""


func _test_corner() -> void:
	_fresh()
	var pts := PackedVector2Array([Vector2(200, 200), Vector2(205, 200), Vector2(205, 240),
		Vector2(400, 240)])
	var c := _draw(pts)
	_check(c != null and c.points.size() >= 4 and c.points[1].distance_to(pts[1]) < 0.01,
		"sub-6px turn retains the actual corner")
	_check(c != null and not c.shaped(), "short turn stays an ordinary position")


func _test_open_loop() -> void:
	_fresh()
	var pts := trace(&"ring", 8, 0.8, 0.15, 90, 0.2)
	_hold(pts)
	_check(_hint() == I18n.t("Для фигуры · доведи к началу"),
		"unclosed loop explains return to start before release")
	_button(pts[-1], false)
	_check(f.contracts.size() == 1 and not f.contracts[0].shaped(),
		"unclosed loop remains an ordinary position")
	_check(_last_reason() == I18n.t("Для фигуры · доведи к началу"),
		"plain result retains its cause after release")


func _test_closure_price() -> void:
	_fresh()
	var pts := trace(&"ring", 8, 0.7, 0.15, 25, 0.2)
	var wallet := ContractShape.poly_len(pts) * Contract.base_price(f.current_kind) + 0.1
	f.mana = wallet
	_hold(pts)
	_check(_hint() == I18n.t("Маны мало · фигура отменится"),
		"full contour price warns before release")
	_button(pts[-1], false)
	_check(f.contracts.is_empty() and absf(f.mana - wallet) < 0.01,
		"unaffordable closure cancels with full refund")
	_check(_last_reason() == I18n.t("Маны мало · фигура отменена"),
		"closure cancellation names mana rather than short stroke")


func _test_floor_refund() -> void:
	_fresh()
	var pts := trace(&"triangle", 5, 0.39, 0, 0, 0)
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720],
		"water": [[[500, 260], [700, 260], [700, 460], [500, 460]]]})
	var wallet := f.mana
	var c := _draw(pts)
	_check(c == null, "figure with submerged corners is rejected")
	_check(absf(f.mana - wallet) < 0.01, "blocked mini figure refunds effect price floor too")


func _test_next_stroke() -> void:
	_fresh()
	f.mana = 0.2
	_hold(PackedVector2Array([Vector2(200, 200), Vector2(250, 200)]))
	_check(not _hint().is_empty(), "rejected mana motion gives a live reason")
	_button(Vector2(250, 200), false)
	f.mana = f.mana_max
	_button(Vector2(400, 500), true)
	_motion(Vector2(500, 500), Vector2(400, 500))
	_check(_hint().is_empty(), "next ordinary stroke has no stale figure or mana hint")
	_button(Vector2(550, 500), false)
	_check(f.contracts.size() == 1 and not f.contracts[0].shaped()
		and f.contracts[0].points[0].distance_to(Vector2(400, 500)) < 0.01,
		"next stroke starts at its own press")
	f.begin(Vector2(500, 300))
	f.extend(Vector2(505, 300))
	f.setup(w)
	_button(Vector2(400, 500), true)
	_motion(Vector2(500, 500), Vector2(400, 500))
	_check(_hint().is_empty(), "new map clears pen sample and feedback state")
	_button(Vector2(550, 500), false)
	_check(f.contracts.size() == 1 and f.contracts[0].points[0].distance_to(Vector2(400, 500)) < 0.01,
		"new map stroke contains no old corner")


func _test_net_price() -> void:
	_fresh()
	_sent.clear()
	var pts := trace(&"ring", 8, 0.7, 0.15, 25, 0.2)
	w.net_mode = true
	w.net_out = func(cmd: Dictionary) -> void: _sent.append(cmd)
	var quantized := PvpCmd.stroke_points(pts, w.world_size)
	var wallet := ContractShape.poly_len(quantized) * Contract.base_price(f.current_kind) + 0.1
	f.mana = wallet
	_hold(pts)
	_check(_hint() == I18n.t("Маны мало · фигура отменится"),
		"network preview warns about closure price without spending")
	_button(pts[-1], false)
	_check(_sent.size() == 1 and absf(f.mana - wallet) < 0.01,
		"network hand emits stroke and leaves wallet to simulation")
	if not _sent.is_empty():
		w.net_apply(0, _sent[0])
	_check(f.contracts.is_empty() and absf(f.mana - wallet) < 0.01,
		"network closure cancellation refunds exactly like local input")
	w.net_mode = false
	w.net_out = Callable()
	_fresh()
	var line := _draw(trace(&"ring", 8, 0.7, 0.15, 90, 0.2))
	_sent.clear()
	f.mana = f.mana_max
	w.net_mode = true
	w.net_out = func(cmd: Dictionary) -> void: _sent.append(cmd)
	_draw(trace(&"ring", 8, 0.7, 0.15, 12, 0.2))
	if not _sent.is_empty():
		w.net_apply(0, _sent[0])
	_check(f.contracts.size() == 1 and f.contracts[0].ring and not f.contracts.has(line),
		"network replay replaces the incomplete line atomically too")
	w.net_mode = false
	w.net_out = Callable()


func _test_redraw() -> void:
	_fresh()
	var line := _draw(trace(&"ring", 8, 0.7, 0.15, 90, 0.2))
	_check(line != null and not line.shaped(), "first incomplete contour is a plain position")
	f.mana = f.mana_max
	var ring := _draw(trace(&"ring", 8, 0.7, 0.15, 12, 0.2))
	_check(ring != null and ring.ring, "corrected complete contour creates the announced ring")
	_check(f.contracts.size() == 1 and not f.contracts.has(line),
		"correction replaces the plain contour without duplicating its slot")
	if ring != null:
		f.dismiss(line)
		f.mana = f.mana_max
		var count := f.contracts.size()
		_draw(trace(&"ring", 8, 0.7, 0.15, 12, 0.2))
		_check(f.contracts.size() == count and f.contracts[0] == ring,
			"repeat of an existing figure still refreshes it")
	_fresh()
	line = _draw(trace(&"ring", 8, 0.7, 0.15, 90, 0.2))
	line.seg_dead.fill(1)
	f.tick(0, 0)
	f.mana = f.mana_max
	ring = _draw(trace(&"ring", 8, 0.7, 0.15, 12, 0.2))
	_check(ring != null and ring.ring and f.contracts.size() == 1,
		"correction over an expired contour still creates a ring")


func _man_line(c: Contract) -> Array[Legionnaire]:
	var units: Array[Legionnaire] = []
	for p in c.posts:
		if units.size() >= 6:
			break
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		units.append(u)
	return units


func _test_replacement() -> void:
	_fresh()
	var line := _draw(trace(&"ring", 8, 0.7, 0.15, 90, 0.2))
	var units := _man_line(line)
	for i in 5:
		f.add_contract(PackedVector2Array([Vector2(120 + i * 180, 110),
			Vector2(220 + i * 180, 110)]), 1, false)
	f.mana = f.mana_max
	var pts := trace(&"ring", 8, 0.7, 0.15, 12, 0.2)
	_hold(pts)
	f.update_preview()
	var preview_units: Array[Legionnaire] = []
	for a in f._preview_plan:
		preview_units.append(a["unit"])
	var honest := f._preview != null
	for u in units:
		honest = honest and preview_units.has(u) and u.contract == line \
			and u.state == Legionnaire.State.POSTED
	_check(honest, "replacement preview counts released participants without changing their state")
	_check("заменит линию" in _hint(), "preview explicitly announces replacement")
	_button(pts[-1], false)
	var ring := f.contracts[-1]
	_check(f.contracts.size() == LegionCfg.MAX_CONTRACTS and ring.ring
		and not f.contracts.has(line), "replacement works at six slots and occupies one slot")
	var free := true
	for u in units:
		free = free and u.state == Legionnaire.State.FREE and u.contract == null
	_check(free, "successful correction frees the old line participants without charging")
	w._assign_free()
	var staffed := true
	for u in units:
		staffed = staffed and u.contract == ring
	_check(staffed, "released participants can immediately staff the new figure")
	_check(absf(f.mana_max - f.mana - ring.length * Contract.base_price(ring.kind)) < 0.1,
		"correction pays its full new contour without refunding previous ink")
	_fresh()
	line = _draw(trace(&"triangle", 8, 0.9, 0.15, 90, 0.2))
	units = _man_line(line)
	f.mana = f.mana_max
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720],
		"water": [[[400, 160], [800, 160], [800, 560], [400, 560]]]})
	_draw(trace(&"triangle", 8, 0.9, 0.15, 8, 0.2))
	var preserved := f.contracts.size() == 1 and f.contracts[0] == line
	for u in units:
		preserved = preserved and u.contract == line and u.state == Legionnaire.State.POSTED
	_check(preserved and absf(f.mana - f.mana_max) < 0.01,
		"blocked correction preserves old positions and refunds new ink")


func _test_status() -> void:
	_fresh()
	var c := _draw(trace(&"square", 5, 0.9, 0.1, 12, 0.2))
	if c == null or not f.has_method("figure_status"):
		_check(false, "figure status helper exists on a human-drawn square")
		return
	_check(f.call("figure_status", c) == I18n.t("Набор %d/%d") % [0, c.charge_need()],
		"empty square asks for staffing")
	var units: Array[Legionnaire] = []
	for p in c.posts:
		if units.size() >= c.charge_need():
			break
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		units.append(u)
	_check(String(f.call("figure_status", c)).begins_with(I18n.t("Набор %d/%d").split("%d")[0]),
		"marching units do not claim readiness")
	for u in units:
		u._arrive()
	c.charge_t = FigureCfg.CHARGE_TIME * 0.5
	_check(f.call("figure_status", c) == I18n.t("Подготовка %d%%") % 50,
		"staffed square displays charge progress")
	c.charge_t = FigureCfg.CHARGE_TIME
	for lang in ["ru", "en"]:
		I18n.select(lang)
		for lefty in [false, true]:
			Settings.lefty_override = "on" if lefty else "off"
			var expected := Controls.text(I18n.t("Готова · сорви {mouse:sling}"))
			_check(f.call("figure_status", c) == expected and "{mouse:" not in expected,
				"ready status uses %s current mouse binding lefty=%s" % [lang, lefty])
	Settings.lefty_override = "off"
	I18n.select("ru")
	units[0].set_free()
	_check(String(f.call("figure_status", c)).begins_with("Набор"),
		"lost participant shows staffing immediately despite stored charge")


func _test_round_controls() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 101101
	var wrong := 0
	var input_wrong := 0
	var got := {}
	for trial in 3000:
		var pts := PackedVector2Array()
		var count := rng.randi_range(8, 22)
		var rot := rng.randf_range(-PI, PI)
		var radius := rng.randf_range(45, 115)
		var stretch := rng.randf_range(0.72, 1.28)
		for i in count + 1:
			# Unequal timing gives crowded samples on one side and few on the other.
			var t := float(i) / count
			var a := TAU * (t + 0.08 * sin(TAU * t))
			var p := Vector2(cos(a) * radius * stretch, sin(a) * radius)
			p += Vector2(rng.randf_range(-0.8, 0.8), rng.randf_range(-0.8, 0.8))
			pts.append(CENTER + p.rotated(rot))
		var fig := ContractShape.classify(pts)
		if trial < 100:
			_fresh()
			var c := _draw(pts)
			input_wrong += int(c != null and c.figure in ContractShape.CORNER_FIGURES)
		if fig in ContractShape.CORNER_FIGURES or fig == ContractShape.EIGHT:
			wrong += 1
			got[fig] = int(got.get(fig, 0)) + 1
	_check(wrong == 0, "3000 sparse circles/ovals retain round intent: false figures %d %s" %
		[wrong, got])
	_check(input_wrong == 0, "100 nonuniform round strokes through mouse input avoid corner figures")


func _test_open_controls() -> void:
	var raw_wrong := 0
	var input_wrong := 0
	var runs := 0
	var paths: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(-120, -80), Vector2(-120, 80), Vector2(120, 80)]),
		PackedVector2Array([Vector2(-60, -80), Vector2(-60, 80), Vector2(60, 80), Vector2(60, -80)]),
		PackedVector2Array([Vector2(-120, -80), Vector2(100, -80), Vector2(-100, 80),
			Vector2(120, 80)]),
		PackedVector2Array([Vector2(-140, -40), Vector2(-70, 40), Vector2(0, -40),
			Vector2(70, 40), Vector2(140, -40)]),
	]
	for path in paths:
		for step: float in [2, 6, 14, 26, 30]:
			for trial in 12:
				var pts := PackedVector2Array()
				var length := ContractShape.poly_len(path)
				var count := ceili(length / step)
				for i in count + 1:
					var p := _at(path, length * i / count)
					p.y += 1.5 * sin(p.x * 0.035 + trial)
					pts.append(CENTER + p.rotated(trial * 0.2) * (0.8 + 0.02 * trial))
				raw_wrong += int(ContractShape.classify(pts) != &"")
				_fresh()
				var c := _draw(pts)
				input_wrong += int(c == null or c.shaped())
				runs += 1
	_check(raw_wrong == 0 and input_wrong == 0,
		"%d crooked open strokes preserve positions: raw %d/input %d false figures" %
		[runs, raw_wrong, input_wrong])
