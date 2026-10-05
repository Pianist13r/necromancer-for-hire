class_name PvpBot
extends RefCounted
##
## Бот стороны «Схватки» (docs/pvp/DESIGN.md §2.2, §2.7): держит оборону своей половины от волн
## и соперника и НАСТУПАЕТ перебежками к чужому Котлу — «линия → срыв → новая линия впереди →
## срыв». Играет ТОЛЬКО через API команд стороны (PvpCmd, LegionWorld.command) — теми же
## действиями, что сеть и человек; читает только то, что видно на поле (позиции, свои договоры).
##
## Раздумье раз в THINK_MIN…THINK_MAX с (реакция человека, как у LegionBot). Свой ГСЧ, засеянный
## сидом боя и стороной: бот одной стороны не сдвигает случайности другой и мира.
##
## Оборона: рубеж поперёк каждой дороги волн у своего Котла (стрелка — к воротам) и рубеж
## «лицом к стыку» (стрелка — к сопернику); держатся подрисовкой, прогнутый давкой участок
## срывается «пружиной». Наступление — машина состояний (enum: пять состояний без тяжёлых
## enter/exit, скилл state-machine): IDLE → MARCH (линия впереди группы, бойцы идут на места) →
## CHARGE (срыв по стрелке, ждём конца натиска) → IDLE; у чужого Котла — SIEGE: линия вплотную,
## строй бьёт Котёл, пока тот жив.
##

enum Stage { IDLE, MARCH, CHARGE, SIEGE }

const THINK_MIN := 0.3
const THINK_MAX := 0.55
## Рубеж обороны: на таком расстоянии от конца дороги (у Котла), длина, отступ «лица к стыку».
const DEF_ALONG := 120.0
const DEF_LEN := 90.0
const DEF_FRONT := 110.0
## Дорога «своя», если её конец ближе этого к моему Котлу.
const ROAD_HOME_R := 160.0
## Подрисовка: участку осталось меньше — штрих поверх рубежа.
const REFRESH_LEAD := 2.5
## Прогиб давкой, с которого участок срывается пружиной.
const SPRING_AT := 0.6
## Наступление: сколько свободных нужно для перебежки, радиус группы, длина прыжка линии.
const ASSAULT_MIN := 8
## На своей половине (ближе к своему Котлу, чем к чужому) перебежка — только кулаком не меньше
## ASSAULT_BIG: мелкие наскоки вязнут в чужой обороне по одному, а павшие у соперника
## возрождаются у его Котла, прямо в драке. «Сбор» тем временем подтягивает резерв к кулаку.
const ASSAULT_BIG := 30
const HOME_R := 260.0
const GROUP_R := 260.0
## «Сбор» отставших: точка — на STRAY_PULL ближе к группе (в радиусе RALLY_R от отставшего);
## дальше STRAY_MAX от группы отставших не зовём (там свой бой).
const STRAY_PULL := 160.0
const STRAY_MAX := 900.0
const LEAP := 110.0
## Первая перебежка от дома — дальше: после натиска бойцы должны встать дальше RECRUIT_R от
## рубежей обороны, иначе вербовка вернёт их на пустые места обороны; но не дальше RECRUIT_R
## от группы — иначе на линию некому встать.
const LEAP_HOME := 150.0
## Линия наступления: на бойца столько px длины (два ряда мест по POST_STEP), пределы длины.
const PX_PER_UNIT := 9.0
const ASSAULT_LEN_MIN := 80.0
const ASSAULT_LEN_MAX := 260.0
## Места заняты на эту долю — срыв; ждать не дольше MARCH_WAIT (набралось хоть MARCH_MIN — срыв),
## MARCH_GIVE_UP — бросить линию (пусть тает).
const MARCH_FILL := 0.7
const MARCH_WAIT := 7.0
const MARCH_MIN := 4
const MARCH_GIVE_UP := 11.0
## Натиск длится CHARGE_TIME; ждём с запасом, пока все станут свободными.
const CHARGE_WAIT := LegionCfg.CHARGE_TIME + 0.3
## Осада: ближе SIEGE_R к чужому Котлу — линия на SIEGE_DIST от его центра, строй бьёт Котёл.
const SIEGE_R := 320.0
const SIEGE_DIST := 52.0
## Осада, при которой Котёл столько секунд не теряет HP, снимается.
const SIEGE_STALL := 10.0
## Оттяжка рогатки (px) при срыве по стрелке: длина не важна (сила всегда полная), только знак.
const PULL := 80.0
## Шаг точек штриха (не меньше POINT_STEP поля — иначе extend пропустит точку).
const STROKE_STEP := 8.0
## Середина линии в скале — отступ назад по стрелке не дальше стольких шагов.
const LINE_BACK_STEPS := 12
## Ку — по чужим у моего Котла ближе этого или у моей линии наступления.
const Q_HOME_R := 380.0
const Q_FRONT_R := 220.0

var world: LegionWorld = null
var side := 0
var stage := Stage.IDLE
## Куда слать команды вместо мира (сетевая проба: NetSession через world.net_out). Пусто — в мир.
var sink: Callable
## Счётчики для серий и тестов: перебежек, осад, срывов обороны, отказов API.
var counts := {"leaps": 0, "sieges": 0, "springs": 0, "rejects": 0, "defense_lines": 0}

var _rng := RandomNumberGenerator.new()
var _think_t := 0.0
## Рубежи обороны: {pts, dir, id} — id живого договора или -1.
var _defense: Array[Dictionary] = []
var _assault_id := -1
var _stage_t := 0.0
## Осада: HP чужого Котла, когда он в последний раз падал, и когда (время стадии).
var _siege_hp := INF
var _siege_hit_t := 0.0


func setup(w: LegionWorld, side_index: int) -> void:
	world = w
	side = side_index
	stage = Stage.IDLE
	_assault_id = -1
	_stage_t = 0.0
	_rng.seed = hash([w._base_seed, side_index, "pvp_bot"])
	_think_t = _rng.randf_range(THINK_MIN, THINK_MAX)
	_defense.clear()
	var home := _me().cauldron_pos
	for r: Dictionary in world.map.get("roads", []):
		var path := world.road_path(String(r.get("id", "")))
		if path.size() < 2 or path[path.size() - 1].distance_to(home) > ROAD_HOME_R:
			continue
		_add_defense(_along_back(path, DEF_ALONG))
	var enemy := _enemy_pos()
	if enemy != Vector2.INF:
		var route := _me().contracts.recruit_path(home, enemy)
		var ahead := route[0] if not route.is_empty() else enemy
		for p in route:
			if p.distance_to(home) >= DEF_FRONT:
				ahead = p
				break
		var d := (ahead - home).normalized()
		_add_defense([home + d * DEF_FRONT, d])


func _free_count() -> int:
	var n := 0
	for u in world.units:
		n += int(u.side == side and u.alive and u.state == Legionnaire.State.FREE)
	return n


func _me() -> PvpSide:
	return world.sides[side]


func _field() -> ContractField:
	return _me().contracts


## Ближайший живой чужой Котёл; INF — соперников нет.
func _enemy_pos() -> Vector2:
	var best := Vector2.INF
	var home := _me().cauldron_pos
	for s: PvpSide in world.sides:
		if s.index != side and s.alive() \
				and home.distance_to(s.cauldron_pos) < home.distance_to(best):
			best = s.cauldron_pos
	return best


## HP ближайшего чужого Котла (INF — соперников нет).
func _enemy_hp() -> float:
	var at := _enemy_pos()
	for s: PvpSide in world.sides:
		if s.index != side and s.cauldron_pos == at:
			return s.cauldron_hp
	return INF


## Точка дороги в dist от её конца (у Котла) и стрелка — назад, к воротам.
func _along_back(path: PackedVector2Array, dist: float) -> Array:
	var left := dist
	for i in range(path.size() - 1, 0, -1):
		var a := path[i]
		var b := path[i - 1]
		var seg := a.distance_to(b)
		if seg >= left and seg > 0.0:
			return [a.lerp(b, left / seg), (b - a).normalized()]
		left -= seg
	return [path[0], (path[0] - path[path.size() - 1]).normalized()]


func _add_defense(at_dir: Array) -> void:
	var at: Vector2 = at_dir[0]
	var d: Vector2 = at_dir[1]
	_defense.append({"pts": _line(at, d, DEF_LEN), "dir": d, "id": -1})


## Ломаная поперёк стрелки d с серединой at, длиной length; концы в скале обрезаны (штрих не
## начинается в камне — ContractField.begin отказал бы).
func _line(at: Vector2, d: Vector2, length: float) -> PackedVector2Array:
	# штрих идёт от конца к концу, и договор считает места и участки по порядку штриха: у бота
	# правой половины порядок — отражение порядка левой, иначе, например, рубеж против волн с
	# севера набирался бы с разных концов (B-295)
	var perp := d.orthogonal() * (-1.0 if _me().cauldron_pos.x > world.world_size.x * 0.5 else 1.0)
	# середина в скале (проход, валун) — отступаем назад по стрелке до земли
	var back := 0
	while not _open(at) and back < LINE_BACK_STEPS:
		at -= d * STROKE_STEP
		back += 1
	if not _open(at):
		return PackedVector2Array()
	# от середины в обе стороны до скалы или края: сплошной кусок, в котором лежит середина
	var half := int(length * 0.5 / STROKE_STEP)
	var lo := 0
	while lo < half and _open(at - perp * STROKE_STEP * float(lo + 1)):
		lo += 1
	var hi := 0
	while hi < half and _open(at + perp * STROKE_STEP * float(hi + 1)):
		hi += 1
	var pts := PackedVector2Array()
	for k in range(-lo, hi + 1):
		pts.append(at + perp * STROKE_STEP * float(k))
	return pts


func _open(p: Vector2) -> bool:
	return Rect2(Vector2.ZERO, world.world_size).grow(-LegionCfg.UNIT_RADIUS * 2.0).has_point(p) \
		and world.terrain.walkable(p) and not world.terrain.is_rock(p)


func tick(dt: float) -> void:
	_stage_t += dt
	_think_t -= dt
	if _think_t > 0.0:
		return
	_think_t = _rng.randf_range(THINK_MIN, THINK_MAX)
	if not _me().alive():
		return
	_build_step()
	_defend()
	_hero_step()
	_assault_step()
	_consolidate()


## «Сбор» отставших к главной группе: после натисков по полю остаются кучки по 2–5 свободных,
## которых не набирает ни одна линия (их видно по «Zz»). R по точке на STRAY_PULL ближе к группе
## от самого дальнего отставшего — позовёт его кучку на STRAY_PULL вперёд; раз в откат «Сбора».
func _consolidate() -> void:
	if _me().rally_cd > 0.0 or not _can_pay(LegionCfg.RALLY_SLOT):
		return
	var free: Array[Legionnaire] = []
	for u in world.units:
		if u.side == side and u.alive and u.state == Legionnaire.State.FREE and not u.is_stunned():
			free.append(u)
	if free.size() < ASSAULT_MIN:
		return
	var enemy := _enemy_pos()
	if enemy == Vector2.INF:
		return
	# цель — линия наступления или передовая кучка: отставших и резерв тянем ВПЕРЁД, к ней
	var goal := Vector2.INF
	var c := _field().by_id(_assault_id)
	if c != null and c.alive():
		goal = c.point_at(c.length * 0.5)
	else:
		for a in free:
			var closer := goal == Vector2.INF \
				or a.position.distance_to(enemy) < goal.distance_to(enemy)
			if closer and _group_at(free, a.position).size() >= ASSAULT_MIN:
				goal = a.position
	if goal == Vector2.INF:
		return
	var stray: Legionnaire = null
	for u in free:
		var d := u.position.distance_to(goal)
		# ближайший к цели из тех, кто позади неё и вне её кучки
		var behind := u.position.distance_to(enemy) > goal.distance_to(enemy)
		if behind and d > GROUP_R and d < STRAY_MAX \
				and (stray == null or d < stray.position.distance_to(goal)):
			stray = u
	if stray == null:
		return
	# Прямая к кучке может попасть глубоко в скалу. Берём продвижение по тому же пути,
	# которым пойдёт боец, и проверяем центр до команды: отказ не расходует откат.
	var route := _field().recruit_path(stray.position, goal)
	if route.is_empty():
		return
	var at := world.rally_center(_route_point(stray.position, route, STRAY_PULL))
	if at != Vector2.INF and stray.position.distance_to(at) <= LegionCfg.RALLY_R:
		_cmd(PvpCmd.rally(at))


## Хватает ли своей маны на способность с запасом бота на линии (PvpSide.ability_mana_reserve,
## D-0927-140): без неё команда была бы отказом, а мана нужна рубежам и перебежкам.
func _can_pay(slot: int) -> bool:
	return world.can_pay_ability(slot, side)


func _cmd(cmd: Dictionary) -> Dictionary:
	if sink.is_valid():
		# сетевой бот (проба lockstep): команда уходит в сессию, мир изменит её через задержку
		# ответа мира ещё нет (номер договора станет известен через задержку) — для бота это
		# «не принято», и он не читает полей результата, которых нет
		sink.call(cmd)
		return {"ok": false, "reason": "net_queued"}
	var res := world.command(side, cmd)
	if not bool(res.get("ok", false)):
		counts["rejects"] = int(counts["rejects"]) + 1
		if world.dev.has("pvp_botlog"):
			print("PVPBOT t=%.1f side=%d reject %s %s" % [world.now, side, String(cmd["type"]),
				String(res.get("reason", ""))])
	return res


# ── Стройка: площадки своей половины по приоритету, потом улучшения ───────────

func _build_step() -> void:
	var st := _me().staff
	var order := st.plots.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["bot_priority"]) > float(b["bot_priority"]))
	for p: Dictionary in order:
		if p["building"] != null:
			continue
		var kind := LegionCfg.KIND_LABORER
		for k in p["preferred_kinds"]:
			if st.kind_unlocked(StringName(String(k))):
				kind = StringName(String(k))
				break
		if _me().souls >= LegionStaff.build_price(kind):
			_cmd(PvpCmd.plot(String(p["id"]), PvpCmd.BUILD, kind))
		return
	for p: Dictionary in order:
		var b: LegionBuilding = p["building"]
		var price := LegionStaff.upgrade_price(b)
		if price >= 0:
			if _me().souls >= price:
				_cmd(PvpCmd.plot(String(p["id"]), PvpCmd.UPGRADE))
			return


# ── Оборона ──────────────────────────────────────────────────────────────────

func _defend() -> void:
	var field := _field()
	for d: Dictionary in _defense:
		var c := field.by_id(int(d["id"]))
		if c == null or not c.alive() or _dead_share(c) > 0.5:
			# рубежа нет (или его пробили наполовину) — чертим заново; старый дотает сам
			if field.contracts.size() < LegionCfg.MAX_CONTRACTS - 1:
				var res := _cmd(PvpCmd.stroke(d["pts"], LegionCfg.KIND_LABORER,
					_arrow(d["pts"], d["dir"])))
				if bool(res.get("ok", false)):
					d["id"] = int(res["contract"])
					counts["defense_lines"] = int(counts["defense_lines"]) + 1
			continue
		var bent := -1
		for s in c.seg_count():
			if c.seg_alive(s) and c.seg_manned(s) >= 2 and c.bend_frac(s) >= SPRING_AT:
				bent = s
				break
		if bent >= 0:
			# давка вот-вот прорвёт — пружина в толпу: стрелка против прогиба
			var push := -c.seg_bend_dir[bent]
			if push.is_zero_approx():
				push = c.dir
			if bool(_cmd(PvpCmd.sling(c.id, bent, -push * PULL)).get("ok", false)):
				counts["springs"] = int(counts["springs"]) + 1
			continue
		if _due(c):
			_cmd(PvpCmd.stroke(d["pts"], c.kind))


static func _dead_share(c: Contract) -> float:
	var dead := 0
	for s in c.seg_count():
		if not c.seg_alive(s):
			dead += 1
	return float(dead) / float(maxi(1, c.seg_count()))


func _due(c: Contract) -> bool:
	for s in c.seg_count():
		if c.seg_alive(s) and c.seg_left(s) < REFRESH_LEAD:
			return true
	return false


func _arrow(pts: PackedVector2Array, d: Vector2) -> Vector2:
	var mid := pts[pts.size() / 2] if not pts.is_empty() else Vector2.ZERO
	var at := mid + d * 60.0
	return at.clamp(Vector2.ONE, world.world_size - Vector2.ONE)


# ── Наступление перебежками ─────────────────────────────────────────────────

func _assault_step() -> void:
	var field := _field()
	var c := field.by_id(_assault_id)
	match stage:
		Stage.IDLE:
			_try_leap()
		Stage.MARCH:
			if c == null or not c.alive():
				_set_stage(Stage.IDLE)
				return
			# стоят в строю (не идут): срыв идущих оставил бы их свободными посреди марша
			var manned := 0
			for s in c.seg_count():
				manned += c.seg_manned(s)
			var full := manned >= MARCH_MIN \
				and float(manned) >= float(c.manned_posts()) * MARCH_FILL
			if full or (_stage_t >= MARCH_WAIT and manned >= MARCH_MIN):
				_release(c)
			elif _stage_t >= MARCH_GIVE_UP:
				_set_stage(Stage.IDLE)   # не набралась — пусть тает, бойцы вернутся свободными
		Stage.CHARGE:
			if _stage_t >= CHARGE_WAIT:
				_set_stage(Stage.IDLE)
		Stage.SIEGE:
			var posted := 0
			if c != null:
				for s in c.seg_count():
					posted += c.seg_manned(s)
			var enemy_hp := _enemy_hp()
			if enemy_hp < _siege_hp:
				_siege_hp = enemy_hp
				_siege_hit_t = _stage_t
			# осаду выбили, она так и не встала или стоит, но Котёл не теряет HP (строй не
			# достаёт) — не держим линию: снова перебежки
			if c == null or not c.alive() or _enemy_pos() == Vector2.INF \
					or (_stage_t >= MARCH_WAIT and posted < MARCH_MIN) \
					or _stage_t - _siege_hit_t >= SIEGE_STALL:
				_set_stage(Stage.IDLE)
			elif _due(c):
				_cmd(PvpCmd.stroke(c.points, c.kind))


func _set_stage(s: Stage) -> void:
	if world.dev.has("pvp_botlog"):   # --dev pvp_botlog=1 — журнал решений бота (отладка серий)
		print("PVPBOT t=%.1f side=%d %s -> %s free=%d" % [world.now, side, Stage.keys()[stage],
			Stage.keys()[s], _free_count()])
	stage = s
	_stage_t = 0.0
	if s == Stage.IDLE:
		_assault_id = -1


## Группа для перебежки — самая продвинутая достаточная кучка свободных: в поле хватает
## ASSAULT_MIN (остатки прошлого натиска идут дальше), у своего Котла — ASSAULT_BIG (из дома —
## только большой волной: мелкие наскоки вязнут в чужой обороне по одному). Линия — впереди
## группы по пути к чужому Котлу; у него — осада. Отставших подберёт вербовка новой линии.
func _try_leap() -> void:
	var enemy := _enemy_pos()
	var field := _field()
	if enemy == Vector2.INF or field.contracts.size() >= LegionCfg.MAX_CONTRACTS:
		return
	var free: Array[Legionnaire] = []
	for u in world.units:
		if u.side == side and u.alive and u.state == Legionnaire.State.FREE and not u.is_stunned():
			free.append(u)
	var home := _me().cauldron_pos
	var group: Array[Legionnaire] = []
	var best_d := INF
	for anchor in free:
		var d := anchor.position.distance_to(enemy)
		if d >= best_d:
			continue
		var near := _group_at(free, anchor.position)
		var own_half := anchor.position.distance_to(home) < d
		var need := ASSAULT_BIG if own_half else ASSAULT_MIN
		if near.size() >= need:
			best_d = d
			group = near
	if group.is_empty():
		return
	var g := Vector2.ZERO
	for u in group:
		g += u.position
	g /= float(group.size())
	var at := Vector2.ZERO
	var d := Vector2.ZERO
	var siege := g.distance_to(enemy) <= SIEGE_R
	if siege:
		d = (enemy - g).normalized()
		at = enemy - d * SIEGE_DIST
	else:
		var route := field.recruit_path(world.terrain.nearest_open(g), enemy)
		if route.is_empty():
			return
		var leap := LEAP_HOME if g.distance_to(_me().cauldron_pos) <= HOME_R else LEAP
		var ahead := _route_point(g, route, leap)
		d = (_route_point(g, route, leap + 40.0) - ahead).normalized()
		if d.is_zero_approx():
			d = (enemy - g).normalized()
		at = ahead
	var length := clampf(group.size() * PX_PER_UNIT, ASSAULT_LEN_MIN, ASSAULT_LEN_MAX)
	var pts := _line(at, d, length)
	if pts.size() < 2 or _poly_len(pts) < LegionCfg.LINE_MIN:
		return
	var res := _cmd(PvpCmd.stroke(pts, LegionCfg.KIND_LABORER, _arrow(pts, d)))
	if not bool(res.get("ok", false)) or _is_defense(int(res["contract"])):
		return   # штрих лёг подрисовкой рубежа обороны — наступать им нельзя
	_assault_id = int(res["contract"])
	if siege:
		counts["sieges"] = int(counts["sieges"]) + 1
		_set_stage(Stage.SIEGE)
		_siege_hp = _enemy_hp()
		_siege_hit_t = 0.0
		_assault_id = int(res["contract"])
	else:
		_set_stage(Stage.MARCH)
		_assault_id = int(res["contract"])


func _is_defense(id: int) -> bool:
	for d: Dictionary in _defense:
		if int(d["id"]) == id:
			return true
	return false


func _group_at(free: Array[Legionnaire], at: Vector2) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in free:
		if u.position.distance_to(at) <= GROUP_R:
			out.append(u)
	return out


## Точка пути route в dist от from (путь A* по клеткам; первая точка — клетка группы).
static func _route_point(from: Vector2, route: PackedVector2Array, dist: float) -> Vector2:
	var at := from
	var left := dist
	for p in route:
		var seg := at.distance_to(p)
		if seg >= left:
			return at.move_toward(p, left)
		left -= seg
		at = p
	return at


static func _poly_len(pts: PackedVector2Array) -> float:
	var n := 0.0
	for i in range(1, pts.size()):
		n += pts[i].distance_to(pts[i - 1])
	return n


## Срыв линии наступления по её стрелке (рогатка: «Точно!», если в зоне враг — считает мир).
func _release(c: Contract) -> void:
	var hero := _me().hero
	if hero != null and hero.cd_left(LegionHero.SLOT_E) <= 0.0 and _can_pay(LegionHero.SLOT_E):
		_cmd(PvpCmd.cast(LegionHero.SLOT_E, c.point_at(c.length * 0.5)))   # Аврал — перед рывком
	for s in c.seg_count():
		if c.seg_alive(s):
			_cmd(PvpCmd.sling(c.id, s, -c.dir * PULL))
			if c.ring or c.figure != &"":
				break   # фигура срывается целиком одним жестом
	counts["leaps"] = int(counts["leaps"]) + 1
	_set_stage(Stage.CHARGE)


# ── Герой ───────────────────────────────────────────────────────────────────

## Ку — по самой близкой к моему Котлу чужой цели (враг волны или боец соперника), иначе — по
## чужим у моей линии наступления.
func _hero_step() -> void:
	var hero := _me().hero
	if hero == null or hero.cd_left(LegionHero.SLOT_Q) > 0.0 or not _can_pay(LegionHero.SLOT_Q):
		return
	var home := _me().cauldron_pos
	var target := _nearest_hostile(home, Q_HOME_R)
	if target == Vector2.INF:
		var c := _field().by_id(_assault_id)
		if c != null and c.alive():
			target = _nearest_hostile(c.point_at(c.length * 0.5), Q_FRONT_R)
	if target != Vector2.INF:
		_cmd(PvpCmd.cast(LegionHero.SLOT_Q, target))


func _nearest_hostile(at: Vector2, r: float) -> Vector2:
	var best := Vector2.INF
	var bd := r * r
	for f in world.foes:
		if f.is_active() and f.position.distance_squared_to(at) < bd:
			bd = f.position.distance_squared_to(at)
			best = f.position
	for u in world.units:
		if u.alive and u.side != side and u.position.distance_squared_to(at) < bd:
			bd = u.position.distance_squared_to(at)
			best = u.position
	return best
