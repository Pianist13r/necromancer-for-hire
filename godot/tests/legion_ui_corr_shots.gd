extends SceneTree
## Кадры для приёмки UI-правок ночной партии 29.09 (slow/ui-corr): экран итога поверх боя «Болота»,
## плашки уроков/брифинга, склеп с подсказкой. Не тест — кадры в --out-dir; смотреть глазами.
## Запуск: --path godot --fixed-fps 60 --script res://tests/legion_ui_corr_shots.gd -- --mute
##   --dev save=user://ui_corr.cfg --out-dir C:/AI/necro/batches/legion/ui-corr-0929 --tag after
## --map ID — карта боя (по умолчанию swamp); --frames N — сколько кадров боя до снимка.

var _main: Node
var _out := "C:/AI/necro/batches/legion/ui-corr-0929"
var _tag := "after"
var _map := "swamp"
var _frames := 240
var _narrow := false


func _initialize() -> void:
	_run.call_deferred()


func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := "%s/%s_%s.png" % [_out, _tag, name]
	print(JSON.stringify({"shot": path, "error": img.save_png(path)}))


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match String(args[i]):
			"--out-dir":
				_out = String(args[i + 1])
			"--tag":
				_tag = String(args[i + 1])
			"--map":
				_map = String(args[i + 1])
			"--narrow":
				_narrow = true
			"--frames":
				_frames = int(args[i + 1])
	DirAccess.make_dir_recursive_absolute(_out)
	_main = (load("res://scenes/legion.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for _i in 10:
		await process_frame
	_main.call("start_battle", _map)
	for _i in _frames:
		await process_frame
	await _shot("battle_" + _map)
	var w: LegionWorld = _main.get("world")
	if _narrow:
		# штрих в узком месте у скалы: подпись «узко — ведите наискось» у конца
		w.contracts.mana = 100.0
		w.contracts.begin(Vector2(450, 240))
		w.contracts.extend(Vector2(450, 212))
		w.contracts.finish()
		for _i in 12:
			await process_frame
		await _shot("narrow_" + _map)
	w.hold = false
	_main.call("_on_match_ended", false, {"hp": 0.0, "kills": 116, "lost": 253, "charges": 99,
		"refreshes": 46, "releases": 13, "releases_manual": 13, "t": 232.0})
	for _i in 30:
		await process_frame
	await _shot("result_" + _map)
	quit()
