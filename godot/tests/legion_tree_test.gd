extends SceneTree
##
## Регресс slow/tree: «Контора» и экран героя — деревья с узлами-иконками (Игорь 26.09: «дерево…
## с иконками… надо читать до фига текста»). Проверяет: у каждой покупки/уровня, ранга и перка
## есть узел и иконка; состояния узлов (куплено / можно / не хватает / закрыто) при разном запасе
## валюты и купленном; клик покупает ровно то же, что прежний путь (Campaign.shop_buy /
## hero_rank_up / hero_take_perk) — сравнение снимков сохранения; требования перков и закрытые
## виды соблюдены; сброс очков; фокус с клавиатуры обходит все узлы, Enter покупает.
## Узлы ищутся по meta "tree_key"/"tree_state", без имени класса — на старом экране (карточки
## с кнопками) тест не падает разбором, а честно проваливает проверки.
## Пишет во временный файл — user://legion.cfg владельца не трогает (Campaign.set_save_path).
##
##   "$GODOT" --headless --path godot --script res://tests/legion_tree_test.gd -- --mute
##

const TEST_PATH := "user://legion_tree_test_run.cfg"

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
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	await _test_office_nodes_and_states()
	await _test_office_click_equals_old_path()
	await _test_office_denied_clicks()
	await _test_office_locked_kind()
	await _test_hero_nodes_and_states()
	await _test_hero_click_equals_old_path()
	await _test_hero_reset()
	await _test_focus_walk()
	_cleanup()
	print("Tree test: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Помощники ─────────────────────────────────────────────────────────────────

func _fresh() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()


func _open(screen: Control) -> Control:
	root.add_child(screen)
	await _frames(2)
	return screen


func _close(screen: Control) -> void:
	screen.queue_free()
	await _frames(1)


func _tree_nodes(screen: Node) -> Dictionary:
	var out := {}
	for c in screen.find_children("*", "", true, false):
		if c.has_meta("tree_key"):
			out[String(c.get_meta("tree_key"))] = c
	return out


func _state(nodes: Dictionary, k: String) -> String:
	var n: Node = nodes.get(k, null)
	return String(n.get_meta("tree_state", "")) if n != null else "<нет узла>"


func _click(nodes: Dictionary, k: String) -> void:
	var n: Node = nodes.get(k, null)
	if n != null:
		n.emit_signal("pressed")


func _shop_keys() -> Array[String]:
	var out: Array[String] = []
	for id: String in LegionMetaCfg.OFFICE_SHOP_ORDER:
		var per_kind := bool(LegionMetaCfg.OFFICE_SHOP[id].get("per_kind", false))
		var kinds: Array = LegionCfg.KIND_ORDER if per_kind else [&""]
		for kind in kinds:
			for lvl in range(1, Campaign.shop_max_level(id) + 1):
				out.append("shop:%s:%s:%d" % [id, String(kind), lvl])
	return out


func _hero_keys() -> Array[String]:
	var out: Array[String] = []
	for a: StringName in LegionMetaCfg.HERO_ABILITIES:
		for r in range(1, LegionMetaCfg.HERO_ABILITY_MAX_RANK + 1):
			out.append("rank:%s:%d" % [String(a), r])
	for id: String in LegionMetaCfg.HERO_PERKS:
		out.append("perk:%s" % id)
	return out


## Всё, что покупки меняют в сохранении, — для сравнения «старый путь» / «клик по узлу».
func _snapshot() -> Dictionary:
	var shop := {}
	for id: String in LegionMetaCfg.OFFICE_SHOP_ORDER:
		shop[id] = Campaign.shop_level(id)
		for kind in LegionCfg.KIND_ORDER:
			shop["%s_%s" % [id, kind]] = Campaign.shop_level(id, String(kind))
	var perks: Array = []
	for p in Campaign.hero_perks():
		perks.append(String(p))
	perks.sort()
	var ranks := {}
	for a in LegionMetaCfg.HERO_ABILITIES:
		ranks[a] = Campaign.hero_rank(a)
	return {"bounty": Campaign.bounty(), "shop": shop, "perks": perks, "ranks": ranks,
		"points": Campaign.hero_points_available()}


func _all_icons_exist(nodes: Dictionary, keys: Array[String]) -> int:
	var missing := 0
	for k in keys:
		var n: Node = nodes.get(k, null)
		if n == null or not ResourceLoader.exists(String(n.get_meta("tree_icon", ""))):
			missing += 1
	return missing


# ── «Контора» ─────────────────────────────────────────────────────────────────

func _test_office_nodes_and_states() -> void:
	_fresh()
	Campaign.unlock_all()
	var screen := await _open(OfficeShop.new())
	var nodes := _tree_nodes(screen)
	var keys := _shop_keys()
	var missing := 0
	for k in keys:
		if not nodes.has(k):
			missing += 1
	_check(keys.size() == 35, "в «Конторе» 35 уровней покупок (получили %d)" % keys.size())
	_check(missing == 0, "у каждого уровня каждой покупки есть узел (нет %d из %d)" % [missing,
		keys.size()])
	_check(_all_icons_exist(nodes, keys) == 0, "у каждого узла «Конторы» есть иконка на диске")

	# Премии 0: первый уровень — «не хватает», дальше — «закрыто» (нужен предыдущий уровень).
	var bad := 0
	for k in keys:
		var want := "poor" if k.ends_with(":1") else "locked"
		if _state(nodes, k) != want:
			bad += 1
	_check(bad == 0, "премия 0: уровень 1 «не хватает», уровни 2+ «закрыто» (неверных %d)" % bad)

	# Премия 50: по цене — «Дальность» 40 и «Штат» 50 можно, «Мана» 60 и «Расчёт» 60 — не хватает.
	Campaign._add_bounty(50)
	screen.call("refresh")
	_check(_state(nodes, "shop:range:laborer:1") == "buyable", "премия 50: «Дальность» ур.1 можно")
	_check(_state(nodes, "shop:staff:guard:1") == "buyable", "премия 50: «Штат» ур.1 (50) можно")
	_check(_state(nodes, "shop:mana::1") == "poor", "премия 50: «Мана» ур.1 (60) не хватает")
	_check(_state(nodes, "shop:settlement::1") == "poor", "премия 50: «Расчёт» ур.1 не хватает")
	_check(_state(nodes, "shop:range:laborer:2") == "locked", "ур.2 закрыт, пока не куплен ур.1")

	# Подсказка: наведение показывает цену и требование одной строкой.
	var n: Node = nodes.get("shop:mana::1", null)
	var tip := ""
	if n != null and screen.has_method("tree"):
		n.emit_signal("mouse_entered")
		var t: UpgradeTree = screen.call("tree")
		tip = t.tip_text() if t.tip_visible_for(n) else ""
	_check(tip.contains("Мана") and tip.contains("+20") and tip.contains("Не хватает 10"),
		"подсказка «Маны»: что даёт с числами и сколько не хватает («%s»)" % tip)
	await _close(screen)


func _test_office_click_equals_old_path() -> void:
	# Старый путь: те же покупки прямыми вызовами, как делали кнопки прежних карточек.
	_fresh()
	Campaign.unlock_all()
	Campaign._add_bounty(300)
	Campaign.shop_buy("range", "laborer")
	Campaign.shop_buy("range", "laborer")
	Campaign.shop_buy("mana")
	Campaign.shop_buy("staff", "guard")
	var old_snap := _snapshot()

	_fresh()
	Campaign.unlock_all()
	Campaign._add_bounty(300)
	var screen := await _open(OfficeShop.new())
	var bought := [0]
	screen.connect("bought", func() -> void: bought[0] += 1)
	var nodes := _tree_nodes(screen)
	_click(nodes, "shop:range:laborer:1")
	_click(nodes, "shop:range:laborer:2")
	_click(nodes, "shop:mana::1")
	_click(nodes, "shop:staff:guard:1")
	var new_snap := _snapshot()
	_check(old_snap == new_snap, "клики по узлам = прежние shop_buy (%s / %s)" % [old_snap["shop"],
		new_snap["shop"]])
	_check(int(bought[0]) == 4, "сигнал bought на каждую покупку (озвучка), получили %d" % bought[0])
	_check(_state(nodes, "shop:range:laborer:2") == "owned", "купленный уровень — «куплено»")
	# 300 − 40 − 70 − 60 − 50 = 80 премии, ур.3 «Дальности» стоит 110.
	_check(_state(nodes, "shop:range:laborer:3") == "poor",
		"следующий уровень цепочки открылся, но премии (80) на него (110) не хватает")
	await _close(screen)


func _test_office_denied_clicks() -> void:
	_fresh()
	Campaign.unlock_all()
	Campaign._add_bounty(100)
	Campaign.shop_buy("staff", "guard")   # 50, остаётся 50
	var screen := await _open(OfficeShop.new())
	var nodes := _tree_nodes(screen)
	var before := _snapshot()
	_click(nodes, "shop:staff:guard:1")   # уже куплено — ничего
	_click(nodes, "shop:staff:guard:3")   # закрыто: нет ур.2
	_click(nodes, "shop:mana::1")         # 60 > 50 — не хватает
	_check(_snapshot() == before, "клик по купленному/закрытому/дорогому ничего не покупает")
	var denied: Node = nodes.get("shop:mana::1", null)
	_check(denied != null and bool(denied.get_meta("tree_denied", false)),
		"отказ отмечен миганием узла")
	await _close(screen)


func _test_office_locked_kind() -> void:
	# Свежая кампания: открыт только подрядчик — ветки вахтёра и счетовода закрыты.
	_fresh()
	Campaign._add_bounty(500)
	var screen := await _open(OfficeShop.new())
	var nodes := _tree_nodes(screen)
	_check(_state(nodes, "shop:range:laborer:1") == "buyable", "открытый вид: покупка доступна")
	_check(_state(nodes, "shop:range:guard:1") == "locked", "неоткрытый вид: узел закрыт")
	_click(nodes, "shop:range:guard:1")
	_check(Campaign.shop_level("range", "guard") == 0 and Campaign.bounty() == 500,
		"клик по закрытому виду не покупает")
	await _close(screen)


# ── Экран героя ───────────────────────────────────────────────────────────────

func _test_hero_nodes_and_states() -> void:
	_fresh()
	Campaign._add_hero_xp(450)   # уровень 4 — 3 очка
	var screen := await _open(HeroScreen.new())
	var nodes := _tree_nodes(screen)
	var keys := _hero_keys()
	var missing := 0
	for k in keys:
		if not nodes.has(k):
			missing += 1
	_check(keys.size() == 15, "у героя 6 рангов и 9 перков (получили %d)" % keys.size())
	_check(missing == 0, "у каждого ранга и перка есть узел (нет %d)" % missing)
	_check(_all_icons_exist(nodes, keys) == 0, "у каждого узла героя есть иконка на диске")
	_check(_state(nodes, "perk:perk_fast_hire") == "buyable", "первый перк ветки — можно")
	_check(_state(nodes, "perk:perk_big_staff") == "locked", "второй перк ветки без первого — закрыт")
	_check(_state(nodes, "rank:q:1") == "buyable" and _state(nodes, "rank:q:2") == "locked",
		"ранг 1 можно, ранг 2 закрыт до ранга 1")
	_click(nodes, "perk:perk_big_staff")
	_check(not Campaign.hero_has_perk(&"perk_big_staff"), "требование перка соблюдено: не взят")
	await _close(screen)

	_fresh()   # уровень 1 — очков нет
	var screen2 := await _open(HeroScreen.new())
	var nodes2 := _tree_nodes(screen2)
	_check(_state(nodes2, "perk:perk_short_cd") == "poor" and _state(nodes2, "rank:e:1") == "poor",
		"без очков: доступные узлы — «не хватает»")
	_click(nodes2, "rank:e:1")
	_check(Campaign.hero_rank(&"e") == 0, "без очков ранг не берётся")
	await _close(screen2)


func _test_hero_click_equals_old_path() -> void:
	_fresh()
	Campaign._add_hero_xp(450)
	Campaign.hero_take_perk(&"perk_fast_hire")
	Campaign.hero_take_perk(&"perk_big_staff")
	Campaign.hero_rank_up(&"q")
	var old_snap := _snapshot()

	_fresh()
	Campaign._add_hero_xp(450)
	var screen := await _open(HeroScreen.new())
	var nodes := _tree_nodes(screen)
	_click(nodes, "perk:perk_fast_hire")
	_check(_state(nodes, "perk:perk_big_staff") == "buyable", "взял первый перк — второй открылся")
	_click(nodes, "perk:perk_big_staff")
	_click(nodes, "rank:q:1")
	_check(_snapshot() == old_snap, "клики по узлам героя = прежние hero_take_perk/hero_rank_up")
	_check(_state(nodes, "rank:q:2") == "poor", "очки кончились: ранг 2 — «не хватает»")
	await _close(screen)


func _test_hero_reset() -> void:
	_fresh()
	Campaign._add_hero_xp(450)
	Campaign.hero_take_perk(&"perk_short_cd")
	Campaign.hero_rank_up(&"w")
	var screen := await _open(HeroScreen.new())
	var nodes := _tree_nodes(screen)
	var reset_btn: Button = null
	for b in screen.find_children("*", "Button", true, false):
		if (b as Button).text == "Сбросить очки":
			reset_btn = b
	_check(reset_btn != null, "кнопка «Сбросить очки» на месте")
	if reset_btn != null:
		reset_btn.pressed.emit()
	_check(Campaign.hero_perks().is_empty() and Campaign.hero_rank(&"w") == 0
		and Campaign.hero_points_available() == 3, "сброс вернул все очки")
	_check(_state(nodes, "perk:perk_short_cd") == "buyable" and _state(nodes, "rank:w:1") == "buyable",
		"после сброса узлы снова «можно»")
	await _close(screen)


# ── Фокус: стрелки/Tab обходят все узлы, Enter покупает ───────────────────────

func _reach(nodes: Dictionary, props: Array[String]) -> int:
	var all := nodes.values()
	if all.is_empty():
		return 0
	var seen := {all[0]: true}
	var queue: Array = [all[0]]
	while not queue.is_empty():
		var n: Control = queue.pop_front()
		for p in props:
			var path: NodePath = n.get(p)
			if path.is_empty():
				continue
			var o := n.get_node_or_null(path)
			if o != null and o.has_meta("tree_key") and not seen.has(o):
				seen[o] = true
				queue.append(o)
	return seen.size()


func _test_focus_walk() -> void:
	_fresh()
	Campaign.unlock_all()
	Campaign._add_bounty(40)
	var screens: Array[Control] = [OfficeShop.new(), HeroScreen.new()]
	for screen in screens:
		screen = await _open(screen)
		var nodes := _tree_nodes(screen)
		var label := "«Контора»" if screen is OfficeShop else "герой"
		var focusable := 0
		for n: Control in nodes.values():
			if n.focus_mode == Control.FOCUS_ALL:
				focusable += 1
		_check(nodes.size() > 0 and focusable == nodes.size(),
			"%s: все узлы берут фокус (%d/%d)" % [label, focusable, nodes.size()])
		var arrows := _reach(nodes, ["focus_neighbor_left", "focus_neighbor_right",
			"focus_neighbor_top", "focus_neighbor_bottom"])
		_check(nodes.size() > 0 and arrows == nodes.size(),
			"%s: стрелками доходим до всех узлов (%d/%d)" % [label, arrows, nodes.size()])
		var tabs := _reach(nodes, ["focus_next"])
		_check(nodes.size() > 0 and tabs == nodes.size(),
			"%s: Tab обходит все узлы (%d/%d)" % [label, tabs, nodes.size()])
		await _close(screen)

	# Настоящий ввод: фокус на «Дальность» подрядчика, стрелка вправо — «Штат», влево и Enter —
	# покупка (премии 40 хватает ровно на неё).
	var office := await _open(OfficeShop.new())
	var nodes := _tree_nodes(office)
	var start: Control = nodes.get("shop:range:laborer:1", null)
	var right_ok := false
	if start != null:
		start.grab_focus()
		_press_action("ui_right")
		await _frames(1)
		right_ok = office.get_viewport().gui_get_focus_owner() == nodes.get("shop:staff:laborer:1")
		_press_action("ui_left")
		await _frames(1)
		_press_action("ui_accept")
		await _frames(1)
	_check(right_ok, "стрелка вправо переводит фокус на соседнюю цепочку")
	_check(Campaign.shop_level("range", "laborer") == 1 and Campaign.bounty() == 0,
		"Enter на узле в фокусе покупает его")
	await _close(office)


func _press_action(action: String) -> void:
	var down := InputEventAction.new()
	down.action = action
	down.pressed = true
	root.push_input(down)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	root.push_input(up)


func _cleanup() -> void:
	var abs_path := ProjectSettings.globalize_path(TEST_PATH)
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(abs_path)
	Campaign.set_save_path(Campaign.PATH)
