class_name PgWaves
extends RefCounted
##
## Волны v2 по карточке и раскладке (BOOK §5.2, §4.1, §6.4, §10 п.4). Числа откалиброваны
## сериями полного бота на «Штатном» (docs/procgen/WAVES.md — таблица до/после и как гонять).
##
## Что решает модуль:
## - БЮДЖЕТ объекта — в «очках» (зомби = 1): BUDGET · budget_mult(D(k)); объект 1 ≈ «Пустырь»
##   (≈ 130 врагов в JSON; «Штатный» проредит массовку темпом LegionChallenge.PACE_THIN). D(k)
##   растёт в среднем на 6–8 % за объект с «пилой» (PgCard), поэтому забег сам доходит до
##   смерти Котла.
## - СОСТАВ: лестница видов PgTables.ENEMY_FROM (1–2 зомби и курьеры, 3+ нотариусы, 4+ щиты,
##   5+ призраки, 6+ юристы, 7+ Прораб «объектом особой важности»); доля «особых» (не массовки)
##   растёт с k; ведущий враг карточки и состав-изюминка перекашивают долю; новый вид первый
##   объект идёт вполсилы («научить, потом проверить»).
## - ТЕМП внутри объекта (напряжение/передышка): разгон, лёгкая волна-передышка в середине,
##   «нажим» перед кульминацией (следующая волна приходит, не дожидаясь клира), кульминация —
##   предпоследняя волна (как в кампании: премия тратится на финал), финал с длинной паузой
##   перед ним. Паузы после клира ≥ 10 с, первая встреча ≤ 25 с (У-10, как считает PgFilter).
## - ДОРОГИ: вес дороги ∝ √длины; приход по дорогам разнесён во времени («откуда рванёт»);
##   у «Клещей» старт одновременный (силы делятся во времени), у «Ложных близнецов» — приход
##   одновременный (топь учитывается). Тихая дорога, трещины, пролёт, горло — по изюминкам.
## - «Схватка» (PvP) волны отсюда НЕ берёт: PgPvp строит черновик по этому модулю, но в игре
##   PvpMaps.adapt_generated заменяет его расписанием «Дуэли» (B-291) — менять PvP здесь нечего.
##

## Бюджет объекта 1 в очках (зомби = 1): «Пустырь» — 131 враг (wasteland.json).
const BUDGET := 130.0
## Множитель бюджета от D(k) — «колено» (budget_mult): до D_KNEE круто (D^GAMMA), дальше
## полого (D^GAMMA_LATE). Почему не одна степень: серии (WAVES.md) — полный бот держит
## объекты 4–8 почти всегда (v0: 38/40 побед), а к 16–20 и при D^1,4 уже карты 0/5.
## v2 (03.10, экономика после economy-mana): v1c (2,6 / 1,55 / 0,35) бот проходил 95/96 карт
## контроля gen 5–8; колено круче и позже, плюс темп по k (TEMPO_*). Серии — BALANCE.md 03.10.
## v3 (03.10, подбор цепочкой): три участка вместо двух — круто до D_KNEE, потом средняя степень
## GAMMA_MID до D_KNEE2 (объекты 5–8 тяжелее, чем у v2), дальше почти плато GAMMA_LATE.
const GAMMA := 6.5
const D_KNEE := 1.3
const GAMMA_MID := 2.65
const D_KNEE2 := 1.6
const GAMMA_LATE := 0.2
## Нагрузка архетипа: разброс побед по картам одного k даёт в основном раскладка, а не число
## врагов (серии WAVES.md: «Клещи» 0/5 при бюджете ×1,4, «Спираль» 5/5 с Котлом 200 при ×5,7 —
## одна длинная дорога вокруг Котла). Бюджет умножается на вес архетипа; нет в списке — 1.
const ARCH_LOAD := {"pincers": 0.7, "turnstile": 0.85, "shelves": 0.85, "island": 0.8,
	"hub": 1.2, "relay": 1.5, "spiral": 1.7}
const COST := {"zombie": 1.0, "beetle": 1.0, "signer": 1.4, "shield_inspector": 1.8,
	"ghost": 1.2, "lawyer": 2.5}
## Очки, которые «съедает» Прораб из финальной волны (он и так её суть).
const BOSS_PTS := 20.0
const SPECIALS: Array[String] = ["signer", "shield_inspector", "ghost", "lawyer"]
## Доля особых (не массовки) в очках волны: SPEC_BASE + SPEC_SLOPE·(k−1), не выше SPEC_MAX.
## Кампания: «Пустырь» ≈ 7 %, «Развилка» ≈ 30 %, «Болото» ≈ 45 % очков.
const SPEC_BASE := 0.08
const SPEC_SLOPE := 0.03
const SPEC_MAX := 0.42
## Доля курьеров в массовке (ведущий «курьер» — ×LEAD_MULT, «Курьерский день» — ×ROSTER_MULT).
const BEETLE_FRAC := 0.18
const BEETLE_FRAC_MAX := 0.55
## Вес вида среди особых до перекосов.
const SPEC_W := {"signer": 1.0, "shield_inspector": 0.8, "ghost": 1.0, "lawyer": 0.35}
const LEAD_MULT := 2.2
const ROSTER_MULT := 3.5
## Состав-изюминка — особых больше за счёт массовки.
const ROSTER_SPEC := 1.4
## Первый объект нового вида — вполсилы, дальше +NEW_KIND_STEP за объект до полной силы.
const NEW_KIND_W := 0.5
const NEW_KIND_STEP := 0.25
const ZOMBIE_SPEED := 34.0
const INTERVAL := {"zombie": 0.5, "beetle": 0.9, "signer": 1.5, "shield_inspector": 1.2,
	"ghost": 1.0, "lawyer": 3.0}
## Порядок выхода внутри волны: массовка впереди, особые за ней (как в кампании).
const DELAY := {"zombie": 0.0, "beetle": 3.0, "signer": 5.25, "shield_inspector": 1.0,
	"ghost": 7.0, "lawyer": 12.0}
## Разброс выхода группы, с: колонны разных видов не стартуют секунда в секунду.
const DELAY_JITTER := 1.5
## На нескольких дорогах колонны реже: общий поток тот же, а колонна не сливается в сплошную.
const MULTI_ROAD_INTERVAL := 1.3
const LAWYER_MAX := 2
const BOSS_DELAY := 6.0

## Число волн: 5, +1 при D ≥ WAVES_D[0], +1 при D ≥ WAVES_D[1], +1 у Прораба; не больше 8.
const WAVES := Vector2i(5, 8)
const WAVES_D: Array[float] = [1.35, 1.9]
## Форма объекта (напряжение/передышка): база растёт от 1 до 1 + RAMP; множители ролей волн.
const RAMP := 1.5
const FIRST_MULT := 0.6
const REST_MULT := 0.6
const CLIMAX_MULT := 1.4
const FINAL_MULT := 0.9
## Паузы после клира (тест карт: ≥ 10 с); перед финалом — передышка после кульминации.
const FIRST_PAUSE := 3.0
const PAUSE := 10.0
const PAUSE_AFTER_CLIMAX := 15.0
## next_in (следующая волна, не дожидаясь клира) = оценка длительности волны × роль, в пределах.
const NEXT_IN := Vector2(30.0, 90.0)
const NEXT_FIRST := 0.9
const NEXT_PUSH := 0.7
const NEXT_REST := 1.3
const NEXT_CLIMAX := 1.3
## Темп растёт с k: next_in × (1 − TEMPO_SLOPE·(k − TEMPO_FROM)), не ниже TEMPO_MIN — волны
## наползают друг на друга, а не только толстеют.
const TEMPO_FROM := 3
const TEMPO_SLOPE := 0.1
const TEMPO_MIN := 0.6
## Разнос прихода по дорогам, с (свой на волну) и потолок сдвига старта.
const STAGGER := Vector2(4.0, 9.0)
## Архетип со стартом одновременно по всем дорогам («Клещи с опозданием», BOOK §3.2 №11).
const SYNC_START := "pincers"
const OFFSET_MAX := 20.0
## Первая встреча ≤ 25 с (У-10); целимся в 20 — запас на толкотню у ворот.
const FIRST_CONTACT := 20.0
## Группа первой волны не стартует ближе этого к Котлу.
const AT_TAIL := 240.0
const SAMPLE := 16.0
## Трещины: выход не раньше 10 с (предупреждение BREACH_WARN_TIME), доля очков волны на них.
const BREACH_DELAY := 12.0
const BREACH_SHARE := 0.3
const BREACH_BEETLE := 0.3
## «Призрачный пролёт»: доля призраков волны, летящих трассой пролёта.
const FLIGHT_SHARE := 0.5
const FLIGHT_DELAY := Vector2(2.0, 8.0)
## Уровни поверх (LegionChallenge): часть особых кульминации — группой tier 1 (её нет у
## «Стажёра»), и сверх бюджета — зомби tier 2 (только «Ад»), выходят после основной колонны.
const TIER1_FRAC := 0.3
const TIER2_FRAC := 0.2


## Волны карты. Пишет в map.procgen: "quiet" (тихая дорога) и "waves" (бюджет и роли волн —
## отладка и тесты).
static func build(map: Dictionary, card: Dictionary, rng: RandomNumberGenerator) -> Array:
	var k := int(card.get("k", 1))
	var d := float(card.get("difficulty", 1.0))
	var quirks: Array = card.get("quirks", [])
	var boss := bool(card.get("boss", false))
	var roads: Array = map["roads"]
	var n := clampi(WAVES.x + int(d >= WAVES_D[0]) + int(d >= WAVES_D[1]) + int(boss),
		WAVES.x, WAVES.y)
	var climax := n - 2
	var rest := rng.randi_range(2, climax - 1) if climax - 1 >= 2 else -1
	var shares := _shares(n, climax, rest)
	var total := BUDGET * budget_mult(d) \
		* float(ARCH_LOAD.get(String(card.get("archetype", "")), 1.0))
	var sum := 0.0
	for s: float in shares:
		sum += s
	var quiet := ""
	var quiet_from := 99
	if quirks.has("quiet_road") and roads.size() >= 2:
		quiet = String(roads[rng.randi_range(1, roads.size() - 1)]["id"])
		quiet_from = rng.randi_range(1, climax - 1)
		map["procgen"]["quiet"] = {"road": quiet, "from_wave": quiet_from + 1}
	var info := _roads_info(map)
	var mean_t := 0.0
	for r: Dictionary in roads:
		mean_t += float(info[r["id"]]["t"])
	mean_t /= roads.size()
	var spec := _spec_weights(card, k)
	var spec_frac := minf(SPEC_MAX, SPEC_BASE + SPEC_SLOPE * (k - 1))
	if String(card.get("roster", "")) != "":
		spec_frac = minf(SPEC_MAX, spec_frac * ROSTER_SPEC)
	var beetle_frac := _beetle_frac(card)
	var has_breaches := not (map.get("breaches", []) as Array).is_empty()
	var tempo := maxf(TEMPO_MIN, 1.0 - TEMPO_SLOPE * maxi(0, k - TEMPO_FROM))
	var waves: Array = []
	for i in n:
		var pts := total * shares[i] / sum
		var last := i == n - 1
		var active: Array[String] = []
		for r: Dictionary in roads:
			if String(r["id"]) != quiet or i >= quiet_from:
				active.append(String(r["id"]))
		# первая волна — старт одновременный: разнос по дорогам съел бы бюджет первой встречи
		var offs := _offsets(active, info, SYNC_START if i == 0
			else String(card.get("archetype", "")), rng)
		var groups: Array = []
		if last and boss:
			pts = maxf(pts - BOSS_PTS, pts * 0.5)
		var breach_pts := 0.0
		if has_breaches and _breach_wave(quirks, i, climax, last):
			breach_pts = pts * BREACH_SHARE
			_breach_groups(groups, map, breach_pts)
		var spec_pts := 0.0 if i == 0 else (pts - breach_pts) * spec_frac
		var mass_pts := pts - breach_pts - spec_pts
		var zc := int(round(mass_pts * (1.0 - beetle_frac)))
		_spread(groups, "zombie", zc, active, offs, info, [], rng)
		_spread(groups, "beetle", int(round(mass_pts * beetle_frac)), active, offs, info, [], rng)
		if i == climax:
			_tier_groups(groups, "zombie", int(round(zc * TIER2_FRAC)), 2, BREACH_DELAY, active,
				offs, info, [], rng)
		if spec_pts > 0.0:
			_specials(groups, spec, spec_pts, i == climax, active, offs, info, map, quirks, rng)
		if last and boss:
			groups.append({"road": _longest(active, info), "type": "boss", "count": 1,
				"interval": 0.98, "delay": BOSS_DELAY})
		var pause := PAUSE_AFTER_CLIMAX if i == climax + 1 else PAUSE
		var wave := {"pause": FIRST_PAUSE if i == 0 else pause, "groups": groups}
		if i == climax:
			wave["climax"] = true
		if not last:
			wave["next_in"] = _next_in(groups, mean_t, i, climax, rest, tempo)
		waves.append(wave)
	_first_contact(waves, map)
	map["procgen"]["waves"] = {"version": 2, "budget": snappedf(total, 0.1), "n": n,
		"climax": climax, "rest": rest, "shares": _snapped(shares, sum),
		"spec_frac": snappedf(spec_frac, 0.001)}
	return waves


## Во сколько раз бюджет объекта сложности d больше объекта 1 (d = 1).
static func budget_mult(d: float) -> float:
	if d <= D_KNEE:
		return pow(d, GAMMA)
	var knee := pow(D_KNEE, GAMMA)
	if d <= D_KNEE2:
		return knee * pow(d / D_KNEE, GAMMA_MID)
	return knee * pow(D_KNEE2 / D_KNEE, GAMMA_MID) * pow(d / D_KNEE2, GAMMA_LATE)


## Доли волн: разгон 1 → 1 + RAMP, первая — лёгкая, передышка, кульминация, финал чуть ниже.
static func _shares(n: int, climax: int, rest: int) -> Array[float]:
	var out: Array[float] = []
	for i in n:
		var s := 1.0 + RAMP * i / float(n - 1)
		if i == 0:
			s *= FIRST_MULT
		elif i == rest:
			s *= REST_MULT
		elif i == climax:
			s *= CLIMAX_MULT
		elif i == n - 1:
			s *= FINAL_MULT
		out.append(s)
	return out


static func _snapped(shares: Array[float], sum: float) -> Array:
	var out: Array = []
	for s: float in shares:
		out.append(snappedf(s / sum, 0.001))
	return out


## Трещины (§4.1): «в тылу» — кульминация и финал (как «Пустырь»; PgFilter: не раньше
## кульминации), «на слиянии» — кульминация, «внутренняя проверка» — кульминация и финал.
static func _breach_wave(quirks: Array, i: int, climax: int, last: bool) -> bool:
	if quirks.has("merge_breach"):
		return i == climax
	if quirks.has("rear_breach") or quirks.has("inner_check"):
		return i == climax or (last and i > climax)
	return false


static func _breach_groups(groups: Array, map: Dictionary, pts: float) -> void:
	var brs: Array = map.get("breaches", [])
	var per := pts / brs.size()
	for br: Dictionary in brs:
		var z := maxi(2, int(round(per * (1.0 - BREACH_BEETLE))))
		var b := maxi(1, int(round(per * BREACH_BEETLE)))
		groups.append({"road": br["road"], "breach": br["id"], "type": "zombie", "count": z,
			"interval": INTERVAL["zombie"], "delay": BREACH_DELAY})
		groups.append({"road": br["road"], "breach": br["id"], "type": "beetle", "count": b,
			"interval": INTERVAL["beetle"], "delay": BREACH_DELAY + 1.0})


## Веса особых видов объекта: лестница видов, ведущий враг, состав-изюминка, новичок вполсилы.
static func _spec_weights(card: Dictionary, k: int) -> Dictionary:
	var foes: Array = card.get("foes", [])
	var lead := String(card.get("lead", "zombie"))
	var roster := String(card.get("roster", "")) != ""
	var out := {}
	for t in SPECIALS:
		if not foes.has(t):
			continue
		var w := float(SPEC_W[t])
		if t == lead:
			w *= ROSTER_MULT if roster else LEAD_MULT
		var since := k - int(PgTables.ENEMY_FROM.get(t, 1))
		w *= minf(1.0, NEW_KIND_W + NEW_KIND_STEP * since)
		out[t] = w
	return out


static func _beetle_frac(card: Dictionary) -> float:
	if String(card.get("lead", "")) != "beetle":
		return BEETLE_FRAC
	var m := ROSTER_MULT if String(card.get("roster", "")) != "" else LEAD_MULT
	return minf(BEETLE_FRAC_MAX, BEETLE_FRAC * m)


## Особые волны: число по очкам и весам; часть кульминации — группой tier 1 («Стажёр» её не
## видит). Щиты идут через горло, призраки частью летят пролётом.
static func _specials(groups: Array, spec: Dictionary, pts: float, climax: bool,
		active: Array[String], offs: Dictionary, info: Dictionary, map: Dictionary,
		quirks: Array, rng: RandomNumberGenerator) -> void:
	var wsum := 0.0
	for t: String in spec:
		wsum += float(spec[t])
	if wsum <= 0.0:
		return
	var throat: Array[String] = []
	if quirks.has("throat") and map["procgen"].has("throat"):
		var th: Dictionary = map["procgen"]["throat"]
		for r: String in th.get("roads", [th["road"]]):
			if active.has(r):
				throat.append(r)
	var flights: Array[String] = []
	for f: Dictionary in map.get("flights", []):
		flights.append(String(f["id"]))
	for t: String in spec:
		var cnt := int(round(pts * float(spec[t]) / wsum / float(COST[t])))
		# вид из состава объекта хоть раз выходит — в кульминации (иначе редкий юрист теряется
		# в округлении, и лестница видов на деле не работает)
		if climax:
			cnt = maxi(cnt, 1)
		if t == "lawyer":
			cnt = mini(cnt, LAWYER_MAX)
		if cnt <= 0:
			continue
		var lanes: Array[String] = throat if t == "shield_inspector" and not throat.is_empty() \
			else active
		var fly: Array[String] = flights if t == "ghost" else ([] as Array[String])
		var tier1 := int(round(cnt * TIER1_FRAC)) if climax and t != "lawyer" else 0
		_spread(groups, t, cnt - tier1, lanes, offs, info, fly, rng)
		_tier_groups(groups, t, tier1, 1, 0.0, lanes, offs, info, fly, rng)


## Группы уровня (поле "tier" — LegionChallenge.apply_map выкидывает их ниже уровня).
static func _tier_groups(groups: Array, t: String, cnt: int, tier: int, later: float,
		lanes: Array[String], offs: Dictionary, info: Dictionary, fly: Array[String],
		rng: RandomNumberGenerator) -> void:
	if cnt <= 0:
		return
	var tg: Array = []
	_spread(tg, t, cnt, lanes, offs, info, fly, rng)
	for g: Dictionary in tg:
		g["tier"] = tier
		g["delay"] = snappedf(float(g["delay"]) + later, 0.05)
	groups.append_array(tg)


## Раздать вид по дорогам: вес дороги ∝ √длины (на длинной больше времени бить колонну),
## старт — свой сдвиг дороги (offs); призраки частью летят трассами пролёта.
static func _spread(groups: Array, t: String, cnt: int, lanes: Array[String], offs: Dictionary,
		info: Dictionary, fly: Array[String], rng: RandomNumberGenerator) -> void:
	if cnt <= 0 or lanes.is_empty():
		return
	var n_fly := int(round(cnt * FLIGHT_SHARE)) if not fly.is_empty() else 0
	var ws: Array[float] = []
	var wsum := 0.0
	for r in lanes:
		var w := sqrt(float(info[r]["len"]))
		ws.append(w)
		wsum += w
	var counts := _apportion(cnt - n_fly, ws, wsum)
	var interval := float(INTERVAL[t]) * (1.0 if lanes.size() == 1 else MULTI_ROAD_INTERVAL)
	for j in lanes.size():
		if counts[j] <= 0:
			continue
		var delay := float(DELAY[t]) + float(offs.get(lanes[j], 0.0)) \
			+ rng.randf_range(0.0, DELAY_JITTER)
		groups.append({"road": lanes[j], "type": t, "count": counts[j],
			"interval": snappedf(interval, 0.01), "delay": snappedf(delay, 0.05)})
	for j in fly.size():
		var c := n_fly / fly.size() + (1 if j < n_fly % fly.size() else 0)
		if c <= 0:
			continue
		groups.append({"road": fly[j], "type": t, "count": c,
			"interval": snappedf(float(INTERVAL[t]), 0.01),
			"delay": snappedf(float(DELAY[t]) + rng.randf_range(FLIGHT_DELAY.x, FLIGHT_DELAY.y),
				0.05)})


## Целые доли по весам без потери суммы (остаток — самым большим дробным частям).
static func _apportion(n: int, ws: Array[float], wsum: float) -> Array[int]:
	var out: Array[int] = []
	var fr: Array[float] = []
	var left := n
	for w in ws:
		var x := n * w / wsum
		out.append(int(x))
		fr.append(x - int(x))
		left -= int(x)
	while left > 0:
		var best := 0
		for j in fr.size():
			if fr[j] > fr[best]:
				best = j
		out[best] += 1
		fr[best] = -1.0
		left -= 1
	return out


## Сдвиг старта по дорогам волны. «Клещи» — старт одновременный (силы делятся во времени,
## BOOK §3.2 №11), «Ложные близнецы» — приход одновременный (№12, топь учтена), прочие —
## приход по дорогам разнесён на STAGGER в случайном порядке: «откуда рванёт сейчас».
static func _offsets(active: Array[String], info: Dictionary, arch: String,
		rng: RandomNumberGenerator) -> Dictionary:
	var out := {}
	if active.size() <= 1 or arch == SYNC_START:
		for r in active:
			out[r] = 0.0
		return out
	var order: Array[String] = active.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	var stagger := 0.0 if arch == "twins" else rng.randf_range(STAGGER.x, STAGGER.y)
	var lo := INF
	for i in order.size():
		var r := order[i]
		out[r] = stagger * i - float(info[r]["t"])
		lo = minf(lo, float(out[r]))
	for r: String in out:
		out[r] = minf(float(out[r]) - lo, OFFSET_MAX)
	return out


## Длина и время пути зомби по каждой дороге (топь ×SWAMP_MULT), дуга первой встречи (как
## PgFilter.first_contact: первый рубеж бота на дороге, без рубежа — Котёл).
static func _roads_info(map: Dictionary) -> Dictionary:
	var swamps: Array[PackedVector2Array] = []
	for poly: Array in map.get("swamp", []):
		swamps.append(_path(poly))
	var out := {}
	for r: Dictionary in map["roads"]:
		var path := _path(r["path"])
		var total := PgGeom.length(path)
		out[String(r["id"])] = {"path": path, "len": total, "swamps": swamps,
			"t": _travel(path, 0.0, total, ZOMBIE_SPEED, swamps), "meet": _meet(path, map)}
	return out


static func _path(src: Array) -> PackedVector2Array:
	var p := PackedVector2Array()
	for q: Array in src:
		p.append(Vector2(q[0], q[1]))
	return p


static func _travel(path: PackedVector2Array, from: float, to: float, speed: float,
		swamps: Array[PackedVector2Array]) -> float:
	var t := 0.0
	var s := from
	while s < to:
		var step := minf(SAMPLE, to - s)
		var mult := 1.0
		var p := PgGeom.point_at(path, s + step * 0.5)
		for sw in swamps:
			if Geometry2D.is_point_in_polygon(p, sw):
				mult = LegionCfg.SWAMP_MULT
				break
		t += step / (speed * mult)
		s += step
	return t


static func _meet(path: PackedVector2Array, map: Dictionary) -> float:
	var best := PgGeom.length(path)
	var base := 0.0
	for i in range(1, path.size()):
		for bl: Dictionary in map.get("bot_lines", []):
			var hit: Variant = Geometry2D.segment_intersects_segment(path[i - 1], path[i],
				Vector2(bl["a"][0], bl["a"][1]), Vector2(bl["b"][0], bl["b"][1]))
			if hit != null:
				best = minf(best, base + path[i - 1].distance_to(hit))
		base += path[i - 1].distance_to(path[i])
	return best


static func _longest(active: Array[String], info: Dictionary) -> String:
	var best := active[0]
	for r in active:
		if float(info[r]["len"]) > float(info[best]["len"]):
			best = r
	return best


## next_in: оценка длительности волны (путь + выход колонн) × роль волны. «Нажим» перед
## кульминацией — следующая приходит на хвост; после передышки и кульминации — дольше.
static func _next_in(groups: Array, mean_t: float, i: int, climax: int, rest: int,
		tempo: float) -> float:
	var span := 0.0
	for g: Dictionary in groups:
		span = maxf(span, float(g.get("delay", 0.0)) + float(g.get("interval", 1.0))
			* (int(g.get("count", 1)) - 1))
	var mult := 1.0
	if i == 0:
		mult = NEXT_FIRST
	elif i == climax - 1:
		mult = NEXT_PUSH
	elif i == rest:
		mult = NEXT_REST
	elif i == climax:
		mult = NEXT_CLIMAX
	return snappedf(clampf((0.5 * mean_t + span) * mult, NEXT_IN.x, NEXT_IN.y) * tempo, 1.0)


## У-10: первая встреча ≤ 25 с — так же, как её меряет фильтр (PgFilter.first_contact): от
## выхода группы до первого рубежа бота на её дороге, скорость вида из LegionCfg.FOES, в топи
## вдвое медленнее. Дольше — группа первой волны выходит дальше по дороге (`at`, как «Пустырь»).
static func _first_contact(waves: Array, map: Dictionary) -> void:
	if waves.is_empty():
		return
	var paths := {}
	for r: Dictionary in map["roads"]:
		var p := PackedVector2Array()
		for q: Array in r["path"]:
			p.append(Vector2(q[0], q[1]))
		paths[r["id"]] = p
	var swamp: Array[PackedVector2Array] = []
	for raw: Array in map.get("swamp", []):
		var poly := PackedVector2Array()
		for q: Array in raw:
			poly.append(Vector2(q[0], q[1]))
		swamp.append(poly)
	for g: Dictionary in waves[0]["groups"]:
		if not paths.has(g["road"]) or g.has("breach"):
			continue
		var path: PackedVector2Array = paths[g["road"]]
		var speed := float(LegionCfg.FOES.get(String(g["type"]), {}).get("speed", 34.0))
		var budget := FIRST_CONTACT - float(waves[0].get("pause", FIRST_PAUSE)) \
			- float(g.get("delay", 0.0))
		var meet := _meet_at(path, map, 0.0)
		if _walk_time(path, 0.0, meet, speed, swamp) <= budget:
			continue
		# сдвигаем выход вперёд, пока время до рубежа не уложится; рубеж считаем заново —
		# выход мог оказаться за первым рубежом
		var at := 0.0
		var total := PgGeom.length(path)
		while at < total - AT_TAIL:
			at += SAMPLE
			meet = _meet_at(path, map, at)
			if _walk_time(path, at, meet, speed, swamp) <= budget:
				break
		g["at"] = int(clampf(at, 0.0, total - AT_TAIL))


## Первый рубеж бота, пересекающий дорогу не раньше at (иначе — конец дороги).
static func _meet_at(path: PackedVector2Array, map: Dictionary, at: float) -> float:
	var best := PgGeom.length(path)
	var base := 0.0
	for i in range(1, path.size()):
		for bl: Dictionary in map.get("bot_lines", []):
			var hit: Variant = Geometry2D.segment_intersects_segment(path[i - 1], path[i],
				Vector2(bl["a"][0], bl["a"][1]), Vector2(bl["b"][0], bl["b"][1]))
			if hit != null:
				var arc := base + path[i - 1].distance_to(hit)
				if arc >= at:
					best = minf(best, arc)
		base += path[i - 1].distance_to(path[i])
	return best


static func _walk_time(path: PackedVector2Array, from: float, to: float, speed: float,
		swamp: Array[PackedVector2Array]) -> float:
	var t := 0.0
	var s := from
	while s < to:
		var step := minf(SAMPLE, to - s)
		var p := PgGeom.point_at(path, s + step * 0.5)
		var mult := 1.0
		for poly in swamp:
			if Geometry2D.is_point_in_polygon(p, poly):
				mult = LegionCfg.SWAMP_MULT
		t += step / (speed * mult)
		s += step
	return t
