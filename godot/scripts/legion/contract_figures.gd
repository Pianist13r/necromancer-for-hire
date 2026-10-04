class_name LegionFigures
extends RefCounted
##
## Что делают бойцы, выстроенные в фигуру (Игорь 26.09: «чтобы юниты, которые выстроились в эту
## фигуру, что-то особенное начинали делать… если сам дождался и она сама распалась, то они
## какую-нибудь ульту делают»). Распознавание — ContractShape, геометрия договора — Contract,
## ввод и отрисовка — ContractField; здесь только бой.
##
## Восьмёрка — «Двойная смена»:
##   · пока держится — строй бьёт чаще (Legionnaire._strike, FigureCfg.EIGHT_PERIOD_MULT);
##   · выпуск (щелчок, рогатка, таяние) — «крест-накрест»: бойцы каждой петли бегут к центру
##     другой петли, петли проходят сквозь перетяжку (charge_for);
##   · растаяла сама целиком, строй набран (≥ OVERTIME_FILL мест) — «Сверхурочные»: через
##     OVERTIME_DELAY каждый участник делает второй натиск обратно, к центру своей петли.
## Треугольник — «Обряд» (D-1002-03: вместо звезды, условия мягче):
##   · строй треугольника НЕ бьёт — держит обряд (Legionnaire._tick_posted);
##   · срыв любым способом — самотаяние, ПКМ, рогатка, Таб — натиск к центру; если в этот миг
##     занято ≥ RITE_FILL мест — «Обряд!»: удар в центре (урон и оглушение), свежие трупы
##     встают внештатниками, участники сильнее. Потери строя обряд не срывают — только
##     убавляют долю мест.
## Квадрат — «Каре» (D-1002-03): строй получает меньше урона (Legionnaire.take_damage), давка
##   его не прогибает (LegionWorld._tick_press), фигура тает дольше (Contract.build_figure).
##   Срыв — обычный натиск наружу, без награды.
##
## Фигура тает ЦЕЛИКОМ: её участки подновляются и тают вместе (ContractField). Так «дождался
## конца» — одно событие с одним порогом, а не пять мелких, и у игрока один таймер на фигуру.
##
## Бот фигур не чертит: ни одна функция здесь не трогает обычные линии и ГСЧ мира — бой бота
## побайтно прежний (tests/legion_runes_test.gd).
##

var world: LegionWorld = null
## Последний обряд (тесты, подписи): {center, r, hit, stunned, raised, units}.
var last_rite: Dictionary = {}
## Отложенные «Сверхурочные»: {t, center, units, homes, done, fired, group}. Боец срывается во
## второй натиск, когда пауза прошла И его первый натиск кончился; ещё бегущий ждёт (не дольше
## OVERTIME_WAIT после паузы) — иначе дальние петли теряли половину второго натиска.
var _overtime: Array[Dictionary] = []
## Усиление участников обряда: {t, units: Array[Legionnaire]}.
var _buffs: Array[Dictionary] = []
## Треугольник, который сейчас срывается с обрядом: натиск его участников — к центру.
var _rite: Contract = null


func setup(w: LegionWorld) -> void:
	world = w


func reset() -> void:
	for b in _buffs:
		_unbuff(b["units"])
	_buffs.clear()
	_overtime.clear()
	_rite = null
	last_rite = {}


## Куда бежит боец места p при выпуске фигуры c: [стрелка, предел пробега].
func charge_for(c: Contract, p: Dictionary, u: Legionnaire) -> Array:
	if c.figure == ContractShape.EIGHT:
		var target := c.lobes[1 - c.lobe_at(float(p["along"]))]
		return _toward(u.position, target, FigureCfg.EIGHT_OVERRUN, p["normal"])
	if c.figure == ContractShape.TRIANGLE:
		# к центру — добить оглушённых обрядом (и без обряда: стрелки мест и так туда)
		return _toward(u.position, c.center, FigureCfg.RITE_OVERRUN, p["normal"])
	return [p["normal"], INF]


static func _toward(from: Vector2, to: Vector2, overrun: float, fallback: Vector2) -> Array:
	var v := to - from
	if v.length() < 1.0:
		return [fallback, overrun]
	return [v.normalized(), v.length() + overrun]


## Щелчок, рогатка или Таб по любому участку фигуры: срывается вся фигура разом (как кольцо).
## power < 0 — щелчок. Залпы участков — одна группа: комбо растёт один раз за выпуск.
func release(c: Contract, power: float, perfect: bool) -> int:
	var squad := _squad(c)
	var rite := _rite_ready(c)
	if rite:
		_rite = c
	var group := {"hit": false, "units": 0}
	var n := 0
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var v := world._volley(c.seg_dir(s), power, perfect, true)
		v["group"] = group
		world._release(c, s, &"manual", v)
		group["units"] = int(group["units"]) + int(v["units"])
		n += 1
	_rite = null
	if n > 0:
		_stat("figure_releases")
		if power >= 0.0:
			_stat("sling_releases")
			if perfect:
				_stat("perfect_releases")
		if rite:
			_do_rite(c, squad)
	return n


## Участок фигуры дотаял — тает вся фигура; самотаяние с набранным строем — награда.
func melt(c: Contract) -> void:
	var intact := true
	for s in c.seg_count():
		intact = intact and c.seg_alive(s)
	var fill := c.fill()
	var squad := _squad(c)
	var homes: Array[Vector2] = []
	if c.figure == ContractShape.EIGHT:
		for u in squad:
			homes.append(c.lobes[c.lobe_at(float(u.post["along"]))])
	var rite := _rite_ready(c)
	if rite:
		_rite = c
	var group := {"hit": false, "units": 0}
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var v := world._volley(c.seg_dir(s), -1.0, false, false)
		v["group"] = group
		world._release(c, s, &"melt", v)
	_rite = null
	if c.figure == ContractShape.EIGHT and intact and fill >= FigureCfg.OVERTIME_FILL \
			and not squad.is_empty():
		var done := PackedByteArray()
		done.resize(squad.size())
		_overtime.append({"t": FigureCfg.OVERTIME_DELAY, "center": c.center, "units": squad,
			"homes": homes, "done": done, "fired": false, "lobes": c.lobes,
			"side": c.owner_side,
			"group": {"hit": false, "units": 0}})
		_stat("overtime_armed")
	elif rite:
		_do_rite(c, squad)


## Бойцы, стоящие в строю фигуры (POSTED на её местах), — участники выпуска и обряда.
func _squad(c: Contract) -> Array[Legionnaire]:
	var squad: Array[Legionnaire] = []
	for p in c.posts:
		var u: Legionnaire = p["unit"]
		if p["dead"] or u == null or u.state != Legionnaire.State.POSTED:
			continue
		squad.append(u)
	return squad


## Треугольник набрал строй к обряду (доля мест — в миг срыва; потери её просто убавляют).
static func _rite_ready(c: Contract) -> bool:
	return c.figure == ContractShape.TRIANGLE and c.fill() >= FigureCfg.RITE_FILL - 0.0001


## Шаг боя (мир зовёт после бойцов): отложенные «Сверхурочные» срываются; усиление обряда гаснет.
func tick(dt: float) -> void:
	for i in range(_overtime.size() - 1, -1, -1):
		_overtime[i]["t"] = float(_overtime[i]["t"]) - dt
		if float(_overtime[i]["t"]) <= 0.0 and _fire_overtime(_overtime[i]):
			_overtime.remove_at(i)
	for i in range(_buffs.size() - 1, -1, -1):
		_buffs[i]["t"] = float(_buffs[i]["t"]) - dt
		if float(_buffs[i]["t"]) <= 0.0:
			_unbuff(_buffs[i]["units"])
			_buffs.remove_at(i)


func pending_overtime() -> int:
	return _overtime.size()


## Сорвать во второй натиск тех, кто уже добежал первый. true — задание закрыто.
func _fire_overtime(job: Dictionary) -> bool:
	var units: Array[Legionnaire] = job["units"]
	var homes: Array[Vector2] = job["homes"]
	var done: PackedByteArray = job["done"]
	var group: Dictionary = job["group"]
	var n := 0
	var waiting := 0
	for i in units.size():
		if done[i] != 0:
			continue
		var u := units[i]
		if not is_instance_valid(u) or not u.alive:
			done[i] = 1
			continue
		if u.state == Legionnaire.State.CHARGE:
			waiting += 1   # первый натиск ещё идёт
			continue
		done[i] = 1
		# занятые делом не срываются: встал в строй новой линии, «Сбор»
		if u.state != Legionnaire.State.FREE and u.state != Legionnaire.State.MARCH:
			continue
		if u.state == Legionnaire.State.MARCH:
			u.set_free()
		var aim := _toward(u.position, homes[i], FigureCfg.EIGHT_OVERRUN, Vector2.RIGHT)
		var v := world._volley(aim[0], -1.0, false, false)
		v["group"] = group
		u.start_charge(aim[0], v, aim[1])
		group["units"] = int(group["units"]) + 1
		n += 1
	job["done"] = done
	if n > 0:
		world.stats["overtime_charges"] = int(world.stats.get("overtime_charges", 0)) + n
		if not bool(job["fired"]):
			job["fired"] = true
			_stat("overtimes")
			world.sides[int(job["side"])].contracts.on_overtime(job["center"], n, job["lobes"])
	return waiting == 0 or float(job["t"]) < -FigureCfg.OVERTIME_WAIT


func _do_rite(c: Contract, squad: Array[Legionnaire]) -> void:
	var reach := 0.0
	for t in c.tips:
		reach += t.distance_to(c.center)
	var r := maxf(FigureCfg.RITE_R_MIN, reach / maxf(1.0, c.tips.size()) * FigureCfg.RITE_R_FRAC)
	var hit := 0
	var stunned := 0
	var effects := world.items_of(c.owner_side).effects
	for f: Variant in effects.enemies(c.center, r):
		effects.damage(f, FigureCfg.RITE_DMG, c.center)
		hit += 1
		if f.alive:
			f.stun(FigureCfg.RITE_STUN)
			stunned += 1 if f.is_stunned() else 0
	var raised := 0
	var hero := world.hero_of(c.owner_side)
	if hero != null:
		# Дубль-вэ базового ранга: обряд — не навык, прокачка W его не усиливает
		var corpses := hero.fresh_corpses(c.center, r, FigureCfg.RITE_RAISE_MAX)
		raised = hero.raise_corpses(corpses, float(LegionCfg.W_DMG_MULT_BY_RANK[0]),
			float(LegionCfg.W_DURATION_BY_RANK[0])).size()
	var live: Array[Legionnaire] = []
	for u in squad:
		if is_instance_valid(u) and u.alive:
			u.rite_dmg_mult = FigureCfg.RITE_BUFF_MULT
			live.append(u)
	_buffs.append({"t": FigureCfg.RITE_BUFF_T, "units": live})
	last_rite = {"center": c.center, "r": r, "hit": hit, "stunned": stunned, "raised": raised,
		"units": live.size()}
	_stat("rites")
	world.impact_stop(FigureCfg.RITE_HITSTOP)
	Juice.shake(world, FigureCfg.RITE_SHAKE, FigureCfg.RITE_SHAKE_T)
	world.field_of(c).on_rite(c, r)


func _unbuff(units: Array[Legionnaire]) -> void:
	for u in units:
		if is_instance_valid(u):
			u.rite_dmg_mult = 1.0


func _stat(key: String) -> void:
	world.stats[key] = int(world.stats.get(key, 0)) + 1
