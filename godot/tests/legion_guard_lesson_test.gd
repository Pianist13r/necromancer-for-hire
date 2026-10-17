extends SceneTree
## B-499: покупка Проходной не заменяет полезное оттеснение конкретной угрозы.

const DT := 1.0 / 60.0
const TARGET_AT := Vector2(500, 378)

var checks := 0
var fails := 0
var w: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _run() -> void:
	Settings.path = "user://guard_lesson_settings.cfg"
	Settings._cfg = ConfigFile.new()
	Campaign.set_save_path("user://guard_lesson_test.cfg")
	Campaign.reset()
	var map: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/legion/maps/gatehouse.json"))
	var lessons := LegionTutorial.parse(map)
	var push: Dictionary = {}
	for l in lessons:
		if l["id"] == &"guard_push":
			push = l
	check(not push.is_empty(), "отдельный урок полезного оттеснения существует")
	if not push.is_empty():
		check(push["kind"] == &"guard_push", "зачёт — результат, а не покупка или выпуск")
		check(not push["start"] and float(push["hold"]) == 0.0,
			"обычные волны идут, учебных врагов и подарков нет")
		check(push["voice"] == &"lg_tut_guard_push", "шаг оттеснения озвучен отдельно от постройки")
		check((push["mark"] as Dictionary).has("line"), "показано место защиты дороги к Котлу")
	check(FileAccess.file_exists("res://scripts/legion/legion_guard_lesson.gd"),
		"причинный наблюдатель полезного оттеснения существует")
	_text_checks(push)
	root.size = Vector2i(1280, 720)
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	_trigger_and_purchase()
	_positive()
	_empty_release()
	_wrong_foe()
	_walk_and_kill()
	_auto_melt()
	_toward_cauldron()
	_rebind_while_pushing()
	_stale_target()
	_no_guard_and_rally()
	_guard_without_shield_rally()
	_distant_guards_and_recovery()
	_empty_line_recovery()
	_distant_front()
	_bot_creates_guard_line()
	_bot_keeps_front()
	_skip_and_restart()
	Settings.lefty_override = ""
	I18n.language = "ru"
	Campaign.reset()
	w.queue_free()
	await process_frame
	print("LEGION GUARD LESSON: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _text_checks(push: Dictionary) -> void:
	if push.is_empty():
		return
	check(push.get("after", &"") == &"guard", "полезный выпуск идёт после урока Проходной")
	check(LessonsCfg.GUARD_PUSH_CREDIT >= 24.0, "порог результата не ниже 24 px")
	var old_language := I18n.language
	var old_lefty := Settings.lefty_override
	var formatter := LegionTutorial.new()
	formatter.lessons = [push]
	for locale in ["ru", "en"]:
		I18n.language = locale
		for lefty in [false, true]:
			Settings.lefty_override = "on" if lefty else "off"
			var lines := [formatter.step_text(0),
				Controls.text(LegionGuardLesson.WAIT_TEXT),
				Controls.text(LegionGuardLesson.APPROACH_TEXT),
				Controls.text(LegionGuardLesson.PUSH_TEXT),
				Controls.text(LegionGuardLesson.FRONT_TEXT),
				Controls.text(LegionGuardLesson.TURN_TEXT),
				Controls.text(LegionGuardLesson.REDRAW_TEXT),
				Controls.text(LegionGuardLesson.DONE_TEXT),
				Controls.text(LegionGuardLesson.EMPTY_TEXT)]
			for line: String in lines:
				check(line.length() <= 110 and not line.contains("{"),
					"%s/левша=%s: текст после Controls.text ≤110 (%d)" %
					[locale, lefty, line.length()])
			if lefty:
				check(lines[0].contains(MouseBind.label(&"draw"))
					and lines[3].contains(MouseBind.label(&"sling")),
					"%s: плашки называют текущие кнопки левши" % locale)
	Controls.rebind(&"rune_frost", KEY_H)
	for locale in ["ru", "en"]:
		I18n.language = locale
		check(formatter.step_text(0).contains(Controls.label(&"rune_frost", true)),
			"%s: переназначенная клавиша Охраны попала в плашку" % locale)
	Controls.reset()
	I18n.language = old_language
	Settings.lefty_override = old_lefty


func _base() -> LegionTutorial:
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.start_map("gatehouse")
	w.start_lessons(true)
	return w.tutorial


func _target(at := TARGET_AT, kind := "shield_inspector") -> Foe:
	var f := w.spawn_foe_on_path(kind, PackedVector2Array([at, w.cauldron_pos]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = f.hp
	return f


func _lesson(at := TARGET_AT) -> Foe:
	var tut := _base()
	var f := _target(at)
	tut.force_lesson(&"guard_push")
	tut._passed[&"guard"] = true
	check(tut.step_id() == &"guard_push" and tut.guard_lesson.target == f,
		"плашка назначила именно живого щитоносца")
	return f


func _line(x := 460.0, dir := Vector2.RIGHT, manned := true) -> Contract:
	var pts := PackedVector2Array([Vector2(x, 344), Vector2(x, 412)])
	var c := w.contracts.add_contract(pts, 1, false, LegionCfg.KIND_GUARD)
	if c == null:
		return null
	c.ttl = 999.0
	c.set_dir(dir)
	if manned:
		for p: Dictionary in c.posts:
			var u := w.spawn_unit(LegionCfg.KIND_GUARD, p["pos"])
			u.assign(c, p)
			u._arrive()
	return c


func _steps(n: int) -> void:
	for i in n:
		w._step(DT)


func _trigger_and_purchase() -> void:
	var tut := _base()
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._next()
	var f := _target()
	var units_before := w.units.size()
	var foes_before := w.foes.size()
	var mana_before := w.contracts.mana
	_steps(1)
	check(tut.step_id() == &"guard" and not tut.passed(&"guard_push"),
		"близкий щитоносец сначала показывает Проходную, не засчитывает выпуск")
	var plot: Dictionary = {}
	for p: Dictionary in w.staff.plots:
		if p["id"] == "p1":
			plot = p
			break
	w.souls = LegionStaff.build_price(LegionCfg.KIND_GUARD)
	var built := w.staff.build(plot, LegionCfg.KIND_GUARD)
	check(built != null, "реальная покупка Проходной прошла")
	var souls_after_buy := w.souls
	_steps(2)
	check(tut.step_id() == &"guard_push" and not tut.passed(&"guard_push")
		and not tut._credit, "покупка открыла урок, но не засчитала оттеснение")
	check(tut.guard_lesson.target == f and tut.guard_lesson.present(tut.lesson()),
		"урок появился при близкой угрозе в конце коридора")
	check(not w.wave_runner.held and not tut.holding(), "урок оттеснения не держит волну")
	check(w.foes.size() == foes_before and tut._staff_spawned == 0
		and w.units.size() <= units_before + built.cap
		and w.units.slice(units_before).all(func(u: Legionnaire) -> bool:
			return u.kind == LegionCfg.KIND_GUARD),
		"урок не создаёт бойцов и врагов сверх штатного найма Проходной")
	check(w.contracts.mana <= mana_before + 1.0,
		"урок не дарит ману сверх обычной регенерации")
	check(w.souls == souls_after_buy, "урок не возвращает души после покупки")


func _positive() -> void:
	var f := _lesson()
	var tut := w.tutorial
	var c := _line()
	check(c != null and tut.guard_lesson.ready(), "живой guard-строй готов к ручному выпуску")
	if c == null:
		return
	var before := f.position.distance_to(w.cauldron_pos)
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(140)
	var gain := f.position.distance_to(w.cauldron_pos) - before
	check(gain >= 24.0, "настоящий фронт отодвинул назначенного щитоносца от Котла на %.2f px" % gain)
	check(tut.passed(&"guard_push") and Campaign.hint_seen(
		LegionTutorial.flag("gatehouse", &"guard_push")),
		"результат фронта зачтён и записан в сохранение")


func _empty_release() -> void:
	_lesson()
	var tut := w.tutorial
	var c := _line(460.0, Vector2.RIGHT, false)
	if c == null:
		check(false, "пустая guard-линия создана")
		return
	w.release_segment(c, 0)
	_steps(2)
	check(not tut._credit and not tut.passed(&"guard_push"),
		"ручной выпуск пустого участка не засчитывает результат")


func _wrong_foe() -> void:
	var shield := _lesson(Vector2(630, 378))
	var tut := w.tutorial
	var other := _target(Vector2(490, 378), "zombie")
	var before := other.position.x
	var c := _line()
	if c == null:
		check(false, "guard-линия для чужой цели создана")
		return
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(70)
	check(other.position.x > before + 1.0 and shield.position.x < 631.0,
		"guard-фронт реально сдвинул другого врага, назначенный щит остался в стороне")
	check(not tut._credit and not tut.passed(&"guard_push"),
		"оттеснение чужого врага не засчитывается")


func _walk_and_kill() -> void:
	var f := _lesson()
	var tut := w.tutorial
	f.position += Vector2(35, 0)
	_steps(1)
	check(not tut._credit and not tut.passed(&"guard_push"),
		"обычное движение щитоносца от Котла не выдаёт зачёт")
	var before_death := f.position
	f.take_damage(f.hp + 1.0, f.position)
	_steps(2)
	check(f.position == before_death and not tut._credit and not tut.passed(&"guard_push"),
		"убийство без оттеснения не выдаёт зачёт")


func _auto_melt() -> void:
	var f := _lesson()
	var tut := w.tutorial
	var c := _line()
	if c == null:
		check(false, "guard-линия для таяния создана")
		return
	var before := f.position.x
	w.release_segment(c, 0, &"melt")
	_steps(140)
	check(f.position.x > before + 1.0, "автотаяние действительно двинуло щитоносца")
	check(not tut._credit and not tut.passed(&"guard_push"),
		"автотаяние даже с оттеснением не засчитывается")


func _toward_cauldron() -> void:
	var f := _lesson()
	var tut := w.tutorial
	var c := _line(540.0, Vector2.LEFT)
	if c == null:
		check(false, "guard-линия для движения к Котлу создана")
		return
	check(not tut.guard_lesson.ready(),
		"плашка не зовёт к выпуску, когда стрелка guard направлена к Котлу")
	var before := f.position.distance_to(w.cauldron_pos)
	w.release_segment_aimed(c, 0, Vector2.LEFT, 1.0, false)
	_steps(140)
	check(f.position.distance_to(w.cauldron_pos) < before - 1.0,
		"фронт действительно сдвинул щитоносца к Котлу")
	check(not tut._credit and not tut.passed(&"guard_push"),
		"движение к Котлу не засчитывается")


func _rebind_while_pushing() -> void:
	_lesson()
	var tut := w.tutorial
	if _line() == null:
		check(false, "guard-линия для смены клавиши создана")
		return
	_steps(1)
	check(tut.guard_lesson.ready()
		and tut._banner._label.text == Controls.text(LegionGuardLesson.PUSH_TEXT),
		"перед сменой клавиши показан совет выпуска")
	Controls.rebind(&"rune_frost", KEY_H)
	_steps(1)
	check(tut._banner._label.text == tut.guard_lesson.text(),
		"смена клавиши сохраняет актуальный динамический совет выпуска")
	Controls.reset()


func _stale_target() -> void:
	var f := _lesson()
	var tut := w.tutorial
	check(_line() != null and tut.guard_lesson.present(tut.lesson()),
		"живые вахтёры и щит в коридоре делают урок доступным")
	f.position.x = 400.0
	check(not tut.guard_lesson.present(tut.lesson()),
		"ушедший с последнего участка щитоносец не держит урок без новой цели")


func _no_guard_and_rally() -> void:
	var tut := _base()
	_target()
	tut.force_lesson(&"guard_push")
	check(not tut.guard_lesson.present(tut.lesson()),
		"без Проходной и вахтёров щитоносец не вызывает невыполнимый урок")
	tut = _base()
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._next()
	w.wave_runner.index = 1
	for i in 3:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, w.cauldron_pos + Vector2(20 * i, 0))
		u.idle_time = LegionCfg.IDLE_NOTICE_TIME + 1.0
	_steps(1)
	check(tut.step_id() == &"rally" and not tut.passed(&"guard_push"),
		"если guard-урок недоступен, «Сбор» на волне 2 не ждёт его вечно")


func _guard_without_shield_rally() -> void:
	var tut := _base()
	var built := w.staff.build(w.staff.plots[0], LegionCfg.KIND_GUARD)
	check(built != null, "Проходная для проверки «Сбора» без угрозы куплена")
	var f := _target(Vector2(650, 378))
	f.take_damage(f.hp + 1.0, f.position)
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._next()
	w.wave_runner.index = 1
	for i in 3:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, w.cauldron_pos + Vector2(20 * i, 0))
		u.idle_time = LegionCfg.IDLE_NOTICE_TIME + 1.0
	_steps(1)
	check(w.active_foes() == 0 and tut.step_id() == &"rally",
		"после гибели всех щитов «Сбор» не ждёт guard-урока при построенной Проходной")


func _distant_guards_and_recovery() -> void:
	_lesson(Vector2(650, 378))
	var tut := w.tutorial
	var push := tut.lesson()
	var built := w.staff.build(w.staff.plots[1], LegionCfg.KIND_GUARD)
	check(built != null, "дальняя Проходная как в seed91 построена справа")
	var far := _line(860.0)
	var empty := _line(460.0, Vector2.RIGHT, false)
	if far == null or empty == null:
		check(false, "дальний строй и пустая учебная линия созданы")
		return
	check(not tut.guard_lesson.present(push),
		"дальняя Проходная и охрана вне радиуса не открывают невыполнимый урок")
	check(tut.guard_lesson.text() != Controls.text(LegionGuardLesson.WAIT_TEXT),
		"пустая учебная линия не обещает марш оставшейся справа охраны")
	tut._voiced.erase(&"guard_push")
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	w.wave_runner.index = 1
	for i in 3:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, w.cauldron_pos + Vector2(20 * i, 0))
		u.idle_time = LegionCfg.IDLE_NOTICE_TIME + 1.0
	_steps(ceili(LessonsCfg.WITHDRAW_T / DT) + 2)
	check(tut.step_id() == &"rally" and not tut.passed(&"guard_push"),
		"недоступный guard-урок снимается без зачёта и освобождает «Сбор»")
	w.contracts.dismiss(far)
	for u in w.units:
		if u.kind == LegionCfg.KIND_GUARD:
			u.position = Vector2(450, 310)
	check(tut.guard_lesson.present(push) and not tut._credit,
		"приближение настоящей охраны возвращает доступность, но не зачёт")
	tut._passed[&"rally"] = true
	tut._next()
	_steps(2)
	check(tut.step_id() == &"guard_push" and not tut.passed(&"guard_push"),
		"после приближения охраны упражнение появляется повторно")


func _empty_line_recovery() -> void:
	_lesson()
	var tut := w.tutorial
	var c := _line(460.0, Vector2.RIGHT, false)
	if c == null:
		check(false, "пустая линия recovery создана")
		return
	var u := w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(450, 310))
	check(tut.guard_lesson.text() != Controls.text(LegionGuardLesson.WAIT_TEXT),
		"близкий свободный вахтёр ещё не означает марш к пустой линии")
	u.assign(c, c.posts[0])
	check(u.state == Legionnaire.State.MARCH
		and tut.guard_lesson.text() == Controls.text(LegionGuardLesson.WAIT_TEXT),
		"ожидание марша появляется только после настоящего назначения к линии")
	u._arrive()
	check(tut.guard_lesson.text() != Controls.text(LegionGuardLesson.WAIT_TEXT)
		and tut.guard_lesson.present(tut.lesson()),
		"прибытие к линии возвращает рабочую подсказку без ложного ожидания")


func _distant_front() -> void:
	var tut := _base()
	_target(Vector2(650, 378))
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._passed[&"guard"] = true
	tut._next()
	var c := _line(860.0)
	if c == null:
		check(false, "дальняя линия для перевода охраны создана")
		return
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	check(not LegionRoleRelease.jobs(w).is_empty(), "дальний выпуск создал настоящий guard-фронт")
	var push := tut.lessons[tut.index_of(&"guard_push")]
	check(not tut.present(push), "дальний фронт не делает учебную линию достижимой")
	_steps(2)
	check(tut.step_id() != &"guard_push" and not tut.passed(&"guard_push"),
		"перевод охраны справа не вызывает урок рисования слева и не даёт зачёт")


func _bot_creates_guard_line() -> void:
	_lesson()
	var tut := w.tutorial
	tut.guard_lesson.act()
	var c := tut.guard_lesson.line()
	check(c != null and c.kind == LegionCfg.KIND_GUARD,
		"помощник при пустой линии действительно чертит Охрану")


func _bot_keeps_front() -> void:
	_lesson()
	var tut := w.tutorial
	var c := _line()
	if c == null:
		check(false, "guard-линия для проверки помощника создана")
		return
	tut.guard_lesson.act()
	var jobs := LegionRoleRelease.jobs(w).size()
	check(jobs > 0, "помощник выпустил живой guard-фронт")
	check(tut.guard_lesson.present(tut.lesson()),
		"местный выпущенный фронт сохраняет доступность упражнения")
	tut.guard_lesson.tick()
	check(tut.guard_lesson.text() == Controls.text(LegionGuardLesson.FRONT_TEXT)
		and tut._banner._label.text == tut.guard_lesson.text(),
		"пока фронт идёт, плашка просит дождаться результата")
	var lines_before := w.contracts.contracts.size()
	tut.guard_lesson.act()
	check(LegionRoleRelease.jobs(w).size() == jobs
		and w.contracts.contracts.size() == lines_before,
		"помощник не чертит новую Охрану поверх ещё идущего фронта")


func _skip_and_restart() -> void:
	_lesson()
	var tut := w.tutorial
	check(not Campaign.hint_seen(LegionTutorial.flag("gatehouse", &"guard_push")),
		"незачтённый урок не записан как пройденный")
	w.restart()
	check(w.tutorial != null and w.tutorial.index_of(&"guard_push") >= 0,
		"рестарт незачтённого урока сохраняет его в списке")
	if w.tutorial == null:
		return
	w.tutorial.skip()
	_steps(1)
	check(Campaign.hint_seen(LegionTutorial.flag("gatehouse", &"guard_push")),
		"явный пропуск записывает флаг урока")
	check(LegionTutorial.pending("gatehouse", w.map).all(func(l: Dictionary) -> bool:
		return l["id"] != &"guard_push"), "после пропуска урок не появляется снова")
