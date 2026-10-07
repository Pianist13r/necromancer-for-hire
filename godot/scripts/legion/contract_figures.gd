class_name LegionFigures
extends RefCounted
##
## Что делают бойцы, выстроенные в фигуру (Игорь 26.09: «чтобы юниты, которые выстроились в эту
## фигуру, что-то особенное начинали делать… если сам дождался и она сама распалась, то они
## какую-нибудь ульту делают»). Распознавание — ContractShape, геометрия договора — Contract,
## ввод и отрисовка — ContractField; здесь только бой.
##
## Подготовка (D-1002 §1, Игорь 05.10.2026): ульта/специальный выпуск срабатывает, только если
## строй держал нужную долю углов НЕПРЕРЫВНО FigureCfg.CHARGE_TIME секунд (Contract.charge_t
## копит ContractField.tick). Ранний выпуск — обычный натиск, без ульты. Так лечится спам мелких
## фигур «на двух скелетов»: у треугольника мест три, порог заряда — два (2/3).
##
## Восьмёрка — «Двойная смена»:
##   · пока держится — строй бьёт чаще (Legionnaire._strike, FigureCfg.EIGHT_PERIOD_MULT);
##   · выпуск (щелчок, рогатка, таяние) — «крест-накрест»: бойцы каждой петли бегут к центру
##     другой петли, петли проходят сквозь перетяжку (charge_for);
##   · растаяла сама целиком, строй набран (≥ OVERTIME_FILL мест) — «Сверхурочные»: через
##     OVERTIME_DELAY каждый участник делает второй натиск обратно, к центру своей петли.
##     Заряд восьмёрке не нужен: до самотаяния фигура и так стоит весь срок.
## Треугольник — «Обряд»:
##   · строй треугольника НЕ бьёт — держит обряд (Legionnaire._tick_posted);
##   · заряженный выпуск — натиск к центру плюс удар в центре, оглушение, свежие трупы встают
##     внештатниками и усиление участников ×RITE_BUFF_MULT.
## Квадрат — «Каре»: строй получает меньше урона (Legionnaire.take_damage), давка его не
##   прогибает (LegionWorld._tick_press), фигура тает дольше. Заряженный выпуск — защитный
##   бафф участников (входящий урон ×SQUARE_GUARD_MULT на SQUARE_GUARD_T секунд).
## Пятиугольник — «Комиссия по упокоению» (D-1002 §4): бойцы на четырёх углах из пяти.
##   Пассив: каждый участник, дождавшийся заряда, получает одноразовый личный щит поля
##   max_hp (подновление линии его не пополняет). Заряженный выпуск — первое касание залпа
##   метит цель, и участники ЭТОЙ группы бьют её ×PENTA_MARK_MULT.
## Полукруг «D» — «Неустойка» (D-1002 §4): два угла между прямой стороной и дугой. Заряженный
##   выпуск — первое касание залпа замедляет врагов в D_SLOW_R px на D_SLOW_T секунд.
##
## Выпуск рогатки идёт по ОБЩЕЙ оси оттяжки (axis): у каждого участника своё начало траектории,
## соседняя фигура не выпускается. Щелчок и таяние оси не дают — тогда у фигуры своя геометрия:
## треугольник к центру, каре/комиссия/неустойка наружу, восьмёрка крест-накрест.
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
## Усиление участников фигуры: {t, units: Array[Legionnaire], kind}.
var _buffs: Array[Dictionary] = []
## Треугольник, который сейчас срывается с обрядом: натиск его участников — к центру.
var _rite: Contract = null
## Номер группы залпа для меток «Комиссии» (цель помечается id группы, а не словарём: id
## сериализуется снимком и переживает загрузку).
var _ult_serial := 0


func setup(w: LegionWorld) -> void:
	world = w


func reset() -> void:
	for b in _buffs:
		_unbuff(b["units"], b["kind"])
	_buffs.clear()
	_overtime.clear()
	_rite = null
	last_rite = {}
	# счётчик групп залпа — с нуля: у клиентов сетевого боя разная история, а id группы
	# сериализуется снимком (J11). Сброс здесь покрывает и start_map, и старт сетевого матча.
	_ult_serial = 0


## Куда бежит боец места p при выпуске фигуры c: [стрелка, предел пробега]. axis — общая ось
## оттяжки рогатки (ZERO — выпуск без прицела: у фигуры своя геометрия).
func charge_for(c: Contract, p: Dictionary, u: Legionnaire, axis := Vector2.ZERO) -> Array:
	if axis != Vector2.ZERO:
		return [axis, INF]
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
## power < 0 — щелчок, axis != ZERO — рогатка (общая ось оттяжки). Залпы участков — одна группа:
## комбо растёт один раз за выпуск. Заряжен ли строй, решает Contract.charge_ready(): не заряжен —
## ульты нет, но натиск идёт обычный.
func release(c: Contract, power: float, perfect: bool, axis := Vector2.ZERO) -> int:
	var squad := _squad(c)
	var ult := c.charge_ready()
	_ult_serial += 1
	var group := {"hit": false, "units": 0, "id": _ult_serial}
	if ult and c.figure == ContractShape.TRIANGLE:
		_rite = c
	var n := 0
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var dir := axis if axis != Vector2.ZERO else c.seg_dir(s)
		var v := world._volley(dir, power, perfect, true)
		v["group"] = group
		if axis != Vector2.ZERO:
			v["axis"] = axis
		_ult_volley(c, v, ult, _ult_serial)
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
		if ult:
			_do_ult(c, squad, axis)
			world.figure_ult.emit(c)
		if axis != Vector2.ZERO:
			world.figure_slung.emit(c)
	return n


## Метка залпа: у «Комиссии» — id группы для метки цели, у «Неустойки» — параметры замедления.
## У остальных ульта решается сразу (_do_ult) или первым контактом самой группы.
func _ult_volley(c: Contract, v: Dictionary, ult: bool, group_id: int) -> void:
	if not ult:
		return
	match c.figure:
		ContractShape.PENTAGON:
			v["mark_group"] = group_id
		ContractShape.D_SHAPE:
			v["slow"] = {"r": FigureCfg.D_SLOW_R, "mult": FigureCfg.D_SLOW_MULT,
				"t": FigureCfg.D_SLOW_T}
		_:
			pass


## Ульта заряженного выпуска, которая решается сразу (не первым контактом).
func _do_ult(c: Contract, squad: Array[Legionnaire], _axis: Vector2) -> void:
	match c.figure:
		ContractShape.TRIANGLE:
			_do_rite(c, squad)
		ContractShape.SQUARE:
			_do_guard(squad)
		_:
			pass


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
	var ult := c.charge_ready()
	if ult and c.figure == ContractShape.TRIANGLE:
		_rite = c
	# у самотаяния тоже своя группа залпа (J5): у двух тающих «Комиссий» с общим id 0 метка
	# одной усиливала бы бойцов другой, а их собственные метки были бы неотличимы
	_ult_serial += 1
	var group := {"hit": false, "units": 0, "id": _ult_serial}
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var v := world._volley(c.seg_dir(s), -1.0, false, false)
		v["group"] = group
		_ult_volley(c, v, ult, _ult_serial)
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
	elif ult:
		_do_ult(c, squad, Vector2.ZERO)
		world.figure_ult.emit(c)


## Бойцы, стоящие в строю фигуры (POSTED на её местах), — участники выпуска и обряда.
func _squad(c: Contract) -> Array[Legionnaire]:
	var squad: Array[Legionnaire] = []
	for p in c.posts:
		var u: Legionnaire = p["unit"]
		if p["dead"] or u == null or u.state != Legionnaire.State.POSTED:
			continue
		squad.append(u)
	return squad


## Шаг боя (мир зовёт после бойцов): отложенные «Сверхурочные» срываются; пассив «Комиссии»
## выдаёт щиты, усиления гаснут.
func tick(dt: float) -> void:
	for i in range(_overtime.size() - 1, -1, -1):
		_overtime[i]["t"] = float(_overtime[i]["t"]) - dt
		if float(_overtime[i]["t"]) <= 0.0 and _fire_overtime(_overtime[i]):
			_overtime.remove_at(i)
	for i in range(_buffs.size() - 1, -1, -1):
		_buffs[i]["t"] = float(_buffs[i]["t"]) - dt
		if float(_buffs[i]["t"]) <= 0.0:
			_unbuff(_buffs[i]["units"], _buffs[i]["kind"])
			_buffs.remove_at(i)
	if world != null:
		for c in world.all_contracts():
			_tick_charge_passive(c)


## Пассив «Комиссии»: строй ДОЖДАЛСЯ заряда — каждый стоящий участник получает одноразовый
## личный щит. Один раз на договор (Contract.ult_armed): подновление линии щит не пополняет и
## новый приход его не получает — он не держал позицию.
func _tick_charge_passive(c: Contract) -> void:
	if c.figure != ContractShape.PENTAGON or c.ult_armed or not c.charge_ready():
		return
	c.ult_armed = true
	for p in c.posts:
		var u: Legionnaire = p["unit"]
		if p["dead"] or u == null or not u.alive or u.shield_given:
			continue
		if u.state != Legionnaire.State.POSTED:
			continue
		u.shield_given = true
		u.shield_hp = u.max_hp * FigureCfg.PENTA_SHIELD


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


## «Обряд»: удар в центре фигуры. У мини-обряда числа ослаблены (D-1002 §6 «Мини-спам»):
## радиус не больше RITE_MINI_R_FRAC·D, урон RITE_DMG_MINI, оглушение RITE_STUN_MINI, подъём ≤ 1.
func _do_rite(c: Contract, squad: Array[Legionnaire]) -> void:
	var reach := 0.0
	for t in c.tips:
		reach += t.distance_to(c.center)
	var r := maxf(FigureCfg.RITE_R_MIN, reach / maxf(1.0, c.tips.size()) * FigureCfg.RITE_R_FRAC)
	var dmg := FigureCfg.RITE_DMG
	var stun := FigureCfg.RITE_STUN
	var raise_max := FigureCfg.RITE_RAISE_MAX
	if c.size_mini:
		r = minf(r, ContractShape.fig_span(c.points) * FigureCfg.RITE_MINI_R_FRAC)
		dmg = FigureCfg.RITE_DMG_MINI
		stun = FigureCfg.RITE_STUN_MINI
		raise_max = FigureCfg.RITE_RAISE_MAX_MINI
	var hit := 0
	var stunned := 0
	var effects := world.items_of(c.owner_side).effects
	for f: Variant in effects.enemies(c.center, r):
		effects.damage(f, dmg, c.center)
		hit += 1
		if f.alive:
			f.stun(stun)
			stunned += 1 if f.is_stunned() else 0
	var raised := 0
	var hero := world.hero_of(c.owner_side)
	if hero != null:
		# Обряд поднимает тем же Дубль-вэ: не навык, поправки W его не усиливают
		var corpses := hero.fresh_corpses(c.center, r, raise_max)
		raised = hero.raise_corpses(corpses, LegionCfg.W_DMG_MULT, LegionCfg.W_DURATION).size()
	var live: Array[Legionnaire] = []
	for u in squad:
		if is_instance_valid(u) and u.alive:
			u.rite_dmg_mult = FigureCfg.RITE_BUFF_MULT
			live.append(u)
	_add_buff(live, FigureCfg.RITE_BUFF_T, &"rite")
	last_rite = {"center": c.center, "r": r, "hit": hit, "stunned": stunned, "raised": raised,
		"units": live.size()}
	_stat("rites")
	world.impact_stop(FigureCfg.RITE_HITSTOP)
	Juice.shake(world, FigureCfg.RITE_SHAKE, FigureCfg.RITE_SHAKE_T)
	world.field_of(c).on_rite(c, r)


## «Каре» заряженный выпуск: участники держат защиту SQUARE_GUARD_T секунд.
func _do_guard(squad: Array[Legionnaire]) -> void:
	var live: Array[Legionnaire] = []
	for u in squad:
		if is_instance_valid(u) and u.alive:
			u.guard_dmg_mult = FigureCfg.SQUARE_GUARD_MULT
			live.append(u)
	if not live.is_empty():
		_add_buff(live, FigureCfg.SQUARE_GUARD_T, &"armor")
		_stat("guards")


func _add_buff(units: Array[Legionnaire], t: float, kind: StringName) -> void:
	if units.is_empty():
		return
	# обновление — по максимуму срока, а не перемножением: старая запись того же вида снимается
	for i in range(_buffs.size() - 1, -1, -1):
		if _buffs[i]["kind"] != kind:
			continue
		# состав — ОБЪЕДИНЕНИЕ, а не только первая запись (J1): второй отряд, получивший тот же
		# бафф, обязан попасть в запись — снятие по таймеру идёт по её участникам, и боец,
		# не попавший туда, остался бы с множителем до конца боя
		var known: Array = _buffs[i]["units"]
		for u in units:
			if not known.has(u):
				known.append(u)
		_buffs[i]["units"] = known
		_buffs[i]["t"] = maxf(float(_buffs[i]["t"]), t)
		return
	_buffs.append({"t": t, "units": units.duplicate(), "kind": kind})


func _unbuff(units: Array[Legionnaire], kind: StringName) -> void:
	for u in units:
		if not is_instance_valid(u):
			continue
		match kind:
			&"rite":
				u.rite_dmg_mult = 1.0
			&"armor":
				u.guard_dmg_mult = 1.0
			_:
				pass


func _stat(key: String) -> void:
	world.stats[key] = int(world.stats.get(key, 0)) + 1
