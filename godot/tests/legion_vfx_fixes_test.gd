extends SceneTree
##
## Регресс slow/vfx-fixes 29.09 — три дефекта после слияния правки эффектов:
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_vfx_fixes_test.gd -- --mute
##
## 1) пузыри простоя: общий потолок IDLE_ICON_MAX не прячет целый вид — четыре кучки
##    чернорабочих (заспавнены первыми) и простаивающие счетоводы: у счетоводов есть пузырь,
##    всего не больше 6;
## 2) сетка после уборки: индексы _u_head/_u_next указывают в актуальный world.units, и
##    nearest_unit не читает мимо массива (иначе SCRIPT ERROR «Out of bounds», его ловит гейт);
## 3) `--dev shot_count=0` не вешает игру: _shot_due() выполняется на кадре --shot-frame.
## Итог «LEGION VFX FIXES: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_vfx_fixes_test.cfg"

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


func _fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.contracts.active = true
	w.hero.reset()


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_idle_kinds()
	_test_grid_after_cleanup()
	_test_shot_count_zero()
	Campaign.reset()
	print("LEGION VFX FIXES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── 1. Пузыри простоя ───────────────────────────────────────────────────────

func _test_idle_kinds() -> void:
	print("— пузыри простоя: каждому виду свой, потолок не растёт")
	_fresh()
	w.contracts.add_contract(PackedVector2Array([Vector2(1100, 600), Vector2(1100, 680)]), 1,
		false, LegionCfg.KIND_LABORER)
	w.contracts.add_contract(PackedVector2Array([Vector2(1000, 600), Vector2(1000, 680)]), 1,
		false, LegionCfg.KIND_CLERK)
	for k in 4:
		for i in 3:
			w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160 + k * 200, 200 + i * 8))
	for i in 3:
		w.spawn_unit(LegionCfg.KIND_CLERK, Vector2(600, 500 + i * 8))
	w.grid.rebuild()
	for u in w.units:
		u.tick(3.0)
	var owners: Dictionary = Legionnaire.idle_icon_owners(w)
	var clerk_idle := 0
	var clerk_shown := 0
	for u in w.units:
		if u.kind == LegionCfg.KIND_CLERK and u.state == Legionnaire.State.FREE \
				and u.idle_time >= LegionCfg.IDLE_NOTICE_TIME:
			clerk_idle += 1
			if owners.has(u.get_instance_id()):
				clerk_shown += 1
	_check(clerk_idle == 3, "три счетовода простаивают (%d)" % clerk_idle)
	_check(clerk_shown >= 1, "у счетоводов есть пузырь (%d)" % clerk_shown)
	_check(owners.size() <= 6, "всего пузырей %d, не больше 6" % owners.size())
	_check(owners.size() >= 1 and owners.size() <= maxi(LegionCfg.IDLE_ICON_MAX, 2),
		"два вида: пузырей %d, не шумнее потолка %d" % [owners.size(), LegionCfg.IDLE_ICON_MAX])


# ── 2. Сетка после уборки ───────────────────────────────────────────────────

func _test_grid_after_cleanup() -> void:
	print("— сетка после _cleanup: индексы актуальны")
	_fresh()
	for i in 8:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300 + i * 30, 300))
	w.grid.rebuild()
	for i in [0, 2, 5]:
		var u: Legionnaire = w.units[i]
		u.take_damage(9999.0, u.position)
	w._cleanup(0.0)
	var bad := 0
	var listed := 0
	for head: int in w.grid._u_head:
		var i := head
		while i != -1:
			listed += 1
			if i >= w.units.size() or w.units[i].idx != i:
				bad += 1
				break
			i = w.grid._u_next[i]
	_check(bad == 0, "все индексы сетки указывают в units (битых %d)" % bad)
	_check(listed == w.units.size(), "в сетке все живые: %d из %d" % [listed, w.units.size()])
	# то, что делают подсказки поля: спросить сетку после уборки
	var found := w.grid.nearest_unit(Vector2(300 + 7 * 30, 300), 40.0)
	_check(found != null and found.alive, "nearest_unit после уборки отдаёт живого бойца")


# ── 3. shot_count=0 ─────────────────────────────────────────────────────────

func _test_shot_count_zero() -> void:
	print("— --dev shot_count=0: кадр снимается, игра не виснет")
	_fresh()
	w.dev["shot_count"] = "0"
	w._shot_frame = 90
	w._frames = 90
	_check(w._shot_due(), "на кадре --shot-frame снимок «пора»")
	w._frames = 91
	_check(not w._shot_due(), "следующий кадр — серии нет (одиночный снимок)")
	w.dev.erase("shot_count")
	w._frames = 90
	_check(w._shot_due(), "без ключа поведение прежнее")
