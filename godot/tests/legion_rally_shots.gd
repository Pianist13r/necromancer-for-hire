extends SceneTree
##
## Кадры приёмки «Сбора» (R) и панели способностей v18 (не тест гейта). Окном, не headless:
##
##   "$GODOT" --path godot --resolution 1280x720 --fixed-fps 60
##       --script res://tests/legion_rally_shots.gd -- --mute --out C:/AI/necro/batches/legion/v18/rally
##
## «Пустырь»: восемь свободных у дороги, R по курсору в стороне — кадр вспышки, кадр в пути,
## кадр «дошли» и крупно панель с откатом.
##

const DT := 1.0 / 60.0

var w: LegionWorld
var _out := ""


func _initialize() -> void:
	_run.call_deferred()


func _shot(name: String) -> void:
	w._fx.queue_redraw()     # мир не в _process (шаги вручную) — вспышки перерисовать самим
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(_out.path_join(name))
	print("кадр ", name)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	_out = args[i + 1] if i >= 0 and i + 1 < args.size() else "user://rally_shots"
	DirAccess.make_dir_recursive_absolute(_out)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("wasteland")
	for k in 8:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(500.0 + 12.0 * float(k % 4),
			560.0 + 12.0 * float(k / 4)))
	for step in 30:
		w._step(DT)
	await _shot("rally_0_before.png")
	var m := InputEventMouseMotion.new()
	m.position = Vector2(640, 470)
	w._input(m)
	var k := InputEventKey.new()
	k.physical_keycode = KEY_R
	k.pressed = true
	w._unhandled_input(k)
	for step in 8:
		w._step(DT)
	await _shot("rally_1_flash.png")
	for step in 60:
		w._step(DT)
	await _shot("rally_2_walk.png")
	for step in 240:
		w._step(DT)
	await _shot("rally_3_done.png")
	print("готово: ", _out)
	quit(0)
