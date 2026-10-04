class_name PgTurns
extends RefCounted
##
## Повороты дороги для У-7 (BOOK §7: «повороты ≥ 60° разделены отрезком ≥ 80 px») и колен дороги
## (мимик, BOOK §4.1). По замыслу координатора (verifier-3, 27.09): поворот ищется по изменению
## направления вдоль оси со сглаженной касательной, а не по отдельным вершинам ломаной. Иначе дуга
## из шагов, «округление до целых» и крошечные встречные изломы (−0,02°) то теряли поворот, то
## дробили его.
##
## Устройство. Ломаная поворачивает только в вершинах, поэтому изломы берутся точно в вершинах
## (там и граница поворота — прямая меж двумя углами меряется от вершины до вершины, g = 79 и 80 px
## различаются). Знак излома — не свой, а сглаженный: изменение направления хорды ±TANGENT px на
## окне ±TANGENT вокруг вершины. На дуге, округлённой до целых, сырые изломы скачут ±45°, а
## сглаженный знак везде один — дуга остаётся одной зоной; на S-изгибе знак меняется.
## Зона поворота — изломы ≥ BEND_EPS одного сглаженного знака, идущие ближе ZONE_BRIDGE px; её
## поворот — чистая сумма изломов со знаком, длина — от первой вершины до последней.
##
## Отступления от чисел координатора (25° на окне 32 px, шпилька < 80 px) — его же таблица случаев
## с ними не сходится: дуга R100 на окне 32 px поворачивает на 18°, R300 — на 6° (обе по таблице
## повороты), а шпилька R40 длиной 126 px по таблице — нарушение.
##

## Излом меньше этого — прямая: −0,02° между шагами угла — не поворот.
const BEND_EPS := deg_to_rad(0.1)
## Изломы одного знака ближе этого — одна зона: дуга с хордой до 31 px (R300 по 6°) — один
## поворот; два угла по 90° через 32 px и ближе — тоже одна зона (разворот, см. HAIRPIN).
const ZONE_BRIDGE := 32.0
## Полухорда касательной и полуокно сглаженного знака, px.
const TANGENT := 8.0
## Сглаженный поворот меньше этого — знак не ясен, берётся знак самого излома.
const SIGN_EPS := deg_to_rad(1.0)
## Шпилька: зона с чистым поворотом ≥ 150° короче этого — разворот на месте. Дуга R100 на 180°
## (314 px) и 20 изломов по 9° через 8 px (160 px) годны; шпилька R40 (126 px) — нет.
const HAIRPIN_TURN := deg_to_rad(150.0)
const HAIRPIN_LEN := 150.0


## Зоны поворота: [[px начала, px конца, поворот со знаком (рад), точка начала, точки изломов,
## знак]].
static func zones(path: PackedVector2Array) -> Array:
	var length := LegionMapChecks.path_length(path)
	var out := []
	var base := 0.0
	for i in range(1, path.size() - 1):
		base += path[i - 1].distance_to(path[i])
		var a := path[i] - path[i - 1]
		var b := path[i + 1] - path[i]
		if a.length() < 1e-6 or b.length() < 1e-6:
			continue
		var bend := a.angle_to(b)
		if absf(bend) < BEND_EPS:
			continue
		var smooth := angle_difference(_heading(path, base - TANGENT, length),
			_heading(path, base + TANGENT, length))
		var sign := signf(smooth) if absf(smooth) >= SIGN_EPS else signf(bend)
		if not out.is_empty() and base - float(out[-1][1]) <= ZONE_BRIDGE \
				and sign == float(out[-1][5]):
			out[-1][1] = base
			out[-1][2] = float(out[-1][2]) + bend
			var zp: PackedVector2Array = out[-1][4]
			zp.append(path[i])
			out[-1][4] = zp
		else:
			out.append([base, base, bend, path[i], PackedVector2Array([path[i]]), sign])
	return out


## Первое нарушение У-7 на дороге: {"what": строка, "at": точка} или {}. Нарушение — два крутых
## поворота (≥ sharp) с прямой меж ними короче gap_min (S и U — оба), или шпилька.
static func problem(path: PackedVector2Array, sharp: float, gap_min: float) -> Dictionary:
	var last_end := -INF
	for z: Array in zones(path):
		var turn := absf(float(z[2]))
		if turn >= HAIRPIN_TURN and float(z[1]) - float(z[0]) < HAIRPIN_LEN:
			return {"what": "разворот шпилькой на %.0f° за %.0f px" % [rad_to_deg(turn),
				float(z[1]) - float(z[0])], "at": z[3]}
		if turn < sharp:
			continue
		if float(z[0]) - last_end < gap_min:
			return {"what": "два поворота ≥ %.0f° ближе %.0f px друг к другу" % [
				rad_to_deg(sharp), gap_min], "at": z[3]}
		last_end = float(z[1])
	return {}


## Направление хорды оси от s − TANGENT до s + TANGENT (концы прижаты к дороге).
static func _heading(path: PackedVector2Array, s: float, length: float) -> float:
	var p0 := LegionMapChecks.point_at(path, clampf(s - TANGENT, 0.0, length))
	var p1 := LegionMapChecks.point_at(path, clampf(s + TANGENT, 0.0, length))
	return (p1 - p0).angle()
