extends SceneTree


func _initialize() -> void:
	var shots := LegionProjectiles.new()
	if not shots.has_method("visible_trail"):
		print("LEGION PROJECTILE READ: FAIL no readable flight trail")
		quit(1)
		return
	var shot := {"pos": Vector2(70, 40), "from": Vector2(10, 40)}
	var trail: PackedVector2Array = shots.call("visible_trail", shot)
	var ok: bool = trail.size() == 2 and trail[1] == shot.pos \
		and trail[0].distance_to(trail[1]) >= 20.0
	shot.pos = Vector2(12, 40)
	trail = shots.call("visible_trail", shot)
	ok = ok and trail[0].x >= 10.0 and trail[1] == shot.pos
	shot.pos = shot.from
	trail = shots.call("visible_trail", shot)
	ok = ok and trail.is_empty()
	var target := Foe.new()
	target.def = {"body": 50.0}
	target.position = Vector2(-50, 60)
	shot.pos = Vector2(70, 40)
	shot.target = target
	trail = shots.call("visible_trail", shot)
	ok = ok and trail[0].x > trail[1].x
	target.free()
	print("LEGION PROJECTILE READ: ", "4/4 OK" if ok else "FAIL")
	quit(0 if ok else 1)
