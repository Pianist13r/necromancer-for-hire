extends SceneTree
##
## Регресс вербовки (медленная сессия 26.09.2026, d3296a1b): кто занимает места договора.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_recruit_test.gd -- --mute
##
## 1) никого не бросает: дальний боец, у которого одно-два достижимых места, получает место,
##    даже если их заняли соседи с выбором (старый порядок «по появлению» и жадный «ближние
##    первыми» оставляли его свободным при пустых местах рядом у соседей);
## 2) ближние к линии — первыми: линия у стопки берёт стопку, а не группу с дороги в 120 px
##    (партия «Развилка» по переписке, ход 45; старый порядок брал тех, кто появился раньше);
## 3) плотная армия: 180 бойцов у шести линий — все на местах, раздача детерминирована
##    (сцена verifier C:\AI\necro\batches\corr\verifier-probes\probe_stuck.gd);
## 4) вышедший из линии (расторжение участка или таяние) не возвращается на места ТОЙ же
##    линии сам — идёт к другой; постороннего новичка та же линия берёт, как прежде
##    (просьба Игоря 29.09.2026; расторжение и таяние — один путь кода, проверены оба повода).
## Итог «LEGION RECRUIT: N/M OK»; код выхода 1, если что-то упало. Карта _plots, кампания
## нейтральная, сохранение временное.
##

const SAVE := "user://legion_recruit_test.cfg"

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
	_test_no_one_left()
	_test_nearest_first()
	_test_dense_army()
	_test_no_return_own_line()
	Campaign.reset()
	print("LEGION RECRUIT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_plots")


func _line(a: Vector2, b: Vector2) -> Contract:
	var pts := PackedVector2Array([a, b])
	return w.contracts.add_contract(pts, w.contracts.default_side(pts), false)


func _open_posts(c: Contract) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in c.posts:
		if not p["dead"] and p["unit"] == null:
			out.append(p)
	return out


func _planned(plan: Array[Dictionary]) -> Dictionary:
	var out := {}
	for a in plan:
		out[a["unit"]] = a
	return out


func _test_no_one_left() -> void:
	print("— никого не бросает")
	_fresh()
	var c := _line(Vector2(330, 300), Vector2(560, 300))
	_check(c != null, "линия поставлена")
	if c == null:
		return
	var radius := float(w.contracts.recruit_r[LegionCfg.KIND_LABORER])
	var far_at := Vector2(140, 300)
	var reach: Array[Dictionary] = []
	for p in _open_posts(c):
		if far_at.distance_to(p["pos"]) <= radius:
			reach.append(p)
	var total := _open_posts(c).size()
	_check(not reach.is_empty() and reach.size() < total,
		"сцена осмысленна: дальнему достижимы %d мест из %d" % [reach.size(), total])
	# соседи появились раньше и стоят прямо на местах дальнего — у каждого есть и другие места
	for p in reach:
		w.spawn_unit(LegionCfg.KIND_LABORER, p["pos"])
	var far := w.spawn_unit(LegionCfg.KIND_LABORER, far_at)
	w.grid.rebuild()
	var plan := w.contracts.assignment_plan(w.contracts.contracts)
	var by := _planned(plan)
	_check(plan.size() == reach.size() + 1,
		"на местах все: %d из %d" % [plan.size(), reach.size() + 1])
	_check(by.has(far), "дальний получил место")
	if by.has(far):
		var a: Dictionary = by[far]
		_check(far.position.distance_to((a["post"] as Dictionary)["pos"]) <= radius,
			"место дальнего — в его радиусе")
		_check(not (a["path"] as PackedVector2Array).is_empty(), "у дальнего есть маршрут")
	var keys := {}
	for a in plan:
		keys[a["post"]] = true
	_check(keys.size() == plan.size(), "одно место — один боец")
	w._assign_free()
	_check(far.state == Legionnaire.State.MARCH, "дальний идёт на место")


func _test_nearest_first() -> void:
	print("— ближние к линии — первыми")
	_fresh()
	var c := _line(Vector2(300, 250), Vector2(370, 250))
	_check(c != null, "короткая линия поставлена")
	if c == null:
		return
	var posts := _open_posts(c)
	var n := posts.size()
	_check(n >= 4, "мест у линии: %d" % n)
	# группа с дороги появилась раньше и стоит в 120 px, стопка — у самой линии
	var road: Array[Legionnaire] = []
	for i in n:
		road.append(w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(290 + i * 8, 370)))
	var stack: Array[Legionnaire] = []
	for p in posts:
		stack.append(w.spawn_unit(LegionCfg.KIND_LABORER, (p["pos"] as Vector2) + Vector2(0, 3)))
	w.grid.rebuild()
	var by := _planned(w.contracts.assignment_plan(w.contracts.contracts))
	var got_stack := 0
	for u in stack:
		if by.has(u):
			got_stack += 1
	var got_road := 0
	for u in road:
		if by.has(u):
			got_road += 1
	_check(got_stack == n, "стопка у линии на местах: %d из %d" % [got_stack, n])
	_check(got_road == 0, "с дороги не сдёрнуты: %d" % got_road)


func _test_dense_army() -> void:
	print("— плотная армия у шести линий")
	_fresh()
	for i in 6:
		var y := 150.0 + i * 60.0
		_line(Vector2(150, y), Vector2(560, y))
	var n := 0
	for i in 400:
		var p := Vector2(160 + (i % 25) * 16, 140 + (i / 25) * 22)
		if w.terrain.walkable(p) and n < 180:
			w.spawn_unit(LegionCfg.KIND_LABORER, p)
			n += 1
	w.grid.rebuild()
	var t := Time.get_ticks_usec()
	var plan := w.contracts.assignment_plan(w.contracts.contracts)
	var cost := Time.get_ticks_usec() - t
	var plan2 := w.contracts.assignment_plan(w.contracts.contracts)
	var same := plan2.size() == plan.size()
	for i in mini(plan.size(), plan2.size()):
		same = same and plan[i]["unit"] == plan2[i]["unit"] and plan[i]["key"] == plan2[i]["key"]
	print("  (раздача: %d бойцов, %d мс)" % [n, cost / 1000])
	_check(n == 180, "бойцов 180")
	_check(plan.size() == n, "на местах все: %d из %d" % [plan.size(), n])
	_check(same, "раздача детерминирована")
	w._assign_free()
	var free := 0
	for u in w.units:
		if u.alive and u.state == Legionnaire.State.FREE:
			free += 1
	_check(free == 0, "после раздачи свободных нет: %d" % free)


## Вышедший из линии не возвращается на места той же линии (расторжение и таяние), но идёт
## к другой; посторонний новичок ту же линию набирает, как прежде.
func _test_no_return_own_line() -> void:
	print("— вышедшие из линии не возвращаются на неё")
	_fresh()
	var a := _line(Vector2(330, 280), Vector2(640, 280))
	var b := _line(Vector2(330, 430), Vector2(640, 430))
	_check(a != null and b != null, "две линии поставлены")
	if a == null or b == null:
		return
	_check(a.seg_count() >= 2, "у линии несколько участков: %d" % a.seg_count())
	# отряд стоит на участке 0 первой линии
	var squad: Array[Legionnaire] = []
	for p in a.posts:
		if int(p["seg"]) != 0:
			continue
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, p["pos"])
		u.assign(a, p)
		u._arrive()
		squad.append(u)
	_check(squad.size() >= 2, "отряд на участке: %d бойцов" % squad.size())
	# игрок запустил участок: натиск окончен, боец свободен у самой линии
	w.release_segment(a, 0, &"manual")
	var freed := 0
	var remembers := 0
	for u in squad:
		u._end_charge()
		if u.state == Legionnaire.State.FREE:
			freed += 1
		if u.no_return_id == a.id:
			remembers += 1
	_check(freed == squad.size(), "запущенный отряд свободен: %d из %d" % [freed, squad.size()])
	_check(remembers == squad.size(),
		"отряд помнит линию, из которой вышел: %d из %d" % [remembers, squad.size()])
	# посторонний новичок у той же линии — контроль, что линия по-прежнему набирает
	var rookie := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(340, 250))
	w.grid.rebuild()
	var by := _planned(w.contracts.assignment_plan(w.contracts.contracts))
	var back := 0
	var other := 0
	for u in squad:
		if not by.has(u):
			continue
		if by[u]["contract"] == a:
			back += 1
		else:
			other += 1
	_check(back == 0, "на прежнюю линию никто не вернулся: %d" % back)
	_check(other == squad.size(), "к другой линии пошли все: %d из %d" % [other, squad.size()])
	_check(by.has(rookie) and by[rookie]["contract"] == a,
		"новичка прежняя линия берёт, как прежде")
	w._assign_free()
	var marching := 0
	for u in squad:
		if u.state == Legionnaire.State.MARCH and u.contract == b:
			marching += 1
	_check(marching == squad.size(), "раздача отправила отряд на другую линию: %d из %d"
		% [marching, squad.size()])
	# тот же выход по времени (таяние): боец с растаявшего участка — не на ту же линию
	var melters: Array[Legionnaire] = []
	for p in a.posts:
		if int(p["seg"]) != 1 or p["unit"] != null:
			continue
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, p["pos"])
		u.assign(a, p)
		u._arrive()
		melters.append(u)
	_check(melters.size() >= 2, "второй отряд на соседнем участке: %d бойцов" % melters.size())
	w.release_segment(a, 1, &"melt")
	for u in melters:
		u._end_charge()
	w.grid.rebuild()
	var by2 := _planned(w.contracts.assignment_plan(w.contracts.contracts))
	var melt_back := 0
	var melt_other := 0
	for u in melters:
		if not by2.has(u):
			continue
		if by2[u]["contract"] == a:
			melt_back += 1
		else:
			melt_other += 1
	_check(melt_back == 0, "после таяния на ту же линию не вернулись: %d" % melt_back)
	_check(melt_other == melters.size(), "растаявшие пошли к другой линии: %d из %d"
		% [melt_other, melters.size()])
