extends SceneTree
## Вход L1 без ссылок на новые классы: на pre-L1 возвращается FAIL, не Parse Error.

var checks := 0
var fails := 0


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _initialize() -> void:
	var duel := LegionWorld.load_map("pvp:duel")
	_check(not duel.is_empty(), "PvP-карта загружается через игровой вход")
	_check((duel.get("sides", []) as Array).size() == 2, "две игровые стороны в карте")
	_check(duel.get("size", []) == [1600.0, 900.0], "PvP-карта хранит размер мира")
	var solo := LegionWorld.load_map("wasteland")
	_check(not solo.is_empty() and not solo.has("sides"), "обычная карта остаётся одиночной")
	print("LEGION PVP ENTRY: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
