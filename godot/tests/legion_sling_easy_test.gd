extends SceneTree
##
## Рогатка «сила полная сразу» (Игорь 26.09: «механика с натяжением не очень удобная… за край
## экрана не всегда можно сильно тянуть»). Умение — только МОМЕНТ отпускания, длина оттяжки
## не важна. Проверки — НАСТОЯЩИМИ событиями мыши (Input.parse_input_event в координатах окна).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_sling_easy_test.gd -- --mute
##
## Итог «LEGION SLING EASY: N/M OK»; код выхода 1, если что-то упало. Схема управления — только в
## памяти (Settings.scheme_override), сохранение кампании — во временный файл.
##

const SAVE := "user://legion_sling_easy_test.cfg"
## Полоса карты _gray между рекой и скалой, вдали от Котла (как в legion_sling_test).
const LAB := Vector2(760, 120)
const DEVICE := 7
## Короткая оттяжка — «чуть-чуть потянул» (ориентир решения координатора ~30 px).
const SHORT := 30.0
## Полная оттяжка старой схемы (SLING_MAX был 140).
const LONG := 140.0
## Сдвиг больше TAP_SLOP, но меньше порога взвода — ещё щелчок.
const DEAD := 16.0
## Центр и радиус кольца (как в legion_ring_test).
const RC := Vector2(790.0, 112.0)
const RR := 55.0

var w: LegionWorld
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


func _line(a: Vector2, b: Vector2, step := 8.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in n + 1:
		pts.append(a.lerp(b, float(i) / n))
	return pts


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


func _button(p: Vector2, button: MouseButton, pressed: bool, settle_frames := 1) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(settle_frames)


## Натяжка рукой: ПКМ в from, ведём по кадру к to, НЕ отпускаем.
func _pull(from: Vector2, to: Vector2, steps := 6) -> void:
	await _move(from, 0)
	await _button(from, MOUSE_BUTTON_RIGHT, true)
	for i in range(1, steps + 1):
		await _move(from.lerp(to, float(i) / steps))


func _shoot(from: Vector2, to: Vector2, settle_frames := 1) -> void:
	await _pull(from, to)
	await _button(to, MOUSE_BUTTON_RIGHT, false, settle_frames)


func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


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


func _seg_units(squad: Array[Legionnaire], seg: int) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in squad:
		if u.state == Legionnaire.State.POSTED and int(u.post["seg"]) == seg:
			out.append(u)
	return out


func _still_foe(at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = f.hp
	return f


## Договор-столбик: два участка по 64 px, стрелка по умолчанию — от Котла (+x).
func _column(y0: float) -> Contract:
	return w.contracts.add_contract(_line(LAB + Vector2(0, y0), LAB + Vector2(0, y0 + 128)), 1, false)


## Все бойцы группы бегут по dir с полной силой рогатки (множители — верх SLING_*).
func _full_charge(units: Array[Legionnaire], dir: Vector2) -> bool:
	var ok := not units.is_empty()
	for u in units:
		ok = ok and u.state == Legionnaire.State.CHARGE and u._charge_dir.dot(dir) > 0.99 \
			and is_equal_approx(float(u._volley["power"]), 1.0) \
			and is_equal_approx(float(u._volley["range"]), LegionCfg.SLING_RANGE.y) \
			and is_equal_approx(float(u._volley["dmg"]), LegionCfg.SLING_DMG.y) \
			and is_equal_approx(float(u._volley["speed"]), LegionCfg.SLING_SPEED.y)
	return ok


func _hint() -> String:
	var f := w.contracts
	return str(f.call("sling_hint")) if f.has_method("sling_hint") else "<нет sling_hint>"


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	await _test_short_equals_long()
	await _test_click_and_dead_band()
	await _test_moment()
	await _test_edge()
	await _test_ring()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION SLING EASY: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Короткая оттяжка (30 px) даёт ровно ту же силу, что старая полная (140 px).
func _test_short_equals_long() -> void:
	print("— короткая оттяжка = полная")
	_fresh()
	var c := _column(0)
	var squad := _man(c)
	var seg0 := _seg_units(squad, 0)
	var seg1 := _seg_units(squad, 1)
	var back := -c.dir
	await _pull(c.seg_center(0), c.seg_center(0) + back * SHORT)
	_check(w.contracts.is_slinging(), "30 px — натяжка")
	_check(is_equal_approx(float(w.contracts.sling_aim().get("power", 0.0)), 1.0),
		"сила при 30 px — полная (%.2f)" % float(w.contracts.sling_aim().get("power", 0.0)))
	await _button(c.seg_center(0) + back * SHORT, MOUSE_BUTTON_RIGHT, false)
	_check(_full_charge(seg0, c.dir), "30 px: натиск с полной силой (%d бойцов)" % seg0.size())
	var short_v: Dictionary = seg0[0]._volley.duplicate() if not seg0.is_empty() else {}
	await _shoot(c.seg_center(1), c.seg_center(1) + back * LONG)
	_check(_full_charge(seg1, c.dir), "140 px: натиск с полной силой (%d бойцов)" % seg1.size())
	var long_v: Dictionary = seg1[0]._volley.duplicate() if not seg1.is_empty() else {}
	var same := not short_v.is_empty() and not long_v.is_empty()
	for k in ["power", "range", "dmg", "speed"]:
		same = same and is_equal_approx(float(short_v.get(k, -1.0)), float(long_v.get(k, -2.0)))
	_check(same, "залп 30 px и 140 px одинаков: %s / %s" % [short_v, long_v])
	_check(int(w.stats.get("sling_releases", 0)) == 2, "оба срыва — рогаткой")


## Щелчок (дрожь < TAP_SLOP) — прежний роспуск; недотянутый порог — тоже щелчок, не слабый выстрел.
func _test_click_and_dead_band() -> void:
	print("— щелчок и недотяг")
	_fresh()
	var c := _column(0)
	var squad := _man(c)
	var seg0 := _seg_units(squad, 0)
	var seg1 := _seg_units(squad, 1)
	var at := c.seg_center(0)
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _move(at + Vector2(3, 2))
	await _button(at + Vector2(3, 2), MOUSE_BUTTON_RIGHT, false)
	var ok := not seg0.is_empty()
	for u in seg0:
		ok = ok and u.state == Legionnaire.State.CHARGE and u._charge_dir.is_equal_approx(c.dir) \
			and is_equal_approx(float(u._volley["range"]), 1.0) and not bool(u._volley["perfect"])
	_check(ok, "щелчок: роспуск по стрелке договора, множители 1.0")
	# 16 px назад-вбок: старый код стрелял «слабой рогаткой» против оттяжки
	var at1 := c.seg_center(1)
	var d := Vector2(-DEAD * 0.6, DEAD * 0.8)
	await _pull(at1, at1 + d, 3)
	_check(not w.contracts.is_slinging(), "16 px — ещё не натяжка (ниже порога взвода)")
	await _button(at1 + d, MOUSE_BUTTON_RIGHT, false)
	# B-071 (slow/intuit, координатор 26.09): недотянул до взвода — отмена, а не роспуск по
	# стрелке договора (отряд уходил не туда, куда тянули)
	ok = not seg1.is_empty() and c.seg_alive(1)
	for u in seg1:
		ok = ok and u.state == Legionnaire.State.POSTED
	_check(ok, "недотянул 16 px — отмена: участок жив, строй на местах")
	_check(int(w.stats.get("sling_releases", 0)) == 0 and int(w.stats["releases_manual"]) == 1,
		"выпуск один — щелчок, короткая оттяжка ничего не сорвала")


## «Точно!» решает МОМЕНТ: с той же короткой оттяжкой враг вне зоны — не золото, вошёл — золото.
func _test_moment() -> void:
	print("— момент отпускания")
	_fresh()
	var c := _column(0)
	_man(c)
	var foe := _still_foe(c.seg_center(0) + c.dir * 150.0)
	var at := c.seg_center(0)
	var to := at - c.dir * SHORT
	await _pull(at, to)
	await _frames(1)
	_check(not bool(w.contracts.sling_aim().get("perfect", true)), "враг в 150 px — зона не золотая")
	_check(_hint() == "Жди врага в зоне", "подпись «ждать»: «%s»" % _hint())
	foe.position = c.seg_center(0) + c.dir * 80.0
	await _frames(2)
	_check(bool(w.contracts.sling_aim().get("perfect", false)),
		"враг вошёл в зону (80 px) при той же оттяжке 30 px — золото")
	_check(_hint() == "Срывай!", "подпись «Срывай!»: «%s»" % _hint())
	await _button(to, MOUSE_BUTTON_RIGHT, false)
	_check(int(w.stats.get("perfect_releases", 0)) == 1, "отпустил в золото — «Точно!»")
	# тот же жест, враг ещё вне зоны — обычный срыв
	_still_foe(c.seg_center(1) + c.dir * 150.0)
	await _shoot(c.seg_center(1), c.seg_center(1) - c.dir * SHORT)
	_check(int(w.stats.get("perfect_releases", 0)) == 1 and int(w.stats.get("sling_releases", 0)) == 2,
		"отпустил рано — срыв без «Точно!»")


## Участок у верхнего края экрана: к краю курсору тянуть некуда (упёрся в y = 0) — выстрел всё
## равно полный, вниз; от края — полный, к краю.
func _test_edge() -> void:
	print("— у края экрана")
	_fresh()
	var c := w.contracts.add_contract(_line(Vector2(700, 16), Vector2(828, 16)), 1, false)
	_check(c != null, "договор у верхнего края")
	if c == null:
		return
	var squad := _man(c)
	var seg0 := _seg_units(squad, 0)
	var seg1 := _seg_units(squad, 1)
	var at := c.seg_center(0)
	var pinned := Vector2(at.x + 3.0, 0.0)   # курсор упёрся в край: оттяжка всего ~16 px
	await _pull(at, pinned)
	_check(w.contracts.is_slinging(), "упёрся в край после %.0f px — натяжка есть" % at.distance_to(pinned))
	var aim := w.contracts.sling_aim()
	var want := -(pinned - at).normalized()
	_check(is_equal_approx(float(aim.get("power", 0.0)), 1.0) and want.y > 0.9,
		"сила полная, стрелка от края (вниз): %s" % aim.get("dir"))
	await _button(pinned, MOUSE_BUTTON_RIGHT, false)
	_check(_full_charge(seg0, want), "у края: натиск вниз с полной силой (%d)" % seg0.size())
	# от края — к краю: обычная короткая оттяжка вниз
	var at1 := c.seg_center(1)
	# Ввод синхронен: проверяем залп до тика, который остановит крайних у границы карты.
	await _shoot(at1, at1 + Vector2(0, SHORT), 0)
	_check(_full_charge(seg1, Vector2.UP), "от края: натиск к краю (вверх) с полной силой (%d)" % seg1.size())
	await _frames(1)
	# за краем окна (чёрные полосы / окно меньше экрана) — то же самое
	_fresh()
	var c2 := w.contracts.add_contract(_line(Vector2(700, 16), Vector2(828, 16)), 1, false)
	var s2 := _seg_units(_man(c2), 0)
	var at2 := c2.seg_center(0)
	await _shoot(at2, Vector2(at2.x, -4.0))
	_check(_full_charge(s2, Vector2.DOWN), "курсор за краем окна (y = −4): полный натиск вниз")


## «Оцепление»: короткая натяжка по кольцу сжимает ВСЁ кольцо с полной силой.
func _test_ring() -> void:
	print("— кольцо")
	_fresh()
	var pts := PackedVector2Array()
	var n := 60
	for i in n + 1:
		var a := -2.2 + (TAU - 0.3) * float(i) / n
		pts.append(RC + Vector2(cos(a), sin(a)) * RR)
	await _move(pts[0], 0)
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for i in range(1, pts.size()):
		await _move(pts[i], MOUSE_BUTTON_MASK_LEFT)
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	var cs := w.contracts.contracts
	var c: Contract = cs[cs.size() - 1] if not cs.is_empty() else null
	_check(c != null and c.ring, "кольцо начерчено")
	if c == null or not c.ring:
		return
	var squad := _man(c)
	for s in [0, 2, 4]:
		_still_foe(c.seg_center(s).lerp(c.center, 0.45))
	var at := c.seg_center(1)
	var away := (at - c.center).normalized()
	# Проверяем залп до тика: ближайшие бойцы уже могут ударить и остановиться.
	await _shoot(at, at + away * SHORT, 0)
	var alive := 0
	for s in c.seg_count():
		if c.seg_alive(s):
			alive += 1
	_check(alive == 0, "30 px по кольцу сорвали всё кольцо")
	var ok := not squad.is_empty()
	for u in squad:
		ok = ok and u.state == Legionnaire.State.CHARGE \
			and u._charge_dir.dot((c.center - u.position).normalized()) > 0.8 \
			and is_equal_approx(float(u._volley.get("range", 0.0)), LegionCfg.SLING_RANGE.y) \
			and bool(u._volley.get("perfect", false))
	_check(ok, "все %d к центру, полная сила (дальность ×%.1f), «Точно!»" % [squad.size(),
		LegionCfg.SLING_RANGE.y])
	_check(int(w.stats.get("sling_releases", 0)) == 1, "рогатка по кольцу посчитана один раз")
	await _frames(1)
