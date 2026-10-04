extends SceneTree
##
## Кадры уроков каждой карты кампании v20 (плашка + метка) в масштабе 1280×720 — для приёмки
## глазами (не гейт: нужен рендер, запуск ОКНОМ). Идёт через настоящую кампанию: LegionMain,
## start_battle(карта) — уроки поднимает сама кампания; урок ставится force_lesson, повод
## (первый враг, элитный, продавленная линия) готовит скрипт.
## Сохранение — user://legion.cfg, поэтому запускать ТОЛЬКО с APPDATA, подменённым на песочницу:
## скрипт сам отказывается работать, если каталог данных — настоящий каталог владельца.
##
##   APPDATA=<песочница> "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720
##       --script res://tests/legion_lessons_shots.gd -- --mute --out C:/AI/necro/batches/legion/lessons
##
## Файлы <карта>_<урок>.png; итог — строка JSON {"shots": [...]}.
##

const SHOT_FRAMES := 100
const SIZE := Vector2i(1280, 720)
const MAPS := ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze", "swamp"]

var _out := "C:/AI/necro/batches/legion/lessons"
var main: LegionMain
var w: LegionWorld


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		_out = args[i + 1]
	_run.call_deferred()


func _run() -> void:
	var data_dir := OS.get_user_data_dir().replace("\\", "/")
	print("user data: ", data_dir)
	if data_dir.contains("/AppData/Roaming/"):
		push_error("кадры уроков: APPDATA не подменён — сохранение владельца под угрозой, выхожу")
		quit(2)
		return
	DisplayServer.window_set_size(SIZE)
	DirAccess.make_dir_recursive_absolute(_out)
	Campaign.set_save_path(Campaign.PATH)
	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	main.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(main)
	await _frames(3)
	var saved: Array[String] = []
	for map_id: String in MAPS:
		for l in LegionTutorial.parse(LegionWorld.load_map(map_id)):
			var path := await _shot(map_id, l)
			if path != "":
				saved.append(path)
	print(JSON.stringify({"shots": saved}))
	quit(0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(map_id: String, l: Dictionary) -> String:
	Campaign.reset()
	Campaign.unlock_all()
	main.start_battle(map_id)
	await _frames(2)
	w = main.world
	var tut := w.tutorial
	if tut == null:
		push_error("кадры уроков: на %s кампания не подняла уроки" % map_id)
		return ""
	var id: StringName = l["id"]
	var when := String(l["when"])
	var c: Contract = null
	var foe: Foe = null
	if when.begins_with("wave:"):
		# урок посреди боя стоит, пока его условие есть сейчас (D-0927-54): повод — N-я волна
		w.wave_runner.index = maxi(w.wave_runner.index, int(when.get_slice(":", 1)) - 1)
	if not l["start"]:
		# «Сбор» — у свободных без дела: строй не ставим, бойцы стоят у Котла
		if l["kind"] != &"rally":
			c = _line_near()
		for f in 150:
			await process_frame
	if when.begins_with("first_foe:"):
		foe = _foe_before(when.get_slice(":", 1), c, 90.0)
	elif when == "first_elite":
		foe = _foe_before("zombie", c, 120.0)
		foe.make_elite()
	if l["kind"] == &"hero_w":
		var victim := _foe_before("zombie", c, 70.0)
		victim.take_damage(victim.hp + 999.0, victim.position)
	if l["kind"] == &"stun_hit" and foe != null:
		foe.stun(30.0)
	tut.force_lesson(id)
	for f in SHOT_FRAMES:
		if c != null and when == "pressed" and is_instance_valid(c):
			for s in c.seg_count():
				if c.seg_alive(s):
					c.seg_bend[s] = LegionCfg.PRESS_BREAK * 0.6
		if foe != null and is_instance_valid(foe) and foe.alive and l["kind"] == &"stun_hit":
			foe.stun(30.0)
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img.get_size() != SIZE:
		img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s_%s.png" % [_out, map_id, String(id)]
	return path if img.save_png(path) == OK else ""


## Договор у Котла, стрелкой от него: строй встаёт сразу (материал урока посреди боя).
func _line_near() -> Contract:
	var mid := w.cauldron_pos + Vector2(130.0, 0.0)
	var pts := PackedVector2Array([mid + Vector2(0, -60), mid + Vector2(0, 60)])
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false)
	c.ttl = 999.0
	return c


func _foe_before(type: String, c: Contract, ahead: float) -> Foe:
	var base := c.point_at(c.length * 0.5) if c != null else w.cauldron_pos + Vector2(260, 0)
	var dir := c.dir if c != null else Vector2.RIGHT
	var at := base + dir * ahead
	return w.spawn_foe_on_path(type, PackedVector2Array([at, w.cauldron_pos]), at)
