extends SceneTree
## Простор учебного треугольника: ввод мышью, старая отметка, первый вход и обычный бой.
## --shot-dir <папка> сохраняет короткую визуальную пробу при запуске с рендером.

const SAVE := "user://legion_lesson_space_test.cfg"
const FPS := 60
const CENTER := Vector2(230, 540)
const OFFSETS := [Vector2.ZERO, Vector2(40, 0), Vector2(-40, 0),
	Vector2(0, 40), Vector2(0, -40)]

var w: LegionWorld
var _checks := 0
var _fails := 0
var _shots := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shot-dir")
	if i >= 0 and i + 1 < args.size():
		_shots = args[i + 1]
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	_fails += 0 if ok else 1
	print("  ok   " if ok else "  FAIL ", label)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _frames(2)
	_data_and_flags()
	for r: int in [60, 80, 100]:
		for offset: Vector2 in OFFSETS:
			await _gesture(float(r), offset)
	for selected: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		await _gesture(60.0, Vector2.ZERO, selected)
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"no_waves": "1", "difficulty": "intern"}
	w.start_map("bridge")
	var ordinary := w.army_alive()
	for i in FPS:
		w._step(1.0 / FPS)
	_check(w.army_alive() == ordinary, "обычный бой без урока не получает бойцов")
	w.start_map("bridge")
	for l: Dictionary in w.map["lessons"]:
		if l["id"] == "triangle":
			l["hold"] = 0
	w.start_lessons(true)
	await _frames(2)
	_check(w.army_alive() == ordinary, "урок без удержания не получает бойцов")
	Campaign.record_result("bridge", true, 0.9)
	w.start_map("bridge")
	w.start_lessons()
	_check(w.tutorial == null and w.army_alive() == ordinary,
		"выигранный Мост не повторяет урок и не получает бойцов")
	w.queue_free()
	await _frames(2)
	Campaign.reset()
	print("LEGION LESSON SPACE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _data_and_flags() -> void:
	var bridge := LegionWorld.load_map("bridge")
	var maze := LegionWorld.load_map("maze")
	var lessons := LegionTutorial.parse(bridge)
	_check(not lessons.is_empty() and lessons[0]["id"] == &"triangle"
		and lessons[0]["start"], "треугольник учится в начале Моста")
	var mark: Dictionary = lessons[0].get("mark", {}) if not lessons.is_empty() else {}
	_check(mark.get("at", []) == [CENTER.x, CENTER.y] and mark.get("r", 0) == 60,
		"жесты проверяют действительное место и радиус учебного шаблона")
	_check(LegionTutorial.parse(maze).is_empty(), "Лабиринт проверяет навыки без нового урока")
	_check(not (maze.get("walls", []) as Array).is_empty(), "стены Лабиринта сохранены")
	Campaign.reset()
	for map_id: String in ["wasteland", "gatehouse", "fork", "archive"]:
		Campaign.record_result(map_id, true, 0.9)
	_check(Campaign.is_unlocked("bridge") and not Campaign.is_unlocked("maze")
		and Campaign.stat(&"shape_unlocked_triangle") > 0.5,
		"треугольник открыт при первом входе на Мост")
	Campaign.mark_hint_seen(&"lesson_maze_triangle")
	var repeat := false
	for l in LegionTutorial.pending("bridge", bridge):
		repeat = repeat or l["id"] == &"triangle"
	_check(not repeat, "старый зачёт lesson_maze_triangle не повторяет урок")
	_check(LegionTutorial.flag("bridge", &"triangle") == &"lesson_maze_triangle",
		"новый зачёт хранится совместимым флагом")
	_check(String(lessons[0].get("voice", "")) == "lg_tut_triangle",
		"урок сохраняет записанную реплику")


func _gesture(r: float, offset: Vector2,
		selected: StringName = LegionCfg.KIND_LABORER) -> void:
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"no_waves": "1", "difficulty": "intern"}
	w.start_map("bridge")
	w.contracts.set_kind(selected)
	w.start_lessons()
	await _frames(2)
	if r == 60.0 and offset == Vector2.ZERO:
		_check(w.contracts.current_kind == LegionCfg.KIND_LABORER,
			"урок выбирает учебных подрядчиков после вида %s" % selected)
		await _shot("bridge_triangle_lesson")
	var pts := LegionLessonBot.template("triangle", CENTER + offset, r)
	var clean := true
	for i in range(1, pts.size()):
		clean = clean and not w.terrain.is_rock(pts[i]) and \
			w.terrain.segment_clear(pts[i - 1], pts[i]).distance_to(pts[i]) < 0.5
	_check(clean, "берег не режет r%.0f, сдвиг %s" % [r, str(offset)])
	await _mouse(pts[0], true)
	for i in range(1, pts.size()):
		var ev := InputEventMouseMotion.new()
		ev.position = root.get_final_transform() * pts[i]
		ev.global_position = ev.position
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(ev)
		await _frames(1)
	await _mouse(pts[pts.size() - 1], false)
	await _frames(2)
	var c: Contract = null
	if not w.contracts.contracts.is_empty():
		c = w.contracts.contracts[w.contracts.contracts.size() - 1]
	_check(c != null and c.figure == ContractShape.TRIANGLE,
		"настоящая мышь рисует треугольник r%.0f, сдвиг %s" % [r, str(offset)])
	_check(Campaign.hint_seen(&"lesson_maze_triangle"), "созданная фигура засчитывает урок")
	if r == 60.0 and offset == Vector2.ZERO and c != null:
		for i in FPS * 6:
			w._step(1.0 / FPS)
		_check(c.fill() >= FigureCfg.RITE_FILL and w.army_alive() == ContractField.fig_need(c),
			"учебный шаблон набирает полстроя ровно достаточным подкреплением")
		w.contracts.release(c, 0)
		_check(int(w.stats.get("rites", 0)) == 1, "сорванный учебный треугольник даёт Обряд")
	if r == 100.0 and offset == Vector2(40, 0):
		await _shot("bridge_triangle_r100_dx40")


func _mouse(at: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = root.get_final_transform() * at
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


func _shot(name: String) -> void:
	if _shots == "":
		return
	DirAccess.make_dir_recursive_absolute(_shots)
	await _frames(30)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	_check(img.save_png("%s/%s.png" % [_shots, name]) == OK, "кадр " + name)
