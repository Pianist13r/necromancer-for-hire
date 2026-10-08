class_name LegionCauldronView
extends Node2D
## Постоянный свет и опора Котла. Удар двигает только рисунок; частицы уже в LegionFxPool.

const RECOVER := 0.28
const PAD := Vector2(62.0, 21.0)
const GLOW := Color(0.56, 0.95, 0.38)

var world: LegionWorld
var sprite: Sprite2D
var side_index := 0
var clock := 0.0
var hit := 0.0
var base_scale := Vector2.ONE
var base_pos := Vector2.ZERO
var glow: Texture2D


func setup(w: LegionWorld, spr: Sprite2D, side: int) -> void:
	world = w
	sprite = spr
	side_index = side
	base_scale = spr.scale
	base_pos = spr.position
	name = "CauldronLight%d" % side
	process_mode = Node.PROCESS_MODE_PAUSABLE
	glow = CharShadows._make_texture()
	if side == 0:
		w.cauldron_hit.connect(_on_hit)
	# При смене карты рисунок освобождается вместе с Entities.
	spr.tree_exiting.connect(queue_free)


func _on_hit(_amount: float) -> void:
	if hit <= 0.0:
		hit = RECOVER


func _process(dt: float) -> void:
	if not is_instance_valid(sprite) or side_index >= world.sides.size():
		return
	visible = world.phase != LegionWorld.Phase.MENU and not Settings.is_economy_graphics()
	clock += dt
	hit = maxf(0.0, hit - dt)
	var k := hit / RECOVER if visible and Settings.is_screen_shake_enabled() else 0.0
	var squash := sin(k * PI) * 0.055
	sprite.scale = base_scale * Vector2(1.0 + squash, 1.0 - squash)
	sprite.position = base_pos
	if visible:
		queue_redraw()


func _draw() -> void:
	if not is_instance_valid(sprite) or side_index >= world.sides.size():
		return
	var side := world.sides[side_index]
	var hp := clampf(side.cauldron_hp / maxf(side.cauldron_max, 1.0), 0.0, 1.0)
	var breath := 0.5 + 0.5 * sin(clock * lerpf(3.2, 1.6, hp)) \
		if Settings.is_flashes_enabled() else 0.5
	var power := 0.28 + hp * 0.12 + breath * 0.04
	var at := base_pos + Vector2(0, 8)
	draw_texture_rect(glow, Rect2(at - PAD, PAD * 2.0), false, Color(0.04, 0.04, 0.07, 0.9))
	draw_texture_rect(glow, Rect2(at - PAD * 1.5, PAD * 3.0), false, Color(GLOW, power))
	draw_set_transform(at, 0, Vector2(1, 0.34))
	# Плотная опора даёт контакт с землёй даже на светлой дороге; градиент снаружи смягчает край.
	draw_circle(Vector2.ZERO, 51, Color(0.10, 0.16, 0.12, 0.65))
	draw_circle(Vector2.ZERO, 48, Color(GLOW, 0.16))
	draw_arc(Vector2.ZERO, 51, 0, TAU, 64, Color(GLOW, 0.58 + breath * 0.04), 2.0, true)
	draw_arc(Vector2.ZERO, 43, 0, TAU, 48, Color(GLOW, 0.28), 1.2, true)
	# Редкие риски сидят в той же перспективе, что опора, и не кодируют угрозу/способность.
	for i in 12:
		var direction := Vector2.from_angle(float(i) * TAU / 12.0)
		draw_line(direction * 45, direction * 49, Color(GLOW, 0.5), 1.5, true)
	draw_set_transform(Vector2.ZERO)
	# Небольшое свечение чаши не отбеливает дорогу, как полноэкранный bloom.
	var rim := at + Vector2(0, -60)
	draw_texture_rect(glow, Rect2(rim - Vector2(52, 29), Vector2(104, 58)),
		false, Color(GLOW, power))
