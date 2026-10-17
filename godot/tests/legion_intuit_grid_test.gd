extends SceneTree
## B-305: подсказочная сетка хранит врагов по размеру текущего мира, а не кадра.
## Только старт двух карт и запросы сетки; боевой серии и снимка бота здесь нет.

const SAVE := "user://legion_intuit_grid_test.cfg"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if ok:
		print("  ok   ", description)
	else:
		_fails += 1
		print("  FAIL ", description)


func _expected_cells(length: float) -> int:
	return ceili((length + 2.0 * LegionCfg.SPATIAL_MARGIN) / IntuitCfg.GRID_CELL)


func _foe(w: LegionWorld, at: Vector2) -> Foe:
	var foe := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	if foe != null:
		foe.speed = 0.0
	return foe


func _query_one(grid: LegionIntuit, at: Vector2, expected: Foe) -> bool:
	var result: int = grid.call("_zone", at, Vector2.RIGHT, 12.0, 24.0, true)
	var found: Array = grid.get("_in_zone")
	return result == 1 and found.size() == 1 and found[0] == expected


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var w: LegionWorld = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.start_map("pvp:duel")
	var grid: LegionIntuit = w.intuit
	_check(w.world_size.x > LegionCfg.WORLD_SIZE.x, "Схватка шире одиночного кадра")
	_check(int(grid.get("_gw")) == _expected_cells(w.world_size.x)
		and int(grid.get("_gh")) == _expected_cells(w.world_size.y),
		"после match_started сетка покрывает всю Схватку")
	var y := w.world_size.y * 0.5
	var left := Vector2(w.world_size.x - 150.0, y)
	var right := Vector2(w.world_size.x - 50.0, y)
	var first := _foe(w, left)
	var second := _foe(w, right)
	_check(first != null and second != null, "два врага созданы в правой части мира")
	if first != null and second != null:
		grid.call("_build_grid")
		var a: int = grid.call("_cell", left)
		var b: int = grid.call("_cell", right)
		var head: PackedInt32Array = grid.get("_head")
		_check(a != b and head[a] >= 0 and head[b] >= 0,
			"два дальних врага не сжаты в одну крайнюю ячейку")
		_check(_query_one(grid, left, first) and _query_one(grid, right, second),
			"запросы правой части возвращают своего врага, не соседнего")

	w.start_map("bridge")
	_check(w.world_size == LegionCfg.WORLD_SIZE and
		int(grid.get("_gw")) == _expected_cells(LegionCfg.WORLD_SIZE.x) and
		int(grid.get("_gh")) == _expected_cells(LegionCfg.WORLD_SIZE.y),
		"после возврата на обычную карту сетка снова 1280×720")
	var ordinary := Vector2(760, 360)
	var third := _foe(w, ordinary)
	_check(third != null, "враг создан на обычной карте")
	if third != null:
		grid.call("_build_grid")
		_check(_query_one(grid, ordinary, third),
			"после смены карты запрос сетки возвращает нового врага")

	Campaign.reset()
	print("LEGION INTUIT GRID: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
