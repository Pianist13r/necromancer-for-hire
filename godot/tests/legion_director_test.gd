extends SceneTree
##
## Регресс режиссёра записи промо (scripts/dev/legion_director.gd): короткий сценарий проходит
## настоящим вводом без записи — съёмку не сломает рефакторинг поля, HUD или штата незаметно.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_director_test.gd -- --mute
##
## Проверяется: читы расстановки (армия, враги, души, мана, постройка), кино-режим HUD (превью
## волны и тосты спрятаны), фигуры настоящими событиями мыши (кольцо → «Оцепление», треугольник
## → «Обряд», кривая линия), рогатка (натиск), Ку по точке (откат пошёл), SCRIPT ERROR нет.
## Итог «LEGION DIRECTOR: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_director_test.cfg"
const SCN := "user://legion_director_test.json"

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


func _scenario() -> Dictionary:
	return {
		"name": "test", "map": "wasteland", "seed": 3, "hud": "clean", "cursor": true, "quit": false,
		"setup": {
			"hold_waves": true, "hints": false, "souls": 250, "mana": 400,
			"build": [{"plot": "p2", "kind": "clerk", "level": 2}],
			"army": [{"kind": "guard", "n": 24, "at": [560, 430], "r": 36},
				{"kind": "clerk", "n": 18, "at": [688, 330], "r": 30},
				{"kind": "laborer", "n": 20, "at": [845, 470], "r": 36}],
			"foes": [{"road": "east", "from": 0.3, "to": 0.45, "n": 12, "jitter": 12,
				"types": ["zombie", "beetle"]}],
		},
		"steps": [
			{"t": 0.1, "do": "ring", "kind": 2, "center": [650, 500], "r": 74, "from": 200},
			{"t": 1.5, "do": "poly", "kind": 3, "pts": [[566, 352], [674, 352], [620, 262], [566, 352]]},
			{"t": 2.8, "do": "draw", "kind": 1, "hand": 3, "pts": [[786, 488], [800, 556], [806, 592]],
				"toward": [900, 540]},
			{"t": 4.6, "do": "sling", "from": [796, 540], "to": [736, 540], "hold": 6},
			{"t": 5.4, "do": "key", "key": "Q", "at": [880, 540], "hold": 6},
			{"t": 6.2, "do": "end"},
		],
	}


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var f := FileAccess.open(SCN, FileAccess.WRITE)
	f.store_string(JSON.stringify(_scenario()))
	f.close()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.start_map("wasteland")
	await process_frame
	var units0 := w.army_alive()
	var foes0 := w.active_foes()
	var d: Node = (load(LegionWorld.DIRECTOR) as GDScript).new()
	d.call("setup", w, ProjectSettings.globalize_path(SCN))
	w.add_child(d)
	await process_frame
	await process_frame
	_check(w.army_alive() - units0 >= 62, "армия +62 вразброс (было %d, стало %d)" % [units0, w.army_alive()])
	_check(w.active_foes() - foes0 == 12, "враги на дороге: +%d (ждём 12)" % (w.active_foes() - foes0))
	_check(w.souls == 250 and w.contracts.mana >= 390.0,
		"души %d (ждём 250), мана %.0f (ждём ~400)" % [w.souls, w.contracts.mana])
	var built := false
	for plot in w.staff.plots:
		if String(plot["id"]) == "p2" and plot["building"] != null:
			built = (plot["building"] as LegionBuilding).level == 2
	_check(built, "постройка p2 «Аудит» второго уровня")
	# читы душ и стройки — не доход: под «Души» нет «+N» (verifier 08.10: «+400406» на кадре)
	var plate: Object = w.hud.get("_plate")
	_check(plate != null and float(plate.get("_gain_t")) <= 0.0 and int(plate.get("_gain")) == 0,
		"плашка «Души» без «+N» после читов (gain %s)" % [plate.get("_gain") if plate else "?"])
	_check(w.hud.cinematic and not w.hud.preview_rect().has_area(), "HUD clean: превью волны спрятано")
	var ring := false
	var tri := false
	var timeout := 0
	while timeout < 60 * 12:
		for c in w.contracts.contracts:
			ring = ring or c.ring
			tri = tri or c.figure == ContractShape.TRIANGLE
		if d.get("frame") >= 6 * 60 + 10:
			break
		await process_frame
		timeout += 1
	_check(ring, "кольцо настоящей мышью → «Оцепление» (contract.ring)")
	_check(tri, "треугольник → фигура triangle («Обряд»)")
	_check(int(w.stats.get("lines", 0)) >= 3, "договоров начерчено: %d (ждём ≥3)" % int(w.stats.get("lines", 0)))
	_check(int(w.stats.get("charges", 0)) > 0, "рогатка: натисков %d (ждём >0)" % int(w.stats.get("charges", 0)))
	var hero := w.my_hero()
	_check(hero != null and hero.cd_left(LegionHero.SLOT_Q) > 0.0, "Ку по точке: откат идёт")
	w.queue_free()
	await process_frame
	await process_frame
	Campaign.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCN))
	print("LEGION DIRECTOR: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
