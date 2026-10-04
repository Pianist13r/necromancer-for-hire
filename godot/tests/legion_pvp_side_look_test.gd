extends SceneTree
## Marker shape and haste tint preservation; screenshot remains required for readability.
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _run() -> void:
	var a := PvpRules.marker_points(Vector2.ZERO, 0, 7.0)
	var b := PvpRules.marker_points(Vector2.ZERO, 1, 7.0)
	_check(a.size() == 17 and b.size() == 5, "формы сторон различаются без цвета")
	_check(a[0].is_equal_approx(a[-1]) and b[0].is_equal_approx(b[-1]), "контуры замкнуты")
	var view := CharView.new()
	root.add_child(view)
	var original := PvpRules.tint(1) * CfgItems.ELITE_TINT
	view.modulate = original * CfgFx.HASTE_MODULATE
	view.set_meta(&"pre_haste_tint", original)
	var impact := LegionImpactFx.new()
	impact._haste_tinted[view.get_instance_id()] = view
	impact._untint_all()
	_check(view.modulate.is_equal_approx(original), "конец E сохраняет tint стороны и элитного")
	_check(not view.has_meta(&"pre_haste_tint"), "сохранённый tint очищен после восстановления")
	# Runtime regression: бой мог убрать труп раньше очередного визуального опроса E.
	var world := LegionWorld.new()
	var side := PvpSide.new(0)
	world.sides.append(side)
	world.hero = LegionHero.new()
	side.hero = world.hero
	var expired := Legionnaire.new()
	world.hero._haste_units.append(expired)
	world.hero._haste_left = 1.0
	expired.free()
	impact.world = world
	impact._tick_haste(1.0)
	_check(impact._haste_tinted.is_empty(), "удалённый боец пропускается без обращения к side")
	world.hero._haste_units.clear()
	world.free()
	impact.free()
	view.queue_free()
	await process_frame
	print("LEGION PVP SIDE LOOK: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
