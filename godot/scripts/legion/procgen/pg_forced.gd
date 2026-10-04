class_name PgForced
extends RefCounted
##
## «Заданная карточка» (D-0927-91: на ней будет стоять перегенерированная кампания). Правило:
## заданные поля — закон; незаданные дотягиваются из обычной карточки объекта k ТОЛЬКО
## совместимыми (таблицы BOOK §6.1–6.3 и ограничения layout D-0927-101) и перетягиваются, если
## раскладка не сложилась: сперва изюминки, затем архетип и биом. Пустая карта — только когда
## задано невозможное (problem() называет причину).
##
## Ключи: biome, archetype, quirks, lead (или lead_enemy), side (или cauldron_side: left /
## right / center), mirror, flip, difficulty, foes, boss, roster.
##

## Сколько вариантов незаданных полей перебирать (каждому — несколько попыток раскладки).
const MAX_VARIANTS := 12
const SIDES: Array[String] = ["left", "right", "center"]


## Нормализованные заданные поля (синонимы ключей → одно имя).
static func normalize(forced: Dictionary) -> Dictionary:
	var f := forced.duplicate(true)
	if f.has("lead_enemy"):
		f["lead"] = f["lead_enemy"]
		f.erase("lead_enemy")
	if f.has("cauldron_side"):
		f["side"] = f["cauldron_side"]
		f.erase("cauldron_side")
	if f.has("boss") and bool(f["boss"]) and f.has("quirks") and not (f["quirks"] as Array).has(
			"boss"):
		(f["quirks"] as Array).append("boss")
	return f


## Изюминка встаёт на архетип по устройству (без лестницы по k: заданная карточка может
## поставить пролёт и Прораба раньше объекта, где их даёт забег).
static func quirk_fits(q: String, arch: String) -> bool:
	return PgTables.QUIRK.has(q) and PgTables.quirk_allowed(q, arch, 99)


static func _arch_ok(arch: String, f: Dictionary) -> bool:
	if not PgTables.ARCH.has(arch):
		return false
	if f.has("biome") and PgTables.arch_cell(arch, String(f["biome"])) == "-":
		return false
	for q: String in f.get("quirks", []):
		if not quirk_fits(q, arch):
			return false
	var caps := PgTables.caps(arch)
	match String(f.get("side", "")):
		"right":
			return bool(caps.get("mirror", false))
		"center":
			return PgTables.CENTER_ARCH.has(arch)
		"left":
			return not bool(caps.get("center", false))
	return not (bool(f.get("mirror", false)) and not bool(caps.get("mirror", false)))


static func _biome_ok(biome: String, arch: String, quirks: Array) -> bool:
	if not PgTables.BIOMES.has(biome) or PgTables.arch_cell(arch, biome) == "-":
		return false
	for q: String in quirks:
		if PgTables.quirk_cell(q, biome) == "-":
			return false
	return true


## "" — заданное выполнимо; иначе понятная причина.
static func problem(forced: Dictionary) -> String:
	var f := normalize(forced)
	if f.has("biome") and not PgTables.BIOMES.has(String(f["biome"])):
		return "неизвестный биом «%s»" % f["biome"]
	if f.has("archetype") and not PgTables.ARCH.has(String(f["archetype"])):
		return "неизвестный архетип «%s»" % f["archetype"]
	if f.has("side") and not SIDES.has(String(f["side"])):
		return "сторона Котла — left / right / center, а не «%s»" % f["side"]
	var quirks: Array = f.get("quirks", [])
	for i in quirks.size():
		if not PgTables.QUIRK.has(String(quirks[i])):
			return "неизвестная изюминка «%s»" % quirks[i]
		for j in range(i + 1, quirks.size()):
			if PgTables.exclusive_clash(String(quirks[i]), String(quirks[j])):
				return "изюминки %s и %s не ставятся вместе (§6.3)" % [quirks[i], quirks[j]]
	if f.has("biome"):
		for q: String in quirks:
			if PgTables.quirk_cell(q, String(f["biome"])) == "-":
				return "изюминка %s не бывает в биоме %s (§6.2)" % [q, f["biome"]]
	if f.has("archetype"):
		return "" if _arch_ok(String(f["archetype"]), f) \
			else "архетип %s несовместим с заданным (биом §6.1, изюминки §6.3, сторона Котла)" \
			% f["archetype"]
	for a in PgTables.ARCH_ORDER:
		if _arch_ok(a, f):
			return ""
	return "ни один архетип не совместим с заданными полями"


## Варианты карточки по порядку попыток: первый — ближайший к обычной карточке объекта, дальше
## — с перетянутыми незаданными полями (изюминки, потом архетип и биом).
static func variants(base: Dictionary, forced: Dictionary, rng: RandomNumberGenerator) \
		-> Array[Dictionary]:
	var f := normalize(forced)
	var out: Array[Dictionary] = []
	var archs := _arch_order(base, f, rng)
	for arch: String in archs:
		for biome: String in _biome_order(base, f, arch, rng):
			for quirks: Array in _quirk_sets(base, f, arch, biome, rng):
				out.append(_complete(base, f, arch, biome, quirks))
				if out.size() >= MAX_VARIANTS:
					return out
	return out


static func _arch_order(base: Dictionary, f: Dictionary, rng: RandomNumberGenerator) -> Array:
	if f.has("archetype"):
		return [String(f["archetype"])]
	var out: Array = []
	if _arch_ok(String(base["archetype"]), f):
		out.append(String(base["archetype"]))
	for a: String in PgRng.shuffled(rng, PgTables.ARCH_ORDER):
		if not out.has(a) and _arch_ok(a, f):
			out.append(a)
	return out.slice(0, 4)


static func _biome_order(base: Dictionary, f: Dictionary, arch: String,
		rng: RandomNumberGenerator) -> Array:
	var forced_q: Array = f.get("quirks", [])
	if f.has("biome"):
		return [String(f["biome"])]
	var out: Array = []
	if _biome_ok(String(base["biome"]), arch, forced_q):
		out.append(String(base["biome"]))
	for b: String in PgRng.shuffled(rng, PgTables.BIOMES):
		if not out.has(b) and _biome_ok(b, arch, forced_q):
			out.append(b)
	return out.slice(0, 2)


## Наборы изюминок: заданные — как есть; иначе совместимая часть изюминок цепочки, затем по
## одной совместимой изюминке (у спирали и звезды «Котёл в центре» — всегда, §4.1).
static func _quirk_sets(base: Dictionary, f: Dictionary, arch: String, biome: String,
		rng: RandomNumberGenerator) -> Array:
	var center := bool(PgTables.caps(arch).get("center", false))
	if f.has("quirks"):
		var q: Array = (f["quirks"] as Array).duplicate()
		if center and not q.has("center"):
			q.append("center")
		return [q]
	var sets: Array = []
	var keep: Array = []
	for q: String in base.get("quirks", []):
		if _quirk_ok(q, arch, biome, keep):
			keep.append(q)
	if center and not keep.has("center"):
		keep.push_front("center")
	if not keep.is_empty():
		sets.append(keep)
	for q: String in PgRng.shuffled(rng, PgTables.QUIRK_ORDER):
		if q == "center" or q == "boss" or not _quirk_ok(q, arch, biome, []):
			continue
		sets.append(["center", q] if center else [q])
	if center:
		sets.append(["center"])
	return sets


static func _quirk_ok(q: String, arch: String, biome: String, have: Array) -> bool:
	if not quirk_fits(q, arch) or PgTables.quirk_cell(q, biome) == "-":
		return false
	for h: String in have:
		if PgTables.exclusive_clash(q, h):
			return false
	return true


static func _complete(base: Dictionary, f: Dictionary, arch: String, biome: String,
		quirks: Array) -> Dictionary:
	var card := base.duplicate(true)
	card.erase("alts")
	card.erase("side")
	for key: String in f:
		card[key] = f[key]
	card["archetype"] = arch
	card["biome"] = biome
	card["quirks"] = quirks.duplicate()
	var caps := PgTables.caps(arch)
	if f.has("side"):
		card["mirror"] = String(f["side"]) == "right"
		card["side"] = f["side"]
	elif not f.has("mirror"):
		card["mirror"] = bool(card.get("mirror", false)) and bool(caps.get("mirror", false))
	card["boss"] = (card["quirks"] as Array).has("boss")
	card["surprise"] = false
	var k := int(card["k"])
	if not f.has("lead") or PgTables.lead_weight(String(card["lead"]), arch, quirks) <= 0.0:
		if not f.has("lead"):
			card["lead"] = _lead(k, arch, quirks, String(card.get("lead", "zombie")))
	if (card["quirks"] as Array).has("roster"):
		if not f.has("roster"):
			card["roster"] = String(PgTables.ROSTERS.get(String(card["lead"]), "notary_week"))
	else:
		card["roster"] = ""
	if not f.has("foes"):
		var foes := PgCard._foes(maxi(k, 1), card)
		for need: String in _needed_foes(card):
			if not foes.has(need):
				foes.append(need)
		card["foes"] = foes
	return PgCard._finish(card, {})


static func _lead(k: int, arch: String, quirks: Array, prefer: String) -> String:
	if PgTables.lead_weight(prefer, arch, quirks) > 0.0 and PgTables.enemies_at(99).has(prefer):
		return prefer
	for e in PgTables.enemies_at(maxi(k, 1)):
		if PgTables.lead_weight(e, arch, quirks) > 0.0:
			return e
	return "zombie"


## Виды, без которых изюминка не работает: пролёт — призраки, состав — ведущий вид.
static func _needed_foes(card: Dictionary) -> Array:
	var out: Array = []
	var quirks: Array = card["quirks"]
	if quirks.has("flight"):
		out.append("ghost")
	if quirks.has("roster"):
		out.append(String(card["lead"]))
	if quirks.has("boss"):
		out.append("boss")
	return out
