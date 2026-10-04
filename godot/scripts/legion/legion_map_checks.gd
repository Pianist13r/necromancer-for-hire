class_name LegionMapChecks
extends RefCounted
##
## Проверки одной карты словарём — общий код теста кампании (`tests/legion_maps_test.gd`) и
## фильтра годности процедурных карт (`PgFilter`, BOOK §10 п.1). Почему вынесено: генератор
## обязан проходить ровно те же проверки, что рисованные карты, и расхождение двух копий
## незаметно пропустило бы негодную карту в игру.
##
## Геометрия проверяется движком по той же сетке, что марш армии, а не только по JSON.
## Кампанийные проверки (путь bg, подсказка, числа «Пустыря») остались в тесте — у процедурной
## карты их нет. Каждая проверка — запись {"ok": bool, "msg": String}: тест считает их по одной
## (итог N/M не меняется), фильтр берёт только проваленные.
##

const SAMPLE_STEP := 8.0
const MIN_DETOUR := 1.4
const RECRUIT_R := 200.0
## v16: DESIGN §12 п.7 — пауза после клира не короче 10 с (кроме первой волны).
const WAVE_PAUSE_MIN := 10.0
## v16: выход из трещины не раньше 10 с от старта волны — столько идёт предупреждение
## (INTEREST_V16 §5 п.3; в движке — LegionCfg.BREACH_WARN_TIME пакета T).
const BREACH_WARN_MIN := 10.0
## Вахтёры рождаются перед дверью площадки: центр + (0, 24), веер вниз ≈22 px.
const POST_SPAWN := Vector2(0.0, 46.0)


## Все проверки одной карты. `notes` получает строки замеров (длины дорог, трещины, состав волн) —
## тест их печатает, фильтр отбрасывает.
## `done` получает true в самом конце: фильтр по нему отличает «проверки прошли» от «оборвались
## ошибкой скрипта посреди» (тогда вернулся бы неполный список, похожий на годную карту).
static func run(map: Dictionary, terrain: LegionTerrain, notes: Array[String],
		done: Array = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var id := String(map.get("id", "?"))
	var cauldron := v(map.get("cauldron", [0, 0]))
	var roads := road_paths(map)
	var plots: Array = map.get("plots", [])
	_add(out, plots.size() >= 3 and plots.size() <= 8, id + " 3–8 участков")
	for road: Dictionary in map.get("roads", []):
		var path: PackedVector2Array = roads[String(road.get("id", ""))]
		var length := 0.0
		var turns := 0
		var clear := true
		for i in range(1, path.size()):
			var delta := path[i] - path[i - 1]
			length += delta.length()
			if i > 1 and absf(delta.angle_to(path[i - 1] - path[i - 2])) > 0.2:
				turns += 1
			var steps := ceili(delta.length() / SAMPLE_STEP)
			for s in steps + 1:
				var p := path[i - 1].lerp(path[i], float(s) / steps)
				for offset: float in [-LegionCfg.MAP_ROAD_WIDTH * 0.5, 0.0,
						LegionCfg.MAP_ROAD_WIDTH * 0.5]:
					var q := p + delta.normalized().orthogonal() * offset
					if not terrain.walkable(q):
						notes.append("blocked %s %s offset %s" % [id, p, offset])
						clear = false
		_add(out, clear, id + "/" + String(road.get("id", "")) + " дорога и её края проходимы")
		_add(out, turns >= 2, id + " не меньше двух поворотов")
		var straight := path[0].distance_to(cauldron) if path.size() > 0 else 0.0
		_add(out, path.size() >= 2 and length >= straight * MIN_DETOUR, id + " путь >= 1,4 прямого")
		_add(out, path.size() >= 2 and path[-1] == cauldron, id + " дорога доходит до котла")
		notes.append("%s/%s: %.0f px, x%.2f, %d turns" % [id, String(road.get("id", "")), length,
			length / maxf(straight, 1.0), turns])
	var ids: Array[String] = []
	var grid: AStarGrid2D = terrain.get("_astar")
	for plot: Dictionary in plots:
		var pid := String(plot.get("id", ""))
		_add(out, not ids.has(pid), id + " уникальный участок")
		ids.append(pid)
		var p := v(plot.get("pos", [0, 0]))
		_add(out, terrain.walkable(p) and not terrain.is_rock(p), id + "/" + pid + " на суше")
		for side: Vector2 in [Vector2(-1, -1), Vector2(-1, 1), Vector2(1, -1), Vector2(1, 1)]:
			var corner: Vector2 = p + side * LegionCfg.MAP_PLOT_SIZE * 0.5
			_add(out, terrain.walkable(corner) and not terrain.is_rock(corner),
				id + "/" + pid + " фундамент на суше")
		_add(out, not grid.get_id_path(terrain.cell_of(cauldron), terrain.cell_of(p)).is_empty(),
			id + "/" + pid + " достижим от котла")
		_add(out, dist_to_roads(p, roads) <= RECRUIT_R, id + "/" + pid + " призыв достаёт дорогу")
	for bl: Dictionary in map.get("bot_lines", []):
		var road_id := String(bl.get("road", ""))
		_add(out, LegionCfg.UNIT_KINDS.has(StringName(bl.get("kind", ""))) and roads.has(road_id),
			id + " вид и дорога рубежа")
		var a := v(bl.get("a", [0, 0]))
		var b := v(bl.get("b", [0, 0]))
		_add(out, roads.has(road_id) and line_cross(a, b, roads[road_id]) != null,
			id + "/" + road_id + " рубеж пересекает свою дорогу")
		var steps := ceili(a.distance_to(b) / SAMPLE_STEP)
		var clear := true
		for s in steps + 1:
			var p := a.lerp(b, float(s) / maxi(steps, 1))
			clear = clear and terrain.walkable(p) and not terrain.is_rock(p)
		_add(out, clear, id + " рубеж целиком проходим")
	_check_post_reach(out, map, id, roads)
	var flights := _check_flights(out, notes, map, roads, terrain)
	for wave: Dictionary in map.get("waves", []):
		for group: Dictionary in wave.get("groups", []):
			var on_flight := flights.has(String(group.get("road", "")))
			_add(out, roads.has(String(group.get("road", ""))) or on_flight,
				id + " группа выходит на существующую дорогу")
			if on_flight:
				_add(out, LegionCfg.FOES.get(String(group.get("type", "")), {}).get("ghost", false),
					id + " по воздушной трассе летят только призраки")
			var elite := int(group.get("elite", 0))
			if elite > 0:
				_add(out, elite <= int(group.get("count", 1))
					and CfgItems.ELITE_TYPES.has(String(group.get("type", ""))),
					id + " гарантированный элитный: не больше группы и вид бывает элитным")
	var merged := roads.duplicate()
	merged.merge(flights)
	_check_tempo(out, notes, map, merged, terrain)
	done.append(true)
	return out


## Оси дорог картой id → точки.
static func road_paths(map: Dictionary) -> Dictionary:
	var roads: Dictionary = {}
	for road: Dictionary in map.get("roads", []):
		roads[String(road.get("id", ""))] = polyline(road.get("path", []))
	return roads


static func polyline(raw: Array) -> PackedVector2Array:
	var path := PackedVector2Array()
	for p: Array in raw:
		path.append(v(p))
	return path


static func v(raw: Array) -> Vector2:
	return Vector2(float(raw[0]), float(raw[1]))


## Расстояние точки до ближайшей оси дороги.
static func dist_to_roads(p: Vector2, roads: Dictionary) -> float:
	var distance := INF
	for path: PackedVector2Array in roads.values():
		for i in range(1, path.size()):
			distance = minf(distance, p.distance_to(
				Geometry2D.get_closest_point_to_segment(p, path[i - 1], path[i])))
	return distance


## Первая по ходу дороги точка, где отрезок a–b её пересекает; null — не пересекает.
static func line_cross(a: Vector2, b: Vector2, path: PackedVector2Array) -> Variant:
	for i in range(1, path.size()):
		var hit: Variant = Geometry2D.segment_intersects_segment(a, b, path[i - 1], path[i])
		if hit != null:
			return hit
	return null


static func path_length(path: PackedVector2Array) -> float:
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i].distance_to(path[i - 1])
	return length


static func point_at(path: PackedVector2Array, at: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	var left := at
	for i in range(1, path.size()):
		var seg := path[i].distance_to(path[i - 1])
		if left <= seg:
			return path[i - 1].lerp(path[i], left / seg)
		left -= seg
	return path[-1]


static func _add(out: Array[Dictionary], ok: bool, msg: String) -> void:
	out.append({"ok": ok, "msg": msg})


## B-079 (своя игра 9ef4ccac на «Проходной»): игрок чертит охрану или аудит ровно поперёк
## дороги, и место на самой дороге должно быть в радиусе набора от какой-нибудь площадки (строить
## Проходную можно на любой, `preferred_kinds` — только выбор бота). Иначе
## линия поперёк прохода стоит пустой, а бот держится только потому, что его рубеж начинается
## ближе к площадке (у старой p2 до точки турникета было 225 px). Подряд набирается и от Котла,
## поэтому проверяются только виды, которых Котёл не рождает.
static func _check_post_reach(out: Array[Dictionary], map: Dictionary, id: String,
		roads: Dictionary) -> void:
	for bl: Dictionary in map.get("bot_lines", []):
		var kind := String(bl.get("kind", ""))
		if kind == String(LegionCfg.KIND_LABORER) or not roads.has(String(bl.get("road", ""))):
			continue
		var cross: Variant = line_cross(v(bl.get("a", [0, 0])), v(bl.get("b", [0, 0])),
			roads[String(bl.get("road", ""))])
		if cross == null:
			continue
		var best := INF
		for plot: Dictionary in map.get("plots", []):
			best = minf(best, (v(plot.get("pos", [0, 0])) + POST_SPAWN).distance_to(cross))
		_add(out, best <= RECRUIT_R, "%s/%s место вида %s на дороге в радиусе набора площадки (%.0f px)"
			% [id, String(bl.get("id", "?")), kind, best])


## Карта «Архив»: воздушные трассы призраков (`flights`). Трасса — не дорога: рельеф ею не
## прорезается. Она должна кончаться у Котла, выходить из тех же ворот, что дорога, и СРЕЗАТЬ:
## проходить сквозь непроходимое (стеллажи) и быть короче дороги из этих ворот.
## Заодно для всех карт: от ворот (первая точка дороги в мире) до Котла есть путь по сетке.
static func _check_flights(out: Array[Dictionary], notes: Array[String], map: Dictionary,
		roads: Dictionary, terrain: LegionTerrain) -> Dictionary:
	var id := String(map.get("id", "?"))
	var cauldron := v(map.get("cauldron", [0, 0]))
	var grid: AStarGrid2D = terrain.get("_astar")
	for road_id: String in roads:
		var gate := gate_of(roads[road_id])
		_add(out, gate != Vector2.INF and not grid.get_id_path(terrain.cell_of(gate),
			terrain.cell_of(cauldron)).is_empty(), id + "/" + road_id + " от ворот до котла есть путь")
	var flights: Dictionary = {}
	for fl: Dictionary in map.get("flights", []):
		var fid := String(fl.get("id", ""))
		_add(out, not roads.has(fid) and not flights.has(fid), id + "/" + fid + " трасса с уникальным id")
		var path := polyline(fl.get("path", []))
		flights[fid] = path
		_add(out, path.size() >= 2 and path[-1] == cauldron, id + "/" + fid + " трасса доходит до котла")
		var solid := flight_walls(path, terrain)
		var twin := flight_twin(path, roads)
		_add(out, twin != "", id + "/" + fid + " трасса выходит из ворот дороги")
		_add(out, solid >= 2, id + "/" + fid + " трасса пролетает сквозь две стены и больше")
		if twin != "":
			var ratio := path_length(path) / maxf(path_length(roads[twin]), 1.0)
			_add(out, ratio < 0.8, id + "/" + fid + " трасса заметно короче дороги")
			notes.append("%s/%s: %.0f px (%.0f%% дороги %s), сквозь стены: %d" % [
				id, fid, path_length(path), ratio * 100.0, twin, solid])
	return flights


## Ворота дороги — первая её точка в кадре (шаг SAMPLE_STEP); INF — дорога кадр не задевает.
static func gate_of(path: PackedVector2Array) -> Vector2:
	var world := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE)
	for i in range(1, path.size()):
		var steps := ceili(path[i - 1].distance_to(path[i]) / SAMPLE_STEP)
		for s in steps + 1:
			var p := path[i - 1].lerp(path[i], float(s) / steps)
			if world.has_point(p):
				return p
	return Vector2.INF


## Сколько раз трасса входит в непроходимое (сколько стеллажей пролетает насквозь).
static func flight_walls(path: PackedVector2Array, terrain: LegionTerrain) -> int:
	var world := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE)
	var solid := 0
	var inside := false
	for i in range(1, path.size()):
		var steps := ceili(path[i - 1].distance_to(path[i]) / SAMPLE_STEP)
		for s in steps + 1:
			var p := path[i - 1].lerp(path[i], float(s) / steps)
			var blocked := world.has_point(p) and not terrain.walkable(p)
			if blocked and not inside:
				solid += 1
			inside = blocked
	return solid


## Дорога, из ворот которой вылетает трасса ("" — ни одной).
static func flight_twin(path: PackedVector2Array, roads: Dictionary) -> String:
	var twin := ""
	for road_id: String in roads:
		var other: PackedVector2Array = roads[road_id]
		if not other.is_empty() and not path.is_empty() and other[0] == path[0]:
			twin = road_id
	return twin


## v16 (docs/legion/INTEREST_V16.md §6): трещины, точка выхода группы, нахлёст и паузы волн.
## Поля необязательны — карта без них проходит как раньше.
static func _check_tempo(out: Array[Dictionary], notes: Array[String], map: Dictionary,
		roads: Dictionary, terrain: LegionTerrain) -> void:
	var id := String(map.get("id", "?"))
	var lengths: Dictionary = {}
	for road_id: String in roads:
		lengths[road_id] = path_length(roads[road_id])
	var breaches: Dictionary = {}
	for br: Dictionary in map.get("breaches", []):
		var bid := String(br.get("id", ""))
		_add(out, not bid.is_empty() and not breaches.has(bid), id + " трещина с уникальным id")
		breaches[bid] = br
		var road := String(br.get("road", ""))
		_add(out, roads.has(road), id + "/" + bid + " трещина на существующей дороге")
		if not roads.has(road):
			continue
		var at := float(br.get("at", -1.0))
		_add(out, at > 0.0 and at < float(lengths[road]), id + "/" + bid + " at трещины внутри пути")
		var p := point_at(roads[road], at)
		_add(out, terrain.walkable(p) and not terrain.is_rock(p),
			id + "/" + bid + " точка трещины проходима")
		notes.append("%s/%s: трещина на %s, %.0f px от ворот, %.0f px до котла, точка (%.0f, %.0f)" % [
			id, bid, road, at, float(lengths[road]) - at, p.x, p.y])
	var foes: Dictionary = {}
	var total := 0
	var next_sum := 0.0
	var waves: Array = map.get("waves", [])
	for i in waves.size():
		var wave: Dictionary = waves[i]
		if i > 0:
			_add(out, float(wave.get("pause", 0.0)) >= WAVE_PAUSE_MIN,
				"%s w%d пауза после клира >= %.0f с" % [id, i + 1, WAVE_PAUSE_MIN])
		if wave.has("next_in"):
			_add(out, float(wave.next_in) > 0.0, "%s w%d next_in > 0" % [id, i + 1])
			_add(out, i < waves.size() - 1, "%s w%d next_in только у непоследней волны" % [id, i + 1])
			next_sum += float(wave.next_in)
		for group: Dictionary in wave.get("groups", []):
			var n := int(group.get("count", 1))
			total += n
			var type := String(group.get("type", ""))
			foes[type] = int(foes.get(type, 0)) + n
			if group.has("at"):
				var at := float(group.at)
				_add(out, roads.has(String(group.get("road", ""))) and at >= 0.0
					and at < float(lengths.get(String(group.get("road", "")), 0.0)),
					"%s w%d at группы внутри дороги" % [id, i + 1])
			if group.has("breach"):
				var bid := String(group.breach)
				_add(out, breaches.has(bid), "%s w%d группа ссылается на существующую трещину" % [id, i + 1])
				_add(out, float(group.get("delay", 0.0)) >= BREACH_WARN_MIN,
					"%s w%d выход из трещины не раньше %.0f с (предупреждение)" % [
						id, i + 1, BREACH_WARN_MIN])
				if breaches.has(bid):
					_add(out, String(group.get("road", "")) == String(breaches[bid].get("road", "")),
						"%s w%d road группы совпадает с дорогой трещины" % [id, i + 1])
	var parts: Array[String] = []
	for type: String in foes:
		parts.append("%s %d" % [type, foes[type]])
	notes.append("%s: волн %d · врагов %d (%s) · сумма next_in %.0f с" % [
		id, waves.size(), total, ", ".join(parts), next_sum])
