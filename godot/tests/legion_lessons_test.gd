extends SceneTree
##
## Уроки карт кампании v20 (docs/legion/CAMPAIGN_V20.md, D-0926-46; Игорь 26.09: «все эти
## элементы постепенно в игре вводились и обучались тоже постепенно… первые два-три уровня»).
## Обучение «Пустыря» — в legion_tutorial_test; здесь — уроки карт 2–6, движок и открытия.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_lessons_test.gd -- --mute
##
## 1) данные: у каждой карты лестницы свои уроки (таблица EXPECT), каждый разбирается движком;
## 2) бот: каждый урок каждой карты проходится ботом через API мира (повод урока подготовлен
##    тестом — первый враг вида, элитный, продавливание; бот сам кастует, чертит, строит);
## 3) повод: первый щитоносец/Юрист, элитный, продавливание, волна — ставят урок сами;
##    урок «врага под Ку» без цели прячется и возвращается со следующим;
## 4) игрок НАСТОЯЩИМИ событиями ввода (мышь, клавиши; bot=off): стрелка Пробелом, Проходная,
##    пружина, «Сбор», кольцо, Дубль-вэ, Е по продавленной линии, восьмёрка, Бухгалтерия,
##    «Точно!» по нотариусу, Ку по Юристу, срыв по оглушённым, треугольник, квадрат; предмет — событием мира
##    (элитный убит); Таб над линией с бойцами — урок Таба (02.10.2026, просьба Игоря);
## 5) урок не повторяется (флаг в сохранении); hold держит волну недолго и не роняет Котёл;
## 6) вне кампании уроков нет, и бой бота побайтно прежний: трасса на трёх картах сверяется с
##    эталоном economy-mana: tests/data/legion_lessons_bot_ref.txt (происхождение — docs/dev/CODEX_MANA.md).
## Сохранение — временный файл (Campaign.set_save_path). Итог «LEGION LESSONS: N/M OK»; код 1.
##

const SAVE := "user://legion_lessons_test.cfg"
const FPS := 60
const DRAG_STEPS := 16
const BOT_REF := "res://tests/data/legion_lessons_bot_ref.txt"
## Бот вне кампании: карта, сид, шагов по 1/60 с (эталон интегрированного economy-mana).
const BOT_RUNS := [["gatehouse", 1, 4800], ["archive", 2, 4800], ["wasteland", 3, 4800]]
## Лестница CAMPAIGN_V20: карта → уроки по порядку.
const EXPECT := {
	"wasteland": [&"draw", &"refresh", &"release", &"perfect", &"build", &"hero_q"],
	"gatehouse": [&"aim", &"erase", &"guard", &"spring", &"rally"],
	"fork": [&"ring", &"hero_w", &"hero_e"],
	"archive": [&"eight", &"clerk", &"item"],
	"bridge": [&"triangle", &"perfect", &"lawyer_q", &"stun_hit"],
	"maze": [],
	"swamp": [&"square"],
	"boss": [],
}

var w: LegionWorld
var _checks := 0
var _fails := 0
var _toasts: Array[String] = []


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


func _on_toast(text: String, _kind: StringName) -> void:
	_toasts.append(text)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	w.toast_posted.connect(_on_toast)
	await _frames(2)
	# бот вне кампании — первым, пока мир ещё не видел уроков: порядок прогона как у эталона
	_test_bot_same()
	_test_data()
	await _test_bot_lessons()
	await _test_triggers()
	await _test_timing()
	await _test_input()
	await _test_tab_lesson()
	await _test_once_and_hold()
	await _test_no_gifts()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION LESSONS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Мир кампании с уроками ───────────────────────────────────────────────────

## Бой карты в кампании со всеми открытиями, уроки — принудительно все (force), волны стоят.
func _start(map_id: String, bot := "", waves := false) -> LegionTutorial:
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern"} if waves else {"difficulty": "intern", "no_waves": "1"}
	w.args.erase("bot")
	if bot != "":
		w.args["bot"] = bot
	w.start_map(map_id)
	w.start_lessons(true)
	# ссылка — до кадров: бот успевает пройти урок начала боя за эти кадры, и движок уходит
	var tut := w.tutorial
	await _frames(2)
	return tut


func _step_until(cond: Callable, seconds: float, each: Callable = Callable()) -> bool:
	for i in int(seconds * FPS):
		if bool(cond.call()):
			return true
		if each.is_valid():
			each.call()
		w._step(1.0 / FPS)
	return bool(cond.call())


func _wait_until(cond: Callable, seconds: float, each: Callable = Callable()) -> bool:
	for i in int(seconds * FPS):
		if bool(cond.call()):
			return true
		if each.is_valid():
			each.call()
		await process_frame
	return bool(cond.call())


## Первый живой договор вдоль бот-линии карты (как рисует бот), со строем.
func _line_on(map_id: String, idx := 0) -> Contract:
	var bl: Dictionary = (w.map["bot_lines"] as Array)[idx]
	var a := Vector2(float(bl["a"][0]), float(bl["a"][1]))
	var b := Vector2(float(bl["b"][0]), float(bl["b"][1]))
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	var c := w.contracts.add_contract(PackedVector2Array([a, b]),
		w.contracts.default_side(PackedVector2Array([a, b])), false)
	c.ttl = 999.0
	_step_until(func() -> bool: return _manned(c) >= 4, 12.0)
	return c


## Договор у самого Котла (строй дотягивается сразу), стрелкой от Котла.
func _line_near() -> Contract:
	var mid := w.cauldron_pos + Vector2(120.0, 0.0)
	var pts := PackedVector2Array([mid + Vector2(0, -60), mid + Vector2(0, 60)])
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false)
	c.ttl = 999.0
	_step_until(func() -> bool: return _manned(c) >= 6, 12.0)
	return c


func _manned(c: Contract) -> int:
	var n := 0
	for s in c.seg_count():
		if c.seg_alive(s):
			n += c.seg_manned(s)
	return n


## Враг вида type перед участком seg договора c (по его стрелке), на дорожке к Котлу.
func _foe_before(type: String, c: Contract, seg: int, ahead := 50.0) -> Foe:
	var at := c.seg_center(seg) + c.dir * ahead
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at, w.cauldron_pos]), at)
	return f


## Прогнуть все живые участки всех договоров (щелчок ПКМ берёт ближайший, какой бы ни был).
func _bend_all() -> void:
	for k in w.contracts.contracts:
		for s in k.seg_count():
			_bend(k, s)


## Прогнуть участок (как напор врагов): держится, пока тест зовёт каждый кадр.
func _bend(c: Contract, seg: int) -> void:
	if is_instance_valid(c) and c.seg_alive(seg):
		c.seg_bend[seg] = LegionCfg.PRESS_BREAK * 0.6


# ── 1. Данные ────────────────────────────────────────────────────────────────

func _test_data() -> void:
	print("— данные: уроки карт")
	for map_id: String in EXPECT:
		var raw: Array = LegionWorld.load_map(map_id).get("lessons", [])
		var ids: Array[StringName] = []
		for l in LegionTutorial.parse(LegionWorld.load_map(map_id)):
			ids.append(l["id"])
		_check(ids == Array(EXPECT[map_id], TYPE_STRING_NAME, "", null) and raw.size() == ids.size(),
			"%s: уроки %s" % [map_id, str(ids)])
		for l in LegionTutorial.parse(LegionWorld.load_map(map_id)):
			var text := String(l["text"])
			_check(text != "" and not text.contains("\n") and text.length() <= 110,
				"%s/%s: одна строка ≤110 знаков (%d)" % [map_id, l["id"], text.length()])


# ── 2. Бот проходит каждый урок через API ────────────────────────────────────

func _test_bot_lessons() -> void:
	print("— бот: каждый урок каждой карты")
	for map_id: String in EXPECT:
		for id: StringName in EXPECT[map_id]:
			var tut := await _start(map_id, "selective")
			if tut == null:
				_check(false, "%s: уроки не стартовали" % map_id)
				continue
			var l: Dictionary = tut.lessons[tut.index_of(id)]
			var c: Contract = null
			var target: Foe = null
			var when := String(l["when"])
			var kind: StringName = l["kind"]
			if not l["start"]:
				# урок посреди боя: у Котла уже стоит строй (как в настоящем бою)
				c = _line_on(map_id, _front_line(map_id))
			if when.begins_with("first_foe:"):
				target = _foe_before(when.get_slice(":", 1), c, 0)
			elif when == "first_elite":
				target = _foe_before("zombie", c, 0, 120.0)
				target.make_elite()
			if kind == &"hero_w":
				var victim := _foe_before("zombie", c, 0, 80.0)
				victim.take_damage(victim.hp + 999.0, victim.position)
			if when.begins_with("wave:"):
				# повод — идёт N-я волна (без него урок посреди боя гаснет, D-0927-54)
				w.wave_runner.index = int(when.get_slice(":", 1)) - 1
			if not tut.passed(id) and tut.step_id() != id:
				tut.force_lesson(id)
			var each := func() -> void:
				if c != null and when == "pressed":
					_bend(c, 0)
				if kind == &"rally":
					# «Сбор» — когда есть свободные без дела (D-0927-54): строй снят, а бот мира
					# чертил бы новые линии и забирал всех в строй — снимаем их, пока урок не сделан
					for k in w.contracts.contracts.duplicate():
						w.contracts.dismiss(k)
				if kind == &"item" and is_instance_valid(target) and target.alive and w.now > 2.0:
					target.take_damage(target.hp + 999.0, target.position)
			var ok := _step_until(func() -> bool: return tut.passed(id), 30.0, each)
			_check(ok, "бот %s/%s: урок пройден за %.1f с" % [map_id, id, w.now])
			if ok:
				_check(Campaign.hint_seen(LegionTutorial.flag(map_id, id)),
					"бот %s/%s: флаг урока в сохранении" % [map_id, id])
	w.args.erase("bot")


func _front_line(map_id: String) -> int:
	return 2 if map_id in ["gatehouse", "fork", "archive"] else 0


func _road() -> String:
	return String(((w.map["roads"] as Array)[0] as Dictionary)["id"])


# ── 3. Повод урока ───────────────────────────────────────────────────────────

func _test_triggers() -> void:
	print("— повод: урок встаёт сам")
	var tut := await _start("gatehouse")
	# начало боя: стрелка (держит волну)
	_check(tut != null and tut.step_id() == &"aim" and w.wave_runner.held,
		"Проходная: на старте — урок стрелки, волна ждёт")
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._next()
	_check(tut.step() < 0 and not w.wave_runner.held, "без повода плашка пуста, волна идёт")
	w.spawn_foe("shield_inspector", "gate", {})
	w._step(1.0 / FPS)
	_check(tut.step_id() == &"guard", "первый щитоносец поставил урок вахтёров (%s)" % tut.step_id())
	var c := _line_on("gatehouse", 2)
	_bend(c, 0)
	w._step(1.0 / FPS)
	_check(tut._armed.has(tut.index_of(&"spring")), "продавленный участок поставил «пружину» в очередь")
	tut._credit = true
	w._step(1.0 / FPS)
	_check(tut.step_id() == &"spring", "после вахтёров — следом «пружина» (%s)" % tut.step_id())

	tut = await _start("bridge")
	tut._passed[&"triangle"] = true
	tut._next()
	var lawyer := w.spawn_foe("lawyer", "north", {})
	w._step(1.0 / FPS)
	_check(tut.step_id() == &"lawyer_q", "первый Юрист поставил урок Ку (%s)" % tut.step_id())
	lawyer.take_damage(lawyer.hp + 999.0, lawyer.position)
	_step_until(func() -> bool: return tut.step_id() != &"lawyer_q", LessonsCfg.WITHDRAW_T + 2.0)
	_check(tut.step_id() != &"lawyer_q" and not tut.passed(&"lawyer_q"),
		"Юриста добили без Ку — урок спрятан и не зачтён")
	w.spawn_foe("lawyer", "north", {})
	_step_until(func() -> bool: return tut.step_id() == &"lawyer_q", 3.0)
	_check(tut.step_id() == &"lawyer_q", "следующий Юрист вернул урок Ку")

	tut = await _start("archive")
	tut._passed[&"eight"] = true
	tut._next()
	var elite := w.spawn_foe("zombie", "north", {})
	elite.make_elite()
	w._step(1.0 / FPS)
	_check(tut.step_id() == &"item", "элитный поставил урок предмета (%s)" % tut.step_id())
	_check(tut.wants_item(), "урок предмета ждёт — выпадение гарантировано")

	tut = await _start("fork", "", true)
	w.dev_invuln = true   # без бота волна дошла бы до Котла раньше второй
	tut._passed[&"ring"] = true
	tut._next()
	_step_until(func() -> bool: return w.wave_runner.wave_no() >= 2, 200.0)
	w._step(1.0 / FPS)
	w.dev_invuln = false
	# D-0927-54: урок Дубль-вэ — когда есть свежий труп; трупа нет — урока нет
	_check(tut.step_id() != &"hero_w" or tut.target_corpse() != null,
		"вторая волна «Развилки» без свежего трупа урок Дубль-вэ не ставит (%s)" % tut.step_id())
	var fell := _step_until(func() -> bool: return w.active_foes() > 0, 20.0)
	for f in w.foes:
		if is_instance_valid(f) and f.alive:
			f.take_damage(f.hp + 999.0, f.position)
			break
	w._step(1.0 / FPS)
	_check(fell and tut.step_id() == &"hero_w",
		"вторая волна «Развилки» и свежий труп поставили урок Дубль-вэ (%s)" % tut.step_id())


# ── 3а. Урок посреди боя — по ситуации сейчас (D-0927-54) ───────────────────

## Координатор 27.09 на «Проходной» (B-084): «Сбор» встал на волне 2, когда все стояли в строю;
## «пружина» висела на волне 4, когда ничего не было прогнуто. Урок посреди боя показывается,
## пока его условие есть сейчас, и гаснет, когда условие ушло, а урок не сделан.
func _test_timing() -> void:
	print("— урок посреди боя: по ситуации сейчас")
	# «Сбор»: волна 2, все в строю — урока нет
	var tut := await _start("gatehouse")
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._next()
	var c := _line_near()
	for u in w.units:
		if u.alive and u.state != Legionnaire.State.POSTED and u.state != Legionnaire.State.MARCH:
			u.take_damage(u.hp + 9999.0, u.position)
	w.wave_runner.index = 1   # идёт волна 2 (повод урока «Сбор»)
	var shown := false
	for i in int(3.0 * FPS):
		w._step(1.0 / FPS)
		shown = shown or tut.step_id() == &"rally"
	_check(not shown and w.wave_runner.wave_no() >= 2,
		"«Сбор»: волна 2, свободных нет — урок не показан (%s, свободных %d)" % [tut.step_id(), _idle()])
	# линию сняли — бойцы стоят без дела кучкой: урок встаёт
	w.contracts.dismiss(c)
	var up := _step_until(func() -> bool: return tut.step_id() == &"rally", 4.0)
	_check(up, "«Сбор»: бойцы без дела кучкой — урок встал (свободных %d)" % _idle())
	# их забрал новый договор (длинный — мест на всех) — урок гаснет, не зачтён
	var mid := w.cauldron_pos + Vector2(120.0, 0.0)
	var pts := PackedVector2Array([mid + Vector2(0, -170), mid + Vector2(0, 170)])
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	w.contracts.add_contract(pts, w.contracts.default_side(pts), false).ttl = 999.0
	var gone := _step_until(func() -> bool: return tut.step() < 0, LessonsCfg.WITHDRAW_T + 4.0)
	_check(gone and not tut.passed(&"rally"),
		"«Сбор»: бойцы снова в строю — урок погас, не зачтён (свободных %d)" % _idle())
	_check(not w.intuit.lesson_on(), "урок погас — советы подсказок снова работают")

	# «пружина»: показ — при прогибе, прогиб ушёл — гаснет, новый прогиб — снова
	tut = await _start("gatehouse")
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._passed[&"rally"] = true
	tut._next()
	c = _line_on("gatehouse", 2)
	_step_until(func() -> bool: return tut.step_id() == &"spring", 0.5, func() -> void: _bend(c, 0))
	_check(tut.step_id() == &"spring", "«пружина»: участок прогнут — урок на плашке")
	_check(w.intuit.lesson_on(), "урок на плашке — советы подсказок молчат")
	var flat := func() -> void:
		for s in c.seg_count():
			c.seg_bend[s] = 0.0
	gone = _step_until(func() -> bool: return tut.step() < 0, LessonsCfg.WITHDRAW_T + 1.0, flat)
	_check(gone and not tut.passed(&"spring"), "«пружина»: прогиб ушёл — урок погас, не зачтён")
	_check(not tut.banner_rect().has_area(), "«пружина»: плашка спрятана")
	# прогиб вернулся сразу — урок не мигает: встаёт не раньше LessonsCfg.REAPPEAR_T (проверяющий
	# 27.09: порог раз в 1,55 с гасил плашку на 2 кадра)
	_step_until(func() -> bool: return tut.step_id() == &"spring", LessonsCfg.REAPPEAR_T * 0.5,
		func() -> void: _bend(c, 0))
	_check(tut.step() < 0, "«пружина»: прогиб вернулся сразу — урок не мигает (ждёт %.1f с)"
		% LessonsCfg.REAPPEAR_T)
	_step_until(func() -> bool: return tut.step_id() == &"spring", LessonsCfg.REAPPEAR_T + 0.5,
		func() -> void: _bend(c, 0))
	_check(tut.step_id() == &"spring", "«пружина»: новый прогиб — урок снова на плашке")
	# урок спрятан, игрок сорвал прогнутый участок ПКМ — засчитан: урок он видел и сделал
	gone = _step_until(func() -> bool: return tut.step() < 0, LessonsCfg.WITHDRAW_T + 1.0, flat)
	_bend(c, 0)
	w.release_segment(c, 0, &"manual")
	_check(gone and tut.passed(&"spring"), "«пружина»: сорвал прогнутый, пока урок спрятан — засчитан")

	# Е: откат снят один раз за бой; пока Е в откате, урок «Е по продавленной» не встаёт
	tut = await _start("fork")
	tut._passed[&"ring"] = true
	tut._passed[&"hero_w"] = true
	tut._next()
	c = _line_on("fork", 2)
	w.hero._cd[LegionHero.SLOT_E] = 30.0
	_step_until(func() -> bool: return tut.step_id() == &"hero_e", 0.5, func() -> void: _bend(c, 0))
	_check(tut.step_id() == &"hero_e" and w.hero.cd_left(LegionHero.SLOT_E) <= 0.0,
		"Е: прогиб — урок встал, откат Е снят")
	# прогиб ушёл, Е нажата по спокойной линии (не зачтено) — урок гаснет
	var flat_e := func() -> void:
		for s in c.seg_count():
			c.seg_bend[s] = 0.0
	flat_e.call()
	w.hero.cast(LegionHero.SLOT_E, c.seg_center(0))
	gone = _step_until(func() -> bool: return tut.step() < 0, LessonsCfg.WITHDRAW_T + 1.0, flat_e)
	_check(gone and not tut.passed(&"hero_e"), "Е по спокойной линии: не зачтено, урок погас")
	# линию снова давят, но Е в откате — урок не встаёт, откат второй раз не снят
	shown = false
	for i in int(2.0 * FPS):
		_bend(c, 0)
		w._step(1.0 / FPS)
		shown = shown or tut.step_id() == &"hero_e"
	_check(not shown and not tut.spring_target().is_empty(),
		"Е в откате: линию давят, а урок «Е» не встаёт — жать нечем")
	_check(w.hero.cd_left(LegionHero.SLOT_E) > 1.0, "Е: второго бесплатного отката нет (%.1f с)"
		% w.hero.cd_left(LegionHero.SLOT_E))

	# постройка уже стоит — урок про неё не встаёт и засчитан
	tut = await _start("gatehouse")
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._next()
	w.souls = 999
	w.staff.build(w.staff.plots[0], LegionCfg.KIND_GUARD)
	w.spawn_foe("shield_inspector", "gate", {})
	w._step(1.0 / FPS)
	w._step(1.0 / FPS)
	_check(tut.step_id() != &"guard" and tut.passed(&"guard"),
		"Проходная уже построена — урок вахтёров не встал, засчитан (%s)" % tut.step_id())


func _idle() -> int:
	var n := 0
	for u in w.units:
		if u.alive and u.state == Legionnaire.State.FREE:
			n += 1
	return n


# ── 4. Игрок: настоящие события ввода ────────────────────────────────────────

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
	var bit := {MOUSE_BUTTON_LEFT: MOUSE_BUTTON_MASK_LEFT, MOUSE_BUTTON_RIGHT: MOUSE_BUTTON_MASK_RIGHT,
		MOUSE_BUTTON_MIDDLE: MOUSE_BUTTON_MASK_MIDDLE}
	ev.button_mask = int(bit.get(button, 0)) if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(1)


func _tap_key(code: Key, at: Vector2) -> void:
	await _move(at)
	await _key(code, true)
	await _frames(1)
	await _key(code, false)
	await _frames(2)


## Штрих ЛКМ по точкам, как рукой.
func _stroke(pts: PackedVector2Array) -> void:
	await _move(pts[0])
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for i in range(1, pts.size()):
		await _move(pts[i], MOUSE_BUTTON_MASK_LEFT)
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	await _frames(2)


## Клик ЛКМ по площадке и кнопка постройки в её меню.
func _build(plot: Dictionary, name: String) -> bool:
	var at: Vector2 = plot["pos"]
	await _move(at)
	await _button(at, MOUSE_BUTTON_LEFT, true)
	await _button(at, MOUSE_BUTTON_LEFT, false)
	await _frames(2)
	if not w.plot_menu.is_open():
		return false
	for b in w.plot_menu.buttons():
		if b.text.begins_with(name) and not b.disabled:
			b.pressed.emit()
			await _frames(2)
			return true
	return false


## Рогатка ПКМ: захват участка, оттяжка прочь от врага, отпускание, когда зона золотая.
func _sling_at(c: Contract, seg: int, foe: Foe, wait_gold := true) -> bool:
	Settings.scheme_override = Settings.SCHEME_SLING
	var at := c.seg_center(seg)
	var pull := at - (foe.position - at).normalized() * LegionCfg.SLING_ARM * 1.6
	await _move(at)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _move(at.lerp(pull, 0.5), MOUSE_BUTTON_MASK_RIGHT)
	await _move(pull, MOUSE_BUTTON_MASK_RIGHT)
	var gold := false
	for k in int(6.0 * FPS):
		var aim := w.contracts.sling_aim()
		gold = not aim.is_empty() and bool(aim["perfect"])
		if gold or not wait_gold:
			break
		await _move(pull, MOUSE_BUTTON_MASK_RIGHT)
	await _button(pull, MOUSE_BUTTON_RIGHT, false)
	Settings.scheme_override = ""
	await _frames(2)
	return gold


func _passed_after(tut: LegionTutorial, id: StringName, seconds: float) -> bool:
	return await _wait_until(func() -> bool: return tut.passed(id), seconds)


# ── 4а. Урок Таба (Игорь 02.10.2026: «в кампанию… добавить, что таб стирает линию сразу целиком») ──

func _tab_at(at: Vector2) -> void:
	await _move(at)
	await _key(KEY_TAB, true)
	await _key(KEY_TAB, false)
	await _frames(2)


func _test_tab_lesson() -> void:
	print("— урок Таба: «Проходная», вторым уроком начала боя")
	var tut := await _start("gatehouse")
	var ids: Array = tut.lessons.map(func(l: Dictionary) -> StringName: return l["id"])
	_check(ids.find(&"erase") == ids.find(&"aim") + 1,
		"урок Таба идёт сразу за стрелкой: %s" % str(ids))
	_check(tut.step_id() == &"aim", "на старте — по-прежнему стрелка, не Таб")
	tut._passed[&"aim"] = true
	tut._next()
	_check(tut.step_id() == &"erase" and tut.holding() and w.wave_runner.held,
		"после стрелки встал урок Таба и держит волну (%s)" % tut.step_id())
	_check(tut._counter(tut.step()) == "2/2", "плашка со счётчиком 2/2 (%s)" % tut._counter(tut.step()))
	var text := tut.step_text(tut.step())
	_check(text.contains("Таб") and text.contains("целиком") and text.contains("разрезанной"),
		"текст: Таб, «целиком» и оговорка про разрезанную линию")
	# линию положил урок (по метке стрелки); ждём, пока встанет строй
	var c := tut.line_target()
	_check(c != null, "урок Таба выложил линию")
	if c == null:
		return
	c.ttl = 999.0
	_step_until(func() -> bool: return _manned(c) >= 3, 12.0)
	_check(_manned(c) >= 3, "на линии стоит строй (%d)" % _manned(c))
	# Таб над пустым местом — урок не засчитан, линия цела
	await _tab_at(c.seg_center(0) + Vector2(260.0, 0.0))
	_check(not tut.passed(&"erase") and tut.step_id() == &"erase" and c.alive(),
		"Таб над пустым местом урок не засчитывает")
	# срыв ПКМ — не то действие: урок учит Табу
	var spare := _line_near()
	var rseg := 0
	for sg in spare.seg_count():
		if spare.seg_alive(sg) and spare.seg_manned(sg) > 0:
			rseg = sg
			break
	w.contracts.release(spare, rseg)
	w._step(1.0 / FPS)
	_check(not tut.passed(&"erase") and tut.step_id() == &"erase", "щелчок ПКМ урок Таба не засчитывает")
	# настоящий Таб над линией с бойцами
	var seg := tut.release_target()
	_check(not seg.is_empty(), "метка урока показывает участок со строем")
	if seg.is_empty():
		return
	var tc: Contract = seg["contract"]
	var at := tc.seg_center(int(seg["seg"]))
	var charges := int(w.stats.get("charges", 0))
	await _tab_at(at)
	_check(tut.passed(&"erase") and Campaign.hint_seen(LegionTutorial.flag("gatehouse", &"erase")),
		"Таб над линией с бойцами засчитал урок, флаг в сохранении")
	_check(int(w.stats.get("charges", 0)) > charges, "бойцы стёртого куска ушли в натиск")
	_check(tut.step_id() != &"erase", "после Таба плашка уходит дальше (%s)" % tut.step_id())
	# Таб, после которого в натиск не ушёл никто (строй не встал), урок не засчитывает
	tut = await _start("gatehouse")
	tut._passed[&"aim"] = true
	tut._next()
	var lone := tut.line_target()
	if lone != null:
		w.tab_erased.emit(lone, 1, 0)
		_check(not tut.passed(&"erase") and tut.step_id() == &"erase",
			"Таб без единого бойца в натиске урок не засчитывает")
		w.tab_erased.emit(lone, 1, 2)
		w._step(1.0 / FPS)
		_check(tut.passed(&"erase"), "Таб с бойцами в натиске засчитывает (сигнал мира)")


func _test_input() -> void:
	print("— игрок: настоящие события ввода")
	# Проходная: стрелка — Пробел и мышь вбок по линии, выложенной уроком
	var tut := await _start("gatehouse")
	tut.force_lesson(&"aim")
	await _frames(2)
	var c := tut.line_target()
	_check(c != null, "Проходная/стрелка: урок выложил линию по метке")
	if c != null:
		var mid := c.point_at(c.length * 0.5)
		var d0 := c.dir
		await _move(mid)
		await _key(KEY_SPACE, true)
		for i in range(1, 9):
			await _move(mid + d0.rotated(deg_to_rad(10.0 * i)) * 80.0)
		await _key(KEY_SPACE, false)
		_check(await _passed_after(tut, &"aim", 1.0), "Проходная/стрелка: Пробел + мышь вбок")
	# вахтёры: площадка → «Проходная»
	tut.force_lesson(&"guard")
	await _frames(2)
	# души урока — на одну постройку, не каждый кадр (проверяющий 27.09: строй-продавай)
	var price := LegionStaff.build_price(LegionCfg.KIND_GUARD)
	_check(w.souls >= price, "Проходная/вахтёры: души на постройку есть (%d)" % w.souls)
	w.souls = 0
	await _frames(3)
	_check(w.souls == price, "Проходная/вахтёры: потратил — урок долил на одну постройку (%d)"
		% w.souls)
	w.souls = 0
	await _frames(3)
	_check(w.souls == 0, "Проходная/вахтёры: второй раз урок души не доливает (%d)" % w.souls)
	w.souls = price
	_check(await _build(tut.target_plot(), "Проходная") and await _passed_after(tut, &"guard", 1.0),
		"Проходная/вахтёры: клик по площадке и кнопка «Проходная»")
	# пружина: участок прогнут — щелчок ПКМ по нему
	c = _line_on("gatehouse", 2)
	tut.force_lesson(&"spring")
	_bend_all()
	# таяние прогнутого участка — не срыв ПКМ: урок «пружина» не зачтён (проверяющий 27.09)
	w.release_segment(c, c.seg_count() - 1, &"melt")
	await _frames(1)
	_check(not tut.passed(&"spring"), "Проходная/пружина: таяние прогнутого участка не зачтено")
	_bend_all()
	await _frames(1)
	var hit := tut.spring_target()
	var at := c.seg_center(0)
	if not hit.is_empty():
		at = (hit["contract"] as Contract).seg_center(int(hit["seg"]))
	await _move(at)
	_bend_all()
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	_bend_all()
	await _button(at, MOUSE_BUTTON_RIGHT, false)
	_check(await _passed_after(tut, &"spring", 1.0), "Проходная/пружина: щелчок ПКМ по прогнутому участку")
	# «Сбор»: Эр у свободных бойцов
	tut.force_lesson(&"rally")
	await _frames(2)
	var rt := tut.rally_target()
	await _tap_key(KEY_R, rt if rt != Vector2.INF else Vector2(300, 380))
	_check(await _passed_after(tut, &"rally", 1.0), "Проходная/«Сбор»: Эр у свободных")

	# Развилка: кольцо штрихом, Дубль-вэ у трупа, Е по продавленной линии
	tut = await _start("fork")
	tut.force_lesson(&"ring")
	await _frames(2)
	await _stroke(tut.figure_points())
	_check(await _passed_after(tut, &"ring", 1.0), "Развилка/кольцо: штрих ЛКМ по шаблону")
	c = _line_on("fork", 2)
	tut.force_lesson(&"hero_w")
	var victim := _foe_before("zombie", c, 0, 80.0)
	victim.take_damage(victim.hp + 999.0, victim.position)
	await _frames(2)
	var corpse := tut.target_corpse()
	if corpse != null:
		await _tap_key(KEY_W, corpse.position)
	_check(await _passed_after(tut, &"hero_w", 1.0), "Развилка/Дубль-вэ: клавиша W у трупа")
	tut.force_lesson(&"hero_e")
	for s in c.seg_count():
		c.seg_bend[s] = 0.0
	await _frames(1)
	_toasts.clear()
	w.hero._cd[LegionHero.SLOT_E] = 0.0
	await _tap_key(KEY_E, c.seg_center(0))
	_check(not tut.passed(&"hero_e") and _toasts.has(LegionTutorial.HINT_NOT_PRESSED),
		"Развилка/Е: по спокойной линии не зачтено, подсказка тостом")
	# Отдельная положительная проба зачёта: предыдущий действительный Е потратил ману.
	# Как и откат, ресурс восстанавливаем в оснастке, а не дарим его уроком в бою.
	w.contracts.mana = w.contracts.mana_max
	w.hero._cd[LegionHero.SLOT_E] = 0.0
	_bend(c, 0)
	await _move(c.seg_center(0))
	_bend(c, 0)
	await _key(KEY_E, true)
	_bend(c, 0)
	await _key(KEY_E, false)
	_check(await _passed_after(tut, &"hero_e", 1.0), "Развилка/Е: клавиша E у продавленной линии")

	# Архив: восьмёрка, Бухгалтерия, предмет с элитного
	tut = await _start("archive")
	tut.force_lesson(&"eight")
	await _frames(2)
	await _stroke(tut.figure_points())
	_check(await _passed_after(tut, &"eight", 1.0), "Архив/восьмёрка: штрих ЛКМ по шаблону")
	w.spawn_foe("ghost", "north", {})
	tut.force_lesson(&"clerk")
	await _frames(2)
	_check(await _build(tut.target_plot(), "Бухгалтерия") and await _passed_after(tut, &"clerk", 1.0),
		"Архив/счетовод: клик по площадке и кнопка «Бухгалтерия»")
	var elite := w.spawn_foe("zombie", "north", {})
	elite.make_elite()
	tut.force_lesson(&"item")
	await _frames(2)
	elite.take_damage(elite.hp + 999.0, elite.position)
	_check(await _passed_after(tut, &"item", 1.0) and not w.items.counts.is_empty(),
		"Архив/предмет: элитный убит — предмет выпал (гарантия урока), урок зачтён")

	# Мост: «Точно!» по нотариусу, Ку по Юристу, срыв по оглушённому
	tut = await _start("bridge")
	c = _line_near()
	# золото и «Точно!» — только у участка со стоящими (D-0926-48, slow/intuit): берём
	# участок, где люди есть, — кто на какой встал, зависит от случая
	var pseg := 0
	for s in c.seg_count():
		if c.seg_manned(s) > c.seg_manned(pseg):
			pseg = s
	var signer := _foe_before("signer", c, pseg, 150.0)
	tut.force_lesson(&"perfect")
	await _frames(1)
	var men := c.seg_manned(pseg)
	var gold := await _sling_at(c, pseg, signer)
	_check(gold, "Мост/«Точно!»: рогатка ПКМ дотянута до золота (участок %d, стоит %d, нотариус %s)"
		% [pseg, men, str(signer.position) if is_instance_valid(signer) else "—"])
	_check(await _passed_after(tut, &"perfect", 1.0),
		"Мост/«Точно!»: отпущена в золото по нотариусу — урок зачтён")
	var lawyer := _foe_before("lawyer", c, 0, 200.0)
	w._step(1.0 / FPS)
	tut.force_lesson(&"lawyer_q")
	await _frames(1)
	await _tap_key(KEY_Q, lawyer.position)
	_check(await _passed_after(tut, &"lawyer_q", 1.0 + CfgFx.BOLT_HITSTOP), "Мост/Юрист: клавиша Q по Юристу")
	# срыв по оглушённым — в свежем бою: прошлый Юрист успел расторгнуть строй
	tut = await _start("bridge")
	c = _line_near()
	# Юрист крепок: Ку его не убивает, а оглушает — есть кого сорвать
	var seg := 0
	for s in c.seg_count():
		if c.seg_manned(s) > c.seg_manned(seg):
			seg = s
	var stun_target := _foe_before("lawyer", c, seg, 45.0)
	tut.force_lesson(&"stun_hit")
	w.hero._cd[LegionHero.SLOT_Q] = 0.0
	await _tap_key(KEY_Q, stun_target.position)
	await _sling_at(c, seg, stun_target, false)
	_check(await _passed_after(tut, &"stun_hit", 2.0), "Мост/оглушённые: Ку, затем рогатка ПКМ в оглушённого")

	# Мост: треугольник на свободном берегу; Болото: квадрат
	tut = await _start("bridge")
	await _frames(2)
	await _stroke(tut.figure_points())
	_check(await _passed_after(tut, &"triangle", 1.0), "Мост/треугольник: штрих ЛКМ по шаблону")
	tut = await _start("swamp")
	await _frames(2)
	await _stroke(tut.figure_points())
	_check(await _passed_after(tut, &"square", 1.0), "Болото/квадрат: штрих ЛКМ по шаблону")


# ── 5. Не повторяется; hold ──────────────────────────────────────────────────

func _test_once_and_hold() -> void:
	print("— урок не повторяется; hold")
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern"}
	w.start_map("gatehouse")
	w.start_lessons()
	var tut := w.tutorial
	_check(tut != null and tut.step_id() == &"aim", "Проходная: первый вход — урок стрелки")
	w.cauldron_hp = 1.0
	w._step(1.0 / FPS)
	_check(is_equal_approx(w.cauldron_hp, w.cauldron_max) and w.wave_runner.held,
		"hold: Котёл не проседает, волна ждёт")
	_step_until(func() -> bool: return not w.wave_runner.held, 40.0)
	_check(not w.wave_runner.held and w.now <= 26.0 and tut.step_id() == &"aim",
		"hold: волна ждёт не дольше 25 с, урок остался на плашке (%.1f с)" % w.now)
	w.cauldron_hp = 1.0
	w._step(1.0 / FPS)
	_check(w.cauldron_hp < 2.0, "после hold Котёл больше не защищён")
	LegionLessonBot.act(tut)
	_step_until(func() -> bool: return tut.passed(&"aim"), 2.0)
	w.start_map("gatehouse")
	w.start_lessons()
	_check(w.tutorial != null and w.tutorial.index_of(&"aim") < 0,
		"второй вход: пройденного урока стрелки нет (%s)" % (
			str(w.tutorial.lessons.map(func(l: Dictionary) -> StringName: return l["id"]))
			if w.tutorial != null else "уроков нет"))
	# вне кампании уроки не идут
	w.in_campaign = false
	Campaign.reset()
	w.start_map("gatehouse")
	await _frames(2)
	_check(w.tutorial == null, "мир без кампании сам уроков не заводит (их зовёт только LegionMain)")


# ── 6. Бой бота вне кампании побайтно прежний ────────────────────────────────

func _bot_digest(map_id: String, seed: int, steps: int) -> String:
	Settings.scheme_override = ""
	w.in_campaign = false
	w.dev = {"difficulty": "intern"}
	w.dev_invuln = false
	w.args["bot"] = "selective"
	w._base_seed = seed
	w.start_map(map_id)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for i in steps:
		w._step(1.0 / 60.0)
		if i % 30 != 0:
			continue
		var line := "%d|%.4f|%.4f|%d|" % [i, w.cauldron_hp, w.contracts.mana, w.souls]
		for u in w.units:
			line += "%.3f,%.3f,%.3f,%d;" % [u.position.x, u.position.y, u.hp, u.state]
		for f in w.foes:
			line += "%s:%.3f,%.3f,%.3f;" % [f.type_id, f.position.x, f.position.y, f.hp]
		for c in w.contracts.contracts:
			line += "c%d:%.2f:%s;" % [c.id, c.length, str(c.seg_age)]
		var keys := w.stats.keys()
		keys.sort()
		for k in keys:
			line += "%s=%s," % [k, str(w.stats[k])]
		ctx.update(line.to_utf8_buffer())
	w.args.erase("bot")
	return ctx.finish().hex_encode()


func _test_bot_same() -> void:
	print("— бот вне кампании: бой побайтно прежний")
	var ref: Dictionary = {}
	var f := FileAccess.open(BOT_REF, FileAccess.READ)
	if f != null:
		for line in f.get_as_text().split("\n", false):
			var parts := line.strip_edges().split(" ")
			if parts.size() == 4:
				ref["%s %s %s" % [parts[0], parts[1], parts[2]]] = parts[3]
	for run: Array in BOT_RUNS:
		var d := _bot_digest(run[0], run[1], run[2])
		var key := "%s %d %d" % [run[0], run[1], run[2]]
		print("  BOTREF %s %s" % [key, d])
		_check(ref.get(key, "") == d, "бот %s: трасса совпала с эталоном economy-mana" % key)


# ── 7. Правки проверяющего 27.09: без подарков вне удержания, конец боя, пройденные карты ──

func _test_no_gifts() -> void:
	print("— вне удержания уроки ничего не дарят; конец боя; пройденная карта")
	# 1. «Проходная»: урок стрелки не сделан, удержание истекло — мана и таяние как в бою
	var tut := await _start("gatehouse", "", true)
	w.dev_invuln = true
	_step_until(func() -> bool: return not w.wave_runner.held, 40.0)
	w.dev_invuln = false
	_check(tut.step_id() == &"aim" and not tut.holding(), "Проходная: удержание истекло, урок висит")
	var c: Contract = w.contracts.contracts[0] if not w.contracts.contracts.is_empty() else null
	w.contracts.mana = 10.0
	if c != null:
		c.seg_age[0] = c.ttl * 0.9
	w._step(1.0 / FPS)
	_check(w.contracts.mana < 20.0, "урок стрелки без удержания: мана не восполнена (%.1f)" %
		w.contracts.mana)
	_check(c != null and c.seg_age[0] >= c.ttl * 0.9,
		"урок стрелки без удержания: линия стареет (%.2f)" % (c.seg_age[0] / c.ttl if c != null else -1.0))
	# «Развилка»: урок кольца без удержания — мана не восполняется
	tut = await _start("fork", "", true)
	_step_until(func() -> bool: return not w.wave_runner.held, 40.0)
	w.contracts.mana = 10.0
	w._step(1.0 / FPS)
	_check(tut.step_id() == &"ring" and w.contracts.mana < 20.0,
		"урок кольца без удержания: мана не восполнена (%.1f)" % w.contracts.mana)
	# «Сбор» посреди боя: всех бойцов не стало — бесплатных подрядчиков нет
	tut = await _start("gatehouse")
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut.force_lesson(&"rally")
	for u in w.units:
		if u.alive:
			u.take_damage(u.hp + 9999.0, u.position)
	for i in 3:
		w._step(1.0 / FPS)
	_check(w.army_alive() == 0, "урок «Сбор» посреди боя не выпускает бесплатных бойцов (%d)" %
		w.army_alive())

	# 2. откат снят один раз, а не каждый кадр
	tut = await _start("fork")
	tut.force_lesson(&"hero_e")
	w._step(1.0 / FPS)
	var mine := w.units[0].position
	w.hero.cast(LegionHero.SLOT_E, mine)
	w._step(1.0 / FPS)
	w._step(1.0 / FPS)
	_check(w.hero.cd_left(LegionHero.SLOT_E) > 1.0,
		"урок Е посреди боя: после каста откат идёт (%.1f с)" % w.hero.cd_left(LegionHero.SLOT_E))
	tut = await _start("bridge")
	c = _line_near()
	var foe := _foe_before("zombie", c, 0, 200.0)
	tut.force_lesson(&"stun_hit")
	_check(w.hero.cd_left(LegionHero.SLOT_Q) <= 0.0, "урок «по оглушённым»: при входе откат Ку снят")
	w.hero.cast(LegionHero.SLOT_Q, foe.position)
	w._step(1.0 / FPS)
	w._step(1.0 / FPS)
	_check(w.hero.cd_left(LegionHero.SLOT_Q) > 1.0,
		"урок «по оглушённым»: после каста откат Ку идёт (%.1f с)" % w.hero.cd_left(LegionHero.SLOT_Q))

	# 3. карта уже выиграна — её уроки не идут
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.record_result("fork", true, 0.9)
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.args.erase("bot")
	w.start_map("fork")
	w.start_lessons()
	_check(w.tutorial == null, "выигранная «Развилка»: уроков нет")
	w.start_map("archive")
	w.start_lessons()
	_check(w.tutorial != null, "невыигранный «Архив»: уроки идут")

	# 4. конец боя снимает урок: плашка, метки, голос
	tut = await _start("fork")
	_check(tut != null and _lesson_nodes() > 0, "бой с уроком: плашка и метки на месте")
	w.force_end(true)
	await _frames(2)
	_check(w.tutorial == null and _lesson_nodes() == 0,
		"итог боя: урок снят, плашки и меток нет (узлов %d)" % _lesson_nodes())


func _lesson_nodes() -> int:
	var n := 0
	for ch in w.get_children():
		if (ch is LegionLessonBanner or ch is LegionTutorialMarks) and not ch.is_queued_for_deletion():
			n += 1
	return n
