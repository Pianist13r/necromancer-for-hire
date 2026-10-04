class_name LegionQuirkFx
extends Node2D
##
## Эффекты логики уровня процедурной карты (BOOK §8.5 п.2, D-0927-68; линия art3, 27.09.2026).
## Главное правило: эффект СООБЩАЕТ о механике места, а не украшает. Источник — `ambient.quirk_fx`
## словаря карты (раскладка кладёт туда {kind, pos|poly|path, id}, LAYOUT.md), состояние — мир:
##   breach        трещина «дышит» и светится сильнее к волне, которая её откроет (волны мира),
##                 горит ровно после открытия;
##   sleeper       спящий мимик «похрапывает»: Zz и пар, пока он спит (Foe.State.SLEEP);
##   flight        едва видный бирюзовый след призрачного пролёта сквозь стены;
##   swamp_road    топь на дороге пускает пузыри там, где вязнут (точки на полотне — чаще);
##   coffee        пролитый кофе в конторе парит;
##   throat_lights / bridge_lights — фонари у горла и моста ярче: место драки освещено;
##   crypt         захваченный склеп теплеет, вражеский — холодная дымка;
##   golden_pit    золотая яма поблёскивает.
## Плюс тихий эффект биома (§8.5 п.3), которого раскладка не даёт: пепел-угли на пустыре,
## светлячки у деревьев кладбища, пыль у дороги на стройке, пылинки в конторе.
##
## Не спорит с игрой (§8.5 п.4): прозрачность низкая, ниже боевых вспышек, частиц единицы, на
## полотно дороги — только пузыри топи (они и есть сообщение «здесь вязнут»). Живёт внутри
## LegionFx, поэтому «экономная графика» (B-053) выключает его вместе со всем слоем эффектов.
## Свой ГСЧ: мир и его world.rng не трогаются. Время — реальный dt (как у LegionFx).
##

const C_CRACK := Color(1.0, 0.55, 0.22)
const C_CRACK_CORE := Color(1.0, 0.86, 0.55)
const C_GHOST := Color(0.5, 1.0, 0.85)
const C_ZZ := Color(0.93, 0.92, 1.0)
const C_STEAM := Color(0.92, 0.94, 1.0)
const C_BUBBLE := Color(0.78, 0.95, 0.82)
const C_COFFEE := Color(0.95, 0.9, 0.82)
const C_WARM := Color(1.0, 0.74, 0.4)
const C_COLD := Color(0.62, 0.72, 0.9)
const C_GOLD := Color(1.0, 0.85, 0.3)
const C_EMBER := Color(1.0, 0.5, 0.2)
const C_FIREFLY := Color(0.86, 1.0, 0.45)
const C_DUST := Color(0.9, 0.82, 0.68)
const C_MOTE := Color(1.0, 0.95, 0.82)

## Трещина: дыхание ускоряется и ярчает к открытию (k 0…1); после открытия — ровное тление.
const CRACK_LEN := Vector2(34.0, 50.0)
const CRACK_SEGS := 6
const CRACK_JAG := 7.0
const CRACK_GLOW_R := Vector2(22.0, 56.0)
const CRACK_GLOW_A := Vector2(0.10, 0.34)
const CRACK_LINE_A := Vector2(0.35, 0.95)
const CRACK_BREATH_F := Vector2(1.2, 3.6) ## рад/с при k=0 и k=1
const CRACK_EMBERS := Vector2(0.3, 2.6)  ## искр/с
const CRACK_K_MIN := 0.25
const CRACK_OPEN_K := 0.4

## Мимик: Z раз в ZZ_EVERY с, поднимается и тает; пар — реже.
const ZZ_EVERY := 1.7
const ZZ_LIFE := 2.3
const ZZ_RISE := 22.0
const ZZ_DRIFT := 9.0
const ZZ_FONT := Vector2(13.0, 22.0)
const ZZ_ALPHA := 0.75
const ZZ_LIFT := 26.0 ## над точкой мимика (земля) — у головы
const SLEEP_R := 48.0
const STEAM_EVERY := 2.6

## След пролёта: пунктир медленно течёт по направлению полёта.
const FLIGHT_A := 0.16
const FLIGHT_W := 2.2
const FLIGHT_DASH := 14.0
const FLIGHT_GAP := 12.0
const FLIGHT_SPEED := 18.0

## Пузыри топи: кольцо растёт и лопается; на полотне дороги — вдвое чаще (там вязнут).
const BUBBLE_RATE := 1.6
const BUBBLE_R := Vector2(1.5, 4.5)
const BUBBLE_LIFE := 0.9
const BUBBLE_A := 0.55
const ROAD_HALF := 23.0
const BUBBLE_ROAD_TRIES := 6
const COFFEE_RATE := 0.9
const STEAM_LIFE := 2.0
const STEAM_RISE := 16.0
const STEAM_SIZE := Vector2(5.0, 12.0)
const STEAM_A := 0.16

## Свет у горла/моста: ореолы фонарей поблизости шире и ярче.
const LIGHT_NEAR := 150.0
const LIGHT_BOOST_R := 1.7
const LIGHT_BOOST_A := 0.11
const LIGHT_POOL_R := 70.0
const LIGHT_POOL_A := 0.07
const LIGHT_FLICKER := 0.2

const CRYPT_WARM_R := 44.0
const CRYPT_WARM_A := 0.2
const CRYPT_COLD_A := 0.12
const GOLD_RATE := 0.9
const GOLD_SPREAD := 20.0
const GOLD_LIFE := 0.7

## Биом — тихо: частота и прозрачность ниже всего остального.
const BIOME_RATE := {"ash": 0.7, "grave": 0.0, "site": 0.5, "office": 0.4}
const FIREFLY_PER_TREE := 2
const FIREFLY_A := 0.55
const FIREFLY_R := 26.0
const BIOME_LIFE := Vector2(2.5, 4.5)
const BIOME_CLEAR := 36.0 ## не ближе к оси дороги

const PART_CAP := 90

var world: LegionWorld = null
var low: Node2D = null
var rng := RandomNumberGenerator.new()
var _glow: Texture2D = null
var _font: Font = null
var _clock := 0.0
## Разобранные эффекты карты: {kind, pos, poly, path, id, ...состояние}.
var _items: Array[Dictionary] = []
## Частицы: {kind, pos, vel, age, life, size, color}; kind — ember/zz/steam/bubble/gold/mote.
var _parts: Array[Dictionary] = []
var _flies: Array[Dictionary] = []
var _biome := ""
var _biome_acc := 0.0
var _roads: Array[PackedVector2Array] = []
var _glows: Array[Dictionary] = []
var _warned: Dictionary = {}   ## id трещины → true, пока идёт предупреждение
var _opened: Dictionary = {}


func setup(fx: LegionFx, w: LegionWorld, ground: Node2D, glow: Texture2D) -> void:
	world = w
	name = "QuirkFx"
	rng.randomize()
	_glow = glow
	_font = ThemeDB.fallback_font
	low = Node2D.new()
	low.name = "QuirkLow"
	ground.add_child(low)
	low.draw.connect(_draw_low)
	if w != null:
		w.breach_warned.connect(_on_breach_warned)
		w.breach_opened.connect(_on_breach_opened)
	fx.tree_exiting.connect(_on_fx_exit)


func _on_fx_exit() -> void:
	if is_instance_valid(low):
		low.queue_free()


func clear() -> void:
	_items.clear()
	_parts.clear()
	_flies.clear()
	_warned.clear()
	_opened.clear()
	_roads.clear()
	_glows.clear()
	_biome = ""
	queue_redraw()
	if low != null:
		low.queue_redraw()


## Сколько эффектов логики уровня разобрано (тест, отчёт).
func count() -> int:
	return _items.size()


func kinds() -> PackedStringArray:
	var out := PackedStringArray()
	for it in _items:
		out.append(String(it["kind"]))
	return out


func load_map(map: Dictionary) -> void:
	clear()
	_biome = String(map.get("biome", "")) if map.has("procgen") else ""
	for road: Dictionary in map.get("roads", []):
		_roads.append(_path(road.get("path", [])))
	var amb: Dictionary = map.get("ambient", {})
	for g: Dictionary in amb.get("glows", []):
		_glows.append({"pos": _vec(g.get("pos", [0, 0])), "r": float(g.get("r", 24.0)),
			"ph": rng.randf() * TAU})
	for q: Dictionary in amb.get("quirk_fx", []):
		var it := {"kind": String(q.get("kind", "")), "id": String(q.get("id", "")),
			"pos": _vec(q.get("pos", [0, 0])), "poly": _path(q.get("poly", [])),
			"path": _path(q.get("path", [])), "acc": 0.0, "acc2": rng.randf(),
			"ph": rng.randf() * TAU}
		if it["kind"] == "breach":
			it["crack"] = _crack(it["pos"])
			it["wave"] = _breach_wave(String(it["id"]))
		_items.append(it)
	if _biome == "grave" or _biome == "swamp":
		for p: Dictionary in map.get("props", []):
			var item := PgCatalog.by_id(String(p.get("item", "")))
			if not (item.get("tags", []) as Array).has("tree"):
				continue
			var at := _vec(p.get("pos", [0, 0])) + Vector2(0, -float(item.get("w", 80.0)) * 0.35)
			for k in FIREFLY_PER_TREE:
				_flies.append({"home": at, "ph": rng.randf() * TAU, "f": rng.randf_range(0.3, 0.6),
					"blink": rng.randf_range(1.2, 2.4)})


static func _vec(v: Variant) -> Vector2:
	var a := v as Array
	# у recruit_link «pos» — пара точек (два участка), не точка
	if a == null or a.size() < 2 or a[0] is Array:
		return Vector2.ZERO
	return Vector2(float(a[0]), float(a[1]))


static func _path(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	var a := v as Array
	if a == null:
		return out
	for p: Variant in a:
		out.append(_vec(p))
	return out


## Трещина — ломаная поперёк земли, детерминированная от точки (одна и та же карта — одна
## и та же трещина, как нарисованная).
func _crack(at: Vector2) -> PackedVector2Array:
	var r := RandomNumberGenerator.new()
	r.seed = hash(Vector2i(at))
	var ln := r.randf_range(CRACK_LEN.x, CRACK_LEN.y)
	var ang := r.randf_range(-0.5, 0.5)
	var dir := Vector2.RIGHT.rotated(ang)
	var out := PackedVector2Array()
	for s in CRACK_SEGS + 1:
		var t := float(s) / CRACK_SEGS - 0.5
		var jag := r.randf_range(-CRACK_JAG, CRACK_JAG) * (1.0 - absf(t) * 1.6)
		out.append(at + dir * ln * t + dir.orthogonal() * jag)
	return out


## Номер волны (0…), которая открывает трещину: первая волна с группой из неё.
func _breach_wave(id: String) -> int:
	if world == null or world.wave_runner == null:
		return -1
	var waves: Array = world.wave_runner.waves
	for i in waves.size():
		for g: Dictionary in (waves[i] as Dictionary).get("groups", []):
			if String(g.get("breach", "")) == id:
				return i
	return -1


func _on_breach_warned(id: String, _in_s: float, _summary: Array) -> void:
	_warned[id] = true


func _on_breach_opened(id: String) -> void:
	_warned.erase(id)
	_opened[id] = true


## Сила трещины 0…1: растёт с номером текущей волны к волне открытия; 1 — пока идёт
## предупреждение; после открытия — ровное тление CRACK_OPEN_K.
func breach_k(it: Dictionary) -> float:
	var id := String(it["id"])
	if _opened.has(id):
		return CRACK_OPEN_K
	if _warned.has(id):
		return 1.0
	var target := int(it.get("wave", -1))
	if target < 0:
		# волны могли ещё не разобраться к старту карты — ищем при первом кадре
		target = _breach_wave(id)
		it["wave"] = target
	if target < 0 or world == null or world.wave_runner == null:
		return CRACK_K_MIN
	var cur := world.wave_runner.index + 1
	return clampf(float(cur) / float(target + 1), CRACK_K_MIN, 0.9)


func _sleeping(at: Vector2) -> bool:
	if world == null:
		return false
	for f in world.foes:
		if f.type_id == "mimic" and f.state == Foe.State.SLEEP \
				and f.position.distance_to(at) < SLEEP_R:
			return true
	return false


func _crypt_side(at: Vector2) -> int:
	if world == null:
		return LegionCrypt.Owner.NEUTRAL
	for c in world.crypts:
		if c.position.distance_to(at) < 60.0:
			return c.allegiance
	return LegionCrypt.Owner.NEUTRAL


# ── Шаг ─────────────────────────────────────────────────────────────────────

func tick(dt: float) -> void:
	if _items.is_empty() and _biome == "" and _parts.is_empty():
		return
	_clock += dt
	for it in _items:
		match String(it["kind"]):
			"breach":
				var k := breach_k(it)
				_emit_every(it, lerpf(CRACK_EMBERS.x, CRACK_EMBERS.y, k), dt, &"ember")
			"sleeper":
				if _sleeping(it["pos"]):
					_emit_every(it, 1.0 / ZZ_EVERY, dt, &"zz")
					it["acc2"] = float(it["acc2"]) + dt / STEAM_EVERY
					if float(it["acc2"]) >= 1.0:
						it["acc2"] = 0.0
						_spawn(&"steam", it["pos"] + Vector2(rng.randf_range(-8, 8), -8.0))
			"swamp_road":
				_emit_every(it, BUBBLE_RATE, dt, &"bubble")
			"coffee":
				_emit_every(it, COFFEE_RATE, dt, &"steam")
			"golden_pit":
				_emit_every(it, GOLD_RATE, dt, &"gold")
			"crypt":
				if _crypt_side(it["pos"]) == LegionCrypt.Owner.ENEMY:
					_emit_every(it, 1.0 / STEAM_EVERY, dt, &"steam")
	_tick_biome(dt)
	for i in range(_parts.size() - 1, -1, -1):
		var p := _parts[i]
		p["age"] = float(p["age"]) + dt
		if float(p["age"]) >= float(p["life"]):
			_parts.remove_at(i)
			continue
		p["pos"] = (p["pos"] as Vector2) + (p["vel"] as Vector2) * dt
	queue_redraw()
	low.queue_redraw()


func _emit_every(it: Dictionary, rate: float, dt: float, kind: StringName) -> void:
	var acc := float(it["acc"]) + rate * dt
	while acc >= 1.0:
		acc -= 1.0
		_spawn(kind, _source(it, kind))
	it["acc"] = acc


## Точка рождения частицы эффекта: у трещины — на её ломаной, у топи — в полигоне (на полотне
## дороги — в первую очередь: пузыри говорят «здесь вязнут»).
func _source(it: Dictionary, kind: StringName) -> Vector2:
	match kind:
		&"ember":
			var crack: PackedVector2Array = it["crack"]
			var i := rng.randi_range(0, crack.size() - 2)
			return crack[i].lerp(crack[i + 1], rng.randf())
		&"zz":
			return (it["pos"] as Vector2) + Vector2(6.0, -ZZ_LIFT)
		&"gold":
			return (it["pos"] as Vector2) + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) \
				* GOLD_SPREAD
	var poly: PackedVector2Array = it["poly"]
	if poly.size() < 3:
		return it["pos"]
	var box := Rect2(poly[0], Vector2.ZERO)
	for v in poly:
		box = box.expand(v)
	var fallback := box.get_center()
	for t in BUBBLE_ROAD_TRIES * 2:
		var p := box.position + Vector2(rng.randf(), rng.randf()) * box.size
		if not Geometry2D.is_point_in_polygon(p, poly):
			continue
		fallback = p
		if kind != &"bubble" or t >= BUBBLE_ROAD_TRIES or _on_road(p):
			return p
	return fallback


func _on_road(p: Vector2) -> bool:
	for path in _roads:
		for i in path.size() - 1:
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p, path[i], path[i + 1])) \
					< ROAD_HALF:
				return true
	return false


func _spawn(kind: StringName, at: Vector2) -> void:
	if _parts.size() >= PART_CAP:
		return
	var p := {"kind": kind, "pos": at, "vel": Vector2.ZERO, "age": 0.0, "life": 1.0,
		"size": 1.0, "color": Color.WHITE}
	match kind:
		&"ember":
			p["vel"] = Vector2(rng.randf_range(-4, 4), -rng.randf_range(10, 22))
			p["life"] = rng.randf_range(0.8, 1.4)
			p["size"] = rng.randf_range(1.2, 2.2)
			p["color"] = C_EMBER
		&"zz":
			p["vel"] = Vector2(ZZ_DRIFT, -ZZ_RISE) / ZZ_LIFE
			p["life"] = ZZ_LIFE
			p["color"] = C_ZZ
		&"steam":
			p["vel"] = Vector2(rng.randf_range(-3, 3), -STEAM_RISE / STEAM_LIFE)
			p["life"] = STEAM_LIFE
			p["color"] = C_COFFEE if _parts.size() % 2 == 0 else C_STEAM
		&"bubble":
			p["life"] = BUBBLE_LIFE * rng.randf_range(0.8, 1.2)
			p["color"] = C_BUBBLE
		&"gold":
			p["life"] = GOLD_LIFE
			p["size"] = rng.randf_range(2.0, 3.5)
			p["color"] = C_GOLD
		&"mote":
			p["vel"] = Vector2(rng.randf_range(-4, 4), -rng.randf_range(2, 7))
			p["life"] = rng.randf_range(BIOME_LIFE.x, BIOME_LIFE.y)
			p["size"] = rng.randf_range(0.9, 1.6)
			p["color"] = C_EMBER if _biome == "ash" else (C_DUST if _biome == "site" else C_MOTE)
	_parts.append(p)


## Тихий фон биома (§8.5 п.3): редкие угли/пылинки в случайных местах земли, не на дороге.
func _tick_biome(dt: float) -> void:
	var rate := float(BIOME_RATE.get(_biome, 0.0))
	if rate <= 0.0:
		return
	_biome_acc += rate * dt
	while _biome_acc >= 1.0:
		_biome_acc -= 1.0
		for t in 4:
			var p := Vector2(rng.randf_range(40, 1240), rng.randf_range(150, 640))
			var near := false
			for path in _roads:
				for i in path.size() - 1:
					if p.distance_to(Geometry2D.get_closest_point_to_segment(p, path[i],
							path[i + 1])) < BIOME_CLEAR:
						near = true
						break
			if not near:
				_spawn(&"mote", p)
				break


# ── Отрисовка ───────────────────────────────────────────────────────────────

func _fade(p: Dictionary) -> float:
	var t := float(p["age"]) / maxf(float(p["life"]), 0.001)
	return clampf(minf(t / 0.2, (1.0 - t) / 0.35), 0.0, 1.0)


func _halo(ci: CanvasItem, at: Vector2, r: float, c: Color) -> void:
	if _glow == null:
		ci.draw_circle(at, r * 0.5, c)
		return
	ci.draw_texture_rect(_glow, Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), false, c)


## Земля (под бойцами): свечение трещины, след пролёта, свет у горла, пузыри, склеп.
func _draw_low() -> void:
	for it in _items:
		match String(it["kind"]):
			"breach":
				_draw_crack(it)
			"flight":
				_draw_flight(it["path"])
			"throat_lights", "bridge_lights":
				_draw_lights(it)
			"crypt":
				var side := _crypt_side(it["pos"])
				if side == LegionCrypt.Owner.PLAYER:
					var b := 0.85 + 0.15 * sin(_clock * 1.3 + float(it["ph"]))
					_halo(low, it["pos"], CRYPT_WARM_R * b, Color(C_WARM, CRYPT_WARM_A * b))
				elif side == LegionCrypt.Owner.ENEMY:
					_halo(low, it["pos"], CRYPT_WARM_R, Color(C_COLD, CRYPT_COLD_A))
	for p in _parts:
		if p["kind"] == &"bubble":
			var t := float(p["age"]) / float(p["life"])
			var r := lerpf(BUBBLE_R.x, BUBBLE_R.y, t)
			low.draw_arc(p["pos"], r, 0.0, TAU, 12,
				Color(p["color"], BUBBLE_A * (1.0 - t * t)), 1.0, true)
	for f in _flies:
		var ph := float(f["ph"])
		var at: Vector2 = f["home"] + Vector2(sin(_clock * float(f["f"]) + ph) * FIREFLY_R,
			cos(_clock * float(f["f"]) * 1.3 + ph * 2.0) * FIREFLY_R * 0.5)
		var blink := maxf(0.0, sin(_clock * float(f["blink"]) + ph))
		if blink > 0.05:
			_halo(low, at, 5.0, Color(C_FIREFLY, FIREFLY_A * blink))


func _draw_crack(it: Dictionary) -> void:
	var k := breach_k(it)
	var f := lerpf(CRACK_BREATH_F.x, CRACK_BREATH_F.y, k)
	var b := 0.5 + 0.5 * sin(_clock * f + float(it["ph"]))
	var at: Vector2 = it["pos"]
	var r := lerpf(CRACK_GLOW_R.x, CRACK_GLOW_R.y, k) * (0.9 + 0.2 * b)
	_halo(low, at, r, Color(C_CRACK, lerpf(CRACK_GLOW_A.x, CRACK_GLOW_A.y, k) * (0.7 + 0.3 * b)))
	var crack: PackedVector2Array = it["crack"]
	var la := lerpf(CRACK_LINE_A.x, CRACK_LINE_A.y, k) * (0.65 + 0.35 * b)
	low.draw_polyline(crack, Color(0.08, 0.03, 0.02, 0.6), 3.4, true)
	low.draw_polyline(crack, Color(C_CRACK, la), 2.0, true)
	low.draw_polyline(crack, Color(C_CRACK_CORE, la * b), 0.9, true)


func _draw_flight(path: PackedVector2Array) -> void:
	if path.size() < 2:
		return
	var period := FLIGHT_DASH + FLIGHT_GAP
	var shift := fmod(_clock * FLIGHT_SPEED, period)
	for i in path.size() - 1:
		var a := path[i]
		var b := path[i + 1]
		var ln := a.distance_to(b)
		var dir := (b - a) / maxf(ln, 0.01)
		var d := shift - period
		while d < ln:
			var s := maxf(d, 0.0)
			var e := minf(d + FLIGHT_DASH, ln)
			if e > s:
				var mid := (s + e) * 0.5 / maxf(ln, 1.0)
				# к концам отрезка тише — след «проступает», а не нарисован линейкой
				var a_mul := 0.55 + 0.45 * sin(mid * PI)
				low.draw_line(a + dir * s, a + dir * e, Color(C_GHOST, FLIGHT_A * a_mul),
					FLIGHT_W, true)
			d += period


func _draw_lights(it: Dictionary) -> void:
	var at: Vector2 = it["pos"]
	var fl := 1.0 - LIGHT_FLICKER * (0.5 + 0.5 * sin(_clock * 5.3 + float(it["ph"])))
	_halo(low, at, LIGHT_POOL_R, Color(C_WARM, LIGHT_POOL_A * fl))
	for g in _glows:
		var gp: Vector2 = g["pos"]
		if gp.distance_to(at) > LIGHT_NEAR:
			continue
		var gf := 1.0 - LIGHT_FLICKER * (0.5 + 0.5 * sin(_clock * 4.1 + float(g["ph"])))
		_halo(low, gp, float(g["r"]) * LIGHT_BOOST_R, Color(C_WARM, LIGHT_BOOST_A * gf))


## Воздух (над бойцами): Zz мимика, пар, искры трещины, блёстки, угли и пылинки биома.
func _draw() -> void:
	for p in _parts:
		var a := _fade(p)
		match p["kind"]:
			&"ember", &"gold", &"mote":
				var tw := 1.0 if p["kind"] != &"gold" else absf(sin(float(p["age"]) * 9.0))
				_halo(self, p["pos"], float(p["size"]) * 2.4, Color(p["color"], 0.5 * a * tw))
				draw_circle(p["pos"], float(p["size"]) * 0.5, Color(p["color"], 0.8 * a * tw))
			&"zz":
				var t := float(p["age"]) / float(p["life"])
				var fs := int(lerpf(ZZ_FONT.x, ZZ_FONT.y, t))
				# тёмная обводка — «z» читается и на светлой дороге, и на тёмной земле
				draw_string_outline(_font, p["pos"], "z", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3,
					Color(0.1, 0.08, 0.16, ZZ_ALPHA * a * 0.7))
				draw_string(_font, p["pos"], "z", HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
					Color(p["color"], ZZ_ALPHA * a))
			&"steam":
				var t := float(p["age"]) / float(p["life"])
				_halo(self, p["pos"], lerpf(STEAM_SIZE.x, STEAM_SIZE.y, t),
					Color(p["color"], STEAM_A * a))
