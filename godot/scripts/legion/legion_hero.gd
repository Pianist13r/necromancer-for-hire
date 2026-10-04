# gdlint: disable=max-public-methods
class_name LegionHero
extends Node2D
##
## Некромант у Котла: способности Ку (разряд), Дубль-вэ (оформление в штат), Е (аврал).
## DESIGN_V15 §6, §12 п.8–9. Порт правила из старого стека (docs/PORT_NOTES.md §3), сохранён
## дословно: откаты стартуют готовыми, а если цели нет — откат НЕ тратится, слот просто мигает
## отказом. С D-0927-140 заклинания стоят маны сверх отката (LegionCfg.ABILITY_MANA; прежде мана
## целиком принадлежала рунам): не хватает — тот же отказ, мана списывается только за
## состоявшийся каст.
##
## Рисование целится курсором — `cast(slot, at)` принимает точку явно (для тестов и для
## `_unhandled_input`, который читает `get_global_mouse_position()`), поэтому логика не зависит
## от системы ввода Godot.
##

## reason: &"no_target" (Ку) | &"no_corpse" (Дубль-вэ) | &"no_target" (Е — некого ускорять) |
## &"no_mana" (любая — не хватило маны, D-0927-140) | &"locked"
signal cast_failed(slot: int, reason: StringName)

const SLOT_Q := 0
const SLOT_W := 1
const SLOT_E := 2
const _SLOT_KEYS: Array[StringName] = [
	&"ability_unlocked_q", &"ability_unlocked_w", &"ability_unlocked_e",
]
const _RANK_KEYS: Array[StringName] = [&"ability_rank_q", &"ability_rank_w", &"ability_rank_e"]

var world: LegionWorld = null
var necro_view: CharView = null
## Сторона боя (PvpSide.index; одиночка — 0): у каждой стороны PvP свой некромант. Ку бьёт и
## чужих бойцов, Е ускоряет только своих (docs/pvp/DESIGN.md §2.5).
var side := 0
## Что сделал последний состоявшийся каст — для подписей у целей (LegionAbilityAim). Заполняется
## ДО world.hero_cast: после каста цели Ку уже биты, а труп Дубль-вэ убран из мира.
## Ку: {slot, at, hits: [{pos, dmg}]} · Дубль-вэ: {slot, at, raised: [{pos, type}]} ·
## Е: {slot, at, n}.
var last_cast: Dictionary = {}

var _cd: Array[float] = [0.0, 0.0, 0.0]
var _vassals: Array = []
var _haste_left := 0.0
var _haste_units: Array[Legionnaire] = []
var _fx_layer: Node2D = null
## Свой ГСЧ для дрожания простой молнии: вид не должен трогать ни world.rng, ни общий randf.
var _vis_rng := RandomNumberGenerator.new()


func setup(w: LegionWorld, view: CharView) -> void:
	world = w
	necro_view = view
	_fx_layer = Node2D.new()
	_fx_layer.name = "HeroFx"
	_fx_layer.z_index = 50
	world.entities.add_child(_fx_layer)
	_vis_rng.randomize()


## Слой узлов героя живёт в Entities мира, а не под героем: без этого каждый перезапуск карты
## оставлял в дереве пустой «HeroFx» прошлого героя (нашёл legion_impact_test).
func _exit_tree() -> void:
	if is_instance_valid(_fx_layer):
		_fx_layer.queue_free()
	# внештатники живут в world.entities, а тикает их герой: без этого новый бой (start_map
	# освобождает героя) оставлял их застывшими фигурами на карте (кадр items-v2 27.09)
	for v in _vassals:
		if is_instance_valid(v):
			v.queue_free()
	_vassals.clear()


func reset() -> void:
	_cd = [0.0, 0.0, 0.0]
	_haste_left = 0.0
	for v in _vassals:
		if is_instance_valid(v):
			v.queue_free()
	_vassals.clear()


## Тикает мир (LegionWorld._step), не _process: порядок кадра общий для всего боя.
func tick(dt: float) -> void:
	for i in _cd.size():
		_cd[i] = maxf(0.0, _cd[i] - dt)
	for i in range(_vassals.size() - 1, -1, -1):
		var v = _vassals[i]
		if not is_instance_valid(v) or not v.tick(dt, world):
			if is_instance_valid(v):
				# срок вышел (не вытеснен новым) — предметам: «Срочный договор» взрывает
				world.items_of(side).on(&"vassal_expired", [v.position, v.raised_type])
				v.queue_free()
			_vassals.remove_at(i)
	if _haste_left > 0.0:
		_haste_left -= dt
		if _haste_left <= 0.0:
			_end_haste()


## Открыта ли способность: 1 — открыта (meta открывает по порядку карт), 0 — закрыта. Вне
## кампании world.camp_stat даёт 1 всем (integrate1: одно правило открытий для всего боя).
func is_unlocked(slot: int) -> bool:
	return world.camp_stat(_SLOT_KEYS[slot]) > 0.5


func rank(slot: int) -> int:
	return clampi(int(round(world.camp_stat(_RANK_KEYS[slot]))), 0, 2)


func cd_left(slot: int) -> float:
	return _cd[slot]


## Предметы: перезарядить способность сразу («Золотое перо») или укоротить откат («Запасное перо»).
func reset_cd(slot: int) -> void:
	_cd[slot] = 0.0


func cut_cd(slot: int, sec: float) -> void:
	_cd[slot] = maxf(0.0, _cd[slot] - sec)


## Сколько внештатников сейчас держит Дубль-вэ (для UI/теста; список внутренний нарочно).
func vassal_count() -> int:
	return _vassals.size()


## Внештатники для слоя вида (фитиль «Срочного договора»). Только чтение.
func vassals() -> Array:
	return _vassals


func cd_total(slot: int) -> float:
	var base: float = [LegionCfg.Q_COOLDOWN, LegionCfg.W_COOLDOWN, LegionCfg.E_COOLDOWN][slot]
	var perk_cut := LegionCfg.PERK_SHORT_CD_MULT * world.camp_stat(&"perk_short_cd")
	return base * maxf(0.0, 1.0 - perk_cut)


## Каст способности по точке `at` (мировые координаты). Возвращает true, если состоялась
## (иначе откат не трогаем — как в старом стеке).
func cast(slot: int, at: Vector2) -> bool:
	if not is_unlocked(slot) or _cd[slot] > 0.0:
		if not is_unlocked(slot):
			cast_failed.emit(slot, &"locked")
		return false
	if not world.can_pay_ability(slot, side):   # мана и запас бота — своей стороны (P2b)
		# D-0927-140: мало маны — каст не состоялся, откат не тронут (как «нет цели»)
		cast_failed.emit(slot, &"no_mana")
		if side == world.local_side:   # слот и звук отказа — интерфейс игрока за экраном
			world.mana_short.emit(slot)
		return false
	var ok := false
	var reason: StringName = &""
	match slot:
		SLOT_Q:
			ok = _cast_q(at)
			reason = &"no_target"
		SLOT_W:
			ok = _cast_w(at)
			reason = &"no_corpse"
		_:
			ok = _cast_e(at)
			reason = &"no_target"
	if ok:
		world.pay_ability(slot, side)
		_cd[slot] = cd_total(slot)
		if necro_view != null and necro_view.has_clip(&"cast"):
			necro_view.play_once(&"cast")
		if world.pvp:
			world.items_of(side)._on_hero_cast(slot, at)
		if side == world.local_side:   # сигнал слушают интерфейс и бот игрока за экраном
			world.hero_cast.emit(slot, at)
	else:
		cast_failed.emit(slot, reason)
	return ok


# ── Ку — Служебный разряд ─────────────────────────────────────────────────────

func _cast_q(at: Vector2) -> bool:
	if world.pvp:
		return _cast_q_pvp(at)
	var chain := q_targets(at)
	if chain.is_empty():
		return false
	var hits: Array[Dictionary] = []
	var prev_pos: Vector2 = necro_view.position if necro_view != null else world.cauldron_of(side)
	# вид — по положениям ДО урона (как раньше): убитая цель может сразу осесть трупом
	var fx := world.gfx_fx()
	var hand := _hand_point(chain[0].position)
	if fx != null:
		fx.impact.bolt_chain(hand, chain)
	else:
		# экономная графика: тот же цвет артефакта (вид = механика), без слоёв частиц
		var col: Color = world.items_of(side).look_of(&"q_bolt", &"color").get("color", LegionCfg.Q_COLOR)
		if not world.items_of(side).look_of(&"q_bolt", &"color").is_empty():
			world.items_of(side).note_look(&"q_bolt", &"color")
		var from := hand
		for f in chain:
			var to := LegionImpactFx.chest(f)
			_bolt(from, to, col)
			_spark(to, col)
			from = to
		Juice.shake(world, LegionCfg.HERO_CAST_SHAKE, LegionCfg.HERO_CAST_SHAKE_DUR)
	for i in chain.size():
		var f := chain[i]
		if not f.alive:
			# звено уже убил прыжок предыдущего (например «Громоотвода») — эффекты по трупу не
			# зовём, иначе «Громоотвод» прыгал дальше с каждого мёртвого звена (verify-items)
			continue
		var dmg := q_damage(i, f)
		hits.append({"pos": f.position, "dmg": dmg})
		f.take_damage(dmg, prev_pos)
		f.stun(q_stun())          # v20: мёртвого не оглушит (stun проверяет alive)
		prev_pos = f.position
		world.items_of(side).on(&"q_hit", [f, dmg, i])   # «Громоотвод», «Громовая канцелярия»
	last_cast = {"slot": SLOT_Q, "at": at, "hits": hits}
	return true


## Цепь Ку по точке — ровно те враги и в том порядке, в каком ударит молния. Одна функция и
## для каста, и для прицела (зажатая Q): иначе кольца-номера под врагами могли бы соврать.
## Пусто — рядом с точкой (Q_RADIUS) живых врагов нет.
func q_targets(at: Vector2) -> Array[Foe]:
	var main := _nearest_foe(at, LegionCfg.Q_RADIUS)
	if main == null:
		return []
	var chain: Array[Foe] = [main]
	chain.append_array(_nearest_foes_around(main.position, main, q_chain_len() - 1))
	return chain


## Сколько целей бьёт цепь сейчас (перк «Цепная реакция» добавляет, потолок — Q_CHAIN_CAP).
func q_chain_len() -> int:
	var base := mini(LegionCfg.Q_CHAIN_BASE_TARGETS + int(world.camp_stat(&"perk_chain_reaction")),
		LegionCfg.Q_CHAIN_CAP)
	# «Скрепка судьбы» — сверх обычного потолка цепи, но не бесконечно
	return mini(base + int(world.item_add(&"q_chain", side)), CfgItems.Q_CHAIN_HARD_CAP)


## Оглушение Ку (без поправки на босса — её делает Foe.stun) с «Табличкой „Не беспокоить“».
func q_stun() -> float:
	return LegionCfg.Q_STUN * world.item_mult(&"q_stun", side)


## Урон i-й цели цепи с учётом ранга (хвост цепи бьёт последним числом Q_CHAIN_DMG); цель-призрак
## (f задан) — ×Q_GHOST_MULT (v20: строй призрака не бьёт — молния вдвое).
func q_damage(i: int, f: Foe = null) -> float:
	var dmg_idx := mini(i, LegionCfg.Q_CHAIN_DMG.size() - 1)
	var dmg := float(LegionCfg.Q_CHAIN_DMG[dmg_idx]) * LegionCfg.Q_RANK_DMG_MULT[rank(SLOT_Q)]
	dmg *= world.item_mult(&"q_dmg", side)   # «Печать двойного действия»
	return dmg * (LegionCfg.Q_GHOST_MULT if f != null and f.ghost else 1.0)


## Поднятая рука некроманта — откуда бьёт Ку (к цели чуть в сторону от центра фигуры).
func _hand_point(target: Vector2) -> Vector2:
	if necro_view == null:
		return world.cauldron_of(side)
	# от ступней, а не от position вида: у CharView ступни ниже position на ground_px()
	var feet := necro_view.position + Vector2(0.0, necro_view.ground_px())
	var sgn := 1.0 if target.x >= feet.x else -1.0
	return feet + Vector2(sgn * CfgFx.BOLT_HAND.x, -necro_view.body_h * CfgFx.BOLT_HAND.y)


static func _body_h(f: Foe) -> float:
	return f.view.body_h if f.view != null else 40.0


func _nearest_foe(at: Vector2, radius: float) -> Foe:
	var best := INF
	var found: Foe = null
	for f in world.foes:
		if not f.alive:
			continue
		var d := at.distance_squared_to(f.position)
		if d < best and d <= radius * radius:
			best = d
			found = f
	return found


func _nearest_foes_around(at: Vector2, exclude: Foe, count: int) -> Array[Foe]:
	var sorted: Array = []
	for f in world.foes:
		if not f.alive or f == exclude:
			continue
		sorted.append({"f": f, "d": at.distance_squared_to(f.position)})
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["d"] < b["d"])
	var out: Array[Foe] = []
	for i in mini(count, sorted.size()):
		out.append(sorted[i]["f"])
	return out


## PvP: цепь Ку по врагам волн И бойцам других сторон (DESIGN §2.5) — те же числа урона и
## оглушения; ближайший к точке — первым, дальше ближайшие к нему. Вид — простая молния: цепь
## смешанная, слой LegionImpactFx ждёт только врагов (серверу вид не нужен вовсе).
func _cast_q_pvp(at: Vector2) -> bool:
	var chain := q_targets_pvp(at)
	if chain.is_empty():
		return false
	var hits: Array[Dictionary] = []
	var from := _hand_point(chain[0].position)
	var prev_pos := from
	for i in chain.size():
		var t := chain[i]
		var f := t as Foe
		var u := t as Legionnaire
		if (f != null and not f.alive) or (u != null and not u.alive):
			continue
		var look := q_look()
		_bolt(from, t.position, look["color"], float(look["width"]))
		_bolt_branches(from, t.position, look)
		from = t.position
		var dmg := q_damage(i, f)
		hits.append({"pos": t.position, "dmg": dmg})
		if f != null:
			f.last_hit_side = side
			f.take_damage(dmg, prev_pos)
			f.stun(q_stun())
		else:
			u.last_hit_side = side
			u.take_damage(dmg, prev_pos)
			if u.alive:
				u.stun(q_stun())
		world.items_of(side).on(&"q_hit", [t, dmg, i])
		if f != null and f.carrier:
			world.note_carrier_q(f, side, dmg, i)
		prev_pos = t.position
	last_cast = {"slot": SLOT_Q, "at": at, "hits": hits}
	return true


## Цепь Ку в PvP: живые враги волн и живые бойцы других сторон.
func q_targets_pvp(at: Vector2) -> Array[Node2D]:
	var all: Array[Node2D] = []
	for f in world.foes:
		if f.alive:
			all.append(f)
	for u in world.units:
		if u.alive and u.side != side:
			all.append(u)
	var main: Node2D = null
	var best := LegionCfg.Q_RADIUS * LegionCfg.Q_RADIUS
	for t in all:
		var d := at.distance_squared_to(t.position)
		if d <= best:
			best = d
			main = t
	if main == null:
		return []
	all.erase(main)
	var center := main.position
	all.sort_custom(func(a: Node2D, b: Node2D) -> bool:
		return a.position.distance_squared_to(center) < b.position.distance_squared_to(center))
	var chain: Array[Node2D] = [main]
	for i in mini(q_chain_len() - 1, all.size()):
		chain.append(all[i])
	return chain


# ── Дубль-вэ — Оформление в штат ──────────────────────────────────────────────

## v20 (D-0926-39): бригада — до W_RAISE_MAX свежих трупов в W_RAISE_RADIUS, ближайшие первыми.
func _cast_w(at: Vector2) -> bool:
	var corpses := w_corpses(at)
	if corpses.is_empty():
		return false
	var raised := raise_corpses(corpses, float(LegionCfg.W_DMG_MULT_BY_RANK[rank(SLOT_W)]),
		w_duration())
	last_cast = {"slot": SLOT_W, "at": at, "raised": raised}
	Juice.shake(world, LegionCfg.HERO_CAST_SHAKE * 0.8, LegionCfg.HERO_CAST_SHAKE_DUR)
	return true


## Поднять трупы внештатниками (Дубль-вэ и «Обряд» треугольника — LegionFigures): урон вида
## × dmg_mult, живут duration секунд. Возвращает [{pos, type}] поднятых. Отката и маны не касается.
func raise_corpses(corpses: Array[Foe], dmg_mult: float, duration: float) -> Array[Dictionary]:
	var raised: Array[Dictionary] = []
	var removed := false
	var fx := world.gfx_fx()
	for corpse in corpses:
		raised.append({"pos": corpse.position, "type": corpse.type_id})
		if _vassals.size() >= LegionCfg.W_MAX_ALLIES:
			var oldest = _vassals[0]
			_vassals.remove_at(0)
			if is_instance_valid(oldest):
				oldest.queue_free()
		var def: Dictionary = LegionCfg.FOES[corpse.type_id]
		var v := _Vassal.new()
		v.side = side
		v.setup(corpse.type_id, corpse.position, float(def["dmg"]) * dmg_mult, duration)
		# «Срочный договор»: внештатник другого окраса и с фитилём (item_look) — видно, что рванёт
		var tint := world.items_of(side).look_of(&"vassal", &"tint")
		if not tint.is_empty():
			v.retint(tint["color"])
			world.items_of(side).note_look(&"vassal", &"tint")
		world.entities.add_child(v)
		_vassals.append(v)
		if fx != null:
			fx.impact.raise(LegionImpactFx.feet(corpse), _body_h(corpse), v)
		else:
			_spark(corpse.position, LegionCfg.W_COLOR)
		Juice.flash(v, LegionCfg.W_COLOR, 0.2)
		# труп поднят — убрать из мира как раньше: сперва из списка foes, потом из дерева
		# (иначе следующий кадр дёрнет tick() у освобождённого узла)
		var idx := world.foes.find(corpse)
		if idx >= 0:
			world.foes.remove_at(idx)
			removed = true
		world._corpses.erase(corpse)
		corpse.queue_free()
	if removed:
		# W может поднять погибших в этом же кадре, уже ПОСЛЕ rebuild перед ботом.
		# Удаление сдвигает индексы остальных врагов: следующий запрос обязан видеть их заново.
		world.grid.rebuild()
	return raised


## Трупы, которые поднимет Дубль-вэ по точке, ближайшие к ней первыми (не больше
## w_raise_max()), — общий список для каста и прицела (зажатая W): превью не врёт.
func w_corpses(at: Vector2) -> Array[Foe]:
	return fresh_corpses(at, LegionCfg.W_RAISE_RADIUS, w_raise_max())


## Сколько трупов поднимает один каст (v20, D-0926-39) — единственное место, где читается.
func w_raise_max() -> int:
	return maxi(1, LegionCfg.W_RAISE_MAX + int(world.item_add(&"w_raise", side)))


## Константа LegionCfg по имени, если она есть, иначе fallback (прицел читает так числа, которые
## могли добавить другие ветки).
static func cfg_or(key: StringName, fallback: Variant) -> Variant:
	var consts := (LegionCfg as Script).get_script_constant_map()
	return consts.get(key, fallback)


## Сколько секунд проживёт внештатник при текущем ранге.
func w_duration() -> float:
	return float(LegionCfg.W_DURATION_BY_RANK[rank(SLOT_W)])


## Свежие трупы в radius от at, ближайшие первыми, не больше limit. Равные расстояния — по
## порядку в мире: бой детерминирован.
func fresh_corpses(at: Vector2, radius: float, limit: int) -> Array[Foe]:
	var found: Array = []
	var candidates: Array = []
	candidates.append_array(world.foes)
	candidates.append_array(world._corpses)
	for i in candidates.size():
		var candidate = candidates[i]
		if not candidate is Foe:
			continue
		var f := candidate as Foe
		if not f.is_fresh_corpse() or f.has_meta(&"summoned") or not f.visible:
			continue
		var d := at.distance_squared_to(f.position)
		if d <= radius * radius and not found.any(func(e: Dictionary) -> bool: return e["f"] == f):
			found.append({"f": f, "d": d, "i": i})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["d"] < b["d"] or (a["d"] == b["d"] and a["i"] < b["i"]))
	var out: Array[Foe] = []
	for k in mini(limit, found.size()):
		out.append(found[k]["f"])
	return out


func _nearest_fresh_corpse(at: Vector2, radius: float) -> Foe:
	var one := fresh_corpses(at, radius, 1)
	return one[0] if not one.is_empty() else null


# ── Е — Аврал ──────────────────────────────────────────────────────────────

func _cast_e(at: Vector2) -> bool:
	var live := e_targets(at)
	if live.is_empty():
		return false
	var duration := e_duration()
	last_cast = {"slot": SLOT_E, "at": at, "n": live.size()}
	for u in live:
		u.haste_speed_mult = LegionCfg.E_SPEED_MULT
		u.haste_dmg_mult = LegionCfg.E_DMG_MULT
	_haste_units = live
	_haste_left = duration
	var fx := world.gfx_fx()
	if fx != null:
		fx.impact.rush(at, e_radius(), side)
	else:
		# «Табель сверхурочных» красит Аврал и в экономной графике
		var col: Color = world.items_of(side).look_of(&"e_haste", &"color").get(
			"color", LegionCfg.E_COLOR)
		if col != LegionCfg.E_COLOR:
			world.items_of(side).note_look(&"e_haste", &"color")
		_ring(at, e_radius(), col)
		for u in live:
			_spark(u.position, col)
	Juice.shake(world, LegionCfg.HERO_CAST_SHAKE, LegionCfg.HERO_CAST_SHAKE_DUR + 0.07)
	return true


## Кого ускорит Е по точке — общий для каста и прицела (зажатая E).
func e_targets(at: Vector2) -> Array[Legionnaire]:
	var live: Array[Legionnaire] = []
	for u in world.units_near(at, e_radius()):
		if u.alive and u.side == side:
			live.append(u)
	return live


## Длительность Аврала: база + ранг + перк «Сверхурочные», не выше потолка.
func e_duration() -> float:
	return minf(
		LegionCfg.E_DURATION_BASE + LegionCfg.E_DURATION_RANK_STEP * rank(SLOT_E)
				+ LegionCfg.E_DURATION_PERK_BONUS * world.camp_stat(&"perk_overtime"),
		LegionCfg.E_DURATION_CAP) + world.item_add(&"e_dur", side)


## Радиус Аврала: база × «Табель сверхурочных» (e_radius). Один читатель на каст, прицел и вид.
func e_radius() -> float:
	return LegionCfg.E_RADIUS * world.item_mult(&"e_radius", side)


## Бойцы под Авралом, пока он идёт (слою импакта — для шлейфа). Только чтение.
func hasted() -> Array[Legionnaire]:
	if _haste_left > 0.0:
		return _haste_units
	return []


func _end_haste() -> void:
	for u in _haste_units:
		if is_instance_valid(u):
			u.haste_speed_mult = 1.0
			u.haste_dmg_mult = 1.0
	_haste_units.clear()


# ── FX экономной графики: простая молния Line2D, вспышки/искры текстурами Kenney ──
# (полная графика рисует всё это слоем LegionImpactFx)

## Простая, но читаемая молния: широкое свечение цвета удара и белая сердцевина по одной
## ломаной — игрок видит, куда ударил, без частиц и вспышек.
func q_look() -> Dictionary:
	var own := world.items_of(side)
	var main := own.look_of(&"q_bolt", &"color")
	var fork := own.look_of(&"q_bolt", &"fork")
	if not main.is_empty():
		own.note_look(&"q_bolt", &"color")
	if not fork.is_empty():
		own.note_look(&"q_bolt", &"fork")
	return {"color": main.get("color", LegionCfg.Q_COLOR), "width": main.get("w", 1.0),
		"fork_color": fork.get("color", LegionCfg.Q_COLOR), "branches": fork.get("branches", 0)}


func _bolt_branches(a: Vector2, b: Vector2, look: Dictionary) -> void:
	var normal := (b - a).orthogonal().normalized()
	for i in int(look["branches"]):
		var at := a.lerp(b, float(i + 1) / float(int(look["branches"]) + 1))
		var tip := at + (b - a) * 0.15 + normal * (22.0 if i % 2 == 0 else -22.0)
		_bolt(at, tip, look["fork_color"], 0.55)


func _bolt(a: Vector2, b: Vector2, color: Color, width := 1.0) -> void:
	var n := 8
	var pts := PackedVector2Array()
	var normal := (b - a).orthogonal().normalized()
	var jag := minf(a.distance_to(b) * 0.08, 9.0)
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		if i > 0 and i < n:
			p += normal * _vis_rng.randf_range(-jag, jag)
		pts.append(p)
	for layer in 2:
		var core := layer == 1
		var line := Line2D.new()
		line.points = pts
		line.width = (2.5 if core else 8.0) * width
		line.default_color = Color.WHITE if core else Color(color, 0.55)
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.z_index = 60
		_fx_layer.add_child(line)
		var t := _fx_layer.create_tween()
		t.tween_interval(0.08)
		t.tween_property(line, "modulate:a", 0.0, 0.16)
		t.tween_callback(line.queue_free)


func _spark(at: Vector2, color: Color) -> void:
	var s := Sprite2D.new()
	s.texture = LegionCfg.HERO_SPARK_TEX
	s.position = at
	s.modulate = color
	s.scale = Vector2.ONE * (24.0 / 512.0)
	s.z_index = 60
	_fx_layer.add_child(s)
	var t := _fx_layer.create_tween()
	t.set_parallel(true)
	t.tween_property(s, "scale", Vector2.ONE * (60.0 / 512.0), 0.25)
	t.tween_property(s, "modulate:a", 0.0, 0.25)
	t.set_parallel(false)
	t.tween_callback(s.queue_free)


func _ring(at: Vector2, radius: float, color: Color) -> void:
	var s := Sprite2D.new()
	s.texture = LegionCfg.HERO_RING_TEX
	s.position = at
	s.modulate = color
	s.modulate.a = 0.55
	s.scale = Vector2.ONE * (radius * 2.0 / 512.0)
	s.z_index = 55
	_fx_layer.add_child(s)
	var t := _fx_layer.create_tween()
	t.tween_property(s, "modulate:a", 0.0, 0.5)
	t.tween_callback(s.queue_free)


## Внештатник (Дубль-вэ): поднятый враг, зелёная тонировка и бейдж (значок в _draw). Стоит на
## точке подъёма и бьёт врагов в радиусе (упрощение старого Ally, DEBT.md: неуязвим — иначе
## бой видов, которые его атакуют, не завязан ни на что в текущем мире). Не участвует в
## world.foes/world.units — душ, опыта и штата не касается.
class _Vassal:
	extends Node2D

	const TINT := Color(0.55, 1.25, 0.7)

	var side := 0
	var damage := 4.0
	var life := 20.0
	var raised_type := ""
	var _view: CharView
	var _attack_cd := 0.0
	var _target: Foe = null

	func setup(type_id: String, at: Vector2, dmg: float, duration: float) -> void:
		position = at
		damage = dmg
		life = duration
		raised_type = type_id
		var def: Dictionary = LegionCfg.FOES[type_id]
		var body_h := float(def.get("radius", 8.0)) * 6.0
		_view = CharView.new()
		add_child(_view)
		_view.setup(String(def.get("char", type_id)), body_h)
		_view.set_tint(TINT)

	func retint(c: Color) -> void:
		_view.set_tint(c)

	## true, пока внештатник ещё живёт (мир зовёт каждый кадр).
	func tick(dt: float, world: LegionWorld) -> bool:
		life -= dt
		if life <= 0.0:
			return false
		_view.modulate.a = clampf(life / 2.0, 0.0, 1.0)
		_attack_cd = maxf(0.0, _attack_cd - dt)
		if _target == null or not _target.alive \
				or position.distance_squared_to(_target.position) > LegionCfg.W_RADIUS * LegionCfg.W_RADIUS:
			_target = null
			for f in world.foes_near(position, LegionCfg.W_RADIUS):
				_target = f
				break
		if _target != null and _attack_cd <= 0.0:
			_attack_cd = LegionCfg.ALLY_ATTACK_CD
			_view.play_once(&"attack")
			_target.last_hit_side = side
			_target.take_damage(damage, position)
		return true
