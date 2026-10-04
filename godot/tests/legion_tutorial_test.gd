extends SceneTree
##
## Самопроверка обучения на wasteland — уроков карты 1 (docs/legion/TUTORIAL_SPEC.md). С v20
## (D-0926-46, Игорь 26.09: «постепенно вводились и обучались») это шесть уроков основы: линия,
## подновление, рогатка, «Точно!», Бытовка, Ку; стрелка, «Сбор», фигуры, Дубль-вэ и Е — уроки
## следующих карт (tests/legion_lessons_test.gd).
##
## Часть 0 — открытия: на свежем прогрессе открыта Ку, Дубль-вэ и Е — нет (открывает «Развилка»);
## порядок уроков и озвучка lg_tut_1..4 на тех же уроках, новые — без голоса.
## Часть 1 — материал (через force_step): мана; линия не тает на уроке подновления; учебные
## зомби (восполнение без предела); души Бытовки; откат Ку обнулён; Котёл не проседает; плашка —
## одна строка без «Шаг N/..» и кнопок, тосты HUD на каждом уроке ниже плашки, в HUD «обучение».
## Часть 2 — сквозной прогон ботом selective с самого начала: бот проходит все шаги теми же
## действиями через API мира, обучение отпускает волны, матч доигрывается, флаг tutorial/done
## стоит и не даёт обучению стартовать снова через LegionMain.
## Часть 3 — путь игрока НАСТОЯЩИМИ событиями ввода (Input.parse_input_event, bot=off, без
## force_step): штрих ЛКМ по призраку; штрих ЛКМ вдоль своей линии — подновление; ПКМ по
## участку со строем; рогатка ПКМ в золото — «Точно!»; площадка и «Бытовка»; Q мимо — не зачёт,
## Q у зомби — финал, плашка «пройдено» и уход.
## Часть 4 — «никаких тупиков» и регрессии: линия растаяла сама на шаге натиска — зачёт; все
## договоры ушли без натиска — откат к линии, а после новой линии — сразу к непройденному
## уроку; меню площадки не пересобирается от смены душ; выход в меню / restart / R вне боя.
##
## Сохранение — во временный файл (Campaign.set_save_path), реальный user://legion.cfg
## владельца не трогает.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_tutorial_test.gd -- --mute
##
## Итог «LEGION TUTORIAL: N/N OK»; код выхода 1, если что-то упало.
##

const TEST_PATH := "user://legion_tutorial_test_run.cfg"
const MAX_MATCH_FRAMES := 60000   ## страховка от зависания: на TD-картах v15 со штатом матч длинный
const FPS := 60
const LONG_TOAST := "Очень длинная строка тоста, чтобы проверить, что она не залезает на плашку"
## Порядок уроков «Пустыря», который обещан владельцу (TUTORIAL_SPEC.md, CAMPAIGN_V20.md).
const ORDER: Array[StringName] = [&"draw", &"refresh", &"release", &"perfect", &"build", &"hero_q"]
## Озвучка v16 остаётся при своих шагах; новые шаги — только текст.
const VOICES := {&"draw": &"lg_tut_1", &"release": &"lg_tut_2", &"perfect": &"lg_tut_perfect_w",
	&"build": &"lg_tut_3", &"hero_q": &"lg_tut_4"}
const DRAG_STEPS := 16
const STEP_WAIT := 10.0

var world: LegionWorld
var _checks := 0
var _fails := 0
## Члены скрипта, а не захваченные локальные переменные: сигналы обучения слушаем методами,
## не лямбдами — на связке двух миров подряд лямбда-замыкание по локальной переменной однажды
## поймало "Lambda capture ... was freed" (движок), методы этой беды не знают.
var _max_step := -1
var _tutorial_finished := false
var _toasts: Array[String] = []
var _seen_ids: Dictionary = {}


func _on_test_step_changed(i: int) -> void:
	_max_step = maxi(_max_step, i)
	_seen_ids[_lessons()[i]["id"]] = true


func _on_test_tutorial_finished() -> void:
	_tutorial_finished = true


func _on_toast(text: String, _kind: StringName) -> void:
	_toasts.append(text)


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


func _seconds(s: float) -> void:
	await _frames(int(s * FPS))


## Уроки «Пустыря» из JSON карты (поле lessons) — в том порядке, в каком их ведёт движок.
func _lessons() -> Array[Dictionary]:
	return LegionTutorial.parse(LegionWorld.load_map("wasteland"))


## Номер урока по id (-1 — такого нет).
func _idx(id: StringName) -> int:
	var list := _lessons()
	for i in list.size():
		if list[i]["id"] == id:
			return i
	return -1


func _new_world() -> LegionWorld:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var w := scene.instantiate() as LegionWorld
	w.embedded = true   # сами решаем, когда стартовать бой — компат-путь тут не нужен
	root.add_child(w)
	root.size = Vector2i(1280, 720)
	w.toast_posted.connect(_on_toast)
	return w


func _start(bot: String = "", campaign := false) -> LegionTutorial:
	Campaign.reset()
	world = _new_world()
	await _frames(2)
	if bot != "":
		world.args["bot"] = bot
	# в кампании мир берёт открытия из Campaign.stat (вне её всё открыто — LegionWorld.camp_stat)
	world.in_campaign = campaign
	world.start_map("wasteland")
	world.start_tutorial()
	await _frames(2)
	return world.tutorial


func _end_world() -> void:
	world.queue_free()
	await _frames(1)


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()

	await _unlock_checks()
	await _material_checks()
	await _full_run_checks()
	await _action_checks()
	await _dead_end_checks()
	await _draw_retry_checks()
	await _fix_regression_checks()

	print("LEGION TUTORIAL: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Часть 0: открытия, порядок шагов, озвучка ────────────────────────────────

func _unlock_checks() -> void:
	Campaign.reset()
	_check(is_equal_approx(Campaign.stat(&"ability_unlocked_q"), 1.0)
			and Campaign.stat(&"ability_unlocked_w") < 0.5 and Campaign.stat(&"ability_unlocked_e") < 0.5,
		"открытия: на свежем прогрессе Ку открыта, Дубль-вэ и Е — нет (их учит «Развилка»)")
	var tut := await _start("", true)
	_check(world.hero != null and world.hero.is_unlocked(LegionHero.SLOT_Q)
			and not world.hero.is_unlocked(LegionHero.SLOT_W)
			and not world.hero.is_unlocked(LegionHero.SLOT_E),
		"открытия: в бою первой карты кампании Ку есть, Дубль-вэ и Е молчат")
	_check(tut != null, "открытия: обучение стартовало в кампании")
	await _end_world()

	var ids: Array[StringName] = []
	for s in _lessons():
		ids.append(s["id"])
	_check(ids == ORDER, "уроки: порядок %s" % str(ids))
	var voices_ok := true
	for s in _lessons():
		if StringName(s.get("voice", &"-")) != StringName(VOICES.get(s["id"], &"")):
			voices_ok = false
	_check(voices_ok, "озвучка: lg_tut_1..4 при договоре/натиске/Бытовке/Ку, «Точно!» — lg_tut_perfect_w, подновление без голоса")


# ── Часть 1: материал, плашка, тосты ─────────────────────────────────────────

func _material_checks() -> void:
	var tut := await _start("")
	_check(tut != null and tut.active, "обучение запущено")
	if tut == null:
		return
	_check(tut.lessons.size() == ORDER.size(),
		"уроков ровно %d (%d)" % [ORDER.size(), tut.lessons.size()])

	for i in tut.lessons.size():
		tut.force_step(i)
		world.toast(LONG_TOAST, &"warn")
		world.toast("Ещё одна строка", &"info")
		await _frames(3)
		var br := tut.banner_rect()
		_check(br.size.x > 0.0 and br.size.y > 0.0 and br.end.x <= 1280.0 and br.position.x >= 0.0,
			"шаг %d: плашка видна и в экране (%s)" % [i + 1, br])
		var rects := world.hud.toast_rects()
		var clash := false
		for r in rects:
			if r.intersects(br):
				clash = true
		_check(not rects.is_empty() and not clash,
			"шаг %d: %d тостов ниже плашки, наложений нет" % [i + 1, rects.size()])
		var text := _banner_text(tut._banner) if tut._banner != null else ""
		_check(text != "" and not text.contains("Шаг") and not text.contains("\n")
				and not text.contains("%"),
			"шаг %d: одна строка без «Шаг N/..» и без «%%»: «%s»" % [i + 1, text])
		_check(_banner_buttons(tut) == 0, "шаг %d: на плашке нет кнопок" % (i + 1))

	# HUD: вместо застывшего отсчёта до волны — «обучение»
	world.hud.tick(1.0)
	var stats_text: String = world.hud._stats.text
	_check(stats_text.contains("обучение") and not stats_text.contains("до волны"),
		"HUD во время обучения: «%s»" % stats_text)

	# шаг 1: мана восполняется, пока договор не проведён
	tut.force_step(0)
	world.contracts.mana = 0.0
	await _frames(2)
	_check(world.contracts.mana >= world.contracts.mana_max - 0.01,
		"шаг 1: мана восполнена до полной (%.1f)" % world.contracts.mana)

	# подновление: линия не тает, пока урок не зачтён, мана полная
	for id: StringName in [&"refresh"]:
		var k := _idx(id)
		if k < 0:
			_check(false, "%s: такого шага нет" % id)
			continue
		world.restart()
		await _frames(2)
		tut = world.tutorial
		tut.force_step(k)
		world.contracts.mana = 0.0
		await _seconds(LegionCfg.SEG_TTL + 2.0)
		_check(tut.step() == k and not world.contracts.contracts.is_empty()
				and world.contracts.contracts[0].alive(),
			"%s: за срок договора + 2 с линия не растаяла (шаг %d)" % [id, tut.step() + 1])
		_check(world.contracts.mana >= world.contracts.mana_max - 0.01,
			"%s: мана полная (%.1f)" % [id, world.contracts.mana])

	# натиск: учебные зомби выставлены и восполняются без предела довыпусков
	var rel := _idx(&"release")
	tut.force_step(rel)
	await _frames(2)
	_check(tut._foes.size() == LegionCfg.TUTORIAL_FOES, "натиск: учебные зомби выставлены (%d)" %
		tut._foes.size())
	for round_i in 5:
		_kill_all(tut._foes)
		await _frames(3)
	_check(tut._foes.size() == LegionCfg.TUTORIAL_FOES and tut.step() == rel,
		"натиск: после пяти истреблений подряд зомби снова есть (%d)" % tut._foes.size())
	world.cauldron_hp = 1.0
	await _frames(2)
	_check(is_equal_approx(world.cauldron_hp, world.cauldron_max),
		"урок: Котёл не проседает (%.0f/%.0f)" % [world.cauldron_hp, world.cauldron_max])

	# Бытовка: души восполняются до цены, площадка отмечена
	tut.force_step(_idx(&"build"))
	world.souls = 0
	await _frames(2)
	_check(world.souls >= LegionStaff.build_price(LegionCfg.KIND_LABORER),
		"Бытовка: души восполнены до цены (%d)" % world.souls)
	_check(String(tut.target_plot().get("id", "")) == LegionCfg.TUTORIAL_PLOT_ID,
		"Бытовка: отмечена площадка %s" % LegionCfg.TUTORIAL_PLOT_ID)

	# Ку: зомби под кольцом, откат обнулён
	tut.force_step(_idx(&"hero_q"))
	world.hero._cd[LegionHero.SLOT_Q] = 9.0
	await _frames(2)
	_check(tut.target_foe() != null, "Ку: есть зомби под кольцом")
	_check(world.hero.cd_left(LegionHero.SLOT_Q) <= 0.0, "Ку: откат обнулён, пока шаг не зачтён")

	await _end_world()


func _banner_buttons(tut: LegionTutorial) -> int:
	if tut._banner == null:
		return -1
	return tut._banner.find_children("*", "Button", true, false).size()


func _kill_all(foes: Array[Foe]) -> void:
	for f in foes.duplicate():
		if is_instance_valid(f) and f.alive:
			f.take_damage(f.hp + 9999.0, f.position)


func _free_units() -> int:
	var n := 0
	for u in world.units:
		if u.alive and u.state == Legionnaire.State.FREE:
			n += 1
	return n


## Свежий труп под Дубль-вэ — те же условия, что у LegionHero (свежий, не призванный, видимый).
func _fresh_corpse() -> Foe:
	var list: Array = []
	list.append_array(world.foes)
	list.append_array(world._corpses)
	for n in list:
		var f := n as Foe
		if f != null and is_instance_valid(f) and f.is_fresh_corpse() and f.visible \
				and not f.has_meta(&"summoned"):
			return f
	return null


## Свободный боец с наибольшим числом свободных соседей в полрадиуса «Сбора». INF — некого.
func _free_cluster() -> Vector2:
	var best := Vector2.INF
	var best_n := -1
	for u in world.units:
		if not u.alive or u.state != Legionnaire.State.FREE:
			continue
		var n := 0
		for v in world.units:
			if v.alive and v.state == Legionnaire.State.FREE \
					and u.position.distance_to(v.position) <= LegionCfg.RALLY_R * 0.5:
				n += 1
		if n > best_n:
			best_n = n
			best = u.position
	return best


# ── Часть 2: сквозной прогон ботом ───────────────────────────────────────────

func _full_run_checks() -> void:
	var tut := await _start("selective")
	_check(tut != null, "прогон: обучение стартовало на первой игре")
	if tut == null:
		return
	_max_step = maxi(-1, tut.step())
	_seen_ids.clear()
	# бот успевает пройти первые шаги за два кадра старта, до подписки на step_changed
	for k in tut.step() + 1:
		_seen_ids[tut.lessons[k]["id"]] = true
	_tutorial_finished = false
	tut.step_changed.connect(_on_test_step_changed)
	tut.finished.connect(_on_test_tutorial_finished)

	var frames := 0
	var tut_frames := -1
	while world.phase == LegionWorld.Phase.BATTLE and frames < MAX_MATCH_FRAMES:
		await process_frame
		frames += 1
		if tut_frames < 0 and _tutorial_finished:
			tut_frames = frames

	_check(frames < MAX_MATCH_FRAMES, "прогон: матч не завис (кадров %d)" % frames)
	var missing: Array[StringName] = []
	for id in ORDER:
		if not _seen_ids.has(id):
			missing.append(id)
	_check(missing.is_empty(), "прогон: бот прошёл через все шаги (не видели: %s)" % str(missing))
	_check(_tutorial_finished, "прогон: бот прошёл обучение за %.1f с" % (tut_frames / float(FPS)))
	_check(world.phase in [LegionWorld.Phase.VICTORY, LegionWorld.Phase.DEFEAT],
		"прогон: матч завершён после обучения (phase=%d)" % world.phase)
	_check(Campaign.tutorial_done(), "прогон: флаг tutorial/done выставлен")

	var scene: PackedScene = load("res://scenes/legion.tscn")
	var main := scene.instantiate() as LegionMain
	main.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(main)
	await _frames(2)
	main.start_battle("wasteland")
	await _frames(2)
	_check(main.world.tutorial == null,
		"прогон: повторный вход в wasteland не запускает обучение снова (флаг уже стоит)")
	main.queue_free()
	await _end_world()


# ── Часть 3: путь игрока настоящими событиями ввода ──────────────────────────

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
	Input.parse_input_event(ev)
	await _frames(1)


## Протяжка ЛКМ как рукой: нажать в a, вести по кадру на точку, отпустить в b.
func _drag(a: Vector2, b: Vector2) -> void:
	await _move(a)
	await _button(a, MOUSE_BUTTON_LEFT, true)
	for i in range(1, DRAG_STEPS + 1):
		await _move(a.lerp(b, float(i) / DRAG_STEPS), MOUSE_BUTTON_MASK_LEFT)
	await _button(b, MOUSE_BUTTON_LEFT, false)


func _key_state(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(1)


func _tap_key(code: Key) -> void:
	await _key_state(code, true)
	await _frames(1)
	await _key_state(code, false)


func _until_step(idx: int, limit: float) -> bool:
	var t := 0
	while world.tutorial != null and world.tutorial.step() < idx and t < int(limit * FPS):
		await process_frame
		t += 1
	return world.tutorial == null or world.tutorial.step() >= idx


func _action_checks() -> void:
	var tut := await _start("")
	_check(tut != null, "игрок: обучение стартовало (bot=off)")
	if tut == null:
		return

	# шаг «договор»: дальний договор (армии не дотянуться) не засчитан, подсказка — тостом
	_toasts.clear()
	var far := PackedVector2Array([Vector2(1150, 300), Vector2(1150, 440)])
	world.contracts.add_contract(far, 1)
	await _frames(2)
	_check(tut.step() == 0, "игрок: дальний договор шаг 1 не засчитал")
	_check(_toasts.has(LegionTutorial.HINT_FAR), "игрок: подсказка «Далеко от бойцов» тостом")
	var ghost := tut.ghost_points()
	# ЛКМ-штрих не точно по призраку — сдвиг на 12 px тоже засчитывается
	await _drag(ghost[0] + Vector2(6, 12), ghost[1] + Vector2(-4, 12))
	await _frames(2)
	var c: Contract = world.contracts.contracts[0] if not world.contracts.contracts.is_empty() else null
	_check(c != null and c.posts.size() >= LegionCfg.TUTORIAL_MIN_POSTS,
		"игрок: штрих ЛКМ у призрака даёт ≥ %d мест (%d)" % [LegionCfg.TUTORIAL_MIN_POSTS,
			c.posts.size() if c != null else -1])
	_check(tut.step() == 1, "игрок: договор у призрака засчитан (шаг %d)" % (tut.step() + 1))

	var aim_i := _idx(&"aim")
	_check(aim_i < 0, "игрок: урока «стрелка» на «Пустыре» больше нет (переехал на «Проходную»)")

	# шаг «подновление»: ЛКМ вдоль своей линии — продление, не новый договор
	var ref_i := _idx(&"refresh")
	var lines_before := world.contracts.contracts.size()
	if c != null and c.alive():
		await _drag(c.point_at(4.0), c.point_at(c.length - 4.0))
		await _frames(2)
	_check(world.contracts.contracts.size() == lines_before,
		"игрок: штрих вдоль своей линии не создал новый договор")
	_check(ref_i >= 0 and tut.step() == ref_i + 1,
		"игрок: штрих вдоль своей линии зачёл «подновление» (шаг %d)" % (tut.step() + 1))

	# шаг «натиск»: ждём строй, ПКМ по самому людному участку (щелчок ПКМ — настоящим событием)
	var rel_i := _idx(&"release")
	var t := 0
	while tut.release_target().is_empty() or _target_manned(tut) < 4:
		await process_frame
		t += 1
		if t > 10 * FPS:
			break
	_check(_target_manned(tut) >= 4, "игрок: строй встал на линии за %.1f с" % (t / float(FPS)))
	var hit := tut.release_target()
	if not hit.is_empty():
		var at := (hit["contract"] as Contract).seg_center(int(hit["seg"]))
		await _move(at)
		await _button(at, MOUSE_BUTTON_RIGHT, true)
		await _frames(2)
		await _button(at, MOUSE_BUTTON_RIGHT, false)
	await _frames(2)
	_check(tut.step() == rel_i + 1, "игрок: ПКМ по участку со строем зачла натиск (шаг %d)" %
		(tut.step() + 1))

	# урок «Точно!»: рогатка ПКМ в золото — враг в зоне удара, отпускание засчитано
	var perf_i := _idx(&"perfect")
	_check(perf_i >= 0 and tut.step() == perf_i, "игрок: после натиска — урок «Точно!» (урок %d)" %
		(tut.step() + 1))
	var shot := await _sling_perfect(tut)
	_check(shot, "игрок: рогатка ПКМ отпущена, когда зона удара золотая")
	await _frames(2)
	_check(tut.step() == perf_i + 1, "игрок: «Точно!» рогаткой зачтено (урок %d)" % (tut.step() + 1))

	# шаг «Бытовка»: клик мимо — подсказка без зачёта; клик по краю спрайта площадки — меню
	var build_i := _idx(&"build")
	_toasts.clear()
	world.contracts.tap.emit(Vector2(640, 640))
	await _frames(2)
	_check(tut.step() == build_i and not world.plot_menu.is_open(), "игрок: клик мимо площадки не зачтён")
	_check(_toasts.has(LegionTutorial.HINT_PLOT), "игрок: подсказка «Кликни по площадке с кольцом»")
	var plot: Dictionary = tut.target_plot()
	if not plot.is_empty():
		var edge: Vector2 = plot["pos"] + Vector2(32, -20)
		_check((edge - (plot["pos"] as Vector2)).length() > LegionCfg.PLOT_PICK_R,
			"игрок: точка края дальше старого радиуса выбора 28 px")
		world.contracts.tap.emit(edge)
		await _frames(2)
	_check(world.plot_menu.is_open(), "игрок: клик по краю спрайта площадки открыл меню")
	var built := false
	for b in world.plot_menu.buttons():
		if b.text.begins_with("Бытовка") and not b.disabled:
			b.pressed.emit()
			built = true
			break
	await _frames(2)
	_check(built and tut.step() == build_i + 1, "игрок: кнопка «Бытовка» построила (шаг %d)" %
		(tut.step() + 1))

	# шаг «Ку»: клавиша Q мимо врага не засчитана; у зомби — зачёт
	var q_i := _idx(&"hero_q")
	await _move(Vector2(1200, 650))
	await _tap_key(KEY_Q)
	await _frames(2)
	_check(tut.active and tut.step() == q_i, "игрок: Ку мимо врага не зачтена")
	var target := tut.target_foe()
	_check(target != null, "игрок: зомби под Ку на месте")
	if target != null:
		await _move(target.position)
		await _tap_key(KEY_Q)
		# попавшая Ку в полной графике даёт стоп-кадр мира (CfgFx.BOLT_HITSTOP реальных секунд):
		# зачёт идёт шагом мира, который наступает уже после стоп-кадра (slow/impact)
		await _frames(2 + ceili(CfgFx.BOLT_HITSTOP * FPS))
	_check(q_i == tut.lessons.size() - 1 or tut.step() == q_i + 1,
		"игрок: клавиша Q у зомби зачла Ку (шаг %d)" % (tut.step() + 1))

	_check(not tut.active and world.tutorial == null, "игрок: клавиша Q у зомби завершила обучение")
	_check(Campaign.tutorial_done(), "игрок: флаг tutorial/done выставлен")
	_check(not world.wave_runner.held, "игрок: волны отпущены")

	# финал: плашка «пройдено», затем строка про Пробел к первой волне — один раз за кампанию
	var banner := _find_banner()
	_check(banner != null and _banner_text(banner) == LegionTutorial.TEXT_DONE,
		"финал: плашка «Обучение пройдено»")
	_check(Campaign.hint_seen(LegionTutorial.flag("wasteland", &"hero_q")),
		"финал: урок Ку отмечен пройденным в сохранении")
	await _seconds(LegionCfg.TUTORIAL_DONE_TIME + 0.5)
	_check(_find_banner() == null, "финал: плашка убрала себя")
	await _end_world()


## Рогатка ПКМ по участку со строем: оттянуть от ближайшего врага и держать, пока зона удара
## не станет золотой (враг в ней), — отпустить. false — золота не дождались.
func _sling_perfect(tut: LegionTutorial) -> bool:
	Settings.scheme_override = Settings.SCHEME_SLING
	var t := 0
	while t < int(20.0 * FPS):
		var hit := tut.release_target()
		var foe := tut.target_foe()
		if not hit.is_empty() and foe != null and _target_manned(tut) > 0:
			var c: Contract = hit["contract"]
			var at := c.seg_center(int(hit["seg"]))
			var pull := at - (foe.position - at).normalized() * LegionCfg.SLING_ARM * 1.6
			await _move(at)
			await _button(at, MOUSE_BUTTON_RIGHT, true)
			await _move(at.lerp(pull, 0.5), MOUSE_BUTTON_MASK_RIGHT)
			await _move(pull, MOUSE_BUTTON_MASK_RIGHT)
			var k := 0
			while k < int(8.0 * FPS):
				var aim := world.contracts.sling_aim()
				if not aim.is_empty() and bool(aim["perfect"]):
					await _button(pull, MOUSE_BUTTON_RIGHT, false)
					Settings.scheme_override = ""
					return true
				foe = tut.target_foe()
				if foe != null:
					pull = at - (foe.position - at).normalized() * LegionCfg.SLING_ARM * 1.6
				await _move(pull, MOUSE_BUTTON_MASK_RIGHT)
				k += 1
			await _button(pull, MOUSE_BUTTON_RIGHT, false)
		await process_frame
		t += 1
	Settings.scheme_override = ""
	return false


func _target_manned(tut: LegionTutorial) -> int:
	var hit := tut.release_target()
	if hit.is_empty():
		return 0
	return (hit["contract"] as Contract).seg_manned(int(hit["seg"]))


func _find_banner() -> CanvasLayer:
	for n in world.get_children():
		if n is CanvasLayer and n.get_script() != null and n.has_method("play_outro") \
				and not n.is_queued_for_deletion():
			return n
	return null


func _banner_text(banner: CanvasLayer) -> String:
	var labels := banner.find_children("*", "Label", true, false)
	return (labels[labels.size() - 1] as Label).text if not labels.is_empty() else ""


# ── Часть 4: никаких тупиков ────────────────────────────────────────────────

func _dead_end_checks() -> void:
	var tut := await _start("")
	if tut == null:
		_check(false, "тупики: обучение не стартовало")
		return
	var rel := _idx(&"release")

	# линия растаяла сама (ПКМ не нажата) — шаг натиска засчитан таянием
	tut.force_step(rel)
	await _seconds(LegionCfg.SEG_TTL + 1.0)
	# зачтён — и следом «Точно!» без линии возвращает к дорожке (линия растаяла вся)
	_check(tut.passed(&"release"), "тупики: линия растаяла сама — натиск засчитан (урок %d)" %
		(tut.step() + 1))

	# все договоры ушли без натиска (ПКМ раньше, чем встал строй) — откат к линии, не тупик
	world.restart()
	await _frames(2)
	tut = world.tutorial
	_toasts.clear()
	tut.force_step(rel)
	var c: Contract = world.contracts.contracts[0] if not world.contracts.contracts.is_empty() else null
	_check(c != null, "тупики: у шага натиска есть живой договор")
	if c != null:
		for s in c.seg_count():
			world.contracts.release(c, s)
	await _frames(3)
	_check(tut.step() == 0, "тупики: договоры ушли без бойцов — откат к шагу 1 (шаг %d)" %
		(tut.step() + 1))
	_check(_toasts.has(LegionTutorial.HINT_EARLY), "тупики: подсказка «дай бойцам встать в строй»")
	# новая линия — сразу к натиску: стрелку и подновление игрок уже прошёл, заново не гоняем
	var g := tut.ghost_points()
	world.contracts.add_contract(g, world.contracts.default_side(g))
	await _frames(2)
	_check(tut.step() == rel, "тупики: после новой линии — сразу непройденный натиск (шаг %d)" %
		(tut.step() + 1))

	# меню площадки: смена душ не пересобирает кнопки — клик, начатый до убийства, не пропадает
	var plot: Dictionary = world.staff.plots[0]
	world.plot_menu.open(plot, plot["pos"])
	var btn: Button = world.plot_menu.buttons()[0]
	world.staff.add_souls(3)
	await _frames(2)
	_check(is_instance_valid(btn) and not btn.is_queued_for_deletion() \
			and world.plot_menu.buttons().has(btn),
		"меню площадки: смена душ не пересобирает кнопки")
	world.souls = 0
	world.staff.add_souls(1)
	await _frames(1)
	_check(is_instance_valid(btn) and btn.disabled, "меню площадки: нехватка душ гасит кнопку на месте")
	world.plot_menu.close()
	await _end_world()


# ── Часть 4б: повторная попытка шага 1 (ревью 25.09, пробник probe1c) ────────

## Штрих тем же путём, что мышь игрока (begin/extend/finish ContractField): только так
## повторный штрих поверх живого договора уходит в продление (match_refresh), как у человека.
func _stroke(a: Vector2, b: Vector2) -> void:
	world.contracts.begin(a)
	for i in range(1, 13):
		world.contracts.extend(a.lerp(b, i / 12.0))
	world.contracts.finish()


func _draw_retry_checks() -> void:
	var tut := await _start("")
	if tut == null:
		_check(false, "повтор: обучение не стартовало")
		return
	var g := tut.ghost_points()

	# короткий штрих по призраку (< TUTORIAL_MIN_POSTS мест) снят, следующий полный — зачёт
	_toasts.clear()
	_stroke(g[0], g[0].lerp(g[1], 0.7))
	await _frames(2)
	_check(tut.step() == 0 and world.contracts.contracts.is_empty(),
		"повтор: короткий штрих не засчитан и снят (договоров %d)" % world.contracts.contracts.size())
	_check(_toasts.has(LegionTutorial.HINT_SHORT), "повтор: подсказка «Коротковато»")
	_stroke(g[0], g[1])
	await _frames(2)
	_check(tut.step() == 1, "повтор: полный штрих по призраку засчитан с первой попытки (шаг %d)" %
		(tut.step() + 1))

	# другой вид (вахтёр): договор снят, подсказка про Подряд, после «1» — зачёт
	world.restart()
	await _frames(2)
	tut = world.tutorial
	world.contracts.set_kind(LegionCfg.KIND_GUARD)
	_toasts.clear()
	_stroke(g[0], g[1])
	await _frames(2)
	_check(tut.step() == 0 and world.contracts.contracts.is_empty(),
		"вид: договор вахтёров на шаге 1 не засчитан и снят")
	_check(_toasts.has(LegionTutorial.HINT_KIND), "вид: подсказка «нужен Подряд — нажми 1»")
	_check(not _toasts.has(LegionTutorial.HINT_FAR) and not _toasts.has(LegionTutorial.HINT_SHORT),
		"вид: подсказка не врёт про «далеко»/«коротко»")
	world.contracts.set_kind(LegionCfg.KIND_LABORER)
	_stroke(g[0], g[1])
	await _frames(2)
	_check(tut.step() == 1, "вид: после «1» штрих по призраку засчитан (шаг %d)" % (tut.step() + 1))

	# вид переживает restart(): обучение само возвращает Подряд
	world.contracts.set_kind(LegionCfg.KIND_CLERK)
	world.restart()
	await _frames(2)
	_check(world.contracts.current_kind == LegionCfg.KIND_LABORER,
		"вид: после restart() в обучении вид = подряд (%s)" % world.contracts.current_kind)
	await _end_world()


# ── Часть 5: регрессии ревью 24.09.2026 (tutfix) ─────────────────────────────

## parse_input_event (не push_input): тот же путь, что настоящее нажатие клавиши.
func _key(physical: Key) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = physical
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := ev.duplicate() as InputEventKey
	up.pressed = false
	Input.parse_input_event(up)


func _fix_regression_checks() -> void:
	var tut := await _start("")
	_check(tut != null, "fix: обучение стартовало (bot=off)")
	if tut == null:
		return

	# выход в меню посреди обучения снимает плашку и прячет боевой HUD
	world.go_to_menu()
	await _frames(2)
	_check(world.tutorial == null, "item6: go_to_menu() снимает активное обучение")
	_check(world.hud != null and not world.hud.visible, "item6: go_to_menu() прячет боевой HUD")
	_check(_find_banner() == null, "item6: плашка обучения снята")

	# restart() незачтённого обучения перезапускает урок с первого шага
	world.start_map("wasteland")
	world.start_tutorial()
	await _frames(2)
	var tut2: LegionTutorial = world.tutorial
	_check(tut2 != null, "item7: обучение снова стартовало для проверки restart()")
	if tut2 != null:
		tut2.force_step(2)
		await _frames(2)
		world.restart()
		await _frames(2)
		var tut3: LegionTutorial = world.tutorial
		_check(tut3 != null and tut3.active, "item7: restart() поднял обучение заново")
		_check(tut3 != null and tut3.step() == 0,
			"item7: восстановленное обучение начато с первого шага, не с обычных волн")

	# R игнорируется вне фазы боя (меню/итог)
	world.go_to_menu()
	await _frames(2)
	var map_id_before := world.map_id
	var phase_before := world.phase
	_key(KEY_R)
	await _frames(2)
	_check(world.phase == phase_before and world.map_id == map_id_before,
		"item8: R вне фазы боя (MENU) не перезапускает матч")
	await _end_world()
