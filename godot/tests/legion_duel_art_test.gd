extends SceneTree
##
## Регресс B-381: карта «Дуэль» режима «Схватка» рисуется полной сборкой PgArt (как «Случайное
## поле»), а не голой процедурной заливкой; кампания с нарисованным bg — как раньше.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_duel_art_test.gd -- --mute
##
## 1) TerrainView.setup(дуэль) ждёт сборку (background_build_pending), кампанийная карта с bg — нет;
## 2) поле gen:<сид>:3:pvp по-прежнему идёт тем же путём;
## 3) мир «Схватки» включает depth_split (вертикальные предметы по глубине), кампания — нет;
## 4) в headless PgArt.build отдаёт null — ожидание земли снимается сразу, симуляция не стоит.
## Итог «LEGION DUEL ART: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_duel_art_test.cfg"

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
	_test_view_setup()
	await _test_world()
	Campaign.reset()
	print("LEGION DUEL ART: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Вид земли вне дерева: setup() только решает, нужна ли сборка, и сам её не запускает.
func _pending(map_id: String) -> bool:
	var map := LegionWorld.load_map(map_id)
	var tv := TerrainView.new()
	tv.setup(map)
	var pending := tv.background_build_pending()
	tv.free()
	return pending


func _test_view_setup() -> void:
	var camp := LegionWorld.load_map("wasteland")
	_check(not String(camp.get("bg", "")).is_empty(), "кампанийная карта wasteland несёт нарисованный bg")
	_check(not _pending("wasteland"), "кампания с bg: PgArt не включается")
	_check(_pending("pvp:duel"), "«Дуэль»: PgArt включается (B-381)")
	_check(_pending("gen:7:3:pvp"), "«Случайное поле» (procgen + pvp): PgArt, как раньше")
	_check(TerrainView.wants_pgart(camp, true), "--dev pgart=1 по-прежнему форсирует сборку")


func _test_world() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.args["pvp_bots"] = true
	w.start_map("pvp:duel")
	await process_frame
	var tv := w._ground as TerrainView
	_check(tv != null, "у мира «Дуэли» есть земля TerrainView")
	if tv != null:
		_check(tv._depth_split, "«Дуэль»: depth_split включён")
	_check(not w._ground_loading, "headless: ожидание земли снято (PgArt вернул null), бой не стоит")
	w.start_map("wasteland")
	await process_frame
	var tv2 := w._ground as TerrainView
	_check(tv2 != null and not tv2._depth_split, "кампания: depth_split выключен")
	_check(tv2 != null and not tv2.background_build_pending(), "кампания: сборка PgArt не ждётся")
	w.queue_free()
	await process_frame
