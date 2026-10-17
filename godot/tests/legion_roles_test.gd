extends SceneTree
## Регресс ролей: настоящий выпуск договора, общий шаг мира и снимок посреди команды.

const SAVE := "user://legion_roles_test.cfg"
const DT := 1.0 / 60.0
const ORIGIN := Vector2(350, 240)

var w: LegionWorld
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", what])


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	_guard_contact()
	_guard_directions()
	_guard_obstacle()
	_guard_limits()
	_clerk_sweep()
	_clerk_cancel()
	_depth_and_water()
	_manual_melt_tab()
	_figures()
	_overtime_cancel()
	_combo()
	_laborer()
	_snapshot()
	_pvp_roles()
	await _freed_member()
	await _actual_input()
	Campaign.reset()
	w.queue_free()
	await process_frame
	print("LEGION ROLES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev = {"spawn_units": "0", "no_waves": "1", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.start_map("_gray")
	w.terrain.setup({"size": [1280, 720]})
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


func _line(kind: StringName, at := ORIGIN) -> Contract:
	var points := PackedVector2Array()
	for i in 9:
		points.append(at + Vector2(0, i * 8.0))
	return w.contracts.add_contract(points, 1, false, kind)


func _man(c: Contract) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _foe(at: Vector2, kind := "zombie") -> Foe:
	var f := w.spawn_foe_on_path(kind, PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = f.hp
	return f


func _steps(n: int) -> void:
	for i in n:
		w._step(DT)


## B-494: печать огневого вала бьёт по прилёту. Досчитать полёт уже выпущенных печатей, не
## двигая бойцов: освободившиеся стрелки не успевают добавить обычные печати.
func _land_shots() -> void:
	for i in 120:
		if w.projectiles.shots.is_empty():
			return
		w.projectiles.tick(DT)


func _guard_contact() -> void:
	_fresh()
	var c := _line(LegionCfg.KIND_GUARD)
	var squad := _man(c)
	var origins := PackedVector2Array()
	for u in squad:
		origins.append(u.position)
	var f := _foe(squad[0].position + Vector2(34, 0))
	var old := f.position
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(30)
	var coherent := squad.size() > 1
	for i in squad.size():
		coherent = coherent and squad[i].state == Legionnaire.State.CHARGE \
			and (squad[i].position - squad[0].position).distance_to(origins[i] - origins[0]) < 0.05
	_check(coherent, "щитовой фронт продолжает общий ход после первого контакта, сохраняя места")
	_check(f.position.x > old.x + 5.0, "щитовой фронт вытесняет лёгкую цель")
	_check(not c.seg_alive(0), "команда расходует участок договора")
	_steps(240)
	var ended := true
	for u in squad:
		ended = ended and u.state == Legionnaire.State.FREE
	_check(ended, "фронт конечен: после команды все выжившие свободны")


func _guard_directions() -> void:
	for dir: Vector2 in [Vector2(0.6, 0.8), Vector2.LEFT]:
		_fresh()
		var c := _line(LegionCfg.KIND_GUARD)
		var squad := _man(c)
		var old := squad[0].position
		_foe(old + Vector2(40, -40))
		w.release_segment_aimed(c, 0, dir, 1.0, false)
		_steps(30)
		var d := squad[0].position - old
		_check(d.dot(dir) > 10.0 and absf(d.cross(dir)) < 0.05,
			"щиты идут строго по выбранной оси %s, не за отдельной целью" % dir)


func _guard_obstacle() -> void:
	_fresh()
	var c := _line(LegionCfg.KIND_GUARD)
	var squad := _man(c)
	var origins := PackedVector2Array()
	for u in squad:
		origins.append(u.position)
	w.terrain.setup({"size": [1280, 720], "rocks": [[[390, 235], [420, 235],
		[420, 265], [390, 265]]]})
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(120)
	var max_run := 0.0
	var min_run := INF
	for i in squad.size():
		max_run = maxf(max_run, squad[i].position.x - origins[i].x)
		min_run = minf(min_run, squad[i].position.x - origins[i].x)
	_check(max_run - min_run < 0.05 and max_run < 35.0,
		"камень ограничивает весь строй, обхода по одному нет (ход %.2f..%.2f)"
		% [min_run, max_run])


func _guard_limits() -> void:
	_fresh()
	var c := _line(LegionCfg.KIND_GUARD)
	var squad := _man(c)
	var old := squad[0].position
	_foe(old + Vector2(27, 0), "boss")
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(40)
	_check((squad[0].position - old).length() < 2.0,
		"тяжёлая цель останавливает продвижение связного фронта")
	_fresh()
	c = _line(LegionCfg.KIND_GUARD)
	squad = _man(c)
	old = squad[0].position
	_foe(old + Vector2(-27, 0), "boss")
	w.release_segment_aimed(c, 0, Vector2.LEFT, 1.0, false)
	_steps(40)
	_check((squad[0].position - old).length() < 2.0,
		"тяжёлая цель на пути отхода ограничивает фронт независимо от ориентации щитов")
	_fresh()
	c = _line(LegionCfg.KIND_GUARD)
	squad = _man(c)
	var diagonal := Vector2(0.1, 0.995).normalized()
	var foe := _foe(squad.back().position + diagonal * 27.0)
	old = foe.position
	w.release_segment_aimed(c, 0, diagonal, 1.0, false)
	_steps(40)
	_check((foe.position - old).dot(diagonal) > 5.0,
		"диагональный перевод вытесняет цель на пути даже сбоку от исходного щита")
	_fresh()
	c = _line(LegionCfg.KIND_GUARD)
	squad = _man(c)
	old = squad[0].position
	for i in 8:
		_foe(old + Vector2(-12, i * 4.0))
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(30)
	_check((squad[0].position - old).length() < 25.0,
		"нападение с фланга мешает переводу фронта")
	_fresh()
	c = _line(LegionCfg.KIND_GUARD)
	squad = _man(c)
	w.release_segment_aimed(c, 0, Vector2.LEFT, 1.0, false)
	var u := squad[0]
	var hp0 := u.hp
	u.take_damage(10.0, u.position + Vector2.RIGHT * 20.0)
	var front_damage := hp0 - u.hp
	hp0 = u.hp
	u.take_damage(10.0, u.position + Vector2.LEFT * 20.0)
	_check(is_equal_approx(front_damage, 5.0) and is_equal_approx(hp0 - u.hp, 10.0),
		"при отходе щит прикрывает исходный фронт, тыл уязвим")


func _clerk_sweep() -> void:
	_fresh()
	var c := _line(LegionCfg.KIND_CLERK)
	var squad := _man(c)
	var origins := PackedVector2Array()
	for u in squad:
		origins.append(u.position)
	var a := _foe(squad[0].position + Vector2(30, 0))
	var b := _foe(squad[0].position + Vector2(200, 0))
	var outside := _foe(squad[0].position + Vector2(70, -75))
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(28)
	_check(a.hp < a.max_hp and b.hp == b.max_hp,
		"огневой вал сначала поражает ближнюю полосу, дальняя ещё ждёт")
	_steps(100)
	var still := true
	for i in squad.size():
		still = still and squad[i].position.distance_to(origins[i]) < 0.05
	_check(still, "счетоводы остаются на своих местах после выпуска")
	_check(b.hp < b.max_hp, "дальняя полоса огневого вала достигает выбранной глубины")
	_check(outside.hp == outside.max_hp, "враг вне зафиксированной полосы не перехватывает залп")
	var off := true
	for u in squad:
		off = off and u.state == Legionnaire.State.FREE
	_check(off, "огневой вал заканчивается, стрелки снова свободны")


func _clerk_cancel() -> void:
	for action: String in ["dead", "rally", "line"]:
		_fresh()
		var c := _line(LegionCfg.KIND_CLERK)
		var squad := _man(c)
		var f := _foe(squad[0].position + Vector2(210, 0))
		w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
		_steps(8)
		match action:
			"dead":
				for u in squad:
					u.take_damage(1000000.0, u.position)
			"rally":
				var count := w.rally(ORIGIN + Vector2(-45, 0))
				_check(count == squad.size(), "ручной Сбор отменяет огневой вал живых участников")
			"line":
				_line(LegionCfg.KIND_CLERK, ORIGIN + Vector2(-30, 0))
				var off := true
				for u in squad:
					off = off and not u.role_command_active()
				_check(off, "новая линия своего вида отменяет прежний огневой приказ")
		_steps(100)
		_check(f.hp == f.max_hp, "%s: отменённый вал не выпускает посмертные/запоздалые полосы" % action)
	_fresh()
	var c := _line(LegionCfg.KIND_CLERK)
	var squad := _man(c)
	var u := squad[0]
	w.release_segment(c, 0)
	var hp0 := u.hp
	u.take_damage(10.0, u.position + Vector2.RIGHT * 20.0)
	_check(is_equal_approx(hp0 - u.hp, 10.0), "неподвижный стрелок не получает щитовую броню")


func _depth_and_water() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		_fresh()
		var c := _line(kind)
		_man(c)
		var short := w.role_release_geometry(c, 0, Vector2.RIGHT, 0.0)
		var deep := w.role_release_geometry(c, 0, Vector2.RIGHT, 1.0)
		_check(float(deep["depth"]) > float(short["depth"]) * 1.8,
			"%s: глубина жеста меняет конечное место команды" % kind)
		var ends: PackedVector2Array = short["ends"]
		var origins: PackedVector2Array = short["origins"]
		var endpoint_depth := ends[0].distance_to(origins[0]) if kind == LegionCfg.KIND_GUARD \
			else (ends[0] - (short["center"] as Vector2)).dot(Vector2.RIGHT)
		_check(is_equal_approx(endpoint_depth, float(short["depth"])),
			"%s: геометрия превью и конечная глубина согласованы" % kind)
	_fresh()
	var c := _line(LegionCfg.KIND_CLERK)
	var squad := _man(c)
	w.terrain.setup({"size": [1280, 720], "water": [[[390, 200], [430, 200],
		[430, 340], [390, 340]]]})
	var f := _foe(squad[0].position + Vector2(190, 0))
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(80)
	_land_shots()
	_check(f.hp < f.max_hp, "огневой вал пересекает воду без перевода стрелков")
	_fresh()
	c = _line(LegionCfg.KIND_CLERK)
	squad = _man(c)
	w.terrain.setup({"size": [1280, 720], "rocks": [[[390, 200], [430, 200],
		[430, 340], [390, 340]]]})
	f = _foe(squad[0].position + Vector2(190, 0))
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
	_steps(80)
	_land_shots()
	_check(f.hp == f.max_hp, "непрозрачная стена закрывает огневую полосу")


func _manual_melt_tab() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		for cause: String in ["manual", "melt", "tab", "tab_gold"]:
			_fresh()
			var c := _line(kind)
			var squad := _man(c)
			if cause.begins_with("tab"):
				w.release_run(c, PackedInt32Array([0]),
					PackedByteArray([1 if cause == "tab_gold" else 0]))
			else:
				w.release_segment(c, 0, StringName(cause))
			var v := squad[0]._volley
			var job: Dictionary = v.get("role_job", {})
			var want := LegionCfg.GUARD_FRONT_DEFAULT if kind == LegionCfg.KIND_GUARD \
				else LegionCfg.CLERK_BARRAGE_DEFAULT
			_check(not job.is_empty() and is_equal_approx(float(job.get("depth", 0.0)), want),
				"%s/%s: тот же конечный приказ с обычной глубиной" % [kind, cause])
			_check(bool(v["manual"]) == (cause != "melt"),
				"%s/%s: происхождение команды для комбо сохранено" % [kind, cause])
			if cause == "tab_gold":
				_check(bool(v["perfect"]), "%s: золотой Таб сохраняет точный срыв" % kind)


func _figure(kind: StringName, figure: StringName) -> Contract:
	var points := PackedVector2Array()
	var center := Vector2(450, 350)
	if figure == ContractShape.EIGHT or figure == ContractShape.D_SHAPE:
		for i in 101:
			var a := TAU * i / 100.0
			var p := Vector2(sin(a) * 70.0, sin(a) * cos(a) * 45.0) \
				if figure == ContractShape.EIGHT else Vector2(cos(a), sin(a)) * 70.0
			if figure == ContractShape.D_SHAPE:
				p.x = maxf(0.0, p.x)
			points.append(center + p)
	else:
		var corners := 3 if figure == ContractShape.TRIANGLE else \
			5 if figure == ContractShape.PENTAGON else 4
		for i in corners:
			var a := Vector2.from_angle(TAU * i / corners - PI / 2.0) * 70.0
			var b := Vector2.from_angle(TAU * (i + 1) / corners - PI / 2.0) * 70.0
			for j in 16:
				points.append(center + a.lerp(b, j / 16.0))
		points.append(points[0])
	w.contracts._create(points, 1, kind, false, figure)
	return w.contracts.contracts.back()


func _figures() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		for figure: StringName in [ContractShape.TRIANGLE, ContractShape.SQUARE,
				ContractShape.PENTAGON, ContractShape.D_SHAPE, ContractShape.EIGHT]:
			for axis: Vector2 in [Vector2.ZERO, Vector2(0.6, 0.8)]:
				_fresh()
				var c := _figure(kind, figure)
				_check(c.figure == figure, "%s/%s: подготовлена настоящая фигура" % [kind, figure])
				var squad := _man(c)
				var facings := PackedVector2Array()
				for u in squad:
					facings.append(u.post["normal"])
				var g := w.role_release_geometry(c, 0, axis, 1.0, true)
				w.figures.release(c, -1.0 if axis.is_zero_approx() else 1.0, false, axis)
				var jobs := LegionRoleRelease.jobs(w)
				var correct := jobs.size() > 0
				for i in squad.size():
					correct = correct and LegionRoleRelease.facing_of(squad[i]).is_equal_approx(facings[i])
				_check(correct, "%s/%s: каждый щит сохраняет исходный фронт" % [kind, figure])
				if axis.is_zero_approx():
					_check(jobs.size() > 1, "%s/%s: обычный выпуск сохраняет разные радиальные/перекрёстные группы"
						% [kind, figure])
					continue
				var job := jobs[0]
				_check(jobs.size() == 1 and (job["dir"] as Vector2).is_equal_approx(axis),
					"%s/%s: рогатка связывает все углы в один конечный приказ" % [kind, figure])
				_check((job["center"] as Vector2).distance_to(g["center"]) < 0.01 \
					and is_equal_approx(float(job["depth"]), float(g["depth"])),
					"%s/%s: общий вал совпадает с плоскостью и глубиной превью" % [kind, figure])
				var before := squad[0].position
				if kind == LegionCfg.KIND_GUARD:
					var p := squad[0].position + axis * 20.0
					w.terrain.setup({"size": [1280, 720], "rocks": [[[p.x - 4, p.y - 4],
						[p.x + 4, p.y - 4], [p.x + 4, p.y + 4], [p.x - 4, p.y + 4]]]})
				_steps(60)
				var coherent := true
				var origins: PackedVector2Array = job["origins"]
				var first := (job["members"] as Array).find(squad[0])
				for i in squad.size():
					var j := (job["members"] as Array).find(squad[i])
					coherent = coherent and (squad[i].position - origins[j]).distance_to(
						squad[0].position - origins[first]) < 0.01
				_check(coherent and (kind == LegionCfg.KIND_CLERK \
					or squad[0].position.distance_to(before) < 20.0),
					"%s/%s: позиции связны, препятствие ограничивает общий перевод" % [kind, figure])
				var saved := NetSnap.save(w)
				_steps(20)
				var want := NetSnap.save(w)
				NetSnap.load(w, saved)
				_steps(20)
				_check(var_to_bytes(want) == var_to_bytes(NetSnap.save(w)),
					"%s/%s: общая команда и личные фронты продолжаются после снимка" % [kind, figure])


func _overtime_cancel() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		for action: String in ["normal", "recall", "reassign"]:
			_fresh()
			var c := _figure(kind, ContractShape.EIGHT)
			var squad := _man(c)
			w.figures.melt(c)
			_check(w.figures.pending_overtime() == 1,
				"%s/%s: самотаяние восьмёрки готовит вторую смену" % [kind, action])
			if action == "recall":
				w.rally(Vector2(420, 320))
			elif action == "reassign":
				var fresh := _line(kind, Vector2(700, 350))
				for i in squad.size():
					squad[i].assign(fresh, fresh.posts[i % fresh.posts.size()])
			_steps(400)
			var fired := int(w.stats.get("overtime_charges", 0))
			_check(fired == (squad.size() if action == "normal" else 0),
				"%s/%s: заслуженная смена конечна, новый приказ не даёт бесплатный второй вал"
				% [kind, action])


func _combo() -> void:
	_fresh()
	var c := _line(LegionCfg.KIND_CLERK)
	var squad := _man(c)
	_foe(squad[0].position + Vector2(25, 0))
	_foe(squad[0].position + Vector2(100, 0))
	w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, true)
	_steps(60)
	_check(w.combo == 1, "несколько полос одного ручного вала растят комбо только один раз")
	var c2 := _line(LegionCfg.KIND_GUARD, ORIGIN + Vector2(0, 200))
	squad = _man(c2)
	w.release_segment(c2, 0)
	_steps(160)
	_check(w.combo == 0, "фронт, выпущенный впустую, сбрасывает комбо по окончании")


func _laborer() -> void:
	_fresh()
	var c := _line(LegionCfg.KIND_LABORER)
	var squad := _man(c)
	_foe(squad[0].position + Vector2(25, 0))
	w.release_segment(c, 0)
	_steps(1)
	_check(squad[0].state == Legionnaire.State.FREE,
		"подрядчик сохраняет прежний натиск до первого контакта")


func _snapshot() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		_fresh()
		var c := _line(kind)
		_man(c)
		_foe(ORIGIN + Vector2(100, 20))
		w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
		_steps(20)
		var saved := NetSnap.save(w)
		_steps(20)
		var want := NetSnap.save(w)
		var result := NetSnap.load(w, saved)
		_check(result.misses.is_empty(), "%s: снимок команды восстановлен без потерянных ссылок" % kind)
		_steps(20)
		_check(var_to_bytes(NetSnap.save(w)) == var_to_bytes(want),
			"%s: продолжение команды после снимка побайтно совпадает" % kind)


func _pvp_roles() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		w.dev = {"spawn_units": "0", "no_waves": "1", "pvp_nobot": "1"}
		w.start_map("pvp:duel")
		w.terrain.setup({"size": [1600, 900]})
		var c := _line(kind, Vector2(650, 350))
		var squad := _man(c)
		var enemy := w.spawn_unit(LegionCfg.KIND_LABORER, squad[0].position + Vector2(40, 0), null, 1)
		enemy.hp = 10000.0
		enemy.max_hp = enemy.hp
		var hp0 := enemy.hp
		w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
		_steps(70)
		_check(enemy.hp < hp0, "%s: новая роль наносит удар армии соперника в PvP" % kind)
		var digest := w.net_digest()
		var saved := NetSnap.save(w)
		var reg := NetSnap.load(w, saved)
		_check(reg.errors.is_empty() and reg.misses.is_empty() and digest == w.net_digest(),
			"%s: PvP-команда и её digest переживают снимок" % kind)


## Синхронные _steps не освобождают queue_free: здесь проходит настоящий кадр удаления тела.
## Список команды сохраняет пустое место погибшего, а выжившие продолжают конечный приказ.
func _freed_member() -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		_fresh()
		var c := _line(kind)
		var squad := _man(c)
		w.release_segment_aimed(c, 0, Vector2.RIGHT, 1.0, false)
		var job: Dictionary = squad[0]._volley["role_job"]
		squad[0].take_damage(1000000.0, squad[0].position)
		for i in 75:
			w._step(DT)
			await process_frame
		_check(not is_instance_valid((job["members"] as Array)[0]),
			"%s: тело первого участника действительно удалено до конца команды" % kind)
		var old := squad[1].position
		var saved := NetSnap.save(w)
		var digest := w.net_digest()
		_steps(20)
		if kind == LegionCfg.KIND_GUARD:
			_check(squad[1].position.x > old.x + 20.0,
				"фронт продолжает движение после освобождения Node павшего участника")
		_steps(80)
		var ended := true
		for u in w.units:
			ended = ended and u.state == Legionnaire.State.FREE
		_check(ended, "%s: удалённый участник не мешает завершить команду выживших" % kind)
		var want := NetSnap.save(w)
		var result := NetSnap.load(w, saved)
		_check(result.misses.is_empty() and result.errors.is_empty() and digest == w.net_digest(),
			"%s: снимок и digest сохраняют команду с пустым местом павшего" % kind)
		_steps(100)
		_check(var_to_bytes(want) == var_to_bytes(NetSnap.save(w)),
			"%s: продолжение после удаления тела и снимка побайтно совпадает" % kind)


func _mouse(p: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = 7
	ev.position = root.get_final_transform() * p
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
	Input.parse_input_event(ev)
	await process_frame


func _actual_input() -> void:
	for scheme: String in [Settings.SCHEME_CLASSIC, Settings.SCHEME_SLING]:
		Settings.scheme_override = scheme
		for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
			_fresh()
			var c := _line(kind)
			var squad := _man(c)
			await process_frame
			await process_frame
			await _mouse(c.seg_center(0), true)
			await _mouse(c.seg_center(0), false)
			_check(not c.seg_alive(0) and squad[0].role_command_active(),
				"настоящий ПКМ/%s: %s получает новую конечную команду" % [scheme, kind])
	Settings.scheme_override = ""
