extends SceneTree
## Геометрия проверяется движком по той же сетке, что марш армии, а не только по JSON.
## Не создаёт бой и не пишет сохранения. _gray проверяет совместимость старого формата.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	for map: Dictionary in Campaign.maps():
		_check_map(map)
	var legacy := LegionWorld.load_map("_gray")
	_check(not legacy.is_empty(), "старый формат загружается без новых полей")
	var view := TerrainView.new()
	view.setup(legacy)
	_check(view.get("_background") == null, "нет bg: процедурный фон")
	legacy["bg"] = "res://assets/vfx/dirt_02.png"
	view.setup(legacy)
	_check(view.get("_background") is Texture2D, "существующий bg загружается")
	legacy["bg"] = "res://assets/legion/maps/missing_test_bg.png"
	view.setup(legacy)
	_check(view.get("_background") == null, "несуществующий bg: процедурный фон")
	view.free()
	print("LEGION MAPS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL: ", message)


func _check_map(map: Dictionary) -> void:
	var terrain := LegionTerrain.new().setup(map)
	var id := String(map.id)
	# общие проверки одной карты — те же зовёт фильтр процгена (PgFilter, BOOK §10 п.1)
	var notes: Array[String] = []
	for c: Dictionary in LegionMapChecks.run(map, terrain, notes):
		_check(c.ok, c.msg)
	for line in notes:
		print(line)
	# art2 (25.09.2026): подложки — JPEG ради лимита 1.5 МБ (владелец разрешил PNG или JPG).
	var bg := String(map.bg)
	_check(bg == "res://assets/legion/maps/%s_bg.png" % id
		or bg == "res://assets/legion/maps/%s_bg.jpg" % id, id + " путь bg")
	_check(not String(map.hint).is_empty(), id + " подсказка")
	if id == "wasteland":
		var total := 0
		for wave: Dictionary in map.waves:
			for group: Dictionary in wave.groups:
				total += int(group.get("count", 1))
		_check(map.waves.size() == 5, "wasteland ровно 5 волн")
		_check(total >= 120 and total <= 132, "wasteland суммарно 120–132 врага")
		_check(map.get("breaches", []).size() >= 1, "wasteland есть трещина")
