class_name SnapUnits
extends RefCounted
##
## К3 снимка (NetSnap): бойцы (world.units), враги (world.foes), трупы (world._corpses),
## снаряды (LegionProjectiles), память урона world._damage_hp, общие залпы натиска. Интерфейс
## куска — докстринг SnapWorld.
##
## Порядок массивов — часть состояния (обход в _step, цепочки сетки, «кто первый»): build
## воссоздаёт units/foes/_corpses в порядке снимка, поэтому ключи u:/f:/c: реестра указывают на
## те же логические объекты. Загрузка на месте переиспользует узел с тем же номером, если он того
## же вида (класс, вид/тип, сторона, элитность, жив) — у клиента не пересоздаются виды, а ссылки
## других кусков на этот узел остаются верными; прочие узлы снимаются (queue_free), недостающие
## создаются без побочных эффектов (без unit_spawned, stats.spawned и расхода world.rng).
##
## Залп натиска (_volley) — один словарь у всех бойцов выпуска, внутри него group — словарь жеста,
## общий с другими залпами и «Сверхурочными» (К2): оба — через reg.share.
## Место строя (post) — словарь из contract.posts: хранится номером в posts своего договора.
##
## Каждое поле класса — либо в *_PROPS/*_REFS (в снимке), либо в *_SKIP с причиной (тест сверяет).
##

const READY := true

const UNIT_PROPS: Array[String] = [
	"position", "side", "last_hit_side", "state", "kind", "hp", "max_hp", "no_return_id",
	"alive", "item_slow_t", "haste_speed_mult", "haste_dmg_mult", "elite", "elite_dmg_mult",
	"rite_dmg_mult", "idle_time", "idle_reason", "projectile_sealed", "_aura_t", "_aura_near",
	"_seal_t", "_seal_cd", "_path", "_path_i", "_atk_cd", "_bonus_t", "_charge_t", "_charge_dir",
	"_charge_run", "_charge_cap", "_bonus_mult", "_first_strike", "_dead_t", "_stun_t",
	"_rally_t", "_scan_skip", "_guard_skip",
]
## spec — обычно общий LegionCfg.UNIT_KINDS[kind]; «бодрый выход» (building.gd _spawn_into)
## подменяет его копией со скоростью ×BRISK_EXIT_MULT — тогда копия идёт в снимок.
const UNIT_REFS: Array[String] = ["field", "home", "post", "contract", "_volley", "spec"]
const UNIT_SKIP: Array[String] = [
	"world", "view",
	"idx",                  # пишет grid.rebuild
	"_moving", "_facing",   # только вид (походка, разворот спрайта)
]

const FOE_PROPS: Array[String] = [
	"position",
	"visible",   # игровое: невидимый (прорвался к Котлу, vanish) не идёт в трупы (_cleanup)
	"type_id", "origin", "state", "hp", "max_hp", "speed", "radius", "ghost", "alive",
	"goal_side", "last_hit_side", "stamp_pos", "stamp_t", "holding", "ram_pos", "ram_t",
	"seal_slow_t", "law_seg", "law_pos", "law_read_t", "stun_t", "elite", "carrier",
	"died_stunned", "_ram_run", "_ram_start", "_path", "_wp", "_detour_at", "_atk_cd",
	"_skill_cd", "_roar_cd", "_wake_t", "_dead_t", "_dir", "_law_scan", "_law_off_road",
]
const FOE_REFS: Array[String] = ["law_c", "_target"]
const FOE_SKIP: Array[String] = [
	"world", "view",
	"def",   # LegionCfg.FOES[type_id], не меняется
	"idx",   # пишет grid.rebuild
]
const SHOTS_REFS: Array[String] = ["shots"]


## Сверка полей классов (тест): [скрипт, учтённые имена].
static func coverage() -> Array:
	return [
		[Legionnaire, UNIT_PROPS + UNIT_REFS + UNIT_SKIP],
		[Foe, FOE_PROPS + FOE_REFS + FOE_SKIP],
		[LegionProjectiles, SHOTS_REFS],
	]


static func save(w: LegionWorld, reg: NetSnap.Reg) -> Dictionary:
	var units := []
	for u in w.units:
		units.append(_save_unit(w, u, reg))
	var foes := []
	for f in w.foes:
		foes.append(_save_foe(f, reg))
	var corpses := []
	for c in w._corpses:
		if c is Legionnaire:
			corpses.append(_save_unit(w, c as Legionnaire, reg))
		else:
			corpses.append(_save_foe(c as Foe, reg))
	# ключи — живые враги (_cleanup снимает павших); неадресуемый ключ стёр бы _track_damage
	var dmg := []
	for f: Variant in w._damage_hp:
		var key := reg.ref_of(f as Object)
		if key != "":
			dmg.append([key, w._damage_hp[f]])
	return {
		"units": units, "foes": foes, "corpses": corpses, "damage_hp": dmg,
		"shots": reg.enc(w.projectiles.shots),
	}


static func build(w: LegionWorld, data: Dictionary, _reg: NetSnap.Reg) -> void:
	if data.is_empty():
		return
	var used := {}
	var old_u: Array = w.units.duplicate()
	var old_f: Array = w.foes.duplicate()
	var old_c: Array = w._corpses.duplicate()
	var units: Array[Legionnaire] = []
	var saved_u: Array = data["units"]
	for i in saved_u.size():
		units.append(_take_unit(w, old_u, i, saved_u[i], used))
	var foes: Array[Foe] = []
	var saved_f: Array = data["foes"]
	for i in saved_f.size():
		foes.append(_take_foe(w, old_f, i, saved_f[i], used))
	var corpses: Array[Node2D] = []
	var saved_c: Array = data["corpses"]
	for i in saved_c.size():
		var d: Dictionary = saved_c[i]
		if d.get("cls") == "u":
			corpses.append(_take_unit(w, old_c, i, d, used))
		else:
			corpses.append(_take_foe(w, old_c, i, d, used))
	for o: Variant in old_u + old_f + old_c:
		var n := o as Node
		if is_instance_valid(n) and not used.has(n.get_instance_id()):
			n.queue_free()
	# assign — тот же объект массива: его могут держать другие системы
	w.units.assign(units)
	w.foes.assign(foes)
	w._corpses.assign(corpses)
	w._damage_hp.clear()
	w.projectiles.shots.clear()


static func link(w: LegionWorld, data: Dictionary, reg: NetSnap.Reg) -> void:
	if data.is_empty():
		return
	var saved_u: Array = data["units"]
	for i in mini(saved_u.size(), w.units.size()):
		_link_unit(w.units[i], saved_u[i], reg)
	var saved_f: Array = data["foes"]
	for i in mini(saved_f.size(), w.foes.size()):
		_link_foe(w.foes[i], saved_f[i], reg)
	var saved_c: Array = data["corpses"]
	for i in mini(saved_c.size(), w._corpses.size()):
		var c := w._corpses[i]
		if c is Legionnaire:
			_link_unit(c as Legionnaire, saved_c[i], reg)
		else:
			_link_foe(c as Foe, saved_c[i], reg)
	w._damage_hp.clear()
	for pair: Array in data["damage_hp"]:
		var f := reg.resolve(String(pair[0]))
		if f != null:
			w._damage_hp[f] = pair[1]
	w.projectiles.shots.assign(reg.dec(data["shots"]))


static func finish(_w: LegionWorld, _data: Dictionary, _reg: NetSnap.Reg) -> void:
	pass


# ── Бойцы ───────────────────────────────────────────────────────────────────

static func _save_unit(w: LegionWorld, u: Legionnaire, reg: NetSnap.Reg) -> Dictionary:
	var d := {"cls": "u"}
	d.merge(NetSnap.props_save(u, UNIT_PROPS))
	var base: Dictionary = LegionCfg.UNIT_KINDS.get(u.kind, {})
	d["spec"] = {} if is_same(u.spec, base) else u.spec.duplicate(true)
	d["field"] = reg.ref_of(u.field)
	d["home"] = reg.ref_of(u.home)
	d["contract"] = reg.ref_of(u.contract)
	d["post"] = _post_ref(w, u, reg)
	var vi := -1
	if not u._volley.is_empty():
		if u._volley.get("group") is Dictionary:
			reg.share(u._volley["group"])
		vi = reg.share(u._volley)
	d["_volley"] = vi
	return d


## Место строя: [ключ договора, номер в posts]; [] — места нет; {"data": …} — место выпало из
## своего договора (договор снят), тогда — копией.
static func _post_ref(w: LegionWorld, u: Legionnaire, reg: NetSnap.Reg) -> Variant:
	if u.post.is_empty():
		return []
	var order: Array[Contract] = []
	if u.contract != null:
		order.append(u.contract)
	order.append_array(w.all_contracts())
	for c in order:
		for j in c.posts.size():
			if is_same(c.posts[j], u.post):
				var key := reg.ref_of(c)
				if key != "":
					return [key, j]
	return {"data": reg.enc(u.post)}


static func _take_unit(w: LegionWorld, pool: Array, i: int, d: Dictionary,
		used: Dictionary) -> Legionnaire:
	var u: Legionnaire = null
	if i < pool.size() and pool[i] is Legionnaire and is_instance_valid(pool[i]) \
			and not used.has((pool[i] as Object).get_instance_id()):
		var old := pool[i] as Legionnaire
		if old.kind == d["kind"] and old.side == int(d["side"]) and old.elite == bool(d["elite"]) \
				and old.alive == bool(d["alive"]):
			u = old
	if u == null:
		u = _new_unit(w, d)
	used[u.get_instance_id()] = true
	var plain := {}
	for k in UNIT_PROPS:
		plain[k] = d[k]
	NetSnap.props_load(u, plain)
	var spec: Dictionary = d["spec"]
	u.spec = LegionCfg.UNIT_KINDS[u.kind] if spec.is_empty() else spec.duplicate(true)
	return u


## Боец без побочных эффектов spawn_unit: тот же вид, сторона и окраска, но без сигнала,
## счёта stats.spawned и звука.
static func _new_unit(w: LegionWorld, d: Dictionary) -> Legionnaire:
	var u := Legionnaire.new()
	u.setup(w, d["position"], d["kind"])
	var side := int(d["side"])
	u.side = side
	u.field = w.sides[side].contracts if side < w.sides.size() else w.contracts
	if w.no_view:
		LegionWorld._mute_view(u.view)
	if w.pvp:
		PvpSideLook.apply(u.view, side)
	if bool(d["elite"]):
		u.make_elite(1.0, float(d["elite_dmg_mult"]))   # корона и масштаб вида; числа — снимок
	w.entities.add_child(u)
	return u


static func _link_unit(u: Legionnaire, d: Dictionary, reg: NetSnap.Reg) -> void:
	u.field = reg.resolve(String(d["field"])) as ContractField
	u.home = reg.resolve(String(d["home"]))
	u.contract = reg.resolve(String(d["contract"])) as Contract
	var p: Variant = d["post"]
	u.post = {}
	if p is Array and (p as Array).size() == 2:
		var c := reg.resolve(String(p[0])) as Contract
		if c != null and int(p[1]) < c.posts.size():
			u.post = c.posts[int(p[1])]
		else:
			reg.misses.append("post:%s/%d" % [p[0], p[1]])
	elif p is Dictionary:
		u.post = reg.dec((p as Dictionary)["data"])
	var vi := int(d["_volley"])
	u._volley = reg.shared(vi) if vi >= 0 else {}


# ── Враги ───────────────────────────────────────────────────────────────────

static func _save_foe(f: Foe, reg: NetSnap.Reg) -> Dictionary:
	var d := {"cls": "f"}
	d.merge(NetSnap.props_save(f, FOE_PROPS))
	d["law_c"] = reg.ref_of(f.law_c)
	d["_target"] = reg.ref_of(f._target)
	# все меты: summoned, pvp_carrier_serial, breach_leaked, pvp_item_death_processed и метки
	# сложности LegionChallenge (щит «Штатного»)
	var meta := {}
	for m in f.get_meta_list():
		meta[m] = f.get_meta(m)
	d["meta"] = meta
	return d


static func _take_foe(w: LegionWorld, pool: Array, i: int, d: Dictionary, used: Dictionary) -> Foe:
	var f: Foe = null
	if i < pool.size() and pool[i] is Foe and is_instance_valid(pool[i]) \
			and not used.has((pool[i] as Object).get_instance_id()):
		var old := pool[i] as Foe
		if old.type_id == d["type_id"] and old.elite == bool(d["elite"]) \
				and old.carrier == bool(d["carrier"]) and old.alive == bool(d["alive"]):
			f = old
	if f == null:
		f = _new_foe(w, d)
	used[f.get_instance_id()] = true
	var plain := {}
	for k in FOE_PROPS:
		plain[k] = d[k]
	NetSnap.props_load(f, plain)
	for m in f.get_meta_list():
		f.remove_meta(m)
	var meta: Dictionary = d["meta"]
	for m: StringName in meta:
		f.set_meta(m, meta[m])
	return f


## Враг без побочных эффектов _add_foe (без записи в _damage_hp — её ведёт link).
static func _new_foe(w: LegionWorld, d: Dictionary) -> Foe:
	var f := Foe.new()
	f.setup(w, String(d["type_id"]), PackedVector2Array(), {"pos": d["position"]})
	if w.no_view:
		LegionWorld._mute_view(f.view)
	if bool(d["elite"]):
		f.make_elite(bool(d["carrier"]))   # ореол и корона; числа — из снимка
	w.entities.add_child(f)
	return f


static func _link_foe(f: Foe, d: Dictionary, reg: NetSnap.Reg) -> void:
	f.law_c = reg.resolve(String(d["law_c"])) as Contract
	f._target = reg.resolve(String(d["_target"])) as Legionnaire
