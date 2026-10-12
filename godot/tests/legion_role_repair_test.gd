extends SceneTree
## Причинные регрессы конечных ролей: защита дома, перехват призрака и направление огня.

const DT := 1.0 / 60.0
var w: LegionWorld
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	_fails += int(not ok)
	print("  %s %s" % ["ok" if ok else "FAIL", what])


func _fresh(side: int) -> ContractField:
	w.dev = {"spawn_units": "0", "no_waves": "1", "ctl_off": "1", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.start_map("pvp:duel")
	w.terrain.setup({"size": [1600, 900]})
	w.dev_invuln = false
	return w.sides[side].contracts


func _line(field: ContractField, kind: StringName, at: Vector2) -> Contract:
	return field.add_contract(PackedVector2Array([at, at + Vector2(0, 64)]), 1, false, kind)


func _man(c: Contract, n: int) -> Array[Legionnaire]:
	var squad: Array[Legionnaire] = []
	for p in c.posts:
		if squad.size() >= n:
			break
		var u := w.spawn_unit(c.kind, p["pos"], null, c.owner_side)
		u.assign(c, p)
		u._arrive()
		squad.append(u)
	return squad


func _steps(n: int) -> void:
	for i in n:
		w._step(DT)


func _hold(u: Legionnaire) -> float:
	var value: Variant = u.get("role_recruit_hold_t")
	return float(value) if value != null else 0.0


func _foe(at: Vector2, goal: Vector2, kind := "zombie", moving := false) -> Foe:
	var f := w.spawn_foe_on_path(kind, PackedVector2Array([at, goal]), at)
	f.def = f.def.duplicate()
	f.def["dmg"] = 0.0
	if not moving:
		f.speed = 0.0
		f.hp = 100000.0
		f.max_hp = f.hp
	return f


func _home(side: int, scheme: String) -> void:
	var field := _fresh(side)
	var home := w.cauldron_of(side)
	var outward := Vector2.RIGHT if side == 0 else Vector2.LEFT
	var c := _line(field, LegionCfg.KIND_GUARD, home + outward * 70 + Vector2(0, 60))
	c.set_dir(-outward)
	var squad := _man(c, 4)
	# Старый договор уже есть: создание новой линии само было бы новым явным приказом.
	var old := Contract.new().build(PackedVector2Array([
		home + Vector2(0, 40), home + Vector2(0, 104)]), 1, Callable(), LegionCfg.KIND_GUARD)
	old.owner_side = side
	old.id = c.id + 1000
	field.contracts.append(old)
	w.release_segment_aimed(c, 0, -outward, 0.0, false)
	_steps(160)
	var label := "%s/сторона %d" % [scheme, side]
	var u := squad[0]
	_check(u.state == Legionnaire.State.FREE and not u.role_command_active(),
		"%s: конечный приказ завершён" % label)
	_check(u.held_t <= 0.0 and _hold(u) > 0.0,
		"%s: после роли удерживается только автовербовка, не ручной Сбор" % label)
	_check(LegionStaff.deployment_plan(field, [old]).is_empty(),
		"%s: старый договор не уводит защитников после роли" % label)
	var saved := NetSnap.save(w)
	var digest := w.net_digest()
	if u.get("role_recruit_hold_t") != null:
		u.set("role_recruit_hold_t", _hold(u) + 1.0)
	_check(digest != w.net_digest(), "%s: новое удержание входит в сетевой digest" % label)
	var result := NetSnap.load(w, saved)
	_check(result.errors.is_empty() and result.misses.is_empty() and _hold(u) > 0.0
		and u.held_t <= 0.0 and digest == w.net_digest(),
		"%s: снимок восстанавливает отдельное удержание роли" % label)
	var hp0: float = w.sides[side].cauldron_hp
	var f := _foe(home + outward * 120, home, "zombie", true)
	f.goal_side = side
	_steps(240)
	_check(is_equal_approx(w.sides[side].cauldron_hp, hp0) and not f.alive and f.hp <= 0.0,
		"%s: свободные после роли перехватывают зомби и сохраняют HP Котла" % label)
	var start := u.position
	w.rally(start + Vector2(0, 45), side)
	_steps(520)
	_check(u.held_t > 0.0 and _hold(u) == 0.0,
		"%s: ручной Сбор заменяет удержание роли собственным удержанием" % label)
	var held_at := u.position
	f = _foe(home + outward * 100, home)
	_steps(40)
	_check(u.position.distance_to(held_at) < 0.01,
		"%s: после ручного Сбора защитник сам не уходит из точки" % label)
	var manual := NetSnap.save(w)
	var manual_digest := w.net_digest()
	var manual_result := NetSnap.load(w, manual)
	_check(manual_result.errors.is_empty() and u.held_t > 0.0 and _hold(u) == 0.0
		and manual_digest == w.net_digest(), "%s: снимок сохраняет смысл ручного Сбора" % label)


func _push(side: int, scheme: String) -> void:
	for manual_hold: float in [0.0, 7.0]:
		var field := _fresh(side)
		var c := _line(field, LegionCfg.KIND_CLERK, Vector2(700, 350))
		var u := _man(c, 1)[0]
		u.held_t = manual_hold
		LegionRoleRelease._push(u, Vector2(3, 0))
		_check(u.state == Legionnaire.State.FREE and is_equal_approx(u.held_t, manual_hold)
			and _hold(u) > 0.0,
			"%s/сторона %d: вытеснение блокирует вербовку, сохраняя ручное удержание %.0f"
			% [scheme, side, manual_hold])


func _ghost(side: int, scheme: String) -> void:
	for kind: StringName in [LegionCfg.KIND_GUARD, LegionCfg.KIND_LABORER]:
		var field := _fresh(side)
		var c := _line(field, kind, Vector2(700, 350))
		var squad := _man(c, 4)
		var f := _foe(squad[0].position - Vector2(30, 0), w.cauldron_of(side), "ghost")
		var bot := LegionBot.new()
		bot.world = w
		bot._seen[f.get_instance_id()] = f.position
		var slot := {"contracts": [c], "role": "front", "last_release": -INF}
		var fired := bot._intercept_ghost(slot)
		_check(fired == (kind == LegionCfg.KIND_LABORER),
			"%s/сторона %d: бот %s перехват призрака видом %s"
			% [scheme, side, "выбирает" if fired else "не выбирает", kind])
	for active in [true, false]:
		var field := _fresh(side)
		var c := _line(field, LegionCfg.KIND_LABORER, Vector2(700, 350))
		var squad := _man(c, 4)
		var f := _foe(squad[0].position - Vector2(30, 0), w.cauldron_of(side), "ghost")
		var guards := _line(field, LegionCfg.KIND_GUARD, f.position - Vector2(0, 10))
		var guard_squad := _man(guards, 4)
		if active:
			w.release_segment_aimed(guards, 0, Vector2.RIGHT, 0.0, false)
		else:
			for u in guard_squad:
				u.set_free()
		w.grid.rebuild()
		var bot := LegionBot.new()
		bot.world = w
		bot._seen[f.get_instance_id()] = f.position
		var slot := {"contracts": [c], "role": "front", "last_release": -INF}
		_check(bot._intercept_ghost(slot) == active,
			"%s/сторона %d: %s вахтёры %s защитой от призрака"
			% [scheme, side, "связанные" if active else "свободные",
			"не считаются" if active else "считаются"])


func _forward(side: int, scheme: String, axis: Vector2) -> void:
	var field := _fresh(side)
	var c := _line(field, LegionCfg.KIND_CLERK, Vector2(700, 350))
	var squad := _man(c, 2)
	var rear := Vector2(700, 350)
	var front := rear + axis * 120 + Vector2(0, 80)
	squad[0].position = rear
	squad[1].position = front
	var behind := _foe(front - axis * 50, w.cauldron_of(side))
	var ahead := _foe(front + axis * 50, w.cauldron_of(side))
	var g := w.role_release_geometry(c, 0, axis, 1.0)
	var depth := float(g["depth"])
	var label := "%s/сторона %d/ось %s" % [scheme, side, axis]
	_check(not LegionRoleRelease.strike_clear(w, c, 0, axis, depth, [behind], g),
		"%s: общая плоскость не даёт превью попадания назад из другой полосы" % label)
	_check(LegionRoleRelease.strike_clear(w, c, 0, axis, depth, [ahead], g),
		"%s: доступная цель впереди видна в превью" % label)
	w.release_segment_aimed(c, 0, axis, 1.0, false)
	_steps(75)
	_check(behind.hp == behind.max_hp and ahead.hp < ahead.max_hp,
		"%s: реальный вал бьёт только впереди своего стрелка" % label)


func _hold_reset(side: int, scheme: String) -> void:
	for action: String in ["assign", "new_line", "free", "rally", "charge", "dead", "expire"]:
		var field := _fresh(side)
		var c := _line(field, LegionCfg.KIND_CLERK, Vector2(700, 350))
		var u := _man(c, 1)[0]
		w.release_segment(c, 0)
		_steps(90)
		match action:
			"assign":
				var next := Contract.new().build(PackedVector2Array([
					Vector2(700, 330), Vector2(700, 394)]), 1, Callable(), c.kind)
				next.owner_side = side
				u.assign(next, next.posts[0])
			"new_line":
				_line(field, c.kind, Vector2(700, 330))
			"free":
				u.set_free()
			"rally":
				u.rally_to(PackedVector2Array([u.position, u.position + Vector2(0, 30)]))
			"charge":
				u.start_charge(Vector2.LEFT)
			"dead":
				u.take_damage(1000000.0, u.position)
			"expire":
				u.set("role_recruit_hold_t", DT * 0.5)
				_steps(1)
		var expected := LegionCfg.ROLE_COMMAND_HOLD if action == "charge" else 0.0
		_check(is_equal_approx(_hold(u), expected),
			"%s/сторона %d: %s сбрасывает прежнее удержание роли" % [scheme, side, action])


func _run() -> void:
	Campaign.set_save_path("user://legion_role_repair_test.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	for scheme: String in [Settings.SCHEME_CLASSIC, Settings.SCHEME_SLING]:
		Settings.scheme_override = scheme
		for side in 2:
			_home(side, scheme)
			_push(side, scheme)
			_ghost(side, scheme)
			_hold_reset(side, scheme)
			for axis: Vector2 in [Vector2.RIGHT, Vector2.LEFT]:
				_forward(side, scheme, axis)
	Settings.scheme_override = ""
	Campaign.reset()
	for s in w.sides:
		s.items.effects.items = null
	w.queue_free()
	await process_frame
	print("LEGION ROLE REPAIR: %d/%d OK" % [_checks - _fails, _checks])
	quit(int(_fails > 0))
