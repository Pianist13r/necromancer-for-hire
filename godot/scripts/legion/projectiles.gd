class_name LegionProjectiles
extends RefCounted
##
## Снаряды дальних бойцов (v15, пакет f0): счетовод мечет «печати». Отдельно от мира, чтобы
## пакет art мог заменить рисунок, не трогая бой. Снаряд самонаводящийся: промахов нет, урон —
## в момент попадания (цель, павшая раньше, «съедает» выстрел). Тикает и рисует мир (LegionWorld).
##
## Огневой вал счетоводов (B-494) тоже стреляет настоящими печатями: полоса выбирает цель, печать
## к ней летит, урон и награда удара с разбега — по прилёту. Его печать отличается цветом и
## размером, попадание отмечает короткая вспышка. Обычные печати рисуются и считаются как прежде.
##

## Только вид печати огневого вала. Цель и рассчитанный урон — как у прежнего вала, скорость — как
## у обычной печати; урон теперь наступает позже: по прилёту, а не в момент выбора цели полосой.
const BARRAGE_COLOR := Color(1.0, 0.12, 0.68)
const BARRAGE_SIZE_MULT := 1.35
## Короче обычного хвоста: в залпе шесть полос подряд, длинные хвосты сливаются в линии.
const BARRAGE_TRAIL_MULT := 0.6
## Вспышка попадания печати огневого вала, с. Только вид: бой её не читает, в снимок не идёт.
const IMPACT_LIFE := 0.18
## Радиусы кольца и ядра вспышки, px: (в начале, прирост к концу жизни).
const IMPACT_RING := Vector2(5.0, 11.0)
const IMPACT_CORE := Vector2(2.0, 7.0)
const IMPACT_CORE_COLOR := Color(1.0, 0.82, 0.95)

## Летящие снаряды: {pos, target, dmg, speed, color, from, side, sealed}; у печати огневого вала
## ещё barrage и charged. Цель — Foe; в PvP ещё боец другой стороны (Legionnaire) или чужой
## Котёл (LegionBuilding-Котёл).
var shots: Array[Dictionary] = []
## Вспышки попаданий огневого вала: {pos, life}. Отдельно от shots: снимок и проверки снарядов
## видят только настоящие выстрелы (SnapUnits.SHOTS_SKIP).
var impacts: Array[Dictionary] = []


## barrage — выстрел огневого вала; charged — убийство им считается ударом с разбега
## (on_charge_kill), как у прежнего мгновенного вала. Обычный словарь печати не меняется.
func fire(from: Legionnaire, target: Node2D, dmg: float,
		barrage := false, charged := false) -> void:
	var shot := {"side": from.side,
		"pos": from.position + Vector2(0.0, -float(from.spec["body_h"]) * 0.5), "target": target,
		"dmg": dmg, "speed": float(from.spec["projectile_speed"]), "color": from.spec["color"],
		"from": from.position, "sealed": from.projectile_sealed,
	}
	if barrage:
		shot["color"] = BARRAGE_COLOR
		shot["barrage"] = true
		shot["charged"] = charged
	shots.append(shot)


func clear() -> void:
	shots.clear()
	impacts.clear()


func tick(dt: float) -> void:
	for i in range(impacts.size() - 1, -1, -1):
		var fx := impacts[i]
		fx["life"] = float(fx["life"]) - dt
		if float(fx["life"]) <= 0.0:
			impacts.remove_at(i)
	for i in range(shots.size() - 1, -1, -1):
		var sh := shots[i]
		# Сначала Variant: присвоение освобождённого узла типизированной переменной — ошибка Godot
		# ещё до проверки (B-494, цель освобождена, пока печать летела).
		var target: Variant = sh["target"]
		if not is_instance_valid(target) or not _alive(target as Node2D):
			shots.remove_at(i)
			continue
		var t := target as Node2D
		var p: Vector2 = sh["pos"]
		# целимся в корпус, а не в ноги: так печать видно летящей над строем
		var aim := t.position + Vector2(0.0, -_body(t) * 0.4)
		var step := float(sh["speed"]) * dt
		if p.distance_to(aim) <= step + LegionCfg.PROJECTILE_HIT_EPS:
			# снять до урона: выстрел попадает ровно один раз, что бы ни случилось в _hit
			shots.remove_at(i)
			_hit(t, sh, t.position + (p - aim))
			if bool(sh.get("barrage", false)):
				impacts.append({"pos": aim, "life": IMPACT_LIFE})
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
		var was_alive := f.alive
		f.last_hit_side = int(sh.get("side", 0))
		f.take_damage(dmg, from, true)
		if bool(sh.get("sealed", false)):
			f.apply_seal_slow()
		# огневой вал: убийство его печатью — по-прежнему удар с разбега (души по комбо, артефакты)
		if bool(sh.get("charged", false)) and was_alive and not f.alive:
			f.world.on_charge_kill(f)
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
	var value: Variant = shot.get("target")   # Variant до проверки: цель могла быть освобождена
	if is_instance_valid(value):
		var target := value as Node2D
		var aim := target.position + Vector2(0.0, -_body(target) * 0.4)
		if not at.is_equal_approx(aim):
			direction = (aim - at).normalized()
	var length := LegionCfg.PROJECTILE_TRAIL
	if bool(shot.get("barrage", false)):
		length *= BARRAGE_TRAIL_MULT
	return PackedVector2Array([at - direction * minf(distance, length), at])


## Печать с контрастным ядром и хвостом — видна на дороге и поверх фигур.
func draw(ci: CanvasItem) -> void:
	var hs := LegionCfg.PROJECTILE_SIZE
	var rim := Vector2(hs + 1.0, hs + 1.0)
	var body := Vector2(hs, hs)
	for sh in shots:
		var sp: Vector2 = sh["pos"]
		var trail := visible_trail(sh)
		var color: Color = sh["color"]
		var size_mult := BARRAGE_SIZE_MULT if bool(sh.get("barrage", false)) else 1.0
		if trail.size() == 2:
			ci.draw_line(trail[0], trail[1], Color(0.03, 0.04, 0.07, 0.85), 7.0, true)
			ci.draw_line(trail[0], trail[1], Color(color, 0.85), 4.0, true)
			ci.draw_line(trail[0].lerp(trail[1], 0.4), trail[1],
				color.lightened(0.7), 1.5, true)
		var shot_rim := rim * size_mult
		var shot_body := body * size_mult
		ci.draw_rect(Rect2(sp - shot_rim, shot_rim * 2.0), Color(0.05, 0.03, 0.08, 0.8))
		ci.draw_rect(Rect2(sp - shot_body, shot_body * 2.0), color)
		ci.draw_rect(Rect2(sp - Vector2(2, 2), Vector2(4, 4)), Color(0.92, 1.0, 0.96))
	# Попадание вала: расходящееся кольцо цвета печати поверх цели и гаснущее ядро.
	for fx in impacts:
		var at: Vector2 = fx["pos"]
		var phase := 1.0 - clampf(float(fx["life"]) / IMPACT_LIFE, 0.0, 1.0)
		var fade := 1.0 - phase
		ci.draw_arc(at, IMPACT_RING.x + IMPACT_RING.y * phase, 0.0, TAU, 20,
			Color(BARRAGE_COLOR, fade), 2.5, true)
		ci.draw_arc(at, IMPACT_CORE.x + IMPACT_CORE.y * phase, 0.0, TAU, 20,
			Color(IMPACT_CORE_COLOR, fade), 1.5, true)
