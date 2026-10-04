extends SceneTree
## Декор v4 не меняет карту/бой, детерминирован и оставляет игровое поле свободным.
const SCATTER := "res://scripts/legion/procgen/pg_art_scatter.gd"
const GRADE := "res://scripts/legion/procgen/pg_art_grade.gd"
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, why: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", why])


func _run() -> void:
	_test_ground()
	check(ResourceLoader.exists(SCATTER), "россыпь v4 доступна")
	check(ResourceLoader.exists(GRADE), "зональная обработка v4 доступна")
	if fails == 0:
		_test_scatter()
		_test_grade()
		_test_road_edge()
		_test_road_ground()
	print("LEGION PROCGEN ART4: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _test_scatter() -> void:
	var script := load(SCATTER) as GDScript
	var map := LegionWorld.load_map("gen:12:5").duplicate(true)
	var before := ProcGen.digest(map)
	var first := Node2D.new()
	var second := Node2D.new()
	var a: Dictionary = script.call("build", first, map)
	var b: Dictionary = script.call("build", second, map)
	check(a.get("scatter", 0) >= 20, "россыпь видна, не пустая")
	check(a.get("cauldron_base", 0) == 1, "площадка Котла единственная")
	check(a == b and first.get_child_count() == second.get_child_count(), "счётчики повторяемы")
	var same := true
	var inside := true
	var road_clear := true
	for i in first.get_child_count():
		var sp := first.get_child(i) as Sprite2D
		var other := second.get_child(i) as Sprite2D
		same = same and sp.position == other.position and sp.scale == other.scale \
			and sp.rotation == other.rotation and sp.texture == other.texture
		if sp.name == "CauldronBase":
			continue
		inside = inside and Rect2(28, 28, 1224, 664).has_point(sp.position)
		var radius := sp.texture.get_width() * sp.scale.x * 0.65
		for road: Dictionary in map.roads:
			var pts := PgArtRoad._points(road.path)
			for j in pts.size() - 1:
				road_clear = road_clear and sp.position.distance_to(
					Geometry2D.get_closest_point_to_segment(sp.position, pts[j], pts[j + 1])) \
					>= 30 + radius - 0.01
	check(same, "позиции, масштаб, угол и текстуры повторяемы")
	check(inside, "все смещения кучек остаются внутри края карты")
	check(road_clear, "россыпь оставляет свободной дорогу с учётом размера картинки")
	check(ProcGen.digest(map) == before, "сборка не меняет словарь карты")
	first.free()
	second.free()


func _test_ground() -> void:
	for biome: String in ["swamp", "site", "ash", "office", "grave", "winter", "boiler", "hell"]:
		var map := {"biome": biome, "id": "missing-ground",
			"procgen": {"seed": 12, "k": 5},
			"ground": "res://assets/legion/procgen/ground/%s_05.jpg" % biome}
		var path := PgArtCanvas.resolve_ground_path(map)
		check(ResourceLoader.exists(path, "Texture2D"),
			"несуществующий пятый фон %s заменяется реальной подложкой" % biome)
	var known := LegionWorld.load_map("gen:12:5")
	check(ResourceLoader.exists(PgArtCanvas.resolve_ground_path(known), "Texture2D"),
		"gen:12:5 не теряет болотную подложку")


func _test_grade() -> void:
	var grade := load(GRADE) as GDScript
	check(grade.call("zone_of", Color(0, 0, 0)) == 0, "земля распознана")
	check(grade.call("zone_of", Color(1, 0, 0)) == 1, "дорога распознана")
	check(grade.call("zone_of", Color(0, 1, 0)) == 2, "предмет распознан")
	check(grade.call("zone_of", Color(0.5, 0, 0)) == -1, "вода исключена из переноса")
	var white: Vector3 = grade.call("srgb_to_lab", Color.WHITE)
	check(absf(white.x - 100) < 0.02 and absf(white.y) < 0.02,
		"белый sRGB переводится в Lab без смещения")
	var own := {"ground": {"mu": Vector3(40, 2, 3), "sd": Vector3(5, 4, 3)}}
	var ref := {"ground": {"mu": Vector3(90, 8, 8), "sd": Vector3(50, 40, 30)}}
	var mat := ShaderMaterial.new()
	# Здесь проверяется передача чисел, реальный пост-шейдер — отдельным GPU-кадром.
	# Dummy-renderer не поддерживает TEXTURE как аргумент sampler2D.
	mat.shader = Shader.new()
	mat.shader.code = "shader_type canvas_item; uniform vec3 src_mu[3]; " \
		+ "uniform vec3 src_sd[3]; uniform vec3 ref_mu[3]; uniform vec3 ref_sd[3]; " \
		+ "uniform vec3 zone_strength; void fragment(){COLOR=vec4(1.0);}"
	var strength: Vector3 = grade.call("apply", mat, own, ref)
	check(strength.y == 0 and strength.z == 0, "отсутствующие зоны не перекрашиваются")
	var mu: PackedVector3Array = mat.get_shader_parameter("ref_mu")
	var sd: PackedVector3Array = mat.get_shader_parameter("ref_sd")
	check(mu[0].x <= 43.201 and sd[0].x <= 8.001, "яркость и разброс земли ограничены")
	# road-1003: светлоту дороги держит PgArtRoad от земли под ней — перенос к крему фонов
	# кампании её не поднимает (было: 40 % пути к L образца — лента «светилась» снова)
	var own_r := {"road": {"mu": Vector3(60, 4, 20), "sd": Vector3(5, 4, 3)}}
	var ref_r := {"road": {"mu": Vector3(88, 6, 26), "sd": Vector3(5, 4, 3)}}
	grade.call("apply", mat, own_r, ref_r)
	var mu_r: PackedVector3Array = mat.get_shader_parameter("ref_mu")
	check(mu_r[1].x <= 60.0 * 1.031 and mu_r[1].x >= 60.0 * 0.969,
		"светлота дороги при переносе почти не меняется (L %.1f при своей 60)" % mu_r[1].x)
	check(absf(mu_r[1].z - 23.0) < 0.01, "оттенок дороги идёт к образцу наполовину")


## Декор на кромке дороги (road-1003): есть, повторяем, не трогает словарь карты и ни одним
## краем картинки не заходит в середину полотна ни одной дороги.
func _test_road_edge() -> void:
	var script := load(SCATTER) as GDScript
	for id: String in ["gen:12:5", "gen:11:3", "gen:12:9", "pvp:duel"]:
		var map := LegionWorld.load_map(id).duplicate(true)
		var before := ProcGen.digest(map)
		var half := PgArtRoad.visible_half(map)
		var first := Node2D.new()
		var second := Node2D.new()
		var n: int = script.call("build_edge", first, map, half)
		var n2: int = script.call("build_edge", second, map, half)
		check(n >= 6 and n == first.get_child_count(), "%s: на кромке есть декор (%d)" % [id, n])
		var same := n == n2
		var core_clear := true
		var worst := INF
		var axes: Array[PackedVector2Array] = []
		for road: Dictionary in map.roads:
			axes.append(PgArtRoad.rounded(PgArtRoad._points(road.path)))
		for i in mini(first.get_child_count(), second.get_child_count()):
			var sp := first.get_child(i) as Sprite2D
			var other := second.get_child(i) as Sprite2D
			same = same and sp.position == other.position and sp.texture == other.texture
			# крайняя точка картинки: половина диагонали (поворот любой)
			var r := (sp.texture.get_size() * sp.scale.x).length() * 0.5
			for axis in axes:
				var dist: float = script.call("axis_distance", sp.position, axis)
				worst = minf(worst, dist - r)
				core_clear = core_clear and dist - r >= half * 0.3
		check(same, "%s: кромка повторяема" % id)
		check(core_clear, "%s: середина полотна чистая (ближайший край картинки — %.1f px от оси, "
			% [id, worst] + "полуширина %.1f)" % half)
		check(ProcGen.digest(map) == before, "%s: кромка не меняет словарь карты" % id)
		first.free()
		second.free()


## Земля под дорогой (road-1003): шейдер полотна получает подложку и то же отображение мира в
## её UV, что у спрайта «Ground» (одиночка — растяжка на кадр, поле PvP — вырезка и зеркало).
func _test_road_ground() -> void:
	var tex := ImageTexture.create_from_image(Image.create(1920, 1080, false, Image.FORMAT_RGB8))
	var one: Dictionary = PgArtRoad.ground_params(LegionWorld.load_map("gen:7:5"), tex)
	check(one.get("scale", Vector2.ZERO).is_equal_approx(Vector2(1.0 / 1280.0, 1.0 / 720.0))
		and float(one.get("mirror", -1.0)) == 0.0, "одиночка: мир → UV подложки растяжкой")
	var duel := LegionWorld.load_map("pvp:duel")
	var two: Dictionary = PgArtRoad.ground_params(duel, tex)
	var mw := LegionTerrain.mirror_width(duel)
	check(float(two.get("mirror", 0.0)) == mw and mw > 0.0, "поле PvP: подложка зеркалится")
	# левый верх половины — угол вырезки, середина поля — правый край вырезки
	var off: Vector2 = two.get("off", Vector2.ZERO)
	var sc: Vector2 = two.get("scale", Vector2.ZERO)
	var mid := off + Vector2(mw * 0.5, 0.0) * sc
	check(off.x == 0.0 and mid.x <= 1.0 + 1e-4 and mid.x > 0.4,
		"поле PvP: стык половин — край вырезки (u %.3f)" % mid.x)
	check(PgArtRoad.ground_params(duel, null).is_empty(), "без подложки — запасной путь")
	for land: float in [0.25, 0.35, 0.5]:
		var b: float = PgArtRoad.brightness(0.8, land, PgArtRoad.target_ratio({"biome": "swamp"}))
		check(0.8 * b / land >= 1.39, "болото: дорога светлее земли L %.2f — ×%.2f (≥ 1,4)"
			% [land, 0.8 * b / land])
