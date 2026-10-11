extends SceneTree
## Бойцы у края карты и линия рядом (Игорь 10.10.2026: «особенно если скелеты стоят на краю карты,
## ты прямо недалеко от них линию проводишь, они всё равно к ней не идут, а потом только уже к
## какой-то следующей идут»).
##
## Край карты — это ворота: враги выходят из-за кадра, натиск уносит бойцов к ним же. Свободный
## боец в 35–70 px от проходящего врага не бил его (вне досягаемости; свободные не преследуют —
## D-0925-09) и не шёл в строй: раздача считала его «занятым дракой» (ASSIGN_BUSY_R — радиус
## прежней погони FREE_AGGRO, оставшийся после её отмены). Пока колонна шла мимо, линия рядом его
## не брала; следующая — уже брала. Здесь же — край без врагов и бойцы после натиска к краю: они
## набирались и до правки, тест держит, чтобы так и осталось.

const SAVE := "user://legion_edge_recruit_test.cfg"
const DT := 1.0 / 60.0
## Котёл в середине: бойцы у краёв — не резерв «у дома» (D-1009-C1), их берёт только ближний набор.
const MAP := {"size": [1280, 720], "cauldron": [640, 360], "start_army": 0}
var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	test_gate_column_passing()
	test_fighting_unit_stays()
	test_home_guard_stays()
	test_quiet_edges()
	test_after_charge_to_edge()
	finish()


func fresh() -> void:
	w.start_map("_gray", MAP)
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	w.contracts.mana = 1000.0
	w.dev_invuln = true


func steps(sec: float) -> void:
	for i in roundi(sec / DT):
		w._step(DT)


## Линия из точки mid вдоль tan, длиной len (шаг 8 px, как штрих).
func line_at(mid: Vector2, tan: Vector2, len := 96.0) -> Contract:
	var pts := PackedVector2Array()
	var n := roundi(len / 8.0)
	for k in n + 1:
		pts.append(mid + tan * (-len * 0.5 + 8.0 * k))
	return w.contracts.add_contract(pts, w.contracts.stroke_side(pts), false,
		LegionCfg.KIND_LABORER)


## Колонна врагов идёт из-за правого края вдоль верхней кромки (y = 60) мимо бойцов у края
## (y = 15): до врага 45 px — дальше досягаемости (26 + 8), ближе ASSIGN_BUSY_R (70).
func gate_column(n: int) -> void:
	for i in n:
		var at := Vector2(1340.0 - 22.0 * i, 60.0)
		w.spawn_foe_on_path("zombie", PackedVector2Array([at, Vector2(-200, 60)]), at)


func test_gate_column_passing() -> void:
	print("— у ворот: колонна идёт мимо, линия в 100 px")
	fresh()
	gate_column(12)
	var edge: Array[Legionnaire] = []
	for x in [1110.0, 1140.0, 1170.0]:
		edge.append(w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(x, 15)))
	steps(0.5)
	var near := 0
	for u in edge:
		var f := w.grid.nearest_foe(u.position, LegionCfg.ASSIGN_BUSY_R, true)
		if f != null and not u._in_reach(f):
			near += 1
	check(near == edge.size(), "сцена: у всех враг ближе %d px, но вне досягаемости (%d из %d)"
		% [int(LegionCfg.ASSIGN_BUSY_R), near, edge.size()])
	var c := line_at(Vector2(1140, 115), Vector2.RIGHT)
	steps(1.0)
	var on := edge.filter(func(u: Legionnaire) -> bool: return u.contract == c).size()
	check(on == edge.size(), "бойцы у края встали в линию рядом, пока колонна идёт мимо (%d из %d)"
		% [on, edge.size()])


## Кого враг уже бьёт вплотную (в досягаемости) — тот дерётся, линия рядом его не уводит.
func test_fighting_unit_stays() -> void:
	print("— дерущийся у края остаётся драться")
	fresh()
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(1100, 15))
	var at := Vector2(1120, 20)
	w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	line_at(Vector2(1100, 115), Vector2.RIGHT)
	w.grid.rebuild()
	w._assign_free()
	check(u.state == Legionnaire.State.FREE, "враг в досягаемости — боец не уходит в строй")


## «Оборона дома» (D-0930-70): свободный у Котла идёт на врага в зоне дома — это драка, линия
## рядом не перебивает её, как и до правки.
func test_home_guard_stays() -> void:
	print("— оборона дома остаётся дракой")
	fresh()
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(640, 260))
	var at := Vector2(640, 310)
	w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	w.contracts.add_contract(PackedVector2Array([Vector2(560, 200), Vector2(720, 200)]), 1, false,
		LegionCfg.KIND_LABORER)
	w.grid.rebuild()
	w._scan_home_threats()
	w._assign_free()
	check(w.home_threat(0) and u.state == Legionnaire.State.FREE,
		"враг в зоне дома в 50 px — защитник не уходит в строй")


## Край без врагов: слева, снизу, в углах; линия в 60–150 px к центру — набор берёт сразу.
func test_quiet_edges() -> void:
	print("— тихий край: линия в 60–150 px")
	var spots := [
		[Vector2(15, 360), Vector2.RIGHT], [Vector2(40, 360), Vector2.RIGHT],
		[Vector2(640, 690), Vector2.UP], [Vector2(640, 710), Vector2.UP],
		[Vector2(15, 15), Vector2(1, 1).normalized()], [Vector2(1265, 705), Vector2(-1, -1).normalized()],
		[Vector2(-6, 500), Vector2.RIGHT],   # вытолкнут давкой за кадр
	]
	var bad: Array[String] = []
	for s: Array in spots:
		for gap: float in [60.0, 100.0, 150.0]:
			fresh()
			var at: Vector2 = s[0]
			var inward: Vector2 = s[1]
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, at)
			var c := line_at(at + inward * gap, inward.orthogonal())
			w.grid.rebuild()
			w._assign_free()
			if c == null or u.contract != c:
				bad.append("%s+%d" % [at, int(gap)])
	check(bad.is_empty(), "у тихого края набраны все (%d случаев), мимо: %s"
		% [spots.size() * 3, ", ".join(bad)])


## Строй у нижнего края сорван натиском к краю (там бойцы и остаются: край — стена натиска,
## B-087), затем новая линия в 60–150 px от них — встают.
func test_after_charge_to_edge() -> void:
	print("— после натиска к краю")
	for gap: float in [60.0, 100.0, 150.0]:
		fresh()
		var c := line_at(Vector2(900, 620), Vector2.RIGHT)
		var mine: Array[Legionnaire] = []
		for p in c.posts:
			mine.append(w.spawn_unit(LegionCfg.KIND_LABORER, (p["pos"] as Vector2) + Vector2(0, -20)))
		steps(2.0)
		for s in c.seg_count():
			w.release_segment_aimed(c, s, Vector2.DOWN, 1.0, false)
		steps(4.5)
		var mean := Vector2.ZERO
		for u in mine:
			mean += u.position
		mean /= float(mine.size())
		var c2 := line_at(Vector2(900, mean.y - gap), Vector2.RIGHT)
		steps(1.0)
		var on := mine.filter(func(u: Legionnaire) -> bool: return u.contract == c2).size()
		var room := c2.posts.size() if c2 != null else 0
		check(mean.y > 690.0 and on == mini(room, mine.size()),
			"натиск унёс к краю (y %.0f), новая линия в %d px взяла %d из %d"
			% [mean.y, int(gap), on, mini(room, mine.size())])


func finish() -> void:
	Campaign.reset()
	print("LEGION EDGE RECRUIT: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
