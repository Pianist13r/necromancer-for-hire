class_name PgCard
extends RefCounted
##
## Карточка объекта k забега (BOOK §2, §5): биом, архетип, 1–2 изюминки, ведущий враг, сторона
## Котла, необычность, цель N(k), сложность D(k). Карточки дешёвые (без раскладки), поэтому
## цепочка 1…k считается заново при каждом вызове: от неё зависят правило разнообразия и кривые.
##
## Поля карточки: k, biome, archetype, mirror, flip, quirks, roster, lead, side, surprise,
## unusual, target, difficulty, breather, boss, climax, foes (виды врагов объекта).
##

## Сколько кандидатов тянется на объект (§5.2) и предел вытягиваний, если многие отсеяны.
const CANDIDATES := 12
const MAX_DRAWS := 60
## Кривая необычности N(k) = BASE + SLOPE·ln(1+k) + колебание (§5.2).
const N_BASE := 0.15
const N_SLOPE := 0.22
const WOBBLE_STEP := 0.06
const WOBBLE_MAX := 0.12
const BREATHER_DROP := 0.2
const BREATHER_GAP := Vector2i(4, 6)
## Две изюминки — только с N(k) ≥ 0,45 (§5.3).
const TWO_QUIRKS_N := 0.45
## Сложность: тренд +6–8 % за объект, после кульминации следующий на 10–15 % легче (§5.2).
const D_GROWTH := Vector2(0.06, 0.08)
const D_SAW := Vector2(0.85, 0.90)
## Прораб: раз в 6–8 объектов, начиная с k ≥ 7 (§4.1).
const BOSS_FIRST := Vector2i(7, 8)
const BOSS_GAP := Vector2i(6, 8)
## Новизна: +0,05 за каждую ось, не совпавшую с прошлой картой (§5.1).
const NOVELTY := 0.05
const SURPRISE_BONUS := 0.25
const MIRROR_CHANCE := 0.3
## Скидка к расстоянию до цели N(k) для архетипа, которого ещё не было в забеге.
const FRESH := 0.15
const FLIP_CHANCE := 0.5


## Цепочка карточек 1…k. Последняя карточка несёт "alts" — следующие по близости к цели
## кандидаты того же объекта (на случай, если раскладка первой не удастся).
static func chain(run_seed: int, k: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var st := {"wobble": 0.0, "trend": 1.0, "next_breather": -1, "next_boss": -1,
		"last_surprise": -100}
	for i in range(1, k + 1):
		var card := _next(run_seed, i, out, st, i == k)
		out.append(card)
	return out


## Карточка по умолчанию на случай, когда ни один кандидат не прошёл: «передышка», змейка,
## одна спокойная изюминка — годна по построению (STAGE2 §2).
static func calm(k: int, biome: String, difficulty: float) -> Dictionary:
	var quirk := "runway"
	if PgTables.quirk_cell("swamp_road", biome) == "F":
		quirk = "swamp_road"
	return _finish({"k": k, "biome": biome, "archetype": "snake", "mirror": false,
		"flip": false, "quirks": [quirk], "roster": "", "lead": "zombie",
		"breather": true, "boss": false, "target": 0.0, "difficulty": difficulty}, {})


## Карточка с полями, заданными явно (режим «заданной карточки», D-0927-91) — первый вариант
## PgForced.variants: заданное — закон, незаданное — совместимое из карточки объекта k.
static func override(base: Dictionary, forced: Dictionary) -> Dictionary:
	var v := PgForced.variants(base, forced, PgRng.make(int(base["k"]), "forced", 0))
	return v[0] if not v.is_empty() else {}


static func _next(run_seed: int, k: int, prev: Array[Dictionary], st: Dictionary,
		want_alts: bool) -> Dictionary:
	var rng := PgRng.make(run_seed, "card", k)
	st["wobble"] = clampf(float(st["wobble"]) + rng.randf_range(-WOBBLE_STEP, WOBBLE_STEP),
		-WOBBLE_MAX, WOBBLE_MAX)
	if int(st["next_breather"]) < 0:
		st["next_breather"] = rng.randi_range(BREATHER_GAP.x, BREATHER_GAP.y)
		st["next_boss"] = rng.randi_range(BOSS_FIRST.x, BOSS_FIRST.y)
	var breather := k == int(st["next_breather"])
	if breather:
		st["next_breather"] = k + rng.randi_range(BREATHER_GAP.x, BREATHER_GAP.y)
	var target := N_BASE + N_SLOPE * log(1.0 + k) + float(st["wobble"])
	if breather:
		target -= BREATHER_DROP
	if k > 1:
		st["trend"] = float(st["trend"]) * (1.0 + rng.randf_range(D_GROWTH.x, D_GROWTH.y))
	var difficulty := float(st["trend"])
	if not prev.is_empty() and bool(prev[-1].get("climax", false)):
		difficulty *= rng.randf_range(D_SAW.x, D_SAW.y)
	var boss_due := k >= int(st["next_boss"]) and not breather
	var ctx := {"k": k, "target": target, "difficulty": difficulty, "breather": breather,
		"boss": boss_due, "surprise_ok": k >= PgTables.SURPRISE_MIN_K
		and k - int(st["last_surprise"]) >= PgTables.SURPRISE_GAP}
	var cands: Array[Dictionary] = []
	var draws := 0
	while cands.size() < CANDIDATES and draws < MAX_DRAWS:
		draws += 1
		var c := _draw(rng, ctx, prev)
		if not c.is_empty():
			cands.append(c)
	if cands.is_empty() and boss_due:
		# Прораб не встал ни в один архетип (память запретила) — переносится на следующий объект
		ctx["boss"] = false
		boss_due = false
		for i in CANDIDATES:
			var c := _draw(rng, ctx, prev)
			if not c.is_empty():
				cands.append(c)
	var card: Dictionary
	if cands.is_empty():
		var last_biome := String(prev[-1]["biome"]) if not prev.is_empty() else ""
		var biome := "ash" if last_biome != "ash" else "grave"
		card = calm(k, biome, difficulty)
	else:
		# ближе к цели N(k); архетип, которого в забеге ещё не было, — со скидкой FRESH: иначе
		# редкие и необычные (спираль, остров, звезда) до 12-го объекта почти не выходят —
		# «О, необычненько» важнее гладкой кривой (решение Игоря через координатора, 27.09)
		var seen := {}
		for p in prev:
			seen[p["archetype"]] = true
		var score := func(c: Dictionary) -> float:
			return absf(float(c["unusual"]) - target) - (0.0 if seen.has(c["archetype"])
				else FRESH)
		var order := range(cands.size())
		order.sort_custom(func(a: int, b: int) -> bool:
			var da: float = score.call(cands[a])
			var db: float = score.call(cands[b])
			return da < db if da != db else a < b)
		card = cands[order[0]]
		if want_alts:
			var alts: Array = []
			for i in range(1, mini(order.size(), 4)):
				alts.append(cands[order[i]])
			card["alts"] = alts
	if bool(card.get("surprise", false)):
		st["last_surprise"] = k
	if boss_due and bool(card["boss"]):
		st["next_boss"] = k + rng.randi_range(BOSS_GAP.x, BOSS_GAP.y)
	return card


## Один кандидат или {} (отсеян совместимостью, памятью или «сюрпризом»).
static func _draw(rng: RandomNumberGenerator, ctx: Dictionary, prev: Array[Dictionary]) \
		-> Dictionary:
	var k := int(ctx["k"])
	var biomes: Array[String] = []
	for b in PgTables.BIOMES:
		if not _recent(prev, "biome", b, PgTables.WINDOW["biome"]):
			biomes.append(b)
	var biome: String = biomes[rng.randi_range(0, biomes.size() - 1)]
	var archs: Array[String] = []
	var aw: Array = []
	for a in PgTables.ARCH_ORDER:
		if _recent(prev, "archetype", a, PgTables.WINDOW["archetype"]):
			continue
		if bool(ctx["boss"]) and not PgTables.BOSS_ARCH.has(a):
			continue
		# «Котёл в центре» у спирали и звезды — часть архетипа: изюминка не повторяется 4
		if PgTables.caps(a).get("center", false) and _recent(prev, "quirk", "center", 4):
			continue
		archs.append(a)
		aw.append(PgTables.W[PgTables.arch_cell(a, biome)])
	var ai := PgRng.pick_weighted(rng, aw)
	if ai < 0:
		return {}
	var arch: String = archs[ai]
	var card := {"k": k, "biome": biome, "archetype": arch, "target": ctx["target"],
		"difficulty": ctx["difficulty"], "breather": ctx["breather"], "boss": ctx["boss"]}
	card["mirror"] = bool(PgTables.caps(arch).get("mirror", false)) \
		and rng.randf() < MIRROR_CHANCE
	card["flip"] = rng.randf() < FLIP_CHANCE
	var quirks := _pick_quirks(rng, card, ctx, prev)
	if quirks.is_empty():
		return {}
	card["quirks"] = quirks
	card["roster"] = ""
	if quirks.has("roster"):
		var opts: Array[String] = []
		for e in PgTables.enemies_at(k):
			if PgTables.ROSTERS.has(e) and PgTables.lead_weight(e, arch, quirks) > 0.0 \
					and not _recent(prev, "lead", e, PgTables.WINDOW["lead"]):
				opts.append(e)
		if opts.is_empty():
			return {}
		card["lead"] = opts[rng.randi_range(0, opts.size() - 1)]
		card["roster"] = PgTables.ROSTERS[card["lead"]]
	else:
		var leads: Array[String] = []
		var lw: Array = []
		for e in PgTables.enemies_at(k):
			if _recent(prev, "lead", e, PgTables.WINDOW["lead"]):
				continue
			leads.append(e)
			lw.append(PgTables.lead_weight(e, arch, quirks))
		var li := PgRng.pick_weighted(rng, lw)
		if li < 0:
			return {}
		card["lead"] = leads[li]
	card["foes"] = _foes(k, card)
	var surprise := PgTables.arch_cell(arch, biome) == PgTables.SURPRISE
	for q: String in quirks:
		surprise = surprise or PgTables.quirk_cell(q, biome) == PgTables.SURPRISE
	if surprise and not bool(ctx["surprise_ok"]):
		return {}
	card["surprise"] = surprise
	return _finish(card, prev[-1] if not prev.is_empty() else {})


static func _pick_quirks(rng: RandomNumberGenerator, card: Dictionary, ctx: Dictionary,
		prev: Array[Dictionary]) -> Array:
	var k := int(ctx["k"])
	var arch := String(card["archetype"])
	var biome := String(card["biome"])
	var out: Array = []
	if PgTables.caps(arch).get("center", false):
		out.append("center")
	if bool(ctx["boss"]):
		out.append("boss")
	var want := 1
	if bool(ctx["breather"]):
		want = 1
	elif float(ctx["target"]) >= TWO_QUIRKS_N \
			and rng.randf() < clampf((float(ctx["target"]) - 0.35) * 1.5, 0.0, 0.8):
		want = 2
	want = maxi(want, out.size())
	var pool: Array[String] = []
	var pw: Array = []
	for q in PgTables.QUIRK_ORDER:
		if q == "center" or q == "boss" or out.has(q):
			continue
		if bool(ctx["breather"]) and not PgTables.CALM.has(q):
			continue
		if not PgTables.quirk_allowed(q, arch, k):
			continue
		if _recent(prev, "quirk", q, PgTables.WINDOW["quirk"]):
			continue
		pool.append(q)
		pw.append(PgTables.W[PgTables.quirk_cell(q, biome)])
	while out.size() < want:
		var i := PgRng.pick_weighted(rng, pw)
		if i < 0:
			break
		var q := pool[i]
		pw[i] = 0.0
		var clash := false
		for have: String in out:
			clash = clash or PgTables.exclusive_clash(q, have)
		if not clash:
			out.append(q)
	return out if out.size() >= 1 else []


## Состав объекта: лестница видов §5.2, «призрак — никогда на острове» (§6.4), Прораб —
## только «объект особой важности».
static func _foes(k: int, card: Dictionary) -> Array:
	var out: Array = []
	for e in PgTables.enemies_at(k):
		if PgTables.lead_weight(e, String(card["archetype"]), card.get("quirks", [])) > 0.0:
			out.append(e)
	if bool(card.get("boss", false)):
		out.append("boss")
	return out


## Производные поля: сторона Котла, кульминация, необычность (§5.1).
static func _finish(card: Dictionary, last: Dictionary) -> Dictionary:
	var quirks: Array = card["quirks"]
	var arch := String(card["archetype"])
	if not card.has("side"):
		card["side"] = "center" if quirks.has("center") \
			else ("right" if bool(card.get("mirror", false)) else "left")
	if not card.has("foes"):
		card["foes"] = _foes(int(card["k"]), card)
	card["surprise"] = bool(card.get("surprise", false))
	card["climax"] = bool(card.get("boss", false)) or quirks.size() >= 2
	var u := PgTables.arch_rarity(arch)
	if bool(card.get("mirror", false)):
		u += PgTables.MIRROR_BONUS
	for q: String in quirks:
		u += float(PgTables.QUIRK_WEIGHT.get(q, 0.1))
	if card["surprise"]:
		u += SURPRISE_BONUS
	if not last.is_empty():
		for axis: String in ["biome", "archetype", "lead", "side"]:
			if String(card.get(axis, "")) != String(last.get(axis, "")):
				u += NOVELTY
		if not _same_set(quirks, last.get("quirks", [])):
			u += NOVELTY
	card["unusual"] = snappedf(u, 0.001)
	card["target"] = snappedf(float(card.get("target", 0.0)), 0.001)
	card["difficulty"] = snappedf(float(card.get("difficulty", 1.0)), 0.001)
	return card


static func _same_set(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for x: Variant in a:
		if not b.has(x):
			return false
	return true


## Было ли значение оси в последних (window − 1) карточках.
static func _recent(prev: Array[Dictionary], axis: String, value: String, window: int) -> bool:
	var n := prev.size()
	for i in range(maxi(0, n - (window - 1)), n):
		var c: Dictionary = prev[i]
		if axis == "quirk":
			if (c.get("quirks", []) as Array).has(value):
				return true
		elif String(c.get(axis, "")) == value:
			return true
	return false
