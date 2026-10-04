# gdlint: disable=max-public-methods
class_name LegionItemEffects
extends RefCounted
##
## Особые обработчики артефактов и синергий. Реестр (item_db.gd) подключает их по имени:
## запись {"on": &"событие", "fx": &"имя", "params": {...}} → fx_<имя>(n, p, args), где n — число
## копий (v2: артефакт уникален, 1), p — params записи, args — аргументы события
## (LegionItems.EVENTS). Новый особый артефакт = запись в реестре + одна функция fx_<имя> здесь.
##
## Механика — только world.rng и часы мира (items.after, опасные зоны items.hazards). Вид —
## сигнал items.fx_event (вспышки — LegionItemFx) и постоянный вид цели (LegionItemLook).
##

## Шаг урона и оглушения опасных зон, секунды мира.
const HAZARD_TICK := 0.25
## Взрыв печати — чуть позже смерти: цепь рвётся по очереди, а не в одном кадре.
const BLAST_DELAY := 0.12
## Огонь чуть желтее угрозы (vfx-clarity 29.09): красный огонь у своих читался «бьют нас».
const COLOR_FIRE := Color(1.0, 0.56, 0.1)
## Оглушение — один цвет на всю игру (CfgFx.C_STUN): и Ку, и печати артефактов.
const COLOR_STUN := CfgFx.C_STUN
const COLOR_BOLT := Color(0.7, 0.85, 1.0)
const COLOR_SOUL := Color(0.45, 0.75, 1.0)
const COLOR_MANA := Color(0.62, 0.43, 1.0)

var world: LegionWorld = null
var items: LegionItems = null


func setup(w: LegionWorld, it: LegionItems) -> void:
	world = w
	items = it


## Нейтральные враги и чужая армия; собственную армию артефакт не поражает.
func enemies(at: Vector2, radius: float) -> Array:
	var out: Array = []
	out.assign(world.foes_near(at, radius))
	if world.pvp:
		for u in world.units_near(at, radius):
			if u.alive and u.side != items.owner_side:
				out.append(u)
	return out


func damage(target: Variant, amount: float, from: Vector2) -> void:
	if not target.alive:
		return
	target.last_hit_side = items.owner_side
	target.take_damage(amount, from)


# ── Общие действия ──────────────────────────────────────────────────────────

## Урон по кругу (и оглушение выживших); каждый враг — один раз.
func blast(at: Vector2, r: float, dmg: float, stun: float = 0.0,
		color: Color = COLOR_FIRE) -> int:
	var hit := 0
	for f: Variant in enemies(at, r):
		damage(f, dmg, at)
		if stun > 0.0:
			f.stun(stun)
		hit += 1
	items.fx_event.emit(&"blast", {"pos": at, "r": r, "color": color})
	return hit


func stun_area(at: Vector2, r: float, t: float, color: Color = COLOR_STUN) -> int:
	var hit := 0
	for f: Variant in enemies(at, r):
		f.stun(t)
		hit += 1
	items.fx_event.emit(&"stun", {"pos": at, "r": r, "color": color})
	return hit


## Цвет вида артефакта (item_db look): взрыв своей печати — её цветом, не красным угрозы.
static func look_color(id: StringName) -> Color:
	return LegionItemDb.look(id).get("color", COLOR_FIRE)


## Артефакт сработал на поле — вид связывает событие с его значком в полоске (item_bar).
func used(id: StringName, at: Vector2) -> void:
	items.fx_event.emit(&"used", {"id": id, "pos": at})


## f — нейтральный враг (Foe) или боец чужой армии (PvP).
func bolt(from: Vector2, f: Variant, dmg: float, color: Color = COLOR_BOLT) -> void:
	items.fx_event.emit(&"bolt", {"from": from, "to": f.position, "color": color})
	damage(f, dmg, from)


## Ближайший живой враг в радиусе, кроме skip.
func nearest(at: Vector2, r: float, skip: Array = []) -> Variant:
	var best: Variant = null
	var bd := r * r
	for f: Variant in enemies(at, r):
		if not f.alive or skip.has(f):
			continue
		var d: float = at.distance_squared_to(f.position)
		if d <= bd:
			bd = d
			best = f
	return best


## Шаг опасной зоны (LegionItems.tick). Призрачная линия — полоса вдоль отрезка a–b.
func hazard_pulse(h: Dictionary) -> void:
	var hit: Array = []
	if h["kind"] == &"ghost":
		var a: Vector2 = h["a"]
		var b: Vector2 = h["b"]
		var mid := (a + b) * 0.5
		for f: Variant in enemies(mid, a.distance_to(b) * 0.5 + float(h["r"])):
			if Geometry2D.get_closest_point_to_segment(f.position, a, b).distance_to(f.position) \
					<= float(h["r"]):
				hit.append(f)
	else:
		hit = enemies(h["pos"], float(h["r"]))
	var from: Vector2 = h.get("pos", Vector2.ZERO)
	for f: Variant in hit:
		if float(h.get("dps", 0.0)) > 0.0:
			damage(f, float(h["dps"]) * HAZARD_TICK, from)
		if float(h.get("stun", 0.0)) > 0.0:
			f.stun(float(h["stun"]))
		if float(h.get("slow", 0.0)) > 0.0:
			if f is Foe:
				f.seal_slow_t = maxf(f.seal_slow_t, float(h["slow"]))
			else:
				f.item_slow_t = maxf(f.item_slow_t, float(h["slow"]))


# ── Отложенные эффекты (LegionItems.after) ──────────────────────────────────

## Таймер истёк: эффект по имени. Новый отложенный эффект = ветка здесь + after(t, имя, args)
## в обработчике; args — те, что обработчик посчитал в момент постановки.
func run_timer(fx: StringName, args: Array) -> void:
	match fx:
		&"stamp_blast":
			_stamp_blast(args[0], float(args[1]), float(args[2]), float(args[3]))
		_:
			push_error("LegionItemEffects: неизвестный отложенный эффект '%s'" % fx)


## «Взрывная печать» (fx_unit_blast): взрыв на месте павшего бойца; dmg уже с blast_mult.
func _stamp_blast(at: Vector2, r: float, dmg: float, stun: float) -> void:
	world.stats["item_blasts"] = int(world.stats.get("item_blasts", 0)) + 1
	blast(at, r, dmg, stun, look_color(&"exploding_stamp"))
	used(&"exploding_stamp", at)


# ── Обработчики (fx_<имя>) ──────────────────────────────────────────────────

## «Золотое перо»: точный срыв перезаряжает Ку.
func fx_golden_pen(_n: int, _p: Dictionary, args: Array) -> void:
	if bool(args[1]) and world.hero_of(items.owner_side) != null:
		world.hero_of(items.owner_side).reset_cd(LegionHero.SLOT_Q)
		items.fx_event.emit(&"text", {"pos": args[0], "text": "Ку готова!",
			"color": Color(1.0, 0.84, 0.32)})


## «Громоотвод»: молния Ку убила цель — прыгает к ближайшему, до hops раз подряд по убитым.
func fx_lightning_rod(_n: int, p: Dictionary, args: Array) -> void:
	var f: Variant = args[0]
	if f.alive:
		return
	var from: Vector2 = f.position
	var dmg := float(args[1]) * float(p["frac"])
	var skip: Array = [f]
	var col: Color = items.look_of(&"q_bolt", &"fork").get("color", COLOR_BOLT)
	for hop in int(p["hops"]):
		var t: Variant = nearest(from, float(p["r"]), skip)
		if t == null:
			return
		bolt(from, t, dmg, col)
		world.stats["item_bolt_hops"] = int(world.stats.get("item_bolt_hops", 0)) + 1
		if t.alive:
			return
		skip.append(t)
		from = t.position


## «Взрывная печать»: свой боец, павший в бою, взрывается печатью (проданный — нет).
func fx_unit_blast(_n: int, p: Dictionary, args: Array) -> void:
	var u: Legionnaire = args[0]
	# печать перезаряжается (cd): своих гибнет ~200 за бой, и взрыв на каждого решал бой сам
	# (серия fork 27.09: 6/6 побед даже при уроне 9) — печати на бойцах тускнеют, пока она не готова
	if u.home == null or world.now < float(items.state.get(&"stamp_ready", -INF)):
		return
	items.state[&"stamp_ready"] = world.now + float(p["cd"])
	var at := u.position
	var mult := 1.0 + items.value(&"blast_mult")
	items.after(BLAST_DELAY, &"stamp_blast",
		[at, float(p["r"]), float(p["dmg"]) * mult, float(p["stun"])])


## «Сургуч с огоньком»: бегущий натиском боец роняет горящие пятна через каждые step px.
func fx_charge_trail(_n: int, p: Dictionary, _args: Array) -> void:
	var last: Dictionary = items.state.get(&"trail", {})
	var seen := {}
	for u in world.units:
		if u.side != items.owner_side or not u.alive or u.state != Legionnaire.State.CHARGE:
			continue
		var id := u.get_instance_id()
		seen[id] = true
		if not last.has(id):
			last[id] = u.position
			continue
		if (last[id] as Vector2).distance_to(u.position) < float(p["step"]):
			continue
		last[id] = u.position
		if items.hazard_count(&"trail") >= CfgItems.TRAIL_HAZARD_CAP:
			continue
		items.add_hazard({"pos": u.position, "kind": &"trail", "r": float(p["r"]),
			"t": float(p["t"]), "dps": float(p["dps"])})
		world.stats["item_trail"] = int(world.stats.get("item_trail", 0)) + 1
	for id: int in last.keys():
		if not seen.has(id):
			last.erase(id)
	items.state[&"trail"] = last


## «Срочный договор»: внештатник Дубль-вэ в конце срока взрывается.
func fx_vassal_blast(_n: int, p: Dictionary, args: Array) -> void:
	var mult := 1.0 + items.value(&"blast_mult")
	blast(args[0], float(p["r"]), float(p["dmg"]) * mult, 0.0, Color(1.0, 0.8, 0.3))


## «Пролонгация»: участок, растаявший сам, ещё t секунд держит призрачную линию: враг на ней
## вязнет и получает урон («Горячая линия» — втрое жарче).
func fx_ghost_line(_n: int, p: Dictionary, args: Array) -> void:
	var c: Contract = args[0]
	var seg: int = args[1]
	if c.release_causes.get(seg, &"") != &"melt" or items.hazard_count(&"ghost") >= CfgItems.GHOST_CAP:
		return
	var poly := c.seg_polys[seg] if seg < c.seg_polys.size() else PackedVector2Array()
	if poly.size() < 2:
		return
	var burn := 1.0 + items.value(&"ghost_burn")
	items.add_hazard({"pos": c.seg_center(seg), "kind": &"ghost", "a": poly[0],
		"b": poly[poly.size() - 1], "r": CfgItems.GHOST_HALF_W, "t": float(p["t"]),
		"dps": float(p["dps"]) * burn, "slow": float(p["slow"]), "hot": burn > 1.0})
	world.stats["item_ghosts"] = int(world.stats.get("item_ghosts", 0)) + 1
	used(&"prolongation", c.seg_center(seg))


## «Рупор завхоза»: «Сбор» оглушает врагов в круге.
func fx_roll_call(_n: int, p: Dictionary, args: Array) -> void:
	# круг оглушения — цветом оглушения; «Рупор» красит само кольцо «Сбора» (look rally)
	stun_area(args[0], float(p["r"]), float(p["stun"]))


## «Душеприказчик»: душа убитого летит в Котёл и лечит его.
func fx_soul_heal(n: int, p: Dictionary, args: Array) -> void:
	var f: Variant = args[0]
	if f.has_meta(&"summoned"):
		return
	var heal := float(p["heal"]) * n * LegionChallenge.heads(f)   # за прежние головы (D-0927-49)
	var own := world.sides[items.owner_side]
	own.cauldron_hp = minf(own.cauldron_max, own.cauldron_hp + heal)
	world.stats["item_heal"] = float(world.stats.get("item_heal", 0.0)) + heal
	items.fx_event.emit(&"heal", {"from": args[1],
		"to": world.cauldron_view_of(items.owner_side)})


## «Печать на Котле»: удар по Котлу — взрыв печати вокруг (урон и оглушение), раз в cd секунд.
func fx_cauldron_ward(_n: int, p: Dictionary, _args: Array) -> void:
	if world.now < float(items.state.get(&"ward_ready", -INF)):
		return
	items.state[&"ward_ready"] = world.now + float(p["cd"])
	var at := world.cauldron_of(items.owner_side)   # свой Котёл (одиночка — cauldron_pos)
	blast(at, float(p["r"]), float(p["dmg"]), float(p["stun"]), look_color(&"cauldron_ward"))
	used(&"cauldron_ward", at)
	world.stats["item_wards"] = int(world.stats.get("item_wards", 0)) + 1


## Синергия «Громовая канцелярия»: каждый удар молнии Ку оставляет оглушающую печать.
func fx_stun_seal(_n: int, p: Dictionary, args: Array) -> void:
	var f: Variant = args[0]
	items.add_hazard({
		"pos": f.position, "kind": &"stun", "r": float(p["r"]), "t": float(p["t"]),
		"stun": float(p["stun"]),
	})
