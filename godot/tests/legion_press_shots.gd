extends SceneTree
##
## Кадры приёмки «Давки» и «Пружины» (v18, не тест гейта). Окном, не headless:
##
##   "$GODOT" --path godot --resolution 1280x720 --fixed-fps 60
##       --script res://tests/legion_press_shots.gd -- --mute --out C:/AI/necro/batches/legion/v18/press
##
## «Два отдела», стена подряда поперёк северной дороги, колонна из 16 зомби (урона нет):
## кадры прогиба на трети и двух третях, прорыва; затем вторая стена — пружина на 0,7.
##

const DT := 1.0 / 60.0

var w: LegionWorld
var _out := ""


func _initialize() -> void:
	_run.call_deferred()


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(_out.path_join(name))
	print("кадр ", name)


func _wall() -> Contract:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	w.dev_invuln = true
	for i in 14:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300.0 + 8.0 * float(i % 10),
			262.0 + 6.0 * float(i / 10)))
	var pts := PackedVector2Array([Vector2(290, 230), Vector2(390, 230)])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false)
	c.set_dir(Vector2.UP)
	c.ttl = 9999.0
	for step in roundi(4.0 / DT):
		w._step(DT)
	var path := PackedVector2Array([Vector2(340, 160), Vector2(340, 290), Vector2(180, 360)])
	for i in 16:
		w.spawn_foe_on_path("zombie", path,
			Vector2(340.0 + (6.0 if i % 2 == 0 else -6.0), 150.0 - 18.0 * float(i)))
	return c


func _max_bend(c: Contract) -> float:
	var b := 0.0
	for s in c.seg_count():
		if c.seg_alive(s):
			b = maxf(b, c.bend_frac(s))
	return b


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	_out = args[i + 1] if i >= 0 and i + 1 < args.size() else "user://press_shots"
	DirAccess.make_dir_recursive_absolute(_out)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	var c := _wall()
	await _shot("press_0_wall.png")
	var marks := [0.33, 0.66, 0.95]
	var k := 0
	for step in roundi(25.0 / DT):
		w._step(DT)
		if k < marks.size() and _max_bend(c) >= float(marks[k]):
			await _shot("press_%d_bend.png" % (k + 1))
			k += 1
		if int(w.stats.get("press_breaks", 0)) > 0:
			for j in 8:
				w._step(DT)
			await _shot("press_4_break.png")
			for j in 90:
				w._step(DT)
			await _shot("press_5_after.png")
			break
	c = _wall()
	var seg := -1
	for step in roundi(25.0 / DT):
		w._step(DT)
		for s in c.seg_count():
			if c.seg_alive(s) and c.bend_frac(s) >= 0.7:
				seg = s
		if seg >= 0:
			break
	if seg >= 0:
		w.dev_invuln = false
		w.contracts.release_aimed(c, seg, Vector2.UP, 0.9, false)
		for j in 12:
			w._step(DT)
			w.contracts.real_tick(DT)
		await _shot("press_6_spring.png")
	print("готово: ", _out)
	quit(0)
