class_name PgPlotPatterns
extends RefCounted
## Два способа расставить штат без новых чисел боя: парная вахта поперёк дороги
## и два тыловых участка веером у Котла. Все обычные резервы/зазоры действуют.
const IDS := ["", "cross_watch", "reserve_fan"]
const HINTS := {
	"cross_watch": "Парная вахта: участки по обе стороны дороги — можно держать перекрёстный огонь.",
	"reserve_fan": "Тыловой веер: два участка у Котла — выбирайте, какой фланг усилить.",
}


static func choose(seed_value: int, k: int, attempt: int) -> String:
	# Передышку и явно заданную карточку не усложняем. После первой карточки остаётся
	# прежний надёжный путь перебора: модификатор не способен исчерпать все попытки.
	if k < 2 or attempt >= ProcGen.ATTEMPTS_PER_CARD:
		return ""
	return IDS[PgRng.make(seed_value, "plot_pattern:%d" % k, attempt).randi_range(0, 2)]


static func apply(lay: PgLayout, candidates: Array[Dictionary],
		chosen: Array[Dictionary]) -> bool:
	var id := String(lay.card.get("plot_pattern", ""))
	if id.is_empty():
		return true
	var pair: Array[Dictionary] = []
	if id == "reserve_fan":
		var rear: Dictionary = chosen[0]
		for c in candidates:
			var pos: Vector2 = c["pos"]
			if pos.distance_to(lay.cauldron) <= PgPlace.REAR_R.y \
					and PgPlace._free(c, chosen) and PgPlace._exact_ok(lay, pos):
				pair = [rear, c]
				break
	elif id == "cross_watch":
		for a in candidates:
			if not _available(lay, a, chosen) or float(a.get("frac", 0.0)) < 0.25 \
					or float(a.get("frac", 0.0)) > 0.7:
				continue
			for b in candidates:
				if a["road"] != b["road"] or absf(float(a["at"]) - float(b["at"])) > 16.0:
					continue
				var span := (a["pos"] as Vector2).distance_to(b["pos"])
				if span < 170.0 or span > 264.0 or not _available(lay, b, chosen):
					continue
				pair = [a, b]
				break
			if not pair.is_empty():
				break
	if pair.is_empty():
		lay.fail = "нет места для схемы участков: " + id
		return false
	for c in pair:
		if not chosen.has(c):
			chosen.append(c)
	lay.extra["plot_pattern"] = {"id": id,
		"points": [PgGeom.arr(pair[0]["pos"]), PgGeom.arr(pair[1]["pos"])]}
	return true


static func _available(lay: PgLayout, c: Dictionary, chosen: Array[Dictionary]) -> bool:
	return PgPlace._free(c, chosen) and PgPlace._exact_ok(lay, c["pos"])


## Метки не заменяют геометрию: проверяем, что оба участка действительно существуют,
## разнесены и расположены там, где обещает подсказка. Остальную годность проверяет PgFilter.
static func check(map: Dictionary, problems: Array[String]) -> bool:
	var pg: Dictionary = map.get("procgen", {})
	var id := String(pg.get("card", {}).get("plot_pattern", ""))
	if id.is_empty():
		return true
	var marker: Dictionary = pg.get("layout", {}).get("plot_pattern", {})
	var points: Array = marker.get("points", [])
	if not HINTS.has(id) or marker.get("id", "") != id or points.size() != 2:
		problems.append("Схема участков: отсутствует корректная разметка")
		return true
	var pair := PackedVector2Array()
	for raw: Variant in points:
		if not raw is Array or raw.size() != 2 \
				or not (raw[0] is float or raw[0] is int) \
				or not (raw[1] is float or raw[1] is int):
			problems.append("Схема участков: неверная точка")
			return true
		var p := LegionMapChecks.v(raw)
		var found := false
		for plot: Dictionary in map.get("plots", []):
			found = found or p.distance_to(LegionMapChecks.v(plot["pos"])) < 1.0
		if not found:
			problems.append("Схема участков: отмеченного участка нет на карте")
		pair.append(p)
	if pair[0].distance_to(pair[1]) < PgPlace.PLOT_GAP:
		problems.append("Схема участков: пара слишком тесная")
	if id == "reserve_fan":
		for p in pair:
			if p.distance_to(LegionMapChecks.v(map["cauldron"])) > PgPlace.REAR_R.y + 1.0:
				problems.append("Тыловой веер: участок далеко от Котла")
	else:
		var crosses := false
		for road: Dictionary in map["roads"]:
			var path := LegionMapChecks.polyline(road["path"])
			for i in range(1, path.size()):
				var hit: Variant = Geometry2D.segment_intersects_segment(
					pair[0], pair[1], path[i - 1], path[i])
				if hit is Vector2:
					crosses = crosses or (hit.distance_to(pair[0]) >= 70.0 \
						and hit.distance_to(pair[1]) >= 70.0)
		if not crosses or pair[0].distance_to(pair[1]) > 265.0:
			problems.append("Парная вахта: участки не по разные стороны дороги")
	return true
