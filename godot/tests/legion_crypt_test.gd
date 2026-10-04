extends SceneTree
## Настоящий мир, ручной шаг без бота/волн. --crypt-shots DIR дополнительно снимает
## постановочные состояния через оконный рендер, не меняя боевые карты ради кадров.

var w: LegionWorld
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _run() -> void:
	w = LegionWorld.new()
	root.add_child(w)
	w.set_process(false)
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.args["bot"] = "off"
	w.start_map("swamp")
	_check(w.crypts.size() == 2, "swamp загружает два склепа")
	for crypt in w.crypts:
		_check(w.terrain.walkable(crypt.position), "склеп на проходимой земле")
		# 28.09: тело склепа — художественный спрайт из каталога процгена; null = заглушка
		_check(crypt.has_artwork(), "у склепа художественный спрайт, не код-заглушка")
	_test_crypt()
	_test_road_recapture()
	_test_boss()
	var argv := OS.get_cmdline_user_args()
	var shot_arg := argv.find("--crypt-shots")
	if shot_arg >= 0 and shot_arg + 1 < argv.size():
		await _shots(argv[shot_arg + 1])
	print("LEGION CRYPT: %d/%d OK" % [_checks - _fails, _checks])
	w.queue_free()
	await process_frame
	quit(1 if _fails else 0)


func _tick_crypt(c: LegionCrypt, seconds: float) -> void:
	# Десятичный шаг с запасом на округление, как в реальном кадровом цикле. v15: места склепа
	# заполняет и возрождает его постройка — штат тикает, как в шаге мира (не на паузе).
	for i in ceili(seconds * 100.0):
		c.tick(0.01)
		if not w.paused:
			w.staff.tick(0.01)


func _crypt_units(c: LegionCrypt) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in w.units:
		if u.alive and u.home == c.building:
			out.append(u)
	return out


func _test_crypt() -> void:
	var c := w.crypts[0]
	# штат склепа — CRYPT_STAFF × темп читаемости STAFF_PACE (D-0927-49: 8 → 6); проверки те же
	var staff := LegionStaff.paced(LegionCfg.CRYPT_STAFF)
	_check(c.building != null and c.building.cap == staff
			and c.building.kind == LegionCfg.KIND_LABORER and w.buildings.has(c.building),
		"склеп — постройка подрядчиков со штатом %d" % staff)
	_tick_crypt(c, 8.1)
	_check(w.army_alive() == 0, "нейтральный склеп не производит бойцов")
	for i in 7:
		w.spawn_unit(LegionCfg.KIND_LABORER, c.position + Vector2(i * 3, 0))
	_tick_crypt(c, 4.1)
	_check(c.allegiance == LegionCrypt.Owner.NEUTRAL, "семерых для захвата мало")
	w.spawn_unit(LegionCfg.KIND_LABORER, c.position)
	_tick_crypt(c, 3.0)
	_check(c.progress > 2.9 and c.allegiance == LegionCrypt.Owner.NEUTRAL,
		"до четырёх секунд виден прогресс, владельца ещё нет")
	var enemy := w.spawn_foe("zombie", "north", {"pos": c.position})
	c.tick(0.01)
	_check(c.progress == 0.0, "враг сбрасывает непрерывный захват")
	enemy.position = Vector2(1200, 360)
	for i in 410:
		c.tick(0.01)
		if c.allegiance == LegionCrypt.Owner.PLAYER:
			break
	_check(c.allegiance == LegionCrypt.Owner.PLAYER, "восемь бойцов за четыре секунды захватили")
	_check(w.army_alive() == 8, "захват сам по себе бойцов не выдаёт")
	_tick_crypt(c, 0.3)
	_check(_crypt_units(c).size() == 1, "штат склепа выходит из двери по одному")
	_tick_crypt(c, 3.0)
	_check(_crypt_units(c).size() == staff and w.army_alive() == 8 + staff,
		"за 3,3 с склеп выдал весь штат %d (армия %d)" % [staff, w.army_alive()])
	_tick_crypt(c, 10.0)
	_check(w.army_alive() == 8 + staff, "сверх штата склеп не производит")
	var mine := _crypt_units(c)
	mine[0].take_damage(1000.0, c.position)
	_tick_crypt(c, LegionCfg.CRYPT_RESPAWN - 0.2)
	_check(_crypt_units(c).size() == staff - 1, "павший ждёт возрождения CRYPT_RESPAWN")
	_tick_crypt(c, 0.3)
	_check(_crypt_units(c).size() == staff, "через CRYPT_RESPAWN место склепа снова занято")
	w.paused = true
	_crypt_units(c)[0].take_damage(1000.0, c.position)
	_tick_crypt(c, 10.0)
	_check(_crypt_units(c).size() == staff - 1, "пауза останавливает склеп")
	w.paused = false
	enemy.position = c.position
	_tick_crypt(c, 10.0)
	_check(_crypt_units(c).size() == staff - 1 and c.allegiance == LegionCrypt.Owner.PLAYER
			and c.building.frozen,
		"спорный склеп не возрождает и не меняет владельца")
	for u in w.units:
		u.position = Vector2(180, 360)
	for i in 2:
		w.spawn_foe("zombie", "north", {"pos": c.position})
	_tick_crypt(c, 4.1)
	_check(c.allegiance == LegionCrypt.Owner.ENEMY, "трое врагов отбивают за четыре секунды")
	var army := w.army_alive()
	var n_foes := w.foes.size()
	_crypt_units(c)[0].take_damage(1000.0, c.position)
	_tick_crypt(c, 10.0)
	_check(w.army_alive() == army - 1 and w.foes.size() == n_foes and c.building.frozen,
		"потерянный склеп заморожен: ни бойцов, ни бесконечной волны")
	for f in w.foes:
		f.position = Vector2(1200, 360)
	for u in w.units:
		u.position = c.position
	_tick_crypt(c, 4.1)
	_check(c.allegiance == LegionCrypt.Owner.PLAYER, "склеп можно захватить повторно")
	# было 10 с при CRYPT_RESPAWN 8; темп читаемости D-0927-49 растянул возрождение (×1,5) —
	# ждём интервал склепа с тем же запасом 2 с, проверка та же
	_tick_crypt(c, LegionCfg.CRYPT_RESPAWN + 2.0)
	_check(_crypt_units(c).size() == staff, "после возврата места склепа снова заполняются")
	w.start_map("boss")
	_check(w.crypts.is_empty(), "смена карты очищает склепы")


func _posted(at: Vector2) -> Legionnaire:
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, at)
	u.post = {"pos": at, "normal": Vector2.RIGHT, "unit": u}
	u.state = Legionnaire.State.POSTED
	return u


func _test_road_recapture() -> void:
	w.start_map("swamp")
	# Реальные участки обеих дорог и обычная скорость: отбивание должно работать
	# на карте без искусственной остановки врагов у склепа.
	for index in w.crypts.size():
		var c := w.crypts[index]
		c.allegiance = LegionCrypt.Owner.PLAYER
		var road := "north" if index == 0 else "south"
		var path := w.road_path(road)
		var nearest_segment := 0
		var distance := INF
		# Начинаем перед склепом, а не с номера точки прежней раскладки карты.
		for segment in range(path.size() - 1):
			var projected := Geometry2D.get_closest_point_to_segment(
				c.position, path[segment], path[segment + 1])
			if c.position.distance_to(projected) < distance:
				distance = c.position.distance_to(projected)
				nearest_segment = segment
		var route := path.slice(nearest_segment)
		for i in 3:
			w.spawn_foe_on_path("zombie", route, route[0] + Vector2(i * 12, 0))
	for i in 1400:
		w.grid.rebuild()
		for f in w.foes:
			f.tick(0.01)
		w.grid.separate()
		for c in w.crypts:
			# Прирост отдельно уже проверен; гарнизон здесь намеренно отсутствует.
			c.tick(0.01)
		for u in w.units:
			u.position = Vector2(180, 360)
	for c in w.crypts:
		_check(c.allegiance == LegionCrypt.Owner.ENEMY, "проходящая тройка отбивает склеп на дороге")
	w.start_map("boss")


func _test_boss() -> void:
	w.terrain = LegionTerrain.new().setup({})
	w.dev_invuln = true
	var u := _posted(Vector2(600, 300))
	var p := u.post
	var boss := w.spawn_foe_on_path("boss", PackedVector2Array([Vector2(200, 300)]),
		Vector2(740, 300))
	_check(boss.hp == 1500.0, "у Прораба 1500 HP")
	w.grid.rebuild()
	var wall := {"rocks": [[[650, 250], [680, 250], [680, 350], [650, 350]]]}
	w.terrain = LegionTerrain.new().setup(wall)
	boss._tick_boss(6.1)
	_check(boss.ram_t < 0.0, "босс не выбирает цель за скалой")
	w.terrain = LegionTerrain.new().setup({})
	boss.tick(0.01)
	_check(boss.ram_t > 0.0 and boss.position == Vector2(740, 300),
		"босс ревёт до контакта и останавливается")
	var locked := boss.ram_pos
	u.position = Vector2(900, 300)
	boss.tick(0.5)
	_check(boss.ram_pos == locked and boss.ram_t > 0.0,
		"точка тарана не преследует выпущенного бойца")
	boss.tick(1.2)
	boss.tick(0.3)
	_check(u.position == Vector2(900, 300), "из круга удара можно уйти")
	u.position = boss.position - Vector2(100, 0)
	w.dev_invuln = false
	# Здесь проверяется отбрасывание выжившего, а не порог убийства базового подрядчика.
	u.hp = LegionCfg.UNIT_HP + float(boss.def["ram_dmg"])
	var hp_before := u.hp
	u.post = p
	u.state = Legionnaire.State.POSTED
	p["pos"] = u.position
	w.grid.rebuild()
	boss.tick(6.1)
	var before := u.position
	boss.tick(1.7)
	boss.tick(0.3)
	_check(u.state == Legionnaire.State.FREE and p["unit"] == null,
		"таран освобождает место и ломает состояние строя")
	_check(is_equal_approx(u.hp, hp_before - float(boss.def["ram_dmg"]) * LegionCfg.FRONT_ARMOR),
		"таран наносит урон с учётом фронтальной брони")
	_check(u.position.distance_to(before) > 60.0 and w.terrain.walkable(u.position),
		"живой боец отброшен на проходимую землю")
	_check(w.foes.size() >= 4, "Прораб вызвал свиту")
	var fatal := _posted(boss.position - Vector2(100, 0))
	var fatal_post := fatal.post
	boss.ram_pos = fatal.position
	boss._ram_start = boss.position
	boss._ram_hit()
	_check(not fatal.alive and fatal_post["unit"] == null,
		"не ушедший базовый подрядчик погибает от тарана и освобождает место")
	w.terrain = LegionTerrain.new().setup(wall)
	var pushed := boss._safe_push(Vector2(620, 300), Vector2(710, 300))
	# край скалы 650; непроходимость — по центрам клеток (v19: 16 px), до полуклетки внутрь
	_check(pushed.x < 650.0 + LegionCfg.CELL * 0.5 and w.terrain.walkable(pushed),
		"толчок не перескакивает скалу (x = %.0f)" % pushed.x)
	w.dev_invuln = false
	boss.ram_t = LegionCfg.BOSS_RAM_WARN
	boss.take_damage(2000, u.position)
	_check(boss.ram_t < 0.0 and not boss.alive, "смерть отменяет предупреждённый таран")


func _shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	w.start_map("swamp")
	var c := w.crypts[0]
	for i in 8:
		_posted(c.position + Vector2(-45 + (i % 4) * 30, 25 + (i / 4) * 18))
	_tick_crypt(c, 2.2)
	await _save_shot(dir.path_join("crypt-capture.png"))
	_tick_crypt(c, 2.0)
	_check(c.allegiance == LegionCrypt.Owner.PLAYER, "кадр «наш склеп» снят после захвата")
	await _save_shot(dir.path_join("crypt-owned.png"))
	for u in w.units:
		u.position = Vector2(180, 360)
	for i in 3:
		w.spawn_foe("zombie", "north", {"pos": c.position})
	_tick_crypt(c, LegionCfg.CRYPT_CAPTURE_TIME + 0.2)
	_check(c.allegiance == LegionCrypt.Owner.ENEMY, "кадр «чужой склеп» снят после отбития")
	await _save_shot(dir.path_join("crypt-enemy.png"))
	w.start_map("boss")
	for i in 16:
		_posted(Vector2(730 + (i % 2) * 18, 210 + (i / 2) * 18))
	var boss := w.spawn_foe_on_path("boss", PackedVector2Array([Vector2(470, 315)]),
		Vector2(875, 265))
	w.grid.rebuild()
	boss.tick(6.1)
	boss.tick(0.35)
	_check(boss.ram_t > 0.0, "кадр босса снят в фазе рёва")
	await _save_shot(dir.path_join("boss-roar.png"))


func _save_shot(path: String) -> void:
	w._fx.queue_redraw()
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(path)
	_check(error == OK, "кадр " + path)
