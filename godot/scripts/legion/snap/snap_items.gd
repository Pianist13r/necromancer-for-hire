class_name SnapItems
extends RefCounted
##
## К6 снимка (NetSnap): артефакты сторон (LegionItems, w.items_of(i)). Интерфейс — докстринг
## SnapWorld.
##
## Сохраняется (на сторону): counts (порядок ключей = порядок получения), synergies (порядок),
## hazards (опасные зоны — данные), state (счётчики обработчиков; «trail» — ключи instance_id
## бойцов, в снимке — ссылки reg), plan, found, _wave_seen, rng (seed+state), _timers.
## Таймеры — данные {t, fx, args} (LegionItems.after → LegionItemEffects.run_timer по имени), args
## — через reg.enc/dec. Пересчитывается: _sums/_handlers/_looks — _rebuild() из counts+synergies;
## числа поля (мана, цена линии) — world.apply_items().
## Не сохраняется — вид: _pulse (импульс получения), _look_hits (счётчик для тестов); effects
## (LegionItemEffects) полей состояния не имеет; owner_side и подписки на сигналы — от setup.
##

const READY := true
## Ключ state «Сургуча с огоньком»: instance_id бойца → последняя точка следа (item_effects).
const TRAIL := &"trail"

## Поля LegionItems (тест полноты): в снимке; пересчёт (_rebuild/apply_items); прочее.
const ITEMS_SAVED: Array[String] = [
	"counts", "synergies", "hazards", "state", "rng", "plan", "found", "_timers", "_wave_seen",
]
const ITEMS_SKIP: Array[String] = [
	"world", "owner_side", "effects",   # структура: ставит setup
	"_sums", "_handlers", "_looks",     # пересчёт _rebuild() из counts + synergies
	"_look_hits", "_pulse",             # вид и счётчик тестов
]


## Сверка полей классов (тест): [скрипт, учтённые имена]. У LegionItemEffects полей нет —
## новое поле без решения уронит тест.
static func coverage() -> Array:
	return [
		[LegionItems, ITEMS_SAVED + ITEMS_SKIP],
		[LegionItemEffects, ["world", "items"]],
	]


static func save(w: LegionWorld, reg: NetSnap.Reg) -> Dictionary:
	var sides := []
	for s in w.sides:
		var it := w.items_of(s.index)
		if it == null:
			sides.append({})
			continue
		var timers := []
		for tm in it._timers:
			timers.append({"t": tm["t"], "fx": tm["fx"], "args": reg.enc(tm["args"])})
		sides.append({
			"counts": it.counts.duplicate(), "synergies": Array(it.synergies),
			"hazards": reg.enc(Array(it.hazards)), "state": _save_state(it.state, reg),
			"plan": Array(it.plan), "found": it.found, "wave_seen": it._wave_seen.duplicate(),
			"rng": NetSnap.save_rng(it.rng), "timers": timers,
		})
	return {"sides": sides}


## Данные без ссылок — сразу; state и таймеры (в них ссылки) — в link.
static func build(w: LegionWorld, data: Dictionary, _reg: NetSnap.Reg) -> void:
	var sides: Array = data.get("sides", [])
	for i in mini(sides.size(), w.sides.size()):
		var it := w.items_of(i)
		var d: Dictionary = sides[i]
		if it == null or d.is_empty():
			continue
		var before := it.owned()
		it.counts = (d["counts"] as Dictionary).duplicate()
		it.synergies.assign(d["synergies"])
		it.plan.assign(d["plan"])
		it.found = int(d["found"])
		it._wave_seen = (d["wave_seen"] as Dictionary).duplicate()
		NetSnap.load_rng(it.rng, d["rng"])
		it.state = {}
		it.hazards.clear()
		it._timers.clear()
		it._rebuild()
		if it.owned() != before:
			_refresh_view(it)
	if not sides.is_empty():
		w.apply_items()


static func link(w: LegionWorld, data: Dictionary, reg: NetSnap.Reg) -> void:
	var sides: Array = data.get("sides", [])
	for i in mini(sides.size(), w.sides.size()):
		var it := w.items_of(i)
		var d: Dictionary = sides[i]
		if it == null or d.is_empty():
			continue
		it.hazards.assign(reg.dec(d["hazards"]))
		it.state = _load_state(d["state"], reg)
		for tm: Dictionary in d["timers"]:
			it._timers.append({"t": float(tm["t"]), "fx": StringName(tm["fx"]),
				"args": reg.dec(tm["args"])})


## RNG артефактов — последним (build/link других кусков его не тратят, но порядок фаз требует).
static func finish(w: LegionWorld, data: Dictionary, _reg: NetSnap.Reg) -> void:
	var sides: Array = data.get("sides", [])
	for i in mini(sides.size(), w.sides.size()):
		var it := w.items_of(i)
		var d: Dictionary = sides[i]
		if it != null and not d.is_empty():
			NetSnap.load_rng(it.rng, d["rng"])


## state: «trail» (instance_id → точка) — списком [ссылка бойца, точка] в порядке ключей; боец
## вне массивов мира (уже снят) пропускается: следующий же tick стёр бы его запись.
static func _save_state(state: Dictionary, reg: NetSnap.Reg) -> Dictionary:
	var out := {}
	for k: Variant in state:
		if k == TRAIL:
			var trail := []
			var last: Dictionary = state[k]
			for id: int in last:
				var key := reg.ref_of(instance_from_id(id))
				if key != "":
					trail.append([key, last[id]])
			out[k] = trail
		else:
			out[k] = reg.enc(state[k])
	return out


static func _load_state(data: Dictionary, reg: NetSnap.Reg) -> Dictionary:
	var out := {}
	for k: Variant in data:
		if k == TRAIL:
			var last := {}
			for pair: Array in data[k]:
				var u := reg.resolve(String(pair[0]))
				if u != null:
					last[u.get_instance_id()] = pair[1]
			out[k] = last
		else:
			out[k] = reg.dec(data[k])
	return out


## Набор артефактов стороны сменился загрузкой — полоска (item_bar) пересобирается сигналами,
## как при новом бое: cleared, затем gained без выпадения (Vector2.INF — без карточки).
static func _refresh_view(it: LegionItems) -> void:
	it.cleared.emit()
	for id in it.owned():
		it.gained.emit(id, Vector2.INF)
