extends SceneTree
##
## Регресс линии layout процгена (docs/procgen/STAGE2.md §1–4, BOOK §2–7):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_procgen_layout_test.gd -- --mute
##
## 1) детерминизм: два вызова → один хэш словаря; map_from_id — тот же словарь;
## 2) 100 сидов × объекты 1…12 (настоящий фильтр PgFilter в цикле кандидатов): карта непустая,
##    LegionTerrain её принимает, каждая дорога проходима с краями и кончается в Котле, участков
##    3–8 и все достижимы, ≤ 200 px до дороги, ворота на свободных отрезках края (правые —
##    ниже превью волны y 200, верхние — с x 820), рубежи пересекают свою дорогу, склепы/мимики/
##    участки ≥ 16 px от края, стены не пересекают оси дорог и не заходят в их полосу, участки и
##    рубежи не под HUD; каждый из 17 архетипов выходит к 12-му объекту; время генерации
##    (медиана ≤ 500 мс — страховка от зависания, не замер скорости: Игорь 03.10 «скорость
##    генерации не критична», порог 150 мс шумел с загрузкой машины 107–176 мс, B-393);
## 3) правило разнообразия BOOK §5.3 по цепочке карточек;
## 4) «заданная карточка» соблюдается; заморозка → разбор → тот же словарь;
## 5) движок: LegionWorld.load_map("gen:1:1") отдаёт карту (на старом коде — пусто), кампания —
##    те же восемь карт.
## Итог «LEGION PROCGEN LAYOUT: N/M OK»; код выхода 1 при провале. Сохранений не пишет.
##

const SEEDS := 100
const KS := 12
const MEDIAN_MS := 500.0
## Отступ «ничего игрового» от края (У-13) и полоса дороги с каймой (стены сюда не заходят).
const EDGE_KEEP := 16.0
const ROAD_BAND := 23.0
const CAMPAIGN := ["archive", "boss", "bridge", "fork", "gatehouse", "maze", "swamp",
	"wasteland"]

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_determinism()
	_engine()
	_many()
	_diversity()
	_forced()
	_freeze()
	print("LEGION PROCGEN LAYOUT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL ", what)


func _determinism() -> void:
	var a := ProcGen.generate(11, 3)
	var b := ProcGen.generate(11, 3)
	_check(not a.is_empty(), "карта 11:3 непустая")
	_check(ProcGen.digest(a) == ProcGen.digest(b), "два вызова — один хэш словаря")
	_check(ProcGen.digest(ProcGen.map_from_id("gen:11:3")) == ProcGen.digest(a),
		"map_from_id отдаёт тот же словарь")
	_check(ProcGen.generate(12, 3).get("roads") != a.get("roads"), "другой сид — другая карта")
	_check(ProcGen.map_from_id("gen:x:1").is_empty() and ProcGen.map_from_id("wasteland")
		.is_empty(), "чужой id — пусто")
	print("хэш 11:3 = ", ProcGen.digest(a).left(16))


func _engine() -> void:
	var m := LegionWorld.load_map("gen:1:1")
	_check(not m.is_empty() and String(m.get("id", "")) == "gen:1:1",
		"LegionWorld.load_map(gen:1:1) — карта генератора")
	var ids: Array[String] = []
	for c: Dictionary in Campaign.maps():
		ids.append(String(c["id"]))
	ids.sort()
	_check(ids == Array(CAMPAIGN, TYPE_STRING, "", null), "кампания — те же восемь карт: %s" % [ids])


func _v(a: Array) -> Vector2:
	return Vector2(a[0], a[1])


func _many() -> void:
	var times: Array[float] = []
	var archs := {}
	var quirks := {}
	var bad := 0
	var jobs: Array[Vector2i] = []
	for s in range(1, SEEDS + 1):
		for k in range(1, KS + 1):
			jobs.append(Vector2i(s, k))
	for job in jobs:
		var s := job.x
		var k := job.y
		var t0 := Time.get_ticks_usec()
		var m := ProcGen.generate(s, k)
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		if m.is_empty():
			_check(false, "%d:%d пустая карта" % [s, k])
			continue
		var why := _map_problems(m)
		if not why.is_empty():
			bad += 1
			if bad <= 12:
				print("  %d:%d %s" % [s, k, why])
		var card: Dictionary = m["procgen"]["card"]
		archs[card["archetype"]] = int(archs.get(card["archetype"], 0)) + 1
		for q: String in card["quirks"]:
			quirks[q] = int(quirks.get(q, 0)) + 1
	_check(bad == 0, "все %d карт годны (плохих %d)" % [jobs.size(), bad])
	times.sort()
	var med := times[times.size() / 2]
	print("время генерации: медиана %.1f мс, максимум %.1f мс" % [med, times[-1]])
	_check(med <= MEDIAN_MS, "медиана генерации ≤ %.0f мс (%.1f)" % [MEDIAN_MS, med])
	print("архетипы: ", archs)
	print("изюминки: ", quirks)
	_check(archs.size() == PgTables.ARCH_ORDER.size(),
		"все 17 архетипов выходят к 12-му объекту (%d)" % archs.size())
	_check(quirks.size() >= 18, "встречаются почти все изюминки (%d из 19)" % quirks.size())


## Проверки тем же движком, что водит армию (независимо от самопроверки PgLayout). Первая
## найденная беда или "".
func _map_problems(m: Dictionary) -> String:
	var terrain := LegionTerrain.new().setup(m)
	var why: Array[String] = []
	var paths := {}
	for r: Dictionary in m["roads"]:
		var p := PackedVector2Array()
		for q: Array in r["path"]:
			p.append(_v(q))
		paths[r["id"]] = p
		_road_problems(terrain, String(r["id"]), p, _v(m["cauldron"]), why)
	_plot_problems(terrain, m, paths, why)
	if (m["bot_lines"] as Array).is_empty():
		why.append("нет рубежей")
	for bl: Dictionary in m["bot_lines"]:
		var path: PackedVector2Array = paths.get(bl["road"], PackedVector2Array())
		var hit := false
		for i in range(1, path.size()):
			hit = hit or Geometry2D.segment_intersects_segment(_v(bl["a"]), _v(bl["b"]),
				path[i - 1], path[i]) != null
		if not hit:
			why.append("%s не пересекает дорогу" % bl["id"])
	var lanes := paths.keys()
	for f: Dictionary in m.get("flights", []):
		lanes.append(f["id"])
	for w: Dictionary in m["waves"]:
		for g: Dictionary in w["groups"]:
			if not lanes.has(g["road"]):
				why.append("группа на несуществующей дороге %s" % g["road"])
	_edge_hud_problems(m, why)
	_wall_problems(m, paths, why)
	return why[0] if not why.is_empty() else ""


## Пункты verifier 27.09: склеп за краем (gen:13:11 — [192, 720]) и зоны HUD (превью волны до
## y 200, плашка статов 0–820 × 0–50) для участков и рубежей.
func _edge_hud_problems(m: Dictionary, why: Array[String]) -> void:
	var inner := Rect2(Vector2.ZERO, PgGeom.WORLD).grow(-EDGE_KEEP)
	for key: String in ["crypts", "sleepers", "plots"]:
		for e: Dictionary in m.get(key, []):
			var p := _v(e["pos"])
			if not inner.has_point(p):
				why.append("%s (%d, %d) ближе 16 px к краю" % [key, p.x, p.y])
			if key == "plots" and PgGeom.in_hud(p, 0.0):
				why.append("участок (%d, %d) под HUD" % [p.x, p.y])
	for bl: Dictionary in m["bot_lines"]:
		for q: Vector2 in [_v(bl["a"]), _v(bl["b"])]:
			if PgGeom.in_hud(q, 0.0):
				why.append("рубеж %s под HUD" % bl["id"])


## Пункт verifier 27.09 (gen:20:4 — крыло горла поперёк дороги): стены не пересекают оси
## дорог и не заходят в полосу дороги (±23 px) толщиной.
func _wall_problems(m: Dictionary, paths: Dictionary, why: Array[String]) -> void:
	for wl: Dictionary in m["walls"]:
		var wp: Array = wl["path"]
		for i in range(1, wp.size()):
			var a := _v(wp[i - 1])
			var b := _v(wp[i])
			for path: PackedVector2Array in paths.values():
				for j in range(1, path.size()):
					if PgGeom.seg_dist(a, b, path[j - 1], path[j]) < ROAD_BAND + float(wl["w"]) * 0.5:
						why.append("стена %s у оси дороги" % [wl["path"]])
						return


func _road_problems(terrain: LegionTerrain, id: String, p: PackedVector2Array, c: Vector2,
		why: Array[String]) -> void:
	if p[-1] != c:
		why.append("%s не кончается в Котле" % id)
	if not PgGeom.gate_ok(p):
		why.append("%s ворота под HUD" % id)
	# правые ворота — ниже превью волны (y ≥ 200), верхние — правее плашки статов (x ≥ 820)
	var g := PgGeom.gate_point(p)
	var side := PgGeom.gate_side(p)
	if (side == "east" and g.y < 232.0) or (side == "north" and g.x < 852.0):
		why.append("%s ворота %s (%d, %d) у панели HUD" % [id, side, g.x, g.y])
	var total := PgGeom.length(p)
	if total / p[0].distance_to(c) < 1.4:
		why.append("%s путь < 1,4 прямой" % id)
	var n := ceili(total / 8.0)
	for s in n + 1:
		var at := total * s / n
		var q := PgGeom.point_at(p, at)
		var nrm := PgGeom.tangent_at(p, at).orthogonal()
		for off: float in [-23.0, 0.0, 23.0]:
			if not terrain.walkable(q + nrm * off):
				why.append("%s перекрыта у %s" % [id, q])
				return


func _plot_problems(terrain: LegionTerrain, m: Dictionary, paths: Dictionary,
		why: Array[String]) -> void:
	var c := _v(m["cauldron"])
	var grid: AStarGrid2D = terrain.get("_astar")
	var plots: Array = m["plots"]
	if plots.size() < 3 or plots.size() > 8:
		why.append("участков %d" % plots.size())
	for pl: Dictionary in plots:
		var p := _v(pl["pos"])
		if not terrain.walkable(p) or grid.get_id_path(terrain.cell_of(c),
				terrain.cell_of(p)).is_empty():
			why.append("%s недостижим" % pl["id"])
		var d := INF
		for path: PackedVector2Array in paths.values():
			d = minf(d, PgGeom.dist_to_path(p, path))
		if d > 200.0:
			why.append("%s дальше 200 от дороги" % pl["id"])


## BOOK §5.3: архетип не повторяется 3 объекта подряд, изюминка — 4, биом — 2, ведущий враг
## — 2; изюминок 1–2, две — только с N(k) ≥ 0,45; «сюрприз» не раньше 4-го и не чаще 1 на 5.
func _diversity() -> void:
	var bad := 0
	for s in range(1, SEEDS + 1):
		var chain := PgCard.chain(s, KS)
		var last_surprise := -100
		for i in chain.size():
			var c := chain[i]
			var why := ""
			for j in range(maxi(0, i - 2), i):
				if chain[j]["archetype"] == c["archetype"]:
					why = "архетип повторён"
			for j in range(maxi(0, i - 3), i):
				for q: String in c["quirks"]:
					if (chain[j]["quirks"] as Array).has(q):
						why = "изюминка %s повторена" % q
			if i > 0 and chain[i - 1]["biome"] == c["biome"]:
				why = "биом повторён"
			if i > 0 and chain[i - 1]["lead"] == c["lead"]:
				why = "ведущий враг повторён"
			var nq := (c["quirks"] as Array).size()
			if nq < 1 or nq > 2 or (nq == 2 and float(c["target"]) < 0.45):
				why = "изюминок %d при N=%.2f" % [nq, c["target"]]
			if bool(c["surprise"]):
				if i + 1 < 4 or i - last_surprise < 5:
					why = "сюрприз рано"
				last_surprise = i
			if why != "":
				bad += 1
				if bad <= 8:
					print("  разнообразие %d:%d — %s" % [s, i + 1, why])
	_check(bad == 0, "правило разнообразия по цепочкам (%d нарушений)" % bad)


func _forced() -> void:
	var want := {"biome": "swamp", "archetype": "island", "quirks": ["mimic_best"],
		"lead_enemy": "beetle"}
	var m := ProcGen.generate(5, 2, {"card": want})
	_check(not m.is_empty(), "заданная карточка разложилась")
	if m.is_empty():
		return
	var c: Dictionary = m["procgen"]["card"]
	_check(c["biome"] == "swamp" and c["archetype"] == "island" and c["quirks"] == ["mimic_best"]
		and c["lead"] == "beetle", "заданные поля карточки соблюдены: %s" % [c])
	_check((m["sleepers"] as Array).size() == 1 and (m["water"] as Array).size() >= 3,
		"изюминка и архетип заданной карточки — в раскладке")
	var again := ProcGen.generate(5, 2, {"card": want})
	_check(ProcGen.digest(again) == ProcGen.digest(m), "заданная карточка детерминирована")


func _freeze() -> void:
	var m := ProcGen.generate(3, 7)
	var back := ProcGen.thaw(ProcGen.freeze(m))
	_check(_same(m, back), "заморозка → разбор → тот же словарь")
	_check(back.keys() == m.keys(), "порядок ключей сохранён")


## Равенство с точностью до int/float (JSON числа разбирает во float).
func _same(a: Variant, b: Variant) -> bool:
	var ok := true
	if (a is int or a is float) and (b is int or b is float):
		ok = is_equal_approx(float(a), float(b))
	elif a is Dictionary and b is Dictionary:
		ok = (a as Dictionary).size() == (b as Dictionary).size()
		for key: Variant in a:
			ok = ok and (b as Dictionary).has(key) and _same(a[key], b[key])
	elif a is Array and b is Array:
		ok = (a as Array).size() == (b as Array).size()
		for i in mini((a as Array).size(), (b as Array).size()):
			ok = ok and _same(a[i], b[i])
	else:
		ok = a == b
	return ok
