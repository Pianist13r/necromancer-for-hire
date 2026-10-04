extends SceneTree
##
## Регресс «обороны дома» (B-281, B-293, B-343; ветка slow/home-guard, 30.09.2026).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_home_guard_test.gd -- --mute
##
## Свободные бойцы стояли и у своего Котла: одиночный враг доходил до Котла сквозь толпу
## свободных, а в «Схватке» чужие бойцы снимали Котёл, пока свои стояли дома. Теперь свободный
## идёт на врага в зоне дома (HOME_GUARD_R у Котла своей стороны), если тот не дальше
## HOME_GUARD_PURSUE; вне зоны — стоит, как раньше (D-0925-09).
## 1) одиночка: свободные в 60–100 px от Котла по другую сторону от врага — враг убит, Котёл цел;
## 2) враг вне зоны дома: свободный рядом с ним не двигается (а флаг стороны поднят другим врагом);
## 3) «Схватка»: чужие бойцы бьют Котёл стороны 0, свои свободные дома идут и бьют их.
## Итог «LEGION HOME GUARD: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_home_guard_test.cfg"
const DT := 1.0 / 60.0

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


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	_test_single_leaker()
	_test_outside_zone()
	_test_pvp_raid()
	Campaign.reset()
	print("LEGION HOME GUARD: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Одиночная карта без волн и без стартовых бойцов.
func _fresh_single() -> void:
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.dev_invuln = false
	w._base_seed = 7
	w.start_map("_plots")


## Число «обороны дома» из LegionCfg по имени: тест гоняется и на коде до правки (доказать, что
## он там падает), где этих констант нет, — тогда берутся значения ветки slow/home-guard.
func _cfg(key: String) -> float:
	var fallback := {"HOME_GUARD_R": 150.0, "HOME_GUARD_PURSUE": 120.0}
	var cfg := load("res://scripts/legion/legion_cfg.gd") as Script
	return float(cfg.get_script_constant_map().get(key, fallback[key]))


func _steps(n: int) -> void:
	for i in n:
		if w.phase != LegionWorld.Phase.BATTLE:
			return
		w._step(DT)


## Точка c + off, сдвинутая к ближайшей проходимой вдоль off (у Котла бывают скалы и вода).
func _walkable_near(c: Vector2, off: Vector2) -> Vector2:
	for k in 20:
		var p := c + off * (1.0 + 0.05 * k)
		if w.terrain.walkable(p):
			return p
	return c + off


func _test_single_leaker() -> void:
	print("— одиночка: враг идёт к Котлу, свободные дома на флангах")
	_fresh_single()
	var c := w.cauldron_pos
	var hp0 := w.cauldron_hp
	var army: Array[Legionnaire] = []
	# шестеро свободных на флангах Котла (север и юг), 60–100 px: враг идёт с востока прямо к
	# Котлу, в их досягаемость сам не попадает — прежний код их не двигал. (С тыла Котла, в
	# 100 px за ним, враг у края Котла дальше HOME_GUARD_PURSUE — так задумано: идут ближние.)
	for i in 6:
		var ang := deg_to_rad((-110.0 if i < 3 else 70.0) + 20.0 * (i % 3))
		var p := _walkable_near(c, Vector2.from_angle(ang) * (60.0 + 8.0 * i))
		army.append(w.spawn_unit(LegionCfg.KIND_LABORER, p))
	# Котёл у западного края карты — враг приходит с востока
	var start := _walkable_near(c, Vector2(200, 0))
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([start, c]), start)
	_check(f != null and army.size() == 6, "враг и шестеро свободных на месте (Котёл %s)" % str(c))
	if f == null:
		return
	var moved := false
	var zz_on_runner := false
	var before: Array[Vector2] = []
	for u in army:
		before.append(u.position)
	for i in roundi(12.0 / DT):
		w._step(DT)
		for k in army.size():
			var u := army[k]
			if u.alive and u._moving:
				moved = true
				if u.idle_time >= LegionCfg.IDLE_NOTICE_TIME:
					zz_on_runner = true
		if not f.alive:
			break
	_check(moved, "свободные пошли на врага в зоне дома")
	_check(not zz_on_runner, "у бегущего на врага нет «Zz» (idle_time сброшен)")
	_check(not f.alive and f.visible, "враг убит бойцами, а не исчез в Котле")
	_check(is_equal_approx(w.cauldron_hp, hp0), "Котёл цел: %.1f из %.1f" % [w.cauldron_hp, hp0])
	var still := 0
	for k in army.size():
		still += int(army[k].position.distance_to(before[k]) < 0.5)
	print("  стояли на месте: %d из %d" % [still, army.size()])


func _test_outside_zone() -> void:
	print("— враг вне зоны дома: свободный рядом стоит")
	_fresh_single()
	var c := w.cauldron_pos
	# враг вне зоны: 230 px от Котла, идёт от Котла прочь — из зоны не выйдет в неё за время теста
	var far := _walkable_near(c, Vector2(0, -230))
	if far.y < 20.0:
		far = _walkable_near(c, Vector2(0, 230))
	var away := far + (far - c).normalized() * 200.0
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([far, away]), far)
	# боец в 70 px от врага (не в досягаемости, но ближе HOME_GUARD_PURSUE) и не дальше
	# HOME_GUARD_R + HOME_GUARD_PURSUE от Котла — отсекает его только проверка зоны
	var side_off := Vector2(70, 0)
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, far + side_off)
	# второй враг — В зоне, по другую сторону Котла (дальше HOME_GUARD_PURSUE от бойца): флаг
	# стороны поднят, и поиск бойца действительно выполняется
	var inner := _walkable_near(c, (c - far).normalized() * 110.0)
	var f2 := w.spawn_foe_on_path("zombie", PackedVector2Array([inner, c]), inner)
	_check(f != null and f2 != null and u != null, "враги и боец на месте")
	if f == null or f2 == null or u == null:
		return
	_check(u.position.distance_to(c) < _cfg("HOME_GUARD_R") + _cfg("HOME_GUARD_PURSUE"),
		"боец в пределах поиска от Котла: %d px" % roundi(u.position.distance_to(c)))
	var p0 := u.position
	var flag_seen := false
	var max_shift := 0.0
	for i in roundi(1.0 / DT):
		w._step(DT)
		# через call: тот же тест гоняется и на коде до правки (там флага нет — проверка упадёт)
		flag_seen = flag_seen or (w.has_method("home_threat") and bool(w.call("home_threat", 0)))
		max_shift = maxf(max_shift, u.position.distance_to(p0))
	_check(flag_seen, "флаг «враг в зоне дома» стороны 0 поднят вторым врагом")
	_check(f.position.distance_to(c) > _cfg("HOME_GUARD_R"), "первый враг всё время вне зоны")
	_check(max_shift < 0.5, "свободный рядом с врагом вне зоны не двинулся: сдвиг %.2f px" % max_shift)


func _test_pvp_raid() -> void:
	print("— «Схватка»: чужие бойцы у Котла, свои свободные дома")
	w.dev = {"spawn_units": "0", "pvp_nobot": "1", "no_waves": "1"}
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 7
	w.start_map("pvp:duel")
	_check(w.pvp and w.sides.size() == 2, "матч двух сторон")
	if not w.pvp or w.sides.size() < 2:
		return
	var c0 := w.cauldron_of(0)
	var c1 := w.cauldron_of(1)
	var toward := (c1 - c0).normalized()
	var hp0 := w.sides[0].cauldron_hp
	var raiders: Array[Legionnaire] = []
	# восемь чужих у бока Котла со стороны противника — Котёл в их досягаемости
	for i in 8:
		var off := toward.rotated(deg_to_rad(-60.0 + 17.0 * i)) * 55.0
		raiders.append(w.spawn_unit(LegionCfg.KIND_LABORER, _walkable_near(c0, off), null, 1))
	# двенадцать своих свободных по другую сторону Котла, 90–110 px: чужих в досягаемости нет
	var home: Array[Legionnaire] = []
	for i in 12:
		var off := (-toward).rotated(deg_to_rad(-55.0 + 10.0 * i)) * (90.0 + 2.0 * (i % 10))
		home.append(w.spawn_unit(LegionCfg.KIND_LABORER, _walkable_near(c0, off), null, 0))
	var before: Array[Vector2] = []
	for u in home:
		before.append(u.position)
	_steps(roundi(8.0 / DT))
	var dmg := hp0 - w.sides[0].cauldron_hp
	var raiders_alive := 0
	for u in raiders:
		raiders_alive += int(u.alive)
	var went := 0
	for k in home.size():
		went += int(home[k].position.distance_to(before[k]) > 5.0)
	print("  урон Котлу стороны 0 за 8 с: %.1f из %.1f; чужих живо %d/8; своих сдвинулось %d/12"
		% [dmg, hp0, raiders_alive, went])
	_check(went >= 6, "свои свободные пошли на чужих у Котла: %d/12" % went)
	_check(raiders_alive == 0, "чужие у Котла перебиты: живо %d/8" % raiders_alive)
	_check(w.sides[0].cauldron_hp > 0.0 and w.phase == LegionWorld.Phase.BATTLE,
		"Котёл стороны 0 устоял, матч идёт")
