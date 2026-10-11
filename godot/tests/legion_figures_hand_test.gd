extends SceneTree
##
## B-490 (Игорь 11.10, живая игра): «Пятиугольник не работает. Работает как оцепление», затем
## «Буква D тоже сложно рисуется — нужно исправлять с фигурами общую проблему». Рукописные штрихи
## всех фигур — одна модель руки (tests/hand_strokes.gd: неровная форма, скруглённые углы, начало
## где угодно, зазор 10–25 px, 40–120 точек, у углов рука медленнее):
##  1) настоящий ввод мыши (Input.parse_input_event, как legion_drawing_input_test): кольцо,
##     восьмёрка, треугольник, квадрат, пятиугольник, «D» — каждая фигура ≥ 90 % своей.
##     До правки пятиугольник ~45 % и «D» ~50 % уходили в кольцо;
##  2) крупная выборка через classify: каждая фигура ≥ 90 % своей, в чужую угловую фигуру — не
##     больше 1 %; круги и вытянутые овалы — ни одной угловой фигуры; круг из 6–12 точек на оборот
##     (неотличим и глазом) пятиугольником — единицы;
##  3) ровный пятиугольник и ровная «D», начатые посреди прямого ребра, — свои фигуры (раньше
##     начало штриха рвало ребро: два угла пятиугольника сливались, «D» теряла прямую сторону);
##  4) кампания до «Кладбищенского лабиринта»: пятиугольник ещё закрыт — штрих ложится обычной
##     линией (не кольцом), и у пера подпись, где фигура откроется.
##
##   "$GODOT" --headless --fixed-fps 60 --path godot
##       --script res://tests/legion_figures_hand_test.gd -- --mute
##
## Итог «LEGION FIGURES HAND: N/M OK»; код выхода 1, если что-то упало.
##

const HandStrokes := preload("res://tests/hand_strokes.gd")
const SAVE := "user://legion_figures_hand_test.cfg"
const DEVICE := 79
const CENTER := Vector2(640.0, 360.0)
const KINDS: Array[StringName] = [&"ring", &"eight", &"triangle", &"square", &"pentagon",
	&"d_shape"]
const CORNER_KINDS: Array[StringName] = [&"triangle", &"square", &"pentagon", &"d_shape"]
## Штрихов на фигуру настоящим вводом и через classify.
const INPUT_N := 25
const BULK_N := 300
const ROUND_N := 1000

var w: LegionWorld
var f: ContractField
var _checks := 0
var _fails := 0
var _gen: RefCounted = HandStrokes.new()


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  ok   ", label)
	else:
		_fails += 1
		print("  FAIL ", label)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "spawn_foes": "0"}
	w.start_map("_gray")
	f = w.contracts
	_test_input()
	_test_bulk()
	_test_mid_edge()
	_test_locked()
	for side in w.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	w.queue_free()
	await process_frame
	await process_frame
	w = null
	Campaign.reset()
	print("LEGION FIGURES HAND: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Ввод ─────────────────────────────────────────────────────────────────────

func _fresh() -> void:
	Input.flush_buffered_events()
	w.set_paused(false)
	w.net_mode = false
	w.net_applying = false
	w.terrain = LegionTerrain.new().setup({"size": [1280, 720]})
	f.cancel_gestures()
	f.setup(w)
	f.active = true
	f.human_input = true
	f.press_consumer = Callable()
	f.mana = f.mana_max
	f._wall_fx.clear()
	f._wall_ms = -1000000


func _button(at: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _motion(at: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.relative = relative
	event.screen_relative = relative
	Input.parse_input_event(event)


## Штрих рукой: нажатие, движения, отпускание. Вернёт новый договор или null.
func _draw(points: PackedVector2Array) -> Contract:
	var before := f.contracts.size()
	_button(points[0], true)
	for i in range(1, points.size()):
		_motion(points[i], points[i] - points[i - 1])
	Input.flush_buffered_events()
	_button(points[points.size() - 1], false)
	return f.contracts[-1] if f.contracts.size() > before else null


static func _kind(c: Contract) -> String:
	if c == null:
		return "нет договора"
	if c.ring:
		return "ring"
	return String(c.figure) if c.figure != &"" else "линия"


func _dense(vertices: PackedVector2Array, step: float) -> PackedVector2Array:
	var points := PackedVector2Array([vertices[0]])
	for i in range(1, vertices.size()):
		var n := maxi(1, ceili(vertices[i - 1].distance_to(vertices[i]) / step))
		for k in range(1, n + 1):
			points.append(vertices[i - 1].lerp(vertices[i], float(k) / n))
	return points


# ── 1. Настоящий ввод ────────────────────────────────────────────────────────

func _test_input() -> void:
	print("— рукописные фигуры настоящим вводом мыши")
	for kind in KINDS:
		_gen.rng.seed = 490 + KINDS.find(kind)
		var got := {}
		for i in INPUT_N:
			_fresh()
			var k := _kind(_draw(_gen.stroke(kind)))
			got[k] = int(got.get(k, 0)) + 1
		var own := int(got.get(String(kind), 0))
		_check(own >= INPUT_N * 0.9, "%s рукой → своя фигура %d из %d (≥ 90 %%): %s"
			% [kind, own, INPUT_N, str(got)])


# ── 2. Крупная выборка и путаница ────────────────────────────────────────────

func _test_bulk() -> void:
	print("— крупная выборка (classify), матрица путаницы")
	for kind in KINDS:
		_gen.rng.seed = 4900 + KINDS.find(kind)
		var got := {}
		for i in BULK_N:
			var k := String(ContractShape.classify(_gen.stroke(kind)))
			got[k] = int(got.get(k, 0)) + 1
		var own := int(got.get(String(kind), 0))
		var alien := 0
		for other in CORNER_KINDS:
			if other != kind:
				alien += int(got.get(String(other), 0))
		_check(own >= BULK_N * 0.9 and alien <= BULK_N * 0.01,
			"%s: своя %d из %d (≥ 90 %%), в чужую угловую %d (≤ 1 %%): %s"
			% [kind, own, BULK_N, alien, str(got)])
	for kind: StringName in [&"ring", &"oval"]:
		_gen.rng.seed = 4950 + (1 if kind == &"oval" else 0)
		var corner := 0
		var ring := 0
		for i in ROUND_N:
			var k := ContractShape.classify(_gen.stroke(kind))
			corner += 1 if CORNER_KINDS.has(k) else 0
			ring += 1 if k == ContractShape.RING else 0
		_check(corner == 0 and ring >= ROUND_N * 0.99,
			"%s рукой: кольцо %d из %d, угловых фигур %d" % [kind, ring, ROUND_N, corner])
	# 6–12 точек на весь оборот: такую ломаную и глазом не отличить от многоугольника — цена
	# PENTA_TIP_MIN 55° (замер 11.10: ~0,4 % против ~0,03 % при 65°); держим её «единицами»
	var rng := RandomNumberGenerator.new()
	rng.seed = 4901
	var penta := 0
	var m := 300
	for i in m:
		var r := rng.randf_range(60.0, 130.0)
		var a0 := rng.randf() * TAU
		var sweep := TAU * rng.randf_range(0.97, 1.03)
		var cnt := rng.randi_range(6, 12)
		var pts := PackedVector2Array()
		for q in cnt + 1:
			var a := a0 + sweep * (q + rng.randf_range(-0.2, 0.2) * float(q > 0 and q < cnt)) / cnt
			pts.append(CENTER + Vector2.from_angle(a) * r
				+ Vector2(rng.randf_range(-1.5, 1.5), rng.randf_range(-1.5, 1.5)))
		penta += 1 if ContractShape.classify(pts) == ContractShape.PENTAGON else 0
	_check(penta <= 4, "круг из 6–12 точек пятиугольником: %d из %d (≤ 4)" % [penta, m])


# ── 3. Начало посреди прямого ребра ──────────────────────────────────────────

func _test_mid_edge() -> void:
	print("— штрих, начатый посреди прямого ребра")
	_fresh()
	var v := PackedVector2Array()
	for i in 5:
		v.append(CENTER + Vector2.from_angle(-PI * 0.5 + TAU * i / 5.0) * 95.0)
	var mid := PackedVector2Array([v[0].lerp(v[1], 0.5)])
	for i in range(1, 6):
		mid.append(v[i % 5])
	mid.append(v[0].lerp(v[1], 0.42))
	var c := _draw(_dense(mid, 7.0))
	_check(_kind(c) == "pentagon",
		"ровный пятиугольник, начатый с середины ребра → «%s»" % _kind(c))
	# «D»: от середины прямой стороны вверх, дуга вправо и вниз, назад к середине с зазором
	_fresh()
	var r := 85.0
	var d := PackedVector2Array([CENTER, CENTER + Vector2(0, -r)])
	for k in range(1, 25):
		var a := -PI * 0.5 + PI * k / 24.0
		d.append(CENTER + Vector2(cos(a), sin(a)) * r)
	d.append(CENTER + Vector2(0, 14))
	c = _draw(_dense(d, 7.0))
	_check(_kind(c) == "d_shape", "ровная «D», начатая с середины прямой стороны → «%s»" % _kind(c))


# ── 4. Пятиугольник ещё не открыт кампанией ──────────────────────────────────

func _test_locked() -> void:
	print("— кампания до «Кладбищенского лабиринта»")
	Campaign.reset()
	Campaign._file().set_value("progress", "unlocked", ["gatehouse", "fork", "archive", "bridge"])
	Campaign._mods_cache_valid = false
	w.in_campaign = true
	_fresh()
	_check(bool(f.shapes.get(ContractShape.RING, false))
		and not bool(f.shapes.get(ContractShape.PENTAGON, true)),
		"до «Лабиринта» кольцо открыто, пятиугольник — нет")
	var v := PackedVector2Array()
	for i in 6:
		v.append(CENTER + Vector2.from_angle(-PI * 0.5 + TAU * (i % 5) / 5.0) * 90.0)
	var pts := _dense(v, 7.0)
	_check(ContractShape.classify(pts) == ContractShape.PENTAGON, "контрольный штрих — пятиугольник")
	var c := _draw(pts)
	_check(_kind(c) == "линия", "закрытый пятиугольник ложится линией, не кольцом: «%s»" % _kind(c))
	var label := String(f._wall_fx[-1]["label"]) if not f._wall_fx.is_empty() else ""
	_check(label.contains(FigureCfg.PENTA_LABEL) and label.contains("Кладбищенский лабиринт"),
		"у пера подпись, где откроется фигура: «%s»" % label)
	# открытая карта «Лабиринт» — тот же штрих уже «Комиссия», подписи-замка нет
	Campaign._file().set_value("progress", "unlocked",
		["gatehouse", "fork", "archive", "bridge", "maze"])
	Campaign._mods_cache_valid = false
	_fresh()
	c = _draw(pts)
	_check(_kind(c) == "pentagon" and f._wall_fx.is_empty(),
		"«Лабиринт» открыт — тот же штрих «Комиссия» без подписи: «%s»" % _kind(c))
	w.in_campaign = false
	Campaign.reset()
