extends SceneTree
##
## Замер цены кадра линий-договоров (не тест гейта). Окном, без vsync:
##
##   "$GODOT" --path godot --resolution 1280x720 --script res://tests/legion_lines_bench.gd
##       -- --mute [--case steady|blink] [--seconds 6]
##
## Карта fork, 6 договоров по ~470 px (LINE_MAX 480) (по два каждого вида), бойцы и ~40 врагов в драке у линий.
## steady — договоры не тают (ровная линия: быстрый путь одной ломаной); blink — все участки в
## последних секундах срока (путь по участкам, течения нет). Печатает JSON {frame_ms медиана/
## среднее/p90}. Скрипт использует только API, которое есть и на master (сравнение A/B).
##

const DT := 1.0 / 60.0

var w: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var case := _arg(argv, "--case", "steady")
	var seconds := _arg(argv, "--seconds", "6").to_float()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	Campaign.set_save_path("user://legion_lines_bench.cfg")
	Campaign.reset()
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.dev_invuln = true
	# давка выключена: прорыв снимал бы участки, и к замеру договоров становилось бы меньше
	w.dev["press_off"] = "1"
	seed(3)
	w.start_map("fork")
	var lines: Array[Contract] = []
	for i in 6:
		var kind: StringName = LegionCfg.KIND_ORDER[i % 3]
		var y := 150.0 + i * 85.0
		var pts := PackedVector2Array()
		for j in 78:   # ~470 px штрихом мыши по 6 px (LINE_MAX 480 с запасом на изгиб)
			pts.append(Vector2(330.0 + j * 6.0, y + sin(j * 0.12 + i) * 10.0))
		var c := w.contracts.add_contract(pts, 1, false, kind)
		if c != null:
			lines.append(c)
			c.ttl = 1.0e6
		for k in 8:
			w.spawn_unit(kind, Vector2(340.0 + k * 55.0, y + 30.0))
	for k in 40:
		var p := Vector2(860.0 + (k % 5) * 20.0, 150.0 + (k / 5) * 60.0)
		w.spawn_foe_on_path("zombie", PackedVector2Array([p, Vector2(300.0, p.y)]), p)
	# разогрев: набор и сход в драку
	for k in 240:
		_hold(lines, case)
		w._step(DT)
		await process_frame
	var times := PackedFloat64Array()
	var t0 := Time.get_ticks_usec()
	var last := t0
	while float(Time.get_ticks_usec() - t0) < seconds * 1.0e6:
		_hold(lines, case)
		w._step(DT)
		await process_frame
		var now := Time.get_ticks_usec()
		times.append(float(now - last) / 1000.0)
		last = now
	var sorted := times.duplicate()
	sorted.sort()
	var total := 0.0
	for t in times:
		total += t
	print(JSON.stringify({
		"case": case, "frames": times.size(), "contracts": w.contracts.contracts.size(),
		"units": w.army_alive(), "foes": w.active_foes(),
		"median_ms": snappedf(sorted[sorted.size() / 2], 0.001),
		"mean_ms": snappedf(total / times.size(), 0.001),
		"p90_ms": snappedf(sorted[int(sorted.size() * 0.9)], 0.001),
	}))
	quit(0)


## Держим сценарий: ровные договоры не стареют, «мигающие» стоят в последних 2 с срока.
func _hold(lines: Array[Contract], case: String) -> void:
	for c in lines:
		if case == "blink":
			c.ttl = LegionCfg.SEG_TTL
			c.seg_age.fill(c.ttl - 2.0)
		else:
			c.seg_age.fill(0.0)


func _arg(argv: PackedStringArray, key: String, def: String) -> String:
	var i := argv.find(key)
	return argv[i + 1] if i >= 0 and i + 1 < argv.size() else def
