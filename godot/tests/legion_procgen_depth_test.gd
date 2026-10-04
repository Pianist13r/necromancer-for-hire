extends SceneTree
## Регресс глубины PgArt. Запускать через фиксированный Legion-гейт после освобождения движка.
## Загрузки через строки намеренно дают FAIL на старой ревизии, а не ParseError.

const PG_ART := "res://scripts/legion/procgen/pg_art.gd"
const PG_SPRITES := "res://scripts/legion/procgen/pg_art_sprites.gd"
const PG_DEPTH := "res://scripts/legion/procgen/pg_art_depth.gd"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok   ", label)
	else:
		_fails += 1
		print("  FAIL ", label)


func _run() -> void:
	var sprites := load(PG_SPRITES) as GDScript
	var art := load(PG_ART) as GDScript
	var depth_resource := load(PG_DEPTH)
	var depth := depth_resource as GDScript if depth_resource is GDScript else null
	_check(sprites != null and art != null,
		"PgArt и PgArtSprites доступны без статических ссылок теста")
	if sprites == null or art == null:
		quit(1)
		return
	var map := _map()
	var legacy_root := Node2D.new()
	var legacy: Dictionary = art.call("compose", legacy_root, map, null, 0.4)
	_check(_sprites_with(legacy_root, "grave_tomb_01") == 1,
		"standalone compose по умолчанию продолжает запекать надгробие")
	legacy_root.free()
	var methods := _methods(sprites)
	_check(methods.has("is_depth_item"), "есть явная классификация вертикальных предметов")
	var supports_split := methods.has("is_depth_item")
	if supports_split:
		_check(not sprites.call("is_depth_item", PgCatalog.by_id("swamp_reeds_l_01")),
			"плоский камыш не уходит из bake")
		_check(sprites.call("is_depth_item", PgCatalog.by_id("grave_column_01"))
			and sprites.call("is_depth_item", PgCatalog.by_id("ash_rock_l_01")),
			"высокая колонна и крупная скала включены явным каталогом")
		_check(not sprites.call("is_depth_item", PgCatalog.by_id("swamp_bridge"))
			and not sprites.call("is_depth_item", PgCatalog.by_id("grave_dec_grass")),
			"мост и плоский scatter остаются запечёнными")
	var split_root := Node2D.new()
	if supports_split:
		var split_data: Dictionary = art.call("compose", split_root, map, null, 0.4, true)
		var split_entries: Array = split_data.get("depth_entries", [])
		_check(split_entries.size() == 1 and String(split_entries[0].item.id) == "grave_tomb_01",
			"из prop-каталога в runtime список попало ровно высокое надгробие")
		_check(_sprites_with(split_root, "grave_tomb_01") == 0
			and _sprites_with(split_root, "grave_sarc_01") == 1,
			"явный split убирает только вертикальный prop, оставляя препятствие в bake")
	else:
		_check(false, "PgArt.compose поддерживает опциональный split-проход")
	split_root.free()
	var depth_methods := _methods(depth) if depth != null else []
	_check(depth_methods.has("should_fade"), "fade-геометрия тестируется без запуска сцены боя")
	if depth_methods.has("should_fade"):
		var area := Rect2(20, 20, 40, 60)
		var head_overlap := Rect2(30, 5, 20, 70)
		_check(depth.call("should_fade", 100.0, head_overlap, area, 90.0),
			"пересечение головой ловится, даже если якорь бойца вне силуэта")
		_check(not depth.call("should_fade", 100.0, head_overlap, area, 120.0),
			"боец с передним якорем рисуется поверх высокого пропа")
		_check(not depth.call("should_fade", 100.0, Rect2(80, 30, 20, 40), area, 90.0),
			"боец вне силуэта не запускает fade")
	_check(depth != null and depth.get_script_constant_map().get("HIDDEN_ALPHA", 1.0) < 1.0,
		"заслоняющий объект остаётся видимым при fade")
	if depth != null:
		var layer := depth.new() as Node
		var layer_root := Node2D.new()
		layer_root.y_sort_enabled = true
		var layer_data: Dictionary = art.call("compose", layer_root, map, null, 0.4, true)
		var layer_entries := _depth_entries(layer_data)
		layer_root.free()
		var render_parent := Node2D.new()
		render_parent.y_sort_enabled = true
		layer.call("setup", null, map, layer_entries, render_parent)
		_check(render_parent.get_child_count() == 1 and render_parent.get_child(0) is Sprite2D,
			"runtime-спрайт — прямой y-sort sibling, тень не дублируется")
		if render_parent.get_child_count() == 1 and render_parent.get_child(0) is Sprite2D:
			var sprite := render_parent.get_child(0) as Sprite2D
			_check(sprite.position == Vector2(420, 340),
				"runtime-спрайт сохраняет опорную точку библиотеки для y-сортировки")
			var pg_art := load(PG_ART) as GDScript
			var sprite_script := load("res://scripts/legion/procgen/pg_art_sprites.gd") as GDScript
			var item: Dictionary = PgCatalog.by_id("grave_tomb_01")
			var baked_scale: float = sprite_script.get_script_constant_map()["TEX_SCALE"]
			var texture_size: Vector2 = pg_art.get_script_constant_map()["TEX_SIZE"]
			var display_scale := TerrainView.WORLD / texture_size
			var baked_width := float(item["w"]) * baked_scale * display_scale.x
			var runtime_width := sprite.texture.get_width() * sprite.scale.x
			_check(is_equal_approx(baked_width, runtime_width),
				"runtime-проп сохраняет baked-ширину после масштаба 1920→1280")
			var baked_anchor := Vector2(420, 340) * baked_scale * display_scale
			_check(baked_anchor.is_equal_approx(sprite.global_position),
				"runtime-проп сохраняет baked-якорь основания")
		layer.call("clear")
		layer.free()
		render_parent.free()
	print("LEGION PROCGEN DEPTH: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _methods(script: GDScript) -> Array:
	var out: Array = []
	for method: Dictionary in script.get_script_method_list():
		out.append(String(method.name))
	return out


func _depth_entries(data: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Variant in data.get("depth_entries", []):
		if entry is Dictionary:
			out.append(entry)
	return out


func _sprites_with(node: Node, needle: String) -> int:
	var count := 0
	for child in node.get_children():
		# слой Fill — декоративные группы gen-art-polish, не предметы карты: тест считает только запечённое словарём
		if child.name == &"Fill":
			continue
		if child is Sprite2D and (child as Sprite2D).texture != null \
				and (child as Sprite2D).texture.resource_path.contains(needle):
			count += 1
		count += _sprites_with(child, needle)
	return count


func _map() -> Dictionary:
	return {"biome": "grave", "procgen": {"version": 1}, "roads": [], "walls": [],
		"rocks": [], "props": [
			{"item": "grave_sarc_01", "pos": [300, 300], "flip": false},
			{"item": "grave_tomb_01", "pos": [420, 340], "flip": false}],
		"water": [], "swamp": [], "bridges": [], "decor": [], "plots": [],
		"ambient": {"glows": []}}
