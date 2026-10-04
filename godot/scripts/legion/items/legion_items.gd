# gdlint: disable=max-public-methods
class_name LegionItems
extends RefCounted
##
## Артефакты боя и забега: что у игрока есть, сумма их чисел, особые обработчики по событиям
## боя, постоянный вид (look) и редкое выпадение с НОСИТЕЛЕЙ. Реестр — item_db.gd, обработчики —
## item_effects.gd, вид — item_look.gd (постоянный) и item_fx.gd (вспышки).
##
## v2 (Игорь 27.09, D-0927-163): «один-два раза за битву максимум, и то не каждую битву»,
## «зря они в конце выпадают», «сохранялись в течение всего забега». Отсюда:
##   • при старте карты бросается бюджет боя 0/1/2 (CfgItems.BATTLE_BUDGET_WEIGHTS) и волны
##     носителей — с середины боя и не в последней (plan); враг пехоты этой волны (CARRIER_NTH-й)
##     рождается элитным НОСИТЕЛЕМ («портфель» над короной) и роняет артефакт, если его убить;
##   • потолок MAX_PER_BATTLE держится при любом источнике (урок «Архива», --dev drop);
##   • артефакт уникален; собранные за бой уходят в раздел забега только ПОБЕДОЙ
##     (LegionWorld.carry_items → Campaign.set_run_items), следующий бой загружает их (load_run).
##
## Механика элитных — world.rng тем же числом бросков, что и без носителей (бой вне артефактов
## не сдвигается). Бюджет, волны носителей и выбор артефакта — СВОЙ rng, засеянный от сида боя:
## воспроизводимо и не трогает остальной бой. Вид — своими ГСЧ в слоях вида.
##

## Артефакт получен (механика уже действует); at — где выпал (Vector2.INF — без выпадения:
## загружен из забега, --dev items, тест).
signal gained(id: StringName, at: Vector2)
## Набор синергии собран.
signal synergy_gained(id: StringName)
## Всё сброшено (новый бой).
signal cleared
## Вспышка особого эффекта для слоя вида: kind — &"blast" | &"bolt" | &"stun" | &"heal" |
## &"echo" | &"text" | &"gain".
signal fx_event(kind: StringName, data: Dictionary)

## События, на которые подписываются особые артефакты (поле on реестра). Хуки, которых нет среди
## сигналов мира, зовутся прямо: q_hit (hero), charge_kill и ring_squeezed (world),
## vassal_expired (hero), tick (сам tick() ниже).
const EVENTS: Array[StringName] = [
	&"foe_killed", &"charge_impact", &"charge_kill", &"q_hit", &"vassal_expired", &"w_raised",
	&"ring_squeezed", &"seg_released", &"rally_used", &"wave_cleared", &"cauldron_hit",
	&"combo_changed", &"unit_spawned", &"unit_died", &"tick",
]

var world: LegionWorld = null
var owner_side := 0
var effects: LegionItemEffects = null
## id → число копий (v2: 1 — артефакт уникален). Порядок ключей — порядок получения.
var counts: Dictionary = {}
## Собранные синергии, в порядке сбора.
var synergies: Array[StringName] = []
## Опасные зоны на земле: {pos, r, t, t0, kind, dps, stun, slow, tick, a?, b?}.
var hazards: Array[Dictionary] = []
## Счётчики обработчиков — сбрасываются с боем.
var state: Dictionary = {}
## Свой ГСЧ механики артефактов (бюджет боя, выбор артефакта) — от сида боя, не world.rng.
var rng := RandomNumberGenerator.new()
## Волны (номер с 1), в которых ещё ждёт своего носителя артефакт этого боя.
var plan: Array[int] = []
## Сколько артефактов выпало в этом бою (потолок CfgItems.MAX_PER_BATTLE).
var found := 0

var _sums: Dictionary = {}
var _handlers: Dictionary = {}
var _timers: Array[Dictionary] = []
## target → {channel: look записи} владеемых артефактов (пересборка в _rebuild).
var _looks: Dictionary = {}
## "target.channel" → сколько раз вид лёг на объект (для теста и --trace).
var _look_hits: Dictionary = {}
## target → остаток импульса получения, секунды мира.
var _pulse: Dictionary = {}
## Волна → сколько пехоты этой волны уже родилось (кто по счёту — носитель).
var _wave_seen: Dictionary = {}


func setup(w: LegionWorld, side := 0) -> LegionItems:
	world = w
	owner_side = side
	effects = LegionItemEffects.new()
	effects.setup(w, self)
	# Сигналы UI без стороны обслуживают только одиночку.
	if side == 0:
		w.foe_killed.connect(func(f: Foe, at: Vector2) -> void:
			if not w.pvp:
				_on_foe_killed(f, at))
		w.charge_impact.connect(func(at: Vector2, perfect: bool) -> void:
			if not w.pvp:
				on(&"charge_impact", [at, perfect]))
		w.rally_used.connect(func(at: Vector2, n: int) -> void:
			if not w.pvp:
				on(&"rally_used", [at, n]))
		w.wave_cleared.connect(func(i: int) -> void:
			if not w.pvp:
				on(&"wave_cleared", [i]))
		w.cauldron_hit.connect(func(amount: float) -> void:
			if not w.pvp:
				on(&"cauldron_hit", [amount]))
		w.combo_changed.connect(func(c: int, m: float) -> void:
			if not w.pvp:
				on(&"combo_changed", [c, m]))
		w.hero_cast.connect(func(slot: int, at: Vector2) -> void:
			if not w.pvp:
				_on_hero_cast(slot, at))
	w.segment_released.connect(func(c: Contract, seg: int, n: int) -> void:
		# без договора (пустой отклик, legion_core_test) — как до владельцев: сторона 0 (B-253)
		if _owns(c.owner_side if c != null else 0):
			on(&"seg_released", [c, seg, n]))
	w.unit_spawned.connect(func(u: Legionnaire) -> void:
		if _owns(u.side):
			on(&"unit_spawned", [u]))
	w.unit_died.connect(func(u: Legionnaire) -> void:
		if _owns(u.side):
			on(&"unit_died", [u]))
	return self


func _owns(side: int) -> bool:
	return side == owner_side and side < world.sides.size() and world.items_of(side) == self


## Новый бой: всё с нуля. Артефакты забега мир возвращает сразу после — load_run().
func reset() -> void:
	counts.clear()
	synergies.clear()
	hazards.clear()
	state.clear()
	_timers.clear()
	plan.clear()
	found = 0
	_wave_seen.clear()
	_pulse.clear()
	_look_hits.clear()
	rng.seed = int(world._base_seed) * 31 + CfgItems.ITEM_SEED_SALT + owner_side * 7919
	_rebuild()
	cleared.emit()


func count(id: StringName) -> int:
	return int(counts.get(id, 0))


func total() -> int:
	return counts.size()


## Артефакты в порядке получения — то, что уходит в раздел забега.
func owned() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in counts:
		out.append(id)
	return out


## Сумма чисел артефактов и собранных синергий по ключу (0 — нет).
func value(key: StringName) -> float:
	return float(_sums.get(key, 0.0))


func has_synergy(id: StringName) -> bool:
	return synergies.has(id)


## Выдать артефакт: механика действует сразу, вид (дуга в полоску, карточка) — по сигналу gained.
## at == Vector2.INF — без выпадения (--dev items, тесты, забег): сразу в полоску, без карточки.
## carried — загружен из забега: не находка этого боя, в stats не считается.
func grant(id: StringName, at: Vector2 = Vector2.INF, carried := false) -> void:
	if LegionItemDb.item(id).is_empty():
		push_warning("LegionItems: неизвестный артефакт '%s'" % id)
		return
	if counts.has(id):
		return   # уникален: второй раз тот же не выдаётся (и не выпадает — pick() его пропускает)
	counts[id] = 1
	if not carried:
		world.stats["items"] = int(world.stats.get("items", 0)) + 1
		var got := String(world.stats.get("item_ids", ""))
		world.stats["item_ids"] = (got + "," if got != "" else "") + String(id)
	var fresh: Array[StringName] = []
	for sid in LegionItemDb.synergy_ids():
		if synergies.has(sid):
			continue
		var need: Array = LegionItemDb.synergy(sid)["items"]
		if need.all(func(n: String) -> bool: return count(StringName(n)) > 0):
			synergies.append(sid)
			fresh.append(sid)
	_rebuild()
	world.apply_items()
	if at != Vector2.INF:
		_gain_impulse(id, at)
	gained.emit(id, at)
	for sid in fresh:
		if not carried:
			world.stats["synergies"] = int(world.stats.get("synergies", 0)) + 1
		synergy_gained.emit(sid)


## Артефакты забега — в начале боя, без выпадения и без карточек (полоска сразу полна).
func load_run(ids: Array) -> void:
	for id: Variant in ids:
		grant(StringName(String(id)), Vector2.INF, true)


## Событие боя → особые обработчики владеемых артефактов и синергий (fx_<имя> в item_effects).
func on(ev: StringName, args: Array) -> void:
	var list: Array = _handlers.get(ev, [])
	for h: Dictionary in list:
		effects.call("fx_" + String(h["fx"]), int(h["n"]), h["params"], args)


## q_hit уже вызвал печати при попадании; после deferred death нужен только kill jump.
func on_q_death(f: Foe, hit: Array) -> void:
	for h: Dictionary in _handlers.get(&"q_hit", []):
		if h["fx"] == &"lightning_rod":
			effects.fx_lightning_rod(int(h["n"]), h["params"], [f, hit[0], hit[1]])


## Через t секунд МИРА выполнить отложенный эффект fx с аргументами args (цепь взрывов):
## таймер — только данные {t, fx, args}, исполнение — LegionItemEffects.run_timer по имени.
## Так таймер переносится снимком боя (NetSnap, К6): Callable по сети не идёт. В args — только
## простые значения и объекты мира (снимок пишет их ссылками reg.enc).
func after(t: float, fx: StringName, args: Array) -> void:
	_timers.append({"t": t, "fx": fx, "args": args})


func add_hazard(d: Dictionary) -> void:
	d["t0"] = float(d["t"])
	d["tick"] = 0.0
	hazards.append(d)


func hazard_count(kind: StringName) -> int:
	var n := 0
	for h in hazards:
		if h["kind"] == kind:
			n += 1
	return n


## Шаг мира: таймеры, опасные зоны, обработчики «tick», остаток импульса. Зовёт LegionWorld._step.
func tick(dt: float) -> void:
	var i := 0
	while i < _timers.size():
		_timers[i]["t"] = float(_timers[i]["t"]) - dt
		if float(_timers[i]["t"]) <= 0.0:
			var timer := _timers[i]
			_timers.remove_at(i)
			effects.run_timer(timer["fx"], timer["args"])
			continue
		i += 1
	for k in range(hazards.size() - 1, -1, -1):
		var h := hazards[k]
		h["t"] = float(h["t"]) - dt
		h["tick"] = float(h["tick"]) - dt
		if float(h["tick"]) <= 0.0:
			h["tick"] = LegionItemEffects.HAZARD_TICK
			effects.hazard_pulse(h)
		if float(h["t"]) <= 0.0:
			hazards.remove_at(k)
	if _handlers.has(&"tick"):
		on(&"tick", [dt])
	for key: StringName in _pulse.keys():
		_pulse[key] = float(_pulse[key]) - dt
		if float(_pulse[key]) <= 0.0:
			_pulse.erase(key)


# ── Вид ─────────────────────────────────────────────────────────────────────

## Вид владеемых артефактов по цели: {channel: запись look}. Пусто — цель выглядит как обычно.
func look(target: StringName) -> Dictionary:
	return _looks.get(target, {})


## Запись канала цели или {} (читателю — одна строка вместо двух get).
func look_of(target: StringName, channel: StringName) -> Dictionary:
	return (_looks.get(target, {}) as Dictionary).get(channel, {})


## Вид лёг на объект: читатель вида отмечает это (тест и отладка).
func note_look(target: StringName, channel: StringName) -> void:
	var key := String(target) + "." + String(channel)
	_look_hits[key] = int(_look_hits.get(key, 0)) + 1


func look_count(key: String) -> int:
	return int(_look_hits.get(key, 0))


## Импульс получения на объекте: 0..1, сколько ещё светится ярче (1 — только что).
func pulse(target: StringName) -> float:
	return clampf(float(_pulse.get(target, 0.0)) / CfgItems.PULSE_T, 0.0, 1.0)


## Артефакт долетел в полоску — объект, на который он действует, вспыхивает (полоска зовёт).
func start_pulse(id: StringName) -> void:
	var lk := LegionItemDb.look(id)
	if not lk.is_empty():
		_pulse[StringName(lk["target"])] = CfgItems.PULSE_T


func _gain_impulse(id: StringName, at: Vector2) -> void:
	var col: Color = CfgItems.RARITY_COLOR.get(LegionItemDb.rarity(id), Color.WHITE)
	fx_event.emit(&"gain", {"pos": at, "color": col})
	Juice.shake(world, CfgItems.GAIN_SHAKE, CfgItems.GAIN_SHAKE_T)
	world.impact_stop(CfgItems.GAIN_HITSTOP)


# ── Элитные, носители и выпадение ───────────────────────────────────────────

## Бюджет боя и волны носителей (старт карты, после WaveRunner). total — число волн карты.
## --dev carriers=3,4 — волны носителей руками (кадры, тесты); --dev carriers= — ни одной.
func plan_battle(total_waves: int) -> void:
	plan.clear()
	_wave_seen.clear()
	# сид боя в игре у всех боёв один (--seed по умолчанию 1): без карты и числа собранных
	# каждый бой кампании бросал бы один и тот же бюджет — «всегда один» или «никогда»
	rng.seed = hash("%d|%s|%d" % [world._base_seed, world.map_id, total()]) + CfgItems.ITEM_SEED_SALT
	if world.dev.has("carriers"):
		for s in String(world.dev["carriers"]).split(",", false):
			plan.append(int(s))
		return
	var budget := _roll_budget()
	# поправка «Стол находок» (item_luck): пустой бой перебрасывается один раз
	if budget == 0 and world.item_add(&"item_luck") > 0.0:
		budget = _roll_budget()
	if total() >= CfgItems.RUN_MAX or LegionItemDb.pick(rng, counts) == &"":
		budget = 0
	var window: Array[int] = []
	for wn in range(ceili(total_waves * CfgItems.WINDOW_FROM), total_waves):
		if wn >= 1:
			window.append(wn)
	for i in range(window.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := window[i]
		window[i] = window[j]
		window[j] = tmp
	for i in mini(budget, window.size()):
		plan.append(window[i])
	plan.sort()


func _roll_budget() -> int:
	var w := CfgItems.BATTLE_BUDGET_WEIGHTS
	var sum := 0.0
	for x in w:
		sum += x
	var roll := rng.randf() * sum
	for i in w.size():
		roll -= w[i]
		if roll <= 0.0:
			return i
	return w.size() - 1


## Бросок на элитного для врага волны. Обучение, свита, босс, Юрист, мимик — никогда.
## --dev elite=ШАНС — принудительный шанс (кадры приёмки, тесты).
## forced — группа волны с полем `elite` (гарантированный элитный для урока): без броска.
## Носитель (волна из plan, CARRIER_NTH-й пехотинец) — элитный всегда, бросок world.rng тот же.
func roll_elite(f: Foe, forced := false) -> bool:
	# урок, держащий волну (обучение «Пустыря»), — без элитных; кампания до «Архива» — тоже:
	# элитные и артефакты открывает он (D-0926-46). Проверка до броска ГСЧ: вне кампании всё
	# открыто, и бой бота не меняется.
	if f == null or (world.tutorial != null and world.tutorial.holding()) \
			or world.camp_stat(&"loot_unlocked_items") < 0.5 \
			or not CfgItems.ELITE_TYPES.has(f.type_id):
		return false
	var carrier := _take_carrier(int(f.origin.get("wave", 0)))
	# поредевший враг весит souls_mult прежних голов (темп D-0927-49) — и шанс его ×вес
	var chance := minf(CfgItems.ELITE_CHANCE + world.item_add(&"elite_chance"),
		CfgItems.ELITE_CHANCE_CAP) * LegionChallenge.heads(f)
	if world.dev.has("elite"):
		chance = float(world.dev["elite"])
	if not forced and world.rng.randf() >= chance and not carrier:
		return false
	f.make_elite(carrier)
	world.stats["elites"] = int(world.stats.get("elites", 0)) + 1
	if carrier:
		world.stats["carriers"] = int(world.stats.get("carriers", 0)) + 1
	return true


func _take_carrier(wn: int) -> bool:
	if wn <= 0 or not plan.has(wn):
		return false
	var n := int(_wave_seen.get(wn, 0)) + 1
	_wave_seen[wn] = n
	if n < CfgItems.CARRIER_NTH:
		return false
	plan.erase(wn)
	return true


## Шанс выпадения с НЕносителя: 0; --dev drop=ШАНС — с любого элитного (кадры, тесты).
func drop_chance() -> float:
	if world.dev.has("drop"):
		return float(world.dev["drop"])
	return 0.0


func _on_foe_killed(f: Foe, pos: Vector2) -> void:
	if world.pvp:
		if f.last_hit_side != owner_side or f.has_meta(&"pvp_item_death_processed"):
			return
		f.set_meta(&"pvp_item_death_processed", true)
	if f.elite:
		world.stats["elites_killed"] = int(world.stats.get("elites_killed", 0)) + 1
		# урок «элитный и артефакт» ещё не зачтён — выпадение гарантировано: первый элитный
		# кампании обязан показать артефакт
		var lesson := world.tutorial != null and world.tutorial.wants_item()
		var dev_drop := drop_chance() > 0.0 and rng.randf() < drop_chance()
		if not f.has_meta(&"summoned") and (f.carrier or lesson or dev_drop) \
				and found < CfgItems.MAX_PER_BATTLE:
			var id := LegionItemDb.pick(rng, counts)
			if id != &"":
				found += 1
				grant(id, pos)
	on(&"foe_killed", [f, pos])


func _on_hero_cast(slot: int, _at: Vector2) -> void:
	if slot != LegionHero.SLOT_W or world.hero_of(owner_side) == null:
		return
	var spots: Array[Vector2] = []
	for r: Dictionary in world.hero_of(owner_side).last_cast.get("raised", []):
		spots.append(r["pos"])
	on(&"w_raised", [spots])


func _rebuild() -> void:
	_sums.clear()
	_handlers.clear()
	_looks.clear()
	for id: StringName in counts:
		var e := LegionItemDb.item(id)
		_add_entry(e, int(counts[id]))
		var lk: Dictionary = e.get("look", {})
		if not lk.is_empty():
			var target := StringName(lk["target"])
			if not _looks.has(target):
				_looks[target] = {}
			(_looks[target] as Dictionary)[StringName(lk["channel"])] = lk
	for sid in synergies:
		_add_entry(LegionItemDb.synergy(sid), 1)


func _add_entry(e: Dictionary, n: int) -> void:
	var mods: Dictionary = e.get("mods", {})
	for k: String in mods:
		var key := StringName(k)
		_sums[key] = float(_sums.get(key, 0.0)) + float(mods[k]) * n
	if e.has("on"):
		var ev := StringName(e["on"])
		if not _handlers.has(ev):
			_handlers[ev] = []
		(_handlers[ev] as Array).append({"fx": e["fx"], "n": n, "params": e.get("params", {})})
