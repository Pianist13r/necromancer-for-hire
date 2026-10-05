extends SceneTree
##
## Открытия кампании v20 по порядку карт (docs/legion/CAMPAIGN_V20.md, D-0926-46) и старые
## сохранения (D-0927-50). Только API, которое было и до v20 (Campaign.stat/is_unlocked/
## pending_unlock_labels, мир, поле договоров, герой): на старом коде тест собирается и честно
## проваливает проверки.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_unlocks_test.gd -- --mute
##
## 1) лестница: свежее сохранение открывает строго по порядку — на карте в первый раз открыто
##    ровно то, чему она учит, и всё, что раньше; ничего раньше времени;
## 2) старое сохранение той же формы, что у владельца (карты fork/bridge/maze открыты, звёзды на
##    wasteland/fork/bridge, обучение пройдено, в unlocks_seen — вахтёр и счетовод): вставленные
##    между ними «Проходная» и «Архив» открыты, их открытия выданы, «Новое» — только восьмёрка,
##    треугольник (до D-1002-03 — звезда) и предметы;
## 3) закрытое в бою молчит: кольцо/восьмёрка/треугольник/квадрат чертятся обычной линией
##    (квадрат и при открытом кольце — не «Оцепление», D-1002-03), Пробел не вертит
##    стрелку, Эр не зовёт «Сбор», Дубль-вэ и Е закрыты, вахтёр не выбирается, элитных нет;
##    вне кампании всё открыто.
## Итог «LEGION UNLOCKS: N/M OK»; код выхода 1.
##

const SAVE := "user://legion_unlocks_test.cfg"
const FPS := 60
## Что открывает каждая карта лестницы (поле unlocks её JSON).
const LADDER := [
	["wasteland", ["ability_unlocked_q"]],
	["gatehouse", ["control_unlocked_aim", "kind_unlocked_guard", "control_unlocked_rally"]],
	["fork", ["shape_unlocked_ring", "ability_unlocked_w", "ability_unlocked_e"]],
	["archive", ["shape_unlocked_eight", "kind_unlocked_clerk", "loot_unlocked_items"]],
	["bridge", ["shape_unlocked_triangle"]],
	["maze", ["shape_unlocked_pentagon"]],
	["swamp", ["shape_unlocked_square", "shape_unlocked_d_shape"]],
]

var w: LegionWorld
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
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	_test_ladder()
	_test_old_save()
	await _test_locks()
	Campaign.reset()
	print("LEGION UNLOCKS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _all_keys() -> Array[String]:
	var out: Array[String] = []
	for step: Array in LADDER:
		for k: String in step[1]:
			out.append(k)
	return out


# ── 1. Лестница ──────────────────────────────────────────────────────────────

func _test_ladder() -> void:
	print("— лестница открытий на свежем сохранении")
	Campaign.reset()
	var ids: Array[String] = []
	for m in Campaign.maps():
		ids.append(String(m.get("id", "")))
	var want_order := ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze", "swamp", "boss"]
	_check(ids == Array(want_order, TYPE_STRING, "", null), "порядок карт %s" % str(ids))
	var open: Array[String] = []
	for i in LADDER.size():
		var map_id: String = LADDER[i][0]
		for k: String in LADDER[i][1]:
			open.append(k)
		# на карте i (она уже открыта, следующая — ещё нет)
		_check(Campaign.is_unlocked(map_id) and (i + 1 >= ids.size() or not Campaign.is_unlocked(ids[i + 1])),
			"%s открыта, следующая — нет" % map_id)
		var wrong: Array[String] = []
		for k in _all_keys():
			var on := Campaign.stat(StringName(k)) > 0.5
			if on != open.has(k):
				wrong.append("%s=%s" % [k, on])
		_check(wrong.is_empty(), "на «%s» открыто ровно пройденное и своё (%s)" % [map_id,
			"ок" if wrong.is_empty() else ", ".join(wrong)])
		Campaign.record_result(map_id, true, 0.9)
	_check(Campaign.stat(&"kind_unlocked_laborer") > 0.5, "подряд открыт всегда")


# ── 2. Старое сохранение ────────────────────────────────────────────────────

## Фикстура той же формы, что сохранение владельца до v20 (свои числа, не живой файл).
func _old_save() -> void:
	Campaign.reset()
	var cfg := ConfigFile.new()
	cfg.set_value("cutscene", "intro_seen", true)
	cfg.set_value("tutorial", "done", true)
	cfg.set_value("tutorial", "hint_unit_guard", true)
	cfg.set_value("tutorial", "hint_foe_lawyer", true)
	cfg.set_value("progress", "wasteland_stars", 3)
	cfg.set_value("progress", "unlocked", ["fork", "bridge", "maze"])
	cfg.set_value("progress", "fork_stars", 2)
	cfg.set_value("progress", "bridge_stars", 3)
	cfg.set_value("meta", "bounty", 10)
	cfg.set_value("meta", "unlocks_seen", ["kind_guard", "kind_clerk"])
	cfg.set_value("hero", "xp", 500)
	cfg.save(SAVE)
	Campaign.set_save_path(SAVE)   # сброс кэша: перечитать файл


func _test_old_save() -> void:
	print("— старое сохранение (до v20)")
	_old_save()
	for id in ["gatehouse", "archive"]:
		_check(Campaign.is_unlocked(id), "%s (вставлена между пройденными) открыта" % id)
	_check(Campaign.is_unlocked("maze") and not Campaign.is_unlocked("swamp"),
		"maze открыта, swamp — по-прежнему нет")
	for k in ["kind_unlocked_guard", "kind_unlocked_clerk", "ability_unlocked_q", "ability_unlocked_w",
			"ability_unlocked_e", "control_unlocked_aim", "control_unlocked_rally", "shape_unlocked_ring",
			"shape_unlocked_eight", "shape_unlocked_triangle", "loot_unlocked_items"]:
		_check(Campaign.stat(StringName(k)) > 0.5, "старое сохранение: %s = 1" % k)
	var labels := Campaign.pending_unlock_labels()
	# D-1002: «Лабиринт» открывает ещё и «Комиссию» — у старого сохранения она тоже «новая»
	var want := ["Фигура «Двойная смена»: восьмёрка", "Элитные проверяющие и предметы",
		"Фигура «Обряд»: треугольник", "Фигура «Комиссия по упокоению»: пятиугольник"]
	_check(labels == Array(want, TYPE_STRING, "", null),
		"«Новое» у старого сохранения — только то, чего до v20 не было: %s" % str(labels))
	Campaign.mark_unlocks_seen()
	_check(Campaign.pending_unlock_labels().is_empty(), "после показа «Новое» пусто")
	Campaign.set_save_path(SAVE)
	_check(Campaign.pending_unlock_labels().is_empty() and Campaign.is_unlocked("archive"),
		"перечитанное сохранение: «Новое» пусто, Архив открыт")
	# свежее сохранение по-прежнему строго по порядку и без «старых» поблажек
	Campaign.reset()
	_check(not Campaign.is_unlocked("gatehouse") and Campaign.stat(&"kind_unlocked_guard") < 0.5,
		"свежее сохранение: Проходная закрыта, вахтёр закрыт")
	Campaign.record_result("wasteland", true, 0.9)
	var fresh := Campaign.pending_unlock_labels()
	_check(fresh.size() == 3 and fresh.has("Новый вид бойца: Вахтёр"),
		"свежее после «Пустыря»: «Новое» — вахтёр, стрелка, «Сбор» (%s)" % str(fresh))


# ── 3. Закрытое в бою молчит ────────────────────────────────────────────────

func _world(campaign: bool) -> void:
	if w == null:
		var scene: PackedScene = load("res://scenes/legion_world.tscn")
		w = scene.instantiate() as LegionWorld
		w.embedded = true
		root.add_child(w)
		await _frames(2)
	w.in_campaign = campaign
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.start_map("fork")
	await _frames(2)


func _circle(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := ceili(TAU * r / 6.0)
	for i in n + 1:
		var a := -PI * 0.5 + (TAU - 0.18) * float(i) / n
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts


func _eight(c: Vector2, b: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var a := b * 0.41
	var n := ceili((a + b) * 4.0 / 6.0)
	for i in n + 1:
		var t := PI * 0.5 + TAU * float(i) / n
		pts.append(c + Vector2(a * sin(t), b * sin(t) * cos(t)).rotated(PI * 0.5))
	return pts


## Правильный многоугольник одним штрихом (n = 3 — треугольник, 4 — квадрат на ребре).
func _ngon(c: Vector2, sides: int, r: float) -> PackedVector2Array:
	var corners := PackedVector2Array()
	var a0 := -PI * 0.5 if sides == 3 else -PI * 0.75
	for k in sides + 1:
		var a := a0 + TAU * float(k % sides) / sides
		corners.append(c + Vector2(cos(a), sin(a)) * r)
	var pts := PackedVector2Array([corners[0]])
	for i in range(1, corners.size()):
		var n := ceili(corners[i - 1].distance_to(corners[i]) / 6.0)
		for k in range(1, n + 1):
			pts.append(corners[i - 1].lerp(corners[i], float(k) / n))
	return pts


## Штрих через поле договоров тем же путём, что мышь; что получилось: "ring", "eight"/"triangle"/
## "square",
## "line" или "" (договора нет).
func _draw(pts: PackedVector2Array) -> String:
	w.contracts.mana = w.contracts.mana_max
	var before := w.contracts.contracts.size()
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	w.contracts.begin(pts[0])
	for i in range(1, pts.size()):
		w.contracts.extend(pts[i])
	w.contracts.finish()
	if w.contracts.contracts.size() <= before:
		return ""
	var c: Contract = w.contracts.contracts[w.contracts.contracts.size() - 1]
	var out := "ring" if c.ring else (String(c.figure) if c.figure != &"" else "line")
	w.contracts.dismiss(c)
	return out


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(1)


func _move(p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = root.get_final_transform() * p
	ev.global_position = ev.position
	Input.parse_input_event(ev)
	await _frames(1)


func _test_locks() -> void:
	print("— закрытое в бою молчит (кампания, пройден только «Пустырь»)")
	Campaign.reset()
	await _world(true)
	var ring := _circle(Vector2(330, 360), 60.0)
	var eight := _eight(Vector2(380, 360), 110.0)
	var tri := _ngon(Vector2(380, 360), 3, 75.0)
	var square := _ngon(Vector2(380, 360), 4, 75.0)
	_check(_draw(ring) == "line", "кольцо до «Развилки» — обычная линия")
	_check(_draw(eight) == "line", "восьмёрка до «Архива» — обычная линия")
	_check(_draw(tri) == "line", "треугольник до «Моста» — обычная линия")
	_check(_draw(square) == "line", "квадрат до «Болота» — обычная линия")
	_check(w.hero != null and w.hero.is_unlocked(LegionHero.SLOT_Q)
			and not w.hero.is_unlocked(LegionHero.SLOT_W) and not w.hero.is_unlocked(LegionHero.SLOT_E),
		"Ку есть, Дубль-вэ и Е молчат")
	_check(not w.contracts.set_kind(LegionCfg.KIND_GUARD), "вахтёр не выбирается")
	_check(w.rally(w.cauldron_pos) < 0, "«Сбор» (R) закрыт — никого не зовёт")
	# Пробел не вертит стрелку живого договора
	var pts := PackedVector2Array([Vector2(320, 300), Vector2(320, 420)])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false)
	var d0 := c.dir
	var mid := c.point_at(c.length * 0.5)
	await _move(mid)
	await _key(KEY_SPACE, true)
	for i in range(1, 7):
		await _move(mid + d0.rotated(deg_to_rad(12.0 * i)) * 80.0)
	await _key(KEY_SPACE, false)
	_check(absf(rad_to_deg(d0.angle_to(c.dir))) < 1.0,
		"Пробел до «Проходной» стрелку не вертит (%.0f°)" % rad_to_deg(d0.angle_to(c.dir)))
	var f := w.spawn_foe("zombie", "north", {})
	_check(not w.items.roll_elite(f, true), "элитных до «Архива» нет (даже гарантированный)")

	print("— по мере карт открывается")
	Campaign.record_result("wasteland", true, 0.9)
	Campaign.record_result("gatehouse", true, 0.9)
	await _world(true)
	_check(_draw(_circle(Vector2(330, 360), 60.0)) == "ring", "на «Развилке» кольцо признаётся")
	_check(_draw(eight) == "line", "восьмёрка на «Развилке» ещё линия")
	_check(_draw(square) == "line", "квадрат на «Развилке» — линия, а не «Оцепление» (B-069)")
	_check(w.hero.is_unlocked(LegionHero.SLOT_W) and w.hero.is_unlocked(LegionHero.SLOT_E),
		"на «Развилке» Дубль-вэ и Е открыты")
	_check(w.rally(w.cauldron_pos) >= 0, "«Сбор» с «Проходной» работает")

	print("— вне кампании открыто всё")
	Campaign.reset()
	await _world(false)
	_check(_draw(_circle(Vector2(330, 360), 60.0)) == "ring" and _draw(eight) == "eight"
			and _draw(tri) == "triangle" and _draw(square) == "square",
		"кольцо, восьмёрка, треугольник, квадрат признаются")
	_check(w.hero.is_unlocked(LegionHero.SLOT_W) and w.contracts.set_kind(LegionCfg.KIND_GUARD),
		"Дубль-вэ и вахтёр доступны")
