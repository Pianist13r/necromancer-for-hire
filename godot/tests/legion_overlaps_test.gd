extends SceneTree
##
## Регресс наездов надписей (кадры координатора 02.10.2026, Игорь: «всё, что критично, типа
## наезжающих надписей и косяков, нужно обязательно доделать»):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_overlaps_test.gd -- --mute
##
## 1) совет «строй набран — сорви: «Обряд!»» — над строем треугольника, а не поперёк бойцов
##    (у квадрата «золотой — щёлкни ПКМ» и так над строем — проверка, что так и осталось);
## 2) сработал обряд — совет гаснет в тот же миг (большая «Обряд!» ложилась на него);
## 3) всплывашка имени фигуры при рождении («Двойная смена!») — над строем: у центра она гасла
##    поверх толпы и читалась «под бойцами»;
## 4) «Болото»: длинная табличка «Ничей склеп · займите…» — у одного склепа, а не у обоих, и ни
##    одна табличка склепа не ложится на панели HUD (нижняя лежала на карточке «Подряд»);
## 5) метка урока треугольника на «Мосте» — не на Котле и не на стартовой армии.
## Итог «LEGION OVERLAPS: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_overlaps_test.cfg"
const DT := 1.0 / 60.0
const FC := Vector2(1130.0, 405.0)
## Рост бойца над точкой места, если вида нет (headless без спрайтов).
const UNIT_H := 40.0

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
	await process_frame
	w.set_process(false)
	Settings.hints_override = "on"
	_test_rite_hint()
	_test_gold_hint()
	_test_figure_popup()
	await _test_crypts()
	_test_bridge_mark()
	Settings.hints_override = ""
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION OVERLAPS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


## Фигура в обход мыши (как legion_figures_test): штрих по шаблону урока.
func _fig(fig: StringName, r: float) -> Contract:
	var pts := LegionLessonBot.template(String(fig), FC, r)
	var n := w.contracts.contracts.size()
	w.contracts.call("_create", pts, 1, LegionCfg.KIND_LABORER, false, fig)
	if w.contracts.contracts.size() == n:
		return null
	var c: Contract = w.contracts.contracts[n]
	return c if c.figure == fig else null


func _man(c: Contract, frac := 1.0) -> void:
	var k := 0
	for p in c.posts:
		if float(k) >= frac * c.posts.size():
			break
		if p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()
			k += 1


## Верх голов строя: самое верхнее место минус рост бойца (по виду, если он есть).
func _crowd_top(c: Contract) -> float:
	var top := INF
	for p in c.posts:
		var y: float = (p["pos"] as Vector2).y - UNIT_H
		var u := p["unit"] as Legionnaire
		if u != null and u.view != null and u.view.body_h > 0.0:
			y = u.position.y + u.view.ground_px() - u.view.body_h
		top = minf(top, y)
	return top


## Подпись совета type на поле: базовая линия (pos − HINT_UP) или INF, если подписи нет.
func _hint_base(type: StringName) -> float:
	var labels: Array = w.intuit.get("_labels")
	for l: Dictionary in labels:
		if l["type"] == type:
			return (l["pos"] as Vector2).y - IntuitCfg.HINT_UP
	return INF


func _test_rite_hint() -> void:
	print("— совет «Обряд» над строем и гаснет на обряде")
	_fresh()
	var c := _fig(&"triangle", 80.0)
	_check(c != null, "треугольник собран")
	if c == null:
		return
	_man(c, 0.6)
	# D-1002: ульта только у ЗАРЯЖЕННОГО строя — держим порог 1,5 с боя
	for i in int(FigureCfg.CHARGE_TIME / (1.0 / 60.0)) + 2:
		w._step(1.0 / 60.0)
	w.intuit.scan()
	var base := _hint_base(&"rite")
	var top := _crowd_top(c)
	_check(base != INF, "строй набран — совет «сорви: «Обряд!»» висит")
	_check(base <= top, "совет над головами строя: базовая линия y %.0f, верх голов %.0f"
		% [base, top])
	var rites := int(w.stats.get("rites", 0))
	for s in c.seg_count():
		if c.seg_alive(s):
			c.seg_age[s] = c.ttl - 0.01
	w.contracts.tick(0.05, w.now)
	_check(int(w.stats.get("rites", 0)) == rites + 1, "обряд сработал на таянии")
	_check(_hint_base(&"rite") == INF, "в миг обряда совета уже нет (без нового скана)")


func _test_gold_hint() -> void:
	print("— «золотой — щёлкни» у квадрата над строем")
	_fresh()
	var c := _fig(&"square", 85.0)
	_check(c != null, "квадрат собран")
	if c == null:
		return
	_man(c)
	# D-1002: бойцы каре стоят ТОЛЬКО на углах — врага ловят зоны угловых участков, а не
	# середины рёбер (пустое ребро больше не даёт широкую зону попадания)
	for off: Vector2 in [Vector2(-95, -95), Vector2(95, -70), Vector2(80, 100), Vector2(-80, 100)]:
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([FC + off, FC + off
			+ Vector2(0, 400)]), FC + off)
		f.speed = 0.0
	w.intuit.scan()
	var base := _hint_base(&"gold")
	_check(base != INF, "враг у каре — совет «золотой» висит")
	_check(base <= _crowd_top(c), "совет над головами: базовая линия y %.0f, верх голов %.0f"
		% [base, _crowd_top(c)])


func _test_figure_popup() -> void:
	print("— имя фигуры при рождении — над строем")
	for fig: StringName in [&"eight", &"triangle", &"square"]:
		_fresh()
		var c := _fig(fig, 70.0 if fig == &"eight" else 80.0)
		if c == null:
			_check(false, "%s собран" % fig)
			continue
		_man(c)
		w.contracts.call("_on_figure_made", c)
		var pops: Array = w.contracts.get("_popups")
		var p: Dictionary = pops[pops.size() - 1]
		# базовая линия всплывашки в первый кадр — pos.y − 34 (ContractField._draw_popups)
		var base := (p["pos"] as Vector2).y - 34.0
		_check(base <= _crowd_top(c), "%s: «%s» над головами (база y %.0f, верх голов %.0f)"
			% [fig, p.get("text", ""), base, _crowd_top(c)])


func _test_crypts() -> void:
	print("— таблички склепов «Болота»")
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1"}
	w.args["bot"] = "off"
	w.start_map("swamp")
	for i in 3:
		await process_frame
	_check(w.crypts.size() == 2, "на «Болоте» два склепа (%d)" % w.crypts.size())
	var long := 0
	for c in w.crypts:
		c.nearby_units = 0
		if c.label_text().contains("займите"):
			long += 1
	_check(long == 1, "«займите 8 бойцами» — у одного склепа, а не у всех (%d)" % long)
	var panels: Array[Rect2] = w.hud.panel_rects()
	_check(panels.size() >= 3, "панели HUD видны (%d): %s" % [panels.size(), panels])
	for c in w.crypts:
		_check_chip(c, panels, "склеп у %s" % c.position)
	# склеп у самого низа поля посередине — табличка уходит над карточками «Подряд/Охрана»
	var c1 := w.crypts[w.crypts.size() - 1]
	c1.position = Vector2(640.0, 600.0)
	_check_chip(c1, panels, "склеп у нижней панели (640, 600)")
	c1.position = Vector2(1240.0, 690.0)
	_check_chip(c1, panels, "склеп в правом нижнем углу (1240, 690)")
	# случайные поля со склепами (PgArch «crypts»): первые сиды, где склепы есть
	var found := 0
	for seed_i in range(1, 60):
		if found >= 3:
			break
		w.start_map("gen:%d:3" % seed_i)
		if w.crypts.is_empty():
			continue
		found += 1
		await process_frame
		for c in w.crypts:
			_check_chip(c, w.hud.panel_rects(), "gen:%d:3, склеп у %s" % [seed_i, c.position])
	_check(found > 0, "нашлись случайные поля со склепами (%d)" % found)


func _check_chip(c: LegionCrypt, panels: Array[Rect2], what: String) -> void:
	if not c.has_method("label_rect"):
		_check(false, "%s: у склепа нет label_rect()" % what)
		return
	var chip: Rect2 = c.call("label_rect")
	chip.position += c.position
	var hit := Rect2()
	for r in panels:
		# 10 px — уголок выбранного вида над карточкой «Подряд» (LegionKindBar)
		if r.grow(10.0).intersects(chip):
			hit = r
	var view := w.view_rect()
	_check(hit == Rect2() and view.encloses(chip), "%s: табличка %s мимо панелей HUD%s" % [what,
		chip, "" if hit == Rect2() else " (лежит на %s)" % hit])


func _test_bridge_mark() -> void:
	print("— метка урока треугольника на «Мосте»")
	var lesson := {}
	for l: Dictionary in LegionWorld.load_map("bridge").get("lessons", []):
		if String(l.get("id", "")) == "triangle":
			lesson = l
	var mark: Dictionary = lesson.get("mark", {})
	var has_mark := mark.has("at") and mark.has("r")
	_check(has_mark, "на «Мосте» есть метка урока треугольника с центром и радиусом")
	if not has_mark:
		return
	var at := Vector2(float(mark["at"][0]), float(mark["at"][1]))
	var tpl := LegionLessonBot.template("triangle", at, float(mark["r"]))
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1"}
	w.start_map("bridge")
	var army := Rect2(w.units[0].position, Vector2.ZERO)
	for u in w.units:
		army = army.expand(u.position)
	var box := Rect2(tpl[0], Vector2.ZERO)
	var open := true
	var near := INF
	for p in tpl:
		box = box.expand(p)
		open = open and w.terrain.walkable(p)
		near = minf(near, p.distance_to(w.cauldron_pos))
	_check(open, "шаблон %s целиком на проходимой земле" % at)
	_check(near >= LegionCfg.CAULDRON_RADIUS * 2.0,
		"шаблон не на Котле: ближайшая точка в %.0f px от Котла" % near)
	_check(not box.intersects(army.grow(8.0)),
		"шаблон %s не на стартовой армии %s" % [box, army])
