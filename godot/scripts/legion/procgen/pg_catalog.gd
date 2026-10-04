class_name PgCatalog
extends RefCounted
##
## Каталог предметов процгена (STAGE2 §4): godot/assets/legion/procgen/catalog.json. Генератор
## выбирает предмет по biomes / role / size / pass / тегу, а не по id: библиотека подменит
## записи-заглушки настоящими, и раскладка не заметит. Каталог читается один раз за процесс.
##

const PATH := "res://assets/legion/procgen/catalog.json"

static var _items: Array = []
static var _by_id: Dictionary = {}


static func items() -> Array:
	if _items.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:
			_items = (parsed as Dictionary).get("items", [])
		for it: Dictionary in _items:
			_by_id[String(it["id"])] = it
	return _items


static func by_id(id: String) -> Dictionary:
	items()
	return _by_id.get(id, {}) as Dictionary


## Подходящие предметы: роль, биом; размер и тег — если заданы. Порядок — порядок каталога
## (детерминизм выбора держит rng вызывающего).
static func find(biome: String, role: String, size := "", tag := "") -> Array:
	var out: Array = []
	for it: Dictionary in items():
		if String(it.get("role", "")) != role:
			continue
		if not (it.get("biomes", []) as Array).has(biome):
			continue
		if size != "" and String(it.get("size", "")) != size:
			continue
		if tag != "" and not (it.get("tags", []) as Array).has(tag):
			continue
		out.append(it)
	return out


## Случайный предмет или {}: чужого биома не берём (кувшинка на пустыре хуже, чем ничего);
## any_biome — крайний случай, когда без предмета раскладка не встанет.
static func pick(rng: RandomNumberGenerator, biome: String, role: String, size := "",
		tag := "", any_biome := false) -> Dictionary:
	var pool := find(biome, role, size, tag)
	if pool.is_empty() and any_biome:
		for it: Dictionary in items():
			if String(it.get("role", "")) == role \
					and (size == "" or String(it.get("size", "")) == size) \
					and (tag == "" or (it.get("tags", []) as Array).has(tag)):
				pool.append(it)
	if pool.is_empty():
		return {}
	return pool[rng.randi_range(0, pool.size() - 1)]


## Звено стены по виду (stone / fence / shelf / cabinet): сначала своего биома.
static func wall(kind: String, biome: String) -> Dictionary:
	var any := {}
	for it: Dictionary in items():
		if String(it.get("role", "")) != "wall" or String(it.get("wall_kind", "")) != kind:
			continue
		if (it.get("biomes", []) as Array).has(biome):
			return it
		if any.is_empty():
			any = it
	return any


## «След» предмета в мире: foot из каталога, сдвинутый в pos (и отражённый при flip).
static func foot_at(item: Dictionary, pos: Vector2, flip: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	for raw: Array in item.get("foot", []):
		var v := Vector2(float(raw[0]), float(raw[1]))
		if flip:
			v.x = -v.x
		out.append((pos + v).round())
	if flip:
		out.reverse()
	return out


## Точки эффекта предмета в мире (BOOK §8.5 п.1).
static func fx_at(item: Dictionary, pos: Vector2, flip: bool) -> Array:
	var out: Array = []
	for fx: Dictionary in item.get("fx", []):
		var at: Array = fx.get("at", [0, 0])
		var v := Vector2(float(at[0]), float(at[1]))
		if flip:
			v.x = -v.x
		var e := fx.duplicate()
		e["pos"] = pos + v
		out.append(e)
	return out
