extends SceneTree
##
## Регресс трека оптимизации (10.10.2026): горячие мелочи шага и вида — тот же итог, быстрее.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_hot_paths_test.gd -- --mute
##
## 1) LegionTerrain.walkable (развёрнут, без трёх вызовов) совпадает с прежней цепочкой
##    _flag_walkable(_flags_at(p)) во всех точках сетки 3,7 px с полями за краем — на картах
##    кампании и на зеркальном поле «Схватки» (mirror_x); и быстрее её не меньше чем в
##    WALK_RATIO раза (медиана отношений; прежний код — сам с собой ×1).
## 2) Вид: CharAnim/CharView сравнивают StringName клипа со String состояния без копии строки —
##    в живом бою (bridge, волны) на каждом виде и каждом 10-м шаге итог сравнения и знак
##    разворота те же, что у прежней формулы со String(animation) и литералом [3, 4, 5].
## Итог «LEGION HOT PATHS: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_hot_paths_test.cfg"
const DT := 1.0 / 60.0
const MAPS := ["bridge", "maze", "swamp", "boss", "fork", "pvp:duel"]
const STEP_PX := 3.7
const ROUNDS := 7
## Замер 10.10: развёрнутая проверка ×0,4–0,6 цепочки; прежний код сам с собой ×0,9–1,1.
const WALK_RATIO := 0.8

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
	_test_walkable()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_facing()
	Campaign.reset()
	print("LEGION HOT PATHS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_walkable() -> void:
	var mirrored := false
	var ratios := PackedFloat64Array()
	for id: String in MAPS:
		var t := LegionTerrain.new().setup(LegionWorld.load_map(id))
		mirrored = mirrored or t.mirror_x
		var pts := PackedVector2Array()
		var y := -20.0
		while y < t.size.y + 20.0:
			var x := -20.0
			while x < t.size.x + 20.0:
				pts.append(Vector2(x, y))
				x += STEP_PX
			y += STEP_PX
		var bad := 0
		var blocked := 0
		for p in pts:
			var old := LegionTerrain._flag_walkable(t._flags_at(p))
			if t.walkable(p) != old:
				bad += 1
			if not old:
				blocked += 1
		_check(bad == 0 and blocked > 0, "%s: walkable = прежней цепочке в %d точках (%d непроходимых)"
			% [id, pts.size(), blocked])
		for r in ROUNDS:
			var a := Time.get_ticks_usec()
			for p in pts:
				LegionTerrain._flag_walkable(t._flags_at(p))
			var b := Time.get_ticks_usec()
			for p in pts:
				t.walkable(p)
			var e := Time.get_ticks_usec()
			ratios.append(float(e - b) / float(maxi(1, b - a)))
	_check(mirrored, "среди карт есть зеркальное поле «Схватки»")
	ratios.sort()
	var ratio := ratios[ratios.size() / 2]
	print("  walkable: развёрнутая / прежняя цепочка = ×%.2f (медиана %d замеров)"
		% [ratio, ratios.size()])
	_check(ratio <= WALK_RATIO, "walkable быстрее прежней цепочки: ×%.2f ≤ %.2f" % [ratio, WALK_RATIO])


func _test_facing() -> void:
	w.dev.erase("no_waves")
	w.start_map("bridge")
	w.dev_invuln = true
	var seen := 0
	var bad := 0
	var clips := {}
	for step in 2400:
		w._step(DT)
		if step % 10 != 0:
			continue
		for v: CharView in CharView.registry:
			var a := v._anim
			if a == null:
				continue
			seen += 1
			clips[String(a.animation)] = true
			var other_old := String(a.animation) != a.current_state()
			var sign_old := 1.0
			if other_old:
				sign_old = -1.0 if a._shown_sector in [3, 4, 5] else 1.0
			else:
				sign_old = -1.0 if a._direction.x < 0.0 else 1.0
			if (a.animation != a.current_state()) != other_old or a.facing_sign() != sign_old:
				bad += 1
	_check(seen > 1000 and clips.size() >= 4, "видов-проверок %d, разных клипов %d" % [seen,
		clips.size()])
	_check(bad == 0, "сравнение клипа и знак разворота — как у прежней формулы (%d расхождений)"
		% bad)
