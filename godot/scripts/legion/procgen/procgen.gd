class_name ProcGen
extends RefCounted
##
## Фасад процедурных карт (STAGE2 §2). Карта объекта k забега run_seed — словарь формата
## кампании плюс поля процгена. Одинаковые (сид, k, VERSION, catalog.json) → одинаковый
## словарь: вся случайность — PgRng от строк «сид|шаг|попытка».
##
##   ProcGen.generate(7, 3)                         карта объекта 3 забега 7
##   ProcGen.generate(7, 3, {"card": {...}})        «заданная карточка» (D-0927-91): поля
##                                                  карточки явно, остальное — генератор
##   ProcGen.map_from_id("gen:7:3")                 то же по id (движок: --map gen:7:3)
##   ProcGen.freeze(map) / ProcGen.thaw(text)       карта целиком в JSON и обратно
##   ProcGen.generate(7, 3, {"pvp": true})          поле PvP из двух половин (PgPvp, BOOK §12);
##                                                  id "gen:7:3:pvp"
##

const VERSION := 1
const ID_PREFIX := "gen:"
## Попытки раскладки: по ATTEMPTS_PER_CARD на карточку, затем следующая по близости к цели
## карточка того же объекта; исчерпаны — «спокойная» карточка (передышка, змейка).
const ATTEMPTS_PER_CARD := 4
const MAX_ATTEMPTS := 12
const CALM_ATTEMPT_BASE := 100
## Заданная карточка: попыток на вариант, всего, и свой диапазон номеров попыток (сиды шага
## раскладки не пересекаются с обычными).
const FORCED_PER_VARIANT := 4
const FORCED_MAX := 240
const FORCED_ATTEMPT_BASE := 1000
## Порядок ключей словаря — как в JSON кампании (читать глазами и сравнивать проще).
const KEY_ORDER: Array[String] = ["id", "title", "subtitle", "theme", "biome", "cauldron",
	"cauldron_hp", "start_army", "army_cap", "rocks", "walls", "roads", "breaches",
	"bot_lines", "hint", "water", "bridges", "swamp", "crypts", "sleepers", "flights",
	"decor", "waves", "plots", "bg", "ground", "props", "ambient", "edges", "procgen"]

## Кэш по id на время процесса: генерация не идёт дважды за один бой (STAGE2 §2).
static var _cache: Dictionary = {}
## Причины провала попыток (для отладки и дампа): причина → сколько раз.
static var fail_log: Dictionary = {}
## Причина последнего отказа заданной карточки ("" — отказа не было).
static var last_error := ""


static func make_id(run_seed: int, k: int) -> String:
	return "%s%d:%d" % [ID_PREFIX, run_seed, k]


## gen:<сид>:<k>[:<опции>] → карта (копия: движок меняет словарь). Чужой формат → {}.
static func map_from_id(id: String) -> Dictionary:
	if not id.begins_with(ID_PREFIX):
		return {}
	if _cache.has(id):
		return (_cache[id] as Dictionary).duplicate(true)
	var parts := id.split(":")
	if parts.size() < 3 or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return {}
	var k := parts[2].to_int()
	if k < 1:
		return {}
	var opts := {}
	if parts.size() >= 4 and parts[3] == PgPvp.ID_SUFFIX:
		opts["pvp"] = true
	var map := generate(parts[1].to_int(), k, opts)
	if map.is_empty():
		return {}
	_cache[id] = map
	return map.duplicate(true)


static func generate(run_seed: int, k: int, opts := {}) -> Dictionary:
	if bool(opts.get("pvp", false)):
		return PgPvp.generate(run_seed, k, opts)
	# одиночная карта — всегда в рамке кадра 1280×720 (рамку половины PvP ставит и снимает PgPvp)
	PgGeom.reset_frame()
	var chain := PgCard.chain(run_seed, maxi(k, 1))
	var card: Dictionary = chain[-1]
	if opts.has("card"):
		return _generate_forced(run_seed, k, card, opts["card"])
	var cards: Array = [card]
	cards.append_array(card.get("alts", []))
	for a in MAX_ATTEMPTS:
		var c: Dictionary = cards[mini(a / ATTEMPTS_PER_CARD, cards.size() - 1)]
		var map := _try(run_seed, k, c, a)
		if not map.is_empty():
			return map
	var prev_biome := String(chain[-2]["biome"]) if chain.size() > 1 else ""
	var calm := PgCard.calm(k, "ash" if prev_biome != "ash" else "grave",
		float(card["difficulty"]))
	for a in MAX_ATTEMPTS:
		var map := _try(run_seed, k, calm, CALM_ATTEMPT_BASE + a)
		if not map.is_empty():
			return map
	push_error("ProcGen: и спокойная карточка не разложилась (сид %d, объект %d)" % [
		run_seed, k])
	return {}


## Заданная карточка (PgForced): варианты незаданных полей по порядку, по FORCED_PER_VARIANT
## попыток каждому; не сложилось — сиды шага раскладки по кругу вариантов до FORCED_MAX.
## Пусто — только если задано невозможное (last_error называет причину).
static func _generate_forced(run_seed: int, k: int, base: Dictionary, forced: Dictionary) \
		-> Dictionary:
	last_error = PgForced.problem(forced)
	var vars: Array[Dictionary] = []
	if last_error.is_empty():
		vars = PgForced.variants(base, forced, PgRng.make(run_seed, "forced:%d" % k, 0))
		if vars.is_empty():
			last_error = "нет совместимой карточки для заданных полей"
	if not last_error.is_empty():
		push_error("ProcGen: заданная карточка невозможна — " + last_error)
		return {}
	var a := 0
	while a < FORCED_MAX:
		var i := a / FORCED_PER_VARIANT
		var v: Dictionary = vars[i] if i < vars.size() else vars[a % vars.size()]
		var map := _try(run_seed, k, v, FORCED_ATTEMPT_BASE + a)
		if not map.is_empty():
			return map
		a += 1
	last_error = "заданная карточка не разложилась за %d попыток" % FORCED_MAX
	push_error("ProcGen: " + last_error + " (сид %d, объект %d)" % [run_seed, k])
	return {}


static func _try(run_seed: int, k: int, card: Dictionary, attempt: int) -> Dictionary:
	var clean := card.duplicate(true)
	clean.erase("alts")
	var layout := PgLayout.new()
	var map := layout.build(clean, PgRng.make(run_seed, "layout:%d" % k, attempt))
	if map.is_empty():
		_log(String(clean["archetype"]) + ": " + layout.fail)
		return {}
	map["id"] = make_id(run_seed, k)
	var pg: Dictionary = map["procgen"]
	pg["version"] = VERSION
	pg["seed"] = run_seed
	pg["k"] = k
	pg["card"] = clean
	pg["attempt"] = attempt
	pg["unusual"] = clean["unusual"]
	pg["difficulty"] = clean["difficulty"]
	map["waves"] = PgWaves.build(map, clean, PgRng.make(run_seed, "waves:%d" % k, attempt))
	PgNames.apply(map, clean, PgRng.make(run_seed, "names:%d" % k, attempt))
	var bad := PgLayout.self_check(map)
	bad.append_array(PgFilter.check(map))
	if not bad.is_empty():
		_log(String(clean["archetype"]) + ": проверка — " + bad[0])
		return {}
	return _ordered(map)


static func _log(why: String) -> void:
	fail_log[why] = int(fail_log.get(why, 0)) + 1


static func _ordered(map: Dictionary) -> Dictionary:
	var out := {}
	for key in KEY_ORDER:
		if map.has(key):
			out[key] = map[key]
	for key: String in map:
		if not out.has(key):
			out[key] = map[key]
	return out


## Заморозка: словарь карты целиком в JSON (порядок ключей сохраняется) — кампанийную карту
## можно сохранить файлом и дальше править руками (уроки, подсказки).
static func freeze(map: Dictionary) -> String:
	return JSON.stringify(map, "\t", false)


static func thaw(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## Хэш словаря для проверки детерминизма (ключи — по алфавиту, чтобы порядок вставки не влиял).
static func digest(map: Dictionary) -> String:
	return JSON.stringify(map, "", true).sha256_text()
