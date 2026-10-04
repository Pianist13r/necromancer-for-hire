extends SceneTree
##
## B-355 (30.09.2026): подписи дорог в превью волны на сгенерированных картах. Генератор даёт двум
## дорогам одной стороны id north/south, превью показывало id как сторону света — на карте с одними
## воротами справа выходило «сев. ×4 · юж. ×3», а на карте с тремя дорогами восточная дорога с id
## south подписывалась «ю». Теперь у gen-карты подпись по стороне ворот и положению дороги;
## кампания — по id, как было.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_road_labels_test.gd -- --mute
##
## Карты (разведка 30.09): gen:3341246352:1 — «Вызов дня» объект №1, одни ворота справа с развилкой;
## gen:2:1 — двое ворот слева; gen:3:1 — двое ворот справа + северные; gen:1:6 — одна дорога.
## Итог «LEGION ROAD LABELS: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_road_labels_test.cfg"
const LAYOUT := "res://scripts/legion/procgen/pg_layout.gd"
const FORK_ONE_GATE := "gen:3341246352:1"
const TWO_WEST := "gen:2:1"
const THREE_ROADS := "gen:3:1"
const SINGLE := "gen:1:6"
const PVP := "gen:7:3:pvp"

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
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	await _test_fork_one_gate()
	await _test_two_gates_one_side()
	await _test_three_roads_letters()
	await _test_campaign_unchanged()
	_test_labels_table()
	_test_pvp_field()
	Campaign.reset()
	print("LEGION ROAD LABELS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Id дорог карты по стороне ворот (первая точка пути за краем кадра).
func _ids_by_side(map: Dictionary) -> Dictionary:
	var out := {}
	for r: Dictionary in map.get("roads", []):
		var p: Array = r["path"][0]
		var side := "south"
		if float(p[0]) < 0.0:
			side = "west"
		elif float(p[0]) > 1280.0:
			side = "east"
		elif float(p[1]) < 0.0:
			side = "north"
		if not out.has(side):
			out[side] = []
		(out[side] as Array).append(String(r["id"]))
	return out


func _open(map_id: String) -> Dictionary:
	w.start_map(map_id)
	w.contracts.human_input = false
	await process_frame
	_check(not w.map.is_empty(), "%s: карта загрузилась" % map_id)
	return _ids_by_side(w.map)


func _preview_of(groups: Array[Dictionary]) -> String:
	var wr := WaveRunner.new()
	wr.world = w
	wr.waves = [{"pause": 10, "next_in": 40, "groups": groups}]
	wr.index = -1
	wr.phase = WaveRunner.Phase.PAUSE
	w.wave_runner = wr
	w.hud._update_preview()
	return w.hud._preview_text.text


## «Вызов дня» №1: одни ворота справа, две ветки — одно название ворот и «верх./ниж.».
func _test_fork_one_gate() -> void:
	print("— одни ворота справа с развилкой (%s)" % FORK_ONE_GATE)
	var sides := await _open(FORK_ONE_GATE)
	var east: Array = sides.get("east", [])
	_check(sides.size() == 1 and east.size() == 2, "две дороги, обе справа: %s" % [sides])
	if east.size() != 2:
		return
	var text := _preview_of([
		{"type": "zombie", "road": east[0], "count": 4},
		{"type": "zombie", "road": east[1], "count": 3},
	])
	print("    превью: ", text.replace("\n", " ⏎ "))
	_check(not text.contains("сев.") and not text.contains("юж."),
		"нет «сев./юж.» — таких ворот на карте нет")
	_check(text.contains("вост. ворота: "), "одни восточные ворота названы один раз")
	_check(text.contains("верх. ×") and text.contains("ниж. ×"), "ветки — «верх.» и «ниж.»")


## Двое ворот на левом краю: оба «зап.», различаются положением.
func _test_two_gates_one_side() -> void:
	print("— двое ворот слева (%s)" % TWO_WEST)
	var sides := await _open(TWO_WEST)
	var west: Array = sides.get("west", [])
	_check(sides.size() == 1 and west.size() == 2, "две дороги, обе слева: %s" % [sides])
	if west.size() != 2:
		return
	var text := _preview_of([
		{"type": "zombie", "road": west[0], "count": 5},
		{"type": "beetle", "road": west[1], "count": 2},
	])
	print("    превью: ", text.replace("\n", " ⏎ "))
	_check(not text.contains("сев.") and not text.contains("юж."), "нет «сев./юж.»")
	_check(text.contains("зап. верх. ×") and text.contains("зап. ниж. ×"),
		"двое западных ворот — «зап. верх.» и «зап. ниж.»")
	_check(not text.contains("ворота:"), "разные ворота не сведены под одно название")


## Три дороги (двое ворот справа + северные): однобуквенные метки у вида — по стороне ворот.
func _test_three_roads_letters() -> void:
	print("— три дороги (%s)" % THREE_ROADS)
	var sides := await _open(THREE_ROADS)
	var east: Array = sides.get("east", [])
	var north: Array = sides.get("north", [])
	_check(east.size() == 2 and north.size() == 1, "двое справа и одни сверху: %s" % [sides])
	if east.size() != 2 or north.size() != 1:
		return
	var groups: Array[Dictionary] = []
	for road: String in [east[0], east[1], north[0]]:
		groups.append({"type": "zombie", "road": road, "count": 6})
	var text := _preview_of(groups)
	print("    превью: ", text.replace("\n", " ⏎ "))
	_check(text.contains("(в·с)") or text.contains("(с·в)"),
		"метки у вида — «в» и «с», по сторонам ворот")
	_check(not text.contains("ю·") and not text.contains("·ю") and not text.contains("(ю"),
		"восточную дорогу с id south не зовут «ю»")


## Кампания: id — настоящие стороны, подписи прежние.
func _test_campaign_unchanged() -> void:
	print("— кампания (fork)")
	await _open("fork")
	var text := _preview_of([
		{"type": "zombie", "road": "north", "count": 20},
		{"type": "zombie", "road": "south", "count": 16},
	])
	_check(text.contains("сев. ×20 · юж. ×16"), "«Развилка» по-прежнему «сев. ×20 · юж. ×16»")


## Таблица подписей генератора напрямую.
func _test_labels_table() -> void:
	print("— PgLayout.road_labels")
	var layout := load(LAYOUT) as GDScript
	_check(layout.has_method("road_labels"), "PgLayout.road_labels есть")
	if not layout.has_method("road_labels"):
		return
	var camp: Dictionary = layout.call("road_labels", w.load_map("fork"))
	_check(camp.is_empty(), "карта кампании — подписей генератора нет (берутся по id)")
	var single_map := ProcGen.map_from_id(SINGLE)
	var single: Dictionary = layout.call("road_labels", single_map)
	_check(single.size() == 1, "одна дорога — одна подпись")
	for id: String in single:
		var lab: Dictionary = single[id]
		_check(String(lab["short"]) == "вост." and String(lab["branch"]) == "" and
			not bool(lab["fork"]), "одна дорога справа — просто «вост.»: %s" % [lab])
		_check(String(lab["title"]) == "восточные ворота", "длинное — «восточные ворота»")
	var fork: Dictionary = layout.call("road_labels", ProcGen.map_from_id(FORK_ONE_GATE))
	var gates := {}
	var branches: Array[String] = []
	for id: String in fork:
		gates[String(fork[id]["gate"])] = true
		branches.append(String(fork[id]["branch"]))
		_check(bool(fork[id]["fork"]), "%s: развилка отмечена" % id)
		_check(String(fork[id]["title"]).ends_with("ветка"), "%s: длинное — «… ветка»: %s" % [
			id, fork[id]["title"]])
	_check(gates.size() == 1, "у развилки ключ ворот общий")
	branches.sort()
	_check(branches == ["верх.", "ниж."], "ветки развилки: %s" % [branches])
	var two: Dictionary = layout.call("road_labels", ProcGen.map_from_id(TWO_WEST))
	var two_gates := {}
	for id: String in two:
		two_gates[String(two[id]["gate"])] = true
		_check(not bool(two[id]["fork"]), "%s: разные ворота — не развилка" % id)
	_check(two_gates.size() == 2, "двое ворот — два ключа")
	# «верх.» — у верхних ворот (меньший y точки ворот)
	for id: String in two:
		var path: Array = []
		for r: Dictionary in ProcGen.map_from_id(TWO_WEST)["roads"]:
			if String(r["id"]) == id:
				path = r["path"]
		var other_y := INF
		for r: Dictionary in ProcGen.map_from_id(TWO_WEST)["roads"]:
			if String(r["id"]) != id:
				other_y = float(r["path"][0][1])
		var upper := float(path[0][1]) < other_y
		_check(String(two[id]["branch"]) == ("верх." if upper else "ниж."),
			"%s: %s ворота — «%s»" % [id, "верхние" if upper else "нижние", two[id]["branch"]])


## B-356: поле «Схватки» (gen:N:K:pvp). Дороги сторон начинаются со шва посередине поля (x = 800),
## а не за краем, — «сторона ворот» там не определена, и прежняя разметка давала «юж. 1-я…4-я» и
## «s0_east» → south. Подписей генератора у PvP-поля нет (как у кампании): превью в «Схватке»
## скрыто (B-320/B-352), понадобятся подписи — придумывать их для шва отдельно.
func _test_pvp_field() -> void:
	for id: String in [PVP, "gen:23:3:pvp", "gen:3341246352:3:pvp"]:
		print("— поле «Схватки» (%s)" % id)
		var map := ProcGen.map_from_id(id)
		_check(map.has("procgen") and Dictionary(map["procgen"]).has("pvp"), "%s: карта PvP" % id)
		var seam := 0
		for r: Dictionary in map.get("roads", []):
			var p: Array = r["path"][0]
			if float(p[0]) > 0.0 and float(p[0]) < 1600.0 and float(p[1]) > 0.0:
				seam += 1
		_check(seam > 0, "%s: есть дороги, начатые внутри поля (%d)" % [id, seam])
		var labels: Dictionary = PgLayout.road_labels(map)
		_check(labels.is_empty(), "%s: подписей генератора нет, а было %d" % [id, labels.size()])
