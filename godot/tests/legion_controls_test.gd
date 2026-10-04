extends SceneTree
##
## Регресс управления v18 (медленная сессия 28c77608, 26.09.2026; Игорь: «кнопки на клавиатуре
## можно более удобные подобрать… прокрутку колёсика можно, нажатие колёсика — нет… может,
## управление для дополнительной механики замутишь»).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_controls_test.gd -- --mute
##
## R — «Сбор»: свободные бойцы в круге бегут к курсору (раньше R перезапускал бой — на старом
## коде проверки сбора падают: карта сброшена, бойцов нет). Колесо — вид договора по кругу.
## Итог «LEGION CONTROLS: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_controls_test.cfg"
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
	_test_rally()
	_test_rally_timeout_in_fight()
	_test_rally_aim_cut_and_pause()
	_test_rally_same_side()
	_test_rally_on_rock()
	_test_rally_promise_fuzz()
	_test_wheel()
	Campaign.reset()
	print("LEGION CONTROLS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _mouse(at: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	w._input(m)


func _key(code: Key) -> void:
	_key_state(code, true)
	_key_state(code, false)


## v19 (B-038): «Сбор» — на отпускание R, пока зажата — круг и отметки.
func _key_state(code: Key, pressed: bool) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.pressed = pressed
	w._unhandled_input(k)


func _count_near(at: Vector2, r: float) -> int:
	var n := 0
	for u in w.units:
		if u.alive and u.position.distance_to(at) <= r:
			n += 1
	return n


func _test_rally() -> void:
	print("— R: свободные в круге бегут к курсору, дальние остаются")
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("wasteland")
	var near: Array[Legionnaire] = []
	for i in 6:
		# v19: (520..570, 560) — скала на рисунке «Пустыря», стала непроходимой; кучка — на земле
		near.append(w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(640.0 + 10.0 * i, 600.0)))
	var far := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(1000, 600))
	var far_at := far.position
	var target := Vector2(620, 470)
	_check(target.distance_to(Vector2(665, 600)) < LegionCfg.RALLY_R \
		and target.distance_to(far_at) > LegionCfg.RALLY_R, "раскладка: шестеро в круге, один вне")
	_mouse(target)
	# v19 (B-038): R зажата — круг и счёт, никто ещё не бежит; отпустил — «Сбор»
	_key_state(KEY_R, true)
	var held := 0
	for u in near:
		if u.state == Legionnaire.State.RALLY:
			held += 1
	var pv := w.rally_preview(target)
	_check(w.rally_aiming and held == 0, "R зажата: круг, на сбор никто не пошёл (%d)" % held)
	_check((pv["reach"] as Array).size() == 6 and (pv["cut"] as Array).is_empty(),
		"круг считает шестерых, отрезанных нет: %d" % (pv["reach"] as Array).size())
	_key_state(KEY_R, false)
	_check(not w.rally_aiming, "R отпущена — круг погас")
	_check(w.phase == LegionWorld.Phase.BATTLE and w.units.size() >= 7,
		"R не перезапускает бой (бойцы на месте): %d" % w.units.size())
	var rallying := 0
	for u in near:
		if u.state == Legionnaire.State.RALLY:
			rallying += 1
	_check(rallying == 6, "все шестеро пошли на сбор: %d" % rallying)
	_check(w.rally(target) == -1, "повторный сбор сразу — откат")
	# дошёл — подошёл к курсору на свою точку подсолнуха (≤ 20 px) хоть раз; потом кучку
	# раздвигает расталкивание свободных (legion_grid): кто пришёл раньше, того толкают
	# пришедшие позже, а свободный на место не возвращается. v19: сцену перенесли со скалы,
	# и на сетке 16 px пути A* другие — порядок прихода сменился, крайнего вытолкнуло на 38 px
	# (замер d26f8623: с CELL 32 та же ветка даёт ровно числа master, максимум 26 px; одиночный
	# боец на сетке 16 не медленнее — путь 148 px против 160). Прежний порог «все ≤ 32 px»
	# мерил порядок прихода, а не «Сбор»; вместо него — дошёл каждый, кучка рядом (≤ 48 px)
	# и её середина у курсора (≤ 24 px — радиус подсолнуха шестерых с запасом).
	var closest: Array[float] = []
	closest.resize(near.size())
	closest.fill(INF)
	for step in roundi(6.0 / DT):
		w._step(DT)
		for k in near.size():
			closest[k] = minf(closest[k], near[k].position.distance_to(target))
	var arrived := 0
	for k in near.size():
		var u := near[k]
		if closest[k] <= 24.0 and u.position.distance_to(target) <= 48.0 \
				and u.state == Legionnaire.State.FREE:
			arrived += 1
	_check(arrived == 6, "дошли к курсору (≤ 24 px) и снова свободны рядом (≤ 48 px): %d" % arrived)
	var mid := Vector2.ZERO
	for u in near:
		mid += u.position / float(near.size())
	_check(mid.distance_to(target) <= 24.0, "середина кучки у курсора: %.1f px" % mid.distance_to(target))
	_check(far.position.distance_to(far_at) < 1.0, "дальний не тронут")
	var stack := 0
	for i in near.size():
		for j in range(i + 1, near.size()):
			if near[i].position.distance_to(near[j].position) < 2.0:
				stack += 1
	_check(stack == 0, "встали подсолнухом, не стопкой: совпавших пар %d" % stack)
	_check(w.rally_left() <= 0.0, "откат прошёл за 6 с")
	print("— сбор без свободных рядом: откат не тратится")
	_check(w.rally(Vector2(200, 100)) == 0 and w.rally_left() == 0.0,
		"некого звать — 0, откат не начат")


## v19 (B-038): круг «Сбора» отличает тех, кто дойдёт, от отрезанных оградой; пауза гасит круг,
## и отпускание R после неё сбора не делает.
func _test_rally_aim_cut_and_pause() -> void:
	print("— круг «Сбора»: отрезанный оградой — серый; пауза гасит круг")
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	var inside := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(450, 660))   # поле за оградой
	var outside := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(450, 560))
	var at := Vector2(450, 575)
	_mouse(at)
	_key_state(KEY_R, true)
	var pv := w.rally_preview(at)
	_check((pv["reach"] as Array).has(outside) and (pv["cut"] as Array).has(inside),
		"снаружи — дойдёт, за оградой — отрезан")
	_key_state(KEY_R, false)
	_check(outside.state == Legionnaire.State.RALLY and inside.state == Legionnaire.State.FREE,
		"побежал только тот, кто дойдёт")
	for step in roundi((LegionCfg.RALLY_CD + 0.5) / DT):
		w._step(DT)
	_key_state(KEY_R, true)
	w.set_paused(true)
	_check(not w.rally_aiming, "пауза гасит круг")
	w.set_paused(false)
	_key_state(KEY_R, false)
	_check(w.rally_left() == 0.0, "отпускание R после паузы сбора не делает")


## v19: «Сбор» у стены — точки подсолнуха не уходят за неё. До правки у правой стены загородки
## «Развилки» (курсор в 6 px от стены, тридцать бойцов) точки 21, 26, 29 ложились за стену на
## проходимую землю, и бойцов слали в обход загородки на ту сторону.
func _test_rally_same_side() -> void:
	print("— «Сбор» у стены: кучка по эту сторону")
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	var at := Vector2(505, 360)
	var squad: Array[Legionnaire] = []
	var ground := true
	for k in 30:
		var p := Vector2(420.0 + 16.0 * (k % 6), 300.0 + 24.0 * floorf(k / 6.0))
		ground = ground and w.terrain.walkable(p)
		squad.append(w.spawn_unit(LegionCfg.KIND_LABORER, p))
	_check(ground and w.terrain.walkable(at), "раскладка: тридцать бойцов и курсор внутри загородки")
	var promised := (w.rally_preview(at)["reach"] as Array).size()
	var n := w.rally(at)
	var across := 0
	for u in squad:
		if u.state == Legionnaire.State.RALLY and u._path[u._path.size() - 1].x >= 512.0:
			across += 1
	_check(n == 30 and promised == n, "позваны все тридцать, как обещал круг: %d / %d" % [
		n, promised])
	_check(across == 0, "ни одна точка сбора не за стеной: %d" % across)
	var east := 0.0
	for step in roundi(LegionCfg.RALLY_MAX_T / DT):
		w._step(DT)
		for u in squad:
			east = maxf(east, u.position.x)
	_check(east < 512.0, "никто не ушёл в обход за стену: самый восточный x = %.1f" % east)


## v19: курсор на ограде — «Сбор» к ближайшей земле (промах на ширину забора); в глубине скалы —
## никого. Круг обещает ровно тех, кто побежит. До правки курсор на ограде звал 0 (verifier
## d26f8623: master звал часть бойцов, после «точек по эту сторону» — никого).
func _test_rally_on_rock() -> void:
	print("— «Сбор» с курсором на ограде и в скале")
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	var squad: Array[Legionnaire] = []
	for k in 5:
		squad.append(w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(430.0 + 10.0 * k, 545.0)))
	var fence := Vector2(450, 600)
	var promised := (w.rally_preview(fence)["reach"] as Array).size()
	_check(not w.terrain.walkable(fence), "раскладка: курсор (450, 600) — на ограде поля")
	var n := w.rally(fence)
	var north := 0
	for u in squad:
		if u.state == Legionnaire.State.RALLY and u._path[u._path.size() - 1].y < 592.0:
			north += 1
	_check(n == 5 and promised == 5, "на ограде: позваны все пятеро, как обещал круг (%d / %d)" % [
		n, promised])
	_check(north == 5, "все встают по свою сторону ограды: %d" % north)
	w.start_map("wasteland")
	var deep := Vector2(470, 600)
	var ground := true
	for k in 5:
		var p := Vector2(640.0, 560.0 + 10.0 * k)
		ground = ground and w.terrain.walkable(p) and p.distance_to(deep) < LegionCfg.RALLY_R
		w.spawn_unit(LegionCfg.KIND_LABORER, p)
	var pv := w.rally_preview(deep)
	var reach := (pv["reach"] as Array).size()
	var cut := (pv["cut"] as Array).size()
	_check(ground and not w.terrain.walkable(deep) and reach == 0 and cut == 5,
		"в глубине скалы «Пустыря» круг: позовёт %d, отрезаны %d (ждём 0 и 5)" % [reach, cut])
	_check(w.rally(deep) == 0, "в глубине скалы — никого")


## Третий verifier d26f8623: круг обещал не тех, кого зовёт «Сбор» (точка подсолнуха за краем
## карты — рельеф там «проходим» ради ворот), а центр на тонкой ограде был не ближайшей землёй
## («Лабиринт», x = 564: земля в 10 px — «позовёт 0»). Прицельный случай и случайные курсоры —
## на земле, на скалах, у края: круг обещает ровно тех, кто побежит, и никто не идёт за край.
func _test_rally_promise_fuzz() -> void:
	print("— круг «Сбора» обещает ровно тех, кого зовёт")
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("maze")
	var ground := Vector2(584, 300)   # земля сразу за оградой
	var placed := 0
	for y in range(250, 360, 12):
		for x in range(580, 660, 12):
			var p := Vector2(x, y)
			if placed < 5 and w.terrain.walkable(p) and w.terrain.connected(p, ground):
				w.spawn_unit(LegionCfg.KIND_LABORER, p)
				placed += 1
	_check(placed == 5, "раскладка: пятеро на земле за оградой x = 564")
	var fence := Vector2(574, 300)
	w.rally_cd = 0.0
	var called := w.rally(fence)
	_check(not w.terrain.walkable(fence) and called == 5,
		"«Лабиринт», курсор на ограде x = 564 в 10 px от земли — позваны пятеро: %d" % called)
	# курсор у каждого из четырёх краёв «Развилки» (на земле): зовёт тех же, кого у края на
	# 20 px ближе к середине (четвёртый verifier: справа и снизу в полосе 7 px не звал никого)
	for edge: Array in [[Vector2(1276, 360), Vector2(1250, 360)], [Vector2(640, 716), Vector2(640, 690)],
			[Vector2(4, 360), Vector2(30, 360)], [Vector2(640, 4), Vector2(640, 30)]]:
		w.start_map("fork")
		var near: Vector2 = edge[1]
		var put := 0
		for y in range(-40, 44, 12):
			for x in range(-40, 44, 12):
				var p := near + Vector2(x, y)
				if put < 6 and w.terrain.walkable(p) and Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).has_point(p):
					w.spawn_unit(LegionCfg.KIND_LABORER, p)
					put += 1
		w.rally_cd = 0.0
		var edge_n := w.rally(edge[0])
		_check(put == 6 and edge_n == 6, "курсор у края %s — позваны все шестеро: %d" % [edge[0], edge_n])
	var field := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).grow(-LegionCfg.UNIT_RADIUS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var bad := 0
	var off := 0
	var tries := 0
	for id: String in ["maze", "fork", "bridge", "swamp"]:
		w.start_map(id)
		var squad: Array[Legionnaire] = []
		while squad.size() < 60:
			var p := Vector2(rng.randf_range(0.0, 1280.0), rng.randf_range(0.0, 720.0))
			if w.terrain.walkable(p):
				squad.append(w.spawn_unit(LegionCfg.KIND_LABORER, p))
		for k in 60:
			var cur := Vector2(rng.randf_range(-4.0, 1284.0), rng.randf_range(-4.0, 724.0))
			if k % 4 == 0:
				cur.y = rng.randf_range(-4.0, 24.0)
			w.rally_cd = 0.0
			# геометрически независимая проба требует оплаченного Сбора; цена уже проверяется
			# economy-тестом: иначе 240 проб тратят общую ману и после 5 кастов дают ложные отказы
			w.contracts.mana = LegionCfg.RALLY_MANA
			for u in squad:
				if u.state != Legionnaire.State.FREE:
					u.set_free()
			var promised := (w.rally_preview(cur)["reach"] as Array).size()
			var n := w.rally(cur)
			tries += 1
			if n != promised:
				bad += 1
				print("    расхождение ", id, " ", cur, ": обещано ", promised, ", позвано ", n)
			for u in squad:
				if u.state == Legionnaire.State.RALLY and not field.has_point(u._path[u._path.size() - 1]):
					off += 1
	_check(bad == 0, "круг обещает ровно тех, кого зовёт: расхождений %d из %d" % [bad, tries])
	_check(off == 0, "никто не идёт за край карты: %d" % off)


## Находка verifier 26.09: боец, которого на сборе держит драка, не выходил из сбора по сроку.
func _test_rally_timeout_in_fight() -> void:
	print("— сбор кончается по сроку и в драке")
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("wasteland")
	w.dev_invuln = true
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(640, 600))
	w.rally(Vector2(620, 470))
	_check(u.state == Legionnaire.State.RALLY, "пошёл на сбор")
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([u.position + Vector2(10, 0),
		u.position + Vector2(11, 0)]), u.position + Vector2(10, 0))
	for step in roundi((LegionCfg.RALLY_MAX_T + 1.0) / DT):
		if f != null and f.alive:
			f.position = u.position + Vector2(10, 0)
		w._step(DT)
	_check(u.state != Legionnaire.State.RALLY, "через %.0f с — не в сборе (state %d)" % [
		LegionCfg.RALLY_MAX_T + 1.0, u.state])


func _wheel(down: bool) -> void:
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
	mb.pressed = true
	mb.position = Vector2(640, 360)
	w.contracts._unhandled_input(mb)


func _test_wheel() -> void:
	print("— колесо: вид договора по кругу")
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.contracts.human_input = true
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	_wheel(true)
	_check(w.contracts.current_kind == LegionCfg.KIND_GUARD, "вниз: подряд → охрана")
	_wheel(true)
	_check(w.contracts.current_kind == LegionCfg.KIND_CLERK, "вниз: охрана → аудит")
	_wheel(true)
	_check(w.contracts.current_kind == LegionCfg.KIND_LABORER, "вниз по кругу: аудит → подряд")
	_wheel(false)
	_check(w.contracts.current_kind == LegionCfg.KIND_CLERK, "вверх: подряд → аудит")
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	w.contracts.begin(Vector2(400, 300))
	w.contracts.extend(Vector2(430, 300))
	_wheel(true)
	_check(w.contracts.current_kind == LegionCfg.KIND_LABORER and w.contracts._drawing,
		"во время штриха колесо не трогает вид и не обрывает штрих")
	w.contracts.cancel()
	w.contracts.unlocked[LegionCfg.KIND_GUARD] = false
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	_wheel(true)
	_check(w.contracts.current_kind == LegionCfg.KIND_CLERK, "закрытый вид колесо пропускает")
