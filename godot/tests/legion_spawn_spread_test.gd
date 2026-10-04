extends SceneTree
##
## Регресс B-037 (медленная сессия d26f8623, 26.09.2026; находка verifier 28c77608): у площадки,
## чей веер двери весь на дороге («Лабиринт», p1), все бойцы рождались в ОДНОЙ запасной точке —
## стопкой, которую накрывает одна печать нотариуса (урок B-018: потери 472 при 304 убитых).
## Теперь запасное место — случайное из проходимых вне дороги.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_spawn_spread_test.gd -- --mute
##
## Для каждой площадки всех карт — 60 рождений: разброс (наибольшее расстояние между двумя)
## не меньше SPREAD_MIN, все проходимы и не ближе SPAWN_ROAD_CLEAR к оси дороги.
## На старом коде падает «Лабиринт» p1 (разброс 0). Итог «LEGION SPAWN SPREAD: N/M OK».
##

const SAVE := "user://legion_spawn_spread_test.cfg"
## Печать нотариуса бьёт кругом 28 px: рождения должны расходиться шире её радиуса.
const SPREAD_MIN := 30.0

var w: LegionWorld
var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	for map_id in ["wasteland", "fork", "bridge", "maze", "swamp", "boss"]:
		w.dev["no_waves"] = "1"
		w.dev["spawn_units"] = "0"
		w.start_map(map_id)
		for plot: Dictionary in w.staff.plots:
			var b := w.staff._make(LegionCfg.KIND_LABORER, LegionBuilding.SOURCE_PLOT,
				plot["pos"], null)
			var pts: Array[Vector2] = []
			var ok := true
			for k in 60:
				var p: Vector2 = b._spawn_point()
				pts.append(p)
				ok = ok and w.terrain.walkable(p) and w.road_dist(p) >= LegionCfg.SPAWN_ROAD_CLEAR
			var spread := 0.0
			for i in pts.size():
				for j in range(i + 1, pts.size()):
					spread = maxf(spread, pts[i].distance_to(pts[j]))
			_check(spread >= SPREAD_MIN and ok, "%s %s: разброс %.0f px, все вне дороги и на суше: %s" % [
				map_id, plot["id"], spread, ok])
	Campaign.reset()
	print("LEGION SPAWN SPREAD: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
