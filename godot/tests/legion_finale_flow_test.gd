extends SceneTree
##
## Финал кампании: победа на предпоследней карте → награда (с переброской) → брифинг последней →
## выход Прораба один раз за сеанс → поражение и «Ещё раз» без второй награды → победа над
## Прорабом → «Кампания пройдена» без ожидающей награды → перезапуск сохранения → меню ведёт на
## первую карту. Плюс правило боя: свита Прораба (summoned) не даёт финала, пока жива
## (active_foes), а сам Прораб не даёт победы, пока жив (LegionWorld._end). Аудит финала
## 13.10.2026 (ветка bridge/20261013-184741).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_finale_flow_test.gd -- --mute
##
## Итог «LEGION FINALE FLOW: N/M OK»; код выхода 1, если что-то упало. Сохранение — временный файл
## (Campaign.set_save_path), настоящий user://legion.cfg владельца не трогаем.
##

const TEST_PATH := "user://legion_finale_flow_test.cfg"

var main: LegionMain
var _checks := 0
var _fails := 0


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
	var deadline := Time.get_ticks_msec() + 60000
	while is_instance_valid(main) and main._loading_battle:
		if Time.get_ticks_msec() >= deadline:
			_check(false, "battle loading timed out")
			quit(1)
			return
		await process_frame
	for i in n:
		await process_frame


func _cutscene() -> LegionCutscene:
	for c in main.get_children():
		if c is LegionCutscene and not c.is_queued_for_deletion():
			return c
	return null


func _skip() -> void:
	var c := _cutscene()
	if c != null:
		c._skip_all()
	await _frames(3)


## Все видимые надписи экрана — проверка текста итога без привязки к именам узлов.
func _screen_texts(node: Node, out: Array[String]) -> void:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	for c in node.get_children():
		_screen_texts(c, out)


func _has_text(fragment: String) -> bool:
	var texts: Array[String] = []
	if main.screen != null:
		_screen_texts(main.screen, texts)
	for t in texts:
		if t.contains(fragment):
			return true
	return false


func _run() -> void:
	# Проверки текста итога — русские строки; язык задаём явно, как legion_hud_text_layout_test
	# (verifier 13.10: на нерусской ОС с чистым APPDATA i18n выбрал бы en и проверки бы упали).
	I18n.initialize("ru")
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)

	var maps := Campaign.maps()
	_check(maps.size() >= 3, "кампания даёт минимум 3 карты")
	var first := String(maps[0].get("id", ""))
	var pre := String(maps[maps.size() - 2].get("id", ""))
	var last := String(maps[maps.size() - 1].get("id", ""))
	_check(LegionMain._has_boss(last) and not LegionMain._has_boss(pre),
		"последняя карта — с боссом, предпоследняя — без (%s → %s)" % [pre, last])
	# Fixture завершённой ранней кампании: иначе меню выбирает первую НЕПРОЙДЕННУЮ карту,
	# и совпадение с first ложно подтверждает fallback после полного прохождения.
	for i in range(maps.size() - 2):
		Campaign.record_result(String(maps[i].get("id", "")), true, 1.0)
	# Премия заранее: сид предложения считается от премии (Campaign.pending_reward_rng) — переброска
	# ниже должна идти при той же премии, что и первое предложение, как у живого игрока.
	Campaign.add_bounty(AmendmentDb.REROLL_COST * 3)

	# ── победа на предпоследней карте → награда за последнюю ────────────────────────────────
	main.start_battle(pre)
	await _frames(2)
	_check(_cutscene() == null and main.world != null and main.world.map_id == pre,
		"бой на предпоследней карте — без катсцены")
	main.world.force_end(true)
	await _frames(2)
	_check(main.screen is LegionResult, "победа на предпоследней — экран итога")
	_check(Campaign.pending_reward() == last, "ожидающая награда ведёт на последнюю карту")
	_check(_has_text("Дальше: выбор поправки") and not _has_text("Кампания пройдена"),
		"итог предпоследней: «Дальше: выбор поправки», не «Кампания пройдена»")
	main._on_result_next()
	await _frames(2)
	_check(main.screen is UpgradePicker, "«Дальше» — выбор поправки")
	var picker := main.screen as UpgradePicker
	var first_offer := picker.offered()
	_check(first_offer.size() == 3, "первое предложение — три поправки")

	# Переброска гарантирует хотя бы одну новую поправку; совпадение остальных допустимо.
	var bounty_before := Campaign.bounty()
	picker._on_reroll()
	await _frames(1)
	var rerolled := picker.offered()
	_check(Campaign.bounty() == bounty_before - AmendmentDb.REROLL_COST,
		"переброска списала цену один раз")
	_check(rerolled.size() == 3, "после переброски снова три поправки")
	var overlap := 0
	for id in rerolled:
		if first_offer.has(id):
			overlap += 1
	print("  info переброска: было %s, стало %s, совпадений %d" % [first_offer, rerolled, overlap])
	_check(overlap < 3, "переброска сменила хотя бы одну поправку")
	_check(Campaign.offer_upgrades(Campaign.pending_reward_rng()) == rerolled,
		"перебросанное предложение сохранено")

	main.pick_upgrade(rerolled[0])
	await _frames(2)
	_check(Campaign.upgrades().has(rerolled[0]), "поправка подписана")
	_check(Campaign.pending_reward() == "" and not Campaign.reward_claimed(),
		"после подписи ожидающей награды нет")
	_check(main.screen is Briefing and (main.screen as Briefing)._map_id == last,
		"после подписи — брифинг последней карты")

	# ── брифинг → выход Прораба → бой ───────────────────────────────────────────────────────
	(main.screen as Briefing).start.emit(last)
	await _frames(2)
	_check(_cutscene() != null, "первый бой на карте босса — катсцена выхода Прораба")
	await _skip()
	_check(main.world.map_id == last and main.world.phase == LegionWorld.Phase.BATTLE,
		"после катсцены — бой на последней карте")

	# ── поражение → «Ещё раз» → брифинг той же карты без награды и без второй катсцены ──────
	main.world.force_end(false)
	await _frames(2)
	_check(main.screen is LegionResult, "поражение на последней — экран итога")
	_check(Campaign.pending_reward() == "" and Campaign.stars(last) == 0,
		"поражение не ставит награду и не даёт звёзд")
	_check(_has_text("Ещё раз"), "на итоге поражения есть «Ещё раз»")
	(main.screen as LegionResult).retry.emit()
	await _frames(2)
	_check(main.screen is Briefing and (main.screen as Briefing)._map_id == last,
		"«Ещё раз» после поражения — брифинг той же последней карты, без выбора поправки")
	(main.screen as Briefing).start.emit(last)
	await _frames(2)
	_check(_cutscene() == null and main.world.map_id == last
		and main.world.phase == LegionWorld.Phase.BATTLE,
		"повторный бой в том же сеансе — без второй катсцены Прораба")

	# ── победа над Прорабом → финал → «Кампания пройдена» ──────────────────────────────────
	main.world.force_end(true)
	await _frames(2)
	_check(main.world.phase == LegionWorld.Phase.BATTLE and _cutscene() == null,
		"победа без убитого Прораба не засчитывается (боевое правило)")
	main.world.stats["boss_killed"] = 1
	main.world.force_end(true)
	await _frames(2)
	_check(_cutscene() != null, "победа над Прорабом — финальная катсцена")
	await _skip()
	_check(main.screen is LegionResult, "после финала — экран итога")
	_check(_has_text("Кампания пройдена"), "итог последней карты — «Кампания пройдена»")
	_check(not _has_text("Дальше: выбор поправки") and _has_text("Ещё раз"),
		"на финальном итоге нет «Дальше», главная — «Ещё раз»")
	_check(Campaign.pending_reward() == "" and Campaign.stars(last) > 0,
		"финал: звёзды последней записаны, ожидающей награды нет")
	_check(main._pending_next_map == "", "финал: следующей карты в памяти экрана нет")

	# ── перезапуск: сохранение и меню после пройденной кампании ───────────────────────────
	Campaign.set_save_path(TEST_PATH)
	_check(Campaign.stars(last) > 0 and Campaign.pending_reward() == ""
		and not Campaign.reward_claimed(), "после перезапуска: финал на диске, награда не висит")
	_check(Campaign.has_progress() and Campaign.is_unlocked(last),
		"после перезапуска: прогресс и карта босса открыты")
	var all_completed := true
	for m in maps:
		all_completed = all_completed and Campaign.stars(String(m.get("id", ""))) > 0
	_check(all_completed, "после финала все карты имеют звёзды: непройденной карты для меню нет")
	_check(LegionRunStore.campaign_completed(), "полная кампания открывает дополнительные режимы")
	main.show_menu()
	await _frames(2)
	_check(main.screen is LegionMenu, "финал → меню")
	var endless_button := main.screen.find_child("EndlessAction", true, false) as Button
	var daily_button := main.screen.find_child("DailyAction", true, false) as Button
	_check(endless_button != null and not endless_button.disabled,
		"после полного финала кнопка бесконечного подряда открыта")
	_check(daily_button != null and not daily_button.disabled,
		"после полного финала кнопка вызова дня открыта")
	var menu_target := (main.screen as LegionMenu)._next_map_id()
	_check(menu_target == first,
		"меню после пройденной кампании ведёт на первую карту (%s)" % menu_target)
	(main.screen as LegionMenu).continue_pressed.emit(menu_target)
	await _frames(2)
	_check(main.screen is Briefing and (main.screen as Briefing)._map_id == first,
		"«Продолжить» после финала — брифинг первой карты, без выбора поправки")

	# ── боевое правило: свита Прораба держит финал, пока жива ──────────────────────────────
	main.start_battle(last)
	await _frames(2)
	var w := main.world
	w.set_process(false)   # мир стоит: проверяем правило, а не волны
	var path := PackedVector2Array([w.cauldron_pos + Vector2(400, 0), w.cauldron_pos])
	# origin без волны: враг волны проходит LegionChallenge.toughen/roll_elite, а носитель предмета
	# откладывает урон (defer_carrier_hit) — здесь нужен голый Прораб, а не бросок на элиту
	var boss := w.spawn_foe_on_path("boss", path, path[0], false, {})
	_check(boss != null and boss.type_id == "boss", "Прораб поставлен на карту")
	var before_summon := w.foes.size()
	boss._summon_escort()
	var escorts: Array[Foe] = []
	for f in w.foes:
		if f.has_meta(&"summoned"):
			escorts.append(f)
	var escort_n := int(boss.def["escort"])
	_check(w.foes.size() == before_summon + escort_n and escorts.size() == escort_n,
		"рёв зовёт свиту: %d призванных с меткой summoned" % escorts.size())
	for f in escorts:
		_check(int(f.origin.get("wave", 0)) == 0, "свита не принадлежит волне (origin.wave 0)")
	boss.take_damage(boss.hp, path[0])
	_check(int(w.stats.get("boss_killed", 0)) == 1 and not boss.alive, "Прораб убит: boss_killed = 1")
	_check(w.active_foes() == escorts.size(),
		"живая свита держит финал: active_foes = %d" % w.active_foes())
	for f in escorts:
		f.take_damage(f.hp, f.position)
	_check(w.active_foes() == 0, "свита добита — врагов не осталось, финал разрешён")

	main.queue_free()
	await _frames(1)
	Campaign.reset()
	print("LEGION FINALE FLOW: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
