extends SceneTree
##
## Самопроверка правил ядра «По истечении договора» без окна:
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_core_test.gd -- --mute
##
## Итог «LEGION CORE: N/N OK»; код выхода 1, если что-то упало. Мир поднимается настоящий
## (scenes/legion_world.tscn, карта _gray, бот выключен), проверки идут через публичный API.
## Пакет flow (v13): legion.tscn стал LegionMain (экраны кампании), сам мир как отдельная
## сцена переехал в legion_world.tscn — тест адаптирован минимально (только путь загрузки).
##

const ROCK_Y := 420.0   ## по этой высоте штрих на карте _gray пересекает скалу 870..1000

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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _line(a: Vector2, b: Vector2, step := 8.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in n + 1:
		pts.append(a.lerp(b, float(i) / n))
	return pts


func _run() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	_check(w.phase == LegionWorld.Phase.BATTLE and w.map_id == "_gray", "мир стартует в бой на _gray")
	_check(not Campaign.uses_real_save(),
		"мир без кампании пишет в своё сохранение, не в user://legion.cfg владельца")
	# маны вдоволь и никаких смертей: проверяем правила, а не баланс
	w.dev_invuln = true
	_test_capacity()
	_test_refresh()
	await _test_melt_to_charge()
	await _test_wall()
	_test_rock_clip()
	_test_astar()
	_test_mouse_input()
	_test_pause_restart()
	_test_effective_resources()
	_test_boss_siege()
	await _test_release_feedback()
	print("LEGION CORE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_capacity() -> void:
	var c := Contract.new().build(_line(Vector2(100, 100), Vector2(460, 100)), 1)
	_check(c.posts.size() == 40, "линия 360 px — 40 мест (2·⌊360/18⌋), есть %d" % c.posts.size())
	_check(c.seg_count() == 6, "участки по 64 px: 360 px — 6 участков")
	var front: Vector2 = c.posts[0]["pos"] - Vector2(c.posts[0]["pos"].x, 100)
	var n: Vector2 = c.posts[0]["normal"]
	_check(front.dot(n) > 0.0, "ряд 0 стоит по стрелке (передний)")
	# конвенция карт MAPS: рубеж a→b на юг с release = +1 смотрит на восток
	var east := Contract.new().build(_line(Vector2(500, 100), Vector2(500, 300)), 1)
	_check(east.normal_at(0).x > 0.9, "release +1 при a→b на юг — стрелка на восток")


func _test_refresh() -> void:
	var f := w.contracts
	f.mana = LegionCfg.MANA_MAX
	var c := f.add_contract(_line(Vector2(300, 620), Vector2(300, 700)), 1, false)
	_check(c != null, "договор ставится по API бота")
	if c == null:
		return
	c.seg_age[0] = 5.0
	var along := _line(Vector2(304, 625), Vector2(304, 690), 6.0)
	var across := _line(Vector2(260, 660), Vector2(345, 660), 6.0)
	_check(not f.match_refresh(along).is_empty(), "штрих ВДОЛЬ договора распознан как подрисовка")
	_check(f.match_refresh(across).is_empty(), "штрих ПОПЕРЁК — не подрисовка")
	# человеческий ввод: подрисовка продлевает участок и не создаёт линию
	var before := f.contracts.size()
	_stroke(along)
	_check(f.contracts.size() == before and c.seg_age[0] < 0.5,
		"подрисовка обнулила возраст, линий не прибавилось")
	_stroke(across)
	_check(f.contracts.size() == before + 1, "штрих поперёк создал новый договор")


func _stroke(pts: PackedVector2Array) -> void:
	var f := w.contracts
	f.mana = LegionCfg.MANA_MAX
	f.begin(pts[0])
	for i in range(1, pts.size()):
		f.extend(pts[i])
	f.finish()


func _man(c: Contract) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if p["unit"] != null or p["dead"]:
			continue
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _test_melt_to_charge() -> void:
	var f := w.contracts
	f.mana = LegionCfg.MANA_MAX
	var c := f.add_contract(_line(Vector2(420, 420), Vector2(420, 560)), 1, false)
	var squad := _man(c)
	var seg0: Array[Legionnaire] = []
	for u in squad:
		if int(u.post["seg"]) == 0:
			seg0.append(u)
	_check(not seg0.is_empty(), "на участке 0 стоят бойцы (%d)" % seg0.size())
	var charges0 := int(w.stats["charges"])
	c.seg_age[0] = c.ttl - 0.02
	await _frames(3)
	var all_charge := true
	for u in seg0:
		all_charge = all_charge and u.state == Legionnaire.State.CHARGE
	_check(all_charge, "участок растаял — его бойцы в НАТИСКЕ")
	_check(int(w.stats["releases_melt"]) >= 1 and int(w.stats["charges"]) - charges0 == seg0.size(),
		"таяние посчитано в trace (releases_melt, charges)")
	var still := 0
	for u in squad:
		if int(u.post.get("seg", -1)) == 1 and u.state == Legionnaire.State.POSTED:
			still += 1
	_check(still > 0, "соседний участок держит строй — участки тают независимо")
	# ПКМ по участку — досрочный натиск
	var hit := f.pick_segment(c.seg_center(1))
	_check(not hit.is_empty() and int(hit["seg"]) == 1, "ПКМ находит участок под курсором")
	f.release(c, 1)
	_check(not c.seg_alive(1) and int(w.stats["releases_manual"]) >= 1, "ПКМ расторгает участок")


## Строй непроходим для зомби и проходим для призрака.
func _test_wall() -> void:
	var f := w.contracts
	f.mana = LegionCfg.MANA_MAX
	var c := f.add_contract(_line(Vector2(1000, 100), Vector2(1000, 300)), 1, false)
	_man(c)
	await _frames(2)
	var z := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(900, 170)]), Vector2(1080, 170))
	var g := w.spawn_foe_on_path("ghost", PackedVector2Array([Vector2(900, 230)]), Vector2(1080, 230))
	await _frames(300)
	_check(z.alive and z.position.x > 1000.0, "зомби упёрся в строй (x = %.0f)" % z.position.x)
	_check(g.alive and g.position.x < 995.0, "призрак прошёл сквозь строй (x = %.0f)" % g.position.x)


func _test_rock_clip() -> void:
	var a := Vector2(800, ROCK_Y)
	var b := Vector2(1100, ROCK_Y)
	var clear := w.terrain.segment_clear(a, b)
	_check(clear.x < 875.0 and clear.x > 840.0 and not w.terrain.is_rock(clear),
		"отрезок обрезан у контура скалы (x = %.0f)" % clear.x)
	var f := w.contracts
	f.mana = LegionCfg.MANA_MAX
	f.begin(a)
	for i in range(1, 31):
		f.extend(a.lerp(b, i / 30.0))
	var ok := f.has_draft() and f._draft[f._draft.size() - 1].x < 875.0
	_check(ok, "штрих мыши не проходит сквозь скалу")
	f.cancel()


func _mouse_button(at: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = at
	ev.button_index = button
	ev.pressed = pressed
	w.contracts._unhandled_input(ev)


## Ввод человека через события: ЛКМ чертит, Tab больше не меняет стрелку, ПКМ отпускает участок.
func _test_mouse_input() -> void:
	var f := w.contracts
	# освобождаем место под лимит договоров: проверяем ввод, а не лимит
	for c in f.contracts.duplicate():
		for s in c.seg_count():
			f.release(c, s)
	f.tick(0.0, w.now)
	f.mana = LegionCfg.MANA_MAX
	var a := Vector2(260, 150)
	var b := Vector2(260, 290)
	_mouse_button(a, MOUSE_BUTTON_LEFT, true)
	for i in range(1, 21):
		var mv := InputEventMouseMotion.new()
		mv.position = a.lerp(b, i / 20.0)
		f._unhandled_input(mv)
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	f._unhandled_input(tab)
	_mouse_button(b, MOUSE_BUTTON_LEFT, false)
	_check(f.contracts.size() == 1, "ЛКМ-штрих создал договор")
	if f.contracts.is_empty():
		return
	var c: Contract = f.contracts[0]
	# v15: Tab не влияет на стрелку; произвольный угол Пробелом проверяет core_v15_test.
	_check(c.normal_at(0).x > 0.9, "Tab не меняет стрелку черновика (от Котла)")
	# v17: щелчок ПКМ = нажать и отпустить на месте (рогатка ждёт отпускания, щелчок — старый роспуск)
	_mouse_button(c.seg_center(0), MOUSE_BUTTON_RIGHT, true)
	_mouse_button(c.seg_center(0), MOUSE_BUTTON_RIGHT, false)
	_check(not c.seg_alive(0), "ПКМ по участку — досрочный выпуск")


## Esc — пауза и обратно; «Заново» (restart) — карта с чистого листа. С v18 (26.09.2026) R —
## «Сбор», а не перезапуск: промах мимо Е стирал партию; «Заново» — кнопкой паузы.
func _test_pause_restart() -> void:
	var esc := InputEventAction.new()
	esc.action = &"pause"
	esc.pressed = true
	w._unhandled_input(esc)
	_check(w.paused and paused, "Esc ставит паузу")
	w._unhandled_input(esc)
	_check(not w.paused and not paused, "Esc снимает паузу")
	w.restart()
	_check(w.contracts.contracts.is_empty() and w.now == 0.0 and w.map_id == "_gray",
		"«Заново» перезапускает карту")


func _test_astar() -> void:
	var a := Vector2(820, ROCK_Y)
	var b := Vector2(1060, ROCK_Y)
	var path := w.terrain.find_path(a, b)
	var inside := false
	var plen := a.distance_to(path[0])
	for i in path.size():
		inside = inside or w.terrain.is_rock(path[i])
		if i > 0:
			plen += path[i].distance_to(path[i - 1])
	_check(not path.is_empty() and path[path.size() - 1] == b, "A* доводит до цели")
	_check(not inside and plen > a.distance_to(b) + 20.0, "A* обходит скалу (путь %.0f px)" % plen)


func _test_effective_resources() -> void:
	w.mods = {"mana_max_bonus": 25.0, "mana_regen_bonus": 2.0, "army_cap_bonus": 20.0}
	w.start_map("_gray")
	var f := w.contracts
	_check(is_equal_approx(f.mana, 125.0), "поправка заполняет потолок маны 125 при старте")
	f.mana = 124.0
	f.tick(1.0, w.now)
	f.tick(1.0, w.now)
	_check(is_equal_approx(f.mana, 125.0), "125 держится после двух тиков регена")
	f.mana = 100.0
	f.tick(1.0, w.now)
	_check(is_equal_approx(f.mana, 100.0 + LegionCfg.MANA_REGEN + 2.0),
		"эффективный реген включает поправку ровно один раз")
	f.mana = 125.0
	f.begin(Vector2(300, 600))
	f.extend(Vector2(340, 600))
	f.cancel()
	_check(is_equal_approx(f.mana, 125.0), "возврат черновика не обрезает ману до 100")
	# v15 (пакет staff): лимита армии нет — потолок это сумма штатов построек, Котёл — штат
	# start_army карты; поправки лимита приходят через Campaign.stat (staff/meta), склеп как
	# постройку проверяет legion_crypt_test
	# штат карты — с темпом читаемости STAFF_PACE (D-0927-49)
	var base_army := LegionStaff.paced(int(w.map.get("start_army", LegionCfg.START_ARMY)))
	_check(w.effective_army_cap() == base_army and w.army_alive() == base_army,
		"потолок — штат Котла, стартовый штат выдан сразу (%d)" % w.army_alive())
	w.mods = {}
	w.start_map("_gray")
	_check(is_equal_approx(w.contracts.mana_max, LegionCfg.MANA_MAX),
		"следующая карта без поправок сбрасывает потолок")


func _test_boss_siege() -> void:
	w.start_map("boss")
	w.dev_invuln = false
	var boss := Foe.new()
	w.entities.add_child(boss)
	boss.setup(w, "boss", PackedVector2Array([w.cauldron_pos]), {})
	w.foes.append(boss)
	var hp := w.cauldron_hp
	w.foe_reached_cauldron(boss)
	_check(boss.is_active() and boss.state == Foe.State.SIEGE and boss.visible,
		"дошедший Прораб остаётся живым и видимым в волне")
	_check(w.cauldron_hp == hp, "осада не наносит прежний разовый урон 140")
	w.force_end(true)
	_check(w.phase == LegionWorld.Phase.BATTLE, "живой Прораб блокирует победу")
	boss.tick(LegionCfg.BOSS_SIEGE_INTERVAL)
	boss.tick(LegionCfg.BOSS_SIEGE_INTERVAL)
	_check(w.cauldron_hp == hp - 2.0 * LegionCfg.BOSS_SIEGE_DAMAGE,
		"осада наносит два периодических удара")
	boss.take_damage(boss.hp, w.cauldron_pos)
	_check(int(w.final_stats(false)["boss_killed"]) == 1, "убийство Прораба отражено в JSON")
	w.force_end(true)
	_check(w.phase == LegionWorld.Phase.VICTORY, "после убийства Прораба победа разрешена")


func _test_release_feedback() -> void:
	w.start_map("_gray")
	w.set_process(false)
	var audio: LegionAudio = null
	for child in w.get_children():
		if child is LegionAudio:
			audio = child as LegionAudio
	_check(audio != null, "звуковой слой подключён")
	if audio == null:
		return
	# Даём отложенным откликам предыдущих проверок завершить свой кадр.
	await process_frame
	var counts: Dictionary = audio.get("_call_counts")
	var before := int(counts.get("segment_released", 0))
	w.segment_released.emit(null, 0, 0)
	await process_frame
	_check(int(counts.get("segment_released", 0)) == before,
		"пустой участок не вызывает звук и тряску натиска")
	w.segment_released.emit(null, 0, 3)
	w.segment_released.emit(null, 1, 4)
	await process_frame
	_check(int(counts.get("segment_released", 0)) == before + 1,
		"два участка одного расторжения дают один отклик")
	var playback: Audio = audio.get("_audio")
	var streams: Dictionary = playback.get("_music_streams")
	_check(streams.size() == Audio.MUSIC_FILES.size() and not streams.values().has(null),
		"все музыкальные потоки загружены до смены волн")
