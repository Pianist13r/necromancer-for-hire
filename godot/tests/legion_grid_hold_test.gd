extends SceneTree
##
## Регресс B-506: сетка мира (LegionGrid) отвечает текущим units/foes сразу после start_map,
## без единого шага боя.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_grid_hold_test.gd -- --mute
##
## Corr-кампания держит мир (hold) с первого кадра боя (B-504) и снимает peek черновика:
## update_preview → LegionStaff.deployment_plan → assignment_plan → _busy → grid.nearest_foe.
## rebuild() сетки шёл только в _step, которого под hold ещё не было: _gw = 0, _gx/_gy давали −1,
## _f_head[−1] — 18 SCRIPT ERROR в накопленной кампании (Архив, turn006/t0). Тот же изъян после
## start_map на том же мире («Заново», следующая карта): индексы прошлой карты указывают мимо
## очищенных foes/units до первого шага.
## Три проверки: первая карта на hold (прямой запрос и настоящий путь превью), повторный
## start_map на построенной сетке, пустой мир без бойцов и врагов.
## Итог «LEGION GRID HOLD: N/M OK»; код выхода 1, если что-то упало. SCRIPT ERROR в логе гейт
## считает падением сам.
##

const SAVE := "user://legion_grid_hold_test.cfg"
## Враги первой карты — на разных клетках сетки (SPATIAL_CELL 48), на открытой земле _gray
## (вода x≈614–706, скалы у (880–1000, 360–470) и (420–530, 95–190)), вдали от Котла (180, 360).
const FOE_A := Vector2(560, 300)
const FOE_B := Vector2(800, 480)
## Враг второй карты — на клетке, где у первой карты врагов не было.
const FOE_C := Vector2(300, 200)
## Свободный писарь и его черновик — в тихом месте _gray, как в legion_core_v15_test.capture.
const CLERK := Vector2(380, 420)
const DRAFT_A := Vector2(420, 220)
const DRAFT_B := Vector2(420, 340)

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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	# встроенный мир: _ready не стартует карту сам — первый start_map идёт уже под hold, и сетка
	# до него ни разу не строилась (ровно состояние corr на t0: _gw = 0)
	w.embedded = true
	root.add_child(w)
	await _frames(2)
	await _test_first_map_on_hold()
	await _test_restart_keeps_grid_current()
	await _test_empty_world()
	Campaign.reset()
	print("LEGION GRID HOLD: %d/%d OK" % [_checks - _fails, _checks])
	w.queue_free()
	await process_frame
	quit(1 if _fails > 0 else 0)


## Карта под hold, как corr: кадры идут (_process), шаг мира — нет. Спящего мимика _gray
## (sleepers) снимаем через map_data: враги в тесте — только из hero_foe.
func _start_held(hero_foe: String) -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.dev["hero_foe"] = hero_foe
	w.hold = true
	var map_data: Dictionary = LegionWorld.load_map("_gray")
	map_data["sleepers"] = []
	w.start_map("_gray", map_data)
	while w.is_ground_loading():
		await process_frame
	await _frames(3)


func _foe_at(at: Vector2) -> Foe:
	for f in w.foes:
		if f.position == at:
			return f
	return null


func _test_first_map_on_hold() -> void:
	print("-- первая карта на hold (corr peek на t0)")
	await _start_held("zombie:%d:%d,zombie:%d:%d" % [FOE_A.x, FOE_A.y, FOE_B.x, FOE_B.y])
	_check(w.now == 0.0 and w.phase == LegionWorld.Phase.BATTLE,
		"мир в бою и не сделал ни шага (now = %.2f)" % w.now)
	var a := _foe_at(FOE_A)
	var b := _foe_at(FOE_B)
	_check(a != null and b != null and w.foes.size() == 2, "два врага расставлены start_map")
	# прямой запрос — тот, что падал в _busy (ASSIGN_BUSY_R)
	_check(w.grid.nearest_foe(FOE_A, LegionCfg.ASSIGN_BUSY_R, true) == a,
		"nearest_foe у первого врага видит его без шага мира")
	_check(w.grid.nearest_foe(FOE_B, LegionCfg.ASSIGN_BUSY_R, true) == b,
		"nearest_foe у второго врага видит его без шага мира")
	_check(w.grid.nearest_foe(CLERK, 30.0, true) == null,
		"nearest_foe вдали от врагов — пусто, не ошибка")
	_check(w.grid.nearest_unit(FOE_A, 30.0) == null,
		"nearest_unit без бойцов — пусто, не ошибка")
	# настоящий путь corr peek: свободный боец + черновик → update_preview → assignment_plan → _busy.
	# Ошибка внутри nearest_foe не рвёт план (_busy получает null и отвечает «свободен»), поэтому
	# до исправления здесь RED — только строкой SCRIPT ERROR в логе, которую гейт считает падением;
	# проверки ниже держат сам путь живым (черновик собран, писарь назначен).
	var clerk := w.spawn_unit(LegionCfg.KIND_CLERK, CLERK)
	_check(clerk != null and clerk.state == Legionnaire.State.FREE, "свободный писарь на поле")
	w.contracts.set_kind(LegionCfg.KIND_CLERK)
	w.contracts.begin(DRAFT_A)
	w.contracts.extend(DRAFT_B)
	w.contracts.update_preview()
	_check(w.contracts._preview != null, "черновик писаря собран под hold")
	_check(w.contracts._preview_plan.size() == 1
		and w.contracts._preview_plan[0]["unit"] == clerk,
		"превью под hold дошло до плана раздачи: писарь назначен (план %d)"
		% w.contracts._preview_plan.size())
	w.contracts.cancel()


## Та же сетка после боя с шагами: start_map на том же мире, индексы прошлой карты не живут.
func _test_restart_keeps_grid_current() -> void:
	print("-- повторный start_map на построенной сетке")
	w.hold = false
	await _frames(5)
	_check(w.now > 0.0, "бой первой карты сделал шаги (now = %.2f) — сетка построена шагом" % w.now)
	await _start_held("zombie:%d:%d" % [FOE_C.x, FOE_C.y])
	_check(w.now == 0.0 and w.foes.size() == 1, "вторая карта: один враг, ни одного шага")
	var c := _foe_at(FOE_C)
	_check(c != null and w.grid.nearest_foe(FOE_C, LegionCfg.ASSIGN_BUSY_R, true) == c,
		"nearest_foe видит врага второй карты без шага мира")
	# клетки врагов первой карты: прежние индексы указывали бы на foes[1] — мимо массива
	_check(w.grid.nearest_foe(FOE_A, 30.0, true) == null,
		"клетка врага прошлой карты пуста (индекс не пережил start_map)")
	_check(w.grid.nearest_foe(FOE_B, 30.0, true) == null,
		"клетка второго врага прошлой карты пуста")
	_check(w.grid.nearest_unit(CLERK, 30.0) == null,
		"клетка писаря прошлой карты пуста")


## Пустой мир: ни бойцов, ни врагов — запросы отвечают «никого», а не ошибкой.
func _test_empty_world() -> void:
	print("-- пустой мир без бойцов и врагов")
	await _start_held("")
	_check(w.units.is_empty() and w.foes.is_empty(), "мир пуст")
	_check(w.grid.nearest_foe(Vector2(640, 360), 400.0, true) == null,
		"nearest_foe в пустом мире — null")
	_check(w.grid.nearest_unit(Vector2(640, 360), 400.0) == null,
		"nearest_unit в пустом мире — null")
	_check(w.grid.count_foes_near(Vector2(640, 360), 400.0) == 0,
		"count_foes_near в пустом мире — 0")
