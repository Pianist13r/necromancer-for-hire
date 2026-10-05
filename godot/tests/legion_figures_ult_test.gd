# gdlint: disable=max-file-lines
extends SceneTree
##
## Регресс независимого ревью J по фигурам (05.10.2026), находки J1, J4, J5, J11.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_figures_ult_test.gd -- --mute
##
## J1 — бафф второго отряда остаётся без снятия: пока защита «Каре» A жива, «Каре» B выпускает
##      свой отряд. Запись баффа одна на вид, поэтому отряд B обязан попасть в неё и потерять
##      защиту вместе с A по общему таймеру, а не носить множитель до конца боя.
## J4 — заряд считается готовым после потери нужного угла: поле обнуляет charge_t только на своём
##      тике, поэтому в том же шаге (после смерти участника) строй ещё «заряжен».
## J5 — самотаявшие «Комиссии» имеют одну метку группы: melt передавал общий id 0, и метка одной
##      фигуры усиливала бойцов другой.
## J11 — счётчик групп залпа переживает сброс мира: у двух сетевых клиентов с разной историей
##      кампании одинаковые команды давали разные id групп и разные снимки.
##
## Новые поля читаются через get(): на прежнем коде тест не падает разбором, а проваливает
## проверки. Итог «LEGION FIGURES ULT: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_figures_ult_test.cfg"
const FIG_CFG_PATH := "res://scripts/legion/figure_cfg.gd"
const FC := Vector2(1130.0, 405.0)
const DT := 1.0 / 60.0

var w: LegionWorld
var fcfg: Script = null
var _fails := 0
var _checks := 0


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
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	if ResourceLoader.exists(FIG_CFG_PATH):
		fcfg = load(FIG_CFG_PATH)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.set_process(false)
	_test_guard_two_squads()
	_test_charge_lost_corner()
	_test_melt_groups()
	Campaign.reset()
	print("LEGION FIGURES ULT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Сцена ────────────────────────────────────────────────────────────────────

func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


func _cfg(key: String, fallback: Variant) -> Variant:
	return fcfg.get_script_constant_map().get(key, fallback) if fcfg != null else fallback


func _steps(sec: float) -> void:
	for i in roundi(sec / DT):
		w._step(DT)


func _charge_secs() -> float:
	return float(_cfg("CHARGE_TIME", 1.5))


func _last() -> Contract:
	var cs := w.contracts.contracts
	return cs[cs.size() - 1] if not cs.is_empty() else null


func _fig_of(c: Contract) -> StringName:
	return c.figure if c != null else &""


func _make_fig(fig: StringName, pts: PackedVector2Array) -> Contract:
	var n := w.contracts.contracts.size()
	w.contracts.call("_create", pts, 1, LegionCfg.KIND_LABORER, false, fig)
	var c := _last() if w.contracts.contracts.size() > n else null
	return c if _fig_of(c) == fig else null


func _man(c: Contract, frac := 1.0) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if p["unit"] != null or p["dead"]:
			continue
		if float(out.size()) >= frac * c.posts.size():
			break
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _melt_all(c: Contract) -> void:
	for s in c.seg_count():
		if c.seg_alive(s):
			c.seg_age[s] = c.ttl - 0.01
	w.contracts.tick(0.05, w.now)


func _ngon(c: Vector2, n: int, r: float, rot := 0.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in n:
		out.append(c + Vector2.from_angle(rot + TAU * i / n) * r)
	return out


func _rect(c: Vector2, wd: float, ht: float, rot := 0.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for v: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		out.append(c + (v * Vector2(wd, ht) * 0.5).rotated(rot))
	return out


## Замкнутый контур: вершины плюс возврат к первой — так чертит рука и так читает ContractShape.
func _loop(corners: Array[Vector2]) -> Array[Vector2]:
	var out := corners.duplicate()
	out.append(corners[0])
	return out


## Ломаная с шагом ~6 px (как штрих мыши) — этой же плотностью меряет ContractShape.
func _dense(pts: Array[Vector2]) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, ceili(a.distance_to(b) / 6.0))
		for k in range(1, n + 1):
			out.append(a.lerp(b, float(k) / n))
	return out


func _sq() -> Contract:
	return _make_fig(&"square", _dense(_loop(_rect(FC, 120, 120, 0.1))))


func _tri() -> Contract:
	return _make_fig(&"triangle", _dense(_loop(_ngon(FC, 3, 80, -PI * 0.5 + 0.1))))


func _penta() -> Contract:
	return _make_fig(&"pentagon", _dense(_loop(_ngon(FC, 5, 85, -PI * 0.5))))


# ── J1: бафф второго отряда ──────────────────────────────────────────────────

func _test_guard_two_squads() -> void:
	print("— J1: защита «Каре» у ВТОРОГО отряда")
	_fresh()
	var c1 := _sq()
	if c1 == null:
		_check(false, "первый квадрат собран")
		return
	var sq1 := _man(c1)
	_steps(_charge_secs() + 0.1)
	_check(c1.charge_ready(), "первый квадрат заряжен")
	w.contracts.release(c1, 0)
	var guard := float(_cfg("SQUARE_GUARD_MULT", 0.75))
	var guarded1 := true
	for u in sq1:
		guarded1 = guarded1 and u.alive and float(u.get("guard_dmg_mult")) < 1.0
	_check(guarded1, "первый отряд под защитой (×%.2f)" % guard)
	# пока защита первого жива, второй квадрат выпускает свой отряд
	var c2 := _sq()
	if c2 == null:
		_check(false, "второй квадрат собран")
		return
	var sq2 := _man(c2)
	_steps(_charge_secs() + 0.1)
	_check(c2.charge_ready(), "второй квадрат заряжен")
	w.contracts.release(c2, 0)
	var guarded2 := true
	for u in sq2:
		guarded2 = guarded2 and u.alive and float(u.get("guard_dmg_mult")) < 1.0
	_check(guarded2, "второй отряд тоже получил защиту")
	# общий таймер истёк — множитель обязан уйти у ОБОИХ отрядов
	_steps(float(_cfg("SQUARE_GUARD_T", 3.0)) + 0.5)
	var left1 := _mult_above_one(sq1)
	var left2 := _mult_above_one(sq2)
	_check(left1 == 0 and left2 == 0,
		"срок защиты снят с обоих отрядов (осталось %d и %d бойцов с множителем)" % [left1, left2])


func _mult_above_one(units: Array[Legionnaire]) -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and absf(float(u.get("guard_dmg_mult")) - 1.0) > 0.001:
			n += 1
	return n


# ── J4: заряд при потере угла ────────────────────────────────────────────────

func _test_charge_lost_corner() -> void:
	print("— J4: готовность заряда при потере угла в том же шаге")
	_fresh()
	var c := _tri()
	if c == null:
		_check(false, "треугольник собран")
		return
	_man(c, 0.66)
	_steps(_charge_secs() + 0.1)
	_check(c.charge_ready(), "строй дождался заряда")
	var u: Legionnaire = c.posts[0]["unit"]
	_check(u != null and c.posted_posts() >= c.charge_need(),
		"порог держится (%d из %d)" % [c.posted_posts(), c.charge_need()])
	# угол убит ПОСЛЕ поля и ДО ручного выпуска: между этими моментами поле не тикает
	u.take_damage(99999.0, u.position + Vector2(5.0, 0.0))
	_check(c.posted_posts() < c.charge_need(),
		"угол потерян в том же шаге (%d из %d)" % [c.posted_posts(), c.charge_need()])
	_check(not c.charge_ready(), "готовность снята сразу, без ожидания тика поля")


# ── J5 и J11: группы залпа ───────────────────────────────────────────────────

func _test_melt_groups() -> void:
	print("— J5/J11: группы залпа самотаяния")
	_fresh()
	var c1 := _penta()
	if c1 == null:
		_check(false, "первая «Комиссия» собрана")
		return
	_man(c1)
	_steps(_charge_secs() + 0.1)
	var serial0 := int(w.figures.get("_ult_serial"))
	_melt_all(c1)
	var serial1 := int(w.figures.get("_ult_serial"))
	_check(serial1 > serial0, "самотаяние заняло свою группу залпа (J5): %d→%d" % [serial0, serial1])
	var c2 := _penta()
	if c2 == null:
		_check(false, "вторая «Комиссия» собрана")
		return
	_man(c2)
	_steps(_charge_secs() + 0.1)
	_melt_all(c2)
	var serial2 := int(w.figures.get("_ult_serial"))
	_check(serial2 > serial1,
		"вторая «Комиссия» не делит группу с первой (J5): %d→%d" % [serial1, serial2])
	w.figures.reset()
	_check(int(w.figures.get("_ult_serial")) == 0,
		"сброс мира обнуляет счётчик групп залпа (J11)")
