class_name Legionnaire
extends Node2D
##
## Подрядчик-скелет. Одна руна — два состояния бойца: В СТРОЮ (стена) и НАТИСК (удар).
##
## Машина состояний — enum (скилл state-machine: < 6 состояний без тяжёлых enter/exit), и
## тикает её мир, а не _process каждого бойца: порядок шага кадра задан спекой (§3), и 140
## отдельных _process его бы размазали. Поиск врагов — через сетку мира, без аллокаций.
##
## v15: вид бойца `kind` (подрядчик/вахтёр/счетовод) — все боевые числа из LegionCfg.UNIT_KINDS
## (поле `spec`), поправки кампании поверх — как раньше. Дальний вид (ranged) не бьёт сам, а
## просит мир выпустить снаряд (LegionWorld.fire_projectile). Рождается только через
## LegionWorld.spawn_unit(kind, pos, home); `home` — постройка-хозяин (штат, пакет staff).
##

## RALLY (v18) — «Сбор»: идёт к точке, которую указал игрок (R), без места в строю; дошёл —
## снова свободен. В конце перечня: числовые значения прежних состояний не сдвигаются.
enum State { FREE, MARCH, POSTED, CHARGE, DEAD, RALLY }

## Кто из простаивающих рисует пузырь в этом кадре: {instance_id: true}. Считается раз в кадр
## на весь мир (static — один кэш на всех бойцов): представитель кучки — первый по world.units
## в IDLE_ICON_CLUSTER_R от прочих представителей того же вида и причины, и на поле не больше
## LegionCfg.IDLE_ICON_MAX, но каждой паре (вид, причина) — хотя бы один (vfx-clarity 29.09: у Котла
## висело до 20 пузырей). Чистый вид.
static var _icon_frame := -1
static var _icon_owners: Dictionary = {}

var world: LegionWorld = null
var view: CharView = null
## Сторона боя (PvpSide.index; одиночка — 0) и поле договоров этой стороны: строй, вербовка,
## аура — только своих договоров. Ставит LegionWorld.spawn_unit.
var side := 0
var field: ContractField = null
## Чей удар был последним (сторона; −1 — проверяющий или никто): души за гибель — ей (PvP).
var last_hit_side := -1
var state := State.FREE
var kind: StringName = LegionCfg.KIND_LABORER
## Параметры вида (ссылка на словарь LegionCfg.UNIT_KINDS[kind]; только чтение).
var spec: Dictionary = LegionCfg.UNIT_KINDS[LegionCfg.KIND_LABORER]
## Постройка-хозяин: освободившееся штатное место (пакет staff). null — Котёл/без хозяина.
var home: Object = null
var hp := LegionCfg.UNIT_HP
var max_hp := LegionCfg.UNIT_HP
var post: Dictionary = {}          ## место в строю (словарь договора) или {}
var contract: Contract = null
## Договор, из строя которого боец вышел натиском (участок растаял или его запустил игрок):
## пока тот жив, раздача мест (ContractField) не возвращает его на места ЭТОГО договора —
## только к другим линиям (Игорь 29.09.2026). −1 — запрета нет; настоящие id договоров
## начинаются с 1, а превью/шаблоны бота строятся мимо ContractField._create() с id 0 —
## такой «договор» никого не банит. Идущего на место (MARCH) запрет не касается:
## тот ещё не стоял в строю.
var no_return_id := -1
var alive := true
var idx := 0                        ## индекс в world.units на этот кадр (сетка поиска)
## Пакет hero: Аврал (§12 п.8) множит скорость и урон на время — ставит и снимает LegionHero,
## сам боец их не трогает.
var item_slow_t := 0.0
var haste_speed_mult := 1.0
var haste_dmg_mult := 1.0
## «Кадровое агентство» (items/): нанятый элитный — толще и сильнее, в короне.
var elite := false
var elite_dmg_mult := 1.0
## «Обряд» (треугольник): участники сильнее на время — ставит и снимает LegionFigures.
var rite_dmg_mult := 1.0
## «Каре» заряженный выпуск: входящий урон × это, пока идёт срок (ставит LegionFigures).
var guard_dmg_mult := 1.0
## «Комиссия по упокоению»: одноразовый личный щит — доля max_hp. Снимает урон РАНЬШЕ здоровья;
## выдаётся один раз на бойца после подготовки фигуры, подновление линии его не пополняет.
var shield_hp := 0.0
var shield_given := false
## «Комиссия» заряженный выпуск: id группы залпа — по нему участники ЭТОЙ группы бьют помеченную
## цель сильнее (Foe.mark_group_id). −1 — группа не метит.
var mark_group_id := -1
## «Комиссия» в «Схватке» (J6): id группы, пометившей ЭТОГО бойца чужим залпом. У врага PvE то же
## поле зовётся mark_group_id, но у бойца оно уже занято своей группой — метку цели держим
## отдельно. −1 — не помечен; mark_hit_t — срок метки (как Foe.mark_t).
var mark_hit_group := -1
var mark_hit_t := 0.0
## «Неустойка» в «Схватке» (J6): замедление чужого залпа — скорость × ult_slow_mult, пока
## ult_slow_t > 0. У врага PvE это slow_mult/slow_t; правила те же.
var ult_slow_mult := 1.0
var ult_slow_t := 0.0

var idle_time := 0.0
var idle_reason: StringName = &"no_contract"
var projectile_sealed := false
var _aura_t := 0.0
var _aura_near := false
var _seal_t := 0.0
var _seal_cd := 0.0

var _path := PackedVector2Array()
var _path_i := 0
var _atk_cd := 0.0
var _bonus_t := 0.0
var _charge_t := 0.0
var _charge_dir := Vector2.RIGHT
var _charge_run := 0.0
## Предел пробега этого бойца в натиске (фигуры: «крест-накрест» — до центра чужой петли);
## у залпа свой общий предел volley["cap"] (кольцо), берётся меньший.
var _charge_cap := INF
## v17 CTL: залп натиска — словарь, общий для всех бойцов одного выпуска (LegionWorld._volley):
## стрелка, сила рогатки, точный срыв, комбо. {} — боец не в натиске.
var _volley: Dictionary = {}
## Множитель рогатки × комбо последнего удара с разбега — держится на окно CHARGE_BONUS_TIME.
var _bonus_mult := 1.0
var _first_strike := false
var _dead_t := 0.0
var _moving := false
var _facing := 1.0
## v18 «Давка»: оглушение после прорыва участка — боец не бьёт и не ходит.
var _stun_t := 0.0
var _rally_t := 0.0
## PvP: сколько шагов ещё не искать цель (вокруг было пусто) — PvpRules.IDLE_SCAN_SKIP.
var _scan_skip := 0
## PvP: то же для поиска «обороны дома» (_guard_home) — свой счётчик, чтобы не глушить друг друга.
var _guard_skip := 0


func setup(w: LegionWorld, at: Vector2, new_kind: StringName = LegionCfg.KIND_LABORER) -> void:
	world = w
	field = w.contracts
	position = at
	kind = new_kind if LegionCfg.UNIT_KINDS.has(new_kind) else LegionCfg.KIND_LABORER
	spec = LegionCfg.UNIT_KINDS[kind]
	hp = float(spec["hp"])
	max_hp = hp
	view = CharView.new()
	add_child(view)
	# integrate1: у каждого вида свои спрайты (art1: guard/clerk в CfgAnim.CHARS), подрядчик —
	# прежний скелет. Тонировка-заглушка F0 снята — вид читается силуэтом, не цветом.
	var char_id := "skeleton" if kind == LegionCfg.KIND_LABORER else String(kind)
	view.setup(char_id if CfgAnim.CHARS.has(char_id) else "skeleton", float(spec["body_h"]))


## Элитный боец постройки («Кадровое агентство»): HP ×hp_mult, урон ×dmg_mult, корона.
func make_elite(hp_mult: float, dmg_mult: float) -> void:
	if elite:
		return
	elite = true
	elite_dmg_mult = dmg_mult
	hp *= hp_mult
	max_hp *= hp_mult
	view.scale = Vector2.ONE * CfgItems.ELITE_SCALE
	view.modulate *= CfgItems.ELITE_TINT
	var mark := LegionEliteMark.new()
	mark.position = Vector2(0.0, view.ground_px() * CfgItems.ELITE_SCALE)
	add_child(mark)
	move_child(mark, 0)
	mark.setup(world, view.body_h * CfgItems.ELITE_SCALE, CfgItems.ELITE_COLOR)


func tick(dt: float) -> void:
	view.begin_action_tick()
	_tick_state(dt)
	view.end_action_tick()


func _tick_state(dt: float) -> void:
	item_slow_t = maxf(0.0, item_slow_t - dt)
	ult_slow_t = maxf(0.0, ult_slow_t - dt)
	if mark_hit_t > 0.0:
		mark_hit_t = maxf(0.0, mark_hit_t - dt)
		if mark_hit_t <= 0.0:
			mark_hit_group = -1
	_atk_cd -= dt
	_seal_t = maxf(0.0, _seal_t - dt)
	_seal_cd = maxf(0.0, _seal_cd - dt)
	_tick_aura(dt)
	if state == State.FREE:
		idle_time += dt
	else:
		idle_time = 0.0
	if not world.no_view:
		queue_redraw()
	_bonus_t -= dt
	if _stun_t > 0.0 and state != State.DEAD:
		view.cancel_action()
		_stun_t -= dt
		view.rotation = 0.0 if _stun_t <= 0.0 else sin(_stun_t * 26.0) * 0.35
		if state == State.FREE or state == State.MARCH or state == State.RALLY:
			if _moving:
				_moving = false
				view.set_locomotion(0.0)
			return
	var moved := false
	match state:
		State.FREE:
			moved = _tick_free(dt)
		State.MARCH:
			moved = _tick_march(dt)
		State.POSTED:
			_tick_posted()
		State.CHARGE:
			moved = _tick_charge(dt)
		State.RALLY:
			moved = _tick_rally(dt)
		State.DEAD:
			_tick_dead(dt)
			return
	if moved != _moving:
		_moving = moved
		view.set_locomotion(1.0 if moved else 0.0)


# ── Переходы ────────────────────────────────────────────────────────────────

## Взять место в строю: маршрут A* в обход скал и воды.
func assign(c: Contract, p: Dictionary, route := PackedVector2Array()) -> void:
	var path := route if not route.is_empty() else field.recruit_path(position, p["pos"])
	if path.is_empty():
		return
	contract = c
	post = p
	p["unit"] = self
	_path = path
	_path_i = 0
	state = State.MARCH


## Место исчезло до прихода (участок растаял на марше) — снова свободен.
func set_free() -> void:
	if not post.is_empty() and post["unit"] == self:
		post["unit"] = null
	state = State.FREE
	post = {}
	contract = null


## v18: оглушить (прорыв участка давкой). Свободный и идущий на место стоят; строй и натиск —
## не оглушаются (в строй оглушённый не попадает: вербовка ждёт, пока враг не отойдёт).
func stun(t: float) -> void:
	_stun_t = maxf(_stun_t, t)
	view.react_hit()


func is_stunned() -> bool:
	return _stun_t > 0.0


## v18: отлететь к точке по прямой шагами по рельефу — в воду и скалу не выталкиваем.
func knock_to(to: Vector2) -> void:
	var d := to - position
	var dist := d.length()
	if dist < 0.5:
		return
	d /= dist
	var left := dist
	while left > 0.0:
		var nxt := position + d * minf(4.0, left)
		if not world.terrain.walkable(nxt):
			break
		position = nxt
		left -= 4.0

## v18 «Сбор»: идти по маршруту к точке игрока. Только свободный (строй и натиск не трогаем).
func rally_to(path: PackedVector2Array) -> void:
	if state != State.FREE or path.is_empty():
		return
	_path = path
	_path_i = 0
	_rally_t = LegionCfg.RALLY_MAX_T
	state = State.RALLY


## Таяние/расторжение участка: бег по стрелке. volley — залп выпуска (v17: сила рогатки,
## точный срыв, комбо); пустой — прежний натиск ровно с прежними числами.
## Запомнить договор строя (no_return_id): боец не возвращается на его места сам.
func start_charge(dir: Vector2, volley: Dictionary = {}, cap := INF) -> void:
	if contract != null:
		no_return_id = contract.id
	post = {}
	contract = null
	state = State.CHARGE
	_charge_dir = dir
	_charge_cap = cap
	_volley = volley
	_charge_t = LegionCfg.CHARGE_TIME * float(volley.get("range", 1.0))
	_charge_run = 0.0
	_first_strike = true
	if not volley.is_empty():
		volley["units"] = int(volley["units"]) + 1
		# «Комиссия»: залп помечает цель — по id группы бойцы ЗНАЮТ, чью метку усиливать
		mark_group_id = int(volley.get("mark_group", -1))


## Натиск окончен (удар, дистанция, упёрся): залп узнаёт, что бойцом меньше.
func _end_charge() -> void:
	if state == State.CHARGE:
		state = State.FREE
	if not _volley.is_empty():
		world.on_charge_unit_done(_volley)
		_volley = {}


func take_damage(amount: float, from: Vector2) -> void:
	if not alive:
		return
	var a := amount
	if state == State.POSTED and not post.is_empty():
		if contract != null and field.in_package(contract, int(post["seg"])):
			a *= LegionCfg.PACKAGE_DAMAGE_MULT
		var n: Vector2 = post["normal"]
		if n.dot(from - position) > 0.0:
			# union_contract (пакет flow, world.mods): доп. снижение урона в строю сверх брони
			# вида спереди (front_armor: подрядчик ×0,7, вахтёр ×0,5).
			a *= maxf(0.0, float(spec["front_armor"]) - world.mod_add("hold_armor"))
		if contract != null and contract.figure == ContractShape.SQUARE:
			a *= FigureCfg.SQUARE_DMG_MULT   # «Каре» (D-1002-03): строй квадрата держит удар
	# «Каре» заряженный выпуск: защитный бафф участников держится и в натиске, и в строю
	a *= guard_dmg_mult
	if world.dev_invuln:
		a = 0.0
	# «Комиссия»: личный щит принимает урон раньше здоровья (один раз на бойца)
	if shield_hp > 0.0 and a > 0.0:
		var absorbed := minf(shield_hp, a)
		shield_hp -= absorbed
		a -= absorbed
	hp -= a
	view.react_hit()
	if hp <= 0.0:
		_die()


func is_corpse_done() -> bool:
	return state == State.DEAD and _dead_t >= LegionCfg.CORPSE_TIME


func _die() -> void:
	alive = false
	if not post.is_empty():
		post["unit"] = null
	post = {}
	contract = null
	if state == State.CHARGE and not _volley.is_empty():
		world.on_charge_unit_done(_volley)
		_volley = {}
	state = State.DEAD
	_dead_t = 0.0
	view.set_locomotion(0.0)
	view.cancel_action()
	if view.has_clip(&"death"):
		view.rotation = 0.0
		view.position.y = 0.0
		view.play_once(&"death")
	world.on_unit_died(self)


func _tick_dead(dt: float) -> void:
	_dead_t += dt
	var k := minf(1.0, _dead_t / 0.35)
	# Новые кадры сами опускают тело: цельный поворот нужен лишь старой заглушке.
	if not view.has_clip(&"death"):
		view.rotation = k * 1.3 * _facing
		view.position.y = k * LegionCfg.UNIT_BODY_H * 0.25
	var fade := clampf((_dead_t - 0.6) / (LegionCfg.CORPSE_TIME - 0.6), 0.0, 1.0)
	modulate = Color(0.7, 0.7, 0.75, 0.85 * (1.0 - fade))


# ── Состояния ───────────────────────────────────────────────────────────────

func _tick_free(dt: float) -> bool:
	# стрелок видит врага на всю свою досягаемость: иначе счетовод бежал бы в рукопашную
	var foe := _target_near(_reach() + LegionCfg.CORE_FOE_RADIUS_MAX, true)
	if foe != null and _in_reach(foe):
		_free_strike(foe)
		return false
	return _guard_home(dt)


func _free_strike(foe: Node2D) -> void:
	# aggressive_lawyers (world.mods): множитель урона натиска чуть переживает сам натиск
	# (окно _bonus_t), поэтому поправка действует и здесь.
	var mult := float(spec["charge_dmg_mult"]) * world.mod_mult("charge_dmg_mult")
	_strike(foe, mult * _bonus_mult if _bonus_t > 0.0 else 1.0, _bonus_t > 0.0)


## «Оборона дома» (B-281, B-293, B-343): свободный не преследует (D-0925-09), кроме зоны дома —
## врага в HOME_GUARD_R от Котла своей стороны он идёт бить, если тот не дальше
## HOME_GUARD_PURSUE. Цель ушла из зоны или погибла — стоит, где стоит (домой не бежит): дальность
## призыва вне дома по-прежнему ощущается (D-0925-02). Поиск — только при поднятом флаге стороны
## (LegionWorld.home_threat) и только у тех, кто вообще может дотянуться до зоны.
func _guard_home(dt: float) -> bool:
	var t := _guard_target()
	if t == null:
		return false
	# бьёт цель сам, а не через _target_near: тот в PvP мог быть в пропуске и опоздать с ударом
	if _in_reach(t):
		_free_strike(t)
		return false
	var to := t.position - position
	var dist := to.length()
	var d := to / dist
	_face(d)
	var sp := float(spec["speed"]) * _item_speed() * world.terrain.speed_mult(position)
	# не глубже досягаемости: вплотную к врагу его обступали бы телом, а не оружием
	var step := minf(sp * dt, dist - _reach() - body_r(t) + LegionCfg.HOME_GUARD_STEP_IN)
	var nxt := position + d * step
	if not world.terrain.walkable(nxt):
		return false
	position = nxt
	# бегущий на врага — не простой: значок «Zz» над ним был бы враньём
	idle_time = 0.0
	return true


## Цель «обороны дома» или null: флаг стороны опущен, боец дальше, чем может дотянуться до зоны,
## или в зоне рядом никого.
func _guard_target() -> Node2D:
	if not world.home_threat(side):
		return null
	var home := world.cauldron_of(side)
	var lim := LegionCfg.HOME_GUARD_R + LegionCfg.HOME_GUARD_PURSUE
	if position.distance_squared_to(home) > lim * lim:
		return null
	# PvP: пустой поиск — пропуск IDLE_SCAN_SKIP шагов, как у _target_near, но своим счётчиком:
	# общий _scan_skip гасил бы и поиск в досягаемости, и наоборот
	if world.pvp and _guard_skip > 0:
		_guard_skip -= 1
		return null
	var t := world.grid.nearest_hostile_in_zone(position, LegionCfg.HOME_GUARD_PURSUE, side, home,
		LegionCfg.HOME_GUARD_R)
	if t == null and world.pvp:
		_guard_skip = PvpRules.IDLE_SCAN_SKIP
	return t


func _tick_march(dt: float) -> bool:
	if post.is_empty() or post["dead"] or contract == null or not contract.seg_alive(int(post["seg"])):
		set_free()
		return false
	# на марше отбивается от того, кто уже вплотную, но за врагами не гонится — идёт в строй
	var foe := _target_near(LegionCfg.MARCH_DEFEND_R, true)
	if foe != null and _in_reach(foe):
		_strike(foe, 1.0)
		return false
	if _path_i >= _path.size():
		_arrive()
		return false
	var goal := _path[_path_i]
	if position.distance_to(goal) <= LegionCfg.ARRIVE_EPS:
		_path_i += 1
		if _path_i >= _path.size():
			_arrive()
			return false
		goal = _path[_path_i]
	var sp := float(spec["speed"]) * _item_speed() * world.terrain.speed_mult(position)
	var step := minf(sp * dt, position.distance_to(goal))
	var d := (goal - position).normalized()
	position += d * step
	_face(d)
	return true


## Сбор: как марш, но без места — отбивается от вплотную подошедшего и идёт дальше; дошёл или
## вышло время — свободен там, где стоит.
func _tick_rally(dt: float) -> bool:
	_rally_t -= dt
	# срок — раньше драки: иначе боец в долгой рубке (осада босса) висел бы в сборе, не видимый
	# вербовке (находка verifier 26.09: 20 с в RALLY при сроке 8 с)
	if _rally_t <= 0.0 or _path_i >= _path.size():
		state = State.FREE
		return false
	var foe := _target_near(LegionCfg.MARCH_DEFEND_R, true)
	if foe != null and _in_reach(foe):
		_strike(foe, 1.0)
		return false
	var goal := _path[_path_i]
	if position.distance_to(goal) <= LegionCfg.ARRIVE_EPS:
		_path_i += 1
		if _path_i >= _path.size():
			state = State.FREE
			return false
		goal = _path[_path_i]
	var sp := float(spec["speed"]) * _item_speed() * world.terrain.speed_mult(position)
	var step := minf(sp * dt, position.distance_to(goal))
	var d := (goal - position).normalized()
	position += d * step
	_face(d)
	return true


func _arrive() -> void:
	position = post["pos"]
	state = State.POSTED
	var n: Vector2 = post["normal"]
	_face(n)


func _tick_posted() -> void:
	if not post.is_empty():
		_face(post["normal"] as Vector2)
	# «Обряд» (Игорь 26.09 о звезде: «пока они в звёздочке стоят, они не атакуют») — с D-1002-03
	# обряд держит строй треугольника
	if contract != null and contract.figure == ContractShape.TRIANGLE:
		return
	# строй ловит только пехоту: призрак проходит сквозь стену и строевому не по зубам —
	# кроме вида hits_ghosts (счетовод: аудит видит призраков и из строя)
	# v20: строй Юриста не трогает (Foe.is_law_immune) — его снимает игрок, а не строй
	var foe := _target_near(_reach() + 20.0, bool(spec["hits_ghosts"]), true)
	if foe != null and _in_reach(foe):
		_strike(foe, 1.0)


func _tick_charge(dt: float) -> bool:
	_charge_t -= dt
	var foe: Node2D = world.grid.charge_target(position, _charge_dir) if not world.pvp \
		else world.grid.charge_target_pvp(position, _charge_dir, side)
	if foe != null and _in_reach(foe):
		# удар с разбега: без ожидания отката и с множителем натиска
		_atk_cd = 0.0
		# v17: касание залпа — комбо, отброс, отклик (до удара: множитель комбо уже новый)
		_bonus_mult = 1.0
		var first := 1.0
		if not _volley.is_empty():
			world.on_charge_contact(self, foe, _volley)
			_bonus_mult = float(_volley["dmg"]) * float(_volley["combo_mult"])
			if _first_strike and bool(_volley["perfect"]):
				first = LegionCfg.PERFECT_FIRST_MULT
		_first_strike = false
		if foe is Foe:
			var f := foe as Foe
			# v20: по оглушённому (Ку) удар с разбега сильнее — связка молнии и рогатки
			if f.is_stunned():
				first *= LegionCfg.STUNNED_CHARGE_MULT
				world.stunned_charge_hit.emit(f)
			# «Штатный»: щит в лоб принимает только разбег — удары после натиска полные
			first *= LegionChallenge.charge_mult(f, position)
		# aggressive_lawyers (world.mods): урон удара с разбега.
		_strike(foe, float(spec["charge_dmg_mult"]) * world.mod_mult("charge_dmg_mult")
			* _bonus_mult * first, true)
		_bonus_t = LegionCfg.CHARGE_BONUS_TIME
		_end_charge()
		return false
	var reach := float(spec["charge_dist"]) * float(_volley.get("range", 1.0))
	# «Оцепление»: натиск кольца к центру — не дальше центра (LegionWorld._ring_cap)
	reach = minf(minf(reach, float(_volley.get("cap", INF))), _charge_cap)
	if _charge_t <= 0.0 or _charge_run >= reach:
		_end_charge()
		return false
	if foe == null and _charge_miss(reach):
		_end_charge()
		return false
	# courier_bonus (world.mods): скорость натиска; v17 — и сила рогатки.
	var sp := float(spec["speed"]) * _item_speed() * LegionCfg.CHARGE_SPEED_MULT \
			* world.mod_mult("charge_speed_mult") * float(_volley.get("speed", 1.0))
	var before := position
	var goal := foe.position if foe != null else position + _charge_dir * 40.0
	if not _step_toward(goal, sp, dt):
		_end_charge()                # упёрся в воду/скалу — натиск окончен
		return false
	# край карты — как стена: за кадром рельеф проходим (ворота врагов), натиск туда не бежит.
	# Стоп только у шага НАРУЖУ: боец заднего ряда у края, бегущий внутрь, бежит как раньше
	# (verifier 180f1168: гасить всю полосу у края — терять половину залпа у края)
	# покомпонентно: сумма по x и y пропускала шаг в углу, меняющий выход по y на выход по x
	# (verifier 180f1168, третий круг: из (2,2) под 45° боец уходил в (-11, 15))
	var out_now := _edge_out(position, world.world_size)
	var out_was := _edge_out(before, world.world_size)
	if out_now.x > out_was.x + 0.001 or out_now.y > out_was.y + 0.001:
		position = before
		_end_charge()
		return false
	_charge_run += before.distance_to(position)
	return true


# ── Помощники ───────────────────────────────────────────────────────────────

## B-077: натиск-промах. Цели нет, пробежал долю CHARGE_MISS_FRAC дальности, а на пути (остаток
## дальности + CHARGE_MISS_LOOK вперёд, CHARGE_MISS_LANE вбок) ни одного врага — стоп: раньше отряд
## улетал на всю дальность мимо колонны и стоял «Zz» на траве, откуда сам не возвращается.
## Враг впереди есть — бежит дальше, как прежде (перелёт колонны к следующей). Кольцо и фигуры с
## пределом (cap, натиск к центру) не трогаем: они сжимаются до центра по замыслу.
func _charge_miss(reach: float) -> bool:
	if _volley.has("cap") or _charge_cap < INF:
		return false
	if _charge_run < reach * LegionCfg.CHARGE_MISS_FRAC:
		return false
	return not world.grid.foe_ahead(position, _charge_dir,
		reach - _charge_run + LegionCfg.CHARGE_MISS_LOOK, LegionCfg.CHARGE_MISS_LANE)


## Насколько точка вылезла за поле натиска (край карты минус CHARGE_EDGE_MARGIN) по x и по y;
## (0, 0) — внутри.
static func _edge_out(p: Vector2, size: Vector2) -> Vector2:
	var m := LegionCfg.CHARGE_EDGE_MARGIN
	var hi := size - Vector2.ONE * m
	return Vector2(maxf(maxf(m - p.x, p.x - hi.x), 0.0), maxf(maxf(m - p.y, p.y - hi.y), 0.0))

## Досягаемость оружия вида (от края тела врага).
func _reach() -> float:
	return float(spec["reach"])


func _in_reach(foe: Node2D) -> bool:
	var r := _reach() + body_r(foe)
	return position.distance_squared_to(foe.position) <= r * r


## Радиус тела цели: врага — из его вида; в PvP ещё боец (UNIT_RADIUS) и Котёл (CAULDRON_RADIUS).
static func body_r(t: Node2D) -> float:
	if t is Foe:
		return (t as Foe).radius
	if t is Legionnaire:
		return LegionCfg.UNIT_RADIUS
	return LegionCfg.CAULDRON_RADIUS


## Ближайшая цель в радиусе r: в одиночке — враг (ровно прежний поиск сетки), в PvP — ещё чужие
## бойцы и чужой Котёл (DESIGN §2.3). ghosts/posted — как у LegionGrid.nearest_foe.
func _target_near(r: float, ghosts: bool, posted := false) -> Node2D:
	if not world.pvp:
		return world.grid.nearest_foe(position, r, ghosts, posted)
	# PvP: пусто вокруг — следующие IDLE_SCAN_SKIP шагов не ищем (сервер: поиск — самое горячее
	# место шага; за 3 шага натиск чужих проходит ~6 px, удар запаздывает на 50 мс)
	if _scan_skip > 0:
		_scan_skip -= 1
		return null
	var t := world.grid.nearest_hostile(position, r, side, ghosts, _reach(), posted)
	if t == null:
		_scan_skip = PvpRules.IDLE_SCAN_SKIP
	return t


## charged — удар с разбега или в окне после него: убийство таким ударом даёт души по комбо.
## Цель — враг; в PvP ещё чужой боец или чужой Котёл: теми же числами урона.
func _strike(foe: Node2D, mult: float, charged := false) -> void:
	_face(foe.position - position)
	if _atk_cd > 0.0:
		view.prepare_attack(_atk_cd, foe)
		return
	_atk_cd = float(spec["period"])
	if state == State.POSTED and contract != null and contract.figure == ContractShape.EIGHT:
		# «Двойная смена»: строй восьмёрки бьёт чаще, пока фигура держится
		_atk_cd *= FigureCfg.EIGHT_PERIOD_MULT
	view.attack_impact()
	var sealed := _seal_t > 0.0
	var dmg := float(spec["dmg"]) * mult * haste_dmg_mult * elite_dmg_mult * rite_dmg_mult
	# «Комиссия»: цель, помеченная моим залпом, получает от участников группы больше. В «Схватке»
	# метка ложится и на чужого бойца (J6) — у него она в своём поле (mark_hit_group).
	if mark_group_id >= 0:
		if foe is Foe and (foe as Foe).mark_group_id == mark_group_id:
			dmg *= FigureCfg.PENTA_MARK_MULT
		elif foe is Legionnaire and (foe as Legionnaire).mark_hit_group == mark_group_id:
			dmg *= FigureCfg.PENTA_MARK_MULT
	if charged:
		dmg *= world.item_mult(&"charge_dmg", side)   # «Дырокол-кастет»
	if sealed:
		dmg *= LegionCfg.SEAL_DAMAGE_MULT
		_seal_t = 0.0
	if bool(spec["ranged"]):
		# урон — по попаданию: пока снаряд летит, цель может умереть от другого, и выстрел пропадёт
		projectile_sealed = sealed
		world.fire_projectile(self, foe, dmg)
		projectile_sealed = false
	elif foe is Foe:
		var f := foe as Foe
		var was_alive := f.alive
		f.last_hit_side = side
		f.take_damage(dmg, position)
		if sealed:
			f.apply_seal_slow()
		if charged and was_alive and not f.alive:
			world.on_charge_kill(f)
	elif foe is Legionnaire:
		# удар по чужому бойцу — в конце шага бойцов (LegionWorld.pvp_hit): бой одновременный,
		# иначе сторона, чьи бойцы раньше в списке, всегда била первой (серия 27.09: 13:7)
		world.pvp_hit(foe as Legionnaire, dmg, position, side)
	else:
		# чужой Котёл: боец бьёт его своим уроном и остаётся на месте (не исчезает, как враг PvE)
		world.damage_cauldron(dmg, "", (foe as LegionBuilding).side)


## Шаг к цели по прямой с проверкой рельефа; упёрлись — пробуем скольжение по осям.
func _step_toward(goal: Vector2, speed: float, dt: float) -> bool:
	var to := goal - position
	var dist := to.length()
	if dist < 0.5:
		return false
	var d := to / dist
	var step := minf(speed * world.terrain.speed_mult(position) * dt, dist)
	var nxt := position + d * step
	if not world.terrain.walkable(nxt):
		nxt = position + Vector2(d.x * step, 0.0)
		if not world.terrain.walkable(nxt):
			nxt = position + Vector2(0.0, d.y * step)
			if not world.terrain.walkable(nxt):
				return false
	position = nxt
	_face(d)
	return true


func _face(direction: Vector2) -> void:
	if absf(direction.x) > 0.05:
		_facing = signf(direction.x)
	if direction.length_squared() > 0.0025:
		view.set_direction(direction)


func settle(mult: float) -> void:
	var base := float(spec["hp"])
	hp = maxf(hp, minf(hp + base * mult, base * LegionCfg.SETTLEMENT_CAP_MULT))


func grant_seal() -> bool:
	if _seal_cd > 0.0:
		return false
	_seal_t = LegionCfg.SEAL_TIME
	_seal_cd = LegionCfg.SEAL_COOLDOWN
	return true


func _tick_aura(dt: float) -> void:
	if not alive:
		return
	_aura_t -= dt
	if _aura_t <= 0.0:
		_aura_t = LegionCfg.ASSIGN_INTERVAL
		_aura_near = field.nearby_kind(position, kind)
		idle_reason = &"no_places" if _aura_near else &"no_contract"
	if field.aura_enabled and state != State.MARCH and _aura_near and hp < max_hp:
		hp = minf(max_hp, hp + LegionCfg.LINE_AURA_REGEN * dt)


## Представители простоя на кадр (описание — у _icon_owners); тест vfx-clarity зовёт напрямую.
## Места раздаём в два прохода (ревью 29.09: четыре кучки чернорабочих, заспавненные первыми,
## съедали все IDLE_ICON_MAX, и простаивающие счетоводы не получали пузыря, хотя справка обещает
## «Zz» над каждым, кто не дотянулся). 1) каждой паре (вид, причина) — первый представитель по
## world.units; 2) остаток до IDLE_ICON_MAX добираем следующими кучками по порядку. Итого
## max(IDLE_ICON_MAX, число пар): пар не больше видов × 2 причины, шум не растёт (обычно 4).
static func idle_icon_owners(w: LegionWorld) -> Dictionary:
	var reps: Array[Legionnaire] = []
	var worth := {}
	for u: Legionnaire in w.units:
		if not u.alive or u.state != State.FREE or u.idle_time < LegionCfg.IDLE_NOTICE_TIME:
			continue
		if not worth.has(u.kind):
			worth[u.kind] = u._idle_worth_flagging()
		if not worth[u.kind]:
			continue
		var near := reps.any(func(r: Legionnaire) -> bool:
			return r.kind == u.kind and r.idle_reason == u.idle_reason \
				and r.position.distance_to(u.position) <= LegionCfg.IDLE_ICON_CLUSTER_R)
		if not near:
			reps.append(u)
	var out := {}
	var pairs := {}
	for r in reps:
		var key := "%s/%s" % [r.kind, r.idle_reason]
		if not pairs.has(key):
			pairs[key] = true
			out[r.get_instance_id()] = true
	for r in reps:
		if out.size() >= LegionCfg.IDLE_ICON_MAX:
			break
		out[r.get_instance_id()] = true
	return out


func _draw() -> void:
	if world != null and world.pvp and alive:
		# у ступней (B-251): на (0, 3) маркер уходил под тело — у счетоводов не виден вовсе
		var feet := view.ground_px() if view != null else 0.0
		PvpView.draw_marker(self, world, Vector2(0.0, feet + PvpRules.MARKER_DY), side, 7.0)
	if state != State.FREE or idle_time < LegionCfg.IDLE_NOTICE_TIME:
		return
	# polish1 (ревью 25.09.2026): простой — нормальное ожидание, пока на поле нет ни одного
	# живого договора этого вида (игрок ещё не начертил линию или она вся растаяла); значок
	# тогда только шумит — было видно на кадре начала боя, где значок висел над всем строем.
	# Один значок на кучку и не больше IDLE_ICON_MAX на поле — idle_icon_owners (кэш кадра).
	var frame := Engine.get_process_frames()
	if frame != _icon_frame:
		_icon_frame = frame
		_icon_owners = idle_icon_owners(world)
	if not _icon_owners.has(get_instance_id()):
		return
	# Пузырь над головой: тёмная заливка, цветная обводка, хвостик вниз к голове и знак внутри.
	# «Zz» (золото) — своего договора рядом нет, боец дремлет; «…» (фиолет) — договор рядом,
	# но мест нет. Раньше тут был серый контур квадратика с диагональю — владелец принял его
	# за не подгрузившуюся графику (25.09.2026).
	var at := LegionCfg.IDLE_ICON_OFFSET
	var r := LegionCfg.IDLE_ICON_R
	var far := idle_reason == &"no_contract"
	var color := LegionCfg.IDLE_ICON_FAR_COLOR if far else LegionCfg.IDLE_ICON_FULL_COLOR
	var tail := PackedVector2Array([
		at + Vector2(-r * 0.45, r * 0.6),
		at + Vector2(r * 0.45, r * 0.6),
		at + Vector2(0.0, r + LegionCfg.IDLE_ICON_TAIL),
	])
	draw_colored_polygon(tail, color)
	draw_circle(at, r, color)
	draw_circle(at, r - LegionCfg.IDLE_ICON_BORDER, LegionCfg.IDLE_ICON_FILL)
	if not far:
		# три точки кругами: символ «…» у шрифта узкий и на 14 px читался серой крошкой
		var step := r * 0.42
		for i in 3:
			draw_circle(at + Vector2(step * float(i - 1), 0.0), r * 0.16, color)
		return
	var glyph := "Zz"
	var font: Font = UiStyle.FONT_TITLE
	var fs := LegionCfg.IDLE_ICON_FONT
	var sz := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var base := at + Vector2(-sz.x * 0.5, font.get_ascent(fs) * 0.5 - font.get_descent(fs) * 0.25)
	draw_string(font, base, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


## Есть ли на поле хоть один живой договор этого вида — иначе значок простоя врёт: это не
## «застрял», а «ждёт, пока игрок начертит линию».
func _idle_worth_flagging() -> bool:
	for c in field.contracts:
		if c.kind == kind and c.alive():
			return true
	return false


## Среди других идле-бойцов того же вида/причины, которые тоже сейчас рисовали бы значок,
## есть ли внутри IDLE_ICON_CLUSTER_R кто-то с меньшим `idx` — тогда рисует он, не мы.
func _cluster_has_representative() -> bool:
	for u: Legionnaire in world.units:
		if u == self or not u.alive or u.state != State.FREE:
			continue
		if u.idle_time < LegionCfg.IDLE_NOTICE_TIME or u.idx >= idx:
			continue
		if u.kind != kind or u.idle_reason != idle_reason:
			continue
		if position.distance_to(u.position) <= LegionCfg.IDLE_ICON_CLUSTER_R:
			return true
	return false


func _item_speed() -> float:
	return haste_speed_mult * (0.5 if item_slow_t > 0.0 else 1.0) \
		* (ult_slow_mult if ult_slow_t > 0.0 else 1.0)
