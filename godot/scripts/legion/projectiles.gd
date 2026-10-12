class_name LegionProjectiles
extends RefCounted
##
## Снаряды дальних бойцов (v15, пакет f0): счетовод мечет «печати». Отдельно от мира, чтобы
## пакет art мог заменить рисунок, не трогая бой. Снаряд самонаводящийся: промахов нет, урон —
## в момент попадания (цель, павшая раньше, «съедает» выстрел). Тикает и рисует мир (LegionWorld).
##

## Летящие снаряды: {pos, target, dmg, speed, color, from, side}. Цель — Foe; в PvP ещё боец
## другой стороны (Legionnaire) или чужой Котёл (LegionBuilding-Котёл).
var shots: Array[Dictionary] = []


func fire(from: Legionnaire, target: Node2D, dmg: float) -> void:
	shots.append({"side": from.side,
		"pos": from.position + Vector2(0.0, -float(from.spec["body_h"]) * 0.5), "target": target,
		"dmg": dmg, "speed": float(from.spec["projectile_speed"]), "color": from.spec["color"],
		"from": from.position, "sealed": from.projectile_sealed,
	})


func clear() -> void:
	shots.clear()


func tick(dt: float) -> void:
	for i in range(shots.size() - 1, -1, -1):
		var sh := shots[i]
		var t: Node2D = sh["target"]
		if t == null or not is_instance_valid(t) or not _alive(t):
			shots.remove_at(i)
			continue
		var p: Vector2 = sh["pos"]
		# целимся в корпус, а не в ноги: так печать видно летящей над строем
		var aim := t.position + Vector2(0.0, -_body(t) * 0.4)
		var step := float(sh["speed"]) * dt
		if p.distance_to(aim) <= step + LegionCfg.PROJECTILE_HIT_EPS:
			shots.remove_at(i)
			_hit(t, sh, t.position + (p - aim))
			continue
		sh["pos"] = p + (aim - p).normalized() * step


static func _alive(t: Node2D) -> bool:
	if t is Foe:
		return (t as Foe).alive
	if t is Legionnaire:
		return (t as Legionnaire).alive
	return (t as LegionBuilding).world.sides[(t as LegionBuilding).side].alive()


## Высота корпуса цели (куда метить): враг — из его вида, боец — из вида бойца, Котёл — рисунок.
static func _body(t: Node2D) -> float:
	if t is Foe:
		return float((t as Foe).def["body"])
	if t is Legionnaire:
		return float((t as Legionnaire).spec["body_h"])
	return LegionCfg.CAULDRON_DRAW_H * 0.5


## Попадание: урон по попаданию (печать врагу — ещё и замедление); PvP — души и Котёл.
static func _hit(t: Node2D, sh: Dictionary, from: Vector2) -> void:
	var dmg := float(sh["dmg"])
	if t is Foe:
		var f := t as Foe
		f.last_hit_side = int(sh.get("side", 0))
		f.take_damage(dmg, from, true)
		if bool(sh.get("sealed", false)):
			f.apply_seal_slow()
	elif t is Legionnaire:
		var u := t as Legionnaire
		u.last_hit_side = int(sh.get("side", 0))
		u.take_damage(dmg, from)
	else:
		var b := t as LegionBuilding
		b.world.damage_cauldron(dmg, "", b.side)


## Только представление: короткий хвост показывает направление полёта в толпе.
## Исходное состояние, скорость, попадание и урон снаряда не меняются.
func visible_trail(shot: Dictionary) -> PackedVector2Array:
	var at: Vector2 = shot["pos"]
	var origin: Vector2 = shot["from"]
	var distance := at.distance_to(origin)
	if distance < 1.0:
		return PackedVector2Array()
	var direction := (at - origin).normalized()
	var target: Node2D = shot.get("target")
	if is_instance_valid(target):
		var aim := target.position + Vector2(0.0, -_body(target) * 0.4)
		if not at.is_equal_approx(aim):
			direction = (aim - at).normalized()
	return PackedVector2Array([
		at - direction * minf(distance, LegionCfg.PROJECTILE_TRAIL), at])


## Печать с контрастным ядром и хвостом — видна на дороге и поверх фигур.
func draw(ci: CanvasItem) -> void:
	var hs := LegionCfg.PROJECTILE_SIZE
	var rim := Vector2(hs + 1.0, hs + 1.0)
	var body := Vector2(hs, hs)
	for sh in shots:
		var sp: Vector2 = sh["pos"]
		var trail := visible_trail(sh)
		var color: Color = sh["color"]
		if trail.size() == 2:
			ci.draw_line(trail[0], trail[1], Color(0.03, 0.04, 0.07, 0.85), 7.0, true)
			ci.draw_line(trail[0], trail[1], Color(color, 0.85), 4.0, true)
			ci.draw_line(trail[0].lerp(trail[1], 0.4), trail[1],
				color.lightened(0.7), 1.5, true)
		ci.draw_rect(Rect2(sp - rim, rim * 2.0), Color(0.05, 0.03, 0.08, 0.8))
		ci.draw_rect(Rect2(sp - body, body * 2.0), sh["color"])
		ci.draw_rect(Rect2(sp - Vector2(2, 2), Vector2(4, 4)), Color(0.92, 1.0, 0.96))
