extends SceneTree
##
## Регресс медленной работы 25–26.09.2026 (сессия a660c562): находки игры по переписке.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_slow_fixes_test.gd -- --mute
##
## 1) площадка рождает бойцов веером перед дверью, а не стопкой в одной точке;
## 2) вставший на дистанции нотариус не запирает идущего за ним зомби;
## 3) превью волны — одна строка на вид врага, несколько ворот — короткими названиями.
## (Вербовка «ближайшие первыми» откатана: жадный порядок оставлял бойцов без мест в плотной
## армии — verifier 26.09, сцена C:\AI\necro\batches\corr\verifier-probes\probe_stuck.gd.)
## Итог «LEGION SLOW FIXES: N/M OK»; код выхода 1, если что-то упало. Карта _plots (река
## посередине, x 614–706 — позиции только западнее), кампания нейтральная, сохранение временное.
##

const SAVE := "user://legion_slow_fixes_test.cfg"
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
	_test_door_fan()
	_test_signer_passable()
	_test_preview_compact()
	Campaign.reset()
	print("LEGION SLOW FIXES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Карта без своих бойцов на старте; волны — только когда тест их проверяет.
func _fresh(map_id: String, waves := false) -> void:
	if waves:
		w.dev.erase("no_waves")
	else:
		w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map(map_id)
	w.dev_invuln = false


func _test_door_fan() -> void:
	print("— веер у двери")
	_fresh("_plots")
	var plot: Dictionary = w.staff.plots[0]
	w.souls = 1000
	var b := w.staff.build(plot, LegionCfg.KIND_LABORER)
	_check(b != null, "Бытовка построена")
	if b == null:
		return
	for i in roundi(6.0 / DT):
		w.now += DT
		w.staff.tick(DT)
	var pts: Array[Vector2] = []
	for u in w.units:
		if u.alive and u.home == b:
			pts.append(u.position)
	_check(pts.size() == b.cap, "штат заполнен: %d/%d" % [pts.size(), b.cap])
	var distinct: Dictionary = {}
	var inside := true
	var in_front := true
	for p in pts:
		distinct[Vector2i(roundi(p.x), roundi(p.y))] = true
		# B-083: веер площадки шире кольца входа на SPAWN_FAN_EXTRA (сторона дальше от дороги)
		if p.distance_to(b.entry) > LegionCfg.BUILDING_ENTRY_RING.y + LegionCfg.SPAWN_FAN_EXTRA + 0.5:
			inside = false
		if p.y < b.entry.y - 0.5:
			in_front = false
	_check(distinct.size() >= pts.size() - 1,
		"не стопкой: %d разных точек из %d" % [distinct.size(), pts.size()])
	_check(inside, "все в веере у двери (не дальше %d px)"
		% int(LegionCfg.BUILDING_ENTRY_RING.y + LegionCfg.SPAWN_FAN_EXTRA))
	_check(in_front, "все перед дверью, не на крыше")


func _test_signer_passable() -> void:
	print("— вставший нотариус не запирает колонну")
	_fresh("_plots")
	# путь — остаток от точки появления: враг сперва идёт к первой точке пути
	var s_at := Vector2(450, 300)
	var z_at := Vector2(490, 300)
	var end := Vector2(100, 300)
	# боец в 180 px впереди держит нотариуса на дистанции (standoff 200), зомби — его прикрытие
	var guard := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(270, 300))
	var signer := w.spawn_foe_on_path("signer", PackedVector2Array([s_at, end]), s_at)
	var zombie := w.spawn_foe_on_path("zombie", PackedVector2Array([z_at, end]), z_at)
	_check(guard != null and signer != null and zombie != null, "боец, нотариус и зомби на месте")
	if signer == null or zombie == null:
		return
	for i in roundi(3.0 / DT):
		w._step(DT)
	_check(signer.alive and signer.holding, "нотариус стоит на дистанции")
	_check(zombie.alive and zombie.position.x < signer.position.x - 10.0,
		"зомби прошёл сквозь стоящего: x %d против %d" % [roundi(zombie.position.x),
			roundi(signer.position.x)])


func _test_preview_compact() -> void:
	print("— превью волны: строка на вид врага")
	_fresh("fork", true)
	var types: Dictionary = {}
	var sources: Dictionary = {}
	for g in w.wave_runner.next_wave_groups():
		types[String(g["type"])] = true
		sources[String(g["from"])] = true
	_check(sources.size() >= 2, "у ближней волны Развилки двое ворот: %d" % sources.size())
	w.hud._update_preview()
	var text := w.hud._preview_text.text
	var lines := text.split("\n")
	# Заголовок + одна строка на вид (без разбивки по воротам внутри неё, B-203) + мелкая
	# подпись воротами вторым «этажом» — она есть, потому что дорог у этой волны не больше двух
	# (B-204: с тремя и более подпись уступает место однобуквенным меткам у самого вида).
	var extra := 1 if sources.size() <= 2 else 0
	_check(lines.size() == 1 + types.size() + extra,
		"строк %d = заголовок + %d видов + %d подпись воротами" % [lines.size(), types.size(), extra])
	_check(text.contains("сев.") and text.contains("юж."), "ворота короткими названиями")
