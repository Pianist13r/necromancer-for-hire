extends SceneTree
## Эталон бота обновлён 08.10 A7: автомарш/тактика, два одинаковых прогона.
## Происхождение новых хешей: docs/dev/audit-1008/gameplay-report.md.
##
## Самопроверка пакета «интуитивнее» (slow/intuit, Игорь 26.09: «пружинный срыв, прицеливание
## рогатки и абилки вовремя — не интуитивные»):
##  1) золотой участок: враг в зоне «Точно!» (геометрия рогатки при полной силе) — участок
##     золотой без натяжки; гаснет, когда враг ушёл; скан сеткой совпадает с перебором поля;
##  2) щелчок ПКМ по золотому — «Точно!» (стрелка участка, сила полная); по обычному — прежний
##     роспуск; B-071: оттяжка 8–23 px (меньше взвода) — отмена, бледная стрелка с 8 px;
##  3) пружина: метка «пружина ×N» с множителем урона, тревога у порога прорыва;
##  4) подсказки навыков: Ку (Юрист зачитывает, нотариус в замахе, толпа давит линию),
##     Е (строй прогибается), Дубль-вэ (≥ 2 свежих трупа у фронта); не чаще HINT_CD на тип;
##     оглушённые помечены, золото с оглушённым — ×1,5;
##  5) галочка «Подсказки» выключает советы (агентный прогон — только в памяти, файл владельца
##     не пишется);
##  6) стена: штрих, начатый в скале, — вспышка «стена», не чаще раза в секунду;
##  7) черновик: пустая часть (мест больше, чем наберёт) — отрезки вдоль линии;
##  8) бой бота побайтно прежний (трасса на 3 картах, «Стажёр», сверка с эталоном
##     интегрированного economy-mana — tests/data/legion_intuit_bot_ref.txt), скан каждые 6 шагов.
##
##   "$GODOT" --headless --path godot --fixed-fps 60 --script res://tests/legion_intuit_test.gd -- --mute
##
## Новый API берётся через get()/call(): на старом коде тест не падает разбором, а честно
## проваливает проверки. Итог «LEGION INTUIT: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_intuit_test.cfg"
const CFG_PATH := "res://scripts/legion/intuit_cfg.gd"
const SETTINGS_PATH := "res://scripts/common/settings.gd"
const BOT_REF := "res://tests/data/legion_intuit_bot_ref.txt"
## Бот: карта, сид, шагов по 1/60 с. Эталон economy-mana: происхождение — docs/dev/CODEX_MANA.md.
const BOT_RUNS := [["bridge", 1, 3600], ["fork", 2, 3600], ["wasteland", 3, 3600]]
## Полоса карты _gray между рекой (x 620–706) и скалой (x 870+), вдали от Котла.
const LAB := Vector2(760, 120)
const DEVICE := 7

var w: LegionWorld
var cfg: Dictionary = {}
var settings_script: GDScript = null
var _fails := 0
var _checks := 0
var _settings_existed := false
var _settings_mtime := 0


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


func _cfg(key: String, fallback: Variant) -> Variant:
	return cfg.get(key, fallback)


func _intuit() -> Object:
	return w.get("intuit") as Object


## Вызов нового API; на старом коде объекта нет — fallback (проверка честно падает).
func _ic(method: String, args: Array = [], fallback: Variant = null) -> Variant:
	var o := _intuit()
	if o == null or not o.has_method(method):
		return fallback
	return o.callv(method, args)


func _fc(method: String, args: Array = [], fallback: Variant = null) -> Variant:
	if not w.contracts.has_method(method):
		return fallback
	return w.contracts.callv(method, args)


func _scan() -> void:
	_ic("scan")


func _set_hints(on: bool) -> void:
	if settings_script != null and settings_script.has_method("set_hints"):
		settings_script.call("set_hints", on)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_settings_existed = FileAccess.file_exists(Settings.PATH)
	if _settings_existed:
		_settings_mtime = FileAccess.get_modified_time(Settings.PATH)
	settings_script = load(SETTINGS_PATH)
	if ResourceLoader.exists(CFG_PATH):
		cfg = (load(CFG_PATH) as Script).get_script_constant_map()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	# бот — первым, пока мир не видел ни одного ввода: порядок тот же, что при съёмке эталона
	_test_bot_same()
	_check(_intuit() != null, "у мира есть слой подсказок (world.intuit)")
	await _test_gold()
	_test_gold_equivalence()
	await _test_gold_click()
	await _test_gold_lure()
	await _test_gold_intercept()
	await _test_gold_probe()
	await _test_plain_click()
	await _test_short_pull()
	_test_spring()
	_test_hint_q()
	_test_hint_e()
	_test_hint_w()
	_test_stunned()
	await _test_unmanned()
	await _test_triangle()
	_test_eight()
	_test_ring_axis()
	await _test_quiet()
	_test_toggle()
	_test_wall()
	_test_draft_empty()
	_test_perf()
	_set_hints(true)
	_check(FileAccess.file_exists(Settings.PATH) == _settings_existed
		and (not _settings_existed or FileAccess.get_modified_time(Settings.PATH) == _settings_mtime),
		"user://settings.cfg не тронут (был: %s)" % _settings_existed)
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION INTUIT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Мир ──────────────────────────────────────────────────────────────────────

func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max
	_set_hints(true)


func _line(a: Vector2, b: Vector2, step := 8.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in n + 1:
		pts.append(a.lerp(b, float(i) / n))
	return pts


## Договор-столбик в лаборатории: два участка по 64 px, стрелка по умолчанию — от Котла (+x).
func _column(y0: float) -> Contract:
	return w.contracts.add_contract(_line(LAB + Vector2(0, y0), LAB + Vector2(0, y0 + 128)), 1, false)


func _man(c: Contract) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if p["unit"] != null or p["dead"]:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _still_foe(at: Vector2, type := "zombie") -> Foe:
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = f.hp
	return f


# ── Настоящие события ввода ──────────────────────────────────────────────────

func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2, mask: int = MOUSE_BUTTON_MASK_RIGHT) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


func _click_right(at: Vector2) -> void:
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _button(at, MOUSE_BUTTON_RIGHT, false)


# ── 1. Золотой участок ───────────────────────────────────────────────────────

func _test_gold() -> void:
	print("— золотой участок")
	_fresh()
	var c := _column(0)
	_man(c)
	_scan()
	_check(_ic("is_gold", [c, 0], null) == false and _ic("is_gold", [c, 1], null) == false,
		"врагов нет — золота нет")
	var f := _still_foe(c.seg_center(0) + c.dir * 40.0)
	_scan()
	_check(_ic("is_gold", [c, 0], false) == true, "враг в зоне «Точно!» участка 0 — участок золотой")
	_check(_ic("is_gold", [c, 1], true) == false, "соседний участок без врага — не золотой")
	# зона — треть дальности натиска при полной силе: 40 px — внутри, 200 — далеко за
	f.position = c.seg_center(0) + c.dir * 200.0
	_scan()
	_check(_ic("is_gold", [c, 0], true) == false, "враг ушёл за зону — золото погасло")
	# скан сам, без вызова: раз в SCAN_PERIOD реального времени
	f.position = c.seg_center(1) + c.dir * 30.0
	await _frames(int(ceil(float(_cfg("SCAN_PERIOD", 0.1)) * 60.0)) + 2)
	_check(_ic("is_gold", [c, 1], false) == true, "скан раз в %.2f с сам зажёг участок 1"
		% float(_cfg("SCAN_PERIOD", 0.1)))


## Скан сеткой = перебор поля (тот же зазор, что у рогатки при полной силе) на 40 раскладках.
func _test_gold_equivalence() -> void:
	print("— золото: сетка против перебора")
	_fresh()
	var cs: Array[Contract] = [_column(0), _column(260)]
	var ring_pts := PackedVector2Array()
	for i in 40:
		ring_pts.append(Vector2(1130, 405) + Vector2.from_angle(TAU * i / 40.0) * 70.0)
	ring_pts.append(ring_pts[0])
	# кольцо — золото у всего кольца, зона к центру урезана (ring_aim)
	if w.contracts.has_method("seg_gold"):
		cs.append(w.contracts._create(ring_pts, 1, LegionCfg.KIND_LABORER, true))
	# золото — только у участков со стоящими бойцами: ставим строй всем
	for c in cs:
		_man(c)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var foes: Array[Foe] = []
	for i in 6:
		foes.append(_still_foe(Vector2(900, 300)))
	var same := true
	var golds := 0
	for trial in 40:
		for f in foes:
			var c: Contract = cs[rng.randi() % cs.size()]
			var s := rng.randi() % c.seg_count()
			f.position = c.seg_center(s) + c.seg_dir(s) * rng.randf_range(-30.0, 140.0) \
				+ c.seg_dir(s).orthogonal() * rng.randf_range(-60.0, 60.0)
		_scan()
		for c in cs:
			for s in c.seg_count():
				var want = _fc("seg_gold", [c, s], null)
				var got = _ic("is_gold", [c, s], null)
				same = same and want != null and got == want
				if got == true:
					golds += 1
	_check(same and golds > 10 and cs.size() == 3,
		"скан сеткой совпал с перебором поля, с кольцом (золотых %d)" % golds)


# ── 2. Щелчок ПКМ ────────────────────────────────────────────────────────────

func _test_gold_click() -> void:
	print("— щелчок по золотому — «Точно!»")
	_fresh()
	var c := _column(0)
	var squad := _man(c)
	var near := _still_foe(c.seg_center(0) + c.dir * 40.0)
	var x0 := near.position.x
	_scan()
	await _click_right(c.seg_center(0))
	_check(not c.seg_alive(0) and c.seg_alive(1), "щелчок распустил ровно участок 0")
	_check(int(w.stats.get("perfect_releases", 0)) == 1, "щелчок по золотому — точный срыв посчитан")
	var popup := false
	for p in w.contracts._popups:
		popup = popup or not (p as Dictionary).has("text")
	_check(popup, "всплыло «Точно!»")
	var ok := false
	for u in squad:
		if u.state == Legionnaire.State.CHARGE:
			ok = u._charge_dir.is_equal_approx(c.dir) and bool(u._volley["perfect"]) \
				and is_equal_approx(float(u._volley["power"]), 1.0)
			break
	_check(ok, "натиск по стрелке участка, сила полная, perfect")
	await _frames(40)
	_check(near.position.x - x0 >= LegionCfg.PERFECT_KNOCK * 0.8,
		"отброс как у точного срыва: %.0f px" % (near.position.x - x0))


## Залпы бойцов договора, ушедших в натиск (общий словарь залпа: в "knocked" — кого задели).
func _volleys(squad: Array[Legionnaire]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for u in squad:
		if u.state == Legionnaire.State.CHARGE and not u._volley.is_empty() \
				and not out.has(u._volley):
			out.append(u._volley)
	return out


func _knocked(volleys: Array[Dictionary], f: Foe) -> bool:
	for v in volleys:
		if (v["knocked"] as Dictionary).has(f):
			return true
	return false


## B-082 / D-0927-53: золото обещает, куда РЕАЛЬНО побежит натиск. Зомби в зоне «Точно!», а
## нотариус (широкий конус, 200 px) или призрак (120 px в любую сторону) вне зоны — натиск
## убежит к нему, значит участок не золотой, и щелчок — обычный роспуск. Приманка в самой зоне —
## золото, и щелчок бьёт её. На 34e6fa6 участок золотел, натиск уходил к нотариусу, зомби цел.
func _test_gold_lure() -> void:
	print("— B-082: приманка вне зоны гасит золото")
	for lure_type: String in ["signer", "ghost"]:
		_fresh()
		var c := _column(0)
		var squad := _man(c)
		var zombie := _still_foe(c.seg_center(0) + c.dir * 40.0)
		# нотариус 130–185 px от бойцов, наискось; призрак до 110 px вбок — оба вне зоны
		var off := Vector2(90, 130) if lure_type == "signer" else Vector2(40, 70)
		var lure := _still_foe(c.seg_center(0) + off, lure_type)
		_scan()
		_check(_ic("is_gold", [c, 0], true) == false and _fc("seg_gold", [c, 0], true) == false,
			"%s вне зоны уведёт натиск — участок 0 не золотой (скан и поле)" % lure_type)
		await _click_right(c.seg_center(0))
		var vs := _volleys(squad)
		_check(int(w.stats.get("perfect_releases", 0)) == 0 and not vs.is_empty(),
			"%s: щелчок по не-золотому — обычный роспуск, не «Точно!»" % lure_type)
		await _frames(120)
		_check(_knocked(vs, lure) and not _knocked(vs, zombie),
			"%s: натиск и правда ушёл к приманке, зомби в зоне не задет — золото не соврало бы"
			% lure_type)
		# приманка в самой зоне — золото есть, и щелчок бьёт её
		_fresh()
		c = _column(0)
		squad = _man(c)
		zombie = _still_foe(c.seg_center(0) + c.dir * 70.0 + c.dir.orthogonal() * 20.0)
		lure = _still_foe(c.seg_center(0) + c.dir * 45.0, lure_type)
		_scan()
		_check(_ic("is_gold", [c, 0], false) == true and _fc("seg_gold", [c, 0], false) == true,
			"%s в зоне — участок 0 золотой" % lure_type)
		await _click_right(c.seg_center(0))
		vs = _volleys(squad)
		_check(int(w.stats.get("perfect_releases", 0)) == 1, "%s в зоне: щелчок — «Точно!»" % lure_type)
		await _frames(120)
		_check(_knocked(vs, lure), "%s в зоне: «Точно!» ударило приманку" % lure_type)


## Сцены проверяющего e386b98 (D-0927-53, консервативное золото): натиск выбирает цель каждый
## тик, и приманка, вошедшая в свой радиус, пока боец бежит к зомби, перехватывает его. На
## e386b98 здесь было золото, а залп бил только приманку.
func _test_gold_intercept() -> void:
	print("— перехват приманкой на пути к зомби")
	var scenes := [["зомби@50 + нотариус@205", 50.0, "signer", 205.0, false],
		["зомби@66 + нотариус@225", 66.0, "signer", 225.0, false],
		["зомби@70 + идущий призрак со 160 px", 70.0, "ghost", 160.0, true]]
	for sc: Array in scenes:
		_fresh()
		var c := _column(0)
		var squad := _man(c)
		var ctr := c.seg_center(0)
		var zombie := _still_foe(ctr + c.dir * float(sc[1]))
		var lure: Foe
		if bool(sc[4]):
			lure = w.spawn_foe_on_path(sc[2], PackedVector2Array([ctr + c.dir * float(sc[3]),
				ctr - c.dir * 300.0]), ctr + c.dir * float(sc[3]))
			lure.hp = 100000.0
		else:
			lure = _still_foe(ctr + c.dir * float(sc[3]), sc[2])
		_scan()
		var gold_scan = _ic("is_gold", [c, 0], true)
		var gold_field = _fc("seg_gold", [c, 0], true)
		w.contracts.release_aimed(c, 0, c.dir, 1.0, true)
		var vs := _volleys(squad)
		await _frames(150)
		_check(gold_scan == false and gold_field == false,
			"%s: не золото (натиск бьёт %s)" % [sc[0], "зомби" if _knocked(vs, zombie)
				else ("приманку" if _knocked(vs, lure) else "никого")])
	# рогатка: «Срывай!» не врёт — нотариус сбоку в конусе, зомби в зоне
	_fresh()
	var c2 := _column(0)
	_man(c2)
	var ctr2 := c2.seg_center(0)
	_still_foe(ctr2 + c2.dir * 40.0)
	_still_foe(ctr2 + c2.dir * 100.0 + c2.dir.orthogonal() * 110.0, "signer")
	var f := w.contracts
	f._grab = {"contract": c2, "seg": 0}
	f._grab_pos = ctr2
	f._pull = ctr2 - c2.dir * 60.0
	var aim: Dictionary = f.sling_aim()
	f.cancel_sling()
	_check(not bool(aim.get("perfect", true)), "рогатка: нотариус уведёт натиск — не «Точно!»")
	# кольцо наружу: нотариус сбоку — ring_aim тоже не «Точно!»
	_fresh()
	var center := Vector2(1130.0, 200.0)
	var ring_pts := PackedVector2Array()
	for i in 40:
		ring_pts.append(center + Vector2.from_angle(TAU * i / 40.0) * 80.0)
	ring_pts.append(ring_pts[0])
	var ring: Contract = f._create(ring_pts, 1, LegionCfg.KIND_LABORER, true)
	ring.set_ring_out(true)
	_man(ring)
	var o := (ring.seg_center(0) - center).normalized()
	_still_foe(ring.seg_center(0) + o * 35.0)
	_still_foe(ring.seg_center(0) + o * 100.0 + o.orthogonal() * 110.0, "signer")
	var ra: Dictionary = f.ring_aim(ring, 0, -o * 60.0, 1.0)
	_check(not bool(ra["perfect"]), "кольцо наружу: нотариус рядом — ring_aim не «Точно!»")
	# кольцо внутрь: зомби в центре, призрак в 40 px за кольцом — «Точно!» соседних участков
	# отбрасывает призрака внутрь, и натиск всех уходит к нему (verify-gold e7f7790): не золото
	_fresh()
	var c_in := Vector2(1100.0, 230.0)
	var pts_in := PackedVector2Array()
	for i in 40:
		pts_in.append(c_in + Vector2.from_angle(TAU * i / 40.0) * 80.0)
	pts_in.append(pts_in[0])
	var ring_in: Contract = f._create(pts_in, 1, LegionCfg.KIND_LABORER, true)
	_man(ring_in)
	_still_foe(c_in)
	_still_foe(c_in + Vector2(120.0, 0.0), "ghost")
	var any_gold := false
	for s in ring_in.seg_count():
		any_gold = any_gold or f.seg_gold(ring_in, s)
	_check(ring_in.ring and not any_gold,
		"кольцо внутрь: призрак в 40 px за кольцом — не золото (отброс соседних залпов)")
	# кольцо 120 px, призрак в 20 px за кольцом, зомби в 50 px напротив — отброс соседних залпов
	# перекрывал и запас 90 px (verify-gold 728b959): приманка у любого участка фигуры — не золото
	_fresh()
	var c_big := Vector2(1060.0, 330.0)
	var pts_big := PackedVector2Array()
	for i in 60:
		pts_big.append(c_big + Vector2.from_angle(TAU * i / 60.0) * 120.0)
	pts_big.append(pts_big[0])
	var ring_big: Contract = f._create(pts_big, 1, LegionCfg.KIND_LABORER, true)
	_man(ring_big)
	_still_foe(c_big - Vector2.from_angle(0.8) * 50.0)
	_still_foe(c_big + Vector2.from_angle(0.8) * 140.0, "ghost")
	var big_gold := false
	for s in ring_big.seg_count():
		big_gold = big_gold or f.seg_gold(ring_big, s)
	_check(ring_big.ring and not big_gold,
		"кольцо 120 px: призрак в 20 px за кольцом — не золото (приманка у участка фигуры)")


## Пробник «золото → попадание» на сценах с нотариусом и призраком: случайные раскладки (враги
## у участка 0 и приманка поблизости); каждый золотой участок — щелчок, и натиск обязан задеть
## врага, который был в зоне «Точно!» в момент щелчка.
func _test_gold_probe() -> void:
	print("— пробник: золото → попадание (нотариус, призрак)")
	var rng := RandomNumberGenerator.new()
	rng.seed = 27
	var golds := 0
	var hits := 0
	var dark := 0
	for trial in 60:
		_fresh()
		var c := _column(0)
		var squad := _man(c)
		var center := c.seg_center(0)
		var side := c.dir.orthogonal()
		var foes: Array[Foe] = []
		for k in rng.randi_range(1, 2):
			foes.append(_still_foe(center + c.dir * rng.randf_range(10.0, 110.0)
				+ side * rng.randf_range(-45.0, 45.0)))
		var lure_type := "signer" if trial % 2 == 0 else "ghost"
		var reach := 230.0 if lure_type == "signer" else 140.0
		var at := center + Vector2.from_angle(rng.randf_range(-PI * 0.6, PI * 0.6)) \
			* rng.randf_range(30.0, reach)
		foes.append(_still_foe(Vector2(clampf(at.x, 720.0, 860.0), at.y), lure_type))
		_scan()
		if _ic("is_gold", [c, 0], false) != true:
			dark += 1
			continue
		golds += 1
		var hit := w.contracts.seg_strike(c, 0, 1.0)
		var zone: Array[Foe] = []
		for f in foes:
			var v := f.position - center
			var along := v.dot(hit["dir"])
			if along >= -f.radius and along <= float(hit["depth"]) + f.radius \
					and absf(v.dot(side)) <= w.contracts.seg_half_len(c, 0) + f.radius:
				zone.append(f)
		await _click_right(center)
		var vs := _volleys(squad)
		await _frames(120)
		var ok := false
		for f in zone:
			ok = ok or _knocked(vs, f)
		if ok:
			hits += 1
		else:
			print("    промах: проба %d, %s" % [trial, lure_type])
	print("  золотых %d, из них попали %d; не золотых %d" % [golds, hits, dark])
	_check(golds >= 15 and hits == golds and dark > 0,
		"золото → попадание: %d/%d (приманки гасили золото %d раз)" % [hits, golds, dark])


func _test_plain_click() -> void:
	print("— щелчок по обычному — прежний роспуск")
	_fresh()
	var c := _column(0)
	var squad := _man(c)
	_still_foe(c.seg_center(1) + c.dir * 200.0)
	_scan()
	await _click_right(c.seg_center(0))
	_check(not c.seg_alive(0), "щелчок распустил участок")
	_check(int(w.stats.get("perfect_releases", 0)) == 0 and int(w.stats.get("sling_releases", 0)) == 0
		and int(w.stats["releases_manual"]) == 1, "обычный щелчок — прежний ручной выпуск")
	var ok := false
	for u in squad:
		if u.state == Legionnaire.State.CHARGE:
			ok = is_equal_approx(float(u._volley["range"]), 1.0) and not bool(u._volley["perfect"])
			break
	_check(ok, "множители прежние (1.0), не perfect")


## B-071: оттяжка от TAP_SLOP до SLING_ARM — отмена; с TAP_SLOP видна бледная стрелка.
func _test_short_pull() -> void:
	print("— B-071: короткая оттяжка — отмена")
	_fresh()
	var c := _column(0)
	_man(c)
	var at := c.seg_center(0)
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _move(at + Vector2(-5, 0))
	_check(_fc("sling_pending", [], null) == false, "оттяжка 5 px — ещё щелчок, стрелки нет")
	await _move(at + Vector2(-15, 0))
	_check(_fc("sling_pending", [], false) == true and not w.contracts.is_slinging(),
		"оттяжка 15 px — бледная стрелка, натяжка не взведена")
	await _button(at + Vector2(-15, 0), MOUSE_BUTTON_RIGHT, false)
	_check(c.seg_alive(0) and int(w.stats["releases"]) == 0,
		"отпустил на 15 px — ничего не сорвалось (было: щелчок по стрелке договора)")
	# щелчок с дрожью меньше TAP_SLOP — прежний роспуск
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _move(at + Vector2(3, 2))
	await _button(at + Vector2(3, 2), MOUSE_BUTTON_RIGHT, false)
	_check(not c.seg_alive(0), "дрожь 3 px — щелчок, участок распущен")


# ── 3. Пружина ───────────────────────────────────────────────────────────────

func _test_spring() -> void:
	print("— пружина")
	_fresh()
	var c := _column(0)
	_man(c)
	c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.5
	c.seg_bend[1] = LegionCfg.PRESS_BREAK * 0.1
	w.hero._cd[2] = 99.0   # совет на поле один — пусть это будет совет пружины, а не Е
	_scan()
	var m = _ic("spring_mult", [c, 0], 0.0)
	_check(absf(float(m) - (1.0 + LegionCfg.SPRING_DMG * 0.5)) < 0.001,
		"прогиб 0,5 — пружина ×%.2f (урон натиска)" % float(m))
	# подпись — то же число одним знаком после запятой (29.09: SPRING_DMG 0,6 → 0,9, было «×1,3»)
	var spring_label := "пружина ×" + ("%.1f" % (1.0 + LegionCfg.SPRING_DMG * 0.5)).replace(".", ",")
	_check(String(_ic("spring_text", [c, 0], "")) == spring_label, "подпись «%s»: «%s»"
		% [spring_label, String(_ic("spring_text", [c, 0], ""))])
	_check(float(_ic("spring_mult", [c, 1], 1.0)) == 0.0, "прогиб 0,1 (< SPRING_MIN) — метки нет")
	_check(_ic("spring_alarm", [c, 0], true) == false, "прогиб 0,5 — без тревоги")
	c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.85
	_scan()
	_check(_ic("spring_alarm", [c, 0], false) == true, "прогиб 0,85 — тревога (к прорыву)")
	_check(int(_ic("hints_shown", [&"spring"], 0)) == 1, "совет «сорви — ударит сильнее» показан раз")


# ── 4. Подсказки навыков ─────────────────────────────────────────────────────

func _test_hint_q() -> void:
	print("— подсказка Ку")
	_fresh()
	var c := _column(0)
	_man(c)
	_scan()
	_check(_ic("useful", [0], true) == false, "спокойно — Ку не подсказан")
	var law := _still_foe(c.seg_center(0) + c.dir * 90.0, "lawyer")
	law.law_read_t = 1.0
	_scan()
	_check(_ic("useful", [0], false) == true, "Юрист зачитывает — Ку полезен")
	_check(int(_ic("hints_shown", [&"q"], 0)) == 1, "подпись Ку показана")
	_check(float(_ic("slot_glow", [0], 0.0)) > 0.5, "слот Ку пульсирует")
	var hint_at = _ic("hint_pos", [0], Vector2.INF)
	_check(hint_at is Vector2 and (hint_at as Vector2).distance_to(law.position) < 80.0,
		"подпись — у Юриста")
	_scan()
	_check(int(_ic("hints_shown", [&"q"], 0)) == 1, "второй скан сразу — подпись не повторилась")
	w.now += float(_cfg("HINT_CD", 10.0)) + 0.05
	_scan()
	_check(int(_ic("hints_shown", [&"q"], 0)) == 2, "через HINT_CD — снова")
	law.law_read_t = -1.0
	var signer := _still_foe(c.seg_center(1) + c.dir * 150.0, "signer")
	signer.stamp_t = 0.5
	_scan()
	_check(_ic("useful", [0], false) == true, "нотариус в замахе — Ку полезен")
	signer.stamp_t = -1.0
	_scan()
	_check(_ic("useful", [0], true) == false, "замаха нет — не подсказан")
	# толпа давит линию (массу пишет press_scan в шаге мира; здесь шага не было — размер сами)
	c.press_mass.resize(c.seg_count())
	c.press_sum.resize(c.seg_count())
	c.press_mass[1] = 4.0
	c.press_sum[1] = (c.seg_center(1) + c.dir * 20.0) * 4.0
	c.seg_bend[1] = LegionCfg.PRESS_BREAK * 0.3
	_scan()
	_check(_ic("useful", [0], false) == true, "толпа давит участок — Ку полезен")
	w.hero._cd[0] = 5.0
	_scan()
	_check(_ic("useful", [0], true) == false, "Ку на откате — не подсказан")
	# потолок: на поле не больше HINT_MAX подписей разом
	w.hero._cd[0] = 0.0
	c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.6
	_still_foe(c.seg_center(0) + c.dir * 40.0)
	w.now += float(_cfg("HINT_CD", 10.0)) + 0.05
	_scan()
	var live = _intuit().get("_labels") if _intuit() != null else null
	_check(live is Array and (live as Array).size() == int(_cfg("HINT_MAX", 2)),
		"пять поводов сразу — подписей на поле %s (потолок HINT_MAX)"
		% (str((live as Array).size()) if live is Array else "?"))


func _test_hint_e() -> void:
	print("— подсказка Е")
	_fresh()
	var c := _column(0)
	_man(c)
	c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.2
	_scan()
	_check(_ic("useful", [2], true) == false, "прогиб 0,2 — Е не подсказан")
	c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.45
	_scan()
	_check(_ic("useful", [2], false) == true, "строй прогибается (0,45) — Е полезен")
	_check(int(_ic("hints_shown", [&"e"], 0)) == 1, "подпись Е показана")
	w.hero._cd[2] = 3.0
	_scan()
	_check(_ic("useful", [2], true) == false, "Е на откате — не подсказан")


func _test_hint_w() -> void:
	print("— подсказка Дубль-вэ")
	_fresh()
	var c := _column(0)
	_man(c)
	var a := _still_foe(c.seg_center(0) + c.dir * 50.0)
	a.take_damage(1e9, c.seg_center(0))
	_scan()
	_check(_ic("useful", [1], true) == false, "один свежий труп — Дубль-вэ не подсказан")
	var b := _still_foe(c.seg_center(0) + c.dir * 60.0 + Vector2(0, 20))
	b.take_damage(1e9, c.seg_center(0))
	_scan()
	_check(_ic("useful", [1], false) == true, "два свежих трупа у фронта — Дубль-вэ полезен")
	_check(int(_ic("hints_shown", [&"w"], 0)) == 1, "подпись Дубль-вэ показана")


func _test_stunned() -> void:
	print("— оглушённые")
	_fresh()
	var c := _column(0)
	_man(c)
	var f := _still_foe(c.seg_center(0) + c.dir * 40.0)
	_scan()
	_check(_ic("gold_stunned", [c, 0], true) == false, "в зоне не оглушённый — без ×1,5")
	f.stun(0.9)
	_scan()
	_check(int(_ic("stunned_count", [], 0)) == 1, "оглушённый помечен")
	_check(_ic("gold_stunned", [c, 0], false) == true, "золото с оглушённым — ×1,5")


# ── Проверяющий 27.09 (d1c055b): кому золото не положено, фигуры, тише ─────────

## Пустой участок и участок «на марше» (назначены, но не стоят) — не золотые; щелчок по ним —
## не «Точно!»: срыв никого не пошлёт (тот же признак POSTED, по которому срывает мир).
func _test_unmanned() -> void:
	print("— золото: пустой участок и марш")
	_fresh()
	var c := _column(0)
	_still_foe(c.seg_center(0) + c.dir * 40.0)
	_scan()
	_check(_ic("is_gold", [c, 0], true) == false, "на участке никого — не золотой")
	_check(int(_ic("hints_shown", [&"gold"], -1)) == 0, "и совета «щёлкни» нет")
	await _click_right(c.seg_center(0))
	_check(int(w.stats.get("perfect_releases", 0)) == 0, "щелчок по пустому — не «Точно!»")
	var c2 := _column(300)
	for p in c2.posts:
		if int(p["seg"]) == 0:
			var u := w.spawn_unit(c2.kind, LAB + Vector2(-120, 500))
			u.assign(c2, p)   # назначен, идёт — ещё не стоит
	_still_foe(c2.seg_center(0) + c2.dir * 40.0)
	_scan()
	_check(c2.seg_manned(0) == 0, "на марше стоящих нет (%d)" % c2.seg_manned(0))
	_check(_ic("is_gold", [c2, 0], true) == false, "участок на марше — не золотой")
	await _click_right(c2.seg_center(0))
	_check(int(w.stats.get("perfect_releases", 0)) == 0, "щелчок по участку на марше — не «Точно!»")


func _fig(fig: StringName, pts: PackedVector2Array) -> Contract:
	var n := w.contracts.contracts.size()
	w.contracts._create(pts, 1, LegionCfg.KIND_LABORER, false, fig)
	if w.contracts.contracts.size() <= n:
		return null
	var c: Contract = w.contracts.contracts[w.contracts.contracts.size() - 1]
	return c if c.figure == fig else null


func _dense6(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size()):
		var k := maxi(1, ceili(pts[i - 1].distance_to(pts[i]) / 6.0))
		for j in range(1, k + 1):
			out.append(pts[i - 1].lerp(pts[i], float(j) / k))
	return out


## Треугольник золотым не бывает никогда: его срыв — выброс ульты («Обряд» — набрать строй).
## До D-1002-03 (02.10) то же правило было у звезды.
func _test_triangle() -> void:
	print("— треугольник: без золота")
	_fresh()
	var center := Vector2(1130.0, 405.0)
	var order := PackedVector2Array()
	for k in 4:
		order.append(center + Vector2.from_angle(-PI * 0.5 + TAU * float(k % 3) / 3.0) * 80.0)
	var c := _fig(ContractShape.TRIANGLE, _dense6(order))
	_check(c != null, "треугольник заключён")
	if c == null:
		return
	_man(c)
	for s in c.seg_count():
		_still_foe(c.seg_center(s) + c.seg_dir(s) * 30.0)
	_scan()
	var any := false
	for s in c.seg_count():
		any = any or _ic("is_gold", [c, s], true) == true
	_check(not any, "враги у всех рёбер — треугольник не золотой")
	_check(int(_ic("hints_shown", [&"gold"], -1)) == 0, "совета «щёлкни» у треугольника нет")
	await _click_right(c.seg_center(0))
	_check(int(w.stats.get("perfect_releases", 0)) == 0, "щелчок по треугольнику — не «Точно!»")


## Восьмёрка: зона — туда, куда реально бегут бойцы (к центру другой петли, charge_for), а не по
## стрелке участка.
func _test_eight() -> void:
	print("— восьмёрка: зона по настоящему натиску")
	_fresh()
	var center := Vector2(1130.0, 405.0)
	var pts := PackedVector2Array()
	var n := 90
	for i in n + 1:
		var t := PI * 0.5 + TAU * float(i) / n
		pts.append(center + Vector2(85.0 * sin(t), 130.0 * sin(t) * cos(t)).rotated(PI * 0.5))
	var c := _fig(ContractShape.EIGHT, pts)
	_check(c != null, "восьмёрка заключена")
	if c == null:
		return
	# Стрелка участка восьмёрки уже смотрит к центру другой петли (Contract._front), но натиск
	# не бежит дальше этого центра с перебегом (charge_for, EIGHT_OVERRUN): враг за ним — не
	# золото, хотя по одной стрелке и глубине рогатки (~91 px) был бы. Берём участок, у
	# которого другая петля ближе всего.
	var best := -1
	var cap := INF
	for s in c.seg_count():
		var along := minf(c.length, (s + 0.5) * LegionCfg.SEG_LEN)
		var d := c.seg_center(s).distance_to(c.lobes[1 - c.lobe_at(along)]) + FigureCfg.EIGHT_OVERRUN
		if d < cap:
			cap = d
			best = s
	# строй — только на этом участке: вся фигура золотится от любого стоящего участка, и враг у
	# другой петли попал бы в зону её собственных участков
	for p in c.posts:
		if int(p["seg"]) == best and p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()
	var dir := c.seg_dir(best)
	_check(best >= 0 and cap + 12.0 < 91.0 + 8.0,
		"есть участок, где натиск короче зоны рогатки (%.0f px)" % cap)
	var f := _still_foe(c.seg_center(best) + dir * minf(30.0, cap * 0.5))
	_scan()
	_check(_ic("is_gold", [c, best], false) == true, "враг на пути натиска к другой петле — золото")
	f.position = c.seg_center(best) + dir * (cap + 12.0)
	_scan()
	_check(_ic("is_gold", [c, best], true) == false,
		"враг за центром другой петли (натиск туда не добежит) — не золото")


## Кольцо: зона по оси удара — внутрь (к центру) или наружу (ring_out).
func _test_ring_axis() -> void:
	print("— кольцо: ось удара")
	_fresh()
	var center := Vector2(1130.0, 405.0)
	var pts := PackedVector2Array()
	for i in 40:
		pts.append(center + Vector2.from_angle(TAU * i / 40.0) * 80.0)
	pts.append(pts[0])
	var c: Contract = w.contracts._create(pts, 1, LegionCfg.KIND_LABORER, true)
	_man(c)
	var s0 := 0
	var out := (c.seg_center(s0) - center).normalized()
	var f := _still_foe(c.seg_center(s0) - out * 35.0)   # внутри кольца
	_scan()
	_check(_ic("is_gold", [c, s0], false) == true, "кольцо внутрь, враг внутри — золото")
	f.position = c.seg_center(s0) + out * 35.0
	_scan()
	_check(_ic("is_gold", [c, s0], true) == false, "кольцо внутрь, враг снаружи — не золото")
	c.set_ring_out(true)
	_scan()
	_check(_ic("is_gold", [c, s0], false) == true, "кольцо наружу, враг снаружи — золото")
	f.position = c.seg_center(s0) - out * 35.0
	_scan()
	_check(_ic("is_gold", [c, s0], true) == false, "кольцо наружу, враг внутри — не золото")


## D-0927-49 (Игорь: «чтоб поменьше всего происходило»): на поле не больше одного совета; совет
## одного типа — не больше трёх раз за бой; сделал нужное — совет больше не показывается.
func _test_quiet() -> void:
	print("— тише: один совет, три раза, гаснет после правильного действия")
	_fresh()
	var c := _column(0)
	_man(c)
	var c2 := _column(300)
	_man(c2)
	c2.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.5
	var law := _still_foe(c.seg_center(1) + c.dir * 150.0, "lawyer")
	law.law_read_t = 1.0
	_still_foe(c.seg_center(0) + c.dir * 40.0)
	_scan()
	var live = _intuit().get("_labels") if _intuit() != null else null
	_check(live is Array and (live as Array).size() == 1,
		"четыре повода (Ку, Е, золото, пружина) — на поле ровно один совет")
	# «Точно!» щелчком по золоту — совет «щёлкни» больше не нужен
	await _click_right(c.seg_center(0))
	_check(_ic("is_done", [&"gold"], false) == true, "щёлкнул по золоту — совет золота снят")
	_still_foe(c.seg_center(1) + c.dir * 40.0)
	for k in 4:
		w.now += float(_cfg("HINT_CD", 10.0)) + 0.05
		_scan()
	_check(int(_ic("hints_shown", [&"gold"], 99)) <= 1 and _ic("is_gold", [c, 1], false) == true,
		"золото видно, а совет «щёлкни» больше не всплывает (%d)"
		% int(_ic("hints_shown", [&"gold"], 99)))
	# Ку: скастовал по подсказке — совет снят, тихий пульс слота остаётся
	_check(int(_ic("hints_shown", [&"q"], 0)) >= 1, "совет Ку был показан")
	# После живых кадров щелчка Юрист мог сменить цель: отдельная проба снова задаёт чтение.
	law.law_read_t = 1.0
	_scan()
	_check(_ic("useful", [0], false) == true, "перед кастом Ку Юрист снова зачитывает")
	var q_before := int(_ic("hints_shown", [&"q"], 0))
	var q_mana := w.contracts.mana
	var q_cd := w.hero.cd_left(0)
	_check(w.hero.cast(0, law.position),
		"Ку по подсказке состоялся (мана %.2f, откат %.2f)" % [q_mana, q_cd])
	_check(_ic("is_done", [&"q"], false) == true, "каст Ку по подсказке — совет Ку снят")
	law.stun_t = 0.0
	law.law_read_t = 1.0
	w.now += float(_cfg("HINT_CD", 10.0)) + 0.05
	w.hero._cd[0] = 0.0
	_scan()
	_check(int(_ic("hints_shown", [&"q"], 99)) == q_before, "Юрист снова читает — совета Ку нет")
	var glow := float(_ic("slot_glow", [0], 0.0))
	_check(glow > 0.0 and glow < 1.0, "пульс слота Ку тихий, но есть (%.2f)" % glow)
	# Е: не больше трёх раз за бой
	for k in 6:
		w.now += float(_cfg("HINT_CD", 10.0)) + 0.05
		_scan()
	_check(int(_ic("hints_shown", [&"e"], 99)) == 3,
		"совет Е — не больше 3 раз за бой (%d)" % int(_ic("hints_shown", [&"e"], 99)))
	# таяние прогнутого участка — не действие игрока: совет пружины остаётся (verify-intuit b38a391)
	c2.seg_bend[1] = LegionCfg.PRESS_BREAK * 0.5
	w.release_segment(c2, 1, &"melt")
	_check(_ic("is_done", [&"spring"], true) == false,
		"участок растаял прогнутым — совет пружины не снят (игрок ничего не делал)")
	# пружина: сорвал прогнутый — совет пружины снят
	w.contracts.release(c2, 0)
	_check(_ic("is_done", [&"spring"], false) == true, "срыв пружиной — совет пружины снят")


# ── 5. Галочка ───────────────────────────────────────────────────────────────

func _test_toggle() -> void:
	print("— галочка «Подсказки»")
	_fresh()
	var on_default = settings_script.call("hints_enabled") if settings_script.has_method("hints_enabled") \
		else null
	_check(on_default == true, "по умолчанию подсказки ВКЛ")
	_set_hints(false)
	var c := _column(0)
	_man(c)
	var law := _still_foe(c.seg_center(0) + c.dir * 40.0, "lawyer")
	law.law_read_t = 1.0
	_scan()
	_check(int(_ic("hints_shown", [&"q"], -1)) == 0 and float(_ic("slot_glow", [0], 1.0)) == 0.0,
		"выключено — подписи и пульса нет")
	_check(_ic("is_gold", [c, 0], false) == true, "золото — не совет, видно и так")
	_set_hints(true)
	_scan()
	_check(int(_ic("hints_shown", [&"q"], 0)) == 1, "включили — подпись вернулась")


# ── 6. Стена ─────────────────────────────────────────────────────────────────

func _test_wall() -> void:
	print("— штрих в стене")
	_fresh()
	# глубоко в скале: у самой кромки (ближе LINE_BEGIN_SNAP) штрих начинается на кромке (B-092)
	var rock := Vector2.INF
	var deep := LegionCfg.LINE_BEGIN_SNAP + 4.0
	for x in range(0, 1280, 16):
		for y in range(0, 720, 16):
			var p := Vector2(x, y)
			if rock != Vector2.INF or not w.terrain.is_rock(p):
				continue
			var inner := true
			for k in 16:
				if not w.terrain.is_rock(p + Vector2.from_angle(TAU * k / 16.0) * deep):
					inner = false
			if inner:
				rock = p
	_check(rock != Vector2.INF, "на карте _gray есть скала")
	var n0 := int(w.contracts.get("wall_bumps") if w.contracts.get("wall_bumps") != null else -1)
	w.contracts.begin(rock)
	_check(not w.contracts.has_draft(), "в скале штрих не начат")
	var n1 := int(w.contracts.get("wall_bumps") if w.contracts.get("wall_bumps") != null else -1)
	_check(n0 == 0 and n1 == 1, "вспышка «стена» (%d → %d)" % [n0, n1])
	w.contracts.begin(rock)
	_check(int(w.contracts.get("wall_bumps") if w.contracts.get("wall_bumps") != null else -1) == 1,
		"вторая попытка сразу — без новой вспышки")
	OS.delay_msec(int(float(_cfg("WALL_GAP", 1.0)) * 1000.0) + 60)
	w.contracts.begin(rock)
	_check(int(w.contracts.get("wall_bumps") if w.contracts.get("wall_bumps") != null else -1) == 2,
		"через секунду — снова")


# ── 7. Пустая часть черновика ────────────────────────────────────────────────

func _empty_len() -> float:
	var runs = _fc("draft_empty_runs", [], null)
	if runs == null:
		return -1.0
	var s := 0.0
	for r: Vector2 in runs:
		s += r.y - r.x
	return s


func _draw_draft(a: Vector2, b: Vector2) -> void:
	var f := w.contracts
	w.grid.rebuild()   # сетка мира — от прошлой проверки (шага не было), раздача спрашивает её
	f.cancel()
	f.begin(a)
	for p in _line(a, b, 6.0):
		f.extend(p)
	f.update_preview()


func _test_draft_empty() -> void:
	print("— пустая часть черновика")
	_fresh()
	var a := Vector2(1060, 330)
	var b := Vector2(1060, 530)
	_draw_draft(a, b)
	var total := w.contracts._draft_len
	var e0 := _empty_len()
	_check(e0 > total * 0.8, "бойцов нет — пусто почти всё (%.0f из %.0f)" % [e0, total])
	for i in 3:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, a + Vector2(-40, 10 + i * 6))
		u.set_free()
	_draw_draft(a, b)
	var e1 := _empty_len()
	_check(e1 > 0.0 and e1 < e0, "трое у начала — пустой только хвост (%.0f)" % e1)
	for i in 30:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, a + Vector2(-40, 20 + i * 6))
		u.set_free()
	_draw_draft(a, b)
	_check(_empty_len() == 0.0, "людей хватает — пустых отрезков нет")
	w.contracts.cancel()


# ── Замер скана ──────────────────────────────────────────────────────────────

func _test_perf() -> void:
	print("— замер скана")
	_fresh()
	for i in 6:
		_man(_column(float(i) * 100.0 - 60.0) if i < 5 else _column(520))
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 80:
		_still_foe(Vector2(rng.randf_range(700, 1200), rng.randf_range(60, 680)))
	var t0 := Time.get_ticks_usec()
	for i in 50:
		_scan()
	var us := float(Time.get_ticks_usec() - t0) / 50.0
	print("  скан: %.0f мкс (80 врагов, %d договоров)" % [us, w.contracts.contracts.size()])
	_check(_intuit() != null and us < 2000.0, "скан дешёвый: %.0f мкс раз в 0,1 с" % us)
	# D-0927-53: приманки рядом включают проход пути натиска — худший случай, 8 приманок у строя
	for i in 8:
		_still_foe(Vector2(rng.randf_range(700, 900), rng.randf_range(60, 680)),
			"signer" if i % 2 == 0 else "ghost")
	t0 = Time.get_ticks_usec()
	for i in 50:
		_scan()
	var us2 := float(Time.get_ticks_usec() - t0) / 50.0
	print("  скан с приманками: %.0f мкс (88 врагов, из них 8 приманок)" % us2)
	_check(_intuit() != null and us2 < 2000.0, "скан с приманками дешёвый: %.0f мкс" % us2)


# ── 8. Бот ───────────────────────────────────────────────────────────────────

func _bot_digest(map_id: String, seed: int, steps: int) -> String:
	Settings.scheme_override = ""
	w.dev = {"difficulty": "intern"}
	w.dev_invuln = false
	w.args["bot"] = "selective"
	w._base_seed = seed
	w.start_map(map_id)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for i in steps:
		w._step(1.0 / 60.0)
		if i % 6 == 0:
			_scan()   # скан подсказок не должен ничего трогать в бою
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
	print("— бот: бой побайтно прежний")
	var ref: Dictionary = {}
	var f := FileAccess.open(BOT_REF, FileAccess.READ)
	if f != null:
		for line in f.get_as_text().split("\n", false):
			var parts := line.strip_edges().split(" ")
			if parts.size() == 4:
				ref["%s %s %s" % [parts[0], parts[1], parts[2]]] = parts[3]
	for run: Array in BOT_RUNS:
		var t0 := Time.get_ticks_msec()
		var d := _bot_digest(run[0], run[1], run[2])
		var key := "%s %d %d" % [run[0], run[1], run[2]]
		print("  BOTREF %s %s  (%d мс)" % [key, d, Time.get_ticks_msec() - t0])
		_check(ref.get(key, "") == d, "бот %s: трасса совпала с эталоном economy-mana" % key)
