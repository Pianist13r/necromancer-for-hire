extends SceneTree
##
## Регресс линии L2 «Половины процгена» (docs/pvp/DESIGN.md §3, §11; BOOK §12):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_halves_test.gd -- --mute
##
## 1) одиночные карты не сломаны: ProcGen.digest 48 карт — как до линии (эталон снят на
##    master 77ba29a), и так же после генерации поля PvP (рамка половины не протекает);
## 2) ProcGen.generate(сид, k, {"pvp": true}) — поле 1600×900 из двух секторов: оно симметрично
##    (рельеф, стены, вода, мосты, дороги, участки, Котлы, предметы, рубежи при x' = W − x
##    совпадают с собой), проёмы стыка у соседей совпадают (1–3 шт., 96–160, кратно 16), каждая
##    половина проходима от каждого проёма до своего Котла (A* движка по рельефу LegionTerrain),
##    участки не в нейтральной полосе, у всего своего — side, ворота PvE на верхнем крае;
##    собственная проверка генератора PgPvp.check — пусто;
## 3) детерминизм: два вызова — один хэш; map_from_id("gen:<сид>:<k>:pvp") — тот же словарь;
## 4) каждый архетип половины (BOOK §12.3) задаётся и складывается.
## Итог «LEGION PVP HALVES: N/M OK»; код выхода 1 при провале. Сохранений не пишет.
##
## Новые классы берутся через load(): на старом коде тест не падает разбором, а честно пишет FAIL.
##

const PVP_SCRIPT := "res://scripts/legion/procgen/pg_pvp.gd"
const HALF_SCRIPT := "res://scripts/legion/procgen/pg_half.gd"
const FIELD := [1600, 900]
const SEEDS := 20
const LATE: Array[int] = [4, 9]
const LATE_SEEDS := 6
const MEDIAN_MS := 300.0
## Эталон одиночных карт: первые 16 знаков ProcGen.digest. Снят на master 77ba29a; 33 из 48
## обновлены под коммит 19de583 (pg_names: тексты адресов брифинга входят в digest). С pg_names
## до 19de583 все 48 совпадали побайтно, т.е. слияние L2 одиночный процген не меняет.
## 03.10 все 48 обновлены под волны v2 (slow/procgen-waves): digest включает волны и подсказку
## брифинга о «тихой дороге»; раскладка без волн (digest без "waves", procgen.waves/quiet) и номер
## попытки на 169 картах — как на master 07337f36 (сверка в docs/procgen/WAVES.md).
## 03.10 (v3, подбор цепочкой) 40 из 48 обновлены повторно: изменился только бюджет и темп волн
## (pg_waves.gd: три участка колена, TEMPO_FROM 3); k1 и раскладка не изменились.
## 08.10: VERSION 2, две схемы участков; эталон закреплён после полного фильтра.
## 08.10 вечер (slow/gate-fix-1008, D-1008-S18): тот эталон снят в 81c7466b со схемами ВКЛ, а
## fcdd2818 выключил их по умолчанию (D-1008-PG6, ProcGen.CONFIG.new_layout_schemes = false) без
## пересъёмки. 22 из 48 обновлены под схемы ВЫКЛ; проба на 2b965b20: с opts new_layout_schemes
## = true все 48 равны прежнему эталону, без него расходятся ровно эти 22 — генератор в
## остальном не менялся.
const GOLDEN := {
	"13:1": "07af4f1418c03354",
	"13:2": "c67a28537da64652",
	"13:3": "7f8644fb7666f4f9",
	"13:4": "26740472a7429419",
	"13:6": "f4b2ceaac5c59d5c",
	"13:9": "ba635a8b14e4076a",
	"1:1": "19ae36c153af6826",
	"1:2": "5cb9c4688f444ef6",
	"1:3": "36b94bb352403eca",
	"1:4": "3d221cc239f659df",
	"1:6": "9704d10a64488681",
	"1:9": "5b491ab4ed4598cc",
	"21:1": "f1b217eecf420420",
	"21:2": "bca88085455c11ef",
	"21:3": "855ebaa4ef1f0528",
	"21:4": "f07003ca8ac19e91",
	"21:6": "e43afc225c7951e7",
	"21:9": "33fb673191be853b",
	"2:1": "9746359f6969205a",
	"2:2": "0024d2386d3dbd09",
	"2:3": "7784d2ca3d7a44fc",
	"2:4": "23ee1f82a7c79864",
	"2:6": "d637950808db3199",
	"2:9": "5e8a9de7308dfdf9",
	"34:1": "6613bb2bf465bc51",
	"34:2": "0e397090d0a8fd21",
	"34:3": "2cac8e8193d59436",
	"34:4": "212fe47d99358323",
	"34:6": "42964e702a3ebe19",
	"34:9": "f26f184f27a9ec39",
	"3:1": "5dac21a965c78624",
	"3:2": "9107ca1675e42fb5",
	"3:3": "8e37e2183598bab0",
	"3:4": "e550da3ead2eb105",
	"3:6": "21f672aa68cdf740",
	"3:9": "520925887665dc88",
	"5:1": "d6474ac1efead310",
	"5:2": "02c0fc057b2cd26a",
	"5:3": "95a5c1791ad91fb8",
	"5:4": "f831ea6e81e2acb0",
	"5:6": "057fca360ebd2fcc",
	"5:9": "e2820fff0d6dad3b",
	"8:1": "69b66794a6c57af3",
	"8:2": "ff6ffb3afc614b5e",
	"8:3": "4768ab768ac1d805",
	"8:4": "7e5d7beb821b8488",
	"8:6": "8366a3218714a285",
	"8:9": "6e1038af920ded0b",
}

var _checks := 0
var _fails := 0
var _pvp: GDScript = null
var _half: GDScript = null


func _initialize() -> void:
	if ResourceLoader.exists(PVP_SCRIPT):
		_pvp = load(PVP_SCRIPT)
	if ResourceLoader.exists(HALF_SCRIPT):
		_half = load(HALF_SCRIPT)
	_check(_pvp != null and _half != null, "есть PgPvp и PgHalf")
	_golden("до поля PvP")
	_fields()
	_determinism()
	_archetypes()
	_golden("после полей PvP")
	print("LEGION PVP HALVES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL ", what)


# ── 1. одиночные карты ───────────────────────────────────────────────────────

func _golden(when: String) -> void:
	var bad: Array[String] = []
	for key: String in GOLDEN:
		var want := String(GOLDEN[key])
		var p := key.split(":")
		var got := ProcGen.digest(ProcGen.generate(p[0].to_int(), p[1].to_int())).left(16)
		if got != want:
			bad.append("%s %s≠%s" % [key, got, want])
	_check(bad.is_empty(), "одиночные карты — те же digest, %s: %s" % [when, bad])


# ── 2. поля ──────────────────────────────────────────────────────────────────

func _fields() -> void:
	var times: Array[float] = []
	var archs := {}
	var runs: Array = []
	for s in range(1, SEEDS + 1):
		runs.append([s, 1])
	for s in range(1, LATE_SEEDS + 1):
		for k in LATE:
			runs.append([s, k])
	for run: Array in runs:
		var t0 := Time.get_ticks_usec()
		var m := ProcGen.generate(run[0], run[1], {"pvp": true})
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		var tag := "поле %d:%d" % [run[0], run[1]]
		if not _is_field(m, tag):
			continue
		archs[String(m["procgen"]["card"]["archetype"])] = true
		_field(m, tag)
	times.sort()
	var med: float = times[times.size() / 2]
	_check(med < MEDIAN_MS, "медиана генерации поля %.1f мс < %d" % [med, MEDIAN_MS])
	_check(archs.size() >= 4, "в выборке ≥ 4 архетипов половины: %s" % [archs.keys()])
	print("полей %d, архетипы %s, мс медиана %.1f, максимум %.1f" % [runs.size(), archs.keys(),
		med, times[-1]])


func _is_field(m: Dictionary, tag: String) -> bool:
	var ok: bool = not m.is_empty() and m.has("sectors") and m.get("size", []) == FIELD \
		and (m["sectors"] as Array).size() == 2
	_check(ok, tag + ": поле PvP 1600×900 из двух секторов")
	return ok


func _field(m: Dictionary, tag: String) -> void:
	if _pvp != null:
		var bad: Array = _pvp.call("check", m)
		_check(bad.is_empty(), tag + ": PgPvp.check пусто — %s" % [bad.slice(0, 4)])
	_symmetry(m, tag)
	_spans(m, tag)
	_sides(m, tag)
	_reach(m, tag)


## Симметрия: множество всех вещей поля и его отражение x' = W − x — одно и то же.
func _symmetry(m: Dictionary, tag: String) -> void:
	var a := _canon(m, false)
	var b := _canon(m, true)
	var diff: Array = []
	for i in a.size():
		if i >= b.size() or a[i] != b[i]:
			diff.append(a[i])
			if diff.size() >= 2:
				break
	_check(a == b and a.size() > 20, tag + ": поле симметрично (%d вещей), разница: %s" % [
		a.size(), diff])


func _canon(m: Dictionary, mirror: bool) -> Array[String]:
	var w := float(m["size"][0])
	var seam := w * 0.5
	var f := func(p: Array) -> String:
		var x := float(p[0])
		return "%d,%d" % [roundi(w - x if mirror else x), roundi(float(p[1]))]
	var poly := func(src: Array) -> String:
		var pts: Array[String] = []
		for p: Array in src:
			pts.append(f.call(p))
		pts.sort()
		return ";".join(pts)
	var seq := func(src: Array) -> String:
		var pts: Array[String] = []
		for p: Array in src:
			pts.append(f.call(p))
		return ">".join(pts)
	var out: Array[String] = []
	for key: String in ["rocks", "water", "bridges", "swamp"]:
		for p: Array in m[key]:
			out.append(key + ":" + poly.call(p))
	for wl: Dictionary in m["walls"]:
		out.append("wall:%s:%s:%s" % [wl["kind"], wl["w"], poly.call(wl["path"])])
	for r: Dictionary in m["roads"]:
		out.append("road:%s:%s" % [r["kind"], seq.call(r["path"])])
	for pl: Dictionary in m["plots"]:
		out.append("plot:" + f.call(pl["pos"]))
	for c: Dictionary in m["cauldrons"]:
		out.append("cauldron:" + f.call(c["pos"]))
	for g: Dictionary in m["gates"]:
		out.append("gate:" + f.call(g["pos"]))
	for bl: Dictionary in m["bot_lines"]:
		out.append("line:" + poly.call([bl["a"], bl["b"]]))
	for pr: Dictionary in m["props"]:
		var on_seam := float(pr["pos"][0]) == seam
		out.append("prop:%s:%s:%s" % [pr["item"], f.call(pr["pos"]),
			bool(pr["flip"]) != (mirror and not on_seam)])
	out.sort()
	return out


func _spans(m: Dictionary, tag: String) -> void:
	var s0: Dictionary = m["sectors"][0]
	var s1: Dictionary = m["sectors"][1]
	var e0 := {}
	var e1 := {}
	for e: Dictionary in s0["edges"]:
		if e["neighbor"] == "p1":
			e0 = e
	for e: Dictionary in s1["edges"]:
		if e["neighbor"] == "p0":
			e1 = e
	_check(not e0.is_empty() and not e1.is_empty() and e0["side"] == "east"
		and e1["side"] == "west", tag + ": край-стык у обоих секторов со ссылкой на соседа")
	if e0.is_empty() or e1.is_empty():
		return
	_check(e0["spans"] == e1["spans"], tag + ": проёмы стыка совпадают: %s / %s" % [
		e0["spans"], e1["spans"]])
	var sp: Array = e0["spans"]
	var ok: bool = sp.size() >= 1 and sp.size() <= 3
	for s: Array in sp:
		var wdt := int(s[1]) - int(s[0])
		ok = ok and wdt >= 96 and wdt <= 160 and wdt % 16 == 0
	_check(ok, tag + ": проёмов 1–3 шириной 96–160 кратно 16: %s" % [sp])


func _sides(m: Dictionary, tag: String) -> void:
	var seam := float(m["size"][0]) * 0.5
	var neutral := float(m["procgen"]["pvp"]["neutral"])
	var ok := true
	var count := [0, 0]
	for pl: Dictionary in m["plots"]:
		var side := int(pl.get("side", -1))
		var x := float(pl["pos"][0])
		ok = ok and (side == 0 and x < seam - neutral or side == 1 and x > seam + neutral)
		if side == 0 or side == 1:
			count[side] += 1
	_check(ok and count[0] == count[1] and count[0] >= 3, tag
		+ ": участки на своей половине вне нейтральной полосы %d px, поровну: %s" % [neutral, count])
	var roads_ok := true
	for r: Dictionary in m["roads"]:
		var side := int(r.get("side", -1))
		var last: Array = r["path"][-1]
		roads_ok = roads_ok and (side == 0 or side == 1) and last == m["cauldrons"][side]["pos"]
	_check(roads_ok, tag + ": у каждой дороги side, кончается в Котле своей стороны")
	var gates: Array = m["gates"]
	var g_ok: bool = gates.size() == 2
	for g: Dictionary in gates:
		g_ok = g_ok and int(g["pos"][1]) == 0 and (int(g["side"]) == 0) == (float(g["pos"][0])
			< seam)
	_check(g_ok, tag + ": ворота PvE — по одним на сторону, на верхнем крае своей половины")
	_check(float(m["cauldrons"][0]["pos"][0]) < seam and float(m["cauldrons"][1]["pos"][0]) > seam,
		tag + ": Котлы — по одному на своей половине")


## Проходимость каждой половины от каждого проёма до своего Котла — A* движка (AStarGrid2D) на
## рельефе по правилам LegionTerrain; сетка размером с поле. Отдельно от PgPvp.check (там
## заливка областей) — другой алгоритм на тех же данных.
func _reach(m: Dictionary, tag: String) -> void:
	var size := Vector2(float(m["size"][0]), float(m["size"][1]))
	var rocks := LegionTerrain._polys(m.get("rocks", []))
	for wl in LegionTerrain._walls(m.get("walls", [])):
		rocks.append_array(LegionTerrain._wall_polys(wl))
	rocks = LegionTerrain._clear_roads(rocks, m.get("roads", []))
	var water := LegionTerrain._polys(m.get("water", []))
	var bridges := LegionTerrain._polys(m.get("bridges", []))
	var cell := float(LegionCfg.CELL)
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, ceili(size.x / cell), ceili(size.y / cell))
	grid.cell_size = Vector2(cell, cell)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for y in grid.region.size.y:
		for x in grid.region.size.x:
			var c := Vector2((x + 0.5) * cell, (y + 0.5) * cell)
			var solid := LegionTerrain._inside_any(rocks, c) or (LegionTerrain._inside_any(water, c)
				and not LegionTerrain._inside_any(bridges, c))
			grid.set_point_solid(Vector2i(x, y), solid)
	var seam := size.x * 0.5
	var bad: Array[String] = []
	for sec: Dictionary in m["sectors"]:
		var side := int(sec["side"])
		var cp: Array = m["cauldrons"][side]["pos"]
		var goal := Vector2i(int(float(cp[0]) / cell), int(float(cp[1]) / cell))
		for e: Dictionary in sec["edges"]:
			if e["neighbor"] == null:
				continue
			for s: Array in e["spans"]:
				var y := (float(s[0]) + float(s[1])) * 0.5
				var x := seam - cell * 0.5 if side == 0 else seam + cell * 0.5
				var from := Vector2i(int(x / cell), int(y / cell))
				if grid.get_id_path(from, goal).is_empty():
					bad.append("сторона %d проём %s" % [side, s])
	_check(bad.is_empty(), tag + ": от каждого проёма есть путь до своего Котла: %s" % [bad])


# ── 3. детерминизм ───────────────────────────────────────────────────────────

func _determinism() -> void:
	var a := ProcGen.generate(3, 2, {"pvp": true})
	var b := ProcGen.generate(3, 2, {"pvp": true})
	_check(not a.is_empty() and ProcGen.digest(a) == ProcGen.digest(b),
		"поле 3:2 — два вызова, один хэш")
	_check(ProcGen.digest(ProcGen.map_from_id("gen:3:2:pvp")) == ProcGen.digest(a),
		"map_from_id(gen:3:2:pvp) — тот же словарь")
	_check(String(a.get("id", "")) == "gen:3:2:pvp", "id поля — gen:3:2:pvp")
	var c := ProcGen.generate(4, 2, {"pvp": true})
	_check(ProcGen.digest(c) != ProcGen.digest(a), "другой сид — другое поле")
	_check(_same(a, ProcGen.thaw(ProcGen.freeze(a))), "заморозка поля → разбор → тот же словарь")
	print("хэш поля 3:2 = ", ProcGen.digest(a).left(16))


## Равенство с точностью до int/float (JSON разбирает числа во float) — как в тесте layout.
func _same(a: Variant, b: Variant) -> bool:
	var ok := true
	if (a is int or a is float) and (b is int or b is float):
		ok = is_equal_approx(float(a), float(b))
	elif a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		ok = da.size() == db.size()
		for key: Variant in da:
			ok = ok and db.has(key) and _same(da[key], db[key])
	elif a is Array and b is Array:
		var aa: Array = a
		var ab: Array = b
		ok = aa.size() == ab.size()
		for i in mini(aa.size(), ab.size()):
			ok = ok and _same(aa[i], ab[i])
	else:
		ok = typeof(a) == typeof(b) and a == b
	return ok


# ── 4. архетипы половины ─────────────────────────────────────────────────────

func _archetypes() -> void:
	var list: Array = _half.get_script_constant_map().get("ARCHETYPES", []) if _half != null \
		else []
	_check(list.has("crossing") and list.size() >= 5, "архетипы половины из BOOK §12.3: %s" % [
		list])
	for arch: String in list:
		var got := 0
		for s in range(1, 4):
			var m := ProcGen.generate(s, 1, {"pvp": true, "archetype": arch})
			if m.is_empty() or String(m["procgen"]["card"]["archetype"]) != arch:
				continue
			if _pvp != null and (_pvp.call("check", m) as Array).is_empty():
				got += 1
			if arch == "crossing":
				var pv: Dictionary = m["procgen"]["pvp"]
				_check(pv["seam"] == "river" and pv["quirk"] == "seam_river"
					and (m["bridges"] as Array).size() == (pv["spans"] as Array).size(),
					"переправа %d: река по стыку, мост на каждом проёме (одна изюминка поля)" % s)
		_check(got == 3, "архетип %s складывается на сидах 1–3: %d/3" % [arch, got])
