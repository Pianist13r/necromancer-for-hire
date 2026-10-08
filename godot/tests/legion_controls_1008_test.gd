extends SceneTree
##
## Регресс управления перед Steam (slow/controls-1008, аудит docs/dev/audit-1008/controls.md).
##
##   "$GODOT" --headless --path godot --fixed-fps 60 --script res://tests/legion_controls_1008_test.gd -- --mute
##
## Ввод — НАСТОЯЩИЙ: Input.parse_input_event в координатах окна, тот же путь, что у ОС, и через
## настоящий HUD (карточки вида, «Вызвать»), а не прямые вызовы поля.
##  а) B-055 — штрих, начатый над карточками вида (x 340–930, y 654–708) и над «Вызвать»,
##     создаёт договор; короткий щелчок по карточке по-прежнему выбирает вид;
##  б) B-057 — тики колеса, пришедшие до нажатия колеса (окно тишины), вид не меняют;
##  в) B-058 — шеврон стрелки участка входит в площадь захвата (линия соседа побеждает);
##  г) B-044 — штрих вдоль живой линии ДРУГОГО вида подновляет её; Шифт + штрих — новая линия
##     поверх (пакет); флаг Шифта доходит через сетевую команду STROKE;
##  д) B-345 — «пенёк» после срыва без людей не держит слот лимита 6; упор в лимит — подпись у
##     пера с текущей клавишей стирания (Controls.text), а не только тост.
## Итог «LEGION CONTROLS 1008: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_controls_1008_test.cfg"
const WORLD := Vector2(1280.0, 720.0)
## Больше окна тишины прокрутки (LegionCfg.WHEEL_CLICK_QUIET) с запасом на медленный кадр.
const QUIET_WAIT_MS := 500

var w: LegionWorld
var f: ContractField
var _fails := 0
var _checks := 0
var _taps := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Input.use_accumulated_input = false
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	f = w.contracts
	f.tap.connect(func(_p: Vector2) -> void: _taps += 1)
	await _set_scale(1.0)
	await _test_kind_bar_stroke()
	await _test_call_stroke()
	await _test_wheel_before_press()
	await _test_arrow_pick()
	await _test_refresh_any_kind()
	await _test_stump_limit()
	await _test_followups()
	Controls.reset()
	Campaign.reset()
	print("LEGION CONTROLS 1008: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Настоящий ввод ──────────────────────────────────────────────────────────

func _set_scale(s: float) -> void:
	root.size = Vector2i(roundi(WORLD.x * s), roundi(WORLD.y * s))
	await process_frame
	await process_frame


func _win(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2, shift := false) -> void:
	var m := InputEventMouseMotion.new()
	m.position = _win(p)
	m.global_position = m.position
	m.shift_pressed = shift
	Input.parse_input_event(m)
	await process_frame


func _btn(p: Vector2, button: MouseButton, pressed: bool, shift := false) -> void:
	var b := InputEventMouseButton.new()
	b.position = _win(p)
	b.global_position = b.position
	b.button_index = button
	b.pressed = pressed
	b.shift_pressed = shift
	Input.parse_input_event(b)
	await process_frame


func _key(code: Key, pressed: bool) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.keycode = code
	k.pressed = pressed
	Input.parse_input_event(k)
	await process_frame


## Штрих ЛКМ от a до b шагами по 10 px экрана (координаты — экран вьюпорта 1280×720 = мир).
func _stroke(a: Vector2, b: Vector2, shift := false) -> void:
	await _move(a, shift)
	await _btn(a, MOUSE_BUTTON_LEFT, true, shift)
	var n := maxi(2, ceili(a.distance_to(b) / 10.0))
	for i in range(1, n + 1):
		await _move(a.lerp(b, float(i) / n), shift)
	await _btn(b, MOUSE_BUTTON_LEFT, false, shift)


func _click(p: Vector2) -> void:
	await _move(p)
	await _btn(p, MOUSE_BUTTON_LEFT, true)
	await _btn(p, MOUSE_BUTTON_LEFT, false)


## Чистое поле: плоская земля без скал, полная мана, без волн и бойцов, все виды открыты.
func _fresh() -> void:
	if w.paused:
		w.set_paused(false)
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	f.active = true
	f.human_input = true
	f.mana = f.mana_max
	f.unlocked = {}
	f.set_kind(LegionCfg.KIND_LABORER)
	_taps = 0


## Горизонтальный договор вида kind, узлы через POINT_STEP, как у штриха мыши; стрелка вверх.
func _hline(y: float, x0 := 440.0, x1 := 760.0, kind: StringName = LegionCfg.KIND_LABORER) -> Contract:
	var pts := PackedVector2Array()
	var x := x0
	while x < x1:
		pts.append(Vector2(x, y))
		x += LegionCfg.POINT_STEP
	pts.append(Vector2(x1, y))
	var c := f.add_contract(pts, 1, false, kind)
	c.set_dir(Vector2.UP)
	return c


func _man(c: Contract) -> void:
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()


func _kind_bar() -> LegionKindBar:
	var bar := w.hud._kind_bar
	bar._refresh_t = 0.0
	bar._process(0.0)
	return bar


# ── а) B-055: карточки вида и «Вызвать» не съедают штрих ─────────────────────

func _test_kind_bar_stroke() -> void:
	print("— а) B-055: штрих над карточками вида")
	_fresh()
	var bar := _kind_bar()
	await process_frame
	_check(bar.visible and bar.buttons.size() == 3, "полоса карточек на месте и видна")
	var r0 := bar.buttons[0].get_global_rect()
	_check(r0.has_point(Vector2(500, 680)), "карточка «Подряд» лежит под (500, 680): %s" % r0)
	await _stroke(Vector2(500, 680), Vector2(500, 560))
	_check(f.contracts.size() == 1, "штрих из (500, 680) над карточкой создал договор (%d)" % f.contracts.size())
	for kind_i in [1, 2]:
		var rect := bar.buttons[kind_i].get_global_rect()
		var before := f.contracts.size()
		await _stroke(rect.get_center(), rect.get_center() + Vector2(-60, -130))
		_check(f.contracts.size() == before + 1,
			"штрих с карточки %d создал договор (%d → %d)" % [kind_i, before, f.contracts.size()])
	_check(f.current_kind == LegionCfg.KIND_LABORER, "протяжка с карточки вид не меняет")
	# короткий щелчок по карточке — выбор вида, как раньше; tap площадки не рождается
	var guard := bar.buttons[1].get_global_rect().get_center()
	var made := f.contracts.size()
	await _click(guard)
	_check(f.current_kind == LegionCfg.KIND_GUARD, "щелчок по карточке «Охрана» выбрал вид")
	_check(_taps == 0 and f.contracts.size() == made, "щелчок по карточке — не tap площадки и не договор")
	await _click(bar.buttons[0].get_global_rect().get_center())
	_check(f.current_kind == LegionCfg.KIND_LABORER, "щелчок по «Подряду» вернул вид")


func _test_call_stroke() -> void:
	print("— а) B-055: штрих над «Вызвать»")
	_fresh()
	var hud := w.hud
	hud._preview.visible = true
	hud._call.visible = true
	await process_frame
	await process_frame
	var rect := hud._call.get_global_rect()
	_check(rect.size.x > 20.0 and rect.size.y > 10.0, "кнопка «Вызвать» разложена: %s" % rect)
	var a := rect.get_center()
	await _stroke(a, a + Vector2(-170, 90))
	_check(f.contracts.size() == 1, "штрих, начатый на «Вызвать», создал договор (%d)" % f.contracts.size())
	var called := [0]
	var count := func(_i: int, _b: int) -> void: called[0] += 1
	w.wave_called.connect(count)
	hud._update_preview()
	hud._call.visible = true
	await process_frame
	await process_frame   # текст превью сменился — кнопка могла сдвинуться: меряем заново
	var can := not hud._call.disabled
	var b := hud._call.get_global_rect().get_center()
	_taps = 0
	await _click(b)
	w.wave_called.disconnect(count)
	_check(_taps == 0 and f.contracts.size() == 1,
		"щелчок по «Вызвать» — не tap площадки и не договор (taps %d, договоров %d)" % [_taps, f.contracts.size()])
	_check(called[0] == (1 if can else 0),
		"закрытая «Вызвать» волну не зовёт (можно: %s, вызовов волны: %d)" % [can, called[0]])
	# открытая кнопка: волн в тестовом мире нет (no_waves), поэтому доказательство нажатия —
	# _press_call → _update_preview снова закрывает кнопку (тик HUD стоит: мир без _process)
	hud._call.disabled = false
	await _click(b)
	_check(hud._call.disabled and _taps == 0 and f.contracts.size() == 1,
		"щелчок по открытой «Вызвать» дошёл до её действия (_press_call), не до площадки")


# ── б) B-057: тики колеса до нажатия колеса ──────────────────────────────────

func _wheel_tick(at: Vector2, down: bool) -> void:
	var b := MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
	await _btn(at, b, true)
	await _btn(at, b, false)


func _test_wheel_before_press() -> void:
	print("— б) B-057: прокрутка перед нажатием колеса")
	_fresh()
	var at := Vector2(640, 400)
	await _move(at)
	OS.delay_msec(QUIET_WAIT_MS)
	await _wheel_tick(at, true)
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	_check(f.current_kind == LegionCfg.KIND_LABORER,
		"тик вниз и сразу нажатие колеса — вид прежний (%s)" % f.current_kind)
	await _btn(at, MOUSE_BUTTON_MIDDLE, false)
	OS.delay_msec(QUIET_WAIT_MS)
	f.set_kind(LegionCfg.KIND_LABORER)
	await _wheel_tick(at, true)
	await _wheel_tick(at, false)
	await _wheel_tick(at, false)
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	_check(f.current_kind == LegionCfg.KIND_LABORER, "три тика и нажатие — вид прежний (%s)" % f.current_kind)
	await _btn(at, MOUSE_BUTTON_MIDDLE, false)
	OS.delay_msec(QUIET_WAIT_MS)
	await _wheel_tick(at, true)
	OS.delay_msec(QUIET_WAIT_MS)
	_check(f.current_kind == LegionCfg.KIND_GUARD, "одиночный тик по-прежнему меняет вид")
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	_check(f.current_kind == LegionCfg.KIND_GUARD, "нажатие колеса спустя окно вид не откатывает")
	await _btn(at, MOUSE_BUTTON_MIDDLE, false)
	OS.delay_msec(QUIET_WAIT_MS)


# ── в) B-058: шеврон стрелки — в площади захвата ─────────────────────────────

func _test_arrow_pick() -> void:
	print("— в) B-058: шеврон стрелки в площади захвата (×2, радиус 20)")
	await _set_scale(2.0)
	_fresh()
	var c := _hline(360)
	var shaft := c.seg_center(1) + Vector2.UP * (ContractField.ARROW_OFFSET + ContractField.ARROW_LEN * 0.5)
	_check(f.pick_radius() <= 21.0, "радиус захвата ужат окном: %.1f" % f.pick_radius())
	var hit := f.pick_segment(shaft)
	_check(not hit.is_empty() and hit["contract"] == c and int(hit["seg"]) == 1,
		"середина шеврона (28 px перед линией) берёт свой участок")
	# настоящая ПКМ по шеврону: захват рогаткой (или щелчок в «классике»)
	await _move(shaft)
	await _btn(shaft, MOUSE_BUTTON_RIGHT, true)
	var grabbed: bool = (not f._grab.is_empty() and f._grab["contract"] == c) or not c.seg_alive(1)
	_check(grabbed, "ПКМ по шеврону взяла участок")
	await _key(KEY_ESCAPE, true)
	await _key(KEY_ESCAPE, false)
	f.cancel_sling()
	if w.paused:
		w.set_paused(false)
	_check(f.pick_segment(c.seg_center(1) + Vector2.UP * 50.0).is_empty(), "за шевроном (50 px) — мимо")
	# сосед прямо на шевроне: его линия ближе — побеждает она
	var n := _hline(360 - (ContractField.ARROW_OFFSET + ContractField.ARROW_LEN * 0.5) - 2.0)
	var near := f.pick_segment(shaft)
	_check(not near.is_empty() and near["contract"] == n, "линия соседа поверх шеврона побеждает")
	await _set_scale(1.0)


# ── г) B-044: подновление живой линии любого вида ───────────────────────────

func _test_refresh_any_kind() -> void:
	print("— г) B-044: штрих вдоль линии другого вида")
	_fresh()
	var g := _hline(300, 440.0, 760.0, LegionCfg.KIND_GUARD)
	for s in g.seg_count():
		g.seg_age[s] = 6.0
	f.set_kind(LegionCfg.KIND_LABORER)
	var mana0 := f.mana
	await _stroke(Vector2(450, 302), Vector2(750, 302))
	_check(f.contracts.size() == 1, "штрих «подрядом» вдоль живой «охраны» не лёг пакетом (%d договоров)" % f.contracts.size())
	_check(g.kind == LegionCfg.KIND_GUARD and g.seg_age[1] < 1.0,
		"линия «охраны» подновлена и осталась охраной (возраст %.1f)" % g.seg_age[1])
	_check(f.mana < mana0, "подновление платное")
	await _stroke(Vector2(450, 302), Vector2(750, 302), true)
	_check(f.contracts.size() == 2 and f.contracts[1].kind == LegionCfg.KIND_LABORER,
		"Шифт + штрих — новая линия «подряда» поверх (пакет): %d договоров" % f.contracts.size())
	# сеть: флаг Шифта переживает кодек и применяется у обоих клиентов одинаково
	var pts := PackedVector2Array()
	for i in 31:
		pts.append(Vector2(450.0 + 10.0 * i, 300.0))
	var cmd := {"type": "stroke", "pts": pts, "kind": String(LegionCfg.KIND_CLERK), "stack": true}
	f.mana = f.mana_max   # два человеческих штриха выше потратили ману: команды должны лечь целиком
	var back := NetCodec.roundtrip(cmd)
	_check(bool(back.get("stack", false)), "флаг «stack» переживает NetCodec")
	var plain := NetCodec.roundtrip({"type": "stroke", "pts": pts, "kind": String(LegionCfg.KIND_CLERK)})
	_check(not plain.has("stack"), "без Шифта флага в команде нет")
	var res := PvpCmd.apply(w, 0, back)
	_check(bool(res.get("ok", false)) and not bool(res.get("refreshed", true)) and f.contracts.size() == 3,
		"STROKE с «stack» кладёт линию поверх (%s)" % res)
	res = PvpCmd.apply(w, 0, plain)
	_check(bool(res.get("ok", false)) and bool(res.get("refreshed", false)) and f.contracts.size() == 3,
		"STROKE без «stack» подновляет живую линию (%s)" % res)


# ── д) B-345: «пеньки» и упор в лимит 6 ──────────────────────────────────────

func _limit_label() -> String:
	for fx: Dictionary in f._wall_fx:
		if String(fx["label"]).contains("договор"):
			return String(fx["label"])
	return ""


func _step() -> void:
	f.tick(1.0 / 60.0, f.now + 1.0 / 60.0)


func _hpts(y: float, x0 := 100.0) -> PackedVector2Array:
	var p := PackedVector2Array()
	for k in 31:
		p.append(Vector2(x0 + 10.0 * k, y))
	return p


func _stumps() -> int:
	var n := 0
	for c in f.contracts:
		if ContractField.is_stump(c):
			n += 1
	return n


func _test_stump_limit() -> void:
	print("— д) B-345: пенёк без людей и упор в лимит")
	_fresh()
	var lines: Array[Contract] = []
	for i in LegionCfg.MAX_CONTRACTS:
		lines.append(_hline(80.0 + 70.0 * i))
	var stump := lines[0]
	w.release_segment(stump, 0, &"manual")   # срыв: остаток линии без людей — «пенёк»
	_check(ContractField.is_stump(stump) and stump.alive(), "срыв без людей — пенёк")
	_step()
	_check(not f.contracts.has(stump) and f.contracts.size() == LegionCfg.MAX_CONTRACTS - 1,
		"пенёк погас на шаге поля, слот свободен (%d)" % f.contracts.size())
	await _stroke(Vector2(200, 200), Vector2(200, 360))
	_check(f.contracts.size() == LegionCfg.MAX_CONTRACTS,
		"на место пенька легла новая линия (%d)" % f.contracts.size())
	# лимит: отказ — подпись у пера с текущей клавишей стирания
	Controls.rebind(&"erase_piece", KEY_I)
	f._wall_ms = -100000
	await _stroke(Vector2(250, 200), Vector2(250, 360))
	_check(f.contracts.size() == LegionCfg.MAX_CONTRACTS, "лимит держит: седьмой линии нет")
	var label := _limit_label()
	_check(label != "", "упор в лимит — подпись у пера: «%s»" % label)
	_check(label.contains(Controls.label(&"erase_piece", true)) and not label.contains("Таб"),
		"подпись называет текущую клавишу стирания (I), не литерал «Таб»")
	Controls.reset()
	# линия с людьми после срыва — не пенёк: слот держит
	_fresh()
	for i in LegionCfg.MAX_CONTRACTS:
		lines[i] = _hline(80.0 + 70.0 * i)
	_man(lines[0])
	w.release_segment(lines[0], 0, &"manual")
	_step()
	await _stroke(Vector2(200, 200), Vector2(200, 360))
	_check(f.contracts.size() == LegionCfg.MAX_CONTRACTS and f.contracts.has(lines[0]),
		"срыв, но на остатке стоят бойцы — линия жива, слот занят (%d)" % f.contracts.size())
	# пустая свежая линия (людей ещё нет, срыва не было) — тоже не пенёк
	_fresh()
	for i in LegionCfg.MAX_CONTRACTS:
		_hline(80.0 + 70.0 * i)
	_step()
	await _stroke(Vector2(200, 200), Vector2(200, 360))
	_check(f.contracts.size() == LegionCfg.MAX_CONTRACTS, "свежие пустые линии слоты держат")
	await _test_stump_bypass()


## Проба verifier 1008 (probe2): 6 линий → срыв на каждой без людей → 6 штрихов → бойцы.
## Было 12 договоров, из них 10 с бойцами при лимите 6.
func _test_stump_bypass() -> void:
	print("— д) B-345: обход лимита пеньками (проба verifier)")
	_fresh()
	var olds: Array[Contract] = []
	for i in LegionCfg.MAX_CONTRACTS:
		olds.append(_hline(80.0 + 70.0 * i))
	for c in olds:
		w.release_segment(c, 0, &"manual")
	# штрихи в тот же кадр, до шага поля: пеньки ещё живы и держат слоты
	for i in LegionCfg.MAX_CONTRACTS:
		f.mana = f.mana_max
		f.stroke(_hpts(120.0 + 90.0 * i), LegionCfg.KIND_LABORER)
	_check(f.contracts.size() <= LegionCfg.MAX_CONTRACTS,
		"пока пеньки живы, новых сверх лимита нет (%d)" % f.contracts.size())
	# подновить пенёк штрихом нельзя: он не матчится
	f.mana = f.mana_max
	var along := PackedVector2Array()
	for k in 30:
		along.append(Vector2(450.0 + 10.0 * k, 80.0))
	var res := f.stroke(along, LegionCfg.KIND_LABORER)
	_check(not bool(res.get("refreshed", false)), "штрих по пеньку его не подновляет (%s)" % res)
	for i in 300:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(640, 380))
	w._assign_free(f)
	var refilled := 0
	for c in olds:
		for q in c.posts:
			if not q["dead"] and q["unit"] != null:
				refilled += 1
	_check(refilled == 0, "пеньки бойцов не набирают (мест занято: %d)" % refilled)
	_step()
	for i in LegionCfg.MAX_CONTRACTS:
		f.mana = f.mana_max
		f.stroke(_hpts(120.0 + 90.0 * i, 860.0), LegionCfg.KIND_LABORER)
	for r in 20:
		w._assign_free(f)
		_step()
	_check(f.contracts.size() <= LegionCfg.MAX_CONTRACTS and _stumps() == 0,
		"после шага: живых договоров %d ≤ %d, пеньков %d" % [f.contracts.size(),
			LegionCfg.MAX_CONTRACTS, _stumps()])


# ── е) доработки после verifier 1008 ────────────────────────────────────────

func _test_followups() -> void:
	print("— е) кодек stack по типу, дрогнувший щелчок по карточке, откат колеса после карточки")
	var pts := PackedVector2Array([Vector2(100, 100), Vector2(200, 100)])
	var base := NetCodec.encode(PvpCmd.stroke(pts, LegionCfg.KIND_LABORER))
	for v: Variant in [1, "true", 1.0, [true]]:
		var raw: Dictionary = base.duplicate(true)
		raw["stack"] = v
		_check(NetCodec.decode(raw).is_empty(), "stack=%s (%s) — команда отброшена" % [v, type_string(typeof(v))])
	var raw_false: Dictionary = base.duplicate(true)
	raw_false["stack"] = false
	var dec := NetCodec.decode(raw_false)
	_check(not dec.is_empty() and not dec.has("stack"), "stack=false — обычный штрих")
	_check(NetSession.BUILD == "net-2026-10-08b", "сборка сети поднята: %s" % NetSession.BUILD)
	# дрогнувший щелчок по карточке: сдвиг больше TAP_SLOP, линия короче минимума — смена вида
	_fresh()
	var bar := _kind_bar()
	await process_frame
	var guard := bar.buttons[1].get_global_rect().get_center()
	var mana0 := f.mana
	await _stroke(guard, guard + Vector2(LegionCfg.TAP_SLOP + 12.0, 0.0))
	_check(f.current_kind == LegionCfg.KIND_GUARD and f.contracts.is_empty() and is_equal_approx(f.mana, mana0),
		"дрогнувший щелчок по «Охране» выбрал вид, линии нет, мана цела")
	# щелчок по карточке сбрасывает окно отката колеса
	f.set_kind(LegionCfg.KIND_LABORER)
	OS.delay_msec(QUIET_WAIT_MS)
	var at := Vector2(640, 400)
	await _move(at)
	await _wheel_tick(at, true)                 # подряд → охрана, окно отката открыто
	await _click(bar.buttons[2].get_global_rect().get_center())   # «Аудит» щелчком
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	_check(f.current_kind == LegionCfg.KIND_CLERK, "нажатие колеса после выбора карточкой вид не откатывает (%s)" % f.current_kind)
	await _btn(at, MOUSE_BUTTON_MIDDLE, false)
