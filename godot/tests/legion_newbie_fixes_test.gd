extends SceneTree
##
## Регресс находок кампании новичка по переписке (сессия 180f1168, 27.09.2026,
## дневник C:\AI\necro\batches\corr\camp-s1\DIARY.md):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_newbie_fixes_test.gd -- --mute
##
## 1) натиск своих не выносит бойцов за край карты (на «Архиве» уносил до 13 за бой), а в
##    середине карты бежит на прежнюю дальность;
## 2) текст поправок «Партнёр по аутстаффу» и «Подъёмные при найме» называет ту прибавку штата,
##    которую поправка даёт на деле (Campaign._legacy_army_mods), а не «+20 бойцов» / «+15»;
## 3) слот «Сбор» закрыт, пока R закрыт (кампания, «Пустырь»), и открыт вне кампании.
## Итог «LEGION NEWBIE FIXES: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_newbie_fixes_test.cfg"
const DT := 1.0 / 60.0

var w: LegionWorld
var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_charge_edge()
	_test_upgrade_texts()
	_test_rally_slot()
	Campaign.reset()
	print("LEGION NEWBIE FIXES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh(map_id: String) -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map(map_id)


## Бег натиска без врагов до конца; вернуть бойца.
func _charge(from: Vector2, dir: Vector2, volley: Dictionary = {}) -> Legionnaire:
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, from)
	u.start_charge(dir, volley)
	for i in roundi(4.0 / DT):
		w.now += DT
		w.grid.rebuild()   # мир не тикает сам (set_process(false)) — сетку целей строим руками
		u.tick(DT)
		if u.state != Legionnaire.State.CHARGE:
			break
	return u


func _test_charge_edge() -> void:
	print("— натиск и край карты")
	_fresh("_plots")
	var m := LegionCfg.CHARGE_EDGE_MARGIN
	var starts := {"вверх": [Vector2(300, 40), Vector2.UP], "вниз": [Vector2(300, 680), Vector2.DOWN],
		"влево": [Vector2(40, 360), Vector2.LEFT]}
	for name: String in starts:
		var p: Vector2 = starts[name][0]
		if not w.terrain.walkable(p):
			_check(false, "стартовая точка %s проходима: %s" % [name, p])
			continue
		var u := _charge(p, starts[name][1])
		var inside := Rect2(Vector2.ONE * (m - 0.01), LegionCfg.WORLD_SIZE - Vector2.ONE * (2.0 * m - 0.02))
		_check(inside.has_point(u.position),
			"натиск %s от края остался на карте: %s" % [name, u.position])
		_check(u.state == Legionnaire.State.FREE, "натиск %s окончен, боец свободен" % name)
	# рогатка (дальность ×1,6) к краю — тоже на карте
	var sling := _charge(Vector2(300, 120), Vector2.UP, w._volley(Vector2.UP, 1.0, false, true))
	_check(sling.position.y >= m - 0.01, "рогатка к верхнему краю остановилась у края: %s" % sling.position)
	# задний ряд у самого края, натиск ВНУТРЬ — бежит на полную дальность, без переноса
	# (verifier 180f1168: стоп по всей полосе у края гасил половину залпа)
	# (B-077: врагов впереди нет — натиск-промах бежит долю CHARGE_MISS_FRAC дальности)
	var free_run := LegionCfg.CHARGE_DIST * LegionCfg.CHARGE_MISS_FRAC
	var back := _charge(Vector2(4, 360), Vector2.RIGHT)
	_check(back.position.x >= 4.0 + free_run - 12.0,
		"у края натиск внутрь бежит, как в середине: x = %.0f" % back.position.x)
	var low := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 8))
	low.start_charge(Vector2.DOWN)
	w.grid.rebuild()
	low.tick(DT)
	_check(low.position.y < 16.0 and low.state == Legionnaire.State.CHARGE,
		"у края натиск внутрь не прыгает на отметку и не гаснет: y = %.1f" % low.position.y)
	# угол: под 45° наружу по x и внутрь по y — выход по x не растёт (третий круг verifier)
	var corner := _charge(Vector2(2, 2), Vector2(-1, 1).normalized())
	_check(corner.position.x >= 2.0 - 0.01,
		"в углу натиск не уводит дальше за край по x: %s" % corner.position)
	var above := _charge(Vector2(10, -100), Vector2(-0.5, 0.87).normalized())
	_check(above.position.x >= 10.0 - 0.01,
		"боец за верхним краем не уходит за левый: %s" % above.position)
	# середина карты: та же дальность, что у края внутрь (без врагов — B-077), край не мешает
	var mid := _charge(Vector2(300, 360), Vector2.RIGHT)
	_check(mid.position.x >= 300.0 + free_run - 12.0,
		"в середине натиск бежит без помех: x = %.0f" % mid.position.x)


func _test_upgrade_texts() -> void:
	print("— тексты поправок про штат")
	for id: String in ["outstaff_partner", "signing_bonus"]:
		Campaign.reset()
		Campaign.add_upgrade(StringName(id))
		var mods := Campaign._legacy_army_mods()
		var add := float(mods.get("cap_mult_laborer", 0.0))
		var text := String(LegionMetaCfg.UPGRADE_POOL[id]["text"])
		var pct := "+%d %%" % roundi(add * 100.0)
		_check(add > 0.0, "%s даёт прибавку штата подрядчиков (%.2f)" % [id, add])
		_check(text.contains(pct), "%s: текст называет %s — «%s»" % [id, pct, text])
		_check(not text.contains("бойцов.") and not text.contains("армия +"),
			"%s: текст не обещает число бойцов" % id)
	Campaign.reset()


func _test_rally_slot() -> void:
	print("— слот «Сбор» закрыт, пока R закрыт")
	var bar := w.hud.get_node_or_null("AbilityBar")
	if bar == null:
		for ch in w.hud.get_children():
			if ch.has_method("rally_locked"):
				bar = ch
	if bar == null:
		for n in w.find_children("*", "", true, false):
			if n.has_method("rally_locked"):
				bar = n
				break
	_check(bar != null, "панель способностей найдена")
	if bar == null:
		return
	# вне кампании открыто всё
	w.in_campaign = false
	_fresh("wasteland")
	_check(not bool(bar.call("rally_locked")), "вне кампании «Сбор» открыт")
	# кампания с чистого сохранения, «Пустырь»: R закрыт до «Проходной»
	Campaign.reset()
	w.in_campaign = true
	_fresh("wasteland")
	_check(not w.rally_unlocked(), "на «Пустыре» кампании R закрыт")
	_check(bool(bar.call("rally_locked")), "и слот «Сбор» рисуется закрытым")
	w.in_campaign = false
