extends SceneTree
## B-414 (координатор 05.10, slow/tutorial-lesson 10.10): урок рогатки по ОДНОЙ фигуре стоял на
## «Прорабе» — последней и самой тяжёлой карте кампании (0/5 у бота), а рогатка — базовый приём
## (Игорь 09.10: главный продающий). Урок переехал в «Архив» — первую карту, где открывается
## фигура, которую рогатка срывает целиком (восьмёрка; кольцо рогатка не срывает, а сжимает):
## сразу за уроком восьмёрки, пока волна ещё ждёт. Зачёт — рогатка по ЛЮБОЙ фигуре.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_tutorial_lesson_1010_test.gd -- --mute
##
## 1) данные: на «Прорабе» урока рогатки нет; в «Архиве» он второй, за восьмёркой, держит волну,
##    шаблон — восьмёрка (открыта этой картой), голос учит текущему правилу (B-483);
##    это первая карта лестницы, где открыта фигура, которую рогатка срывает целиком;
## 2) игрок настоящим вводом: штрих восьмёрки → урок рогатки встаёт следом, волна ждёт, шаблон
##    не рисуется (восьмёрка уже стоит) → ПКМ, оттяжка, отпускание → урок зачтён, волна не шла;
## 3) бот уроков: вторую восьмёрку поверх стоящей не чертит, срывает её рогаткой;
## 4) «классика» (ПКМ — только щелчок, рогатки нет): урока нет — он не держит плашку и не
##    загораживает уроки счетовода и предмета.
## Сохранение — временный файл. Итог «LEGION TUTORIAL LESSON 1010: N/M OK»; код 1 при провале.
##

const SAVE := "user://legion_tutorial_lesson_1010.cfg"
const SETTINGS := "user://legion_tutorial_lesson_1010_settings.cfg"
const FPS := 60
const LESSON_MAP := "archive"
const OLD_MAP := "boss"
const ID := &"sling_one"
## Фигуры, которые рогатка срывает целиком (ContractFigures.release → figure_slung). Кольцо —
## сжатие (_squeeze), не рогатка по фигуре.
const SLUNG_SHAPES := ["eight", "triangle", "square", "pentagon", "d_shape"]

var w: LegionWorld
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Settings.path = SETTINGS
	Settings._cfg = ConfigFile.new()
	Settings.scheme_override = Settings.SCHEME_SLING
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _frames(2)
	_test_data()
	_test_tradeoff_text()
	await _test_player()
	await _test_natural_melt()
	await _test_bot()
	await _test_classic()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION TUTORIAL LESSON 1010: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Бой карты в кампании (всё открыто), уроки — как у игрока (не force), волны идут.
func _start(map_id: String, bot := "") -> LegionTutorial:
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern"}
	w.args.erase("bot")
	if bot != "":
		w.args["bot"] = bot
	w.start_map(map_id)
	w.start_lessons(false)
	var tut := w.tutorial
	await _frames(2)
	return tut


func _slung_lessons(map_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for l in LegionTutorial.parse(LegionWorld.load_map(map_id)):
		if l["kind"] == &"figure_slung":
			out.append(l)
	return out


# ── 1. Данные ────────────────────────────────────────────────────────────────

func _test_data() -> void:
	print("— данные: где стоит урок рогатки")
	_check(_slung_lessons(OLD_MAP).is_empty(),
		"«Прораб»: урока рогатки больше нет (%d)" % _slung_lessons(OLD_MAP).size())
	var ids: Array[StringName] = []
	for l in LegionTutorial.parse(LegionWorld.load_map(LESSON_MAP)):
		ids.append(l["id"])
	_check(str(ids) == str([&"eight", ID, &"clerk", &"item"]),
		"«Архив»: восьмёрка, рогатка, счетовод, предмет (%s)" % str(ids))
	var found := _slung_lessons(LESSON_MAP)
	_check(found.size() == 1, "«Архив»: ровно один урок рогатки")
	if found.size() != 1:
		return
	var l: Dictionary = found[0]
	_check(l["id"] == ID and l["start"] and float(l["hold"]) > 0.0,
		"урок начала боя и держит волну (hold %s)" % str(l["hold"]))
	_check(String(l["arg"]) == "eight", "шаблон — восьмёрка (%s)" % l["arg"])
	var unlocks: Array = LegionWorld.load_map(LESSON_MAP).get("unlocks", [])
	_check(unlocks.has("shape_unlocked_" + String(l["arg"])),
		"фигура шаблона открывается этой картой (%s)" % str(unlocks))
	_check(l["voice"] == &"lg_tut_sling_one",
		"B-483: рогатка выбирает голос без несуществующей соседней фигуры")
	# первая карта лестницы, где открыта фигура, которую рогатка срывает целиком
	var first := ""
	for m in Campaign.maps():
		var opens := false
		for key: Variant in m.get("unlocks", []):
			for shape: String in SLUNG_SHAPES:
				opens = opens or String(key) == "shape_unlocked_" + shape
		if opens:
			first = String(m.get("id", ""))
			break
	_check(first == LESSON_MAP, "это первая карта с такой фигурой (%s)" % first)


func _test_tradeoff_text() -> void:
	var tut := LegionTutorial.new()
	tut.lessons = LegionTutorial.parse(LegionWorld.load_map(LESSON_MAP))
	_check(tut.lessons[tut.index_of(&"eight")]["voice"] == &"lg_tut_eight",
		"B-483: восьмёрка выбирает голос естественного таяния")
	var old_language := I18n.language
	for language in ["ru", "en"]:
		I18n.select(language)
		var draw_text := tut.step_text(tut.index_of(&"eight"))
		var sling_text := tut.step_text(tut.index_of(ID))
		var fill := str(roundi(FigureCfg.OVERTIME_FILL * 100.0)) + "%"
		_check(draw_text.contains(fill), "%s: порог естественного бонуса из конфига" % language)
		_check(not draw_text.contains("{") and not sling_text.contains("{"),
			"%s: учебные токены раскрыты" % language)
		_check(sling_text.contains("без «Сверхурочных»") if language == "ru"
			else sling_text.contains("without Overtime"), "%s: цена раннего выпуска явная" % language)
		_check(not sling_text.contains("соседняя") and not sling_text.contains("next one"),
			"%s: нет обещания про отсутствующую соседнюю фигуру" % language)
	I18n.select(old_language)


# ── 2. Игрок настоящим вводом ────────────────────────────────────────────────

func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2, mask: int = 0) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := {MOUSE_BUTTON_LEFT: MOUSE_BUTTON_MASK_LEFT, MOUSE_BUTTON_RIGHT: MOUSE_BUTTON_MASK_RIGHT}
	ev.button_mask = int(bit.get(button, 0)) if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


func _stroke(pts: PackedVector2Array) -> void:
	await _move(pts[0])
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for i in range(1, pts.size()):
		await _move(pts[i], MOUSE_BUTTON_MASK_LEFT)
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	await _frames(2)


func _eights() -> Array[Contract]:
	var out: Array[Contract] = []
	for c in w.contracts.contracts:
		if c.alive() and c.figure == ContractShape.EIGHT:
			out.append(c)
	return out


func _test_player() -> void:
	print("— игрок: восьмёрка, затем рогатка по ней")
	var tut := await _start(LESSON_MAP)
	_check(tut != null and tut.step_id() == &"eight", "старт «Архива»: урок восьмёрки")
	if tut == null or tut.index_of(ID) < 0:
		_check(false, "урока рогатки в «Архиве» нет — сценарий не идёт")
		return
	var wave0 := w.wave_runner.wave_no()
	await _stroke(tut.figure_points())
	await _frames(2)
	_check(tut.passed(&"eight"), "восьмёрка начерчена штрихом ЛКМ — урок зачтён")
	_check(tut.step_id() == ID, "следом встал урок рогатки (%s)" % tut.step_id())
	_check(w.wave_runner.held, "волна ждёт — спокойное окно")
	_check(tut.figure_standing(), "восьмёрка урока стоит — чертить вторую не надо")
	var marks: Node = tut.get("_marks")
	_check(marks != null and marks.call("shows_template") == false,
		"шаблон «где чертить» поверх своей фигуры не рисуется")
	var eights := _eights()
	_check(eights.size() == 1, "на поле одна восьмёрка (%d)" % eights.size())
	if eights.is_empty():
		return
	var c := eights[0]
	# дать строю встать (как игрок, прочитав плашку)
	for i in int(2.0 * FPS):
		w._step(1.0 / FPS)
	var seg := -1
	for s in c.seg_count():
		if c.seg_alive(s) and seg < 0:
			var hit := w.contracts.pick_segment(c.seg_center(s))
			if not hit.is_empty() and hit["contract"] == c:
				seg = s
	_check(seg >= 0, "ПКМ над восьмёркой берёт именно её")
	if seg < 0:
		return
	var at := c.seg_center(seg)
	var pull := at + (w.cauldron_pos - at).normalized() * LegionCfg.SLING_ARM * 2.0
	await _move(at)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _move(at.lerp(pull, 0.5), MOUSE_BUTTON_MASK_RIGHT)
	await _move(pull, MOUSE_BUTTON_MASK_RIGHT)
	await _button(pull, MOUSE_BUTTON_RIGHT, false)
	await _frames(3)
	_check(tut.passed(ID) or not tut.active, "ПКМ, оттяжка, отпускание — урок рогатки зачтён")
	_check(Campaign.hint_seen(LegionTutorial.flag(LESSON_MAP, ID)), "флаг урока в сохранении")
	_check(int(w.stats.get("overtime_armed", 0)) == 0,
		"B-483: ранний выпуск не обещает бонус таяния")
	_check(w.wave_runner.wave_no() == wave0,
		"пока шли оба урока, волна не начиналась (%d → %d)" % [wave0, w.wave_runner.wave_no()])


## Тот же штрих, но игрок выбирает подождать. Зачёт рогатки не подменяется таймером;
## бонус должен случиться, а после него должна остаться возможность дорисовать упражнение.
func _test_natural_melt() -> void:
	var tut := await _start(LESSON_MAP)
	await _stroke(tut.figure_points())
	var eights := _eights()
	_check(eights.size() == 1, "B-483: для сравнения нарисована одна восьмёрка")
	if eights.is_empty():
		return
	var c := eights[0]
	for i in int(3.0 * FPS):
		w._step(1.0 / FPS)
	_check(c.posted_posts() >= ceili(c.posts.size() * FigureCfg.OVERTIME_FILL),
		"B-483: учебная восьмёрка набирает порог бонуса обычной вербовкой")
	for i in int((c.ttl + FigureCfg.OVERTIME_DELAY + FigureCfg.OVERTIME_WAIT) * FPS):
		w._step(1.0 / FPS)
	_check(int(w.stats.get("overtime_armed", 0)) == 1 and int(w.stats.get("overtimes", 0)) == 1,
		"B-483: естественное таяние даёт второй приказ")
	_check(not tut.passed(ID) and tut.step_id() == ID,
		"B-483: таяние не выдаётся за выполненную рогатку")
	_check(not tut.figure_standing(), "B-483: после таяния вновь доступен шаблон для штриха")
	await _stroke(tut.figure_points())
	_check(tut.figure_standing(), "B-483: после ожидания можно начертить новую восьмёрку")


# ── 3. Бот уроков ────────────────────────────────────────────────────────────


func _test_bot() -> void:
	print("— бот уроков: рогатка по уже стоящей восьмёрке")
	var made := [0]
	var count := func(c: Contract) -> void:
		if c.figure == ContractShape.EIGHT:
			made[0] += 1
	w.contracts.figure_made.connect(count)
	var tut := await _start(LESSON_MAP, "selective")
	var ok := false
	for i in int(30.0 * FPS):
		if tut == null or tut.passed(ID) or (tut.index_of(ID) >= 0 and not tut.active):
			ok = tut != null
			break
		w._step(1.0 / FPS)
	w.contracts.figure_made.disconnect(count)
	_check(ok and tut.passed(&"eight") and tut.passed(ID),
		"бот прошёл восьмёрку и рогатку за 30 с боя")
	_check(made[0] == 1, "восьмёрка начерчена один раз, а не поверх стоящей (%d)" % made[0])


# ── 4. «Классика» ────────────────────────────────────────────────────────────

func _test_classic() -> void:
	print("— «классика»: рогатки нет — урока нет")
	Settings.scheme_override = Settings.SCHEME_CLASSIC
	var ids: Array[StringName] = []
	for l in LegionTutorial.pending(LESSON_MAP, LegionWorld.load_map(LESSON_MAP), true):
		ids.append(l["id"])
	_check(not ids.has(ID) and ids.has(&"eight") and ids.has(&"clerk"),
		"в «классике» урока рогатки нет, остальные на месте (%s)" % str(ids))
	var tut := await _start(LESSON_MAP)
	if tut != null:
		tut._passed[&"eight"] = true
		tut._next()
	w.spawn_foe("ghost", "north", {})
	w._step(1.0 / FPS)
	_check(tut != null and tut.step_id() == &"clerk",
		"после восьмёрки первый призрак ставит урок счетовода (%s)"
		% (tut.step_id() if tut != null else "—"))
	Settings.scheme_override = Settings.SCHEME_SLING
	ids.clear()
	for l in LegionTutorial.pending(LESSON_MAP, LegionWorld.load_map(LESSON_MAP), true):
		ids.append(l["id"])
	_check(ids.has(ID), "в схеме «рогатка» урок на месте")
