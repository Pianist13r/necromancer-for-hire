extends SceneTree

var _checks := 0
var _fails := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])

func _run() -> void:
	var map := LegionWorld.load_map("wasteland")
	var lessons: Array = map.get("lessons", [])
	var draw_text := ""
	for lesson: Dictionary in lessons:
		if lesson.get("id", "") == "draw":
			draw_text = String(lesson.get("text", ""))
	_check(draw_text.contains("Шифт") and draw_text.contains("нов"),
		"первый урок поясняет Шифт и новый договор рядом с прежним")
	var d := LegionLessonBot.template("d_shape", Vector2.ZERO, 85.0)
	var max_x := 0.0
	for point: Vector2 in d:
		max_x = maxf(max_x, point.x)
	_check(max_x >= 104.0 and ContractShape.classify(d) == ContractShape.D_SHAPE,
		"образец D имеет выраженную выпуклую дугу и распознаётся тем же классификатором")
	var marks_script := load("res://scripts/legion/legion_tutorial_marks.gd") as Script
	_check(marks_script.has_method("template_motion_active")
		and not bool(marks_script.call("template_motion_active", 8.0)),
		"метка урока перестаёт бесконечно мигать")
	var w := LegionWorld.new()
	root.add_child(w)
	w.set_process(false)
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.dev["gray"] = "1"
	w.args["bot"] = "off"
	w.start_map("swamp")
	w.start_lessons(true)
	w.tutorial.force_lesson(&"d_shape")
	var marks := w.tutorial._marks
	marks._process(0.016)
	marks._process(6.1)
	_check(marks.shows_template() and not marks.template_motion_active(marks._step_t)
		and w.tutorial.figure_points().size() > 20
		and ContractShape.classify(w.tutorial.figure_points()) == ContractShape.D_SHAPE,
		"через 6 с остаётся полный статичный образец D, распознаваемый классификатором")
	var c: LegionCrypt = w.crypts[0]
	c.allegiance = LegionCrypt.Owner.ENEMY
	_check(c.label_text().length() < 20 and c.label_rect().position.y < 0.0,
		"вражеский склеп показывает короткий статус над собой, не длинную подсказку на поле")
	w.start_map("maze")
	w.start_lessons(true)
	w.tutorial.force_lesson(&"pentagon")
	var maze_marks := w.tutorial._marks
	_check(maze_marks.shows_template(), "без помощи учебный пятиугольник виден")
	w.contracts.active = true
	w.contracts.shapes[ContractShape.PENTAGON] = true
	var maze_guide_started := w.contracts.start_pentagon_guide()
	_check(maze_guide_started and not maze_marks.shows_template(),
		"при включённой помощи дубль учебного пятиугольника скрыт")
	var exit_guide := InputEventKey.new()
	exit_guide.keycode = KEY_ESCAPE
	exit_guide.pressed = true
	w.contracts._input(exit_guide)
	_check(maze_marks.shows_template(), "после Esc учебный образец возвращается")
	w.start_map("_gray")
	var field := w.contracts
	field.active = true
	field.shapes[ContractShape.PENTAGON] = true
	var mana_before := field.mana
	var contracts_before := field.contracts.size()
	_check(field.start_pentagon_guide(), "добровольная помощь доступна в бою")
	var guide := field.pentagon_guide
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = w.world_to_screen(Vector2(420, 360))
	var kind_before := field.current_kind
	field._unhandled_input(wheel)
	_check(guide.radius > 85.0 and field.current_kind == kind_before,
		"колесо меняет только размер направляющей, не вид договора")
	var click := InputEventMouseButton.new()
	click.button_index = MouseBind.physical(&"draw")
	click.pressed = true
	click.position = w.world_to_screen(Vector2(420, 360))
	field._unhandled_input(click)
	click.pressed = false
	field._unhandled_input(click)
	_check(guide.anchored and field.contracts.size() == contracts_before
		and is_equal_approx(field.mana, mana_before) and not field.has_draft(),
		"первый щелчок закрепляет ориентиры без договора и платы")
	var figure := LegionLessonBot.template("pentagon", guide.center, guide.radius)
	var ring := LegionLessonBot.template("ring", guide.center, guide.radius)
	_check(guide.corners_seen(figure) == 5 and guide.corners_seen(ring) < 3,
		"счётчик требует настоящих поворотов, круг не получает пять углов")
	field.begin(figure[0])
	for i in range(1, figure.size()):
		field.extend(figure[i])
	_check(field.mana < mana_before
		and is_equal_approx(mana_before - field.mana, field._draft_cost)
		and field.contracts.size() == contracts_before,
		"свободный обвод расходует ману по обычному правилу, договор ещё не создан")
	field.finish()
	_check(field.contracts.size() == contracts_before + 1
		and field.contracts[-1].figure == ContractShape.PENTAGON and field.mana < mana_before,
		"после release обычный классификатор создал Комиссию")
	field.start_pentagon_guide()
	Settings.lefty_override = "on"
	var mana_lefty := field.mana
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MouseBind.physical(&"draw")
	left_click.position = w.world_to_screen(Vector2(600, 360))
	left_click.pressed = true
	field._unhandled_input(left_click)
	_check(guide.floating and guide.blocked and not guide.anchored
		and is_equal_approx(field.mana, mana_lefty),
		"в стене ориентиры краснеют и не закрепляются")
	left_click.pressed = false
	field._unhandled_input(left_click)
	left_click.position = w.world_to_screen(Vector2(420, 360))
	left_click.pressed = true
	field._unhandled_input(left_click)
	_check(guide.anchored and left_click.button_index == MOUSE_BUTTON_RIGHT,
		"в режиме левши направляющая закрепляется кнопкой рисования")
	Settings.lefty_override = ""
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	field._input(esc)
	_check(not guide.enabled(), "Esc убирает направляющую")
	field.start_pentagon_guide()
	w.start_map("_gray")
	_check(not guide.enabled(), "новая карта убирает направляющую")
	var howto := HowtoLegion.new()
	howto.show_pentagon_help = true
	root.add_child(howto)
	_check(howto.find_child("HowtoPentagonHelp", true, false) != null,
		"повторный вход в помощь есть в справке фигур")
	howto.queue_free()
	w.queue_free()
	await process_frame
	print("LEGION PLAYTEST FEEDBACK: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
