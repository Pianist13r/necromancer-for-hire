extends SceneTree
## Настоящие Foe двигаются симуляцией; вид сам выбирает idle/walk по перемещению.

const DT := 1.0 / 60.0
var checks := 0
var fails := 0
var world: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s" % ["OK" if ok else "FAIL", label])


func _step(foe: Foe) -> void:
	world.grid.rebuild()
	foe.tick(DT)
	foe.view._process(DT)


func _sleep_wake() -> void:
	var start := Vector2(500, 300)
	var mimic := world.spawn_foe_on_path("mimic", PackedVector2Array([start, start + Vector2.DOWN * 300]), start)
	mimic.state = Foe.State.SLEEP
	mimic.view.set_process(false)
	mimic.view.set_loop_state(&"sleep")
	for i in 12:
		_step(mimic)
	check(mimic.position == start and mimic.view.current_state() == &"sleep",
		"sleep event stays sleep while stationary")
	mimic.take_damage(1.0, start + Vector2.UP)
	check(mimic.state == Foe.State.WAKE and mimic.view.current_state() == &"wake",
		"real damage event starts wake")
	# Движение извне не может перебить одноразовое пробуждение.
	mimic.position += Vector2(0, 1)
	mimic.view._process(DT)
	check(mimic.view.current_state() == &"wake", "wake clip is not replaced by movement")
	for i in 25:
		_step(mimic)
	mimic.view._anim._on_animation_finished()
	_step(mimic)
	check(mimic.view.current_state() == &"walk", "real wake recovery resumes locomotion")


func _run() -> void:
	Campaign.set_save_path("user://legion_foe_locomotion_test.cfg")
	Campaign.reset()
	world = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	world.embedded = true
	root.add_child(world)
	await process_frame
	world.dev = {"spawn_units": "0", "no_waves": "1"}
	world.start_map("wasteland")
	world.set_process(false)
	world.terrain = LegionTerrain.new().setup({})
	for kind: String in ["zombie", "ghost", "beetle", "signer", "lawyer", "mimic", "boss", "shield_inspector"]:
		var start := Vector2(500, 300)
		var foe := world.spawn_foe_on_path(kind, PackedVector2Array([start, start + Vector2(0, 300)]), start)
		foe._skill_cd = 1000.0
		foe._roar_cd = 1000.0
		foe.view.set_process(false)
		foe.view._process(DT)
		for i in 12:
			_step(foe)
		check(foe.position.distance_to(start) > 1.0, kind + ": real simulation moved")
		check(foe.view.current_state() == &"walk", kind + ": moving Foe shows walk")
		check(String(foe.view._anim.animation).ends_with("_s"), kind + ": real vertical path selects S")
		foe.stun(2.0)
		var stopped := foe.position
		for i in 12:
			_step(foe)
		check(foe.position == stopped, kind + ": stun keeps real position")
		check(foe.view.current_state() == &"idle", kind + ": stationary Foe shows idle")
		foe.stun_t = 0.0
		_step(foe)
		foe.view.attack_impact()
		check(foe.view.current_state() == &"attack", kind + ": impact starts")
		_step(foe)
		check(foe.view.current_state() == &"walk", kind + ": moving recovery resumes walk")
		foe.view.prepare_attack(0.05)
		foe.position += Vector2(0, 1)
		foe.view._process(DT)
		check(foe.view._anim.is_preparing_attack(), kind + ": moving special preparation remains intact")
		foe.take_damage(100000.0, foe.position + Vector2.UP)
		foe.position += Vector2(0, 1)
		foe.view._process(DT)
		check(foe.view.current_state() == &"death", kind + ": corpse cannot resume walking")
	_sleep_wake()
	# Разомкнуть RefCounted-цикл items↔effects у изолированного тестового мира.
	world.items.effects.items = null
	world.items.effects = null
	world.queue_free()
	await process_frame
	Campaign.reset()
	print("FOE LOCOMOTION: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)
