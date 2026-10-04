extends SceneTree
## Повреждение не подменяет двухногую походку счетовода старым одноногим клипом.

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	if not ok:
		_fails += 1
	print("%s %s" % ["OK" if ok else "FAIL", message])


func _run() -> void:
	var view := CharView.new()
	root.add_child(view)
	view.setup("clerk", 42.0)
	view.set_locomotion(1.0)
	_check(view.current_state() == &"walk", "walk starts")
	view.react_hit()
	_check(view.current_state() == &"walk", "damage preserves complete walking pose")
	_check(float(view.get("_spring_v")) < 0.0, "damage still supplies spring feedback")
	_check(view.play_once(&"attack"), "attack can start immediately after damage")
	_check(view.current_state() == &"attack", "damage does not block the next attack")
	view.free()
	for kind: String in ["skeleton", "guard", "zombie", "ghost", "beetle",
		"signer", "lawyer", "mimic", "boss"]:
		var fighter := CharView.new()
		root.add_child(fighter)
		fighter.setup(kind, 46.0)
		fighter.set_direction(Vector2.UP)
		fighter.set_loop_state(&"walk")
		var anim: AnimatedSprite2D = fighter.get("_anim")
		var before := anim.animation
		fighter.react_hit()
		_check(fighter.current_state() == &"walk" and anim.animation == before,
			"%s damage preserves rear walking pose" % kind)
		_check(float(fighter.get("_spring_v")) < 0.0, "%s retains hit feedback" % kind)
		_check(fighter.play_once(&"attack"), "%s hit yields to attack" % kind)
		fighter.free()
	# Все виды занимают одни и те же места договора. Их якорь не может
	# перескакивать с центра фигуры на макушку при смене вида бойцов.
	for kind: String in ["guard", "clerk"]:
		var actor := CharView.new()
		root.add_child(actor)
		actor.setup(kind, 46.0)
		_check(absf(actor.ground_px() - 46.0 * CfgAnim.SKELETON_GROUND_OFF) < 0.1,
			"%s ground anchor matches laborer at equal height" % kind)
		actor.free()
	print("CLERK POSE: %d failures" % _fails)
	quit(1 if _fails else 0)
