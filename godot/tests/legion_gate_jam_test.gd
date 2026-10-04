extends SceneTree
##
## Регресс затора у ворот (медленная сессия 26.09.2026, d3296a1b; бэклог B-029, B-366).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_gate_jam_test.gd -- --mute
##
## Старый баг: враг переходил к следующей точке пути, только подойдя к ней ближе WAYPOINT_EPS
## (8 px), а толпа, которую расталкивание держит на 16–20 px друг от друга, кружила вокруг общей
## точки — у ворот «Моста» стоял ком из 20–35 врагов, наружу шла струйка, Юрист застревал.
##
## Состав волны — из карты мира после start_map (JSON карты с темпом читаемости и множителями
## уровня LegionChallenge — ровно то, что выйдет в бою), без призраков (летят не по дороге).
## B-366: тест держал копию чисел «Моста», и после D-0930-71 волны разошлись с ним; волны карт
## меняются балансом, а тест ловит кружение, а не плотность колонны. Суть проверки — два признака кружения:
## 1) за 60 с от ворот ушли все (прошли точку пути gone_wp или убиты);
## 2) ни один не провёл у ворот (круг r около center) дольше DWELL_MAX — колонна, идущая
##    сквозь ворота, проходит круг за секунды; кружащий стоит там десятками секунд.
## Наибольший ком у ворот печатается для сведения: он растёт с плотностью волны (36 зомби
## по 0,5 с на две дороги дают 20+ проходящих разом) и сам по себе затора не доказывает.
## Случаи: «Мост» 3-я и 5-я волна (ворота общие для двух дорог), «Архив» 5-я (0,3 с — самая
## плотная колонна кампании, двое ворот); 5-е волны — ещё и на «Аду» (×1,3 голов, ×0,8 промежуток).
## Итог «LEGION GATE JAM: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_gate_jam_test.cfg"
const DT := 1.0 / 60.0
const SECS := 60.0
## Дольше этого у ворот — кружит. Колонна проходит круг r = 70 px за 3–6 с даже в толчее;
## на старом коде (WAYPOINT_PASS_R = 0) кружащие стоят у ворот 30+ с.
const DWELL_MAX := 15.0

const BRIDGE_GATES := [Vector2(1175, 350)]
const ARCHIVE_GATES := [Vector2(1160, 100), Vector2(1160, 620)]
const CASES := [
	{"map": "bridge", "wave": 3, "lvl": "normal", "gates": BRIDGE_GATES, "gone_wp": 4},
	{"map": "bridge", "wave": 5, "lvl": "normal", "gates": BRIDGE_GATES, "gone_wp": 4},
	{"map": "bridge", "wave": 5, "lvl": "hell", "gates": BRIDGE_GATES, "gone_wp": 4},
	{"map": "archive", "wave": 5, "lvl": "normal", "gates": ARCHIVE_GATES, "gone_wp": 3},
	{"map": "archive", "wave": 5, "lvl": "hell", "gates": ARCHIVE_GATES, "gone_wp": 3},
]
## Круг «у ворот» вокруг точки gates.
const GATE_R := 70.0

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
	for c: Dictionary in CASES:
		_test_gate_crowd(c)
	Campaign.reset()
	print("LEGION GATE JAM: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Очередь волны wave_no карты (как WaveRunner: delay + interval·k), кроме призраков и полётов.
func _wave_queue(wave_no: int) -> Array[Array]:
	var queue: Array[Array] = []   # [время, путь, вид]
	var waves: Array = w.map.get("waves", [])
	if wave_no < 1 or wave_no > waves.size():
		return queue
	for g: Dictionary in (waves[wave_no - 1] as Dictionary).get("groups", []):
		var type := String(g.get("type", "zombie"))
		var path := w.road_remainder(String(g.get("road", "")), 0.0)
		if type == "ghost" or path.is_empty() or not _is_road(String(g.get("road", ""))):
			continue
		for k in int(g.get("count", 1)):
			queue.append([float(g.get("delay", 0.0)) + float(g.get("interval", 1.0)) * k, path,
				type])
	queue.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	return queue


func _is_road(id: String) -> bool:
	for r: Dictionary in w.map.get("roads", []):
		if String(r.get("id", "")) == id:
			return true
	return false


func _test_gate_crowd(c: Dictionary) -> void:
	var tag := "%s, волна %d, %s" % [c["map"], c["wave"], c["lvl"]]
	print("— %s уходит от ворот" % tag)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.dev["difficulty"] = String(c["lvl"])
	w.start_map(String(c["map"]))
	w.dev_invuln = true
	var queue := _wave_queue(int(c["wave"]))
	_check(queue.size() >= 40, "%s: в волне по дорогам %d проверяющих" % [tag, queue.size()])
	if queue.is_empty():
		return
	var gates: Array = c["gates"]
	var r := GATE_R
	var gone_wp := int(c["gone_wp"])
	var spawned: Array[Foe] = []
	var dwell: Dictionary = {}   # Foe -> секунд у ворот
	var t := 0.0
	var qi := 0
	var worst_crowd := 0
	for step in roundi(SECS / DT):
		while qi < queue.size() and float(queue[qi][0]) <= t:
			var path: PackedVector2Array = queue[qi][1]
			var f := w.spawn_foe_on_path(String(queue[qi][2]), path, path[0])
			if f != null:
				spawned.append(f)
				dwell[f] = 0.0
			qi += 1
		w._step(DT)
		t += DT
		var crowd := 0
		for f in spawned:
			if not f.alive:
				continue
			for gate: Vector2 in gates:
				if f.position.distance_to(gate) < r:
					crowd += 1
					dwell[f] = float(dwell[f]) + DT
					break
		worst_crowd = maxi(worst_crowd, crowd)
	var gone := 0
	var worst_dwell := 0.0
	for f in spawned:
		if not f.alive or f._wp >= gone_wp:
			gone += 1
		worst_dwell = maxf(worst_dwell, float(dwell[f]))
	print("  (появилось %d, ушло от ворот %d, наибольший ком у ворот %d, дольше всех у ворот %.1f с)"
		% [spawned.size(), gone, worst_crowd, worst_dwell])
	_check(spawned.size() == queue.size(), "%s: появились все %d" % [tag, queue.size()])
	_check(gone == spawned.size(), "%s: за %.0f с от ворот ушли все: %d из %d" % [tag, SECS, gone,
		spawned.size()])
	_check(worst_dwell <= DWELL_MAX, "%s: никто не кружит у ворот дольше %.0f с: %.1f с"
		% [tag, DWELL_MAX, worst_dwell])
