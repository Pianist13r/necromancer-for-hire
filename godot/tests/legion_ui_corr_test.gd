extends SceneTree
## Интерфейсные правки по партии-переписке 29.09 (slow/ui-corr, DIARY night-0929): экраны поверх
## слоёв мира, понятные подписи и разовая подсказка склепа, брифинг «Болота» про призраков,
## вводный тост под плашкой урока, отклик «узко/коротко» у штриха, что не лёг. Бой не меняется.
## Запуск: --headless --path godot --fixed-fps 60 --script res://tests/legion_ui_corr_test.gd -- --mute

const SAVE := "user://legion_ui_corr_test.cfg"

var w: LegionWorld
var _checks := 0
var _fails := 0
var _toasts: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _on_toast(text: String, _kind: StringName) -> void:
	_toasts.append(text)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	w.toast_posted.connect(_on_toast)
	await _frames(2)
	_test_swamp_brief()
	await _test_crypt_labels()
	await _test_crypt_hint_once()
	await _test_lesson_drops_brief_toast()
	await _test_short_stroke_feedback()
	await _test_overlay_above_world()
	Campaign.reset()
	print("LEGION UI CORR: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# 3. брифинг «Болота» называет призраков и того, кто их бьёт (unit.gd: hits_ghosts у счетовода)
func _test_swamp_brief() -> void:
	var hint := String(LegionWorld.load_map("swamp").get("hint", ""))
	_check(hint.contains("призрак") and hint.contains("Бухгалтерию"),
		"брифинг «Болота» про призраков и Бухгалтерию")
	_check(LegionCfg.UNIT_KINDS[LegionCfg.KIND_CLERK]["hits_ghosts"] == true
		and LegionCfg.UNIT_KINDS[LegionCfg.KIND_LABORER]["hits_ghosts"] == false,
		"брифинг не врёт: призраков строем бьёт только счетовод")


func _start_swamp() -> void:
	Campaign.reset()
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.args["bot"] = "off"
	w.start_map("swamp")


# 2. подписи склепа: что делать, а не «0/8 · 4 с»
func _test_crypt_labels() -> void:
	_start_swamp()
	await _frames(2)
	var c := w.crypts[0]
	var neutral := c.label_text()
	_check(neutral.contains("Ничей") and neutral.contains("8"), "ничей склеп: «%s»" % neutral)
	c.allegiance = LegionCrypt.Owner.ENEMY
	var enemy := c.label_text()
	_check(enemy.contains("Ад") and enemy.contains("займите") and not enemy.contains("/"),
		"склеп Ада: «%s»" % enemy)
	c.capturing = LegionCrypt.Owner.PLAYER
	c.progress = 1.5
	_check(c.label_text().begins_with("Захватываем"), "идёт захват: «%s»" % c.label_text())
	c.capturing = LegionCrypt.Owner.NEUTRAL
	c.progress = 0.0
	c.allegiance = LegionCrypt.Owner.PLAYER
	_check(c.label_text().begins_with("Склеп ваш · штат"), "наш склеп: «%s»" % c.label_text())
	c.contested = true
	_check(c.label_text().contains("Враги"), "оспорен: «%s»" % c.label_text())


# 2. одна подсказка про склеп, один раз за кампанию
func _test_crypt_hint_once() -> void:
	_start_swamp()
	_toasts.clear()
	await _frames(3)
	var early := _toasts.filter(func(t: String) -> bool: return t.begins_with("Склеп:"))
	_check(early.is_empty(), "подсказка склепа не лезет поверх вводного тоста")
	w.now = LegionMapHints.CRYPT_HINT_AT + 0.5
	await _frames(4)
	w.now += 30.0
	await _frames(4)
	var got := _toasts.filter(func(t: String) -> bool: return t.begins_with("Склеп:"))
	_check(got.size() == 1, "подсказка склепа ровно одна плашка (%d)" % got.size())
	_check(got.size() == 1 and String(got[0]).contains("8 бойцов")
		and String(got[0]).contains("Договор"), "в подсказке: сколько бойцов и про договор")
	_check(Campaign.hint_seen(&"crypt_intro"), "флаг подсказки стоит — во втором бою не повторится")


# 4. урок начала боя гасит вводный тост карты — не две плашки стопкой
func _test_lesson_drops_brief_toast() -> void:
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.args["bot"] = "off"
	w.start_map("gatehouse")
	_check(not w.hud.toast_rects().is_empty(), "до урока вводный тост карты стоит")
	w.start_lessons(true)
	await _frames(2)
	_check(w.tutorial != null, "урок начала боя идёт")
	_check(w.hud.toast_rects().is_empty(), "с плашкой урока вводного тоста нет")


# 5. штрих короче минимума: подпись у конца («узко» у стены, «коротко» в чистом поле)
func _test_short_stroke_feedback() -> void:
	_start_swamp()
	await _frames(2)
	var cf := w.contracts
	cf.mana = 100.0
	var n0 := cf.contracts.size()
	cf.begin(Vector2(450, 240))
	cf.extend(Vector2(450, 212))   # до верхней скалы (кромка y=205) — конец у стены
	cf.finish()
	_check(cf.contracts.size() == n0, "штрих в 28 px договора не создал")
	_check(cf._wall_fx.size() == 1 and String(cf._wall_fx[0]["label"]).contains("наискось"),
		"у стены — «узко — ведите наискось»")
	cf._wall_fx.clear()
	cf._wall_ms = -1000000
	cf.begin(Vector2(300, 480))
	cf.extend(Vector2(330, 480))
	cf.finish()
	_check(cf._wall_fx.size() == 1 and String(cf._wall_fx[0]["label"]).begins_with("коротко"),
		"в чистом поле — «коротко»")
	cf._wall_fx.clear()
	cf._wall_ms = -1000000
	cf.begin(Vector2(300, 480))
	cf.extend(Vector2(304, 480))
	cf.finish()
	_check(cf._wall_fx.is_empty(), "случайный щелчок без протяжки молчит")


# 1. экраны вне боя рисуются выше любого слоя мира (кольца склепов z=5, метки, эффекты героя 60)
func _test_overlay_above_world() -> void:
	_check(LegionMain.OVERLAY_Z > 60 and LegionMain.OVERLAY_Z > LegionTutorialMarks.Z
		and LegionMain.OVERLAY_Z > LegionCfg.HINT_Z, "OVERLAY_Z выше слоёв мира")
	var main: Node = (load("res://scenes/legion.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _frames(3)
	var probe := Control.new()
	main.call("_set_screen", probe)
	_check(probe.z_index == LegionMain.OVERLAY_Z, "экран, поставленный через _set_screen, поверх мира")
	main.queue_free()
	await process_frame
