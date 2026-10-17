class_name LegionGuardLesson
extends RefCounted
## B-499: наблюдатель обычного боя. Не создаёт бойцов/врагов, не держит волну и не даёт ресурсов.

const WAIT_TEXT := "Вахтёры идут к линии. Дождитесь строя — щитоносец приближается к Котлу."
const APPROACH_TEXT := "Подновляйте линию ЛКМ. Выпускайте, когда щитоносец подойдёт к щитам."
const PUSH_TEXT := "Щитоносец перед щитами! ПКМ по линии — оттесните его от Котла."
const DONE_TEXT := "Щитоносец оттеснён от Котла. Вы выиграли место перед строем!"
const TURN_TEXT := "Мышь на линию, зажмите {key:aim_contract}: поверните стрелку к щитоносцу."
const REDRAW_TEXT := "Щитоносец за вашим строем. Перечертите Охрану между ним и Котлом."
const FRONT_TEXT := "Вахтёры идут вперёд. Дождитесь оттеснения — пока не чертите новую линию."
const EMPTY_TEXT := "Нет вахтёров у линии. Подведите их «Сбором» или ждите найма ближней Проходной."

var tut: LegionTutorial
var target: Foe
var pushed := 0.0
var first_contact := Vector2.INF
var _text := ""
var _recruit_line: Contract


func _init(owner: LegionTutorial) -> void:
	tut = owner


func center(l: Dictionary) -> Vector2:
	var line: Array = (l.get("mark", {}) as Dictionary).get("line", [])
	if line.size() < 2:
		return Vector2.INF
	return (Vector2(line[0][0], line[0][1]) + Vector2(line[-1][0], line[-1][1])) * 0.5


func candidate(l: Dictionary) -> Foe:
	var at := center(l)
	var best: Foe = null
	for f in tut.world.foes:
		if not f.is_active() or f.type_id != "shield_inspector":
			continue
		# Последний прямой участок дороги: цель уже видна, строй ещё успеет собраться.
		var d := f.position - at
		if d.x < 0.0 or d.x > LessonsCfg.GUARD_APPROACH_R \
				or absf(d.y) > LessonsCfg.GUARD_LANE_HALF:
			continue
		if best == null or f.position.distance_squared_to(tut.world.cauldron_pos) \
				< best.position.distance_squared_to(tut.world.cauldron_pos):
			best = f
	return best


func available() -> bool:
	if _recruit_line == null:
		var i := tut.index_of(&"guard_push")
		if i < 0:
			return false
		var mark: Array = tut.lessons[i]["mark"].get("line", [])
		var pts := PackedVector2Array()
		for point: Array in mark:
			pts.append(Vector2(point[0], point[1]))
		_recruit_line = Contract.new().build(pts, 1, tut.world.terrain.walkable,
			LegionCfg.KIND_GUARD)
	for u in tut.world.units:
		if u.alive and u.kind == LegionCfg.KIND_GUARD and _reachable(u.position):
			return true
	# Ближняя Проходная скоро заполнит пустые штатные места обычным наймом.
	# Полная дальняя постройка не обещает телепортацию уже стоящей охраны.
	for p in tut.world.staff.plots:
		var b := p["building"] as LegionBuilding
		if b != null and b.kind == LegionCfg.KIND_GUARD and not b.frozen \
				and b.alive_count() < b.cap and _reachable(b.entry):
			return true
	return false


func _reachable(at: Vector2) -> bool:
	var radius := float(tut.world.contracts.recruit_r.get(
		LegionCfg.KIND_GUARD, LegionCfg.RECRUIT_R))
	if _recruit_line.live_distance(at) > radius:
		return false
	for post in _recruit_line.posts:
		if at.distance_squared_to(post["pos"]) <= radius * radius \
				and tut.world.terrain.connected(at, post["pos"]):
			return true
	return false


func upcoming(l: Dictionary) -> bool:
	for f in tut.world.foes:
		if f.is_active() and f.type_id == "shield_inspector" and f.position.x >= center(l).x:
			return true
	return false


func present(l: Dictionary) -> bool:
	if not available():
		return false
	if not is_instance_valid(target) or not target.is_active() \
			or target.position.x < center(l).x:
		target = null
	return target != null or candidate(l) != null


func enter() -> void:
	target = candidate(tut.lesson())
	pushed = 0.0
	first_contact = Vector2.INF
	_text = ""


func line() -> Contract:
	var at := center(tut.lesson())
	var best: Contract = null
	for c in tut.world.contracts.contracts:
		if c.kind != LegionCfg.KIND_GUARD or not c.alive():
			continue
		if c.point_at(c.length * 0.5).distance_to(at) > LessonsCfg.GUARD_LINE_R:
			continue
		if best == null or c.posted_posts() > best.posted_posts():
			best = c
	return best


func release_target() -> Dictionary:
	var c := line()
	if c == null:
		return {}
	var best := -1
	var count := 0
	for s in c.seg_count():
		if c.seg_alive(s) and c.seg_manned(s) > count:
			best = s
			count = c.seg_manned(s)
	return {"contract": c, "seg": best} if best >= 0 else {}


func ready() -> bool:
	var hit := release_target()
	if hit.is_empty() or not is_instance_valid(target) or not target.is_active():
		return false
	var c: Contract = hit["contract"]
	var s: int = hit["seg"]
	var delta := target.position - c.seg_center(s)
	var away := (target.position - tut.world.cauldron_pos).normalized()
	return delta.dot(away) > 0.0 and c.seg_dir(s).dot(away) > 0.0 \
		and delta.normalized().dot(c.seg_dir(s)) >= LessonsCfg.GUARD_AIM_DOT \
		and delta.length() <= LegionCfg.GUARD_FRONT_DEFAULT - LessonsCfg.GUARD_PUSH_CREDIT * 2.0


func front_active() -> bool:
	for job in LegionRoleRelease.jobs(tut.world):
		if job["role"] == LegionCfg.KIND_GUARD:
			return true
	return false


func text() -> String:
	if front_active():
		return Controls.text(FRONT_TEXT)
	var c := line()
	if c == null:
		return tut.step_text(tut.step())
	if c.posted_posts() == 0:
		return Controls.text(WAIT_TEXT if _marching(c) else EMPTY_TEXT)
	if is_instance_valid(target) and target.is_active():
		var hit := release_target()
		if not hit.is_empty():
			var s: int = hit["seg"]
			var delta := target.position - c.seg_center(s)
			var away := (target.position - tut.world.cauldron_pos).normalized()
			if delta.dot(away) <= 0.0:
				return Controls.text(REDRAW_TEXT)
			if delta.normalized().dot(c.seg_dir(s)) < LessonsCfg.GUARD_AIM_DOT \
					or c.seg_dir(s).dot(away) <= 0.0:
				return Controls.text(TURN_TEXT)
	return Controls.text(PUSH_TEXT if ready() else APPROACH_TEXT)


func _marching(c: Contract) -> bool:
	for post in c.posts:
		var u: Legionnaire = post["unit"]
		if not post["dead"] and is_instance_valid(u) and u.alive \
				and u.state == Legionnaire.State.MARCH and u.contract == c:
			return true
	return false


func tick(force := false) -> void:
	if not is_instance_valid(target) or not target.is_active():
		enter()
	var current := text()
	if (force or current != _text) and tut._banner != null:
		_text = current
		tut._banner.retext(current)


func observe(job: Dictionary, foe: Node2D, move: Vector2) -> void:
	if not tut.active or tut.step_kind() != &"guard_push" or foe != target \
			or not is_instance_valid(target) or not target.is_active():
		return
	var manual := false
	for value: Variant in job.get("members", []):
		if is_instance_valid(value) and value is Legionnaire:
			var u := value as Legionnaire
			manual = manual or (u.alive and u.kind == LegionCfg.KIND_GUARD \
				and bool(u._volley.get("manual", false)))
	if not manual:
		return
	var away := (target.position - tut.world.cauldron_pos).normalized()
	var gain := move.dot(away)
	if gain <= 0.0:
		return
	if first_contact == Vector2.INF:
		first_contact = target.position - move
	pushed += gain
	var net := target.position.distance_to(tut.world.cauldron_pos) \
		- first_contact.distance_to(tut.world.cauldron_pos)
	if pushed >= LessonsCfg.GUARD_PUSH_CREDIT and net >= LessonsCfg.GUARD_PUSH_CREDIT:
		tut._credit = true


func act() -> void:
	# Новая линия — приказ перенабора: она оборвёт ещё действующий фронт вахтёров.
	if front_active():
		return
	var c := line()
	if c == null:
		var pts := tut.ghost_points()
		tut.world.contracts.set_kind(LegionCfg.KIND_GUARD)
		var made := tut.world.contracts.add_contract(pts, tut.world.contracts.default_side(pts),
			true, LegionCfg.KIND_GUARD)
		if made != null:
			made.set_dir(Vector2.RIGHT)
	elif ready():
		var hit := release_target()
		tut.world.contracts.release(c, int(hit["seg"]))
	else:
		var segs := PackedInt32Array()
		for s in c.seg_count():
			if c.seg_alive(s) and c.seg_left(s) < c.ttl * 0.5:
				segs.append(s)
		if not segs.is_empty():
			tut.world.contracts.refresh(c, segs)
