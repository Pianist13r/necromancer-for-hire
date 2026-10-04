class_name PgTables
extends RefCounted
##
## Таблицы совместимости BOOK §6 данными. Буквы клеток: F — «часто» (Ч, ×1,0), R — «редко»
## (Р, ×0,35), S — «почти никогда» (П, ×0,06, «сюрприз»), «-» — никогда. Порядок столбцов —
## BIOMES. Числа необычности — BOOK §5.1, лестница видов — §5.2. Правило разнообразия — §5.3.
##

const BIOMES: Array[String] = ["grave", "office", "swamp", "ash", "site"]
## Запасной рисунок движка без PgArt: у terrain_view есть темы grave/swamp/ash/office.
const BIOME_THEME := {"grave": "grave", "office": "office", "swamp": "swamp", "ash": "ash",
	"site": "office"}
const W := {"F": 1.0, "R": 0.35, "S": 0.06, "-": 0.0}
const SURPRISE := "S"

## §6.1 биом × архетип (18-й, «зеркало», — преобразование любого, строки у него нет).
const ARCH := {
	"snake": "FRFFF", "turnstile": "RFSRF", "fork": "FFRFR", "shelves": "SF--R",
	"crossing": "FSFRS", "maze": "FF-RR", "crypts": "R-FS-", "two_fronts": "RRRRF",
	"spiral": "FRRFR", "star": "RFRFR", "pincers": "FFFFF", "twins": "RSFRS",
	"boulevard": "FRRRR", "courtyard": "RFSRF", "relay": "RFRFR", "island": "R-FSS",
	"hub": "RFRRR",
}
## Порядок архетипов — ради детерминизма перебора (порядок ключей словаря тоже стабилен,
## но явный список читается и сверяется с BOOK §3 проще).
const ARCH_ORDER: Array[String] = ["snake", "turnstile", "fork", "shelves", "crossing", "maze",
	"crypts", "two_fronts", "spiral", "star", "pincers", "twins", "boulevard", "courtyard",
	"relay", "island", "hub"]
const CAMPAIGN_ARCH: Array[String] = ["snake", "turnstile", "fork", "shelves", "crossing",
	"maze", "crypts", "two_fronts"]

## Редкость архетипа (§5.1): кампанийные 0,10; новые 0,20–0,35.
const ARCH_RARITY := {"spiral": 0.35, "island": 0.35, "star": 0.25, "pincers": 0.2,
	"twins": 0.3, "boulevard": 0.2, "courtyard": 0.25, "relay": 0.2, "hub": 0.25}
const CAMPAIGN_RARITY := 0.10
## «Зеркало» (архетип 18) — дешёвое разнообразие: небольшая добавка к необычности.
const MIRROR_BONUS := 0.10

## Устройство архетипа, от которого зависят изюминки: число ворот, есть ли слияние/развилка,
## можно ли отражать (верхние ворота при отражении уйдут под HUD — у maze/star/hub нельзя).
const ARCH_CAPS := {
	"snake": {"gates": 1, "merge": false, "mirror": true},
	"turnstile": {"gates": 1, "merge": true, "mirror": true},
	"fork": {"gates": 1, "merge": true, "mirror": true},
	"shelves": {"gates": 2, "merge": true, "mirror": true},
	"crossing": {"gates": 1, "merge": true, "mirror": true, "water": true},
	"maze": {"gates": 3, "merge": true, "mirror": false},
	"crypts": {"gates": 2, "merge": true, "mirror": true},
	"two_fronts": {"gates": 2, "merge": true, "mirror": true},
	"spiral": {"gates": 1, "merge": false, "mirror": true, "center": true},
	"star": {"gates": 3, "merge": false, "mirror": false, "center": true},
	# клещи и близнецы сходятся только в самом Котле (с двух сторон) — узла слияния нет
	"pincers": {"gates": 2, "merge": false, "mirror": true},
	"twins": {"gates": 2, "merge": false, "mirror": true},
	"boulevard": {"gates": 2, "merge": true, "mirror": true},
	"courtyard": {"gates": 1, "merge": false, "mirror": true},
	# у эстафеты Котёл внизу (y 544–576): отражённый справа ушёл бы из y 200–520 (§3.2, 18)
	"relay": {"gates": 1, "merge": false, "mirror": false},
	"island": {"gates": 2, "merge": true, "mirror": true, "water": true},
	"hub": {"gates": 3, "merge": true, "mirror": false},
}

## Изюминки §4.1 (19 шт.). id короткие: их читают фильтр (throat), волны и названия.
const QUIRK_ORDER: Array[String] = ["bridge1", "rear_breach", "merge_breach", "inner_check",
	"mimic_best", "mimic_mine", "crypts_front", "flight", "throat", "swamp_road", "golden_pit",
	"recruit_link", "quiet_road", "center", "runway", "island_plot", "roster", "boss", "coffee"]
## §6.2 биом × изюминка. Строк нет у «котла в центре», «состава» и «Прораба» — их держат
## архетип и расписание, а не биом (F во всех столбцах).
const QUIRK := {
	"bridge1": "FSFRR", "rear_breach": "RRRFF", "merge_breach": "RRRFF", "inner_check": "RFRFF",
	"mimic_best": "FRFRS", "mimic_mine": "FRFRS", "crypts_front": "F-FR-", "flight": "FFRRS",
	"throat": "RFRRF", "swamp_road": "R-F-S", "coffee": "-R---", "golden_pit": "RRFFR",
	"recruit_link": "FFFFF", "quiet_road": "FFFFF", "runway": "RFRFF", "island_plot": "R-FS-",
	"center": "FFFFF", "roster": "FFFFF", "boss": "FFFFF",
}
## Вес изюминки в необычности (§5.1: 0,10 топь на дороге … 0,30 внутренняя проверка).
const QUIRK_WEIGHT := {
	"bridge1": 0.2, "rear_breach": 0.3, "merge_breach": 0.25, "inner_check": 0.3,
	"mimic_best": 0.2, "mimic_mine": 0.18, "crypts_front": 0.15, "flight": 0.22, "throat": 0.15,
	"swamp_road": 0.10, "coffee": 0.12, "golden_pit": 0.15, "recruit_link": 0.12,
	"quiet_road": 0.18, "center": 0.2, "runway": 0.10, "island_plot": 0.2, "roster": 0.15,
	"boss": 0.3,
}
## «Передышка» (§5.3): одна изюминка из спокойных.
const CALM: Array[String] = ["swamp_road", "runway", "coffee"]
## Взаимоисключающие группы: две трещины разных видов — никогда (§6.3); мимик, топь — по одной.
const EXCLUSIVE: Array = [["rear_breach", "merge_breach", "inner_check"],
	["mimic_best", "mimic_mine"], ["swamp_road", "coffee"]]
## §6.3 архетип × изюминка — никогда (плюс решения линии layout, D-0927-100…).
const CONFLICTS := {
	# у острова мосты сами — горла у Котла (§3.2 №16), второе горло на коротких коленах не встаёт
	"maze": ["throat"], "island": ["bridge1", "flight", "island_plot", "throat"],
	"spiral": ["runway"],
	"relay": ["center", "runway"], "crypts": ["coffee"], "crossing": ["bridge1"],
	"twins": ["swamp_road", "coffee"],
}
## Изюминки, которым нужна особая раскладка. «Один мост»: река через весь кадр пересекает
## общий для всех дорог прямой кусок ≥ 288 px — есть только у однодорожных архетипов (у
## развилок и фронтов общий ствол короче, D-0927-101). «Взлётка»: архетипы, умеющие растянуть
## колено до 480 px, не теряя извилистости ≥ 1,4 (развилка, клещи, бульвар — не умеют: замер
## зондом 400 скелетов — 0–5 годных). «Котёл в центре» — только §4.1 (9, 10, 17).
const BRIDGE1_ARCH: Array[String] = ["snake", "relay", "courtyard"]
const RUNWAY_ARCH: Array[String] = ["snake", "two_fronts", "hub", "courtyard"]
## «Трещина на слиянии»: слияние далеко от Котла (у прочих оно в 150–200 px от Котла, и
## трещина за ним вылезала бы прямо у Котла — это уже «трещина в тылу»).
const MERGE_BREACH_ARCH: Array[String] = ["two_fronts", "hub", "maze"]
const CENTER_ARCH: Array[String] = ["spiral", "star", "hub"]
const BOSS_ARCH: Array[String] = ["two_fronts", "hub", "spiral"]

## §5.2 лестница видов: с какого объекта вид входит в состав.
const ENEMY_FROM := {"zombie": 1, "beetle": 1, "signer": 3, "shield_inspector": 4,
	"ghost": 5, "lawyer": 6, "boss": 7}
const ENEMY_ORDER: Array[String] = ["zombie", "beetle", "signer", "shield_inspector", "ghost",
	"lawyer"]
## «Состав-изюминка» (§4.1): перекос состава на один вид.
const ROSTERS := {"signer": "notary_week", "ghost": "ghost_shift", "beetle": "courier_day",
	"shield_inspector": "shield_week", "lawyer": "legal"}
## §6.4: где вид «любит» стоять (F), где «редко» (R), где никогда («-»); прочее — R.
const ENEMY_LIKES := {
	"zombie": {"*": "F"},
	"beetle": {"pincers": "F", "relay": "F", "twins": "F"},
	"signer": {"turnstile": "F", "crossing": "F", "two_fronts": "F", "courtyard": "F"},
	"shield_inspector": {"turnstile": "F", "boulevard": "F"},
	"ghost": {"spiral": "F", "maze": "F", "shelves": "F", "island": "-"},
	"lawyer": {"fork": "F", "two_fronts": "F", "relay": "R"},
}
const ENEMY_LIKES_QUIRK := {"shield_inspector": ["throat"], "ghost": ["flight"]}

## §5.3: сколько объектов подряд ось не повторяется (архетип — 3, изюминка — 4, биом — 2,
## ведущий враг — 2). «Окно 3» = отличается от двух предыдущих.
const WINDOW := {"archetype": 3, "quirk": 4, "biome": 2, "lead": 2}
const SURPRISE_MIN_K := 4
const SURPRISE_GAP := 5


static func cell(row: String, biome: String) -> String:
	var i := BIOMES.find(biome)
	return row[i] if i >= 0 and i < row.length() else "-"


static func arch_cell(arch: String, biome: String) -> String:
	return cell(String(ARCH.get(arch, "-----")), biome)


static func quirk_cell(quirk: String, biome: String) -> String:
	return cell(String(QUIRK.get(quirk, "-----")), biome)


static func arch_rarity(arch: String) -> float:
	return float(ARCH_RARITY.get(arch, CAMPAIGN_RARITY))


static func caps(arch: String) -> Dictionary:
	return ARCH_CAPS.get(arch, {}) as Dictionary


## Виды врагов, доступные объекту k (без Прораба — он «объект особой важности»).
static func enemies_at(k: int) -> Array[String]:
	var out: Array[String] = []
	for e in ENEMY_ORDER:
		if k >= int(ENEMY_FROM[e]):
			out.append(e)
	return out


## Вес вида как «ведущего» состава для архетипа и изюминок карты (§6.4).
static func lead_weight(enemy: String, arch: String, quirks: Array) -> float:
	var likes: Dictionary = ENEMY_LIKES.get(enemy, {})
	var mark := String(likes.get(arch, likes.get("*", "R")))
	if mark == "-":
		return 0.0
	for q: String in ENEMY_LIKES_QUIRK.get(enemy, []):
		if quirks.has(q):
			mark = "F"
	return float(W[mark])


## Можно ли взять изюминку q к архетипу arch на объекте k (всё, кроме биома и памяти).
static func quirk_allowed(q: String, arch: String, k: int) -> bool:
	var c := caps(arch)
	if (CONFLICTS.get(arch, []) as Array).has(q):
		return false
	match q:
		"quiet_road":
			return int(c.get("gates", 1)) >= 2
		"inner_check":
			return int(c.get("gates", 1)) == 1
		"merge_breach":
			return MERGE_BREACH_ARCH.has(arch)
		"mimic_mine":
			return bool(c.get("merge", false))
		"bridge1":
			return BRIDGE1_ARCH.has(arch)
		"runway":
			return RUNWAY_ARCH.has(arch)
		"center":
			return CENTER_ARCH.has(arch)
		"flight":
			return k >= int(ENEMY_FROM["ghost"])
		"boss":
			return BOSS_ARCH.has(arch) and k >= int(ENEMY_FROM["boss"])
		"roster":
			return enemies_at(k).size() > 2
	return true


## Изюминки из одной группы EXCLUSIVE не ставятся вместе.
static func exclusive_clash(a: String, b: String) -> bool:
	for group: Array in EXCLUSIVE:
		if group.has(a) and group.has(b):
			return true
	return false
