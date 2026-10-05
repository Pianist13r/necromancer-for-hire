class_name Foe
extends Node2D
##
## Проверяющий из Ада. Идёт по дороге к Котлу, упирается в строй и рубит его; нотариус
## печатает издалека по самой плотной группе, призрак проходит сквозь строй, мимик спит у
## дороги, босс таранит участок строя. Всё различие видов — поля LegionCfg.FOES и пара веток
## здесь: подклассы ради пяти веток дали бы больше файлов, чем логики.
##

enum State { WALK, FIGHT, SLEEP, WAKE, DEAD, SIEGE }

var world: LegionWorld = null
var view: CharView = null
var type_id := ""
var def: Dictionary = {}
## Источник сохраняется до смерти: нахлёст не должен смешивать награды волн.
var origin: Dictionary = {"wave": 0, "breach": ""}
var state := State.WALK
var hp := 1.0
var max_hp := 1.0
var speed := 30.0
var radius := 8.0
var ghost := false
var alive := true
var idx := 0
## PvP (docs/pvp/DESIGN.md §2.3): к чьему Котлу идёт — половины, где кончается его дорога
## (одиночка — всегда 0), и чей удар был последним (−1 — ничей): души за убийство — ей.
var goal_side := 0
var last_hit_side := -1
## Нотариус: где упадёт печать и сколько осталось до удара (< 0 — печати нет).
var stamp_pos := Vector2.ZERO
var stamp_t := -1.0
## Нотариус стоит на дистанции (_signer_holds) — расталкивание пропускает сквозь него идущих
## (legion_grid.separate): иначе вставший на узкой дороге запирал свою колонну.
var holding := false
## Точка фиксируется при рёве: выпущенный участок может уйти из будущего удара.
var ram_pos := Vector2.ZERO
var ram_t := -1.0
var seal_slow_t := 0.0
## «Неустойка» заряженный выпуск: замедление от первого касания залпа (скорость × slow_mult,
## пока slow_t > 0) и «Комиссия»: id группы, пометившей эту цель, — участники группы бьют её
## сильнее. Оба поля переживают загрузку снимка (SnapUnits).
var slow_t := 0.0
var slow_mult := 1.0
var mark_group_id := -1
var mark_t := 0.0
## Юрист (v17 LAW): цель — участок договора и точка на нём; law_read_t ≥ 0 — идёт зачитка.
var law_c: Contract = null
var law_seg := -1
var law_pos := Vector2.ZERO
var law_read_t := -1.0
## v20: оглушение (Ку) — сколько ещё стоит: не ходит, не бьёт, не давит строй (legion_grid).
var stun_t := 0.0
## Артефакты (items/): элитный — толще, крупнее, в короне.
var elite := false
## Носитель артефакта (LegionItems.plan_battle): элитный, над короной «портфель»; убит — роняет.
var carrier := false
## Был оглушён в момент смерти — «Взрывная печать» (stun_t к этому моменту уже обнулён).
var died_stunned := false
var _ram_run := -1.0
var _ram_start := Vector2.ZERO

var _path := PackedVector2Array()
var _wp := 0
## v19: не раньше этого времени мира — следующий обход стены по A* (см. _detour).
var _detour_at := -INF
var _atk_cd := 0.0
var _skill_cd := 0.0
var _roar_cd := 0.0
var _wake_t := 0.0
var _dead_t := 0.0
var _target: Legionnaire = null
var _dir := Vector2.LEFT
var _law_scan := 0.0
## Юрист сошёл с дороги к участку: к Котлу возвращается путём A*, а не к пройденной точке.
var _law_off_road := false


func setup(w: LegionWorld, new_type: String, path: PackedVector2Array, opts: Dictionary) -> void:
	world = w
	origin = {"wave": 0, "breach": ""}
	origin.merge(opts.get("origin", {}), true)
	type_id = new_type
	def = LegionCfg.FOES[type_id]
	hp = float(def["hp"])
	max_hp = hp
	speed = float(def["speed"])
	radius = float(def["radius"])
	ghost = bool(def.get("ghost", false))
	_path = path
	_wp = 0
	position = opts.get("pos", path[0] if path.size() > 0 else Vector2.ZERO)
	goal_side = w.side_at(path[path.size() - 1] if path.size() > 0 else position)
	_skill_cd = float(def.get("stamp_cd", def.get("ram_cd", 0.0)))
	_roar_cd = float(def.get("roar_cd", 0.0))
	view = CharView.new()
	view.locomotion_from_position = true
	add_child(view)
	view.setup(String(def["char"]), float(def["body"]))
	view.modulate = def.get("tint", Color.WHITE)
	if ghost:
		view.modulate.a = float(def.get("alpha", 0.6))
	if bool(opts.get("sleep", false)):
		state = State.SLEEP
		view.set_loop_state(&"sleep")
	if _path.size() > 0:
		_dir = (_path[mini(1, _path.size() - 1)] - position).normalized()
		if _dir.is_zero_approx():
			_dir = Vector2.LEFT
		_face(_dir)


## Элитный враг волны (LegionItems.roll_elite): HP ×ELITE_HP_MULT, крупнее, ореол и корона.
func make_elite(as_carrier := false) -> void:
	if elite:
		return
	elite = true
	carrier = as_carrier
	hp *= CfgItems.ELITE_HP_MULT
	max_hp = hp
	view.scale = Vector2.ONE * CfgItems.ELITE_SCALE
	view.modulate *= CfgItems.ELITE_TINT
	var mark := LegionEliteMark.new()
	mark.position = Vector2(0.0, view.ground_px() * CfgItems.ELITE_SCALE)
	add_child(mark)
	move_child(mark, 0)
	mark.carrier = as_carrier
	mark.setup(world, view.body_h * CfgItems.ELITE_SCALE, CfgItems.ELITE_COLOR)


## Живой и в игре (спящий мимик в подсчёт волны не входит).
## Куда враг идёт или бьёт (последний шаг или удар) — давка считает только идущих на участок.
func heading() -> Vector2:
	return _dir


func is_active() -> bool:
	return alive and state != State.SLEEP


func tick(dt: float) -> void:
	view.begin_action_tick()
	_tick_state(dt)
	view.end_action_tick()


func _tick_state(dt: float) -> void:
	_atk_cd -= dt
	seal_slow_t = maxf(0.0, seal_slow_t - dt)
	slow_t = maxf(0.0, slow_t - dt)
	if mark_t > 0.0:
		mark_t = maxf(0.0, mark_t - dt)
		if mark_t <= 0.0:
			mark_group_id = -1
	if type_id == "shield_inspector":
		queue_redraw()
	match state:
		State.DEAD:
			_dead_t += dt
			# B-049: труп таял по часам вида (реальные секунды CharView._process), а убирался
			# и был доступен Дубль-вэ по часам мира (_dead_t, уже с масштабом «Отсрочки») — при
			# замедлении мира вид тает быстрее и раньше уборки. Гоним вид часами мира.
			_drive_corpse()
			return
		State.SIEGE:
			_tick_siege()
			return
		State.SLEEP:
			if world.grid.nearest_unit(position, float(def.get("wake_radius", 100.0))) != null:
				state = State.WAKE
				_wake_t = 0.4
				view.play_once(&"wake")
				_path = world.terrain.find_path(position, world.cauldron_of(goal_side))
				_wp = 0
			return
		State.WAKE:
			_wake_t -= dt
			if _wake_t <= 0.0:
				state = State.WALK
			return
	# оглушение (Ку) занимает ход целиком; вставший нотариус, босс (таран) и Юрист (зачитка) —
	# пока идёт их особое действие
	if _tick_stun(dt) or (type_id == "signer" and _tick_signer(dt)) \
			or (type_id == "boss" and _tick_boss(dt)) or (type_id == "lawyer" and _tick_lawyer(dt)):
		return
	_tick_move(dt)


## v20: true — оглушён и этот кадр стоит (тот же покачивающийся вид, что у бойца, unit.gd).
func _tick_stun(dt: float) -> bool:
	if stun_t <= 0.0:
		return false
	view.cancel_action()
	stun_t = maxf(0.0, stun_t - dt)
	view.rotation = 0.0 if stun_t <= 0.0 else sin(stun_t * 26.0) * 0.3
	if type_id == "lawyer":
		queue_redraw()
	return true


## Нотариус: печать тикает всегда; true — встал на дистанции и дерётся только с подошедшими.
func _tick_signer(dt: float) -> bool:
	_tick_stamp(dt)
	holding = _signer_holds()
	if holding:
		_melee_if_close()
	return holding


func take_damage(amount: float, from: Vector2, projectile := false) -> void:
	if not alive:
		return
	if projectile and _dir.dot(from - position) > 0.0:
		amount *= float(def.get("projectile_front_mult", 1.0))
	if world.defer_carrier_hit(self, amount, from):
		return
	# --dev invuln: замер кадра на постоянной массе, никто не умирает
	hp -= 0.0 if world.dev_invuln else amount
	view.react_hit()
	if state == State.SLEEP:
		state = State.WAKE
		_wake_t = 0.4
		view.play_once(&"wake")
		_path = world.terrain.find_path(position, world.cauldron_of(goal_side))
		_wp = 0
	if hp <= 0.0:
		alive = false
		state = State.DEAD
		stamp_t = -1.0
		ram_t = -1.0
		_ram_run = -1.0
		if law_read_t >= 0.0:
			world.stats["lawyer_interrupts"] = int(world.stats.get("lawyer_interrupts", 0)) + 1
		_law_drop()
		died_stunned = stun_t > 0.0
		stun_t = 0.0
		view.rotation = 0.0
		queue_redraw()
		view.play_once(&"death")
		# B-049: часы мира ведут труп с первого кадра смерти — иначе hold, наступивший до
		# ближайшего tick(), дал бы виду растаять по своим часам (verifier 26.09, пункт C)
		_drive_corpse()
		_face(from - position)
		world.on_foe_died(self)


## B-049: возраст трупа виду — часами мира, но ТОЛЬКО пока идёт бой. Бой кончается внутри
## _step() (волны кончились → _end → LegionWorld._release_corpses), а тот же шаг потом ещё
## тикает врагов и трупы (foes[i].tick, _cleanup) — без проверки фазы они снова брали вид на
## часы мира, и трупы стояли целыми под экраном итога (verifier-3 26.09). Проверка по фазе, а
## не «липкий» отпуск в CharView: враг, убитый в том же шаге ПОСЛЕ конца боя, начал бы новую
## смерть (play_once снимает отпуск) и снова застрял бы; фаза же отвечает на сам вопрос
## «шагает ли ещё мир».
func _drive_corpse() -> void:
	if view != null and world.phase == LegionWorld.Phase.BATTLE:
		view.set_corpse_age(_dead_t)


## Враг лежит на земле дольше стандартного CORPSE_TIME (пакет hero, DESIGN_V15 §12 п.8):
## окно HERO_CORPSE_TTL — пока Дубль-вэ ещё может поднять свежий труп в штат. Уборка
## Legionnaire (unit.gd) этот метод не использует — там CORPSE_TIME как раньше.
func is_corpse_done() -> bool:
	return state == State.DEAD and _dead_t >= LegionCfg.HERO_CORPSE_TTL


## «Свежий труп» для Дубль-вэ: мёртв недолго, не босс (§12: «босс и свита недоступны» — свиту
## по типу не отличить от обычных зомби волны, различаем только босса по type_id).
func is_fresh_corpse() -> bool:
	return state == State.DEAD and type_id != "boss" and _dead_t <= LegionCfg.HERO_CORPSE_TTL


## v20 Ку: оглушить на t секунд (босса — на долю Q_STUN_BOSS_MULT; в осаде — нет: осада —
## отдельный бой у ворот, её ведёт свой таймер). Спящего прямой вызов не оглушает, но Ку сначала
## бьёт (take_damage будит мимика), потом оглушает — проснувшийся стоит оглушённым (verifier 26.09).
## Сбивает то, что враг «замахнул»: зачитка Юриста начнётся заново, когда очнётся; печать
## нотариуса в замахе не падает (откат печати уже пошёл).
func stun(t: float) -> void:
	if not alive or state == State.SIEGE or state == State.SLEEP:
		return
	stun_t = maxf(stun_t, t * (LegionCfg.Q_STUN_BOSS_MULT if type_id == "boss" else 1.0))
	if law_read_t >= 0.0:
		world.stats["lawyer_interrupts"] = int(world.stats.get("lawyer_interrupts", 0)) + 1
		law_read_t = -1.0
	if stamp_t >= 0.0:
		world.stats["stamps_broken"] = int(world.stats.get("stamps_broken", 0)) + 1
		stamp_t = -1.0
	queue_redraw()


func is_stunned() -> bool:
	return stun_t > 0.0


## v20: строй Юриста не трогает — «договор зачитывают, стоящие по нему юриста не бьют». Его
## снимают навык (Ку), натиск, свободные и «Сбор» — ответ игрока, а не строя (B-061).
func is_law_immune() -> bool:
	return type_id == "lawyer"


## Дошёл до Котла: удар и исчезновение (без трупа).
func vanish() -> void:
	# Различаем провал перехвата и обычный прорыв: общий урон скрывал причину поражения.
	var key := type_id + "_leaks"
	world.stats[key] = int(world.stats.get(key, 0)) + 1
	alive = false
	state = State.DEAD
	_dead_t = LegionCfg.CORPSE_TIME
	visible = false


# ── Движение и бой ──────────────────────────────────────────────────────────

func _tick_move(dt: float) -> bool:
	# цель уже рядом — рубим стоя
	if _target != null and (not _target.alive or not _reach(_target)):
		_target = null
	if _target != null:
		_hit(_target)
		return false
	if ghost:
		# призрак не останавливается: бьёт не строевых на ходу, строй не замечает
		var near := world.grid.nearest_unit_loose(position, radius + LegionCfg.FOE_REACH)
		if near != null:
			_hit(near)
	else:
		var loose := world.grid.nearest_unit_loose(position, LegionCfg.FOE_AGGRO)
		if loose != null:
			if _reach(loose):
				_target = loose
				_hit(loose)
				return false
	var goal := _goal()
	if goal == Vector2.INF:
		world.foe_reached_cauldron(self)
		return false
	var stuck := not ghost and _in_rock()
	if stuck:
		goal = _rock_exit()
	var d := (goal - position).normalized()
	var sp := speed * (1.0 if ghost else world.terrain.speed_mult(position))
	if seal_slow_t > 0.0:
		sp *= LegionCfg.SEAL_SLOW_MULT
	if slow_t > 0.0:
		sp *= slow_mult   # «Неустойка»: просрочка тянет ход
	var nxt := position + d * sp * dt
	if not ghost:
		var blocker := world.grid.posted_blocking(nxt, LegionCfg.BLOCK_R + radius - 8.0)
		if blocker != null:
			if type_id == "beetle":
				var slip := _find_slip(d, sp * dt)
				if slip != Vector2.INF:
					position = slip
					_face(d)
					return true
			_target = blocker
			_hit(blocker)
			return false
		if not stuck and not world.terrain.walkable(nxt):
			nxt = _around_wall(nxt, goal)
	# INF — упёрся в стену и ищет обход: этот кадр стоит
	if nxt != Vector2.INF:
		position = nxt
		_dir = d
		_face(d)
	return nxt != Vector2.INF


## Следующая точка дороги; INF — дошёл до Котла.
func _goal() -> Vector2:
	if position.distance_to(world.cauldron_of(goal_side)) <= LegionCfg.CAULDRON_RADIUS:
		return Vector2.INF
	while _wp < _path.size() and _waypoint_done(_wp):
		_wp += 1
	if _wp >= _path.size():
		return world.cauldron_of(goal_side)
	return _path[_wp]


## Точка пути i пройдена: ближе WAYPOINT_EPS или уже за ней в пределах WAYPOINT_PASS_R —
## по ту сторону прямой через точку поперёк следующего отрезка (см. legion_cfg).
func _waypoint_done(i: int) -> bool:
	var p := _path[i]
	var d := position.distance_to(p)
	if d <= LegionCfg.WAYPOINT_EPS:
		return true
	if d > LegionCfg.WAYPOINT_PASS_R or i + 1 >= _path.size():
		return false
	return (position - p).dot(_path[i + 1] - p) > 0.0


## v19: враг оказался в непроходимой клетке (в бою не бывает: толчки проверяют рельеф, но
## защиты не было — verifier d26f8623: Юрист, поставленный в скалу, стоял там навсегда). Такой
## идёт к ближайшей земле, не упираясь в стены.
func _in_rock() -> bool:
	return not world.terrain.walkable(position)


## Куда идти из скалы: к ближайшей земле; земли нет — стоять.
func _rock_exit() -> Vector2:
	var q := world.terrain.nearest_open(position)
	return position if q == Vector2.INF else q


## v19: шаг nxt упёрся в стену — куда шагнуть вместо него; INF — скользить некуда, обход по A*
## заказан (_detour), этот кадр стоим.
func _around_wall(nxt: Vector2, goal: Vector2) -> Vector2:
	var slide := _slide(nxt - position)
	if slide == Vector2.INF:
		_detour(goal)
	return slide


## v19: шаг упёрся в стену — скольжение вдоль неё по одной из осей (как у бойца, unit.gd
## _step_toward). Точка пути «пройдена» уже в 32 px (WAYPOINT_PASS_R), и на углу обхода враг
## срезает диагональ в торец стены — скольжение доводит его до угла. INF — скользить некуда
## или почти некуда (стена поперёк пути: ползти вдоль неё — медленно, пусть ищет обход).
func _slide(v: Vector2) -> Vector2:
	var min_len := v.length() * LegionCfg.FOE_SLIDE_MIN
	for part: Vector2 in [Vector2(v.x, 0.0), Vector2(0.0, v.y)]:
		if part.length() >= min_len and part.length_squared() > 0.0001 \
				and world.terrain.walkable(position + part):
			return position + part
	return Vector2.INF


## v19 «стены по рисунку»: к точке пути враг идёт по прямой, и после отброса с дороги прямая
## могла лечь сквозь стену. Упёрся — вставляем обход по A* до этой точки, дальше прежний путь.
## Не чаще FOE_DETOUR_CD: если обхода нет, враг ждёт, а не ищет путь каждый кадр.
func _detour(goal: Vector2) -> void:
	if world.now < _detour_at:
		return
	_detour_at = world.now + LegionCfg.FOE_DETOUR_CD
	var around := world.terrain.find_path(position, goal)
	if _wp + 1 < _path.size():
		around.append_array(_path.slice(_wp + 1))
	_path = around
	_wp = 0


## Жук ищет дыру: пробует уйти в сторону под углом, если там не строй и не вода.
## Углы пробуются по порядку — сначала по часовой; в правой половине поля «Схватки» — зеркально
## (B-294): иначе жуки обеих половин сначала уходят на запад, а это разные стороны от Котла.
func _find_slip(d: Vector2, step: float) -> Vector2:
	var hand := -1.0 if world.terrain.mirror_x and position.x > world.world_size.x * 0.5 else 1.0
	for ang in LegionCfg.BEETLE_SLIP_ANGLES:
		var p := position + d.rotated(ang * hand) * step
		if world.terrain.walkable(p) and world.grid.posted_blocking(p, LegionCfg.BLOCK_R) == null:
			return p
	return Vector2.INF


func _reach(u: Legionnaire) -> bool:
	var r := radius + LegionCfg.UNIT_RADIUS + LegionCfg.FOE_REACH
	return position.distance_squared_to(u.position) <= r * r


func _hit(u: Legionnaire) -> void:
	_dir = (u.position - position).normalized()
	_face(u.position - position)
	if _atk_cd > 0.0:
		view.prepare_attack(_atk_cd, u)
		return
	_atk_cd = float(def["cd"])
	view.attack_impact()
	u.last_hit_side = -1
	u.take_damage(float(def["dmg"]), position)


func _melee_if_close() -> void:
	var u := world.grid.nearest_unit(position, radius + LegionCfg.UNIT_RADIUS + LegionCfg.FOE_REACH)
	if u != null:
		_hit(u)


# ── Нотариус ────────────────────────────────────────────────────────────────

## Встаёт, как только любой боец ближе standoff, и печатает издалека — пока за своей пехотой.
func _signer_holds() -> bool:
	if world.grid.nearest_unit(position, float(def["standoff"])) == null:
		return false
	return world.grid.count_escort(position, LegionCfg.SIGNER_ESCORT_R) > 0


func _tick_stamp(dt: float) -> void:
	if stamp_t >= 0.0:
		stamp_t -= dt
		if stamp_t < 0.0:
			view.attack_impact()
			world.stamp_hit(stamp_pos, float(def["stamp_r"]), float(def["stamp_dmg"]), position)
		else:
			view.prepare_special(stamp_t, LegionCfg.SIGNER_WARN)
		return
	_skill_cd -= dt
	if _skill_cd > 0.0:
		return
	var at := world.grid.densest_unit_point(position, float(def["range"]), float(def["stamp_r"]))
	if at == Vector2.INF:
		return
	_skill_cd = float(def["stamp_cd"])
	stamp_pos = at
	stamp_t = LegionCfg.SIGNER_WARN
	_face(at - position)
	view.prepare_special(stamp_t, LegionCfg.SIGNER_WARN)


# ── Юрист (v17 LAW, DESIGN_V17 §3.1) ────────────────────────────────────────

## true — ход занят Юристом (идёт к участку или зачитывает); false — обычный путь к Котлу.
## Цель выбирается один раз и держится, пока участок жив: телеграф не должен прыгать.
func _tick_lawyer(dt: float) -> bool:
	queue_redraw()
	if law_c != null and not _law_target_ok():
		_law_drop()
	if law_c == null:
		_law_scan -= dt
		if _law_scan <= 0.0:
			_law_scan = LegionCfg.LAWYER_RESCAN
			_law_pick()
	if law_c == null:
		if _law_off_road:
			# сошёл с дороги к участку, которого больше нет: к Котлу — новым путём
			_law_off_road = false
			_path = world.terrain.find_path(position, world.cauldron_of(goal_side))
			_wp = 0
		return false
	if law_read_t >= 0.0:
		law_read_t -= dt
		if law_read_t < 0.0:
			var c := law_c
			var seg := law_seg
			_law_drop()
			_law_scan = 0.0
			view.attack_impact()
			world.tear_segment(c, seg)
		else:
			view.prepare_special(law_read_t, LegionCfg.LAWYER_READ_TIME, law_c)
		return true
	var to_goal := law_pos - position
	if to_goal.length() <= LegionCfg.LAWYER_REACH:
		law_read_t = LegionCfg.LAWYER_READ_TIME
		_face(to_goal)
		view.prepare_special(law_read_t, LegionCfg.LAWYER_READ_TIME, law_c)
		return true
	while _wp < _path.size() - 1 and _waypoint_done(_wp):
		_wp += 1
	var goal := _path[_wp] if _wp < _path.size() else law_pos
	var stuck := _in_rock()
	if stuck:
		goal = _rock_exit()
	var d := (goal - position).normalized()
	var sp := speed * world.terrain.speed_mult(position)
	if seal_slow_t > 0.0:
		sp *= LegionCfg.SEAL_SLOW_MULT
	# последний шаг не перелетает точку: иначе на малом dt Юрист дрожал бы вокруг неё
	var nxt := position + d * minf(sp * dt, position.distance_to(goal))
	# v19: сквозь стену не идёт — как пехота (_around_wall): скольжение, иначе обход по A*
	if not stuck and not world.terrain.walkable(nxt):
		nxt = _around_wall(nxt, goal)
		if nxt == Vector2.INF:
			return true
	position = nxt
	_dir = d
	_face(d)
	return true


func _law_target_ok() -> bool:
	return law_seg >= 0 and law_seg < law_c.seg_count() and law_c.seg_alive(law_seg) \
		and world.contracts.contracts.has(law_c)


## Самый людный живой участок в LAWYER_SEEK_R от себя: каждый боец в строю перевешивает
## LAWYER_MANNED_WEIGHT px расстояния, при равенстве — ближайший; точка — середина участка.
## До v20 — просто ближайший, и почти всегда пустой (B-061): Юрист ничего не решал.
func _law_pick() -> void:
	var best := -INF
	var spot := Vector2.INF
	for c: Contract in world.contracts.contracts:
		for s in c.seg_count():
			if not c.seg_alive(s):
				continue
			var d := position.distance_to(c.seg_center(s))
			if d > LegionCfg.LAWYER_SEEK_R:
				continue
			var score := float(c.seg_manned(s)) * LegionCfg.LAWYER_MANNED_WEIGHT - d
			if score <= best:
				continue
			var p := _law_spot(c, s)
			if p != Vector2.INF:
				best = score
				law_c = c
				law_seg = s
				spot = p
	if law_c == null:
		return
	law_pos = spot
	_path = world.terrain.find_path(position, law_pos)
	_wp = 0
	_target = null
	_law_off_road = true
	world.stats["lawyer_targets"] = int(world.stats.get("lawyer_targets", 0)) + 1


## v19: где Юрист встанет зачитывать участок — точка самого участка на проходимой земле, до
## которой он дойдёт, ближайшая к середине; INF — такой нет (участок за оградой, над водой, в щели
## между скалами), и участок не цель. Раньше целью была середина: Юрист шёл к договору в поле за
## оградой сквозь ограду, а к середине над водой доходил до берега и стоял, пока участок жив
## (verifier d26f8623 — «Болото», «Мост», щель у саркофага «Пустыря»).
func _law_spot(c: Contract, s: int) -> Vector2:
	var t := world.terrain
	var mid := c.seg_center(s)
	if t.walkable(mid) and t.connected(position, mid):
		return mid
	var best := Vector2.INF
	var poly: PackedVector2Array = c.seg_polys[s]
	for i in range(1, poly.size()):
		var n := maxi(1, ceili(poly[i - 1].distance_to(poly[i]) / (LegionCfg.CELL * 0.5)))
		for k in range(n + 1):
			var p := poly[i - 1].lerp(poly[i], float(k) / float(n))
			if p.distance_squared_to(mid) < best.distance_squared_to(mid) \
					and t.walkable(p) and t.connected(position, p):
				best = p
	return best


func _law_drop() -> void:
	view.cancel_action()
	law_c = null
	law_seg = -1
	law_read_t = -1.0


## Доля зачитки 0..1; −1 — не читает.
func law_read_progress() -> float:
	if law_read_t < 0.0:
		return -1.0
	return 1.0 - law_read_t / LegionCfg.LAWYER_READ_TIME


## Телеграф Юриста поверх мира: пунктир к точке, подсветка участка, печать «!» над целью,
## кольцо зачитки над головой. Видно с момента выбора цели — ответить есть когда.
func draw_law_telegraph(canvas: Node2D) -> void:
	if not alive or law_c == null:
		return
	var color := LegionCfg.LAWYER_COLOR
	var ink := Color(0.08, 0.03, 0.02, 0.7)
	var pulse := 0.5 + 0.5 * sin(world.now * 8.0)
	var reading := law_read_t >= 0.0
	# участок-цель: тёмная подложка и пульсирующая заливка — видно и в толпе, и на лаве
	var poly := law_c.seg_polys[law_seg]
	canvas.draw_polyline(poly, ink, 12.0, true)
	canvas.draw_polyline(poly, Color(LegionCfg.LAWYER_TEAR_COLOR if reading else color,
		0.55 + 0.45 * pulse), 7.0, true)
	if not reading:
		canvas.draw_dashed_line(position, law_pos, ink, 6.0, LegionCfg.LAWYER_DASH, true, true)
		canvas.draw_dashed_line(position, law_pos, color, 3.0, LegionCfg.LAWYER_DASH, true, true)
	var seal := law_pos + Vector2(0.0, -LegionCfg.LAWYER_SEAL_LIFT)
	var r := LegionCfg.LAWYER_SEAL_R * (1.0 + 0.15 * pulse)
	if reading:
		# зачитка: кольцо-прогресс вокруг печати над целью и вокруг значка Юриста
		var k := law_read_progress()
		var ring := LegionCfg.LAWYER_RING_R
		var fill := color.lerp(LegionCfg.LAWYER_TEAR_COLOR, k)
		for at: Vector2 in [seal, position + lawyer_badge_offset()]:
			canvas.draw_arc(at, ring, 0.0, TAU, 32, ink, 7.0, true)
			canvas.draw_arc(at, ring, -PI * 0.5, -PI * 0.5 + TAU * k, 32, fill, 4.5, true)
			ring = LegionCfg.LAWYER_RING_R * 0.7
	canvas.draw_circle(seal, r + 2.0, ink)
	canvas.draw_circle(seal, r, Color(0.75, 0.12, 0.1))
	canvas.draw_arc(seal, r, 0.0, TAU, 24, color, 2.0, true)
	var font := ThemeDB.fallback_font
	var fs := 18
	var sz := font.get_string_size("!", HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	canvas.draw_string(font, seal + Vector2(-sz.x * 0.5, sz.y * 0.32), "!",
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


## Где над Юристом висит значок «§» (и малое кольцо зачитки).
func lawyer_badge_offset() -> Vector2:
	return Vector2(0.0, -float(def["body"]) + 2.0)


# ── Нотариус: телеграф печати (v17 LAW, DESIGN_V17 §3.2) ─────────────────────

## Доля роста круга на земле 0..1 в последние STAMP_TELEGRAPH с перед ударом; −1 — круга нет.
func stamp_telegraph() -> float:
	if not alive or stamp_t < 0.0 or stamp_t > LegionCfg.STAMP_TELEGRAPH:
		return -1.0
	return 1.0 - stamp_t / LegionCfg.STAMP_TELEGRAPH


## Замах (весь SIGNER_WARN) — тонкий контур, куда упадёт; последние 0.6 с круг растёт от
## центра до stamp_r: момент удара — когда заливка упрётся в контур. У ног нотариуса —
## кольцо-прогресс замаха; linked — ещё и пунктир от него к кольцу (StampThrower).
func draw_stamp_warning(canvas: Node2D, color: Color, linked: bool = false) -> void:
	if not alive or stamp_t < 0.0:
		return
	StampThrower.draw(canvas, self, color, linked)
	var r := float(def["stamp_r"])
	canvas.draw_arc(stamp_pos, r, 0.0, TAU, 32, Color(color, 0.55), 1.5, true)
	var k := stamp_telegraph()
	if k < 0.0:
		return
	var grow := 1.0 - (1.0 - k) * (1.0 - k)   # ease-out: круг быстро заявляет место
	canvas.draw_circle(stamp_pos, r * grow, Color(color, 0.25 + 0.3 * k))
	canvas.draw_arc(stamp_pos, r * grow, 0.0, TAU, 32, Color(color, 0.9), 2.0, true)
	canvas.draw_arc(stamp_pos, r, 0.0, TAU, 32, Color(color, 0.6 + 0.4 * k), 2.5, true)


# ── Босс ────────────────────────────────────────────────────────────────────

## Осада не удаляет врага из волны. Первый удар отложен, чтобы успеть ответить на тост.
func begin_siege() -> void:
	if state == State.SIEGE:
		return
	state = State.SIEGE
	_target = null
	ram_t = -1.0
	_ram_run = -1.0
	_atk_cd = LegionCfg.BOSS_SIEGE_INTERVAL
	world.stats["boss_sieges"] = int(world.stats.get("boss_sieges", 0)) + 1
	world.toast("ПРОРАБ ОСАЖДАЕТ КОТЁЛ! Переведи строй к котлу!", &"warn")
	view.play_once(&"roar")


func _tick_siege() -> void:
	if _atk_cd > 0.0:
		view.prepare_attack(_atk_cd)
		return
	_atk_cd = LegionCfg.BOSS_SIEGE_INTERVAL
	_face(world.cauldron_of(goal_side) - position)
	view.attack_impact()
	world.damage_cauldron(LegionCfg.BOSS_SIEGE_DAMAGE, type_id, goal_side, origin)


func _tick_boss(dt: float) -> bool:
	_skill_cd -= dt
	_roar_cd -= dt
	if ram_t >= 0.0:
		ram_t -= dt
		if ram_t <= 0.0:
			ram_t = -1.0
			_ram_run = 0.0
			_ram_start = position
			# v19: разбег — ход на цель тарана; давка «в лоб» смотрит на _dir (verifier d26f8623:
			# таран шёл со старым направлением, и Прораб, таранящий фланг сбоку, мог не давить)
			if ram_pos != position:
				_dir = (ram_pos - position).normalized()
			view.prepare_special(LegionCfg.BOSS_RAM_TIME, LegionCfg.BOSS_RAM_TIME)
		return true
	if _ram_run >= 0.0:
		_ram_run += dt
		view.prepare_special(LegionCfg.BOSS_RAM_TIME - _ram_run, LegionCfg.BOSS_RAM_TIME)
		var k := minf(1.0, _ram_run / LegionCfg.BOSS_RAM_TIME)
		position = _safe_push(position, _ram_start.lerp(ram_pos, k))
		if k >= 1.0:
			_ram_run = -1.0
			_skill_cd = float(def["ram_cd"])
			_ram_hit()
		return true
	if _roar_cd <= 0.0:
		_roar_cd = float(def["roar_cd"])
		_summon_escort()
	if _skill_cd > 0.0:
		return false
	# Рёв начинается до контакта. Ищем именно строй, а не бегущую приманку.
	var best: Legionnaire = null
	var dist := LegionCfg.BOSS_RAM_RANGE
	for u in world.units:
		if not u.alive or u.state != Legionnaire.State.POSTED:
			continue
		var d := position.distance_to(u.position)
		if d < dist and _safe_push(position, u.position).is_equal_approx(u.position):
			best = u
			dist = d
	if best == null:
		return false
	ram_pos = best.position
	ram_t = LegionCfg.BOSS_RAM_WARN
	_target = null
	_face(ram_pos - position)
	view.play_once(&"roar")
	world.boss_roared.emit(self, ram_pos)
	world.toast("ПРОРАБ: ОСВОБОДИТЬ УЧАСТОК!", &"warn")
	return true


func _summon_escort() -> void:
	var rest := _path.slice(_wp)
	for i in int(def["escort"]):
		var center := (float(def["escort"]) - 1.0) / 2.0
		var offset := Vector2((i - center) * LegionCfg.BOSS_ESCORT_SPACING, 0)
		var at := _safe_push(position, position + offset + LegionCfg.BOSS_ESCORT_OFFSET)
		# свита — призванные: душ, опыта и премии не дают (пакет staff, DESIGN_V15 §12 п.4)
		world.spawn_foe_on_path("zombie", rest, at, true)


func _ram_hit() -> void:
	view.attack_impact()
	# Прямой поиск: при разбеге сетка ещё содержит позиции начала кадра.
	for u in world.units_near(ram_pos, float(def["ram_r"])):
		u.take_damage(float(def["ram_dmg"]), _ram_start)
		if not u.alive:
			continue
		if not u.post.is_empty():
			u.post["unit"] = null
		u.set_free()
		var away := (u.position - ram_pos).normalized()
		if away == Vector2.ZERO:
			away = (ram_pos - _ram_start).normalized()
		u.position = _safe_push(u.position, u.position + away * LegionCfg.BOSS_PUSH_DIST)
	_target = null
	# Возвращаться к уже пройденной точке дороги после рывка нельзя.
	_path = world.terrain.find_path(position, world.cauldron_of(goal_side))
	_wp = 0
	world.boss_rammed.emit(self, ram_pos)


func _safe_push(from: Vector2, to: Vector2) -> Vector2:
	var steps := maxi(1, ceili(from.distance_to(to) / LegionCfg.BOSS_MOVE_STEP))
	var result := from
	for i in range(1, steps + 1):
		var next := from.lerp(to, float(i) / steps)
		if not world.terrain.walkable(next):
			break
		result = next
	return result


func draw_ram_warning(canvas: Node2D) -> void:
	if ram_t < 0.0 and _ram_run < 0.0:
		return
	var color := LegionCfg.BOSS_RAM_COLOR
	var r := float(def["ram_r"])
	var k := 1.0 - maxf(0.0, ram_t) / LegionCfg.BOSS_RAM_WARN
	canvas.draw_circle(ram_pos, r, Color(color, 0.15 + 0.2 * k))
	canvas.draw_arc(ram_pos, r, 0, TAU, 48, color, 3.0, true)
	canvas.draw_arc(ram_pos, r * (1.0 - k), 0, TAU, 48, color, 2.0, true)
	canvas.draw_line(position, ram_pos, Color(color, 0.65), 3.0, true)


func _face(direction: Vector2) -> void:
	if direction.length_squared() > 0.0025:
		view.set_direction(direction)


func apply_seal_slow() -> void:
	seal_slow_t = LegionCfg.SEAL_SLOW_TIME


func _draw() -> void:
	if type_id == "lawyer" and alive:
		_draw_lawyer_badge()
		return
	if type_id != "shield_inspector" or not alive:
		return
	var size := LegionCfg.CORE_SHIELD_SIZE
	var at := _dir * size.x + Vector2(0, -float(def["body"]) * 0.5)
	var poly := PackedVector2Array([
		at + Vector2(-size.x, -size.y), at + Vector2(size.x, -size.y),
		at + Vector2(size.x, 0), at + Vector2(0, size.y), at + Vector2(-size.x, 0),
	])
	draw_colored_polygon(poly, LegionCfg.CORE_SHIELD_FILL)
	poly.append(poly[0])
	draw_polyline(poly, LegionCfg.CORE_SHIELD_RIM, 2.0, true)
	draw_circle(at + Vector2(0, -size.y * 0.35), 2.2, LegionCfg.CORE_SHIELD_RIM)


## Значок Юриста над головой — «§» цвета угрозы на тёмной плашке: отличить от нотариуса с одного
## взгляда (силуэт у них общий, своего спрайта пока нет — долг в DEBT.md).
func _draw_lawyer_badge() -> void:
	# ореол цвета угрозы под ногами — силуэт выделяется в толпе без своего спрайта; не золото:
	# золотой ореол — у элитного (vfx-clarity 29.09)
	draw_set_transform(Vector2(0.0, -2.0), 0.0, Vector2(1.0, 0.4))
	draw_circle(Vector2.ZERO, 15.0, Color(LegionCfg.LAWYER_COLOR, 0.35))
	draw_arc(Vector2.ZERO, 15.0, 0.0, TAU, 28, LegionCfg.LAWYER_COLOR, 2.5, true)
	draw_set_transform(Vector2.ZERO)
	var at := lawyer_badge_offset()
	draw_circle(at, 9.0, Color(0.08, 0.05, 0.02, 0.9))
	draw_arc(at, 9.0, 0.0, TAU, 20, LegionCfg.LAWYER_COLOR, 2.0, true)
	var font := ThemeDB.fallback_font
	var fs := 14
	var sz := font.get_string_size("§", HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(font, at + Vector2(-sz.x * 0.5, sz.y * 0.3), "§", HORIZONTAL_ALIGNMENT_LEFT, -1,
		fs, LegionCfg.LAWYER_COLOR)
