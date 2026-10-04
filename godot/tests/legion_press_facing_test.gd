extends SceneTree
##
## Регресс «давка — только в лоб» (медленная сессия d26f8623, 26.09.2026; партия «Лабиринт» по
## переписке, ходы 28, 30, 70). Давка v18 считала всех врагов в 56 px от участка: линия вдоль
## дороги (фланг) прогибалась от колонны, которая шла мимо (67–77 % при 1–3 бойцах), а пробка в
## устье коридора — от врагов, топтавшихся ПОЗАДИ неё. Прогиб уводил строй в сторону от них —
## «прорыв из воздуха», и контрприём против стены на дороге (фланг) наказывался давкой.
## Теперь давит тот, кто идёт или бьёт в сторону участка (LegionCfg.PRESS_FACING).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_press_facing_test.gd -- --mute
##
## На старом коде падают сцены «мимо» и «позади». Сцена «в лоб» — страховка: давка работает.
## Земля «Двух отделов» без стен (стены — tests/legion_walls_test.gd). Урона нет (invuln).
## Итог «LEGION PRESS FACING: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_press_facing_test.cfg"
const DT := 1.0 / 60.0

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
	_test_column_passing_by()
	_test_foes_behind()
	_test_column_head_on()
	_test_boss_ram_heading()
	Campaign.reset()
	print("LEGION PRESS FACING: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Линия подряда из точек a→b стрелкой dir; n бойцов стоят рядом и набираются за 4 с.
func _line(a: Vector2, b: Vector2, dir: Vector2, n_units: int, near: Vector2) -> Contract:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	var bare := w.map.duplicate(true)
	bare.erase("walls")
	w.terrain = LegionTerrain.new().setup(bare)
	w.dev_invuln = true
	for i in n_units:
		w.spawn_unit(LegionCfg.KIND_LABORER, near + Vector2(8.0 * float(i % 6), 6.0 * float(i / 6)))
	var pts := PackedVector2Array([a, b])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false,
		LegionCfg.KIND_LABORER)
	c.set_dir(dir)
	c.ttl = 9999.0
	for step in roundi(4.0 / DT):
		w._step(DT)
	return c


func _max_bend(c: Contract, seconds: float) -> float:
	var best := 0.0
	for step in roundi(seconds / DT):
		w._step(DT)
		for s in c.seg_count():
			if c.seg_alive(s):
				best = maxf(best, c.bend_frac(s))
	return best


## Колонна идёт по северной дороге (1120,160)→(800,160) мимо линии в 35 px от оси — вдоль неё.
func _test_column_passing_by() -> void:
	print("— колонна проходит мимо фланговой линии: прогиба нет")
	var c := _line(Vector2(880, 125), Vector2(1010, 125), Vector2.DOWN, 4, Vector2(900, 105))
	_check(c.seg_manned(0) + c.seg_manned(1) >= 3, "на линии бойцы: %d" % (c.seg_manned(0) + c.seg_manned(1)))
	var path := PackedVector2Array([Vector2(1120, 160), Vector2(800, 160), Vector2(800, 290)])
	for i in 14:
		w.spawn_foe_on_path("zombie", path, Vector2(1060.0 + 16.0 * float(i), 160.0 + (4.0 if i % 2 == 0 else -4.0)))
	var bend := _max_bend(c, 14.0)
	print("  (наибольший прогиб %.2f, прорывов %d)" % [bend, int(w.stats.get("press_breaks", 0))])
	_check(bend < 0.1, "фланг не прогнут колонной, идущей мимо (%.2f)" % bend)
	_check(int(w.stats.get("press_breaks", 0)) == 0, "прорывов нет")


## Пробка поперёк северной дороги (x = 340) стрелкой на север; враги ПОЗАДИ неё уходят на юг.
func _test_foes_behind() -> void:
	print("— враги позади пробки уходят прочь: прогиба нет")
	var c := _line(Vector2(290, 230), Vector2(390, 230), Vector2.UP, 4, Vector2(300, 205))
	var path := PackedVector2Array([Vector2(340, 290), Vector2(180, 360)])
	for i in 10:
		w.spawn_foe_on_path("zombie", path, Vector2(330.0 + 5.0 * float(i % 4), 250.0 + 7.0 * float(i / 4)))
	var bend := _max_bend(c, 6.0)
	print("  (наибольший прогиб %.2f)" % bend)
	_check(bend < 0.1, "пробка не прогнута врагами позади (%.2f)" % bend)


## Та же пробка, колонна идёт на неё с севера — давка работает, как в legion_press_test.
func _test_column_head_on() -> void:
	print("— колонна давит в пробку в лоб: прогиб и прорыв")
	var c := _line(Vector2(290, 230), Vector2(390, 230), Vector2.UP, 14, Vector2(300, 262))
	var path := PackedVector2Array([Vector2(340, 160), Vector2(340, 290), Vector2(180, 360)])
	for i in 16:
		w.spawn_foe_on_path("zombie", path, Vector2(340.0 + (6.0 if i % 2 == 0 else -6.0), 150.0 - 18.0 * float(i)))
	var bend := _max_bend(c, 20.0)
	print("  (наибольший прогиб %.2f, прорывов %d)" % [bend, int(w.stats.get("press_breaks", 0))])
	_check(bend >= 0.5 or int(w.stats.get("press_breaks", 0)) >= 1, "колонна прогнула пробку (%.2f)" % bend)
	_check(int(w.stats.get("press_breaks", 0)) >= 1, "и прорвала её")


## Таран Прораба: во время разбега ход смотрит на цель тарана. До правки разбег шёл со старым
## направлением (по дороге), и Прораб, таранящий фланг сбоку, мог не давить (verifier d26f8623).
func _test_boss_ram_heading() -> void:
	print("— таран Прораба: ход на цель")
	_line(Vector2(290, 230), Vector2(390, 230), Vector2.UP, 0, Vector2(300, 262))
	var at := Vector2(560, 360)
	var f := w.spawn_foe_on_path("boss", PackedVector2Array([at, Vector2(180, 360)]), at)
	f._dir = Vector2.LEFT
	f.ram_pos = at + Vector2(0, 90)
	f.ram_t = 0.001
	f.tick(DT)
	var h := f.heading()
	_check(h.dot(Vector2.DOWN) > 0.99, "разбег смотрит на цель тарана: %s" % h)
