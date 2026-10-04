extends SceneTree
## Минимальный поведенческий регресс для отказа Ку при нехватке маны.
## Использует только API, которые уже есть в master до economy-mana: hero.cast и cd_left.
## На старом коде каст проходит, наносит урон и включает откат; на новой версии всё остаётся целым.

const SAVE := "user://legion_mana_boundary_test.cfg"
const TARGET := Vector2(760, 120)

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_fails += 1
		print("  FAIL ", message)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world := scene.instantiate() as LegionWorld
	root.add_child(world)
	await process_frame
	world.dev["no_waves"] = "1"
	world.dev["spawn_units"] = "0"
	world.start_map("_gray")
	world.set_process(false)
	world.dev_invuln = false
	world.hero.reset()
	world.contracts.mana = 44.0
	var foe := world.spawn_foe_on_path("zombie", PackedVector2Array([TARGET]), TARGET)
	foe.speed = 0.0
	var hp_before := foe.hp
	var mana_before := world.contracts.mana
	var cast_ok := world.hero.cast(LegionHero.SLOT_Q, TARGET)
	_check(not cast_ok, "Ку при 44 маны отвергнут")
	_check(is_equal_approx(world.contracts.mana, mana_before), "при отказе мана не меняется")
	_check(is_equal_approx(foe.hp, hp_before), "при отказе враг не получает урон")
	_check(is_equal_approx(world.hero.cd_left(LegionHero.SLOT_Q), 0.0),
		"при отказе откат не включается")
	# Положительный контроль исключает ложный успех из-за закрытого навыка/плохой цели.
	world.hero.reset()
	var positive_foe := world.spawn_foe_on_path("zombie", PackedVector2Array([TARGET]), TARGET)
	positive_foe.speed = 0.0
	var positive_hp := positive_foe.hp
	world.contracts.mana = 45.0
	_check(world.hero.cast(LegionHero.SLOT_Q, TARGET), "ровно 45 маны: Ку проходит")
	_check(is_equal_approx(world.contracts.mana, 0.0), "ровно 45 маны: цена списана целиком")
	_check(positive_foe.hp < positive_hp, "при успешном касте цель получает урон")
	_check(world.hero.cd_left(LegionHero.SLOT_Q) > 0.0, "при успешном касте откат включается")
	Campaign.reset()
	print("LEGION MANA BOUNDARY: %d/8 OK" % (8 - _fails))
	quit(1 if _fails > 0 else 0)
