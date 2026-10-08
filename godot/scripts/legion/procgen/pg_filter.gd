class_name PgFilter
extends RefCounted
##
## Фильтр годности процедурной карты (BOOK §7 «Правила удобства», §10 «Фильтр годности»).
## Игорь: ни одна карта не должна быть неудобной. Генератор (ProcGen) зовёт check() на каждого
## кандидата: пустой ответ — карта годна; иначе кандидат отбрасывается, а строки объясняют почему
## (правило, число, место).
##
## Что проверяется:
## 1. Все проверки теста карт кампании (LegionMapChecks — тот же код, что у legion_maps_test).
## 2. Жёсткие правила У-1…У-13 книги — геометрией: растр препятствий PgRaster и лучи поперёк дороги
##    по методике замеров книги (comfort_measure.py), чтобы пороги значили то же, что в книге.
## 3. Правила изюминок BOOK §4.1, которые видны по данным (И-…): мост, трещины, мимики, склепы,
##    топь, горло, центр, взлётная полоса, Прораб; часть — только если изюминка есть в
##    procgen.card.quirks (bridge1, inner_check, mimic_mine, recruit_link, coffee).
## 0. Словарь сперва проверяется на форму: битый (нет дорог, точка не пара чисел…) не роняет
##    фильтр, а даёт строки «Словарь: …» (BOOK §10: смоук без SCRIPT ERROR).
##
## Исключения книги — по разметке генератора (договор линий layout ↔ filter, 27.09.2026):
## - «узкое горло»: procgen.card.quirks содержит "throat" И есть procgen.throat {road, roads,
##   from, to, pos} (from/to — px от начала каждой дороги из roads; у турникета горло лежит на
##   общем начале двух дорог) — там пролёт может быть 80–90 px; без разметки горла нет;
## - «спираль»: procgen.card.archetype == "spiral" — извилистость до 4,0.
## Кампанийные карты рисованные и У-правилам не обязаны: тест кампании их не применяет.
##

# ── У-1, У-2: пролёт поперёк дороги ─────────────────────────────────────────
## Шаг выборки по оси дороги — как в comfort_measure.py.
const SAMPLE_STEP := 8.0
## У-1: линия ≥ LINE_MIN (60) плюс толщина и дрожь руки (B-092: «Два отдела»).
const SPAN_MIN := 90.0
## Изюминка «узкое горло» (BOOK §4.1): пролёт 80–90 px на отрезке ≤ 120 px, участок охраны ≤ 150.
const THROAT_SPAN_MIN := 80.0
const THROAT_LEN_MAX := 120.0
const THROAT_GUARD_R := 150.0
## Допуск границ отрезка горла по длине дороги (px).
const THROAT_SNAP := 1.0
## У-2: ≥ 55 % длины каждой дороги — пролёт ≥ 200 px.
const SPAN_WIDE := 200.0
const WIDE_SHARE_MIN := 0.55
## Пороги отчётов книги (§3.1): доля < 76 px — «линия поперёк не рождается».
const SPAN_TIGHT_REPORT := 76.0

# ── У-3: прямые ─────────────────────────────────────────────────────────────
const STRAIGHT_MIN := 140.0
## Свободная полоса сбоку — от края дороги (половина MAP_ROAD_WIDTH), не от оси.
const STRAIGHT_STRIP := 40.0
const STRAIGHTS_MIN := 2
## Поворот меньше этого — ещё прямая (тот же порог, что счёт поворотов в тесте карт).
const TURN_EPS := 0.2

# ── У-4, У-5: участки ───────────────────────────────────────────────────────
const PLOT_ROAD_MIN := 70.0
const PLOT_ROAD_MAX := 140.0
## Ближе PLOT_ROAD_MIN — «рискованный» участок: такой допустим один.
const RISKY_PLOTS_MAX := 1
const RESERVE_R := 250.0

# ── У-6, У-13: HUD и края ───────────────────────────────────────────────────
## Панели HUD, закрывающие арену (BOOK §7 У-6): плашка статов сверху слева (HUD_PLATE_POS 8,5,
## высота 40, ширина 12 + 4·10 + ΣHUD_BLOCK_W = 804 → x 8–812; берём до 820, как layout), превью
## волны (WAVE_PREVIEW_POS 968,12, ширина 300), карточки видов (KIND_BAR_POS 340,654), слоты
## способностей (ui/ability_bar.gd slot_rect: x 966–1264, y 634–698).
const HUD_RECTS: Array[Rect2] = [
	Rect2(0, 0, 820, 50), Rect2(960, 0, 310, 130), Rect2(340, 630, 600, 90), Rect2(960, 630, 310, 90)]
## Свободные отрезки края для ворот: [от, до] по координате вдоль края. Слева и справа — y,
## сверху и снизу — x. Учтены панели и отступ ≥ 60 px от угла (книга: левый 50–700 — угол важнее).
## Верх — от 820, а не 780 книги: плашка статов по замеру кончается на x 812.
const GATE_LEFT := Vector2(60, 660)
const GATE_RIGHT := Vector2(140, 620)
const GATE_TOP := Vector2(820, 950)
const GATE_BOTTOM := Vector2(60, 320)
## Ворота «на краю»: первая точка дороги за кадром или ближе этого к краю.
const GATE_EDGE_TOL := 16.0
## У-13: ничего игрового ближе к краю кадра (CHARGE_EDGE_MARGIN — натиск стопорится там же).
const EDGE_KEEP := 16.0

# ── У-7: читаемость пути ────────────────────────────────────────────────────
const SHARP_TURN := deg_to_rad(60.0)
const SHARP_GAP_MIN := 80.0
## Как искать повороты (зоны, шпилька) — PgTurns.
const EDGE_NEAR := 40.0
const EDGE_RUN_MAX := 200.0
## Две дороги «идут вместе», если хвост (или начало) одной лежит на другой с такой точностью.
const MERGE_EPS := 2.0
## Вершины дороги ближе этого друг к другу подряд — одна вершина (повтор в данных).
const DUP_EPS := 0.01

# ── У-8: Котёл ──────────────────────────────────────────────────────────────
const CAULDRON_EDGE_MIN := 110.0
const CAULDRON_FREE_R := 90.0
## Шаг проверки свободного круга по растру.
const CAULDRON_PROBE := 4
const LAST_STRAIGHT_MIN := 120.0

# ── У-9: пролёт призраков ───────────────────────────────────────────────────
const FLIGHT_LAST_MIN := 150.0

# ── У-10: темп ──────────────────────────────────────────────────────────────
const FIRST_CONTACT_MAX := 25.0
## Запас шагов сверх длины дороги в счёте встречи (предел цикла — от длины, не от данных).
const LOOP_SLACK := 16

# ── У-11: извилистость ──────────────────────────────────────────────────────
const DETOUR_MIN := 1.4
const DETOUR_MAX := 2.6
const DETOUR_MAX_SPIRAL := 4.0

# ── У-12: проходы вне дорог ─────────────────────────────────────────────────
const PASSAGE_MIN := 60.0
## Препятствия ближе этого сомкнуты (общая грань — не щель).
const GAP_TOUCH := 1.0
## Толщина полос за краем кадра, которыми край изображает стену для У-12.
const FRAME_BAND := 20.0

# ── Изюминки по данным (BOOK §4.1; id изюминок и архетипов — как у layout) ──
## «Топь на дороге»: не на последних 250 px к Котлу.
const SWAMP_TAIL := 250.0

# ── score(): мягкие правила ─────────────────────────────────────────────────
const WALKABLE_LO := 0.65
const WALKABLE_HI := 0.92
## Выход за коридор на столько (доля) — штраф 1.
const WALKABLE_SLACK := 0.15
## «Своя история» участка: что-то рядом — декор, предмет, склеп, мимик или край препятствия.
const STORY_R := 110.0
const SCORE_W_WALKABLE := 0.5
const SCORE_W_STORY := 0.5


## Годна ли карта: пустой массив — годна; иначе по строке на нарушение («У-1: …», «Тест: …»).
static func check(map: Dictionary) -> Array[String]:
	return evaluate(map)["problems"]


## Генератору достаточно первого отказа; полный check сохраняет все причины для редактора.
static func accepts(map: Dictionary) -> bool:
	return rejection(map).is_empty()


static func rejection(map: Dictionary) -> Array[String]:
	var result: Variant = _analyze(map, true)
	if result is Dictionary and result.get("problems", null) is Array:
		return result["problems"]
	return ["Фильтр: быстрый разбор оборвался — карта не проверена"]


## Штраф мягких правил 0…1 (меньше — лучше): доля проходимого 65–92 % и «своя история» у участков.
## «Дорога — самый светлый объект» здесь не проверяется: это картинка (PgArt), а не данные.
static func score(map: Dictionary) -> float:
	return evaluate(map)["score"]


## Числа для калибровки и отчётов (см. ключи в _measure_dict).
static func measure(map: Dictionary) -> Dictionary:
	return evaluate(map)["measure"]


## Всё сразу одним разбором — генератору, которому нужны и годность, и штраф. Если разбор
## оборвался ошибкой скрипта, ответ — нарушение, а не «годна» (при сомнении — отбраковать).
static func evaluate(map: Dictionary) -> Dictionary:
	var r: Variant = _analyze(map)
	if r is Dictionary and (r as Dictionary).get("problems", null) is Array \
			and (r as Dictionary).get("score", null) is float \
			and (r as Dictionary).get("measure", null) is Dictionary:
		return r
	var broken: Array[String] = ["Фильтр: разбор карты оборвался ошибкой — карта не проверена"]
	return {"problems": broken, "score": 1.0, "measure": {"invalid": true, "problems": 1}}


## Этапы разбора по порядку: [имя, Callable(ctx, problems) -> bool]. Этап, не вернувший true
## (оборвался SCRIPT ERROR), останавливает разбор строкой «Фильтр: …».
static func _stages(map: Dictionary) -> Array:
	return [
		["рельеф", func(c: Dictionary, _p: Array[String]) -> bool:
			c["terrain"] = LegionTerrain.new().setup(map)
			c["raster"] = PgRaster.build(map)
			c["cauldron"] = LegionMapChecks.v(map.cauldron)
			c["roads"] = _dedup_roads(LegionMapChecks.road_paths(map))
			c["throat"] = _throat(map)
			c["spiral"] = PgQuirkRules.archetype(map) == "spiral"
			return c["terrain"] != null and c["raster"] != null],
		["тест карт", func(c: Dictionary, p: Array[String]) -> bool: return _test_checks(c, p)],
		["выборка", func(c: Dictionary, _p: Array[String]) -> bool:
			c["samples"] = _samples(c)
			c["junctions"] = PgQuirkRules.junctions(c["roads"])
			return c["samples"] is Dictionary and c["junctions"] is Array],
		["У-1, У-2", func(c: Dictionary, p: Array[String]) -> bool: return _rule_spans(c, p)],
		["У-3", func(c: Dictionary, p: Array[String]) -> bool: return _rule_straights(c, p)],
		["У-4, У-5", func(c: Dictionary, p: Array[String]) -> bool: return _rule_plots(c, p)],
		["У-6", func(c: Dictionary, p: Array[String]) -> bool: return _rule_gates(c, p)],
		["У-7", func(c: Dictionary, p: Array[String]) -> bool: return _rule_path_reading(c, p)],
		["У-8", func(c: Dictionary, p: Array[String]) -> bool: return _rule_cauldron(c, p)],
		["У-9", func(c: Dictionary, p: Array[String]) -> bool: return _rule_flights(c, p)],
		["У-10", func(c: Dictionary, p: Array[String]) -> bool:
			c["contact"] = first_contact(map, c["roads"], c["terrain"])
			if is_nan(float(c["contact"])):
				return false
			if float(c["contact"]) > FIRST_CONTACT_MAX:
				p.append("У-10: первая встреча через %.0f с (≤ %.0f)"
					% [c["contact"], FIRST_CONTACT_MAX])
			return true],
		["У-11", func(c: Dictionary, p: Array[String]) -> bool: return _rule_detour(c, p)],
		["У-12", func(c: Dictionary, p: Array[String]) -> bool: return PgSpaceRules.passages(c, p)],
		["У-13", func(c: Dictionary, p: Array[String]) -> bool: return PgSpaceRules.edges_hud(c, p)],
		["горло и топь", func(c: Dictionary, p: Array[String]) -> bool:
			return PgQuirkRules.rule_throat_swamp(c, p)],
		["мосты", func(c: Dictionary, p: Array[String]) -> bool:
			return PgQuirkRules.rule_bridges(c, p)],
		["трещины", func(c: Dictionary, p: Array[String]) -> bool:
			return PgQuirkRules.rule_breaches(c, p)],
		["мимики и склепы", func(c: Dictionary, p: Array[String]) -> bool:
			return PgQuirkRules.rule_sleepers_crypts(c, p)],
		["изюминки", func(c: Dictionary, p: Array[String]) -> bool:
			return PgQuirkRules.rule_layout_quirks(c, p)],
		["схема участков", func(c: Dictionary, p: Array[String]) -> bool:
			return PgPlotPatterns.check(c["map"], p)],
		["оценка", func(c: Dictionary, _p: Array[String]) -> bool:
			var walkable: float = (c["raster"] as PgRaster).free_share()
			var story := _story_share(c)
			c["score"] = clampf(SCORE_W_WALKABLE * _walkable_penalty(walkable)
				+ SCORE_W_STORY * (1.0 - story), 0.0, 1.0)
			c["measure"] = _measure_dict(c, walkable, story, float(c["contact"]))
			return c["measure"] is Dictionary],
	]


static func _analyze(map: Dictionary, quick := false) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var problems := PgMapShape.check(map)
	if not problems.is_empty():
		return {"problems": problems, "score": 1.0,
			"measure": {"invalid": true, "problems": problems.size(),
				"ms": float(Time.get_ticks_usec() - t0) / 1000.0}}
	var ctx := {"map": map}
	for st: Array in _stages(map):
		if quick and st[0] == "оценка":
			return {"problems": problems}
		var ok: Variant = (st[1] as Callable).call(ctx, problems)
		if not (ok is bool and ok):
			problems.append("Фильтр: этап «%s» оборвался ошибкой — карта не проверена" % st[0])
			return {"problems": problems, "score": 1.0,
				"measure": {"invalid": true, "problems": problems.size()}}
		if quick and not problems.is_empty():
			return {"problems": problems}
	var m: Dictionary = ctx["measure"]
	m["problems"] = problems.size()
	m["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return {"problems": problems, "score": float(ctx["score"]), "measure": m}


## Проверки теста карт кампании (BOOK §10 п.1) — строками «Тест: …» без повторов.
static func _test_checks(ctx: Dictionary, problems: Array[String]) -> bool:
	var notes: Array[String] = []
	var done: Array = []
	var seen: Dictionary = {}
	for c: Dictionary in LegionMapChecks.run(ctx["map"], ctx["terrain"], notes, done):
		if not c.ok and not seen.has(c.msg):
			seen[c.msg] = true
			problems.append("Тест: " + String(c.msg))
	return not done.is_empty()


## Повтор вершины подряд — не излом и не «дорога пересекает себя» (verifier 27.09): схлопываем.
static func _dedup_roads(roads: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for road_id: String in roads:
		var src: PackedVector2Array = roads[road_id]
		var path := PackedVector2Array()
		for p in src:
			if path.is_empty() or path[-1].distance_to(p) > DUP_EPS:
				path.append(p)
		out[road_id] = path
	return out


# ── Выборка поперёк дороги ──────────────────────────────────────────────────

## Точки оси каждой дороги с шагом SAMPLE_STEP (только в кадре) и свободный ход в обе стороны.
## Порядок и шаг — как seg_samples() в comfort_measure.py: от начала каждого звена, конец звена
## не берётся. {id: {"pos", "arc", "dir", "left", "right", "span"}}.
static func _samples(ctx: Dictionary) -> Dictionary:
	var raster: PgRaster = ctx["raster"]
	var out: Dictionary = {}
	# Общие стволы развилок семплируются каждой дорогой; геометрия луча та же.
	var rays := {}
	for road_id: String in ctx["roads"]:
		var path: PackedVector2Array = ctx["roads"][road_id]
		var pos := PackedVector2Array()
		var arc := PackedFloat32Array()
		var dir := PackedVector2Array()
		var left := PackedInt32Array()
		var right := PackedInt32Array()
		var base := 0.0
		for i in range(1, path.size()):
			var a := path[i - 1]
			var seg := path[i] - a
			var length := seg.length()
			if length < 1e-6:
				continue
			var t := seg / length
			var n := Vector2(-t.y, t.x)
			var k := 0.0
			while k < length:
				var p := a + t * k
				if p.x >= 0.0 and p.y >= 0.0 and p.x < PgRaster.W and p.y < PgRaster.H:
					pos.append(p)
					arc.append(base + k)
					dir.append(t)
					var key := Vector4(p.x, p.y, n.x, n.y)
					if not rays.has(key):
						rays[key] = Vector2i(raster.ray(p, n), raster.ray(p, -n))
					var distances: Vector2i = rays[key]
					left.append(distances.x)
					right.append(distances.y)
				k += SAMPLE_STEP
			base += length
		var span := PackedInt32Array()
		span.resize(pos.size())
		for j in pos.size():
			span[j] = left[j] + right[j]
		out[road_id] = {"pos": pos, "arc": arc, "dir": dir, "left": left, "right": right,
			"span": span}
	return out


## Разметка горла или {} (нет горла): {"roads": id дорог, "from", "to", "pos"}. Горло лежит на
## отрезке [from, to] каждой дороги из roads (у турникета — на общем начале двух дорог).
static func _throat(map: Dictionary) -> Dictionary:
	var pg: Dictionary = map.get("procgen", {})
	var quirks: Array = pg.get("card", {}).get("quirks", [])
	var raw: Dictionary = pg.get("throat", {})
	if not quirks.has("throat") or raw.is_empty():
		return {}
	var ids: Array[String] = []
	for r: Variant in raw.get("roads", [raw.get("road", "")]):
		ids.append(String(r))
	var from := float(raw.get("from", 0.0))
	var to := float(raw.get("to", 0.0))
	var roads := LegionMapChecks.road_paths(map)
	var pos := Vector2.INF
	if raw.has("pos"):
		pos = LegionMapChecks.v(raw.pos)
	elif not ids.is_empty() and roads.has(ids[0]):
		pos = LegionMapChecks.point_at(roads[ids[0]], (from + to) * 0.5)
	return {"roads": ids, "from": from, "to": to, "pos": pos}


static func _on_throat(throat: Dictionary, road_id: String, arc: float) -> bool:
	return (throat["roads"] as Array).has(road_id) and arc >= float(throat["from"]) - THROAT_SNAP \
		and arc <= float(throat["to"]) + THROAT_SNAP


## У-1 (везде ≥ 90, кроме горла) и У-2 (≥ 55 % дороги ≥ 200). По дороге — одна строка, худшая точка.
static func _rule_spans(ctx: Dictionary, problems: Array[String]) -> bool:
	var throat: Dictionary = ctx["throat"]
	for road_id: String in ctx["samples"]:
		var sm: Dictionary = ctx["samples"][road_id]
		var span: PackedInt32Array = sm["span"]
		var worst := -1
		var bad := 0
		var wide := 0
		for j in span.size():
			if span[j] >= SPAN_WIDE:
				wide += 1
			var need := SPAN_MIN
			if not throat.is_empty() and _on_throat(throat, road_id, sm["arc"][j]):
				need = THROAT_SPAN_MIN
			if span[j] < need:
				bad += 1
				if worst < 0 or span[j] < span[worst]:
					worst = j
		if worst >= 0:
			var p: Vector2 = sm["pos"][worst]
			problems.append("У-1: пролёт %d px на дороге %s у (%.0f,%.0f); уже %.0f px — %.0f %% дороги"
				% [span[worst], road_id, p.x, p.y, SPAN_MIN, 100.0 * bad / span.size()])
		if span.size() > 0 and float(wide) / span.size() < WIDE_SHARE_MIN:
			problems.append("У-2: на дороге %s пролёт ≥ %.0f px лишь на %.0f %% длины (нужно ≥ %.0f %%)"
				% [road_id, SPAN_WIDE, 100.0 * wide / span.size(), WIDE_SHARE_MIN * 100.0])
	return true


# ── У-3: прямые с полосой ───────────────────────────────────────────────────

## Сколько на дороге прямых ≥ 140 px, вдоль которых с одной стороны непрерывно свободно ≥ 40 px
## от края дороги. Прямая — подряд идущие звенья с поворотом < TURN_EPS; считается её часть в кадре.
static func straights(sm: Dictionary) -> int:
	var need := int(ceil(LegionCfg.MAP_ROAD_WIDTH * 0.5 + STRAIGHT_STRIP))
	var dir: PackedVector2Array = sm["dir"]
	var left: PackedInt32Array = sm["left"]
	var right: PackedInt32Array = sm["right"]
	var arc: PackedFloat32Array = sm["arc"]
	var count := 0
	var j := 0
	while j < dir.size():
		# один прямой кусок: пока направление почти то же и выборка идёт подряд
		var start := j
		var run_l := 0.0
		var run_r := 0.0
		var best := 0.0
		var from_l := arc[j]
		var from_r := arc[j]
		while j < dir.size() and (j == start or (absf(dir[j].angle_to(dir[j - 1])) < TURN_EPS
				and arc[j] - arc[j - 1] <= SAMPLE_STEP + 0.01)):
			if left[j] >= need:
				run_l = arc[j] - from_l + SAMPLE_STEP
			else:
				from_l = arc[j] + SAMPLE_STEP
				run_l = 0.0
			if right[j] >= need:
				run_r = arc[j] - from_r + SAMPLE_STEP
			else:
				from_r = arc[j] + SAMPLE_STEP
				run_r = 0.0
			best = maxf(best, maxf(run_l, run_r))
			j += 1
		if best >= STRAIGHT_MIN:
			count += 1
	return count


static func _rule_straights(ctx: Dictionary, problems: Array[String]) -> bool:
	for road_id: String in ctx["samples"]:
		var n := straights(ctx["samples"][road_id])
		if n < STRAIGHTS_MIN:
			problems.append(("У-3: на дороге %s прямых ≥ %.0f px со свободной полосой ≥ %.0f px"
				+ " — %d (нужно ≥ %d)")
				% [road_id, STRAIGHT_MIN, STRAIGHT_STRIP, n, STRAIGHTS_MIN])
	return true


# ── У-4, У-5: участки ───────────────────────────────────────────────────────

static func _rule_plots(ctx: Dictionary, problems: Array[String]) -> bool:
	var map: Dictionary = ctx["map"]
	var cauldron: Vector2 = ctx["cauldron"]
	var risky: Array[String] = []
	var nearest := INF
	for plot: Dictionary in map.get("plots", []):
		var p := LegionMapChecks.v(plot.pos)
		var d := LegionMapChecks.dist_to_roads(p, ctx["roads"])
		if d > PLOT_ROAD_MAX:
			problems.append("У-4: участок %s в %.0f px от дороги (≤ %.0f)" % [plot.id, d, PLOT_ROAD_MAX])
		elif d < PLOT_ROAD_MIN:
			risky.append("%s %.0f px" % [plot.id, d])
		nearest = minf(nearest, p.distance_to(cauldron))
	if risky.size() > RISKY_PLOTS_MAX:
		problems.append("У-4: участков ближе %.0f px к дороге %d (≤ %d): %s"
			% [PLOT_ROAD_MIN, risky.size(), RISKY_PLOTS_MAX, ", ".join(risky)])
	if nearest > RESERVE_R:
		problems.append("У-5: ближайший к Котлу участок в %.0f px (≤ %.0f)" % [nearest, RESERVE_R])
	return true


# ── У-6: ворота ─────────────────────────────────────────────────────────────

static func _rule_gates(ctx: Dictionary, problems: Array[String]) -> bool:
	var done: Dictionary = {}
	for road_id: String in ctx["roads"]:
		var path: PackedVector2Array = ctx["roads"][road_id]
		if path.is_empty():
			continue
		var first := path[0]
		if _edge_dist(first) > GATE_EDGE_TOL:
			problems.append("У-6: дорога %s начинается внутри кадра (%.0f,%.0f), а не на краю"
				% [road_id, first.x, first.y])
			continue
		var g := LegionMapChecks.gate_of(path)
		if g == Vector2.INF:
			continue
		var key := Vector2i(roundi(g.x), roundi(g.y))
		if done.has(key):
			continue
		done[key] = true
		var why := _gate_problem(g)
		if why != "":
			problems.append("У-6: ворота дороги %s у (%.0f,%.0f) %s" % [road_id, g.x, g.y, why])
	# трещины — ворота посреди карты: видны и не под панелью (BOOK §4.1 «Внутренняя проверка»)
	for br: Dictionary in ctx["map"].get("breaches", []):
		var road := String(br.get("road", ""))
		if not ctx["roads"].has(road):
			continue
		var p := LegionMapChecks.point_at(ctx["roads"][road], float(br.get("at", 0.0)))
		if _under_hud(p):
			problems.append("У-6: трещина %s у (%.0f,%.0f) под панелью HUD" % [br.get("id", "?"), p.x, p.y])
	return true


## Почему ворота g (точка входа дороги в кадр) неудобны; "" — удобны.
static func _gate_problem(g: Vector2) -> String:
	var size := LegionCfg.WORLD_SIZE
	var d := {"слева": g.x, "справа": size.x - g.x, "сверху": g.y, "снизу": size.y - g.y}
	var side := "слева"
	for k: String in d:
		if float(d[k]) < float(d[side]):
			side = k
	var span: Vector2 = {"слева": GATE_LEFT, "справа": GATE_RIGHT, "сверху": GATE_TOP,
		"снизу": GATE_BOTTOM}[side]
	var along := g.y if side == "слева" or side == "справа" else g.x
	if along < span.x or along > span.y:
		return "%s вне свободного отрезка края %.0f–%.0f (угол или панель HUD)" % [side, span.x, span.y]
	return ""


static func _edge_dist(p: Vector2) -> float:
	var size := LegionCfg.WORLD_SIZE
	if p.x < 0.0 or p.y < 0.0 or p.x > size.x or p.y > size.y:
		return 0.0
	return minf(minf(p.x, p.y), minf(size.x - p.x, size.y - p.y))


static func _under_hud(p: Vector2) -> bool:
	for r in HUD_RECTS:
		if r.has_point(p):
			return true
	return false


# ── У-7: путь читается ──────────────────────────────────────────────────────

static func _rule_path_reading(ctx: Dictionary, problems: Array[String]) -> bool:
	var roads: Dictionary = ctx["roads"]
	var ids: Array = roads.keys()
	for road_id: String in ids:
		var path: PackedVector2Array = roads[road_id]
		var cross := _self_cross(path)
		if cross != Vector2.INF:
			problems.append("У-7: дорога %s пересекает сама себя у (%.0f,%.0f)"
				% [road_id, cross.x, cross.y])
		var bad := PgTurns.problem(path, SHARP_TURN, SHARP_GAP_MIN)
		if not bad.is_empty():
			var at: Vector2 = bad["at"]
			problems.append("У-7: на дороге %s %s у (%.0f,%.0f)" % [road_id, bad["what"], at.x, at.y])
		var run := _edge_run(ctx["samples"][road_id])
		if run.x > EDGE_RUN_MAX:
			problems.append(("У-7: дорога %s идёт вдоль края ближе %.0f px на %.0f px (≤ %.0f),"
				+ " до (%.0f,%.0f)")
				% [road_id, EDGE_NEAR, run.x, EDGE_RUN_MAX, run.y, run.z])
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var hit := _roads_cross(roads[ids[i]], roads[ids[j]])
			if hit != Vector2.INF:
				problems.append("У-7: дорога %s пересекает дорогу %s у (%.0f,%.0f) не слиянием"
					% [ids[i], ids[j], hit.x, hit.y])
	return true


static func _self_cross(path: PackedVector2Array) -> Vector2:
	for i in range(1, path.size()):
		for j in range(i + 2, path.size()):
			var hit: Variant = Geometry2D.segment_intersects_segment(path[i - 1], path[i],
				path[j - 1], path[j])
			if hit != null:
				return hit
	return Vector2.INF


## Первая точка, где две дороги пересекаются НЕ как общий вход (одинаковое начало до точки) и НЕ
## как слияние (одинаковый путь от точки до Котла). INF — таких нет.
static func _roads_cross(a: PackedVector2Array, b: PackedVector2Array) -> Vector2:
	for i in range(1, a.size()):
		var lo_a := a[i - 1].min(a[i])
		var hi_a := a[i - 1].max(a[i])
		for j in range(1, b.size()):
			if b[j - 1].max(b[j]).x < lo_a.x or b[j - 1].min(b[j]).x > hi_a.x \
					or b[j - 1].max(b[j]).y < lo_a.y or b[j - 1].min(b[j]).y > hi_a.y:
				continue
			var hit: Variant = Geometry2D.segment_intersects_segment(a[i - 1], a[i], b[j - 1], b[j])
			if hit == null:
				continue
			var p: Vector2 = hit
			if _same_route(_tail(a, p), _tail(b, p)) or _same_route(_head(a, p), _head(b, p)):
				continue
			return p
	return Vector2.INF


static func _arc_of(path: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	var at := 0.0
	var base := 0.0
	for i in range(1, path.size()):
		var q := Geometry2D.get_closest_point_to_segment(p, path[i - 1], path[i])
		var d := p.distance_to(q)
		if d < best - 0.01:
			best = d
			at = base + path[i - 1].distance_to(q)
		base += path[i - 1].distance_to(path[i])
	return at


static func _tail(path: PackedVector2Array, p: Vector2) -> PackedVector2Array:
	return _cut(path, _arc_of(path, p), INF)


static func _head(path: PackedVector2Array, p: Vector2) -> PackedVector2Array:
	return _cut(path, 0.0, _arc_of(path, p))


## Часть ломаной между длинами from и to.
static func _cut(path: PackedVector2Array, from: float, to: float) -> PackedVector2Array:
	var out := PackedVector2Array([LegionMapChecks.point_at(path, from)])
	var base := 0.0
	for i in range(1, path.size()):
		base += path[i - 1].distance_to(path[i])
		if base > from and base < to:
			out.append(path[i])
	if to < INF:
		out.append(LegionMapChecks.point_at(path, to))
	return out


## Две ломаные — один и тот же путь (с точностью MERGE_EPS).
static func _same_route(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	var la := LegionMapChecks.path_length(a)
	if absf(la - LegionMapChecks.path_length(b)) > MERGE_EPS * 2.0:
		return false
	var steps := maxi(1, ceili(la / SAMPLE_STEP))
	for s in steps + 1:
		var p := LegionMapChecks.point_at(a, la * s / steps) if a.size() > 1 else a[0]
		if b.size() < 2:
			if p.distance_to(b[0]) > MERGE_EPS:
				return false
			continue
		var d := INF
		for i in range(1, b.size()):
			d = minf(d, p.distance_to(Geometry2D.get_closest_point_to_segment(p, b[i - 1], b[i])))
		if d > MERGE_EPS:
			return false
	return true


## Зоны поворота дороги (PgTurns.zones) — для отчётов и проб.
static func _turns(path: PackedVector2Array) -> Array:
	return PgTurns.zones(path)


## Точка первого нарушения У-7 по поворотам; INF — нет.
static func _sharp_turns(path: PackedVector2Array) -> Vector2:
	var bad := PgTurns.problem(path, SHARP_TURN, SHARP_GAP_MIN)
	return Vector2.INF if bad.is_empty() else bad["at"]


## Самый длинный кусок дороги ближе EDGE_NEAR к краю: (длина, x, y конца).
static func _edge_run(sm: Dictionary) -> Vector3:
	var pos: PackedVector2Array = sm["pos"]
	var arc: PackedFloat32Array = sm["arc"]
	var best := Vector3.ZERO
	var from := -1.0
	for j in pos.size():
		if _edge_dist(pos[j]) >= EDGE_NEAR:
			from = -1.0
			continue
		# разрыв выборки (дорога выходила за кадр) — новый кусок
		if from < 0.0 or arc[j] - arc[j - 1] > SAMPLE_STEP + 0.01:
			from = arc[j]
		var run := arc[j] - from + SAMPLE_STEP
		if run > best.x:
			best = Vector3(run, pos[j].x, pos[j].y)
	return best


# ── У-8: Котёл ──────────────────────────────────────────────────────────────

static func _rule_cauldron(ctx: Dictionary, problems: Array[String]) -> bool:
	var c: Vector2 = ctx["cauldron"]
	var edge := _edge_dist(c)
	if edge < CAULDRON_EDGE_MIN:
		problems.append("У-8: Котёл (%.0f,%.0f) в %.0f px от края (≥ %.0f)"
			% [c.x, c.y, edge, CAULDRON_EDGE_MIN])
	for r in HUD_RECTS:
		var q := c.clamp(r.position, r.end)
		if q.distance_to(c) < CAULDRON_FREE_R:
			problems.append("У-8: круг резерва Котла r %.0f заходит под панель HUD у (%.0f,%.0f)"
				% [CAULDRON_FREE_R, q.x, q.y])
			break
	var raster: PgRaster = ctx["raster"]
	var near := INF
	var at := Vector2.ZERO
	var r2 := CAULDRON_FREE_R * CAULDRON_FREE_R
	var rad := int(CAULDRON_FREE_R)
	for dy in range(-rad, rad + 1, CAULDRON_PROBE):
		for dx in range(-rad, rad + 1, CAULDRON_PROBE):
			var d2 := float(dx * dx + dy * dy)
			if d2 <= r2 and d2 < near * near and raster.solid_at(c + Vector2(dx, dy)):
				near = sqrt(d2)
				at = c + Vector2(dx, dy)
	if near < INF:
		problems.append("У-8: препятствие в %.0f px от Котла у (%.0f,%.0f) — круг r %.0f не свободен"
			% [near, at.x, at.y, CAULDRON_FREE_R])
	for road_id: String in ctx["roads"]:
		var last := _last_straight(ctx["roads"][road_id])
		if last < LAST_STRAIGHT_MIN:
			problems.append("У-8: последняя прямая дороги %s к Котлу %.0f px (≥ %.0f)"
				% [road_id, last, LAST_STRAIGHT_MIN])
	return true


## Длина последней прямой ломаной (звенья с поворотом < TURN_EPS склеиваются).
static func _last_straight(path: PackedVector2Array) -> float:
	if path.size() < 2:
		return 0.0
	var i := path.size() - 1
	var length := path[i].distance_to(path[i - 1])
	while i >= 2 and absf((path[i] - path[i - 1]).angle_to(path[i - 1] - path[i - 2])) < TURN_EPS:
		i -= 1
		length += path[i].distance_to(path[i - 1])
	return length


# ── У-9: пролёт призраков ───────────────────────────────────────────────────

static func _rule_flights(ctx: Dictionary, problems: Array[String]) -> bool:
	var raster: PgRaster = ctx["raster"]
	for fl: Dictionary in ctx["map"].get("flights", []):
		var path := LegionMapChecks.polyline(fl.get("path", []))
		var last := _last_straight(path)
		if last < FLIGHT_LAST_MIN:
			problems.append("У-9: последняя прямая пролёта %s %.0f px (≥ %.0f)"
				% [fl.id, last, FLIGHT_LAST_MIN])
			continue
		var end := path[-1]
		var dir := (path[-2] - end).normalized()
		var s := 0.0
		while s <= last:
			var p := end + dir * s
			if raster.solid_at(p):
				problems.append("У-9: последняя прямая пролёта %s идёт над препятствием у (%.0f,%.0f)"
					% [fl.id, p.x, p.y])
				break
			s += SAMPLE_STEP
	return true


# ── У-10: первая встреча ────────────────────────────────────────────────────

## Секунды от старта боя до встречи первого врага первой волны с ближайшим по ходу рубежом бота
## (`bot_lines` — где идёт драка; без рубежа на пути — у Котла). Скорость вида из FOES, топь
## замедляет пеших. Сверено с B-078: «Два отдела» дают ~43 с (наблюдение в игре ~50 с).
## NAN — счёт не сошёлся (шагов больше, чем даёт длина дороги): этап У-10 считается оборванным.
static func first_contact(map: Dictionary, roads: Dictionary, terrain: LegionTerrain) -> float:
	var waves: Array = map.get("waves", [])
	if waves.is_empty():
		return INF
	var wave: Dictionary = waves[0]
	var start := float(wave.get("pause", LegionCfg.WAVE_PAUSE_DEFAULT))
	var paths := roads.duplicate()
	for fl: Dictionary in map.get("flights", []):
		paths[String(fl.id)] = LegionMapChecks.polyline(fl.get("path", []))
	var best := INF
	for g: Dictionary in wave.get("groups", []):
		var road := String(g.get("road", ""))
		var at := float(g.get("at", 0.0))
		var breach := String(g.get("breach", ""))
		for br: Dictionary in map.get("breaches", []):
			if breach != "" and String(br.get("id", "")) == breach:
				road = String(br.get("road", road))
				at = float(br.get("at", at))
		if not paths.has(road):
			continue
		var path: PackedVector2Array = paths[road]
		var foe: Dictionary = LegionCfg.FOES.get(String(g.get("type", "zombie")), {})
		var speed := float(foe.get("speed", 30.0))
		var ghost := bool(foe.get("ghost", false))
		var meet := _meet_arc(map, path, at)
		var t := start + float(g.get("delay", 0.0))
		var s := at
		# предел шагов — длина дороги, а не данные: at за пределами дороги не должен крутить цикл
		var left := ceili(LegionMapChecks.path_length(path) / SAMPLE_STEP) + LOOP_SLACK
		if speed <= 0.0:
			return NAN
		while s < meet:
			left -= 1
			if left < 0:
				return NAN
			var step := minf(SAMPLE_STEP, meet - s)
			var mult := 1.0 if ghost else terrain.speed_mult(
				LegionMapChecks.point_at(path, s + step * 0.5))
			t += step / (speed * mult)
			s += step
		best = minf(best, t)
	return best


static func _meet_arc(map: Dictionary, path: PackedVector2Array, at: float) -> float:
	var best := LegionMapChecks.path_length(path)
	var base := 0.0
	for i in range(1, path.size()):
		for bl: Dictionary in map.get("bot_lines", []):
			var hit: Variant = Geometry2D.segment_intersects_segment(path[i - 1], path[i],
				LegionMapChecks.v(bl.a), LegionMapChecks.v(bl.b))
			if hit != null:
				var arc := base + path[i - 1].distance_to(hit)
				if arc >= at:
					best = minf(best, arc)
		base += path[i - 1].distance_to(path[i])
	return best


# ── У-11: извилистость ──────────────────────────────────────────────────────

static func _rule_detour(ctx: Dictionary, problems: Array[String]) -> bool:
	var hi := DETOUR_MAX_SPIRAL if ctx["spiral"] else DETOUR_MAX
	for road_id: String in ctx["roads"]:
		var x := _detour(ctx["roads"][road_id], ctx["cauldron"])
		if x < DETOUR_MIN or x > hi:
			problems.append("У-11: извилистость дороги %s ×%.2f (нужно %.1f–%.1f)"
				% [road_id, x, DETOUR_MIN, hi])
	return true


static func _detour(path: PackedVector2Array, cauldron: Vector2) -> float:
	if path.size() < 2:
		return 0.0
	return LegionMapChecks.path_length(path) / maxf(path[0].distance_to(cauldron), 1.0)


# ── score() и measure() ─────────────────────────────────────────────────────

static func _walkable_penalty(share: float) -> float:
	if share < WALKABLE_LO:
		return clampf((WALKABLE_LO - share) / WALKABLE_SLACK, 0.0, 1.0)
	if share > WALKABLE_HI:
		return clampf((share - WALKABLE_HI) / WALKABLE_SLACK, 0.0, 1.0)
	return 0.0


## Доля участков со «своей историей» рядом: декор или предмет процгена, склеп, мимик, край скалы
## или стены ближе STORY_R. Голый круг в поле — без истории.
static func _story_share(ctx: Dictionary) -> float:
	var map: Dictionary = ctx["map"]
	var plots: Array = map.get("plots", [])
	if plots.is_empty():
		return 0.0
	var marks := PackedVector2Array()
	for kind: String in ["decor", "props", "crypts", "sleepers"]:
		for e: Dictionary in map.get(kind, []):
			if e.has("pos"):
				marks.append(LegionMapChecks.v(e.pos))
	var terrain: LegionTerrain = ctx["terrain"]
	var with_story := 0
	for plot: Dictionary in plots:
		var p := LegionMapChecks.v(plot.pos)
		var found := false
		for m in marks:
			if m.distance_to(p) <= STORY_R:
				found = true
				break
		if not found:
			for poly in terrain.rocks:
				for k in poly.size():
					var q := Geometry2D.get_closest_point_to_segment(p, poly[k], poly[(k + 1) % poly.size()])
					if q.distance_to(p) <= STORY_R:
						found = true
						break
				if found:
					break
		if found:
			with_story += 1
	return float(with_story) / plots.size()


## Процентиль как numpy.percentile (линейная интерполяция) — чтобы p10 сходился с книгой.
static func percentile(sorted: PackedInt32Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	var idx := q / 100.0 * (sorted.size() - 1)
	var lo := floori(idx)
	var hi := mini(lo + 1, sorted.size() - 1)
	return lerpf(float(sorted[lo]), float(sorted[hi]), idx - lo)


static func _span_stats(span: PackedInt32Array) -> Dictionary:
	var sorted := span.duplicate()
	sorted.sort()
	var n := maxi(sorted.size(), 1)
	var tight76 := 0
	var tight90 := 0
	var wide := 0
	for s in sorted:
		if s < SPAN_TIGHT_REPORT:
			tight76 += 1
		if s < SPAN_MIN:
			tight90 += 1
		if s >= SPAN_WIDE:
			wide += 1
	return {
		"min": sorted[0] if sorted.size() > 0 else 0, "p10": percentile(sorted, 10.0),
		"median": percentile(sorted, 50.0), "lt76": 100.0 * tight76 / n, "lt90": 100.0 * tight90 / n,
		"ge200": 100.0 * wide / n, "samples": sorted.size(),
	}


## Ключи: span (все дороги вместе, как в книге §3.1: min/p10/median, lt76/lt90/ge200 — % выборки),
## roads (по дороге: length, detour, turns, span, straights, last_straight), first_contact (с),
## walkable (доля свободного кадра), story (доля участков с историей), plots_to_road (px),
## plot_cauldron_min (px), problems (число нарушений), ms (время разбора).
static func _measure_dict(ctx: Dictionary, walkable: float, story: float,
		contact: float) -> Dictionary:
	var all := PackedInt32Array()
	var roads: Dictionary = {}
	for road_id: String in ctx["samples"]:
		var sm: Dictionary = ctx["samples"][road_id]
		all.append_array(sm["span"])
		var path: PackedVector2Array = ctx["roads"][road_id]
		# крутые повороты (≥ 60°) по зонам PgTurns — тем же счётом, что У-7
		var turns := 0
		for z: Array in PgTurns.zones(path):
			if absf(float(z[2])) >= SHARP_TURN:
				turns += 1
		roads[road_id] = {
			"length": LegionMapChecks.path_length(path), "detour": _detour(path, ctx["cauldron"]),
			"turns": turns, "span": _span_stats(sm["span"]), "straights": straights(sm),
			"last_straight": _last_straight(path),
		}
	var to_road: Array[float] = []
	var to_cauldron := INF
	for plot: Dictionary in ctx["map"].get("plots", []):
		var p := LegionMapChecks.v(plot.pos)
		to_road.append(LegionMapChecks.dist_to_roads(p, ctx["roads"]))
		to_cauldron = minf(to_cauldron, p.distance_to(ctx["cauldron"]))
	return {
		"span": _span_stats(all), "roads": roads, "first_contact": contact, "walkable": walkable,
		"story": story, "plots_to_road": to_road, "plot_cauldron_min": to_cauldron,
	}
