class_name PgPvp
extends RefCounted
##
## Поле онлайн-PvP «Схватка» из половин процгена (BOOK §12, docs/pvp/DESIGN.md §3, линия L2).
##
##   ProcGen.generate(7, 3, {"pvp": true})                        поле 1600×900 мира, масштаб 0,8
##   ProcGen.generate(7, 3, {"pvp": true, "archetype": "fork"})   заданный архетип половины
##   ProcGen.generate(7, 3, {"pvp": true, "field": [1706, 960], "scale": 0.75})
##   ProcGen.map_from_id("gen:7:3:pvp")
##
## Устройство: у каждой стороны своя половина-карта (сектор). Половина раскладывается обычным
## конвейером PgLayout в своей рамке (PgGeom.set_frame: размер половины, HUD PvP, свободные
## отрезки края) по скелету PgHalf; поле = половина стороны 0 как есть + её образ одним
## преобразованием стороны 1 (Transform2D: x' = W_поля − x). Проёмы стыка совпадают по
## построению: стык — вертикаль x = W_поля/2, и она неподвижна при отражении. Всё, что лежит на
## самом стыке (стена стыка, река и мосты переправы), строится симметричным и кладётся в поле
## один раз.
##
## Двойка в формат не зашита (D-0927-83): поле — список секторов со своим преобразованием
## вида (`sectors[].xf`, DESIGN §3.2 view_xf) и краями `edges` со ссылкой на соседа; у всего, что
## принадлежит стороне, есть `side` (0, 1, …). Для 3–4 игроков нужны свои преобразования
## (поворот сектора) и рамка сектора — сейчас сделано только 1 на 1 (SIDES).
##
## Формат словаря поля — формат кампании (STAGE2 §3) плюс:
##   size [W, H], scale, cauldrons [{side, pos}], cauldron = Котёл стороны 0 (совместимость),
##   roads[] + side, name (имя в половине), kind ("seam" — от проёма к Котлу, "pve" — волны),
##   plots[]/bot_lines[] + side, gates [{side, road, kind, edge, pos}],
##   sectors [{id "p<side>", side, rect [x, y, w, h], cauldron, xf [[a,b],[c,d],[ox,oy]], edges}],
##   edges — все края секторов (с полем sector), procgen.pvp — параметры поля.
## Id дорог, участков, рубежей — "s<side>_<id в половине>".
##

const FIELD := Vector2(1600.0, 900.0)
## Масштаб показа поля в окне 1280×720 (DESIGN §3.1: 0,8 — стартовое число).
const SCALE := 0.8
## Сейчас только 1 на 1: две половины рядом, стык — вертикаль посередине.
const SIDES := 2
const ATTEMPTS_PER_ARCH := 3
const MAX_ATTEMPTS := 15
## Проём стыка не ближе к панелям HUD, чем это (как «≥ 60 от угла» У-6, с запасом на ±48).
const EDGE_GAP := 48.0
## Слабые волны PvE (DESIGN §2.6, решено инстансом): уровень первого объекта, численность ×0,5,
## первая на 60-й секунде, дальше каждые 45 с; одинаковые обеим сторонам.
const PVE_DIFFICULTY := 1.0
const PVE_MULT := 0.5
const PVE_FIRST := 60.0
const PVE_EVERY := 45.0
const PVE_FOES: Array[String] = ["zombie", "beetle"]
const ID_SUFFIX := "pvp"
## Проверка поля: полоса дороги (±23 — край дороги, как в self_check), шаг выборки.
const ROAD_HALF := 23.0
const SAMPLE := 8.0
## Стык закрыт вне проёмов: проверяем точки не ближе этого к концу проёма.
const SEAM_PROBE_GAP := 24.0
## Участок: фундамент ±22×±17 (self_check), не под HUD с запасом.
const PLOT_CORNERS: Array[Vector2] = [Vector2(-22, -17), Vector2(22, -17), Vector2(-22, 17),
	Vector2(22, 17)]
const PLOTS := Vector2i(3, 8)


# ── генерация ────────────────────────────────────────────────────────────────

static func make_id(run_seed: int, k: int) -> String:
	return "%s:%s" % [ProcGen.make_id(run_seed, k), ID_SUFFIX]


static func generate(run_seed: int, k: int, opts: Dictionary) -> Dictionary:
	var field := _vec(opts.get("field", FIELD))
	var scale := float(opts.get("scale", SCALE))
	var half := Vector2(field.x / SIDES, field.y)
	var chain := PgCard.chain(run_seed, maxi(k, 1))
	var base: Dictionary = chain[-1]
	var archs := _arch_order(run_seed, k, String(base["biome"]), String(opts.get("archetype", "")))
	for a in MAX_ATTEMPTS:
		var arch: String = archs[mini(a / ATTEMPTS_PER_ARCH, archs.size() - 1)]
		var map := _try(run_seed, k, _card(base, arch), a, half, field, scale)
		if not map.is_empty():
			return map
	push_warning("ProcGen PvP: поле не сложилось (сид %d, объект %d)" % [run_seed, k])
	return {}


## Порядок архетипов половины: взвешенный жребий без возврата (веса PgHalf × биом §6.1).
static func _arch_order(run_seed: int, k: int, biome: String, forced: String) -> Array[String]:
	if forced != "":
		return [forced]
	var rng := PgRng.make(run_seed, "pvp_arch:%d" % k)
	var pool: Array[String] = []
	var w: Array = []
	for arch in PgHalf.ARCHETYPES:
		var cell := float(PgTables.W[PgTables.arch_cell(arch, biome)])
		if cell > 0.0:
			pool.append(arch)
			w.append(float(PgHalf.WEIGHTS[arch]) * maxf(cell, PgTables.W["R"]))
	var out: Array[String] = []
	while not pool.is_empty():
		var i := PgRng.pick_weighted(rng, w)
		out.append(pool[i])
		pool.remove_at(i)
		w.remove_at(i)
	return out


## Карточка половины: биом и объект — от обычной карточки забега; архетип — половины; изюминок
## ловушек нет (одна изюминка поля — у переправы, общая река, её строит скелет).
static func _card(base: Dictionary, arch: String) -> Dictionary:
	var foes: Array = []
	foes.append_array(PVE_FOES)
	return PgCard.override(base, {"archetype": arch, "mirror": false, "flip": false,
		"side": "left", "quirks": [], "roster": "", "lead": "zombie", "boss": false,
		"foes": foes, "difficulty": PVE_DIFFICULTY, "half": true})


static func _try(run_seed: int, k: int, card: Dictionary, attempt: int, half: Vector2,
		field: Vector2, scale: float) -> Dictionary:
	var hud := hud_rects(field, scale)
	PgGeom.set_frame(half, hud, gate_spans(half, hud))
	var layout := PgLayout.new()
	var hm := layout.build(card, PgRng.make(run_seed, "pvp_layout:%d" % k, attempt))
	PgGeom.reset_frame()
	if hm.is_empty():
		ProcGen._log("pvp " + String(card["archetype"]) + ": " + layout.fail)
		return {}
	hm["procgen"]["card"] = card
	var waves := _waves(hm, layout, card, PgRng.make(run_seed, "pvp_waves:%d" % k, attempt))
	PgNames.apply(hm, card, PgRng.make(run_seed, "pvp_names:%d" % k, attempt))
	var out := _assemble(hm, layout, waves, field, scale)
	out["id"] = make_id(run_seed, k)
	var pg: Dictionary = out["procgen"]
	pg["version"] = ProcGen.VERSION
	pg["seed"] = run_seed
	pg["k"] = k
	pg["card"] = card
	pg["attempt"] = attempt
	pg["unusual"] = card["unusual"]
	pg["difficulty"] = card["difficulty"]
	var bad := check(out)
	if not bad.is_empty():
		ProcGen._log("pvp " + String(card["archetype"]) + ": проверка поля — " + bad[0])
		return {}
	return _ordered(out)


# ── рамка половины ───────────────────────────────────────────────────────────

## Панели HUD в координатах мира поля: экранные прямоугольники одиночной игры, делённые на
## масштаб, и их зеркала. Зеркало — потому что второй игрок видит поле отражённым (DESIGN §3.2):
## важное на любой половине не должно уходить под панели ни у одного из двоих. Итоговый HUD PvP
## делает линия L4 — если он будет другим, поменять здесь.
static func hud_rects(field: Vector2, scale: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r in PgGeom.HUD_RECTS:
		var q := Rect2(r.position / scale, r.size / scale)
		out.append(q)
		out.append(Rect2(field.x - q.end.x, q.position.y, q.size.x, q.size.y))
	return out


## Свободные отрезки края половины: восток (стык) — между панелями у стыка сверху и снизу;
## север (ворота PvE) — от конца высокой панели в левом верхнем углу до нейтральной полосы.
## Запад и юг — нет (юг целиком под панелями карточек и способностей).
static func gate_spans(half: Vector2, hud: Array[Rect2]) -> Dictionary:
	var top := 0.0
	var bottom := half.y
	var north_lo := 0.0
	for r in hud:
		if r.position.x <= half.x and r.end.x >= half.x:
			if r.position.y <= 0.0:
				top = maxf(top, r.end.y)
			else:
				bottom = minf(bottom, r.position.y)
	for r in hud:
		# высокая верхняя панель (глубже полосы у стыка) в западной части половины
		if r.position.y <= 0.0 and r.end.y > top + 1.0 and r.position.x < half.x * 0.5:
			north_lo = maxf(north_lo, r.end.x)
	return {"east": Vector2(ceilf((top + EDGE_GAP) / 16.0) * 16.0,
			floorf((bottom - EDGE_GAP) / 16.0) * 16.0),
		"north": Vector2(north_lo, half.x - PgHalf.NEUTRAL.y),
		"west": Vector2.ZERO, "south": Vector2.ZERO}


static func _vec(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	var a: Array = v
	return Vector2(float(a[0]), float(a[1]))


# ── волны PvE ────────────────────────────────────────────────────────────────

## Волны v0 по дороге PvE половины: PgWaves на «первом объекте» (зомби и курьеры), численность
## ×0,5, первая на 60-й секунде, дальше каждые 45 с. Числа подберёт серия L1 (DESIGN §2.6).
static func _waves(hm: Dictionary, layout: PgLayout, card: Dictionary,
		rng: RandomNumberGenerator) -> Array:
	var pve: Dictionary = hm["roads"][int(layout.nodes["pve_road"])]
	var view := {"roads": [pve], "plots": hm["plots"], "flights": [], "breaches": [],
		"procgen": hm["procgen"]}
	var waves := PgWaves.build(view, card, rng)
	for i in waves.size():
		var w: Dictionary = waves[i]
		if i == 0:
			w["pause"] = PVE_FIRST
		if i < waves.size() - 1:
			w["next_in"] = PVE_EVERY
		for g: Dictionary in w["groups"]:
			g["count"] = maxi(1, roundi(float(g["count"]) * PVE_MULT))
	return waves


# ── поле из половины ─────────────────────────────────────────────────────────

## Преобразование стороны: сторона 0 — тождество, сторона 1 — отражение x' = W − x.
static func side_xf(side: int, field: Vector2) -> Transform2D:
	if side == 0:
		return Transform2D.IDENTITY
	return Transform2D(Vector2(-1, 0), Vector2(0, 1), Vector2(field.x, 0))


static func _assemble(hm: Dictionary, layout: PgLayout, waves: Array, field: Vector2,
		scale: float) -> Dictionary:
	var seam := field.x / SIDES
	var out := {"title": hm["title"], "subtitle": "Схватка", "hint": hm["hint"],
		"theme": hm["theme"], "biome": hm["biome"], "size": [int(field.x), int(field.y)],
		"scale": scale, "cauldron": [], "cauldrons": [], "cauldron_hp": hm["cauldron_hp"],
		"start_army": hm["start_army"], "army_cap": hm["army_cap"]}
	for key: String in ["rocks", "walls", "roads", "breaches", "bot_lines", "water", "bridges",
			"swamp", "crypts", "sleepers", "flights", "decor", "plots", "props", "gates",
			"sectors", "edges"]:
		out[key] = []
	out["ambient"] = {"glows": [], "embers": [], "fog": [], "wisps": [], "water": [],
		"quirk_fx": []}
	out["waves"] = []
	for w: Dictionary in waves:
		var wo := w.duplicate(true)
		wo["groups"] = []
		out["waves"].append(wo)
	var pve_id := String(hm["roads"][int(layout.nodes["pve_road"])]["id"])
	var spans: Array = layout.nodes["spans"]
	var neutral: Rect2 = layout.nodes["neutral"]
	for side in SIDES:
		_place(out, hm, waves, side_xf(side, field), side, seam, pve_id)
		out["sectors"].append(_sector(side, field, seam, spans, int(layout.nodes["pve_gate"]),
			out["cauldrons"][side]["pos"]))
	out["cauldron"] = out["cauldrons"][0]["pos"]
	for sec: Dictionary in out["sectors"]:
		for e: Dictionary in sec["edges"]:
			var eo := e.duplicate(true)
			eo["sector"] = sec["id"]
			out["edges"].append(eo)
	out["bg"] = ""
	out["ground"] = hm["ground"]
	out["procgen"] = {"flip": false, "layout": hm["procgen"].get("layout", {}),
		"pvp": {"sides": SIDES, "field": [int(field.x), int(field.y)],
			"half": [int(seam), int(field.y)], "scale": scale, "neutral": int(neutral.size.x),
			"seam": String(layout.nodes["seam"]),
			"quirk": "seam_river" if String(layout.nodes["seam"]) == "river" else "",
			"spans": spans.duplicate(true), "pve_gate": int(layout.nodes["pve_gate"]),
			"waves": "v0: PgWaves объекта 1 ×%.1f, первая на %d с, дальше каждые %d с" % [
				PVE_MULT, int(PVE_FIRST), int(PVE_EVERY)]}}
	return out


## Лежит ли набор точек на стыке (касается вертикали x = seam): такие вещи симметричны сами и
## кладутся в поле один раз — стороной 0.
static func _on_seam(pts: Array, seam: float) -> bool:
	var lo := INF
	var hi := -INF
	for p: Array in pts:
		lo = minf(lo, float(p[0]))
		hi = maxf(hi, float(p[0]))
	return lo <= seam and hi >= seam


static func _pt(xf: Transform2D, p: Array) -> Array:
	var q := xf * Vector2(float(p[0]), float(p[1]))
	return [roundi(q.x), roundi(q.y)]


static func _pts(xf: Transform2D, src: Array) -> Array:
	var out: Array = []
	for p: Array in src:
		out.append(_pt(xf, p))
	return out


## Многоугольник: при отражении обход меняется — возвращаем исходный.
static func _poly(xf: Transform2D, src: Array) -> Array:
	var out := _pts(xf, src)
	if xf.determinant() < 0.0:
		out.reverse()
	return out


static func _rect(xf: Transform2D, r: Array) -> Array:
	var a := xf * Vector2(float(r[0]), float(r[1]))
	var b := xf * Vector2(float(r[0]) + float(r[2]), float(r[1]) + float(r[3]))
	return [roundi(minf(a.x, b.x)), roundi(minf(a.y, b.y)), int(r[2]), int(r[3])]


static func _sid(side: int, id: String) -> String:
	return "s%d_%s" % [side, id]


## Дорога стыка в половине начинается за краем рамки (x > seam); в поле она начинается на самом
## стыке — продолжение дороги соседа.
static func _clip_seam(path: Array, seam: float) -> Array:
	var p0 := Vector2(float(path[0][0]), float(path[0][1]))
	var p1 := Vector2(float(path[1][0]), float(path[1][1]))
	if p0.x <= seam:
		return path.duplicate(true)
	var t := (p0.x - seam) / (p0.x - p1.x)
	var q := p0.lerp(p1, clampf(t, 0.0, 1.0))
	var out: Array = [[roundi(q.x), roundi(q.y)]]
	for i in range(1, path.size()):
		out.append(path[i])
	return out


static func _place(out: Dictionary, hm: Dictionary, waves: Array, xf: Transform2D, side: int,
		seam: float, pve_id: String) -> void:
	var mirrored := xf.determinant() < 0.0
	var first := side == 0
	out["cauldrons"].append({"side": side, "pos": _pt(xf, hm["cauldron"])})
	for poly: Array in hm["rocks"]:
		out["rocks"].append(_poly(xf, poly))
	for wl: Dictionary in hm["walls"]:
		if _on_seam(wl["path"], seam) and not first:
			continue
		var w := wl.duplicate(true)
		w["path"] = _pts(xf, wl["path"])
		out["walls"].append(w)
	for key: String in ["water", "bridges", "swamp"]:
		for poly: Array in hm[key]:
			if _on_seam(poly, seam) and not first:
				continue
			out[key].append(_poly(xf, poly))
	for r: Dictionary in hm["roads"]:
		var id := String(r["id"])
		var kind := "pve" if id == pve_id else "seam"
		var path: Array = r["path"] if kind == "pve" else _clip_seam(r["path"], seam)
		out["roads"].append({"id": _sid(side, id), "path": _pts(xf, path), "side": side,
			"name": id, "kind": kind})
		if kind == "pve":
			# дорога PvE входит отвесно сверху (PgHalf._attach_pve): ворота — на верхнем крае
			out["gates"].append({"side": side, "road": _sid(side, id), "kind": "pve",
				"edge": "north", "pos": _pt(xf, [path[0][0], 0])})
	for br: Dictionary in hm["breaches"]:
		var b := br.duplicate(true)
		b["road"] = _sid(side, String(br["road"]))
		b["side"] = side
		out["breaches"].append(b)
	for bl: Dictionary in hm["bot_lines"]:
		var l := bl.duplicate(true)
		l["id"] = _sid(side, String(bl["id"]))
		l["road"] = _sid(side, String(bl["road"]))
		l["a"] = _pt(xf, bl["a"])
		l["b"] = _pt(xf, bl["b"])
		var d := xf.basis_xform(Vector2(float(bl["dir"][0]), float(bl["dir"][1])))
		l["dir"] = [snappedf(d.x, 0.001), snappedf(d.y, 0.001)]
		# стрелка считается от порядка a→b; отражение меняет сторону нормали
		if mirrored:
			l["release"] = -int(bl["release"])
		var nx: Array = []
		for n: String in bl["next_ids"]:
			nx.append(_sid(side, n))
		l["next_ids"] = nx
		l["support_id"] = _sid(side, String(bl["support_id"]))
		l["side"] = side
		out["bot_lines"].append(l)
	for key: String in ["crypts", "sleepers"]:
		for c: Dictionary in hm[key]:
			out[key].append({"pos": _pt(xf, c["pos"]), "side": side})
	for fl: Dictionary in hm["flights"]:
		out["flights"].append({"id": _sid(side, String(fl["id"])), "path": _pts(xf, fl["path"]),
			"side": side})
	for d: Dictionary in hm["decor"]:
		out["decor"].append({"kind": d["kind"], "pos": _pt(xf, d["pos"])})
	for pl: Dictionary in hm["plots"]:
		var p := pl.duplicate(true)
		p["id"] = _sid(side, String(pl["id"]))
		p["pos"] = _pt(xf, pl["pos"])
		var serves: Array = []
		for s: String in pl["serves_lines"]:
			serves.append(_sid(side, s))
		p["serves_lines"] = serves
		p["side"] = side
		out["plots"].append(p)
	for pr: Dictionary in hm["props"]:
		if float(pr["pos"][0]) == seam and not first:
			continue
		var p := pr.duplicate(true)
		p["pos"] = _pt(xf, pr["pos"])
		if mirrored and float(pr["pos"][0]) != seam:
			p["flip"] = not bool(pr["flip"])
		out["props"].append(p)
	_place_ambient(out["ambient"], hm["ambient"], xf, first, seam)
	for i in waves.size():
		for g: Dictionary in waves[i]["groups"]:
			var go := g.duplicate(true)
			go["road"] = _sid(side, String(g["road"]))
			out["waves"][i]["groups"].append(go)


static func _place_ambient(dst: Dictionary, src: Dictionary, xf: Transform2D, first: bool,
		seam: float) -> void:
	for g: Dictionary in src.get("glows", []):
		var e := g.duplicate(true)
		e["pos"] = _pt(xf, g["pos"])
		dst["glows"].append(e)
	for key: String in ["embers", "fog", "wisps"]:
		for g: Dictionary in src.get(key, []):
			var e := g.duplicate(true)
			e["rect"] = _rect(xf, g["rect"])
			if e.has("drift"):
				var d := xf.basis_xform(Vector2(float(g["drift"][0]), float(g["drift"][1])))
				e["drift"] = [roundi(d.x), roundi(d.y)]
			dst[key].append(e)
	for g: Dictionary in src.get("water", []):
		if _on_seam(g["poly"], seam) and not first:
			continue
		var e := g.duplicate(true)
		e["poly"] = _poly(xf, g["poly"])
		dst["water"].append(e)
	for g: Dictionary in src.get("quirk_fx", []):
		var e := g.duplicate(true)
		for key: String in ["pos", "poly", "path"]:
			if not g.has(key):
				continue
			var v: Array = g[key]
			e[key] = _pts(xf, v) if not v.is_empty() and v[0] is Array else _pt(xf, v)
		dst["quirk_fx"].append(e)


## Сектор стороны: рамка, Котёл, преобразование вида и края. Край стыка — со ссылкой на соседа;
## верхний край — с воротами PvE (соседа нет). Стороны света краёв отражаются вместе с сектором.
static func _sector(side: int, field: Vector2, seam: float, spans: Array, pve_x: int,
		cauldron: Array) -> Dictionary:
	var xf := side_xf(side, field)
	var mirrored := xf.determinant() < 0.0
	var gate := Vector2(pve_x, 0)
	var g := xf * gate
	var edges: Array = [
		{"id": "edge_west" if mirrored else "edge_east", "side": "west" if mirrored else "east",
			"spans": spans.duplicate(true), "neighbor": "p%d" % (1 - side)},
		{"id": "edge_north", "side": "north",
			"spans": [[roundi(g.x) - 48, roundi(g.x) + 48]], "neighbor": null}]
	var x0 := 0.0 if side == 0 else seam
	return {"id": "p%d" % side, "side": side, "rect": [int(x0), 0, int(seam), int(field.y)],
		"cauldron": cauldron, "xf": [[xf.x.x, xf.x.y], [xf.y.x, xf.y.y],
			[xf.origin.x, xf.origin.y]], "edges": edges}


static func _ordered(map: Dictionary) -> Dictionary:
	var out := {}
	for key: String in ProcGen.KEY_ORDER:
		if map.has(key):
			out[key] = map[key]
	for key: String in ["size", "scale", "cauldrons", "gates", "sectors"]:
		if map.has(key) and not out.has(key):
			out[key] = map[key]
	for key: String in map:
		if not out.has(key):
			out[key] = map[key]
	return out


# ── проверка поля ────────────────────────────────────────────────────────────

## Нарушения, которые поле обещает по построению (пусто — годно). Своя проверка, а не
## LegionTerrain/PgFilter: те пока знают только кадр 1280×720 (LegionCfg.WORLD_SIZE). Рельеф —
## те же правила, что у LegionTerrain (скалы + контуры стен, подрезанные полосой дороги; вода
## без мостов), на сетке 16 px размера поля.
static func check(map: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if not map.has("size") or not map.has("sectors") or (map["sectors"] as Array).size() != SIDES:
		out.append("не поле PvP (нет size/sectors)")
		return out
	var size := _vec(map["size"])
	var seam := size.x / SIDES
	var hud := hud_rects(size, float(map.get("scale", SCALE)))
	var relief := Relief.new(map)
	var cauldrons: Array[Vector2] = []
	for c: Dictionary in map["cauldrons"]:
		cauldrons.append(_v(c["pos"]))
	for i in cauldrons.size():
		var c := cauldrons[i]
		if c.x < 110.0 or c.y < 110.0 or c.x > size.x - 110.0 or c.y > size.y - 110.0 \
				or _in(hud, c, 60.0):
			out.append("Котёл стороны %d у края или под HUD" % i)
		if not relief.walkable(c):
			out.append("Котёл стороны %d не на суше" % i)
	# дороги: кончаются в своём Котле, проходимы с краями
	var paths := {}
	for r: Dictionary in map["roads"]:
		var p := PackedVector2Array()
		for q: Array in r["path"]:
			p.append(_v(q))
		paths[r["id"]] = p
		var side := int(r["side"])
		if p[-1] != cauldrons[side]:
			out.append("%s не кончается в Котле своей стороны" % r["id"])
		var total := PgGeom.length(p)
		var n := ceili(total / SAMPLE)
		for s in n + 1:
			var at := total * s / n
			var q := PgGeom.point_at(p, at)
			if q.x < 0.0 or q.y < 0.0 or q.x > size.x or q.y > size.y:
				continue
			var t := PgGeom.tangent_at(p, at).orthogonal()
			var ok := true
			for off: float in [-ROAD_HALF, 0.0, ROAD_HALF]:
				ok = ok and relief.walkable(q + t * off)
			if not ok:
				out.append("%s перекрыта у (%d, %d)" % [r["id"], q.x, q.y])
				break
	# стык: проёмы проходимы, между ними закрыто; проёмы соседей совпадают
	var sec0: Dictionary = map["sectors"][0]
	var sec1: Dictionary = map["sectors"][1]
	var spans0: Array = _edge(sec0, String(sec1["id"]))
	var spans1: Array = _edge(sec1, String(sec0["id"]))
	if spans0.is_empty() or JSON.stringify(spans0) != JSON.stringify(spans1):
		out.append("проёмы стыка у соседей не совпадают: %s / %s" % [spans0, spans1])
	if spans0.size() < 1 or spans0.size() > 3:
		out.append("проёмов стыка %d (нужно 1–3)" % spans0.size())
	for s: Array in spans0:
		var wdt := int(s[1]) - int(s[0])
		if wdt < PgHalf.SPAN_W.x or wdt > PgHalf.SPAN_W.y or wdt % 16 != 0:
			out.append("проём %s шириной %d (96–160, кратно 16)" % [s, wdt])
	var y := SAMPLE
	while y < size.y:
		var inside := false
		var near_end := false
		for s: Array in spans0:
			inside = inside or (y >= float(s[0]) and y <= float(s[1]))
			near_end = near_end or absf(y - float(s[0])) < SEAM_PROBE_GAP \
				or absf(y - float(s[1])) < SEAM_PROBE_GAP
		if not near_end:
			var open := relief.walkable(Vector2(seam, y))
			if inside and not open:
				out.append("проём стыка закрыт у y %d" % y)
			elif not inside and open:
				out.append("стык открыт вне проёмов у y %d" % y)
		y += SAMPLE
	# связность: от каждого проёма — до обоих Котлов (свой Котёл достижим от стыка, и поле
	# едино); каждая сторона — со своей половины стыка
	for s: Array in spans0:
		var mid := (float(s[0]) + float(s[1])) * 0.5
		for side in SIDES:
			var at := Vector2(seam - 8.0 if side == 0 else seam + 8.0, mid)
			for c in cauldrons:
				if not relief.connected(at, c):
					out.append("от проёма y %d (сторона %d) нет пути к Котлу (%d, %d)" % [
						mid, side, c.x, c.y])
	var neutral := float(map["procgen"]["pvp"]["neutral"])
	var per_side: Array[int] = []
	per_side.resize(SIDES)
	for pl: Dictionary in map["plots"]:
		var p := _v(pl["pos"])
		var side := int(pl["side"])
		per_side[side] += 1
		for corner in PLOT_CORNERS:
			if not relief.walkable(p + corner):
				out.append("%s фундамент не на суше" % pl["id"])
				break
		if not relief.connected(p, cauldrons[side]):
			out.append("%s недостижим от своего Котла" % pl["id"])
		if _in(hud, p, 8.0):
			out.append("%s под HUD" % pl["id"])
		if absf(p.x - seam) < neutral:
			out.append("%s в нейтральной полосе" % pl["id"])
		if (side == 0) != (p.x < seam):
			out.append("%s не на своей половине" % pl["id"])
	for side in SIDES:
		if per_side[side] < PLOTS.x or per_side[side] > PLOTS.y:
			out.append("участков у стороны %d: %d" % [side, per_side[side]])
	for poly: Array in map["rocks"]:
		for q: Array in poly:
			if absf(float(q[0]) - seam) < neutral:
				out.append("препятствие в нейтральной полосе у (%d, %d)" % [q[0], q[1]])
				break
	for bl: Dictionary in map["bot_lines"]:
		var a := _v(bl["a"])
		var b := _v(bl["b"])
		var path: PackedVector2Array = paths.get(bl["road"], PackedVector2Array())
		var cross := false
		for i in range(1, path.size()):
			cross = cross or Geometry2D.segment_intersects_segment(a, b, path[i - 1],
				path[i]) != null
		if not cross:
			out.append("%s не пересекает свою дорогу" % bl["id"])
		for s in 9:
			if not relief.walkable(a.lerp(b, s / 8.0)):
				out.append("%s непроходим" % bl["id"])
				break
		if _in(hud, a, 0.0) or _in(hud, b, 0.0):
			out.append("%s под HUD" % bl["id"])
	for g: Dictionary in map["gates"]:
		var p := _v(g["pos"])
		if p.y > 0.5:
			out.append("ворота PvE %s не на верхнем крае" % g["road"])
	return out


static func _edge(sec: Dictionary, neighbor: String) -> Array:
	for e: Dictionary in sec["edges"]:
		if e["neighbor"] != null and String(e["neighbor"]) == neighbor:
			return e["spans"]
	return []


static func _v(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


static func _in(rects: Array[Rect2], p: Vector2, margin: float) -> bool:
	for r in rects:
		if r.grow(margin).has_point(p):
			return true
	return false


## Рельеф поля любого размера по правилам LegionTerrain: скалы и контуры стен (подрезанные
## полосой дороги ROAD_CLEAR), вода без мостов; связные области по четырём соседям на сетке
## LegionCfg.CELL — как _label_regions движка.
class Relief:
	var rocks: Array[PackedVector2Array] = []
	var boxes: Array[Rect2] = []
	var water: Array[PackedVector2Array] = []
	var bridges: Array[PackedVector2Array] = []
	var size := Vector2.ZERO
	var cols := 0
	var rows := 0
	var comp := PackedInt32Array()

	func _init(map: Dictionary) -> void:
		size = PgPvp._vec(map["size"])
		rocks = LegionTerrain._polys(map.get("rocks", []))
		for wl in LegionTerrain._walls(map.get("walls", [])):
			rocks.append_array(LegionTerrain._wall_polys(wl))
		rocks = LegionTerrain._clear_roads(rocks, map.get("roads", []))
		boxes = LegionTerrain._boxes(rocks)
		water = LegionTerrain._polys(map.get("water", []))
		bridges = LegionTerrain._polys(map.get("bridges", []))
		var cell := float(LegionCfg.CELL)
		cols = ceili(size.x / cell)
		rows = ceili(size.y / cell)
		comp.resize(cols * rows)
		comp.fill(-1)
		var open := PackedByteArray()
		open.resize(cols * rows)
		for y in rows:
			for x in cols:
				open[y * cols + x] = 1 if walkable(Vector2((x + 0.5) * cell, (y + 0.5) * cell)) \
					else 0
		var region := 0
		for start in cols * rows:
			if comp[start] != -1 or open[start] == 0:
				continue
			comp[start] = region
			var stack := PackedInt32Array([start])
			while not stack.is_empty():
				var k := stack[stack.size() - 1]
				stack.resize(stack.size() - 1)
				var cx := k % cols
				var cy := k / cols
				for nb: int in [k - 1 if cx > 0 else -1, k + 1 if cx < cols - 1 else -1,
						k - cols if cy > 0 else -1, k + cols if cy < rows - 1 else -1]:
					if nb >= 0 and comp[nb] == -1 and open[nb] == 1:
						comp[nb] = region
						stack.append(nb)
			region += 1

	## Точно по многоугольникам (как is_rock + вода/мост движка).
	func walkable(p: Vector2) -> bool:
		if LegionTerrain._inside_boxed(rocks, boxes, p):
			return false
		return not LegionTerrain._inside_any(water, p) or LegionTerrain._inside_any(bridges, p)

	func region(p: Vector2) -> int:
		var cell := float(LegionCfg.CELL)
		var x := clampi(int(p.x / cell), 0, cols - 1)
		var y := clampi(int(p.y / cell), 0, rows - 1)
		return comp[y * cols + x]

	func connected(a: Vector2, b: Vector2) -> bool:
		var ra := region(a)
		return ra >= 0 and ra == region(b)
