# gdlint: disable=max-returns
extends SceneTree
##
## Зеркальность БОЯ «Схватки» (B-365): отражённая позиция даёт отражённый бой.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_mirror_battle_test.gd -- --mute
##
## Поле PvP — зеркало x' = W − x, но статическая зеркальность (legion_pvp_mirror_test) не ловит
## асимметрию ХОДА боя: рождение бойцов, «Сбор», носители артефактов. Здесь бой бот-против-бота
## идёт как есть (мир A); каждые SAMPLE_EVERY шагов снимается снимок (NetSnap) S и снимок через
## STEPS шагов. Мир B — та же карта со сменой сторон (сторона 0 справа, --dev pvp_swap=1) —
## грузит ОТРАЖЁННЫЙ S и делает те же STEPS шагов; его снимок, отражённый обратно, должен
## совпасть со снимком A (допуск TOL px — float32 у x и у W − x округляется по-разному).
## Сравнение — шагом из настоящих состояний, а не целым матчем: бой хаотичен, и шум float за
## минуту вырастает до пикселя, а сдвиг в один пиксель меняет исход порогов (дошёл/не дошёл).
##
## Контроль метода: тот же снимок в мир A без отражения — совпадение побитово.
## Итог «LEGION PVP MIRROR BATTLE: N/M OK»; выход 1 при провале.
##

const SAVE := "user://legion_pvp_mirror_battle_test.cfg"
## [карта, сид, до какого шага]: «Дуэль» — рождение, «Сбор», первые перебежки; gen-поле — ещё и
## носители на оси стыка (12 с) и у прохода (35 с).
const RUNS := [["pvp:duel", 3, 4500], ["gen:11:3:pvp", 2, 3000]]
const SAMPLE_EVERY := 150
const STEPS := 20
const TOL := 0.05
const DT := 1.0 / 60.0

## Ключи снимка с координатами: точки (x → W − x), направления (x → −x), не координаты.
const POINT_KEYS := ["position", "pos", "points", "_seg_centers", "center", "lobes", "seg_polys",
	"tips", "pts", "entry", "_path", "ram_pos", "stamp_pos", "law_pos", "_ram_start",
	"cauldron_pos", "cauldron_view_pos"]
const DIR_KEYS := ["dir", "normal", "offset", "seg_bend_dir", "_charge_dir", "_dir"]
const KEEP_KEYS := ["world_size", "entry_ring", "lobe_span"]
## Не сравниваются: однокадровые буферы давки (пересчёт в шаге), рамки и куски ломаной участков
## (производные от points, число точек куска — порог float на границе участка), хэш карты
## (у смены сторон своя карта).
const SKIP_KEYS := ["press_sum", "press_mass", "seg_polys", "seg_press_box", "map_hash"]

var w: LegionWorld
var fw := 1600.0
var unknown := {}
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
	for r: Array in RUNS:
		_battle(String(r[0]), int(r[1]), int(r[2]))
	_check(unknown.is_empty(), "все координаты снимка известны отражению (новые: %s)" % [
		unknown.keys()])
	Campaign.reset()
	print("LEGION PVP MIRROR BATTLE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _start(id: String, seed_value: int, swap: bool) -> void:
	w.dev = {"pvp_swap": "1"} if swap else {}
	w.args["pvp_bots"] = true
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = seed_value
	w.start_map(id)


## Снимок отдельной копией: снимок делит упакованные массивы с живым миром, а загрузка — со
## словарём снимка (шаг мира после load_snapshot правил бы сохранённый снимок).
func _snap() -> Dictionary:
	return bytes_to_var(var_to_bytes(w.snapshot()))


func _load(d: Dictionary) -> void:
	w.load_snapshot(bytes_to_var(var_to_bytes(d)))


func _steps(n: int) -> void:
	for i in n:
		w._process(DT)


func _battle(id: String, seed_value: int, until: int) -> void:
	print("— %s, сид %d" % [id, seed_value])
	_start(id, seed_value, false)
	fw = w.world_size.x
	var pairs: Array = []
	var i := 0
	while i < until and w.pvp_match.result.is_empty():
		if i > 0 and i % SAMPLE_EVERY == 0:
			var before := _snap()
			_steps(STEPS)
			pairs.append([i, before, _snap()])
			i += STEPS
			continue
		_steps(1)
		i += 1
	_check(pairs.size() >= 15, id + ": снимков боя %d" % pairs.size())
	# контроль: без отражения снимок воспроизводит бой
	var ctl: Array = pairs[pairs.size() / 2]
	_load(ctl[1])
	_steps(STEPS)
	var diffs: Array = []
	_cmp(ctl[2], _snap(), "", diffs)
	_check(diffs.is_empty(), id + ": контроль — снимок без отражения повторяет шаги (%s)" % [
		diffs.slice(0, 3)])
	var bad := 0
	var first := ""
	for p: Array in pairs:
		_start(id, seed_value, true)
		var cfg := SnapWorld.config(w)
		var mir: Dictionary = _mirror(p[1], "")
		mir["world"]["cfg"] = cfg
		_load(mir)
		_steps(STEPS)
		diffs = []
		_cmp(p[2], _mirror(_snap(), ""), "", diffs)
		if not diffs.is_empty():
			bad += 1
			if first == "":
				first = "шаг %d (%.1f с): %s" % [p[0], p[0] * DT, str(diffs.slice(0, 4))]
	var tail := "; первое — " + first if first != "" else ""
	_check(bad == 0, id + ": отражённый снимок — отражённый ход боя (%d снимков, расхождений %d%s)"
		% [pairs.size(), bad, tail])


func _mx(v: Vector2) -> Vector2:
	return Vector2(fw - v.x, v.y)


## Отражение снимка: точки, направления, сторона выпуска договора (±1 к хорде), имена дорог и
## площадок половин (s0_… ↔ s1_…: отражение кладёт левую площадку на правую).
func _mirror(v: Variant, key: String) -> Variant:
	if v is Dictionary:
		var out := {}
		var d: Dictionary = v
		for k in d:
			out[k] = _mirror(d[k], str(k))
		if d.has("owner_side") and d.has("side") and d.has("points"):
			out["side"] = -int(d["side"])
		return out
	if v is Array:
		var out := []
		for x in v:
			out.append(_mirror(x, key))
		return out
	if v is String:
		var sv: String = v
		if sv.begins_with("s0_"):
			return "s1_" + sv.substr(3)
		if sv.begins_with("s1_"):
			return "s0_" + sv.substr(3)
		return v
	if v is Vector2:
		return _mirror_vec(v, key)
	if v is PackedVector2Array:
		var o := PackedVector2Array()
		for p: Vector2 in v:
			o.append(_mirror_vec(p, key))
		return o
	if v is Rect2:
		var r: Rect2 = v
		return Rect2(fw - r.end.x, r.position.y, r.size.x, r.size.y)
	return v


func _mirror_vec(p: Vector2, key: String) -> Vector2:
	if key in POINT_KEYS:
		return _mx(p)
	if key in DIR_KEYS:
		return Vector2(-p.x, p.y)
	if not key in KEEP_KEYS and not key in SKIP_KEYS:
		unknown[key] = true
	return p


func _cmp(a: Variant, b: Variant, path: String, out: Array) -> void:
	if out.size() > 20:
		return
	if (a is float or a is int) and (b is float or b is int):
		if typeof(a) != typeof(b) or a is float:
			if not (is_inf(float(a)) and is_inf(float(b))) and absf(float(a) - float(b)) > TOL:
				out.append("%s: %s / %s" % [path, a, b])
			return
	if typeof(a) != typeof(b):
		out.append("%s: тип %s / %s" % [path, type_string(typeof(a)), type_string(typeof(b))])
		return
	if a is Dictionary:
		for k in a:
			if str(k) in SKIP_KEYS:
				continue
			if not (b as Dictionary).has(k):
				out.append("%s/%s: нет у отражения" % [path, k])
				continue
			_cmp(a[k], b[k], path + "/" + str(k), out)
		return
	if a is Array or a is PackedVector2Array or a is PackedFloat32Array or a is PackedInt32Array \
			or a is PackedFloat64Array or a is PackedInt64Array or a is PackedByteArray:
		if a.size() != b.size():
			out.append("%s: размер %d / %d" % [path, a.size(), b.size()])
			return
		for i in a.size():
			_cmp(a[i], b[i], "%s[%d]" % [path, i], out)
		return
	if a is Vector2:
		var va: Vector2 = a
		var vb: Vector2 = b
		var inf_ok := (is_inf(va.x) or is_inf(va.y)) and (is_inf(vb.x) or is_inf(vb.y))
		# значения по умолчанию у только что рождённых (ещё не читались): ZERO и RIGHT/LEFT
		var dflt := (va == Vector2.ZERO and vb == Vector2(fw, 0.0)) \
			or (va == Vector2.RIGHT and vb == Vector2.LEFT) or (va == Vector2.LEFT and vb == Vector2.RIGHT)
		if not inf_ok and not dflt and (absf(va.x - vb.x) > TOL or absf(va.y - vb.y) > TOL):
			out.append("%s: %s / %s" % [path, va, vb])
		return
	if a is Rect2:
		return
	if a != b:
		out.append("%s: %s / %s" % [path, str(a).left(60), str(b).left(60)])
