class_name SnapFlow
extends RefCounted
##
## К5 снимка (NetSnap): волны (WaveRunner), боты сторон (PvpBot).
## Интерфейс — докстринг SnapWorld.
##
## Состояние куска — только данные (числа, строки, словари, массивы), ссылок на объекты нет:
## link пуст. Бот помнит договоры числом (Contract.id в _defense[].id и _assault_id) — их
## восстанавливает К2, здесь они проходят как есть. waves WaveRunner не снимаем — те же из
## карты; side/world бота и сами боты стабильны (их со сторонами создаёт start_map по тому же
## cfg — совместимость сверяет К1).
##

const READY := true

## Поля классов куска (тест полноты): в снимке или пропуск с причиной.
const WAVES_SAVED: Array[String] = ["index", "phase", "timer", "held", "_runs", "_clock", "_due",
	"_last_call", "_last_start", "_called_since_tick"]
const WAVES_SKIP: Array[String] = [
	"world",
	"waves",   # волны карты: только читаются; карта — в конфиге К1 (map_hash)
]
const BOT_SAVED: Array[String] = ["stage", "counts", "_rng", "_think_t", "_defense", "_assault_id",
	"_stage_t", "_siege_hp", "_siege_hit_t"]
const BOT_SKIP: Array[String] = [
	"world", "side",   # структура: _setup_pvp_bots в start_map
	"sink",            # сетевая проба (Callable): куда слать команды — решает хозяин мира
]


## Сверка полей классов (тест): [скрипт, учтённые имена].
static func coverage() -> Array:
	return [
		[WaveRunner, WAVES_SAVED + WAVES_SKIP],
		[PvpBot, BOT_SAVED + BOT_SKIP],
	]


static func save(w: LegionWorld, _reg: NetSnap.Reg) -> Dictionary:
	var wr := w.wave_runner
	var waves := {}
	if wr != null:
		waves = {
			"index": wr.index, "phase": int(wr.phase), "timer": wr.timer, "held": wr.held,
			"runs": _plain(wr._runs), "clock": wr._clock, "due": wr._due,
			"last_call": wr._last_call, "last_start": wr._last_start,
			"called": wr._called_since_tick,
		}
	var bots := []
	for s in w.sides:
		if s.bot is PvpBot:
			var b := s.bot as PvpBot
			bots.append({
				"stage": int(b.stage), "counts": b.counts.duplicate(true),
				"rng": NetSnap.save_rng(b._rng), "think_t": b._think_t,
				"defense": _plain(b._defense), "assault_id": b._assault_id,
				"stage_t": b._stage_t, "siege_hp": b._siege_hp,
				"siege_hit_t": b._siege_hit_t,
			})
		else:
			bots.append({})
	return {"waves": waves, "bots": bots}


static func build(w: LegionWorld, data: Dictionary, _reg: NetSnap.Reg) -> void:
	if data.is_empty():
		return
	var wr := w.wave_runner
	if wr != null and data.has("waves"):
		_waves_build(wr, data["waves"])
	var bots: Array = data.get("bots", [])
	for i in mini(bots.size(), w.sides.size()):
		if w.sides[i].bot is PvpBot and bots[i] is Dictionary \
				and not (bots[i] as Dictionary).is_empty():
			_bot_build(w.sides[i].bot as PvpBot, bots[i])


static func _waves_build(wr: WaveRunner, d: Dictionary) -> void:
	wr.index = int(d["index"])
	wr.phase = int(d["phase"])
	wr.timer = float(d["timer"])
	wr.held = bool(d["held"])
	wr._runs = _typed_dicts(d["runs"])
	wr._clock = float(d["clock"])
	wr._due = float(d["due"])
	wr._last_call = float(d["last_call"])
	wr._last_start = float(d["last_start"])
	wr._called_since_tick = bool(d["called"])


static func _bot_build(b: PvpBot, d: Dictionary) -> void:
	b.stage = int(d["stage"])
	b.counts = (d["counts"] as Dictionary).duplicate(true)
	NetSnap.load_rng(b._rng, d["rng"])
	b._think_t = float(d["think_t"])
	b._defense = _typed_dicts(d["defense"])
	b._assault_id = int(d["assault_id"])
	b._stage_t = float(d["stage_t"])
	b._siege_hp = float(d["siege_hp"])
	b._siege_hit_t = float(d["siege_hit_t"])


## Ссылок нет — разрешать нечего.
static func link(_w: LegionWorld, _data: Dictionary, _reg: NetSnap.Reg) -> void:
	pass


## Кусок последний в CHUNKS: после его build мир (и потоки в нём) до grid.rebuild() никто не
## трогает, побочно сдвинутого состояния нет; timer уже точное значение снимка.
static func finish(_w: LegionWorld, _data: Dictionary, _reg: NetSnap.Reg) -> void:
	pass


## Состояние в Array[Dictionary]: копия вглубь, чтобы мир не делил словари со снимком.
static func _typed_dicts(src: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for x: Variant in (src as Array):
		out.append((x as Dictionary).duplicate(true))
	return out


## Глубокая копия в простые структуры: у живого мира очереди волн и рубежи бота лежат в
## типизированных массивах, а после загрузки — в обычных; byte-сравнение двух снимков не
## должно видеть этой разницы.
static func _plain(v: Variant) -> Variant:
	if v is Array:
		var out := []
		for x: Variant in v:
			out.append(_plain(x))
		return out
	if v is Dictionary:
		var out := {}
		for k: Variant in v:
			out[k] = _plain(v[k])
		return out
	return v
