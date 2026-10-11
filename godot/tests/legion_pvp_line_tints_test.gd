extends SceneTree
##
## «Схватка»: линии сторон отличаются оттенком (Игорь 10.10.2026: «в мультиплеере нужно, чтобы
## линии оттенками отличались, чтобы они не путались»; ветка slow/pvp-line-tints).
##  1) одиночка — цвета линий ровно LegionCfg.UNIT_KINDS (и растворение участка), фигуры прежние;
##  2) PvP, local_side 0 (против бота / хост) — поле 0 родное, поле 1 сдвинуто для каждого вида и
##     части (тело, сердцевина), светлота Okhsl та же; растворение участка соперника — его цветом;
##  3) PvP, local_side 1 (клиент) — родные цвета у поля 1, сдвиг у поля 0;
##  4) виды соперника между собой различимы не хуже порога (тон Okhsl).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_line_tints_test.gd -- --mute
##
## Итог «LEGION PVP LINE TINTS: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pvp_line_tints_test.cfg"
const DUEL := "pvp:duel"
const PARTS := ["color", "core"]
## Порог различимости видов соперника между собой: доля круга тона Okhsl (≈ 43°).
const MIN_KIND_HUE_GAP := 0.12

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


func _start(map_id: String) -> void:
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w._base_seed = 7
	w.start_map(map_id)
	await _frames(3)


## Цвет линии вида на поле. Старый код (до ветки) метода не знает — тогда цвет вида как есть:
## тест падает проверками, а не разбором скрипта.
func _col(f: ContractField, kind: StringName, part: String) -> Color:
	if f.has_method(&"line_color"):
		return f.call(&"line_color", kind, part)
	return ContractField._kind_color(kind, part)


## Цвет растворения участка — по настоящему пути отрисовки (ContractField._fade).
func _fade_body(f: ContractField, kind: StringName) -> Color:
	var c := Contract.new()
	c.kind = kind
	c.points = PackedVector2Array([Vector2(700, 400), Vector2(800, 400)])
	c.seg_polys = [PackedVector2Array([Vector2(700, 400), Vector2(800, 400)])]
	c.seg_bend = PackedFloat32Array([0.0])
	f._fading.clear()
	f._fade(c, 0)
	var body: Color = f._fading[0]["body"] if not f._fading.is_empty() else Color.BLACK
	f._fading.clear()
	return body


func _native(f: ContractField, label: String) -> void:
	for k in LegionCfg.KIND_ORDER:
		for p in PARTS:
			var want: Color = LegionCfg.UNIT_KINDS[k][p]
			_check(_col(f, k, p) == want, "%s: %s/%s — родной цвет" % [label, k, p])
		_check(_fade_body(f, k) == LegionCfg.UNIT_KINDS[k]["color"],
			"%s: растворение %s — родной цвет" % [label, k])


func _rival(f: ContractField, label: String) -> void:
	for k in LegionCfg.KIND_ORDER:
		for p in PARTS:
			var own: Color = LegionCfg.UNIT_KINDS[k][p]
			var got := _col(f, k, p)
			_check(not got.is_equal_approx(own), "%s: %s/%s сдвинут (%s → %s)" % [label, k, p, own, got])
			_check(absf(got.ok_hsl_l - own.ok_hsl_l) < 0.01,
				"%s: %s/%s — светлота та же (%.3f / %.3f)" % [label, k, p, own.ok_hsl_l, got.ok_hsl_l])
		var fb := _fade_body(f, k)
		_check(fb.is_equal_approx(_col(f, k, "color")) and not fb.is_equal_approx(
			LegionCfg.UNIT_KINDS[k]["color"]), "%s: растворение %s — цветом соперника" % [label, k])


func _hue_gap(a: float, b: float) -> float:
	var d := absf(a - b)
	return minf(d, 1.0 - d)


func _test_single() -> void:
	print("— одиночка: цвета прежние")
	await _start("_gray")
	_check(not w.pvp, "PvP выключен")
	_native(w.contracts, "одиночка")
	_check(not w.contracts.has_method(&"fig_line_color") or w.contracts.call(&"fig_line_color",
		ContractShape.TRIANGLE) == FigureCfg.TRI_COLOR, "одиночка: фигура прежнего цвета")


func _test_host() -> void:
	print("— Схватка, local_side 0 (против бота / хост)")
	await _start(DUEL)
	_check(w.pvp and w.sides.size() == 2 and w.local_side == 0, "дуэль, сторона экрана 0")
	_native(w.sides[0].contracts, "хост: своё поле 0")
	_rival(w.sides[1].contracts, "хост: поле соперника 1")
	var hues: Array[float] = []
	for k in LegionCfg.KIND_ORDER:
		hues.append(_col(w.sides[1].contracts, k, "color").ok_hsl_h)
	var gap := 1.0
	for i in hues.size():
		for j in range(i + 1, hues.size()):
			gap = minf(gap, _hue_gap(hues[i], hues[j]))
	_check(gap >= MIN_KIND_HUE_GAP,
		"виды соперника различимы между собой: мин. разрыв тона %.3f" % gap)


func _test_client() -> void:
	print("— Схватка, local_side 1 (клиент сети)")
	w.local_side = 1   # как у клиента после start_net (свойство читается вживую при отрисовке)
	_native(w.sides[1].contracts, "клиент: своё поле 1")
	_rival(w.sides[0].contracts, "клиент: поле соперника 0")
	w.local_side = 0


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _frames(2)
	await _test_single()
	await _test_host()
	await _test_client()
	await _test_single()
	Campaign.reset()
	print("LEGION PVP LINE TINTS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
