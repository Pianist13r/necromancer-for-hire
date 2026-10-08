extends Node
##
## Водитель ввода: проходит обучение на wasteland НАСТОЯЩИМИ событиями мыши и клавиатуры
## (Input.parse_input_event в координатах окна — тот же путь, что у ОС), а не вызовами API мира.
## Нужен приёмке «глазами игрока» (владелец 25.09: прошлое обучение не проверяли вводом).
##
##   --dev tutorial=1 --dev tutorial_play=good|clumsy|pause   (обёртка — tools/tutorial_play.sh)
##
## Шаги (девять, TUTORIAL_SPEC.md): договор, стрелка (Пробел + мышь вбок), подновление (ЛКМ вдоль
## своей линии), натиск (ПКМ), «Сбор» (зажать и отпустить R), Бытовка, Q, W, E.
## good   — всё правильно и быстро;
## clumsy — на каждом шаге сперва 20+ с ничего не делает (линия на шагах стрелки и подновления
##          обязана дожить); договор — сперва чертит у правого края (далеко от армии), потом по
##          линии; натиск — не жмёт ПКМ, ждёт таяния; Бытовка — сперва кликает по линии договора
##          (растаяла — чертит новую и тычет в неё) и по земле, потом по КРАЮ площадки; Ку —
##          сперва жмёт Q мимо врага, потом по врагу;
## pause  — как good, но посреди шага натиска Esc, пауза, снова Esc;
## short  — шаг 1: короткий штрих по призраку (< 10 мест), затем сразу полный, дальше как good;
## kind   — шаг 1: клавиша 2 (вахтёры), штрих по призраку, затем 1 и снова штрих, дальше как good.
## В short/kind draw_counted_at_once — засчитана ли следующая полная попытка сразу.
##
## Путь кампании (LegionMain, без --map; сохранение — только во временный файл):
##   --dev save=user://legion_menu_test.cfg --dev tutorial_play=campaign|skip
## campaign — главное меню → клик «Начать кампанию» по её rect → вступление (клик ЛКМ по кадру,
##            как игрок, прочитав титр) → брифинг → «В бой» → в бою шаги как в good;
## skip     — тот же путь, на шаге 2 Esc → на экране паузы кампании клик «Пропустить обучение».
## В JSON: from_campaign (мир встроен в LegionMain и идёт в кампании) и video — секунды ролика,
## когда были меню, катсцена, брифинг, бой, пауза (по ним режутся кадры приёмки).
##
## Координаты сценария — мировые (1280×720); в окно их переводит get_final_transform() корневого
## окна (растяжение canvas_items). Проверка «куда попали события» — pointer_err в итоговом JSON:
## расстояние между точкой, куда водитель вёл мышь, и позицией, которую увидел мир из события.
## Свои события помечены device=DEVICE; настоящие мышь и клавиатура на время прогона глушатся
## (_input), чтобы случайное движение мыши владельца над окном не испортило запись.
## Итог — одна строка JSON {"tutorial_play": …} в stdout, затем выход (код 1 — не дошёл).
##

const DEVICE := 7
const DRAG_STEPS := 26
const DRAG_WOBBLE := 3.0
const STEP_LIMIT := 120.0
const IDLE_WAIT := 21.0
const READ_WAIT := 1.2
const TAIL_WAIT := 7.5
const FAR_A := Vector2(1150.0, 300.0)
const FAR_B := Vector2(1150.0, 440.0)
const EMPTY_GROUND := Vector2(640.0, 640.0)
const MISS_AIM := Vector2(1100.0, 600.0)
const PLOT_EDGE := Vector2(30.0, -18.0)
const EXTRA_A := Vector2(240.0, 470.0)
const EXTRA_B := Vector2(340.0, 470.0)
## Сценарий short: доля призрака, которую игрок протягивает в первой попытке (~75 из 108 px).
const SHORT_FRAC := 0.7
## Столько игрок читает кадр вступления, прежде чем кликнуть «дальше».
const CUT_READ := 2.5
const CUT_MAX_CLICKS := 12
const SCREEN_LIMIT := 15.0
const CENTER := Vector2(640.0, 360.0)
## Шаг «стрелка»: мышь уходит от середины линии дугой на AIM_SWING рад за AIM_STEPS кадров.
const AIM_STEPS := 10
const AIM_SWING := 1.3
const AIM_REACH := 90.0
## Столько держит R, разглядывая круг «Сбора».
const RALLY_HOLD := 0.6

var world: LegionWorld = null
## LegionMain — только в сценариях кампании (setup_main), иначе null.
var main: LegionMain = null
var scenario := "good"

var _last_screen := Vector2.ZERO
var _steps: Dictionary = {}
var _events: Array[String] = []
var _pointer_err := -1.0
var _aim_check: Dictionary = {}
var _clock := 0.0
var _video: Dictionary = {}
var _from_campaign := false


func setup(w: LegionWorld, s: String) -> void:
	world = w
	scenario = s
	name = "TutorialDriver"
	process_mode = Node.PROCESS_MODE_ALWAYS


## Путь кампании: водитель ведёт LegionMain от главного меню; мир появится после «В бой».
func setup_main(m: LegionMain, s: String) -> void:
	main = m
	scenario = s
	name = "TutorialDriver"
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_run()


func _process(dt: float) -> void:
	_clock += dt


func _input(event: InputEvent) -> void:
	if (event is InputEventMouse or event is InputEventKey) and event.device != DEVICE:
		get_viewport().set_input_as_handled()


func _run() -> void:
	await _frames(3)
	if main != null and not await _campaign_entry():
		return
	var tut := world.tutorial
	if tut == null:
		_done(false, "обучение не запущено (нужен --dev tutorial=1)")
		return
	tut.step_changed.connect(func(i: int) -> void:
		_steps["step%d" % (i + 1)] = snappedf(world.now, 0.1))
	tut.finished.connect(func() -> void: _steps["finished"] = snappedf(world.now, 0.1))
	_steps["step1"] = snappedf(world.now, 0.1)
	# v20 (D-0926-46): обучение «Пустыря» — шесть уроков; стрелка, «Сбор», Дубль-вэ и Е — уроки
	# следующих карт (их шаги водителя остались для кадров приёмки прошлых версий)
	var steppers: Array[Callable] = [_step_draw, _step_refresh, _step_release, _step_perfect,
		_step_build, _step_q]
	if scenario == "skip":
		steppers = [_step_draw, _step_skip]
	for stepper: Callable in steppers:
		if not bool(await stepper.call(tut)):
			return
	if not await _until(func() -> bool: return world.wave_runner.wave_no() >= 1, STEP_LIMIT):
		_done(false, "волны не пошли после обучения")
		return
	_steps["wave1"] = snappedf(world.now, 0.1)
	await _wait(TAIL_WAIT)
	_done(true, "")


# ── Кампания: меню → вступление → брифинг → бой ─────────────────────────────

func _campaign_entry() -> bool:
	if not await _until(func() -> bool: return main.screen is LegionMenu, SCREEN_LIMIT):
		_done(false, "главное меню не показалось")
		return false
	_mark("menu")
	await _wait(READ_WAIT)
	var start := main.screen.find_child("CampaignAction", true, false) as Button
	if start == null:
		_done(false, "в меню нет кнопки кампании (%s)" % str(_button_texts(main.screen)))
		return false
	_log("click «%s»" % start.text)
	await _click_control(start)
	if await _until(func() -> bool: return _find_child(LegionCutscene) != null, 5.0):
		_mark("cutscene")
		if scenario == "campaign":
			await _wait(READ_WAIT)
			var skip := _find_button(_find_child(LegionCutscene), "Пропустить")
			if skip != null:
				await _click_control(skip)
				_log("cutscene: clicked visible skip button")
		var clicks := 0
		while _find_child(LegionCutscene) != null and clicks < CUT_MAX_CLICKS:
			await _wait(CUT_READ)
			if _find_child(LegionCutscene) == null:
				break
			await _click(CENTER, MOUSE_BUTTON_LEFT)
			clicks += 1
		_log("cutscene clicks=%d" % clicks)
	else:
		_log("cutscene: не показана")
	if not await _until(func() -> bool: return main.screen is Briefing, SCREEN_LIMIT):
		_done(false, "брифинг не показался после вступления")
		return false
	await _wait(0.5)
	_mark("briefing")
	await _wait(READ_WAIT)
	var go := _find_button(main.screen, "В бой")
	if go == null:
		_done(false, "на брифинге нет «В бой» (%s)" % str(_button_texts(main.screen)))
		return false
	_log("click «В бой»")
	await _click_control(go)
	var ok := await _until(func() -> bool:
		return main.world != null and main.world.tutorial != null, SCREEN_LIMIT)
	if not ok:
		_done(false, "обучение не стартовало из кампании")
		return false
	world = main.world
	_from_campaign = world.embedded and world.in_campaign
	_mark("battle")
	return true


# ── Шаги ────────────────────────────────────────────────────────────────────

func _step_draw(tut: LegionTutorial) -> bool:
	if scenario == "clumsy":
		await _wait(IDLE_WAIT)
		_log("draw far t=%.1f" % world.now)
		await _drag(FAR_A, FAR_B)
		await _wait(3.0)
	else:
		await _wait(READ_WAIT)
	var pts := tut.ghost_points()
	var a := pts[0]
	var b := pts[pts.size() - 1]
	if scenario == "short":
		# послушный, но торопливый: штрих по призраку, не дотянув (~75 px, < 10 мест)
		_log("draw short t=%.1f" % world.now)
		await _drag(a, a.lerp(b, SHORT_FRAC))
		await _wait(0.8)
		_mark("toast_short")
		_aim_check["after_short"] = {"step": tut.step() + 1,
			"contracts": world.contracts.contracts.size()}
		await _wait(1.0)
	elif scenario == "kind":
		# игрок нажал 2 (вахтёры): штрих по призраку, подсказка, 1, снова штрих
		await _key(KEY_2)
		_log("kind=%s, draw ghost t=%.1f" % [world.contracts.current_kind, world.now])
		await _drag(a, b)
		await _wait(0.8)
		_mark("toast_kind")
		_aim_check["after_wrong_kind"] = {"step": tut.step() + 1,
			"contracts": world.contracts.contracts.size()}
		await _wait(1.0)
		await _key(KEY_1)
		await _wait(0.3)
	_log("draw ghost t=%.1f kind=%s" % [world.now, world.contracts.current_kind])
	await _drag(a, b)
	await _frames(3)
	# повторная попытка по призраку обязана засчитаться сразу, а не уйти в продление (ревью 25.09)
	_aim_check["draw_counted_at_once"] = tut.step() >= 1
	return await _expect_step(tut, _at(&"refresh"), "шаг 1 (договор) не зачтён")


## Стрелка: курсор на середину линии, Пробел зажат, мышь уходит вбок дугой, Пробел отпущен.
func _step_aim(tut: LegionTutorial) -> bool:
	await _wait(IDLE_WAIT if scenario == "clumsy" else READ_WAIT)
	var c := tut.line_target()
	if c == null:
		_done(false, "на шаге «стрелка» нет живой линии")
		return false
	var mid := c.point_at(c.length * 0.5)
	var d0 := c.dir
	_log("aim t=%.1f" % world.now)
	await _move(mid)
	await _key_state(KEY_SPACE, true)
	for i in range(1, AIM_STEPS + 1):
		await _move(mid + d0.rotated(AIM_SWING * i / AIM_STEPS) * AIM_REACH)
	await _key_state(KEY_SPACE, false)
	_aim_check["aim_turn_deg"] = snappedf(rad_to_deg(d0.angle_to(c.dir)), 1.0)
	return await _expect_step(tut, _at(&"refresh"), "шаг «стрелка» не зачтён")


## Подновление: ЛКМ-штрих вдоль своей линии от края до края.
func _step_refresh(tut: LegionTutorial) -> bool:
	await _wait(IDLE_WAIT if scenario == "clumsy" else READ_WAIT)
	var c := tut.line_target()
	if c == null:
		_done(false, "на шаге «подновление» нет живой линии")
		return false
	_log("refresh t=%.1f" % world.now)
	await _drag(c.point_at(4.0), c.point_at(c.length - 4.0))
	return await _expect_step(tut, _at(&"release"), "шаг «подновление» не зачтён")


func _step_release(tut: LegionTutorial) -> bool:
	if scenario == "clumsy":
		await _wait(IDLE_WAIT)
		_log("waiting melt t=%.1f" % world.now)
		return await _expect_step(tut, _at(&"perfect"), "шаг натиска не зачтён таянием")
	# как человек: ждёт, пока строй встанет на линии, и бьёт ПКМ по людному участку
	if not await _until(func() -> bool: return _manned_target(tut) >= 4, STEP_LIMIT):
		_done(false, "строй не встал на линии шага 2")
		return false
	if scenario == "pause":
		_log("esc t=%.1f" % world.now)
		await _key(KEY_ESCAPE)
		await _wait(2.0)
		_log("paused=%s" % str(world.paused))
		await _key(KEY_ESCAPE)
		await _wait(1.0)
		_log("resumed paused=%s" % str(world.paused))
	var hit := tut.release_target()
	if hit.is_empty():
		_done(false, "на шаге 2 нет живой линии для ПКМ")
		return false
	var at := (hit["contract"] as Contract).seg_center(int(hit["seg"]))
	_log("rmb t=%.1f" % world.now)
	await _click(at, MOUSE_BUTTON_RIGHT)
	return await _expect_step(tut, _at(&"perfect"), "шаг натиска не зачтён ПКМ")


## «Точно!»: ПКМ по участку со строем, оттяжка прочь от ближайшего учебного зомби, держать,
## пока зона удара не станет золотой (враг в ней), — отпустить.
func _step_perfect(tut: LegionTutorial) -> bool:
	if not await _until(func() -> bool:
			return _manned_target(tut) > 0 and tut.target_foe() != null, STEP_LIMIT):
		_done(false, "на уроке «Точно!» нет строя или врага")
		return false
	var hit := tut.release_target()
	var at := (hit["contract"] as Contract).seg_center(int(hit["seg"]))
	var foe := tut.target_foe()
	var pull := at - (foe.position - at).normalized() * LegionCfg.SLING_ARM * 1.6
	_log("sling t=%.1f" % world.now)
	await _move(at)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _move(pull, MOUSE_BUTTON_MASK_RIGHT)
	await _until(func() -> bool:
		var aim := world.contracts.sling_aim()
		return not aim.is_empty() and bool(aim["perfect"]), STEP_LIMIT)
	await _button(pull, MOUSE_BUTTON_RIGHT, false)
	return await _expect_step(tut, _at(&"build"), "урок «Точно!» не зачтён")


## «Сбор»: курсор к свободным, R зажата (круг прицела), отпущена — побежали.
func _step_rally(tut: LegionTutorial) -> bool:
	if not await _until(func() -> bool: return tut.rally_target() != Vector2.INF, STEP_LIMIT):
		_done(false, "на шаге «Сбор» нет свободных бойцов")
		return false
	await _wait(IDLE_WAIT if scenario == "clumsy" else READ_WAIT)
	var at := tut.rally_target()
	_log("rally t=%.1f" % world.now)
	await _move(at)
	await _key_state(KEY_R, true)
	await _wait(RALLY_HOLD)
	_aim_check["rally_aiming"] = world.rally_aiming
	await _key_state(KEY_R, false)
	return await _expect_step(tut, _at(&"build"), "шаг «Сбор» не зачтён")


func _step_build(tut: LegionTutorial) -> bool:
	var p := tut.target_plot()
	if p.is_empty():
		_done(false, "на шаге 3 нет отмеченной площадки")
		return false
	var click_at: Vector2 = p["pos"]
	if scenario == "clumsy":
		await _wait(IDLE_WAIT)
		if tut.release_target().is_empty():
			# линия шага 2 уже растаяла — неуклюжий игрок чертит новую, чтобы по ней ткнуть
			_log("draw extra line t=%.1f" % world.now)
			await _drag(EXTRA_A, EXTRA_B)
			await _wait(1.0)
		var hit := tut.release_target()
		var line_at := EXTRA_A.lerp(EXTRA_B, 0.5)
		if not hit.is_empty():
			line_at = (hit["contract"] as Contract).seg_center(int(hit["seg"]))
		_log("tap line t=%.1f live=%s" % [world.now, str(not hit.is_empty())])
		await _click(line_at, MOUSE_BUTTON_LEFT)
		await _wait(1.5)
		_log("tap ground t=%.1f" % world.now)
		await _click(EMPTY_GROUND, MOUSE_BUTTON_LEFT)
		await _wait(3.5)
		_log("menu open after misses=%s" % str(world.plot_menu.is_open()))
		# край видимой площадки: радиус 28 px сюда не доставал (баг v15)
		click_at += PLOT_EDGE
	else:
		await _wait(READ_WAIT)
	_log("tap plot t=%.1f" % world.now)
	await _click(click_at, MOUSE_BUTTON_LEFT)
	await _frames(3)
	if not world.plot_menu.is_open():
		_done(false, "клик по площадке не открыл меню")
		return false
	var btn: Button = null
	for b in world.plot_menu.buttons():
		if b.text.begins_with("Бытовка") and not b.disabled:
			btn = b
	if btn == null:
		_done(false, "в меню площадки нет доступной кнопки «Бытовка»")
		return false
	await _wait(0.6)
	_log("click button t=%.1f" % world.now)
	var at := btn.get_global_rect().get_center()
	await _move(at)
	_log("hover=%s" % str(get_viewport().gui_get_hovered_control() == btn))
	await _click(at, MOUSE_BUTTON_LEFT)
	return await _expect_step(tut, _at(&"hero_q"), "шаг «Бытовка» не зачтён")


## Сценарий skip: строй встал → Esc → «Пропустить обучение» на экране паузы кампании.
func _step_skip(tut: LegionTutorial) -> bool:
	if not await _until(func() -> bool: return _manned_target(tut) >= 4, STEP_LIMIT):
		_done(false, "строй не встал на линии шага 2")
		return false
	_log("esc t=%.1f" % world.now)
	await _key(KEY_ESCAPE)
	if not await _until(func() -> bool: return _find_child(LegionPause) != null, 3.0):
		_done(false, "экран паузы кампании не открылся")
		return false
	await _wait(1.0)
	_mark("pause")
	_aim_check["banner_hidden_on_pause"] = tut._banner != null and not tut._banner.visible
	await _wait(1.0)
	var skip := _find_button(_find_child(LegionPause), "Пропустить обучение")
	if skip == null:
		_done(false, "на паузе нет «Пропустить обучение»")
		return false
	_log("click «Пропустить обучение»")
	await _click_control(skip)
	var ok := await _until(func() -> bool:
		return world.tutorial == null and not world.paused, 3.0)
	if not ok:
		_done(false, "«Пропустить обучение» не сняло обучение / паузу")
		return false
	_steps["skipped"] = snappedf(world.now, 0.1)
	_aim_check["held_after_skip"] = world.wave_runner.held
	return true


func _step_q(tut: LegionTutorial) -> bool:
	if scenario == "clumsy":
		await _wait(IDLE_WAIT)
		await _move(MISS_AIM)
		await _frames(2)
		await _key(KEY_Q)
		await _frames(2)
		_log("q miss t=%.1f step=%d cd=%.1f" % [
			world.now, tut.step() + 1, world.hero.cd_left(LegionHero.SLOT_Q)])
		_aim_check["miss_counted"] = world.tutorial == null
		# каст мимо не состоялся: откат Ку не потрачен (LegionHero.cast вернул false)
		_aim_check["miss_cd_left"] = world.hero.cd_left(LegionHero.SLOT_Q)
		await _wait(1.5)
	if not await _until(func() -> bool: return _foe_on_screen(tut) != null, STEP_LIMIT):
		_done(false, "на шаге 4 нет зомби на экране")
		return false
	var f := _foe_on_screen(tut)
	var aim := f.position + Vector2(0.0, -20.0)
	await _move(aim)
	await _frames(2)
	_aim_check["event_mouse"] = world.aim_pos()
	_aim_check["os_mouse"] = world.get_global_mouse_position()
	_aim_check["target"] = aim
	_log("q t=%.1f" % world.now)
	await _key(KEY_Q)
	if not await _until(func() -> bool: return world.tutorial == null or tut.step() > _at(&"hero_q"),
			3.0):
		_done(false, "Ку по зомби не зачтена (%s)" % str(_aim_check))
		return false
	return true


## Дубль-вэ: курсор на свежий труп, W.
func _step_w(tut: LegionTutorial) -> bool:
	if not await _until(func() -> bool: return tut.target_corpse() != null, STEP_LIMIT):
		_done(false, "на шаге «Дубль-вэ» нет свежего трупа")
		return false
	await _wait(READ_WAIT)
	var corpse := tut.target_corpse()
	if corpse == null:
		_done(false, "свежий труп пропал до нажатия W")
		return false
	_log("w t=%.1f" % world.now)
	await _move(corpse.position)
	await _frames(2)
	await _key(KEY_W)
	return await _expect_step(tut, _at(&"hero_e"), "шаг «Дубль-вэ» не зачтён")


## Е: курсор в гущу своих, E — последний шаг.
func _step_e(tut: LegionTutorial) -> bool:
	await _wait(READ_WAIT)
	var at := tut.aura_target()
	if at == Vector2.INF:
		_done(false, "на шаге «Е» нет своих бойцов")
		return false
	_log("e t=%.1f" % world.now)
	await _move(at)
	await _frames(2)
	await _key(KEY_E)
	if not await _until(func() -> bool: return world.tutorial == null, 3.0):
		_done(false, "Е у своих не завершила обучение")
		return false
	return true


func _log(line: String) -> void:
	_events.append(line)
	print("DRIVER ", line)


# ── Ввод ────────────────────────────────────────────────────────────────────

func _screen(p: Vector2) -> Vector2:
	return get_viewport().get_final_transform() * p


func _move(p: Vector2, mask: int = 0) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.relative = sp - _last_screen
	ev.button_mask = mask
	_last_screen = sp
	Input.parse_input_event(ev)
	await _frames(1)
	if _pointer_err < 0.0 and world != null:
		_pointer_err = world.aim_pos().distance_to(p)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


## Клик по кнопке интерфейса — по центру её фактического прямоугольника на экране.
func _click_control(c: Control) -> void:
	var at := c.get_global_rect().get_center()
	await _move(at)
	await _click(at, MOUSE_BUTTON_LEFT)


func _click(p: Vector2, button: MouseButton) -> void:
	await _move(p)
	await _button(p, button, true)
	await _frames(2)
	await _button(p, button, false)


## Протяжка ЛКМ как рукой: нажать в a, вести с лёгкой дрожью по кадру на точку, отпустить в b.
func _drag(a: Vector2, b: Vector2) -> void:
	await _move(a)
	await _button(a, MOUSE_BUTTON_LEFT, true)
	for i in range(1, DRAG_STEPS + 1):
		var k := float(i) / float(DRAG_STEPS)
		var side := (b - a).orthogonal().normalized()
		var wobble := side * sin(k * TAU * 1.5) * DRAG_WOBBLE * (1.0 - absf(2.0 * k - 1.0))
		await _move(a.lerp(b, k) + wobble, MOUSE_BUTTON_MASK_LEFT)
	await _button(b, MOUSE_BUTTON_LEFT, false)


## Клавиша вниз или вверх отдельно — для удержания (Пробел стрелки, R «Сбора»).
func _key_state(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.device = DEVICE
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(2)


func _key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.device = DEVICE
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(2)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	Input.parse_input_event(up)
	await _frames(1)


# ── Ожидание ────────────────────────────────────────────────────────────────

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Ждать sec секунд кадрового времени (в записи --fixed-fps — игрового; на паузе тоже идёт).
func _wait(sec: float) -> void:
	var t := 0.0
	while t < sec:
		await get_tree().process_frame
		t += get_process_delta_time()


func _until(cond: Callable, limit: float) -> bool:
	var t := 0.0
	while not bool(cond.call()):
		if t >= limit:
			return false
		await get_tree().process_frame
		t += get_process_delta_time()
	return true


func _at(id: StringName) -> int:
	return world.tutorial.index_of(id) if world.tutorial != null else -1


func _expect_step(tut: LegionTutorial, idx: int, fail: String) -> bool:
	var ok := await _until(func() -> bool:
		return world.tutorial == null or tut.step() >= idx, STEP_LIMIT)
	if not ok:
		_done(false, fail)
	return ok


func _manned_target(tut: LegionTutorial) -> int:
	var hit := tut.release_target()
	if hit.is_empty():
		return 0
	return (hit["contract"] as Contract).seg_manned(int(hit["seg"]))


func _mark(what: String) -> void:
	_video[what] = snappedf(_clock, 0.1)
	_log("%s at video %.1f s" % [what, _clock])


func _find_child(type: Variant) -> Node:
	var root: Node = main if main != null else world
	for c in root.get_children():
		if is_instance_of(c, type) and not c.is_queued_for_deletion():
			return c
	return null


func _find_button(root: Node, prefix: String) -> Button:
	if root == null:
		return null
	for b in root.find_children("*", "Button", true, false):
		var btn := b as Button
		if btn.visible and not btn.disabled and btn.text.begins_with(prefix):
			return btn
	return null


func _button_texts(root: Node) -> Array[String]:
	var out: Array[String] = []
	if root != null:
		for b in root.find_children("*", "Button", true, false):
			out.append((b as Button).text)
	return out


func _foe_on_screen(tut: LegionTutorial) -> Foe:
	var f := tut.target_foe()
	if f != null and Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).has_point(f.position):
		return f
	return null


func _done(ok: bool, why: String) -> void:
	var win := DisplayServer.window_get_size()
	print(JSON.stringify({
		"tutorial_play": scenario, "ok": ok, "why": why,
		"t": snappedf(world.now, 0.1) if world != null else -1.0,
		"from_campaign": _from_campaign, "video": _video,
		"real_save_untouched": not Campaign.uses_real_save(),
		"steps": _steps, "events": _events, "pointer_err": snappedf(_pointer_err, 0.01),
		"aim": str(_aim_check), "window": [win.x, win.y],
		"final_transform": str(get_viewport().get_final_transform()),
		"tutorial_done_flag": Campaign.tutorial_done(),
	}))
	get_tree().quit(0 if ok else 1)
