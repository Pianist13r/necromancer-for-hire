# gdlint: disable=max-public-methods
class_name LegionGrid
extends RefCounted
##
## Пространственная сетка мира: поиск соседей и расталкивание без аллокаций в кадре.
## Пересобирается раз в кадр (rebuild): голова списка на клетку + «следующий» на сущность —
## два PackedInt32Array вместо словарей и физических тел (скилл godot-optimization).
## Индексы действуют до конца кадра: мёртвых отсекает флаг alive, новые попадут в следующий.
##

var world: LegionWorld = null

var _gw := 0
var _gh := 0
## Размер мира, под который собрана сетка: карта PvP больше (DESIGN §3.3) — пересборка.
var _size := Vector2.ZERO
## PvP: те же бойцы ещё и списками по сторонам (голова — клетка × сторона): поиск чужих не
## перебирает своих. Без этого в толпе у своего Котла запрос «ближайший чужой» стоил ~20 мкс
## (замер 27.09: 266 бойцов — 7,6 из 11,6 мс шага мира на бойцах).
var _s_head := PackedInt32Array()
var _s_next := PackedInt32Array()
var _n_sides := 1
## Котлы сторон на этот кадр: позиция и постройка-Котёл (null — пал или сдался). Поиск цели
## бойца спрашивает их сотни раз за шаг — без вызовов PvpSide.alive() и цепочек свойств.
var _cz_pos := PackedVector2Array()
var _cz_b: Array[LegionBuilding] = []
var _u_head := PackedInt32Array()
var _u_next := PackedInt32Array()
var _f_head := PackedInt32Array()
var _f_next := PackedInt32Array()


func setup(w: LegionWorld) -> LegionGrid:
	world = w
	return self


func _gx(x: float) -> int:
	return clampi(int((x + LegionCfg.SPATIAL_MARGIN) / LegionCfg.SPATIAL_CELL), 0, _gw - 1)


func _gy(y: float) -> int:
	return clampi(int((y + LegionCfg.SPATIAL_MARGIN) / LegionCfg.SPATIAL_CELL), 0, _gh - 1)


func rebuild() -> void:
	if _gw == 0 or _size != world.world_size:
		_size = world.world_size
		_gw = ceili((_size.x + 2.0 * LegionCfg.SPATIAL_MARGIN) / LegionCfg.SPATIAL_CELL)
		_gh = ceili((_size.y + 2.0 * LegionCfg.SPATIAL_MARGIN) / LegionCfg.SPATIAL_CELL)
		_u_head.resize(_gw * _gh)
		_f_head.resize(_gw * _gh)
	_u_head.fill(-1)
	_f_head.fill(-1)
	_u_next.resize(world.units.size())
	for i in world.units.size():
		var u := world.units[i]
		u.idx = i
		_u_next[i] = -1
		if not u.alive:
			continue
		var c := _gy(u.position.y) * _gw + _gx(u.position.x)
		_u_next[i] = _u_head[c]
		_u_head[c] = i
	if world.pvp:
		_rebuild_sides()
	_f_next.resize(world.foes.size())
	for i in world.foes.size():
		var f := world.foes[i]
		f.idx = i
		_f_next[i] = -1
		if not f.alive:
			continue
		var c := _gy(f.position.y) * _gw + _gx(f.position.x)
		_f_next[i] = _f_head[c]
		_f_head[c] = i


## Ближайший живой враг в радиусе r. ghosts = false — призраков не видим (строй их не ловит).
## v20: posted = true — ищет строй, а строй Юриста не видит (Foe.is_law_immune): иначе Юрист,
## стоящий в строю, заслонял бы соседей-зомби от бойцов рядом.
func nearest_foe(p: Vector2, r: float, ghosts: bool, posted := false) -> Foe:
	var best: Foe = null
	var bd := r * r
	for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
		for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
			var i := _f_head[gy * _gw + gx]
			while i != -1:
				var f := world.foes[i]
				if f.alive and (ghosts or not f.ghost) and not (posted and f.is_law_immune()):
					var d := f.position.distance_squared_to(p)
					if d < bd:
						bd = d
						best = f
				i = _f_next[i]
	return best


## Цель натиска. Натиск бежит по стрелке «до первого врага»: пехоту он берёт только прямо на
## пути (узкий конус CHARGE_SEEK_DOT, CHARGE_SEEK px) и потому проходит мимо зомби, давящих
## соседний участок. Но нотариуса в широком конусе впереди и призрака в любую сторону он
## выцеливает — это и есть смысл выпуска отряда (docs/CONCEPT.md: «отпусти крыло на нотариусов»).
func charge_target(p: Vector2, dir: Vector2) -> Foe:
	var r := maxf(LegionCfg.CHARGE_SEEK_SIGNER, LegionCfg.CHARGE_SEEK_GHOST)
	var best: Foe = null
	var best_score := INF
	for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
		for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
			var i := _f_head[gy * _gw + gx]
			while i != -1:
				var f := world.foes[i]
				i = _f_next[i]
				if not f.is_active():
					continue
				var to := f.position - p
				var d := to.length()
				var dot := to.dot(dir) / maxf(d, 0.001)
				var score := INF
				if f.ghost and d <= LegionCfg.CHARGE_SEEK_GHOST:
					score = d
				elif f.type_id == "signer" and d <= LegionCfg.CHARGE_SEEK_SIGNER \
						and dot >= LegionCfg.CHARGE_SIGNER_DOT:
					score = d
				elif d <= LegionCfg.CHARGE_SEEK and dot >= LegionCfg.CHARGE_SEEK_DOT:
					# пехота на пути — после приоритетных целей: те в счёте без надбавки
					score = d + LegionCfg.CHARGE_SEEK_SIGNER
				if score < best_score:
					best_score = score
					best = f
	return best


## B-077: есть ли впереди по натиску хоть один враг — не дальше r по ходу бега и не дальше
## half_w вбок от его оси (dir — единичный). Натиск без цели и без врагов на пути больше не
## летит на всю дальность «в пустоту».
func foe_ahead(p: Vector2, dir: Vector2, r: float, half_w: float) -> bool:
	var rr := r + half_w
	for gy in range(_gy(p.y - rr), _gy(p.y + rr) + 1):
		for gx in range(_gx(p.x - rr), _gx(p.x + rr) + 1):
			var i := _f_head[gy * _gw + gx]
			while i != -1:
				var f := world.foes[i]
				i = _f_next[i]
				if not f.is_active():
					continue
				var to := f.position - p
				var along := to.dot(dir)
				if along > 0.0 and along <= r and absf(to.cross(dir)) <= half_w:
					return true
	return false


## «Приманка» натиска: нотариус и призрак — их charge_target выцеливает издалека и раньше пехоты
## (ContractField.strike_clear гасит по ним золото, D-0927-53).
static func is_lure(f: Foe) -> bool:
	return f.ghost or f.type_id == "signer"


func _nearest_unit_impl(p: Vector2, r: float, loose_only: bool, posted_only: bool) -> Legionnaire:
	var best: Legionnaire = null
	var bd := r * r
	for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
		for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
			var i := _u_head[gy * _gw + gx]
			while i != -1:
				var u := world.units[i]
				i = _u_next[i]
				if not u.alive:
					continue
				var posted := u.state == Legionnaire.State.POSTED
				if (loose_only and posted) or (posted_only and not posted):
					continue
				var d := u.position.distance_squared_to(p)
				if d < bd:
					bd = d
					best = u
	return best


func nearest_unit(p: Vector2, r: float) -> Legionnaire:
	return _nearest_unit_impl(p, r, false, false)


## Ближайший НЕ строевой боец (свободный, на марше, в натиске).
func nearest_unit_loose(p: Vector2, r: float) -> Legionnaire:
	return _nearest_unit_impl(p, r, true, false)


## Боец строя, в которого упирается точка: строй — стена.
func posted_blocking(p: Vector2, r: float) -> Legionnaire:
	return _nearest_unit_impl(p, r, false, true)


func count_units_near(p: Vector2, r: float) -> int:
	var n := 0
	var r2 := r * r
	for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
		for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
			var i := _u_head[gy * _gw + gx]
			while i != -1:
				var u := world.units[i]
				if u.alive and u.position.distance_squared_to(p) <= r2:
					n += 1
				i = _u_next[i]
	return n


## Живая пехота (без призраков) в радиусе — «давит ли кто-то этот участок».
func count_foes_near(p: Vector2, r: float) -> int:
	var n := 0
	var r2 := r * r
	for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
		for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
			var i := _f_head[gy * _gw + gx]
			while i != -1:
				var f := world.foes[i]
				if f.is_active() and not f.ghost and f.position.distance_squared_to(p) <= r2:
					n += 1
				i = _f_next[i]
	return n


## v18 «Давка»: разнести массу пехоты по живым участкам договора — каждого врага к БЛИЖАЙШЕМУ
## участку, если его центр ближе band к линии участка (иначе враг у стыка давил бы оба и короткий
## хвост линии прорывался от троих). Пишет c.press_mass[s] и c.press_sum[s] (Σ позиция × масса).
## Вставший нотариус (holding) стоит поодаль и не давит.
func press_scan(c: Contract, band: float) -> void:
	var n_seg := c.seg_count()
	c.press_mass.resize(n_seg)
	c.press_mass.fill(0.0)
	c.press_sum.resize(n_seg)
	c.press_sum.fill(Vector2.ZERO)
	if c.points.is_empty():
		return
	var box := Rect2(c.points[0], Vector2.ZERO)
	for p in c.points:
		box = box.expand(p)
	box = box.grow(band)
	var band2 := band * band
	for gy in range(_gy(box.position.y), _gy(box.end.y) + 1):
		for gx in range(_gx(box.position.x), _gx(box.end.x) + 1):
			var i := _f_head[gy * _gw + gx]
			while i != -1:
				var f := world.foes[i]
				i = _f_next[i]
				# v20: оглушённый (Ку) строй не давит — молния снимает напор с участка
				if not f.is_active() or f.ghost or f.holding or f.stun_t > 0.0 \
						or not box.has_point(f.position):
					continue
				var best := band2
				var best_s := -1
				var best_q := Vector2.ZERO
				for s in n_seg:
					# рамка участка — отсев до точной дистанции (замер verifier 26.09: без него
					# давка при 300 врагах — 6,7 мс из 11 мс шага мира)
					if not c.seg_alive(s) or not c.seg_press_box[s].has_point(f.position):
						continue
					var poly := c.seg_polys[s]
					for k in range(1, poly.size()):
						var q := Geometry2D.get_closest_point_to_segment(f.position, poly[k - 1], poly[k])
						var d2 := q.distance_squared_to(f.position)
						if d2 <= best:
							best = d2
							best_s = s
							best_q = q
				if best_s < 0:
					continue
				# давит тот, кто идёт или бьёт в сторону участка: колонна, идущая мимо фланга, и
				# толпа позади пробки строй не гнут (партия «Лабиринт» по переписке, 26.09)
				var to_seg := best_q - f.position
				if to_seg.length_squared() > 1.0 \
						and f.heading().dot(to_seg.normalized()) < LegionCfg.PRESS_FACING:
					continue
				var m := float(LegionCfg.PRESS_MASS.get(f.type_id, LegionCfg.PRESS_MASS_DEFAULT)) \
					* LegionChallenge.press_mult(f, c.kind)
				c.press_mass[best_s] += m
				c.press_sum[best_s] += f.position * m


## Пехота-прикрытие нотариуса: активные враги, кроме нотариусов и призраков.
func count_escort(p: Vector2, r: float) -> int:
	var n := 0
	var r2 := r * r
	for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
		for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
			var i := _f_head[gy * _gw + gx]
			while i != -1:
				var f := world.foes[i]
				i = _f_next[i]
				if f.is_active() and not f.ghost and f.type_id != "signer" \
						and f.position.distance_squared_to(p) <= r2:
					n += 1
	return n


## Центр самой плотной группы бойцов в дальности range (для печати); INF — никого.
func densest_unit_point(from: Vector2, range_r: float, r: float) -> Vector2:
	var best := Vector2.INF
	var best_n := 0
	var rr := range_r * range_r
	var seen := 0
	# B-365: обход обрывается на SIGNER_SAMPLES·4 бойцах, и ничью берёт первый найденный — на
	# поле «Схватки» справа клетки обходятся справа налево (зеркально): иначе нотариус левой
	# половины выбирал кучку с тыла (от Котла), а правой — с фронта
	var gx0 := _gx(from.x - range_r)
	var gx1 := _gx(from.x + range_r)
	var flip := world.terrain != null and world.terrain.mirror_x \
		and from.x > world.world_size.x * 0.5
	for gy in range(_gy(from.y - range_r), _gy(from.y + range_r) + 1):
		for k in gx1 - gx0 + 1:
			var gx := gx1 - k if flip else gx0 + k
			var i := _u_head[gy * _gw + gx]
			while i != -1:
				var u := world.units[i]
				i = _u_next[i]
				if not u.alive or u.position.distance_squared_to(from) > rr:
					continue
				seen += 1
				if seen > LegionCfg.SIGNER_SAMPLES * 4:
					return best
				var n := count_units_near(u.position, r)
				if n > best_n:
					best_n = n
					best = u.position
	return best


## Для бота: есть ли враг данного вида в полосе ПЕРЕД точкой (по нормали, до dist).
func separate() -> void:
	var r := LegionCfg.UNIT_RADIUS * 2.0
	var r2 := r * r
	for u in world.units:
		# строй неподвижен, марш идёт колонной по маршруту A*: расталкивание на узком мосту
		# запирало колонну (толчок сильнее шага), поэтому толкаем только свободных и натиск
		if not u.alive or u.state == Legionnaire.State.POSTED \
				or u.state == Legionnaire.State.MARCH:
			continue
		var push := Vector2.ZERO
		var p := u.position
		for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
			for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
				var i := _u_head[gy * _gw + gx]
				while i != -1:
					var o := world.units[i]
					i = _u_next[i]
					if o == u or not o.alive:
						continue
					var d := p - o.position
					var dl2 := d.length_squared()
					if dl2 < r2 and dl2 > 0.0001:
						var dl := sqrt(dl2)
						push += d / dl * (r - dl) * 0.5
		if push != Vector2.ZERO:
			var nxt := p + push.limit_length(LegionCfg.SEPARATION_STEP)
			if world.terrain.walkable(nxt):
				u.position = nxt
	var fr := LegionCfg.FOE_SEPARATION * 2.0
	for f in world.foes:
		if not f.alive or f.state == Foe.State.SLEEP:
			continue
		var push := Vector2.ZERO
		var p := f.position
		for gy in range(_gy(p.y - fr), _gy(p.y + fr) + 1):
			for gx in range(_gx(p.x - fr), _gx(p.x + fr) + 1):
				var i := _f_head[gy * _gw + gx]
				while i != -1:
					var o := world.foes[i]
					i = _f_next[i]
					if o == f or not o.alive or o.ghost != f.ghost:
						continue
					# толчок сильнее шага зомби: вставший нотариус запирал свою колонну — на
					# подъёме «Моста» 15–20 зомби стояли за ним ~20 с (партия по переписке
					# 25.09.2026). Пару «стоящий — идущий» не расталкиваем вовсе: толкай мы
					# стоящего, идущий гнал бы его перед собой (регресс-тест legion_slow_fixes).
					if o.holding != f.holding:
						continue
					var d := p - o.position
					var dl2 := d.length_squared()
					var rr := f.radius + o.radius
					if dl2 < rr * rr and dl2 > 0.0001:
						var dl := sqrt(dl2)
						push += d / dl * (rr - dl) * 0.5
		if push == Vector2.ZERO:
			continue
		var nxt := p + push.limit_length(LegionCfg.SEPARATION_STEP)
		if f.ghost or (world.terrain.walkable(nxt) \
				and posted_blocking(nxt, LegionCfg.BLOCK_R + f.radius - 8.0) == null):
			f.position = nxt


## Удар по кругу (печать, таран): все живые бойцы в радиусе получают урон. Возвращает,
## скольких задело (статистика: сколько армии съедают печати).
func hit_units(at: Vector2, r: float, dmg: float, from: Vector2) -> int:
	var n := 0
	var r2 := r * r
	for gy in range(_gy(at.y - r), _gy(at.y + r) + 1):
		for gx in range(_gx(at.x - r), _gx(at.x + r) + 1):
			var i := _u_head[gy * _gw + gx]
			while i != -1:
				var u := world.units[i]
				i = _u_next[i]
				if u.alive and u.position.distance_squared_to(at) <= r2:
					u.last_hit_side = -1
					u.take_damage(dmg, from)
					n += 1
	return n


# ── PvP: чужие бойцы и чужой Котёл (docs/pvp/DESIGN.md §2.3) ─────────────────

## Ближайший живой боец НЕ стороны side в радиусе r.
func nearest_enemy_unit(p: Vector2, r: float, side: int) -> Legionnaire:
	var best: Legionnaire = null
	var bd := r * r
	var cells := _gw * _gh
	for s in _n_sides:
		if s == side:
			continue
		for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
			for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
				var i := _s_head[s * cells + gy * _gw + gx]
				while i != -1:
					var u := world.units[i]
					i = _s_next[i]
					if u.alive:
						var d := u.position.distance_squared_to(p)
						if d < bd:
							bd = d
							best = u
	return best


## «Оборона дома»: ближайшая к p (ближе r) враждебная бойцу стороны side цель, которая сама
## лежит в круге zr вокруг zc (Котёл стороны). Враг PvE — любой, и призрак тоже (свободный их
## бьёт, как в Legionnaire._tick_free); в PvP ещё чужой боец. Отдельный поиск, а не
## nearest_hostile: тот ищет чужих бойцов только в досягаемости, а ближайшая цель вне зоны не
## должна заслонять цель в зоне чуть дальше.
func nearest_hostile_in_zone(p: Vector2, r: float, side: int, zc: Vector2, zr: float) -> Node2D:
	var best: Node2D = null
	var bd := r * r
	var zr2 := zr * zr
	for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
		for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
			var i := _f_head[gy * _gw + gx]
			while i != -1:
				var f := world.foes[i]
				i = _f_next[i]
				if f.alive and f.position.distance_squared_to(zc) < zr2:
					var d := f.position.distance_squared_to(p)
					if d < bd:
						bd = d
						best = f
	if not world.pvp:
		return best
	var cells := _gw * _gh
	for s in _n_sides:
		if s == side:
			continue
		for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
			for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
				var i := _s_head[s * cells + gy * _gw + gx]
				while i != -1:
					var u := world.units[i]
					i = _s_next[i]
					if u.alive and u.position.distance_squared_to(zc) < zr2:
						var d := u.position.distance_squared_to(p)
						if d < bd:
							bd = d
							best = u
	return best


## Есть ли в круге zr вокруг zc враждебная стороне side цель (враг PvE; в PvP — и чужой боец).
## Один запрос на сторону за шаг (LegionWorld._scan_home_threats): без него каждый свободный
## у Котла искал бы цель радиусом HOME_GUARD_PURSUE каждый шаг даже в мирное время.
func hostile_in_zone(zc: Vector2, zr: float, side: int) -> bool:
	if nearest_foe(zc, zr, true) != null:
		return true
	return world.pvp and nearest_enemy_unit(zc, zr, side) != null


## Списки бойцов по сторонам (только PvP; индексы — те же, что у общего списка этого кадра).
func _rebuild_sides() -> void:
	_n_sides = world.sides.size()
	_cz_pos.resize(_n_sides)
	_cz_b.resize(_n_sides)
	for s: PvpSide in world.sides:
		_cz_pos[s.index] = s.cauldron_pos
		_cz_b[s.index] = s.staff.cauldron if s.alive() and s.staff != null else null
	var cells := _gw * _gh
	_s_head.resize(cells * _n_sides)
	_s_head.fill(-1)
	_s_next.resize(world.units.size())
	for i in world.units.size():
		var u := world.units[i]
		_s_next[i] = -1
		if not u.alive:
			continue
		var c := u.side * cells + _gy(u.position.y) * _gw + _gx(u.position.x)
		_s_next[i] = _s_head[c]
		_s_head[c] = i


## Цель бойца стороны side в PvP: враг PvE — ровно тем же поиском, что в одиночке (радиус r);
## чужой боец и чужой Котёл — только в досягаемости reach от края их тела: бьют лишь того, до
## кого дотянулись, а искать дальше — лишняя работа в толпе (замер 27.09: поиск был самым
## горячим местом шага мира). Из достающих — ближайший по краю тела (Котёл большой: боец у его
## бока бьёт его, а не бойца за спиной); не достаёт никто — враг PvE, как в одиночке.
func nearest_hostile(p: Vector2, r: float, side: int, ghosts: bool, reach: float,
		posted := false) -> Node2D:
	var foe := nearest_foe(p, r, ghosts, posted)
	var best: Node2D = null
	var bd := reach
	if foe != null:
		var df := foe.position.distance_to(p) - foe.radius
		if df <= bd:
			bd = df
			best = foe
	var u := nearest_enemy_unit(p, reach + LegionCfg.UNIT_RADIUS, side)
	if u != null:
		var du := u.position.distance_to(p) - LegionCfg.UNIT_RADIUS
		if du <= bd:
			bd = du
			best = u
	var c := enemy_cauldron(p, reach, side)
	if c != null and c.position.distance_to(p) - LegionCfg.CAULDRON_RADIUS <= bd:
		best = c
	return best if best != null else foe


## Чужой живой Котёл (постройка-Котёл стороны), чей край ближе r; null — нет такого.
func enemy_cauldron(p: Vector2, r: float, side: int) -> LegionBuilding:
	var rr := r + LegionCfg.CAULDRON_RADIUS
	for s in _cz_b.size():
		if s != side and _cz_b[s] != null and _cz_pos[s].distance_squared_to(p) <= rr * rr:
			return _cz_b[s]
	return null


## Цель натиска бойца стороны side в PvP: как charge_target (приоритет нотариусов и призраков),
## плюс чужие бойцы — как пехота (узкий конус на пути), плюс чужой Котёл в широком конусе —
## он важнее всего: ради него и бежали.
func charge_target_pvp(p: Vector2, dir: Vector2, side: int) -> Node2D:
	var c := enemy_cauldron(p, LegionCfg.CHARGE_SEEK_SIGNER, side)
	if c != null:
		var to_c := c.position - p
		if to_c.dot(dir) / maxf(to_c.length(), 0.001) >= LegionCfg.CHARGE_SIGNER_DOT:
			return c
	var foe := charge_target(p, dir)
	var best: Node2D = foe
	var best_score := INF
	if foe != null:
		var d0 := foe.position.distance_to(p)
		best_score = d0 if LegionGrid.is_lure(foe) else d0 + LegionCfg.CHARGE_SEEK_SIGNER
	var r := LegionCfg.CHARGE_SEEK
	var cells := _gw * _gh
	for s in _n_sides:
		if s == side:
			continue
		for gy in range(_gy(p.y - r), _gy(p.y + r) + 1):
			for gx in range(_gx(p.x - r), _gx(p.x + r) + 1):
				var i := _s_head[s * cells + gy * _gw + gx]
				while i != -1:
					var u := world.units[i]
					i = _s_next[i]
					if not u.alive:
						continue
					var to := u.position - p
					var d := to.length()
					if d > r or to.dot(dir) / maxf(d, 0.001) < LegionCfg.CHARGE_SEEK_DOT:
						continue
					var score := d + LegionCfg.CHARGE_SEEK_SIGNER
					if score < best_score:
						best_score = score
						best = u
	return best
