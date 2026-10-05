extends SceneTree
##
## Самопроверка фундамента v15 (пакет f0, docs/legion/DESIGN_V15.md §1, §4, §11, §12 п.5):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_v15_api_test.gd -- --mute
##
## Итог «LEGION V15 API: N/M OK»; код выхода 1, если что-то упало. Мир настоящий (карта _gray,
## без волн и стартовой армии), проверки — через публичный API, который читают пакеты
## core/staff/hero/meta. Сохранение кампании — только во временный файл.
##

const SAVE := "user://legion_v15_api_test.cfg"
## Полоса карты _gray между рекой (x 620–706) и скалой (x 870+), вдали от Котла — место опытов.
const LAB := Vector2(760, 120)

var w: LegionWorld
var _fails := 0
var _checks := 0
var _died: Array = []
var _taps: Array[Vector2] = []
var _kinds: Array[StringName] = []


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


func _line(a: Vector2, b: Vector2, step := 8.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in n + 1:
		pts.append(a.lerp(b, float(i) / n))
	return pts


func _run() -> void:
	# первым делом: настоящий user://legion.cfg владельца не трогаем
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	_fresh()
	_test_kinds_spawn()
	await _test_clerk_projectile()
	await _test_clerk_ghost()
	_test_guard_armor()
	await _test_charge_dir()
	_test_assign_by_kind()
	_test_field_kind()
	_test_tap_arbitration()
	_test_campaign_stat()
	Campaign.reset()
	print("LEGION V15 API: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Чистая карта: без волн и без армии у Котла — в опытах только то, что поставил тест.
func _fresh() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


## Встать бойцом вида договора на каждое пустое место (как тест ядра, но с видом).
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


func _still_foe(type: String, at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at]), at)
	f.speed = 0.0
	return f


func _test_kinds_spawn() -> void:
	w.unit_died.connect(func(u: Legionnaire) -> void: _died.append(u))
	var home := RefCounted.new()
	var ok := true
	for kind: StringName in LegionCfg.KIND_ORDER:
		var spec: Dictionary = LegionCfg.UNIT_KINDS[kind]
		var u := w.spawn_unit(kind, LAB + Vector2(0, 300), home)
		ok = ok and u.kind == kind and is_equal_approx(u.hp, float(spec["hp"])) \
			and u.spec == spec and u.home == home
		u.take_damage(1000.0, u.position + Vector2.RIGHT)
	_check(ok, "spawn_unit рождает три вида со своими числами и хозяином")
	var lab: Dictionary = LegionCfg.UNIT_KINDS[LegionCfg.KIND_LABORER]
	_check(is_equal_approx(float(lab["hp"]), LegionCfg.UNIT_HP)
			and is_equal_approx(float(lab["dmg"]), LegionCfg.UNIT_DMG)
			and is_equal_approx(float(lab["period"]), LegionCfg.UNIT_ATK_CD)
			and is_equal_approx(float(lab["charge_dist"]), LegionCfg.CHARGE_DIST),
		"подрядчик — ровно прежние числа ядра")
	var g: Dictionary = LegionCfg.UNIT_KINDS[LegionCfg.KIND_GUARD]
	var c: Dictionary = LegionCfg.UNIT_KINDS[LegionCfg.KIND_CLERK]
	_check(float(g["hp"]) == 60.0 and float(g["front_armor"]) == 0.5
			and float(g["charge_dist"]) == 100.0
			and float(c["reach"]) == 150.0 and bool(c["ranged"]) and bool(c["hits_ghosts"])
			and float(c["charge_dist"]) == 120.0,
		"числа вахтёра и счетовода по DESIGN §1")
	_check(_died.size() == 3 and (_died[0] as Legionnaire).home == home,
		"unit_died несёт бойца (с хозяином) — для штата")
	var u2 := w.spawn_unit(&"nobody", LAB)
	_check(u2.kind == LegionCfg.KIND_LABORER, "неизвестный вид — подрядчик")
	u2.take_damage(1000.0, LAB)


func _test_clerk_projectile() -> void:
	_fresh()
	var clerk := w.spawn_unit(LegionCfg.KIND_CLERK, LAB)
	var zombie := _still_foe("zombie", LAB + Vector2(140, 0))
	var hp0 := zombie.hp
	var flying := 0
	for i in 60:
		await process_frame
		flying = maxi(flying, w.projectiles.shots.size())
	var dmg := float(LegionCfg.UNIT_KINDS[LegionCfg.KIND_CLERK]["dmg"])
	_check(flying > 0, "счетовод стреляет снарядом (в полёте было %d)" % flying)
	_check(zombie.hp <= hp0 - dmg + 0.01,
		"снаряд попал в зомби на 140 px (HP %.0f → %.0f)" % [hp0, zombie.hp])
	_check(clerk.position.distance_to(LAB) < 2.0, "счетовод стреляет с места, а не бежит в рукопашную")
	zombie.take_damage(1000.0, LAB)
	clerk.take_damage(1000.0, LAB)


func _test_clerk_ghost() -> void:
	_fresh()
	var f := w.contracts
	var cc := f.add_contract(_line(LAB, LAB + Vector2(0, 80)), 1, false, LegionCfg.KIND_CLERK)
	_man(cc)
	var ghost := _still_foe("ghost", LAB + Vector2(100, 40))
	var lc := f.add_contract(_line(LAB + Vector2(0, 300), LAB + Vector2(0, 380)), 1, false)
	_man(lc)
	var ghost2 := _still_foe("ghost", LAB + Vector2(30, 340))
	var hp0 := ghost.hp
	var hp2 := ghost2.hp
	# залп восьми счетоводов убивает призрака быстрее, чем уберут труп (CORPSE_TIME 1,2 с)
	await _frames(45)
	var hit := not is_instance_valid(ghost) or ghost.hp < hp0
	_check(hit, "счетовод из строя бьёт призрака")
	_check(is_instance_valid(ghost2) and ghost2.hp == hp2,
		"строевой подрядчик призрака по-прежнему не бьёт")
	if is_instance_valid(ghost2):
		ghost2.take_damage(1000.0, LAB)


func _test_guard_armor() -> void:
	_fresh()
	var f := w.contracts
	var gc := f.add_contract(_line(LAB, LAB + Vector2(0, 80)), 1, false, LegionCfg.KIND_GUARD)
	var lc := f.add_contract(_line(LAB + Vector2(0, 300), LAB + Vector2(0, 380)), 1, false)
	var guard := _man(gc)[0]
	var lab := _man(lc)[0]
	_check(gc.kind == LegionCfg.KIND_GUARD and guard.kind == LegionCfg.KIND_GUARD,
		"договор охраны и вахтёр")
	var front := guard.position + gc.dir * 20.0
	guard.take_damage(10.0, front)
	_check(is_equal_approx(guard.hp, 60.0 - 5.0),
		"вахтёр в строю спереди получает ×0,5 (HP %.1f)" % guard.hp)
	guard.take_damage(10.0, guard.position - gc.dir * 20.0)
	_check(is_equal_approx(guard.hp, 45.0), "вахтёр сзади получает полный урон")
	lab.take_damage(10.0, lab.position + lc.dir * 20.0)
	_check(is_equal_approx(lab.hp, 30.0 - 7.0), "подрядчик спереди — прежние ×0,7")


## Натиск идёт по единой стрелке договора даже на изогнутой линии и после переворота.
func _test_charge_dir() -> void:
	_fresh()
	var f := w.contracts
	# уголок: вниз, потом вправо — локальные нормали участков разные, стрелка одна
	var bent := _line(LAB, LAB + Vector2(0, 96))
	bent.append_array(_line(LAB + Vector2(0, 96), LAB + Vector2(96, 96)).slice(1))
	var c := f.add_contract(bent, 1, false)
	_check(c != null and c.dir.is_normalized(), "у договора одна единичная стрелка dir")
	if c == null:
		return
	var chord := (bent[bent.size() - 1] - bent[0]).normalized()
	_check(absf(c.dir.dot(chord)) < 0.01, "по умолчанию стрелка перпендикулярна хорде")
	var squad := _man(c)
	var before := {}
	for u in squad:
		before[u] = u.position
	for s in c.seg_count():
		f.release(c, s)
	await _frames(30)
	var ok := squad.size() > 0
	for u in squad:
		var d: Vector2 = u.position - before[u]
		ok = ok and d.length() > 10.0 and d.normalized().dot(c.dir) > 0.95
	_check(ok, "натиск всех участков изогнутой линии идёт по dir (%d бойцов)" % squad.size())
	f.tick(0.0, w.now)
	var c2 := f.add_contract(_line(LAB + Vector2(0, 300), LAB + Vector2(0, 400)), 1, false)
	var old := c2.dir
	c2.flip_dir()
	_check(c2.dir.is_equal_approx(-old) and (c2.posts[0]["normal"] as Vector2).is_equal_approx(-old),
		"flip_dir переворачивает стрелку и места")
	var squad2 := _man(c2)
	var p0 := squad2[0].position
	f.release(c2, int(squad2[0].post["seg"]))
	await _frames(30)
	_check((squad2[0].position - p0).normalized().dot(c2.dir) > 0.95,
		"после переворота натиск по новой dir")


func _test_assign_by_kind() -> void:
	_fresh()
	var f := w.contracts
	var lc := f.add_contract(_line(LAB, LAB + Vector2(0, 80)), 1, false)
	var guard := w.spawn_unit(LegionCfg.KIND_GUARD, LAB + Vector2(-20, 40))
	w.grid.rebuild()
	w._assign_free()
	_check(guard.state == Legionnaire.State.FREE and lc.manned_posts() == 0,
		"свободный вахтёр не встаёт на договор подряда")
	var gc := f.add_contract(_line(LAB + Vector2(0, 300), LAB + Vector2(0, 380)), 1, false,
		LegionCfg.KIND_GUARD)
	# v15 core: договор не тянет вахтёра с 300 px, подводим в радиус нового рубежа.
	guard.position = LAB + Vector2(-20, 320)
	var lab := w.spawn_unit(LegionCfg.KIND_LABORER, LAB + Vector2(-20, 60))
	w.grid.rebuild()
	w._assign_free()
	_check(guard.state == Legionnaire.State.MARCH and guard.contract == gc,
		"вахтёр набран договором охраны")
	_check(lab.state == Legionnaire.State.MARCH and lab.contract == lc,
		"подрядчик набран договором подряда")


## Клавиши 1/2/3, цена по виду, цвет и вид черновика.
func _test_field_kind() -> void:
	_fresh()
	var f := w.contracts
	f.kind_changed.connect(func(k: StringName) -> void: _kinds.append(k))
	_key(KEY_2)
	_check(f.current_kind == LegionCfg.KIND_GUARD and _kinds == [LegionCfg.KIND_GUARD],
		"клавиша 2 — договор охраны, сигнал kind_changed")
	_key(KEY_3)
	f.mana = f.mana_max
	var m0 := f.mana
	# шаг узлов 7 px: ближе POINT_STEP (6) поле узел пропускает, и длина штриха была бы меньше
	var pts := _line(LAB, LAB + Vector2(0, 100), 7.0)
	f.begin(pts[0])
	for i in range(1, pts.size()):
		f.extend(pts[i])
	var spent := m0 - f.mana
	f.finish()
	var c: Contract = f.contracts[f.contracts.size() - 1] if not f.contracts.is_empty() else null
	_check(c != null and c.kind == LegionCfg.KIND_CLERK, "штрих при виде 3 — договор аудита")
	_check(is_equal_approx(spent, 100.0 * 0.16), "цена аудита 0,16 за px (списано %.2f)" % spent)
	if c != null:
		var n := int(c.length / 20.0) * 2
		_check(c.posts.size() == n, "шаг мест аудита 20 px: %d мест" % c.posts.size())
	_check(not f.set_kind(&"nobody") and f.current_kind == LegionCfg.KIND_CLERK,
		"неизвестный вид не выбрать")
	_key(KEY_1)
	var bot := f.add_contract(_line(LAB + Vector2(200, 0), LAB + Vector2(200, 100)), 1, true)
	_check(bot != null and bot.kind == LegionCfg.KIND_LABORER, "API бота по умолчанию ставит подряд")


func _key(code: Key) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.pressed = true
	w.contracts._unhandled_input(k)


func _mouse(at: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = at
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	w.contracts._unhandled_input(ev)


func _move(at: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = at
	w.contracts._unhandled_input(mv)


## DESIGN_V15 §12 п.5: клик < 8 px — tap, протяжка — рисование от точки нажатия.
func _test_tap_arbitration() -> void:
	_fresh()
	var f := w.contracts
	f.tap.connect(func(p: Vector2) -> void: _taps.append(p))
	var p := LAB + Vector2(100, 200)
	var m0 := f.mana
	var n0 := f.contracts.size()
	_mouse(p, true)
	_move(p + Vector2(3, 2))
	_move(p + Vector2(5, -4))
	_check(not f.has_draft(), "до 8 px черновика нет")
	_mouse(p + Vector2(5, -4), false)
	_check(_taps.size() == 1 and _taps[0] == p, "короткий клик даёт tap(точка нажатия)")
	_check(f.mana == m0 and f.contracts.size() == n0, "tap не тратит ману и не создаёт договор")
	_mouse(p, true)
	for i in range(1, 11):
		_move(p + Vector2(3.0 * i, 0))
	_check(f.has_draft() and f._draft[0] == p and f._draft_len > 25.0,
		"протяжка 30 px — черновик от точки нажатия (длина %.0f)" % f._draft_len)
	_check(f.mana < m0, "мана списывается только после порога")
	_mouse(p + Vector2(30, 0), false)
	_check(_taps.size() == 1 and is_equal_approx(f.mana, m0),
		"короткий штрих вернул ману, tap не было")
	f.press_consumer = func(at: Vector2) -> bool: return at.distance_to(p) < 50.0
	_mouse(p, true)
	for i in range(1, 11):
		_move(p + Vector2(0, 6.0 * i))
	_mouse(p + Vector2(0, 60), false)
	_check(_taps.size() == 1 and not f.has_draft() and f.mana == m0,
		"press_consumer поглощает нажатие: ни tap, ни рисования")
	_mouse(p + Vector2(200, 0), true)
	_mouse(p + Vector2(200, 0), false)
	_check(_taps.size() == 2, "нажатие мимо потребителя снова даёт tap")
	f.press_consumer = Callable()


func _test_campaign_stat() -> void:
	Campaign.reset()
	var neutral := true
	for key: StringName in [&"cap_mult_guard", &"respawn_mult_clerk", &"charge_dmg_mult",
			&"production_mult"]:
		neutral = neutral and Campaign.stat(key) == 1.0
	for key: StringName in [&"recruit_r_laborer", &"seg_ttl_bonus_guard", &"mana_max_bonus",
			&"mana_regen_bonus", &"start_souls", &"ability_rank_q", &"perk_fast_hire", &"army_cap_bonus"]:
		neutral = neutral and Campaign.stat(key) == 0.0
	_check(neutral, "Campaign.stat по умолчанию нейтрален (множители 1, прибавки 0)")
	# A1: прокачка — 12 карточек поправок AmendmentDb (рогалик), старого пула мелких процентов
	# нет. Свод модов карточек — MetaMods: ключ-множитель ∏(1+v), прибавочный Σv.
	Campaign.add_upgrade(&"golden_exit")   # натиск +60 %
	Campaign.add_upgrade(&"bulk_ink")      # цена договора −35 %, набор −60 шагов
	var taken := Campaign.upgrades()
	_check(taken.size() == 2 and taken.has(&"golden_exit") and taken.has(&"bulk_ink"),
		"карточки поправок ложатся в договор (%s)" % [taken])
	_check(is_equal_approx(Campaign.stat(&"charge_dmg_mult"), 1.6)
			and is_equal_approx(Campaign.stat(&"mana_cost_mult"), 0.65)
			and is_equal_approx(Campaign.stat(&"recruit_r_guard"), -60.0),
		"поправки видны через stat (×1,6 натиска, ×0,65 цены договора, −60 набора)")
	# E-1005: второй источник того же ключа-множителя не складывается, а перемножается (0,65 × 1,25).
	_check(is_equal_approx(Campaign.stat(&"mana_cost_mult", [0.25]), 0.8125),
		"stat сводит дополнительный источник тем же правилом (×0,65 · ×1,25)")
