extends SceneTree
##
## Читаемость «Схватки» и подписей каста (сессия slow/pvp-read, 30.09.2026):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_read_test.gd -- --mute
##
## B-346: у бойцов «Схватки» цвет стороны — материал вида (PvpSideLook): у сторон разный, у
##        одиночки общий контур без цвета стороны; Е / тинт / вспышка материал не стирают.
## B-347: подписи урона Ку (ability_aim._note) не стоят друг на друге: у одной точки они
##        разъезжаются по вертикали; число живых подписей ограничено.
## B-351: итог «Схватки» зовёт числа «Армия», а не «Бойцов в строю».
## Итог «LEGION PVP READ: N/M OK»; код выхода 1 при провале. Сохранений не пишет.
##

var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _hue(u: Legionnaire) -> float:
	var m := u.view.look_material() as ShaderMaterial
	return float(m.get_shader_parameter("side_hue")) if m != null else -1.0


func _run() -> void:
	Campaign.set_save_path("user://legion_pvp_read_test.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
	# ── B-346 ──
	w.start_map("pvp:duel")
	var p0 := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 400), null, 0)
	var p1 := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(1300, 400), null, 1)
	var g1 := w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(1300, 460), null, 1)
	_check(_hue(p0) >= 0.0 and _hue(p1) >= 0.0, "PvP: у бойцов обеих сторон есть материал стороны")
	_check(not is_equal_approx(_hue(p0), _hue(p1)), "PvP: оттенки сторон различаются (%.2f и %.2f)"
		% [_hue(p0), _hue(p1)])
	_check(is_equal_approx(_hue(g1), _hue(p1)), "PvP: вахтёр стороны 1 — оттенок стороны")
	# Е / «Аврал» красит modulate вида, вспышка и постоянный тинт — self_modulate: материал на месте
	var mat0 := p0.view.look_material()
	p0.view.modulate *= CfgFx.HASTE_MODULATE
	p0.view.set_tint(Color(1.0, 0.85, 0.3))
	p0.view.flash()
	var impact := LegionImpactFx.new()
	impact._haste_tinted[p0.view.get_instance_id()] = p0.view
	p0.view.set_meta(&"pre_haste_tint", Color.WHITE)
	impact._untint_all()
	impact.free()
	_check(p0.view.look_material() == mat0 and _hue(p0) >= 0.0,
		"после Е, тинта элитки и вспышки цвет стороны на месте")
	# Одиночка получает общий контур, а не шейдер цвета PvP-стороны.
	w.start_map("fork")
	var solo := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 400))
	var solo_material := solo.view.look_material() as ShaderMaterial
	_check(solo_material != null and solo_material.shader == CharReadability.SHADER,
		"одиночка: общий контур без материала стороны")
	# ── B-347 ──
	var aim := w.ability_aim
	aim.notes.clear()
	for i in 4:
		aim._note(Vector2(400, 400), "−%d" % (34 - i * 8), Color.WHITE)
	var stacked := 0
	for i in aim.notes.size():
		for j in range(i + 1, aim.notes.size()):
			var a: Vector2 = aim.notes[i]["pos"]
			var b: Vector2 = aim.notes[j]["pos"]
			if absf(a.x - b.x) < aim.NOTE_SPACE_X and absf(a.y - b.y) < float(aim.NOTE_FONT):
				stacked += 1
	_check(aim.notes.size() == 4 and stacked == 0,
		"4 подписи Ку в одной точке разъехались (наложений: %d)" % stacked)
	aim.notes.clear()
	for i in 40:
		aim._note(Vector2(400, 400), "−1", Color.WHITE)
	_check(aim.notes.size() <= aim.NOTE_MAX, "живых не больше NOTE_MAX (%d)" % aim.notes.size())
	aim.notes.clear()
	# ── B-351 ──
	var d := PvpResult.describe({"winner": 0, "reason": PvpMatch.REASON_LIMIT, "t": 100.0,
		"sides": [{"hp": 500.0, "army": 97}, {"hp": 400.0, "army": 109}]})
	var text := "\n".join(d["lines"])
	_check(text.contains("97") and text.contains("109") and not text.contains("в строю"),
		"итог «Схватки»: армия, а не «в строю»")
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION PVP READ: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
