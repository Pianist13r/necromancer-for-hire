extends SceneTree
##
## Регресс «линии цвета бойца» (Игорь 26.09.2026: «Линии должны быть красивее и по цвету
## совпадать с моделькой персонажа, которого призывают»):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_lines_test.gd -- --mute
##
## 1) характерный цвет вида, записанный в LegionCfg.UNIT_KINDS[kind]["sprite"], совпадает с
##    замером по НАСТОЯЩИМ кадрам бойца (тот же алгоритм, что tools/kind_colors.py);
## 2) палитра линии (ContractField.line_palette) — это цвет вида из cfg, и её оттенок — оттенок
##    спрайта (сдвиг не больше HUE_TOL), насыщенность не ниже спрайта;
## 3) три вида различимы между собой (ΔE в OKLab не меньше KIND_DE_MIN), а тело линии не путается
##    с цветами предупреждений (давка, разрыв и телеграф Юриста, тревожная стрелка, подрисовка);
## 4) полная графика рисует линию с течением, рождением и растворением; экономная — ту же линию
##    без течения и частиц, без ошибок;
## 5) бой бота с отрисовкой линий совпадает до числа в полной и экономной графике.
## Итог «LEGION LINES: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_lines_test.cfg"
const WORLD_SCENE := "res://scenes/legion_world.tscn"
const DT := 1.0 / 60.0
const BATTLE_S := 40.0
## Кадры видов: подрядчик — прежний скелет, у вахтёра и счетовода — свои (unit.gd setup).
const CHAR_IDS := {&"laborer": "skeleton", &"guard": "guard", &"clerk": "clerk"}
## Пороги замера — как в tools/kind_colors.py.
const MIN_ALPHA := 200.0 / 255.0
const MIN_SAT := 0.30
const MIN_VAL := 0.33
const BINS := 24
const PIXEL_STEP := 2
## Допуски: замер по прореженной сетке против записанного — почти ноль; оттенок линии может
## уйти от спрайта не больше HUE_TOL (сдвиг ради предупреждений), виды — не ближе KIND_DE_MIN.
const SPRITE_DE_TOL := 0.03
const HUE_TOL := 12.0
const KIND_DE_MIN := 0.2
const WARN_DE_MIN := 0.1

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
	var args := OS.get_cmdline_user_args()
	var export_index := args.find("--export-sources")
	if export_index >= 0 and export_index + 1 < args.size():
		var file := FileAccess.open(args[export_index + 1], FileAccess.WRITE)
		if file == null:
			quit(1)
			return
		file.store_string(JSON.stringify(color_sources(), "\t"))
		file.close()
		quit(0)
		return
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_test_sprite_colors()
	_test_palette()
	_test_distinct()
	if "--colors-only" in args:
		print("LEGION LINE COLORS: %d/%d OK" % [_checks - _fails, _checks])
		quit(1 if _fails > 0 else 0)
		return
	await _test_draw(false)
	await _test_draw(true)
	await _test_battle_equal()
	Settings.economy_override = ""
	Campaign.reset()
	print("LEGION LINES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── цвет спрайта ────────────────────────────────────────────────────────────

## Доминирующий насыщенный цвет всех кадров вида: корзины оттенка по 15°, кость/рубашка
## (низкая насыщенность) и контур (тёмное) отброшены. Возвращает средний цвет самой большой корзины.
static func clip_dirs(char_id: String) -> Array[String]:
	var result: Array[String] = []
	var clips: Dictionary = CfgAnim.char_def(char_id).get("clips", {})
	for clip: Dictionary in clips.values():
		var variants: Array = [clip]
		variants.append_array((clip.get("directions", {}) as Dictionary).values())
		for variant: Dictionary in variants:
			var dir := String(variant.get("dir", ""))
			if dir != "" and dir not in result:
				result.append(dir)
	result.sort()
	return result


## Python-инструмент получает разрешённые клипы от самого CfgAnim, без парсера GDScript.
static func color_sources() -> Dictionary:
	var kinds := {}
	for kind: StringName in CHAR_IDS:
		kinds[String(kind)] = {"char_id": CHAR_IDS[kind], "dirs": clip_dirs(CHAR_IDS[kind])}
	var characters := {}
	for char_id: String in CfgAnim.CHARS:
		var fallback: Array[String] = []
		for item: Dictionary in CfgAnim.char_def(char_id).get("fallback", {}).values():
			var path := String(item.get("tex", ""))
			if path != "" and path not in fallback:
				fallback.append(path)
		characters[char_id] = {"dirs": clip_dirs(char_id), "fallback": fallback}
	return {"kinds": kinds, "characters": characters}


static func measure_sprite(char_id: String) -> Color:
	var sums: Array[Vector4] = []
	sums.resize(BINS)
	sums.fill(Vector4.ZERO)
	for dir: String in clip_dirs(char_id):
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f in d.get_files():
			if not f.begins_with("spr_") or not f.ends_with(".png"):
				continue
			var img := Image.load_from_file(ProjectSettings.globalize_path(dir.path_join(f)))
			if img == null:
				continue
			for y in range(0, img.get_height(), PIXEL_STEP):
				for x in range(0, img.get_width(), PIXEL_STEP):
					var c := img.get_pixel(x, y)
					if c.a < MIN_ALPHA or c.s < MIN_SAT or c.v < MIN_VAL:
						continue
					var k := int(c.h * BINS) % BINS
					sums[k] += Vector4(c.r, c.g, c.b, 1.0)
	var best := Vector4.ZERO
	for v in sums:
		if v.w > best.w:
			best = v
	if best.w <= 0.0:
		return Color.BLACK
	return Color(best.x / best.w, best.y / best.w, best.z / best.w)


func _test_sprite_colors() -> void:
	print("— записанный цвет вида = замер по кадрам бойца")
	for kind: StringName in LegionCfg.KIND_ORDER:
		var spec: Dictionary = LegionCfg.UNIT_KINDS[kind]
		var measured := measure_sprite(String(CHAR_IDS[kind]))
		var has := spec.has("sprite")
		var recorded: Color = spec.get("sprite", Color.BLACK)
		var de := oklab_de(measured, recorded)
		print("    %s: замер %s, в cfg %s, ΔE %.3f" % [kind, _hex(measured), _hex(recorded), de])
		_check(has and de <= SPRITE_DE_TOL, "%s: cfg[sprite] совпадает с кадрами (ΔE ≤ %.2f)"
			% [kind, SPRITE_DE_TOL])


# ── палитра линии ───────────────────────────────────────────────────────────

## Через call(): на старом коде метода нет, и тест должен упасть проверкой, а не разбором.
static func _palette(kind: StringName) -> Dictionary:
	var probe := ContractField.new()
	var pal: Dictionary = probe.call("line_palette", kind) if probe.has_method("line_palette") else {}
	probe.free()
	return pal


func _test_palette() -> void:
	print("— палитра линии выведена из цвета бойца")
	for kind: StringName in LegionCfg.KIND_ORDER:
		var spec: Dictionary = LegionCfg.UNIT_KINDS[kind]
		var pal := _palette(kind)
		_check(not pal.is_empty(), "%s: ContractField.line_palette есть" % kind)
		if pal.is_empty() or not spec.has("sprite"):
			continue
		var body: Color = pal["body"]
		var sprite: Color = spec["sprite"]
		_check(body == spec["color"] and pal["core"] == spec["core"],
			"%s: тело/сердцевина линии — цвет вида из cfg (карточки, стрелка, кольцо — те же)" % kind)
		var dh := _hue_diff(body.h, sprite.h) * 360.0
		print("    %s: линия %s (оттенок %.0f°), спрайт %s (%.0f°), сдвиг %.1f°"
			% [kind, _hex(body), body.h * 360.0, _hex(sprite), sprite.h * 360.0, dh])
		_check(dh <= HUE_TOL, "%s: оттенок линии = оттенок бойца (±%.0f°)" % [kind, HUE_TOL])
		_check(body.s >= sprite.s * 0.95, "%s: линия не бледнее бойца" % kind)
		_check(pal["core"].v > body.v or pal["core"].get_luminance() > body.get_luminance(),
			"%s: сердцевина светлее тела" % kind)


func _test_distinct() -> void:
	print("— виды различимы, предупреждения не путаются с линией")
	var kinds := LegionCfg.KIND_ORDER
	for i in kinds.size():
		for j in range(i + 1, kinds.size()):
			var a: Color = LegionCfg.UNIT_KINDS[kinds[i]]["color"]
			var b: Color = LegionCfg.UNIT_KINDS[kinds[j]]["color"]
			var de := oklab_de(a, b)
			_check(de >= KIND_DE_MIN, "%s ~ %s: ΔE %.3f ≥ %.2f" % [kinds[i], kinds[j], de, KIND_DE_MIN])
	var warns := {
		"давка PRESS_COLOR": LegionCfg.PRESS_COLOR, "разрыв LAWYER_TEAR": LegionCfg.LAWYER_TEAR_COLOR,
		"Юрист LAWYER_COLOR": LegionCfg.LAWYER_COLOR, "стрелка ARROW_WARN": ContractField.ARROW_WARN,
		"подрисовка REFRESH": ContractField.REFRESH_COLOR,
	}
	for kind: StringName in kinds:
		var body: Color = LegionCfg.UNIT_KINDS[kind]["color"]
		var worst := INF
		var worst_name := ""
		for name: String in warns:
			var de := oklab_de(body, warns[name])
			if de < worst:
				worst = de
				worst_name = name
		_check(worst >= WARN_DE_MIN, "%s: ближайшее предупреждение %s, ΔE %.3f ≥ %.2f"
			% [kind, worst_name, worst, WARN_DE_MIN])


# ── отрисовка ───────────────────────────────────────────────────────────────

func _test_draw(economy: bool) -> void:
	var label := "экономная" if economy else "полная"
	print("— отрисовка линий: ", label)
	Settings.economy_override = "on" if economy else "off"
	var w := load(WORLD_SCENE).instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	var f := w.contracts
	var made: Array[Contract] = []
	var y := 200.0
	for kind: StringName in LegionCfg.KIND_ORDER:
		var pts := PackedVector2Array()
		for i in 9:
			pts.append(Vector2(300.0 + i * 20.0, y + sin(i * 0.7) * 8.0))
		var c := f.add_contract(pts, 1, false, kind)
		_check(c != null, "%s: договор %s создан" % [label, kind])
		if c != null:
			made.append(c)
		y += 120.0
	if made.size() != 3 or not f.has_method("birth_k"):
		_check(false, "%s: у поля есть визуальный слой линий (birth_k/fading_count)" % label)
		w.queue_free()
		await process_frame
		return
	await _render(w, 2)
	var k0 := float(f.call("birth_k", made[0]))
	_check(int(f.get("drawn_lines")) == 3, "%s: нарисовано 3 линии" % label)
	if economy:
		_check(int(f.get("drawn_flow")) == 0, "экономная: течения нет")
		_check(is_equal_approx(k0, 1.0), "экономная: рождение без анимации")
	else:
		_check(int(f.get("drawn_flow")) > 0, "полная: течение энергии рисуется")
		_check(k0 > 0.0 and k0 < 1.0, "полная: линия рождается (k=%.2f)" % k0)
	await _render(w, 60)
	_check(is_equal_approx(float(f.call("birth_k", made[0])), 1.0), "%s: рождение закончилось" % label)
	# выпуск участка — растворение (полная) или сразу исчезновение (экономная)
	f.release(made[1], 0)
	await _render(w, 2)
	var fading := int(f.call("fading_count"))
	if economy:
		_check(fading == 0, "экономная: растворения нет")
	else:
		_check(fading > 0, "полная: выпущенный участок растворяется (%d)" % fading)
	# продление части участков: возрасты расходятся, линия рисуется прогонами (склейка кусков)
	_check(f.refresh(made[1], PackedInt32Array([2]), false), "%s: продление участка 2" % label)
	await _render(w, 2)
	_check(int(f.get("drawn_lines")) == 3, "%s: после частичного продления — те же 3 линии" % label)
	# снять договор целиком (как обучение) — все живые участки растворяются
	f.dismiss(made[2])
	await _render(w, 2)
	if not economy:
		_check(int(f.call("fading_count")) > fading, "полная: снятый договор тоже растворяется")
	await _render(w, 90)
	_check(int(f.call("fading_count")) == 0, "%s: растворение закончилось и не копится" % label)
	_check(int(f.get("drawn_lines")) == 2, "%s: осталось 2 линии" % label)
	# последние секунды срока: мигание остаётся читаемым, течение на мигающих участках гаснет
	# (энергия «уходит» из договора — второй сигнал того же)
	var flow_before := int(f.get("drawn_flow"))
	made[0].seg_age.fill(made[0].ttl - 1.5)
	var a_min := 1.0
	for i in 12:
		await _render(w, 1)
		a_min = minf(a_min, f._seg_alpha(made[0], 0))
	_check(a_min < 0.6, "%s: мигание перед таянием глубокое (мин. альфа %.2f)" % [label, a_min])
	if not economy:
		_check(int(f.get("drawn_flow")) < flow_before,
			"полная: на мигающей линии течение гаснет (%d → %d)" % [flow_before, int(f.get("drawn_flow"))])
	w.queue_free()
	await process_frame
	Settings.economy_override = ""


## Шаг мира + настоящий кадр (в безголовом прогоне _draw тоже вызывается).
func _render(w: LegionWorld, frames: int) -> void:
	for i in frames:
		w._step(DT)
		await process_frame


# ── бой одинаков ────────────────────────────────────────────────────────────

func _test_battle_equal() -> void:
	print("— бой с отрисовкой линий одинаков в обеих графиках")
	var full := await _battle_with(false)
	var eco := await _battle_with(true)
	print("    полная: ", full)
	print("    экономная: ", eco)
	_check(int(full.get("kills", 0)) > 0, "в бою были убитые (%d)" % int(full.get("kills", 0)))
	var made := int(full.get("contracts", 0))
	_check(made > 0, "бот чертил договоры (%d)" % made)
	_check(full == eco, "итоги мира совпадают")


func _battle_with(economy: bool) -> Dictionary:
	Settings.economy_override = "on" if economy else "off"
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var world := load(WORLD_SCENE).instantiate() as LegionWorld
	root.add_child(world)
	await process_frame
	world.set_process(false)
	world.args["bot"] = "selective"
	seed(7)
	world.start_map("fork")
	var made := 0
	for k in roundi(BATTLE_S / DT):
		world._step(DT)
		made = maxi(made, world.contracts.contracts.size())
		if k % 6 == 0:
			await process_frame   # линии рисуются посреди боя — вид не должен трогать симуляцию
		if world.phase != LegionWorld.Phase.BATTLE:
			break
	var result := {"t": snappedf(world.now, 0.001), "kills": int(world.stats["kills"]),
		"lost": int(world.stats["lost"]), "hp": snappedf(world.cauldron_hp, 0.001),
		"units": world.army_alive(), "foes": world.foes.size(), "souls": world.souls,
		"mana": snappedf(world.contracts.mana, 0.001), "rng": world.rng.state,
		"contracts": made, "rnd": randi()}
	world.queue_free()
	await process_frame
	Settings.economy_override = ""
	Campaign.reset()
	return result


# ── цветовая математика ─────────────────────────────────────────────────────

## Расстояние в OKLab: равные шаги — равная заметность для глаза (RGB врёт в жёлто-зелёном).
static func oklab_de(a: Color, b: Color) -> float:
	return _oklab(a).distance_to(_oklab(b))


static func _oklab(c: Color) -> Vector3:
	var lin := c.srgb_to_linear()
	var l := 0.4122214708 * lin.r + 0.5363325363 * lin.g + 0.0514459929 * lin.b
	var m := 0.2119034982 * lin.r + 0.6806995451 * lin.g + 0.1073969566 * lin.b
	var s := 0.0883024619 * lin.r + 0.2817188376 * lin.g + 0.6299787005 * lin.b
	l = pow(l, 1.0 / 3.0)
	m = pow(m, 1.0 / 3.0)
	s = pow(s, 1.0 / 3.0)
	return Vector3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


static func _hue_diff(a: float, b: float) -> float:
	var d := absf(a - b)
	return minf(d, 1.0 - d)


static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)
