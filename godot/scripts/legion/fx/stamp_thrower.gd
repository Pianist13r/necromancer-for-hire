class_name StampThrower
extends RefCounted
##
## Кто бросает печать (slow/notary-read 29.09). Ночь по переписке: «красное кольцо печати стоит
## над кучей моих бойцов, а сам нотариус, который её ставит, не выделен» — ответ на нотариуса
## (Ку сбивает замах, рогатка по нему) требует его найти. Язык угроз — как у Юриста: у ног
## нотариуса в замахе — кольцо-прогресс цвета угрозы (заполнилось — печать упала; тем же
## кольцом Юрист показывает зачитку), от него к кольцу печати — красный пунктир. Нитей не больше
## LegionCfg.STAMP_LINK_MAX, первыми — ближние к Котлу; кольцо у ног — у каждого.
##
## Чисто вид: бой отсюда ничего не читает, случайных чисел нет (эталоны трасс бота не меняются).
##


## Доля замаха 0..1 (весь SIGNER_WARN): 1 — печать падает; −1 — не замахивается.
static func windup(f: Foe) -> float:
	if not f.alive or f.stamp_t < 0.0:
		return -1.0
	return clampf(1.0 - f.stamp_t / LegionCfg.SIGNER_WARN, 0.0, 1.0)


## Нить: от груди нотариуса к краю кольца печати; пусто — замаха нет или кольцо накрывает его.
static func link(f: Foe) -> PackedVector2Array:
	if windup(f) < 0.0:
		return PackedVector2Array()
	var from := LegionImpactFx.chest(f)
	var to := f.stamp_pos
	var d := from.distance_to(to)
	var r := float(f.def["stamp_r"])
	if d <= r + 4.0:
		return PackedVector2Array()
	return PackedVector2Array([from, to + (from - to) / d * r])


## Кому тянуть нить: не больше STAMP_LINK_MAX нотариусов в замахе, ближние к Котлу первыми
## (дальние — меньше угроза и больше каши на экране). Одно кольцо — одна нить: кучка нотариусов
## бьёт в одну точку, и три пунктира вплотную читались штриховкой (кадр Болота, 12 в замахе);
## нить по кольцу рядом с уже связанным (ближе STAMP_LINK_SPREAD радиусов печати) не тянем.
static func owners(all: Array[Foe], cauldron: Vector2) -> Dictionary:
	var winding: Array[Foe] = []
	for f in all:
		if windup(f) >= 0.0:
			winding.append(f)
	winding.sort_custom(func(a: Foe, b: Foe) -> bool:
		return a.position.distance_squared_to(cauldron) < b.position.distance_squared_to(cauldron))
	var out := {}
	var taken: Array[Vector2] = []
	for f in winding:
		if out.size() >= LegionCfg.STAMP_LINK_MAX:
			break
		var near := float(f.def["stamp_r"]) * LegionCfg.STAMP_LINK_SPREAD
		var dup := false
		for p in taken:
			if p.distance_to(f.stamp_pos) < near:
				dup = true
				break
		if dup:
			continue
		taken.append(f.stamp_pos)
		out[f] = true
	return out


## Кольцо-прогресс у ног (эллипс на земле) и, если linked, пунктир к кольцу печати. Тёмная
## подложка — видно и на лаве, и на светлой дороге.
static func draw(canvas: Node2D, f: Foe, color: Color, linked: bool) -> void:
	var k := windup(f)
	if k < 0.0:
		return
	var ink := Color(0.08, 0.03, 0.02, 0.7)
	if linked:
		var seg := link(f)
		if not seg.is_empty():
			var a := 0.55 + 0.4 * k
			var w := LegionCfg.STAMP_LINK_W
			canvas.draw_dashed_line(seg[0], seg[1], Color(ink, ink.a * a), w + 3.0,
				LegionCfg.LAWYER_DASH, true, true)
			canvas.draw_dashed_line(seg[0], seg[1], Color(color, a), w,
				LegionCfg.LAWYER_DASH, true, true)
	var feet := LegionImpactFx.feet(f)
	var rx := LegionCfg.STAMP_HALO_R * (f.view.scale.x if f.view != null else 1.0)
	var ry := rx * LegionCfg.STAMP_HALO_ASPECT
	var full := PackedVector2Array()
	var arc := PackedVector2Array()
	var n := 24
	for i in n + 1:
		var t := float(i) / float(n)
		var ang := -PI * 0.5 + TAU * t
		var p := feet + Vector2(cos(ang) * rx, sin(ang) * ry)
		full.append(p)
		if t <= k:
			arc.append(p)
	canvas.draw_polyline(full, ink, 4.0, true)
	canvas.draw_polyline(full, Color(color, 0.35), 1.5, true)
	if arc.size() >= 2:
		canvas.draw_polyline(arc, color, 2.5, true)
