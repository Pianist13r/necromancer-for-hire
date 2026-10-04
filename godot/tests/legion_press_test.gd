extends SceneTree
##
## Регресс «Давки» и «Пружины» (медленная сессия 28c77608, 26.09.2026; Игорь: «самая
## эффективная стратегия — рисовать прямо на дороге… и постройки вываливают бойцов на дорогу»).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_press_test.gd -- --mute
##
## «Два отдела», северная дорога (вертикаль x = 340 от y = 160 до 290): линия подряда поперёк
## дороги на y = 230, стрелкой на север. До правки стена держала любую колонну, пока жива:
## проверки «колонна прошла» на старом коде падают. Урона нет (invuln) — меряем саму давку,
## а не размен ударами.
## Итог «LEGION PRESS: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_press_test.cfg"
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
	w.set_process(false)
	_test_small_group_held()
	_test_column_breaks_through()
	_test_guard_holds_more()
	_test_spring()
	_test_spawn_off_road()
	Campaign.reset()
	print("LEGION PRESS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Стена подряда поперёк северной дороги «Двух отделов»; n бойцов вида kind у линии.
func _wall(kind: StringName, n_units: int) -> Contract:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	# v19 «стены по рисунку»: ограды «Двух отделов» (x ≈ 302 и y ≈ 265) легли ровно туда, где
	# эта сцена ставит стену и бойцов. Давку меряем на земле карты без стен: стены проверяет
	# tests/legion_walls_test.gd, а числа этой сцены подобраны под открытую землю.
	var bare := w.map.duplicate(true)
	bare.erase("walls")
	w.terrain = LegionTerrain.new().setup(bare)
	w.dev_invuln = true
	for i in n_units:
		w.spawn_unit(kind, Vector2(300.0 + 8.0 * float(i % 10), 262.0 + 6.0 * float(i / 10)))
	var pts := PackedVector2Array([Vector2(290, 230), Vector2(390, 230)])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false, kind)
	c.set_dir(Vector2.UP)
	c.ttl = 9999.0
	for step in roundi(4.0 / DT):
		w._step(DT)
	return c


## Колонна зомби по дороге сверху: n штук, шаг 18 px, начиная с y = 150.
func _column(n: int, type := "zombie") -> Array[Foe]:
	var path := PackedVector2Array([Vector2(340, 160), Vector2(340, 290), Vector2(180, 360)])
	var out: Array[Foe] = []
	for i in n:
		var at := Vector2(340.0 + (6.0 if i % 2 == 0 else -6.0), 150.0 - 18.0 * float(i))
		var f := w.spawn_foe_on_path(type, path, at)
		if f != null:
			out.append(f)
	return out


func _posted(c: Contract) -> int:
	var n := 0
	for p in c.posts:
		if not p["dead"] and p["unit"] != null \
				and (p["unit"] as Legionnaire).state == Legionnaire.State.POSTED:
			n += 1
	return n


func _passed(foes: Array[Foe]) -> int:
	var n := 0
	for f in foes:
		if f.position.y > 262.0 or f.position.x < 300.0:
			n += 1
	return n


func _stat(key: String) -> int:
	return int(w.stats.get(key, 0))


func _test_small_group_held() -> void:
	print("— три зомби: стена держит, как раньше")
	var c := _wall(LegionCfg.KIND_LABORER, 14)
	var men := _posted(c)
	_check(men >= 10, "в строю не меньше 10: %d" % men)
	var foes := _column(3)
	for step in roundi(20.0 / DT):
		w._step(DT)
	print("  (прорывов %d, прошло %d)" % [_stat("press_breaks"), _passed(foes)])
	_check(_stat("press_breaks") == 0, "прорывов нет")
	_check(_passed(foes) == 0, "никто не прошёл линию")


func _test_column_breaks_through() -> void:
	print("— колонна из 16 зомби продавливает участок подряда")
	var c := _wall(LegionCfg.KIND_LABORER, 14)
	var foes := _column(16)
	var t_break := -1.0
	var max_bend := 0.0
	var t := 0.0
	for step in roundi(30.0 / DT):
		w._step(DT)
		t += DT
		for s in c.seg_count():
			if "seg_bend" in c:
				max_bend = maxf(max_bend, float(c.seg_bend[s]))
		if t_break < 0.0 and _stat("press_breaks") > 0:
			t_break = t
	print("  (прорыв на %.1f с, наибольший прогиб %.1f px, прошло %d)" % [t_break, max_bend,
		_passed(foes)])
	_check(_stat("press_breaks") >= 1, "участок прорван")
	_check(t_break > 0.0 and t_break <= 20.0, "прорыв не позже 20 с: %.1f" % t_break)
	_check(_passed(foes) >= 4, "в дыру прошли хотя бы 4: %d" % _passed(foes))


func _test_guard_holds_more() -> void:
	print("— охрана держит семерых там, где подряд прогибается")
	var c := _wall(LegionCfg.KIND_GUARD, 14)
	var foes := _column(7)
	for step in roundi(20.0 / DT):
		w._step(DT)
	print("  (охрана: в строю %d, прорывов %d, прошло %d)" % [_posted(c), _stat("press_breaks"),
		_passed(foes)])
	_check(_stat("press_breaks") == 0, "охрану не прорвали")
	_check(_passed(foes) == 0, "через охрану никто не прошёл")


func _test_spring() -> void:
	print("— пружина: выпуск прогнутого участка бьёт сильнее")
	var c := _wall(LegionCfg.KIND_LABORER, 14)
	var foes := _column(16)
	var bent_seg := -1
	for step in roundi(20.0 / DT):
		w._step(DT)
		for s in c.seg_count():
			if c.seg_alive(s) and c.bend_frac(s) >= 0.5:
				bent_seg = s
		if bent_seg >= 0:
			break
	_check(bent_seg >= 0, "участок прогнулся хотя бы наполовину")
	if bent_seg < 0:
		return
	w.dev_invuln = false     # урон натиска нужен: иначе «задел» не увидеть по HP
	var got := {"bend": -1.0}
	var cb := func(_c: Contract, _s: int, bend: float) -> void: got["bend"] = bend
	w.spring_released.connect(cb)
	w.release_segment(c, bent_seg, &"manual")
	w.spring_released.disconnect(cb)
	_check(_stat("spring_releases") == 1, "выпуск засчитан пружиной")
	_check(float(got["bend"]) >= 0.5, "сила пружины — прогиб участка: %.2f" % float(got["bend"]))
	_check(c.seg_bend[bent_seg] == 0.0, "прогиб выпущенного участка обнулён")
	var hit := 0
	for step in roundi(1.5 / DT):
		w._step(DT)
	for f in foes:
		if f.hp < f.max_hp:
			hit += 1
	_check(hit >= 1, "натиск пружины кого-то задел: %d" % hit)


## Расстояние до оси ближайшей дороги — своё, не из игры: проверка работает и на старом коде.
func _road_dist(p: Vector2) -> float:
	var best := INF
	for r in w.map.get("roads", []):
		var path: Array = r.get("path", [])
		for i in range(1, path.size()):
			var a := Vector2(float(path[i - 1][0]), float(path[i - 1][1]))
			var b := Vector2(float(path[i][0]), float(path[i][1]))
			best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


func _test_spawn_off_road() -> void:
	print("— постройки рождают бойцов не на дороге (все площадки всех карт)")
	var worst := INF
	var worst_at := ""
	for map_id in ["wasteland", "fork", "bridge", "maze", "swamp", "boss"]:
		w.dev["no_waves"] = "1"
		w.dev["spawn_units"] = "0"
		w.start_map(map_id)
		for plot: Dictionary in w.staff.plots:
			var b := w.staff._make(LegionCfg.KIND_LABORER, LegionBuilding.SOURCE_PLOT,
				plot["pos"], null)
			for k in 60:
				var p: Vector2 = b._spawn_point()
				var d := _road_dist(p)
				if d < worst:
					worst = d
					worst_at = "%s %s" % [map_id, plot["id"]]
				if not w.terrain.walkable(p):
					worst = -1.0
					worst_at = "%s %s — непроходимая точка %s" % [map_id, plot["id"], p]
	print("  (ближе всех к дороге: %.1f px — %s)" % [worst, worst_at])
	_check(worst >= 34.0, "ни одного рождения ближе 34 px к оси дороги: %.1f (%s)" % [worst,
		worst_at])
