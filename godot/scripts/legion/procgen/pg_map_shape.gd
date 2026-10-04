class_name PgMapShape
extends RefCounted
##
## Проверка формы словаря карты до замеров фильтра годности (PgFilter). Фильтр при сомнении
## отбраковывает, а не пропускает: битое значение (число — массивом, id — числом, группа волны без
## type, две дороги с одним id…) даёт строку «Словарь: …», и замеры не запускаются вовсе. Иначе
## SCRIPT ERROR посреди замеров обрывал разбор, и check() отвечал «годна» (verifier 27.09).
## Проверяются типы всех полей, которые читают LegionMapChecks, LegionTerrain, PgFilter и
## PgQuirkRules. Поля, которые фильтр не читает (title, hint, decor.kind…), не проверяются.
##

## Координаты дальше этого от начала — брак данных (и замеры шли бы по миллионам шагов).
const COORD_LIMIT := 4000.0
## Любое число словаря, влияющее на циклы (at, delay, interval, pause, next_in, w…), по модулю
## не больше этого: at = −1e9 крутил счёт первой встречи часами (verifier-3 27.09).
const NUM_LIMIT := 1.0e5
## Врагов в группе (count, elite) не больше этого.
const COUNT_MAX := 5000


## [] — форма годна; иначе строки «Словарь: …» (не больше одной на поле, чтобы не тонуть).
static func check(map: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var id: Variant = map.get("id", null)
	if not id is String or String(id).is_empty():
		out.append("Словарь: нет id строкой")
	if not _point(map.get("cauldron", null)):
		out.append("Словарь: cauldron — не точка [x, y]")
	var road_ids := _roads(out, map)
	_list(out, map, "plots", func(it: Dictionary) -> String:
		return _need(it, {"id": TYPE_STRING, "pos": "point"}))
	_list(out, map, "bot_lines", func(it: Dictionary) -> String:
		return _need(it, {"a": "point", "b": "point", "road": TYPE_STRING, "kind": TYPE_STRING},
			{"id": TYPE_STRING}))
	_list(out, map, "crypts", func(it: Dictionary) -> String:
		return _need(it, {"pos": "point"}))
	_list(out, map, "sleepers", func(it: Dictionary) -> String:
		return _need(it, {"pos": "point"}))
	for key: String in ["decor", "props"]:
		_list(out, map, key, func(it: Dictionary) -> String:
			return _need(it, {}, {"pos": "point"}))
	_list(out, map, "breaches", func(it: Dictionary) -> String:
		return _need(it, {"id": TYPE_STRING, "road": TYPE_STRING, "at": "number"}))
	_list(out, map, "walls", func(it: Dictionary) -> String:
		return _need(it, {"path": "path2"}, {"w": "number", "kind": TYPE_STRING}))
	_list(out, map, "flights", func(it: Dictionary) -> String:
		var why := _need(it, {"id": TYPE_STRING, "path": "path2"})
		if why == "" and road_ids.has(it.id):
			why = "id %s совпадает с дорогой" % it.id
		return why)
	for key: String in ["rocks", "water", "bridges", "swamp"]:
		var polys: Variant = map.get(key, [])
		if not polys is Array:
			out.append("Словарь: %s — не список" % key)
			continue
		for poly: Variant in polys:
			if not _path(poly, 3):
				out.append("Словарь: %s — многоугольник не из трёх и больше точек [x, y]" % key)
				break
	_waves(out, map)
	_procgen(out, map)
	return out


## Дороги: список словарей с уникальным непустым id и путём из ≥ 2 точек. Вернёт множество id.
static func _roads(out: Array[String], map: Dictionary) -> Dictionary:
	var ids: Dictionary = {}
	var roads: Variant = map.get("roads", null)
	if not roads is Array or (roads as Array).is_empty():
		out.append("Словарь: нет дорог (roads — непустой список)")
		return ids
	for r: Variant in roads:
		if not r is Dictionary:
			out.append("Словарь: дорога — не словарь")
			return ids
		var rid: Variant = (r as Dictionary).get("id", null)
		if not rid is String or String(rid).is_empty():
			out.append("Словарь: дорога без id строкой")
			return ids
		if ids.has(rid):
			out.append("Словарь: две дороги с id %s" % rid)
		ids[rid] = true
		var path: Variant = (r as Dictionary).get("path", null)
		if not _path(path, 2):
			out.append("Словарь: дорога %s — путь не из двух и больше точек [x, y]" % rid)
		elif (path as Array).all(func(p: Array) -> bool: return p == path[0]):
			out.append("Словарь: дорога %s — все точки пути совпадают" % rid)
	return ids


static func _waves(out: Array[String], map: Dictionary) -> void:
	var waves: Variant = map.get("waves", null)
	if not waves is Array or (waves as Array).is_empty():
		out.append("Словарь: нет волн (waves — непустой список)")
		return
	for i in (waves as Array).size():
		var w: Variant = waves[i]
		if not w is Dictionary:
			out.append("Словарь: волна %d — не словарь" % (i + 1))
			return
		var why := _need(w, {"groups": TYPE_ARRAY},
			{"pause": "number", "next_in": "number", "climax": TYPE_BOOL})
		if why != "":
			out.append("Словарь: волна %d — %s" % [i + 1, why])
			return
		for g: Variant in w.groups:
			if not g is Dictionary:
				out.append("Словарь: волна %d — группа не словарь" % (i + 1))
				return
			why = _need(g, {"road": TYPE_STRING, "type": TYPE_STRING},
				{"count": "count", "interval": "number", "delay": "number", "at": "number",
					"elite": "count0", "breach": TYPE_STRING, "souls_mult": "number"})
			if why == "" and not LegionCfg.FOES.has(g.type):
				why = "неизвестный вид врага %s" % g.type
			if why != "":
				out.append("Словарь: волна %d, группа — %s" % [i + 1, why])
				return


static func _procgen(out: Array[String], map: Dictionary) -> void:
	if map.has("biome") and not map.biome is String:
		out.append("Словарь: biome — не строка")
	if not map.has("procgen"):
		return
	var pg: Variant = map.procgen
	if not pg is Dictionary:
		out.append("Словарь: procgen — не словарь")
		return
	var why := _need(pg, {}, {"card": TYPE_DICTIONARY, "throat": TYPE_DICTIONARY})
	if why != "":
		out.append("Словарь: procgen — %s" % why)
		return
	if pg.has("card"):
		why = _need(pg.card, {}, {"quirks": "strings", "archetype": TYPE_STRING})
		if why != "":
			out.append("Словарь: procgen.card — %s" % why)
	if pg.has("throat"):
		why = _need(pg.throat, {"from": "number", "to": "number"},
			{"road": TYPE_STRING, "roads": "strings", "pos": "point"})
		if why == "" and not pg.throat.has("road") and not pg.throat.has("roads"):
			why = "нет road или roads"
		if why != "":
			out.append("Словарь: procgen.throat — %s" % why)


## Каждый элемент списка key — словарь, годный по правилу rule ("" — годен). Одна строка на
## список: дальше смотреть незачем, карта уже брак. Нет поля — нечего проверять (необязательно).
static func _list(out: Array[String], map: Dictionary, key: String, rule: Callable) -> void:
	if not map.has(key):
		return
	var items: Variant = map[key]
	if not items is Array:
		out.append("Словарь: %s — не список" % key)
		return
	for it: Variant in items:
		if not it is Dictionary:
			out.append("Словарь: %s — элемент не словарь" % key)
			return
		var why: String = rule.call(it)
		if why != "":
			out.append("Словарь: %s — %s" % [key, why])
			return


## Поля словаря: need — обязательные, may — необязательные; тип — TYPE_* или слово:
## "number", "count" (целое ≥ 1), "count0" (целое ≥ 0), "point", "path2", "strings".
static func _need(it: Dictionary, need: Dictionary, may := {}) -> String:
	for k: String in need:
		if not it.has(k):
			return "нет %s" % k
	for group: Dictionary in [need, may]:
		for k: String in group:
			if it.has(k) and not _is(it[k], group[k]):
				return "%s — не %s" % [k, _type_name(group[k])]
	return ""


static func _is(v: Variant, kind: Variant) -> bool:
	if kind is int:
		return typeof(v) == kind
	match String(kind):
		"number":
			return _number(v) and absf(float(v)) <= NUM_LIMIT
		"count":
			return _number(v) and float(v) >= 1.0 and float(v) <= COUNT_MAX \
				and float(v) == floorf(float(v))
		"count0":
			return _number(v) and float(v) >= 0.0 and float(v) <= COUNT_MAX \
				and float(v) == floorf(float(v))
		"point":
			return _point(v)
		"path2":
			return _path(v, 2)
		"strings":
			if not v is Array:
				return false
			for s: Variant in v:
				if not s is String:
					return false
			return true
	return false


static func _type_name(kind: Variant) -> String:
	if kind is int:
		return {TYPE_STRING: "строка", TYPE_BOOL: "да/нет", TYPE_ARRAY: "список",
			TYPE_DICTIONARY: "словарь"}.get(kind, "нужного типа")
	return {"number": "число по модулю ≤ 1e5", "count": "целое 1…5000", "count0": "целое 0…5000",
		"point": "точка [x, y]", "path2": "путь из ≥ 2 точек",
		"strings": "список строк"}.get(String(kind), String(kind))


static func _number(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))


static func _point(v: Variant) -> bool:
	if not v is Array or (v as Array).size() != 2:
		return false
	return _number(v[0]) and _number(v[1]) and absf(float(v[0])) <= COORD_LIMIT \
		and absf(float(v[1])) <= COORD_LIMIT


static func _path(v: Variant, min_points: int) -> bool:
	if not v is Array or (v as Array).size() < min_points:
		return false
	for p: Variant in v:
		if not _point(p):
			return false
	return true
