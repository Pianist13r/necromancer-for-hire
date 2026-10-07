class_name SnapStaff
extends RefCounted
##
## К4 снимка (NetSnap): штат сторон (LegionStaff), постройки (world.buildings), склепы
## (world.crypts), герои сторон (LegionHero) и их внештатники Дубль-вэ. Интерфейс — SnapWorld.
##
## Порядок world.buildings — часть состояния (staff.tick делит бюджет армии по порядку):
## build собирает массив заново в порядке снимка. Котлы и постройки склепов уже создал start_map
## (К1) — они переиспользуются; участковая постройка мира «на месте» переиспользуется при
## совпадении plot_id её стороны, недостающая создаётся staff._make (фабрика игры, но без платы
## душами — не build()); лишние участковые уходят тихо: их бойцов перезапишет К3, а продажа
## списала бы души. Бойцов создаёт К3 — здесь только ключи «u:<i>» через реестр.
##
## «Бодрый выход»: боец из _brisk постройки ходит с копией spec (скорость ×BRISK_EXIT_MULT,
## building._spawn_into), пока идёт его таймер. Саму копию spec хранит и восстанавливает К3
## (UNIT_REFS "spec"); здесь — только список бойцов и их таймеры.
##
## Освобождённый боец в slot_unit/_brisk/_haste_units (пал, а таймер «бодрого выхода»/Аврала
## ещё идёт) не адресуем — снимок хранит null: освобождённый и null одинаково молча убираются
## своим тиком. last_cast героя, artwork и nearby_units склепа — вид/пересчёт, не сохраняются.
##

const READY := true

## Поля классов куска (тест полноты): в снимке или пропуск с причиной.
const STAFF_SAVED: Array[String] = ["plots", "_soul_frac", "_kill_frac",   # plots — только building
	"_cap_mult", "_respawn_mult", "_unlocked"]
const STAFF_SKIP: Array[String] = [
	"world", "side", "cauldron", "stat_fn",          # структура: setup в start_map
]
const BUILDING_SAVED: Array[String] = [
	"side", "kind", "source", "level", "cap", "respawn_t", "entry", "entry_ring", "frozen",
	"invested", "plot_id", "brisk_exit", "slot_unit", "slot_t", "slot_fresh", "_fill_cd",
	"_brisk", "_brisk_t",
]
const BUILDING_SKIP: Array[String] = [
	"world",                                               # структура
	"artwork_variant", "_drawn_alive", "_artwork_view",   # вид
]
const CRYPT_SAVED: Array[String] = ["allegiance", "capturing", "progress", "contested", "building"]
const CRYPT_SKIP: Array[String] = [
	"_tone",   # вид: множитель спрайта из world.apply_harmony; gameplay его не читает
	"world", "_ring", "_tex",   # структура и вид
	"nearby_units",             # пересчёт: tick считает его первым делом и сам же читает
]
const HERO_SAVED: Array[String] = ["_cd", "_vassals", "_haste_left", "_haste_units"]
const HERO_SKIP: Array[String] = [
	"world", "side", "necro_view", "_fx_layer",   # структура и вид
	"_vis_rng",    # ГСЧ дрожания молнии — только вид
	# итог каста: пишется в cast до сигнала hero_cast и читается им же (артефакты), между
	# шагами — только подписи прицела
	"last_cast",
]
const VASSAL_SAVED: Array[String] = ["side", "damage", "life", "raised_type", "_attack_cd",
	"_target"]
const VASSAL_SKIP: Array[String] = ["_view"]   # вид (строит setup по raised_type)


## Сверка полей классов (тест): [скрипт, учтённые имена].
static func coverage() -> Array:
	return [
		[LegionStaff, STAFF_SAVED + STAFF_SKIP],
		[LegionBuilding, BUILDING_SAVED + BUILDING_SKIP],
		[LegionCrypt, CRYPT_SAVED + CRYPT_SKIP],
		[LegionHero, HERO_SAVED + HERO_SKIP],
		[LegionHero._Vassal, VASSAL_SAVED + VASSAL_SKIP],
	]


static func save(w: LegionWorld, reg: NetSnap.Reg) -> Dictionary:
	var staffs := []
	for s in w.sides:
		var st := s.staff
		var plots := []
		for p: Dictionary in st.plots:
			plots.append(_ref(reg, p["building"]))
		staffs.append({"soul_frac": st._soul_frac, "kill_frac": st._kill_frac, "plots": plots,
			"cap_mult": st._cap_mult.duplicate(), "respawn_mult": st._respawn_mult.duplicate(),
			"unlocked": st._unlocked.duplicate()})
	var buildings := []
	for b: LegionBuilding in w.buildings:
		buildings.append({
			"side": b.side, "kind": b.kind, "source": b.source, "level": b.level,
			"cap": b.cap, "respawn_t": b.respawn_t,
			"position": b.position, "entry": b.entry, "entry_ring": b.entry_ring,
			"frozen": b.frozen, "invested": b.invested, "plot_id": b.plot_id,
			"brisk_exit": b.brisk_exit,
			"slot_t": b.slot_t.duplicate(), "slot_fresh": b.slot_fresh.duplicate(),
			"fill_cd": b._fill_cd, "brisk_t": b._brisk_t.duplicate(),
			"slots": _refs(reg, b.slot_unit), "brisk": _refs(reg, b._brisk),
		})
	var crypts := []
	for c: LegionCrypt in w.crypts:
		crypts.append({
			"allegiance": c.allegiance, "capturing": c.capturing, "progress": c.progress,
			"contested": c.contested, "position": c.position, "building": _ref(reg, c.building),
		})
	var heroes := []
	for s in w.sides:
		var h := w.hero_of(s.index)
		var cd: Array = [0.0, 0.0, 0.0]
		var haste: Array = []
		var haste_left := 0.0
		var vassals := []
		if h != null:
			cd = h._cd.duplicate()
			haste_left = h._haste_left
			haste = _refs(reg, h._haste_units)
			for v: LegionHero._Vassal in h._vassals:
				vassals.append({
					"position": v.position, "side": v.side, "damage": v.damage, "life": v.life,
					"raised_type": v.raised_type, "attack_cd": v._attack_cd,
					"target": _ref(reg, v._target),
				})
		heroes.append({"cd": cd, "haste_left": haste_left, "haste": haste, "vassals": vassals})
	return {"staffs": staffs, "buildings": buildings, "crypts": crypts, "heroes": heroes}


static func build(w: LegionWorld, data: Dictionary, reg: NetSnap.Reg) -> void:
	if data.is_empty():
		return   # куска в снимке нет (снимок старой фазы) — мир не трогаем
	var staffs: Array = data.get("staffs", [])
	var crypt_d: Array = data.get("crypts", [])
	var bs: Array = data.get("buildings", [])
	# штат: дробные остатки душ/голов (сами души — в PvpSide, К1). Площадки обнуляются:
	# снимок перелинкует их в link, а висеть на освобождённых постройках опасно
	for i in mini(staffs.size(), w.sides.size()):
		var st := w.sides[i].staff
		var d: Dictionary = staffs[i]
		st._soul_frac = float(d.get("soul_frac", 0.0))
		st._kill_frac = float(d.get("kill_frac", 0.0))
		# поправки кампании (setup читает их из camp_stat): вне кампании нейтральные, но хозяин
		# мира может подменить stat_fn — снимок несёт их как есть
		st._cap_mult = (d.get("cap_mult", st._cap_mult) as Dictionary).duplicate()
		st._respawn_mult = (d.get("respawn_mult", st._respawn_mult) as Dictionary).duplicate()
		st._unlocked = (d.get("unlocked", st._unlocked) as Dictionary).duplicate()
		for p: Dictionary in st.plots:
			p["building"] = null
	# склепы: те же узлы (карту и сид готовит К1), состояние — из снимка
	if not crypt_d.is_empty() and crypt_d.size() != w.crypts.size():
		reg.errors.append("staff: склепов в мире %d, в снимке %d" % [w.crypts.size(), crypt_d.size()])
	for i in mini(crypt_d.size(), w.crypts.size()):
		_apply_crypt(w.crypts[i], crypt_d[i])
	var crypt_bidx := {}   # ключ постройки склепа → индекс склепа в снимке
	for i in crypt_d.size():
		var key: Variant = (crypt_d[i] as Dictionary).get("building", null)
		if key != null:
			crypt_bidx[String(key)] = i
	# существующие постройки мира по категориям: Котёл и склеп переиспользовать (создаёт
	# start_map), участковая — по plot_id её стороны (мир «на месте»)
	var cauldrons := {}
	var crypt_owned := {}
	var by_plot := {}
	for b: LegionBuilding in w.buildings:
		if b.source == LegionBuilding.SOURCE_CAULDRON:
			cauldrons[b.side] = b
		elif b.source == LegionBuilding.SOURCE_CRYPT:
			for j in w.crypts.size():
				if w.crypts[j].building == b:
					crypt_owned[j] = b
		else:
			by_plot["%d,%s" % [b.side, b.plot_id]] = b
	# постройки в порядке снимка; на пустом месте — null (ошибка выше), чтобы ключи b:<i>
	# остальных кусков не поехали
	var out: Array = []
	for i in bs.size():
		var d: Dictionary = bs[i]
		var source := StringName(String(d.get("source", LegionBuilding.SOURCE_PLOT)))
		var side := int(d.get("side", 0))
		var b: LegionBuilding = null
		if source == LegionBuilding.SOURCE_CAULDRON:
			b = cauldrons.get(side) as LegionBuilding
			cauldrons.erase(side)
		elif source == LegionBuilding.SOURCE_CRYPT:
			var ci: int = crypt_bidx.get("b:%d" % i, -1)
			if ci >= 0:
				b = crypt_owned.get(ci) as LegionBuilding
				crypt_owned.erase(ci)
		else:
			var pk := "%d,%s" % [side, String(d.get("plot_id", ""))]
			b = by_plot.get(pk) as LegionBuilding
			by_plot.erase(pk)
			if b == null:
				# недостающая участковая постройка — той же фабрикой, что игра, но без души
				b = w.sides[side].staff._make(
					StringName(String(d.get("kind", LegionCfg.KIND_LABORER))), source,
					d.get("position", Vector2.ZERO), null)
		if b == null:
			reg.errors.append("staff: постройка b:%d (%s стороны %d) не нашлась" % [i, source, side])
			out.append(null)
			continue
		_apply_building(b, d)
		out.append(b)
	# лишние участковые мира: бойцов перезапишет К3, души не трогаем (продажа списывала бы)
	for b: LegionBuilding in by_plot.values():
		w.building_changed.emit(b)
		b.queue_free()
	if not cauldrons.is_empty() or not crypt_owned.is_empty():
		reg.errors.append("staff: у мира остались Котлы/склепы, которых нет в снимке")
	w.buildings.clear()
	for b in out:
		w.buildings.append(b)
	# герои: откаты и внештатники (вид внештатника строится setup'ом из raised_type); боец
	# под Авралом — ссылка в link, множители на бойце восстановит К3
	var hs: Array = data.get("heroes", [])
	for i in mini(hs.size(), w.sides.size()):
		var h := w.hero_of(i)
		if h == null:
			continue
		var d: Dictionary = hs[i]
		var cd: Array[float] = []
		for v in (d.get("cd", []) as Array):
			cd.append(float(v))
		h._cd = cd
		h._haste_left = float(d.get("haste_left", 0.0))
		h._haste_units.clear()
		for v in h._vassals:
			if is_instance_valid(v):
				v.queue_free()
		h._vassals.clear()
		for vd: Dictionary in d.get("vassals", []):
			var v := LegionHero._Vassal.new()
			v.side = int(vd.get("side", i))
			v.setup(String(vd.get("raised_type", "")), vd.get("position", Vector2.ZERO),
				float(vd.get("damage", 0.0)), float(vd.get("life", 0.0)))
			w.entities.add_child(v)
			v._attack_cd = float(vd.get("attack_cd", 0.0))
			h._vassals.append(v)


static func link(w: LegionWorld, data: Dictionary, reg: NetSnap.Reg) -> void:
	if data.is_empty():
		return
	var staffs: Array = data.get("staffs", [])
	for i in mini(staffs.size(), w.sides.size()):
		var st := w.sides[i].staff
		var plots: Array = (staffs[i] as Dictionary).get("plots", [])
		if plots.size() != st.plots.size():
			reg.errors.append("staff: площадок стороны %d в мире %d, в снимке %d"
				% [i, st.plots.size(), plots.size()])
		for j in mini(plots.size(), st.plots.size()):
			st.plots[j]["building"] = _resolve(reg, plots[j]) as LegionBuilding
	# постройки уже стоят в порядке снимка — читаем прямо из world.buildings
	var bs: Array = data.get("buildings", [])
	for i in mini(bs.size(), w.buildings.size()):
		var b: LegionBuilding = w.buildings[i]
		if b == null:
			continue
		var d: Dictionary = bs[i]
		b.slot_unit.clear()
		for k: Variant in d.get("slots", []):
			b.slot_unit.append(_resolve(reg, k) as Legionnaire)
		for k: Variant in d.get("brisk", []):
			b._brisk.append(_resolve(reg, k) as Legionnaire)
	var crypt_d: Array = data.get("crypts", [])
	for i in mini(crypt_d.size(), w.crypts.size()):
		w.crypts[i].building = _resolve(
			reg, (crypt_d[i] as Dictionary).get("building", null)) as LegionBuilding
	var hs: Array = data.get("heroes", [])
	for i in mini(hs.size(), w.sides.size()):
		var h := w.hero_of(i)
		if h == null:
			continue
		var d: Dictionary = hs[i]
		h._haste_units.clear()
		for k: Variant in d.get("haste", []):
			h._haste_units.append(_resolve(reg, k) as Legionnaire)
		var vs: Array = d.get("vassals", [])
		for j in mini(vs.size(), h._vassals.size()):
			var v: LegionHero._Vassal = h._vassals[j]
			v._target = _resolve(reg, (vs[j] as Dictionary).get("target", null)) as Foe


## Побочных сдвигов нет: фабрики куска не трогают души, RNG и счётчики мира (их К1 вернёт
## в finish последним). Порядок построек уже стоит с build.
static func finish(_w: LegionWorld, _data: Dictionary, _reg: NetSnap.Reg) -> void:
	pass


# ── Состояния объектов ───────────────────────────────────────────────────────


static func _apply_building(b: LegionBuilding, d: Dictionary) -> void:
	b.side = int(d.get("side", b.side))
	b.kind = StringName(String(d.get("kind", b.kind)))
	b.source = StringName(String(d.get("source", b.source)))
	b.level = int(d.get("level", 1))
	b.cap = int(d.get("cap", 0))
	b.respawn_t = float(d.get("respawn_t", b.respawn_t))
	b.position = d.get("position", b.position)
	b.entry = d.get("entry", b.entry)
	b.entry_ring = d.get("entry_ring", b.entry_ring)
	b.frozen = bool(d.get("frozen", false))
	b.invested = int(d.get("invested", 0))
	b.plot_id = String(d.get("plot_id", ""))
	b.brisk_exit = bool(d.get("brisk_exit", false))
	b.slot_t = (d.get("slot_t", PackedFloat32Array()) as PackedFloat32Array).duplicate()
	b.slot_fresh = (d.get("slot_fresh", PackedByteArray()) as PackedByteArray).duplicate()
	b._fill_cd = float(d.get("fill_cd", 0.0))
	b._brisk_t = (d.get("brisk_t", PackedFloat32Array()) as PackedFloat32Array).duplicate()
	b.slot_unit.clear()
	b.slot_unit.resize(b.slot_t.size())   # null-ы; бойцов положит link
	b._brisk.clear()
	b.refresh_artwork()   # вид: уровень/вид мог измениться, пусто для Котла и склепа
	b.queue_redraw()


static func _apply_crypt(c: LegionCrypt, d: Dictionary) -> void:
	c.position = d.get("position", c.position)
	c.progress = float(d.get("progress", 0.0))
	c.contested = bool(d.get("contested", false))
	# enum через int напрямую не присваивается типизированно — разбор значений
	match int(d.get("allegiance", LegionCrypt.Owner.NEUTRAL)):
		LegionCrypt.Owner.PLAYER:
			c.allegiance = LegionCrypt.Owner.PLAYER
		LegionCrypt.Owner.ENEMY:
			c.allegiance = LegionCrypt.Owner.ENEMY
		_:
			c.allegiance = LegionCrypt.Owner.NEUTRAL
	match int(d.get("capturing", LegionCrypt.Owner.NEUTRAL)):
		LegionCrypt.Owner.PLAYER:
			c.capturing = LegionCrypt.Owner.PLAYER
		LegionCrypt.Owner.ENEMY:
			c.capturing = LegionCrypt.Owner.ENEMY
		_:
			c.capturing = LegionCrypt.Owner.NEUTRAL


# ── Ссылки реестра ───────────────────────────────────────────────────────────


## Ключ объекта или null (нет объекта, освобождён или вне массивов мира): null и ""
## в разрешении ведут себя одинаково, но null не даёт ложных «ссылок в никуда» в снимке.
## Параметр без типа: освобождённый боец (его может легально держать _brisk/_haste_units,
## пока идёт таймер) не проходит проверку типа Object-параметра — Godot 4.7 это ошибка вызова.
static func _ref(reg: NetSnap.Reg, o: Variant) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	var key := reg.ref_of(o)
	return key if key != "" else null


static func _refs(reg: NetSnap.Reg, arr: Array) -> Array:
	var out := []
	for u in arr:
		out.append(_ref(reg, u))
	return out


static func _resolve(reg: NetSnap.Reg, key: Variant) -> Object:
	return reg.resolve("" if key == null else String(key))
