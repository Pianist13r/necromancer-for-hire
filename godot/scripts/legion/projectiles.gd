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


## Печать — квадрат цвета вида с тёмной каймой: видно, кто стреляет.
func draw(ci: CanvasItem) -> void:
	var hs := LegionCfg.PROJECTILE_SIZE
	var rim := Vector2(hs + 1.0, hs + 1.0)
	var body := Vector2(hs, hs)
	for sh in shots:
		var sp: Vector2 = sh["pos"]
		ci.draw_rect(Rect2(sp - rim, rim * 2.0), Color(0.05, 0.03, 0.08, 0.8))
		ci.draw_rect(Rect2(sp - body, body * 2.0), sh["color"])
