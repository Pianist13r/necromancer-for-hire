extends SceneTree
##
## Регресс «стен по рисунку» (медленная сессия d26f8623, 26.09.2026). Игорь: «каменная стена,
## а через неё юниты проходят свободно… чтобы точно я понимал, какие препятствия препятствия,
## а какие нет… чтобы через препятствия, которые выглядят как препятствие, юниты проходить не
## могли»; «на всех уровнях».
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_walls_test.gd -- --mute
##
## На старом коде падает: нарисованные стены «Двух отделов» и «Лабиринта», кучи хлама «Прораба»,
## скалы «Пустыря» были проходимы, а в ямах «Прораба» стояли невидимые скалы. Плюс
## инварианты: тонкая стена не пропускает путь A* ни в одной точке; боец, отброшенный на стену,
## останавливается; штрих руны обрывается о стену; подсветка препятствий видна, пока чертишь;
## враг и Юрист не ходят сквозь стены; Юрист не стоит у недосягаемой середины участка; враг,
## попавший в скалу, выходит к земле.
## Итог «LEGION WALLS: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_walls_test.cfg"
const DT := 1.0 / 60.0

## Точки на нарисованных препятствиях: должны быть непроходимы и резать штрих руны.
const SOLID := {
	"fork": [[447, 203], [524, 300], [524, 450], [447, 518], [670, 360], [440, 118],
		[230, 265], [900, 112], [1067, 240], [450, 601]],
	"maze": [[650, 112], [568, 300], [341, 380], [424, 460], [650, 504], [950, 344],
		[910, 420], [1220, 60], [300, 207]],
	"boss": [[400, 170], [500, 560], [1060, 40], [1040, 600], [1080, 380], [1262, 440]],
	"wasteland": [[900, 200], [480, 650], [800, 100], [30, 650], [880, 632]],
	# валуны «Моста» и «Болота» нарисованы (verifier d26f8623 опроверг «невидимые скалы»:
	# на наложении их закрыла заливка) — остаются твёрдыми
	"bridge": [[480, 357], [850, 418], [1150, 515]],
	"swamp": [[440, 183], [760, 375], [455, 610]],
}
## Места, где на рисунке пусто (плоские фундаменты в ямах «Прораба»): должны быть проходимы.
const OPEN := {
	"boss": [[770, 222], [770, 497]],
}

## Середина участка дальше LAWYER_REACH от земли, до которой дойти (verifier d26f8623): договор
## над озером «Болота», вдоль реки «Моста», в щели между скалами у саркофага «Пустыря». До правки
## Юрист выбирал такой участок, доходил до края и стоял, пока участок жив. Теперь он либо
## зачитывает с проходимой точки самого участка, либо не берёт участок в цель.
const LAW_CASES := [
	["swamp", [[1180, 390], [1270, 390]], [1150, 250]],
	["bridge", [[670, 330], [670, 470]], [780, 400]],
	["wasteland", [[174, 214], [174, 278]], [110, 330]],
]


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
	_test_painted_solid()
	_test_invisible_rocks_gone()
	_test_walls_do_not_leak()
	_test_path_goes_around()
	_test_knock_stops_at_wall()
	_test_foe_goes_around()
	_test_lawyer_sealed_field()
	_test_lawyer_goes_around()
	_test_lawyer_unreachable_middle()
	_test_foe_leaves_rock()
	_test_nearest_open()
	_test_stroke_stops_at_wall()
	_test_hint()
	Campaign.reset()
	print("LEGION WALLS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _start(id: String) -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map(id)


func _test_painted_solid() -> void:
	for id: String in SOLID:
		var t := LegionTerrain.new().setup(LegionWorld.load_map(id))
		for raw: Array in SOLID[id]:
			var p := Vector2(raw[0], raw[1])
			_check(not t.walkable(p) and t.is_rock(p), "%s: нарисованное препятствие %s непроходимо" % [id, p])


func _test_invisible_rocks_gone() -> void:
	for id: String in OPEN:
		var t := LegionTerrain.new().setup(LegionWorld.load_map(id))
		for raw: Array in OPEN[id]:
			var p := Vector2(raw[0], raw[1])
			_check(t.walkable(p) and not t.is_rock(p), "%s: на пустом месте рисунка %s — проходимо" % [id, p])


## Тонкая стена (ограда 16 px) не должна пропускать путь A* между центрами клеток: по обе
## стороны каждой стены через 8 px — пара точек, путь между ними не пересекает осевую стены.
func _test_walls_do_not_leak() -> void:
	var walls_total := 0
	for map: Dictionary in Campaign.maps():
		var id := String(map.id)
		var t := LegionTerrain.new().setup(map)
		walls_total += t.walls.size()
		var leaks := 0
		var pairs := 0
		for wl: Dictionary in t.walls:
			var path: PackedVector2Array = wl["path"]
			var off := float(wl["w"]) * 0.5 + 12.0
			for i in range(1, path.size()):
				var a := path[i - 1]
				var b := path[i]
				var n := (b - a).normalized().orthogonal()
				var steps := floori(a.distance_to(b) / 8.0)
				for s in range(1, steps):
					var m := a.lerp(b, float(s) / float(steps))
					var p := m + n * off
					var q := m - n * off
					if not (t.walkable(p) and t.walkable(q)):
						continue
					var route := t.find_path(p, q)
					# пути нет (поле за оградой замкнуто): find_path отдаёт одну точку назначения
					if route.size() < 2:
						continue
					pairs += 1
					route.insert(0, p)
					if _crosses_solid(route, path, t):
						leaks += 1
						if leaks <= 3:
							print("    утечка ", id, " ", p, " -> ", q)
		_check(leaks == 0, "%s: пути A* не проходят сквозь стены (%d пар)" % [id, pairs])
	_check(walls_total > 0, "в картах есть тонкие стены (walls)")


## Путь пересёк осевую стены там, где стена твёрдая. Там, где стену срезала проезжая часть
## (terrain._clear_roads), пересечение — это обход по дороге, а не утечка.
func _crosses_solid(route: PackedVector2Array, wall: PackedVector2Array, t: LegionTerrain) -> bool:
	for i in range(1, route.size()):
		for k in range(1, wall.size()):
			var x: Variant = Geometry2D.segment_intersects_segment(route[i - 1], route[i], wall[k - 1], wall[k])
			if x != null and t.is_rock(x as Vector2):
				return true
	return false


func _crosses(route: PackedVector2Array, wall: PackedVector2Array) -> bool:
	for i in range(1, route.size()):
		for k in range(1, wall.size()):
			if Geometry2D.segment_intersects_segment(route[i - 1], route[i], wall[k - 1], wall[k]) != null:
				return true
	return false


## «Два отдела»: из загородки буквой П у Котла на восток за её правую стену — только в обход.
func _test_path_goes_around() -> void:
	var t := LegionTerrain.new().setup(LegionWorld.load_map("fork"))
	var a := Vector2(447, 360)
	var b := Vector2(575, 360)
	var route := t.find_path(a, b)
	route.insert(0, a)
	var length := 0.0
	for i in range(1, route.size()):
		length += route[i].distance_to(route[i - 1])
	var wall := PackedVector2Array([Vector2(524, 203), Vector2(524, 518)])
	_check(not route.is_empty() and not _crosses(route, wall),
		"fork: путь из загородки не проходит сквозь правую стену")
	_check(length > a.distance_to(b) * 2.0, "fork: путь в обход (%.0f px против %.0f напрямую)" % [
		length, a.distance_to(b)])


## Отброс (прорыв давки, натиск) идёт шагами по рельефу — сквозь стену не пролетает.
func _test_knock_stops_at_wall() -> void:
	_start("fork")
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(470, 360))
	u.knock_to(Vector2(600, 360))
	_check(u.position.x < 516.0, "fork: отброшенный боец остановился у стены (x = %.0f)" % u.position.x)


## Враг, отброшенный с дороги в загородку, к следующей точке пути идёт в обход стены: до правки
## шёл по прямой к точке, и прямая ложилась сквозь стену.
func _test_foe_goes_around() -> void:
	_start("fork")
	w.dev_invuln = true
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(575, 360)]), Vector2(470, 360))
	var through := false
	var east := false
	var prev := f.position
	for step in roundi(25.0 / DT):
		w._step(DT)
		var x: Variant = Geometry2D.segment_intersects_segment(prev, f.position,
			Vector2(524, 203), Vector2(524, 518))
		if x != null and w.terrain.is_rock(x as Vector2):
			through = true
		prev = f.position
		east = east or f.position.x > 545.0
	_check(not through, "fork: враг не прошёл сквозь стену загородки")
	_check(east, "fork: враг обошёл загородку и вышел к точке пути (x = %.0f)" % f.position.x)


## Юрист и договор в поле за оградой (verifier d26f8623): поле «Двух отделов» у нижней дороги
## обнесено оградой с трёх сторон и краем карты с четвёртой — туда не дойти. До правки Юрист
## выбирал участок в поле и шёл к нему по прямой сквозь ограду (y = 601).
func _test_lawyer_sealed_field() -> void:
	_start("fork")
	w.dev_invuln = true
	w.contracts.active = true
	var c := w.contracts.add_contract(PackedVector2Array([Vector2(360, 665), Vector2(540, 665)]), 1, false)
	var f := w.spawn_foe_on_path("lawyer", PackedVector2Array([Vector2(450, 560), w.cauldron_pos]),
		Vector2(450, 560))
	var in_rock := false
	var deepest := f.position.y
	for step in roundi(10.0 / DT):
		w._step(DT)
		if not is_instance_valid(f) or not f.alive:
			break
		in_rock = in_rock or not w.terrain.walkable(f.position)
		deepest = maxf(deepest, f.position.y)
	_check(not in_rock, "fork: Юрист ни разу не стоял в ограде")
	_check(deepest < 592.0, "fork: Юрист не зашёл за ограду поля (max y = %.0f)" % deepest)
	_check(c.seg_alive(0), "fork: участок в недоступном поле цел")


## Юрист к участку внутри загородки буквой П (вход с запада) идёт в обход её правой стены,
## а не сквозь неё, и дочитывает. Срок договора продлён: иначе участок гаснет сам за 12 с, и
## тест принимал это за расторжение (verifier d26f8623) — считаем только причину «torn».
func _test_lawyer_goes_around() -> void:
	_start("fork")
	w.dev_invuln = true
	w.contracts.active = true
	var c := w.contracts.add_contract(PackedVector2Array([Vector2(447, 300), Vector2(447, 428)]), 1, false)
	c.ttl = 120.0
	var f := w.spawn_foe_on_path("lawyer", PackedVector2Array([Vector2(575, 360), w.cauldron_pos]),
		Vector2(575, 360))
	var through := false
	var in_rock := false
	var prev := f.position
	for step in roundi(40.0 / DT):
		w._step(DT)
		if not is_instance_valid(f) or not f.alive:
			break
		var x: Variant = Geometry2D.segment_intersects_segment(prev, f.position,
			Vector2(524, 203), Vector2(524, 518))
		if x != null and w.terrain.is_rock(x as Vector2):
			through = true
		in_rock = in_rock or not w.terrain.walkable(f.position)
		prev = f.position
		if _torn(c):
			break
	_check(not through and not in_rock, "fork: Юрист не прошёл сквозь стену загородки")
	_check(_torn(c), "fork: Юрист обошёл загородку и зачитал расторжение участка внутри")


func _torn(c: Contract) -> bool:
	return c.release_causes.values().has(&"torn")


func _test_lawyer_unreachable_middle() -> void:
	for case: Array in LAW_CASES:
		var id: String = case[0]
		_start(id)
		w.dev_invuln = true
		w.contracts.active = true
		var pts := PackedVector2Array()
		for raw: Array in case[1]:
			pts.append(Vector2(raw[0], raw[1]))
		var c := w.contracts.add_contract(pts, 1, false)
		c.ttl = 120.0
		var at := Vector2(case[2][0], case[2][1])
		var f := w.spawn_foe_on_path("lawyer", PackedVector2Array([at, w.cauldron_pos]), at)
		var targeted := false
		var stood := 0.0
		var longest := 0.0
		var prev := f.position
		for step in roundi(30.0 / DT):
			w._step(DT)
			if not is_instance_valid(f) or not f.alive or _torn(c):
				break
			targeted = targeted or f.law_c == c
			var still := f.law_c == c and f.law_read_t < 0.0 and f.position.distance_to(prev) < 0.01
			stood = stood + DT if still else 0.0
			longest = maxf(longest, stood)
			prev = f.position
		_check(not targeted or _torn(c), "%s: Юрист либо зачитал участок, либо не брал его в цель (%s)"
			% [id, "зачитал" if _torn(c) else ("стоит" if targeted else "не брал")])
		_check(longest < 2.0, "%s: не стоит у недосягаемой середины (дольше всего %.1f с)" % [id, longest])


## Враг, оказавшийся в непроходимой клетке, выходит к ближайшей земле (verifier d26f8623: Юрист,
## поставленный в скалу «Развилки», стоял там навсегда). В бою так не бывает — страховка.
func _test_foe_leaves_rock() -> void:
	_start("fork")
	w.dev_invuln = true
	for spec: Array in [["zombie", Vector2(524, 300)], ["lawyer", Vector2(524, 450)]]:
		var at: Vector2 = spec[1]
		var f := w.spawn_foe_on_path(spec[0], PackedVector2Array([at, w.cauldron_pos]), at)
		var solid := not w.terrain.walkable(f.position)
		for step in roundi(3.0 / DT):
			w._step(DT)
		_check(solid and w.terrain.walkable(f.position),
			"fork: %s из скалы %s вышел на землю (%s)" % [spec[0], at, f.position.round()])
	# глубоко: угол скалы «Пустыря», до земли ~158 px (третий verifier: поиск в 5 клеток не
	# находил землю, и враг стоял навсегда)
	_start("wasteland")
	w.dev_invuln = true
	var deep := Vector2(8, 8)
	var z := w.spawn_foe_on_path("zombie", PackedVector2Array([deep, w.cauldron_pos]), deep)
	var was_solid := not w.terrain.walkable(z.position)
	for step in roundi(8.0 / DT):
		w._step(DT)
	_check(was_solid and w.terrain.walkable(z.position),
		"wasteland: зомби из глубины скалы %s вышел на землю (%s)" % [deep, z.position.round()])


## nearest_open — ближайшая земля, а не первая клетка по порядку обхода (третий verifier:
## «Лабиринт», ограда x = 564 в клетку, курсор (574, 300) — земля в 10 px, ответ был в 30 px).
func _test_nearest_open() -> void:
	var t := LegionTerrain.new().setup(LegionWorld.load_map("maze"))
	var p := Vector2(574, 300)
	var q := t.nearest_open(p)
	_check(not t.walkable(p) and t.walkable(q) and p.distance_to(q) < 12.0,
		"maze: у ограды x = 564 ближайшая земля в %.1f px (%s)" % [p.distance_to(q), q.round()])
	var g := Vector2(700, 400)
	_check(t.walkable(g) and t.nearest_open(g) == g, "на земле nearest_open — сама точка")


## Штрих договора обрывается у стены: изнутри загородки на восток дальше стены не тянется.
func _test_stroke_stops_at_wall() -> void:
	_start("fork")
	var cf := w.contracts
	cf.mana = 100.0
	cf.begin(Vector2(440, 300))
	for x in range(450, 610, 10):
		cf.extend(Vector2(float(x), 300.0))
	var last: Vector2 = cf._draft[cf._draft.size() - 1]
	_check(last.x < 512.0, "fork: штрих оборвался у стены (x = %.0f)" % last.x)
	_check(cf.is_gesturing(), "fork: пока чертишь — жест идёт")
	cf.cancel()


## Подсветка препятствий: вспыхивает в начале боя и гаснет; видна, пока чертишь.
func _test_hint() -> void:
	_start("maze")
	var hint: ObstacleHint = w.obstacle_hint
	_check(hint != null and hint.poly_count() >= w.terrain.rocks.size() and hint.poly_count() > 0,
		"maze: подсветка знает все препятствия")
	if hint == null:
		return
	for step in roundi(0.5 / DT):
		hint.tick(DT)
	_check(hint.modulate.a > 0.5, "maze: вспышка препятствий в начале боя (a = %.2f)" % hint.modulate.a)
	for step in roundi(4.0 / DT):
		hint.tick(DT)
	_check(hint.modulate.a < 0.01, "maze: вспышка погасла (a = %.2f)" % hint.modulate.a)
	w.contracts.mana = 100.0
	w.contracts.begin(Vector2(250, 600))
	for step in roundi(0.4 / DT):
		hint.tick(DT)
	_check(hint.modulate.a > 0.9, "maze: пока чертишь — подсветка видна (a = %.2f)" % hint.modulate.a)
	w.contracts.cancel()
	for step in roundi(1.0 / DT):
		hint.tick(DT)
	_check(hint.modulate.a < 0.01, "maze: отпустил — погасла (a = %.2f)" % hint.modulate.a)
