extends SceneTree
## Каталог — ресурс игры. Изменения карты для боя не должны проникать в следующую загрузку.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	var start := Time.get_ticks_usec()
	for i in 100:
		Campaign.maps()
	print("CATALOG 100 reads: ", (Time.get_ticks_usec() - start) / 1000.0, " ms")
	var maps := Campaign.maps()
	_check(not maps.is_empty(), "каталог не пустой")
	var original := maps.duplicate(true)
	var id := String(maps[0]["id"])
	maps[0]["title"] = "испорчено"
	maps[0]["waves"].clear()
	_check(Campaign.map(id) == original[0], "выданная карта — независимая глубокая копия")
	var single := Campaign.map(id)
	single["title"] = "другая правка"
	_check(Campaign.maps() == original, "доступ по id не портит каталог")
	_check(Campaign.map("no_such_map").is_empty(), "неизвестный id не подставляет другую карту")
	print("CAMPAIGN CATALOG: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fails += 1
		print("FAIL: ", message)
