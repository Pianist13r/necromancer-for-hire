extends SceneTree
##
## Кадры приёмки линии newbie2 (находки кампании новичка 180f1168) — не гейт: нужен рендер,
## запуск ОКНОМ (окно уводит за экран автолоад agent_window по --mute). Идёт через LegionMain.
## Сохранение — user://legion.cfg, поэтому ТОЛЬКО с APPDATA, подменённым на песочницу: скрипт
## сам отказывается работать, если каталог данных — настоящий каталог владельца.
##
##   APPDATA=<песочница> "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720
##       --script res://tests/legion_newbie2_shots.gd
##       -- --mute --out C:/AI/necro/batches/procgen/newbie2/shots
##
## Кадры: rally_closed (слот «Сбор» закрыт на «Пустыре», B-089), charge_edge (натиск к краю
## «Пустыря» встаёт у края, B-087), hero_screen (экран героя без панели волн, B-093), lull_hint
## (совет «F» в затишье «Двух отделов», B-078), corridor_line (линия поперёк коридора 67 px,
## B-092). Итог — строка JSON {"shots": [...]}.
##

const SIZE := Vector2i(1280, 720)

var main: LegionMain
var _out := "C:/AI/necro/batches/procgen/newbie2/shots"
var _saved: Array[String] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		_out = args[i + 1]
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var path := "%s/%s.png" % [_out, name]
	if img.save_png(path) == OK:
		_saved.append(path)


func _run() -> void:
	var data_dir := OS.get_user_data_dir().replace("\\", "/")
	if data_dir.contains("/AppData/Roaming/"):
		push_error("кадры newbie2: APPDATA не подменён — сохранение владельца под угрозой, выхожу")
		quit(2)
		return
	DisplayServer.window_set_size(SIZE)
	DirAccess.make_dir_recursive_absolute(_out)
	Campaign.set_save_path(Campaign.PATH)
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	main = (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await _frames(3)
	# 1. «Пустырь» новичка: «Сбор» закрыт — слот тёмный
	main.start_battle("wasteland")
	await _frames(30)
	await _shot("rally_closed")
	# 2. «Пустырь», низ слева (свободная земля до карточек видов): отряд в 50 px от нижнего края
	# срывается рогаткой вниз — встаёт у края (16 px), не уходит за кадр
	Campaign.reset()
	Campaign.unlock_all()
	main.start_battle("wasteland")
	await _frames(2)
	var w := main.world
	if w.tutorial != null:
		w.tutorial.skip()
	for k in 8:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(110.0 + 14.0 * k, 660.0))
		u.start_charge(Vector2.DOWN, w._volley(Vector2.DOWN, 1.0, false, true))
	await _frames(90)
	await _shot("charge_edge")
	# 3. после боя — экран героя без панели волн и полоски видов
	w.force_end(true)
	await _frames(3)
	main.show_hero(func() -> void: pass)
	await _frames(10)
	await _shot("hero_screen")
	# 4. «Два отдела»: затишье до первого контакта — совет «F»
	Campaign.reset()
	Campaign.unlock_all()
	Settings.hints_override = "on"
	main.start_battle("fork")
	await _frames(2)
	w = main.world
	if w.tutorial != null:
		w.tutorial.skip()
	var shown := false
	for i in 60 * 30:
		await process_frame
		if w.intuit.hints_shown(&"call") > 0:
			shown = true
			break
	await _frames(20)
	await _shot("lull_hint" if shown else "lull_hint_missing")
	# 5. «Два отдела»: штрих поперёк коридора между оградой и стеной (x = 460) — линия есть
	w.contracts.mana = w.contracts.mana_max
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	w.contracts.begin(Vector2(460, 112))
	for k in range(1, 13):
		w.contracts.extend(Vector2(460, lerpf(112.0, 190.0, k / 12.0)))
	w.contracts.finish()
	await _frames(40)
	await _shot("corridor_line")
	Settings.hints_override = ""
	Campaign.reset()
	print(JSON.stringify({"shots": _saved}))
	quit(0)
