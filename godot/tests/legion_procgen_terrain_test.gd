extends SceneTree
##
## Регресс линии terrain (B-107…B-109, сессия e5d60159, 27.09.2026): сборка картинки
## процедурной карты (PgArt) и её подключение к TerrainView/LegionFx.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_procgen_terrain_test.gd -- --mute
##
## 1) PgArt.build() в headless (dummy-рендер) не падает и не виснет — сразу null;
## 2) TerrainView с процедурной картой без bg не падает (headless → запасной _draw_procedural);
## 3) LegionFx.load_ambient_dict разбирает ту же схему, что load_ambient(path) — сравнение
##    по количеству и содержимому излучателей на одном и том же словаре;
## 4) LegionFx._dust_color для процедурной карты без bg не падает (сразу C_DUST, фон ещё не
##    собран синхронно) и не виснет на ожидании сигнала, которого в headless не будет.
##
## Итог «LEGION PROCGEN TERRAIN: N/M OK»; код выхода 1, если что-то упало. Сохранение — во
## временный user://, кампания сброшена в конце.

const SAVE := "user://legion_procgen_terrain_test.cfg"
const AMB_TMP := "user://legion_procgen_terrain_ambient_test.json"

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
	_test_headless_is_headless()
	_test_pgart_build_headless()
	_test_terrain_view_procgen_no_crash()
	await _test_world_dev_pgart_flag()
	await _test_ambient_dict_matches_file()
	_test_dust_color_no_bg_no_crash()
	Campaign.reset()
	print("LEGION PROCGEN TERRAIN: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Проверка допущения, на котором стоит PgArt.build(): headless-прогон гейта и тестов
## репортует себя так же, как этот тест — иначе detection в pg_art.gd молча не сработает.
func _test_headless_is_headless() -> void:
	_check(DisplayServer.get_name() == "headless", "DisplayServer.get_name() == headless в тесте")


## Карта БЕЗ поля bg (как у процедурной, STAGE2 §3) — build() должен вернуть null сразу,
## не пытаясь завести SubViewport и ждать кадр, которого headless не отдаст.
func _test_pgart_build_headless() -> void:
	var map := {"biome": "ash", "roads": [], "rocks": []}
	var host := Node.new()
	root.add_child(host)
	var req := PgArt.build(map, host)
	_check(req == null, "PgArt.build() в headless возвращает null (не виснет на await кадра)")
	host.queue_free()


## Процедурная карта без bg — TerrainView не падает; в headless PgArt.build() вернул null
## (проверено выше), значит держится запасной _draw_procedural(), фон не пуст.
func _test_terrain_view_procgen_no_crash() -> void:
	var map := _sample_map()
	var tv := TerrainView.new()
	root.add_child(tv)
	tv.setup(map)
	await process_frame
	_check(is_instance_valid(tv), "TerrainView.setup() процедурной карты не роняет узел")
	_check(tv.background_texture() == null,
		"headless: PgArt не собрал текстуру — фон остаётся пуст (запасной рисунок в _draw)")
	tv.queue_redraw()
	await process_frame
	_check(is_instance_valid(tv), "TerrainView._draw() запасного рисунка не падает без фона")
	tv.queue_free()


## --dev pgart=1 на обычной кампанийной карте (B-109): _build_ground должен собрать TerrainView
## через PgArt из ГЕОМЕТРИИ карты, а не через её штатный bg — тоже без падения в headless.
func _test_world_dev_pgart_flag() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.dev["pgart"] = "1"
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	root.add_child(w)
	await process_frame
	w.set_process(false)
	var tv := w.ground_view()
	_check(tv != null, "--dev pgart=1: ground_view() отдаёт TerrainView")
	if tv != null:
		_check(tv.background_texture() == null,
			"--dev pgart=1 headless: фон карты игнорирован (PgArt должен был его перекрыть,"
			+ " но в headless он null — запасной рисунок несёт ту же геометрию)")
	w.queue_free()
	await process_frame


## Один и тот же словарь — через файл (load_ambient) и напрямую (load_ambient_dict) — должен
## дать одинаковое число и содержимое излучателей: генератор не собирает свой формат.
func _test_ambient_dict_matches_file() -> void:
	var d := {
		"glows": [{"pos": [10, 20], "r": 30, "color": "ffb060", "flicker": 0.4}],
		"embers": [{"rect": [0, 0, 100, 50], "rate": 2.0, "color": "ff7a30"}],
		"fog": [{"rect": [0, 0, 200, 100], "count": 2, "color": "c8d2e8", "alpha": 0.2,
			"drift": [3, 1]}],
		"wisps": [{"rect": [0, 0, 150, 80], "count": 1, "color": "7fffd8"}],
		"water": [{"poly": [[0, 0], [10, 0], [10, 10]], "rate": 1.5, "color": "e0f6ff"}],
	}
	var f := FileAccess.open(AMB_TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()
	# LegionFx.setup() трогает world.entities (индекс для своего слоя земли) — нужен настоящий
	# собранный LegionWorld, не голый Node; каждый берёт свой отдельный мир, чтобы не делить
	# пулы частиц между двумя сравниваемыми загрузками.
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world_a := scene.instantiate() as LegionWorld
	var world_b := scene.instantiate() as LegionWorld
	root.add_child(world_a)
	root.add_child(world_b)
	await process_frame
	var fx_file := LegionFx.new()
	fx_file.setup(world_a)
	fx_file.rng.seed = 1
	var fx_dict := LegionFx.new()
	fx_dict.setup(world_b)
	fx_dict.rng.seed = 1
	var ok_file := fx_file.load_ambient(AMB_TMP)
	var ok_dict := fx_dict.load_ambient_dict(d)
	_check(ok_file and ok_dict, "load_ambient(path) и load_ambient_dict(d) обе вернули true")
	_check(fx_file._amb_glows.size() == fx_dict._amb_glows.size()
		and fx_file._amb_glows.size() == 1, "glows: одинаковое число излучателей (файл/словарь)")
	_check(fx_file._amb_emit.size() == fx_dict._amb_emit.size()
		and fx_file._amb_emit.size() == 4, "embers+fog+wisps+water: одинаковое число (файл/словарь)")
	if fx_file._amb_glows.size() == 1 and fx_dict._amb_glows.size() == 1:
		var ga: Dictionary = fx_file._amb_glows[0]
		var gb: Dictionary = fx_dict._amb_glows[0]
		_check(ga["pos"] == gb["pos"] and ga["r"] == gb["r"] and ga["color"] == gb["color"],
			"glows: содержимое совпадает (позиция/радиус/цвет)")
	fx_file.free()
	fx_dict.free()
	world_a.queue_free()
	world_b.queue_free()
	await process_frame
	DirAccess.remove_absolute(AMB_TMP)


## Процедурная карта без bg, PgArt ещё не собрал фон (headless — никогда не соберёт) —
## _dust_color не должен падать и не должен виснуть на несработавшем сигнале. LegionWorld
## здесь — пустой, вне дерева: LegionFx._load_ground читает только world.map/ground_view().
func _test_dust_color_no_bg_no_crash() -> void:
	var map := _sample_map()
	var fake_world := LegionWorld.new()
	fake_world.map = map
	var fx := LegionFx.new()
	fx.world = fake_world
	fx._load_ground(map)
	var col: Color = fx._dust_color(Vector2(100, 100))
	_check(col is Color, "_dust_color() без собранного фона возвращает Color, не падает")
	fx.free()
	fake_world.free()


func _sample_map() -> Dictionary:
	return {
		"id": "gen:1:1", "biome": "ash", "bg": "",
		"procgen": {"version": 1, "seed": 1, "k": 1},
		"roads": [{"id": "east", "path": [[100, 100], [400, 100], [400, 300]]}],
		"rocks": [[[500, 200], [560, 200], [560, 260], [500, 260]]],
		"water": [], "swamp": [], "bridges": [],
		"decor": [{"kind": "candle", "pos": [200, 200]}],
		"props": [{"item": "grave_sarc_01", "pos": [300, 300], "flip": false}],
		"ambient": {"glows": [{"pos": [200, 200], "r": 24}]},
	}
