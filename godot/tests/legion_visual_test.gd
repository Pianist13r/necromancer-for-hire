extends SceneTree
## Визуальный регресс: сохраняемые настройки, бюджет FX, слой мира, 300 врагов.

var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _run() -> void:
	Settings.use_dev_save("user://visual_test.cfg")
	Settings._cfg = ConfigFile.new()
	var settings := Settings.new()
	for key: String in ["screen_shake", "flashes", "world_grade"]:
		var getter := "is_" + key + "_enabled"
		var setter := "set_" + key
		var implemented := settings.has_method(getter) and settings.has_method(setter)
		check(implemented, "API настройки " + key)
		if implemented:
			check(bool(settings.call(getter)), key + " включено по умолчанию")
			settings.call(setter, false)
			Settings._cfg = null
			check(not bool(settings.call(getter)), key + " переживает перечитывание файла")
			settings.call(setter, true)
	var screen := SettingsScreen.new()
	root.add_child(screen)
	await process_frame
	for key in ["ScreenShake", "Flashes", "WorldGrade"]:
		check(screen.find_child(key, true, false) is CheckBox, "галочка " + key)
	screen.queue_free()
	var pool := LegionFxPool.new(null, false, false)
	for i in 500:
		pool.add(i, 0, 0.1, 4, 0, 1, Color.WHITE)
	var capacity := pool.px.size()
	pool.step(0.2)
	check(pool.n == 0, "пул освобождает истёкшие частицы")
	for i in 500:
		pool.add(i, 0, 0.1, 4, 0, 1, Color.WHITE)
	check(pool.px.size() == capacity, "пул повторно использует ёмкость")
	Campaign.set_save_path("user://visual_test.cfg")
	var w := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	w.set_process(false)
	check(w.entities.get_node_or_null("CauldronLight0") != null,
		"свет Котла внутри Entities, порядок слоёв мира сохранён")
	var post := w.get_node_or_null("WorldGrade") as CanvasLayer
	check(post != null, "виньетка создана")
	if post != null and settings.has_method("set_world_grade"):
		check(post.layer > 0 and post.layer < w.hud.layer, "обработка ниже HUD")
		settings.call("set_world_grade", false)
		await process_frame
		check(not (post.get_child(0) as CanvasItem).is_visible_in_tree(), "виньетка выключается")
		settings.call("set_world_grade", true)
		await process_frame
		check((post.get_child(0) as CanvasItem).is_visible_in_tree(), "виньетка включается")
		post.hide()
		await process_frame
		check(not post.visible, "постобработка уважает скрытие слоя модальным экраном")
		post.show()
	for i in 300:
		w._spawn_bench_foe(i)
	for i in 3:
		w._step(1.0 / 60.0)
		await process_frame
	check(w.active_foes() == 300, "300 врагов пережили шаг мира и кадр")
	w.foes[0].make_elite()
	var crown := false
	for node in w.foes[0].get_children():
		crown = crown or node is LegionEliteMark
	check(crown, "элитный сохраняет корону и ореол в толпе")
	var friendly := w.spawn_unit(LegionCfg.KIND_CLERK, Vector2(400, 400))
	check(friendly.view.look_material() != w.foes[1].view.look_material(),
		"свои и враги имеют разные общие контуры")
	check(w.foes[1].view.look_material() == w.foes[2].view.look_material(),
		"враги делят один материал вместо 300 копий")
	await _accessibility(w)
	await _flash_regressions(w)
	Settings.set_economy_graphics(true)
	await process_frame
	if post != null:
		check(not (post.get_child(0) as CanvasItem).is_visible_in_tree(),
			"экономная отключает постобработку")
	Settings.set_economy_graphics(false)
	var clips: Dictionary = CfgAnim.CLERK_CLIPS["attack"]
	for dir: String in ["e", "se", "s", "ne", "n"]:
		check(String(clips.directions[dir].dir).ends_with("attack_" + dir),
			"счетовод использует актуальный мастер " + dir)
	w.queue_free()
	await process_frame
	print("LEGION VISUAL: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _accessibility(w: LegionWorld) -> void:
	var test_cam := Camera2D.new()
	w.add_child(test_cam)
	test_cam.make_current()
	await process_frame
	Settings.set_flashes(false)
	Settings.set_screen_shake(false)
	var actor := w.foes[0].view
	actor.flash()
	check(float(actor.get("_flash_t")) == 0, "вспышка персонажа выключена")
	check(is_equal_approx(Juice.flash_alpha(0.1), Juice.flash_alpha(1.0)),
		"при выключенных вспышках линия не мигает")
	check(is_equal_approx(Juice.flash_alpha(1.0), 1.0),
		"выключенные вспышки не затемняют линии договора")
	var line := Contract.new().build(PackedVector2Array([Vector2(300, 300), Vector2(500, 300)]), 1)
	var renderer := ContractRenderer.new(w.contracts)
	check(is_equal_approx(renderer._alpha(line, 0), 1.0), "свежий участок остаётся ярким")
	line.seg_age[0] = line.ttl - 0.2
	check(is_equal_approx(renderer._alpha(line, 0), 1.0), "тающий участок остаётся ярким")
	Juice.flash(w)
	Juice.shake(w, 20, 1)
	check(JuiceeEffect.accessibility.no_flash, "флаг вспышек Juicee подключён")
	check(JuiceeEffect.accessibility.no_screenshake, "флаг тряски Juicee подключён")
	var fx := w.get_node("LegionFx") as LegionFx
	var glow_count := fx._glow_g.n
	var dust_count := fx._dust.n
	fx.emit_breach(Vector2(500, 300))
	check(fx._glow_g.n == glow_count, "прорыв без оранжевой вспышки при выключении")
	check(fx._dust.n > dust_count, "пыль прорыва сохраняет отклик события")
	fx.impact._screen_t = 0.0
	var chain: Array[Foe] = [w.foes[0]]
	fx.impact.bolt_chain(w.cauldron_pos, chain)
	check(fx.impact._screen_t == 0.0, "молния не включает вспышку экрана")
	Settings.set_flashes(true)
	Settings.set_screen_shake(true)
	if root.has_meta(&"visual_flash"):
		root.remove_meta(&"visual_flash")
	check(Juice.screen_flash_allowed(w), "первая вспышка разрешена")
	check(not Juice.screen_flash_allowed(w), "серия вспышек ограничена")
	check(Juice.screen_flash_allowed(w, &"visual_threat", 0),
		"виньетка угрозы независима от занятого лимита молнии")
	root.set_meta(&"visual_flash", Time.get_ticks_msec() - 501)
	check(Juice.screen_flash_allowed(w), "после 500 мс вспышка снова доступна")
	if root.has_meta(&"visual_shake"):
		root.remove_meta(&"visual_shake")
	Juice.shake(w, 20, 1)
	check(not test_cam.offset.is_zero_approx(), "тест возврата камеры действительно запускает тряску")
	var active := JuiceeEffect._alive.size()
	Juice.shake(w, 20, 1)
	check(JuiceeEffect._alive.size() == active, "повторный удар не суммирует тряски")
	Settings.set_screen_shake(false)
	await process_frame
	var cam := w.get_viewport().get_camera_2d()
	check(cam != null and cam.offset.is_zero_approx(), "выключение возвращает камеру")
	Settings.set_screen_shake(true)
	test_cam.queue_free()
	await process_frame


func _flash_regressions(w: LegionWorld) -> void:
	Settings.set_flashes(true)
	var a := w.foes[1].view
	var b := w.foes[2].view
	a.flash()
	b.flash()
	check(a._flash_t > 0.0 and b._flash_t > 0.0, "оба врага вспыхивают в одном кадре")
	for i in 4:
		await process_frame
	w.foes[3].view.flash()
	check(w.foes[3].view._flash_t > 0.0, "следующий прыжок молнии не теряет вспышку")
	var audio := LegionAudio.new()
	root.add_child(audio)
	audio.setup_standalone(true, false)
	audio.attach_world(w)
	# HUD уже подписан; даже занятый бюджет молнии не должен съесть важный удар.
	root.set_meta(&"visual_flash", Time.get_ticks_msec())
	w.cauldron_hit.emit(20.0)
	var red := 1.0
	var green := 1.0
	for i in 16:
		await process_frame
		red = maxf(red, w.modulate.r)
		green = minf(green, w.modulate.g)
	print("FLASH HIT: max_r=%.3f min_g=%.3f" % [red, green])
	check(red > 1.5 and green < 0.85, "удар Котла красный и яркий при включённых вспышках")
	var foe := w.foes[4]
	var old_type := foe.type_id
	foe.type_id = "boss"
	root.set_meta(&"visual_flash", Time.get_ticks_msec())
	w.foe_died.emit(foe)
	foe.type_id = old_type
	var white := 3.0
	for i in 22:
		await process_frame
		white = maxf(white, w.modulate.r + w.modulate.g + w.modulate.b)
	print("FLASH BOSS: max_sum=%.3f" % white)
	check(white > 5.0, "смерть босса даёт белую вспышку после удара Котла")
	Juice.flash(w, Color.WHITE, 0.3)
	for i in 3:
		await process_frame
	check(w.modulate.r > 1.0, "вспышка активна перед выключением")
	Settings.set_flashes(false)
	check(w.modulate.is_equal_approx(Color.WHITE), "выключение сразу возвращает цвет мира")
	w.cauldron_hit.emit(20.0)
	for i in 4:
		await process_frame
	check(w.modulate.is_equal_approx(Color.WHITE), "выключенные вспышки подавляют удар Котла")
	Settings.set_flashes(true)
	audio.queue_free()
	await process_frame
