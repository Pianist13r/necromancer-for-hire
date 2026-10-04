extends SceneTree
##
## Регресс slow/notary-read 29.09 (ночь по переписке, дневник night-0929, находки 5 и 17):
## «красное кольцо печати стоит над кучей моих бойцов, а сам нотариус, который её ставит, не
## выделен» и «у щитовиков знак щита над головой постоянно голубой — тот же цвет, что голубой =
## оглушение». Только вид: механику боя тест не трогает.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_notary_read_test.gd -- --mute
##
## 1) знак щита — не оттенок смысла: ΔE до каждого цвета CfgFx.MEANING_COLOR ≥ MEANING_MIN_DE, а
##    цветной (не серый) — ещё и дальше HUE_MIN_DEG по тону от голубого оглушения;
## 2) нотариус в замахе связан со своим кольцом: нить (StampThrower.link) есть всё время замаха,
##    идёт от нотариуса к краю кольца, прогресс замаха растёт 0 → 1; после удара и после Ку
##    (оглушение сбивает замах) нити нет;
## 3) волна нотариусов: нитей не больше LegionCfg.STAMP_LINK_MAX, первым — ближний к Котлу, два
##    связанных кольца не лежат друг на друге.
## Итог «LEGION NOTARY READ: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_notary_read_test.cfg"
const DT := 1.0 / 60.0
const THROWER := "res://scripts/legion/fx/stamp_thrower.gd"
## Ниже этой насыщенности (OKLab) цвет читается серым — тон не важен.
const GRAY_CHROMA := 0.04
## Цветной знак не ближе этого по тону к голубому оглушению (у прежнего щита было 22°).
const HUE_MIN_DEG := 45.0

var w: LegionWorld
var _fails := 0
var _checks := 0
var _st: Script = null


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
	_test_shield()
	_st = load(THROWER) if ResourceLoader.exists(THROWER) else null
	_check(_st != null, "есть слой «кто бросает печать» (%s)" % THROWER)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	if _st != null:
		_test_link()
		_test_stun_breaks()
		_test_wave()
	Campaign.reset()
	print("LEGION NOTARY READ: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.contracts.active = true


# ── 1. Знак щита ────────────────────────────────────────────────────────────

func _test_shield() -> void:
	print("— знак щита не оттенка смысла")
	# до правки: заливка Color(0.2, 0.35, 0.55) в коде, обод CORE_CLIP_COLOR
	var marks := {
		"заливка": _const(LegionCfg, "CORE_SHIELD_FILL", Color(0.2, 0.35, 0.55)),
		"обод": _const(LegionCfg, "CORE_SHIELD_RIM", LegionCfg.CORE_CLIP_COLOR),
	}
	var stun_hue := _hue(CfgFx.C_STUN)
	for part: String in marks:
		var col: Color = marks[part]
		for m: StringName in CfgFx.MEANING_COLOR:
			var de := oklab_de(col, CfgFx.MEANING_COLOR[m])
			_check(de >= CfgFx.MEANING_MIN_DE, "щит, %s %s ≠ «%s»: ΔE %.3f ≥ %.2f"
				% [part, col.to_html(false), m, de, CfgFx.MEANING_MIN_DE])
		var ch := _chroma(col)
		var dh := absf(angle_difference(deg_to_rad(_hue(col)), deg_to_rad(stun_hue)))
		_check(ch < GRAY_CHROMA or rad_to_deg(dh) >= HUE_MIN_DEG,
			"щит, %s: серый (насыщенность %.3f) или тон дальше %.0f° от оглушения (%.0f°)"
			% [part, ch, HUE_MIN_DEG, rad_to_deg(dh)])


# ── 2. Нить «кто бросает» ───────────────────────────────────────────────────

func _signer(at: Vector2, target: Vector2) -> Foe:
	var s := w.spawn_foe_on_path("signer", PackedVector2Array([at]), at)
	s.stamp_pos = target
	s.stamp_t = LegionCfg.SIGNER_WARN
	return s


func _link(f: Foe) -> PackedVector2Array:
	return _st.call("link", f)


func _test_link() -> void:
	print("— нотариус в замахе связан со своим кольцом")
	_fresh()
	var at := Vector2(700, 300)
	var s := _signer(at, at + Vector2.LEFT * 220.0)
	w.spawn_unit(LegionCfg.KIND_LABORER, s.stamp_pos)
	var r := float(s.def["stamp_r"])
	var always := true
	var grows := true
	var last := -1.0
	var ends_ok := true
	var starts_ok := true
	var t := 0.0
	while s.stamp_t >= 0.0 and t < 3.0:
		var seg := _link(s)
		var k := float(_st.call("windup", s))
		always = always and seg.size() == 2
		grows = grows and k >= last and k >= 0.0
		last = k
		if seg.size() == 2:
			ends_ok = ends_ok and absf(seg[1].distance_to(s.stamp_pos) - r) < 1.0
			starts_ok = starts_ok and seg[0].distance_to(s.position) < float(s.def["body"])
		w.grid.rebuild()
		s._tick_stamp(DT)
		t += DT
	_check(always, "нить есть весь замах (%.2f с)" % t)
	_check(starts_ok, "нить начинается у нотариуса")
	_check(ends_ok, "нить упирается в край кольца печати (радиус %.0f)" % r)
	_check(grows and last > 0.95, "прогресс замаха растёт до конца (%.2f)" % last)
	_check(_link(s).is_empty(), "печать упала — нити нет")
	var own: Dictionary = _st.call("owners", w.foes, w.cauldron_pos)
	_check(own.is_empty(), "печать упала — связанных нотариусов нет (%d)" % own.size())


func _test_stun_breaks() -> void:
	print("— Ку сбивает замах — нить гаснет")
	_fresh()
	var s := _signer(Vector2(700, 300), Vector2(480, 300))
	_check(_link(s).size() == 2, "в замахе нить есть")
	s.stun(1.0)
	_check(_link(s).is_empty(), "оглушён — замах сбит, нити нет")


# ── 3. Волна нотариусов ─────────────────────────────────────────────────────

func _test_wave() -> void:
	print("— волна нотариусов: нитей не больше STAMP_LINK_MAX, ближние к Котлу")
	_fresh()
	var cap := int(_const(LegionCfg, "STAMP_LINK_MAX", 0))
	var near: Foe = null
	var best := INF
	# 12 нотариусов: шесть бьют в одну кучку, шесть — каждый в свою
	for i in 12:
		var at := Vector2(620 + (i % 6) * 40, 200 + int(i / 6.0) * 260)
		var target := Vector2(420, 330) if i < 6 else Vector2(380 + i * 30, 470 + (i % 2) * 90)
		var s := _signer(at, target)
		var d := at.distance_to(w.cauldron_pos)
		if d < best:
			best = d
			near = s
	var own: Dictionary = _st.call("owners", w.foes, w.cauldron_pos)
	_check(own.size() >= 1 and own.size() <= cap, "12 в замахе — нитей %d (потолок %d)"
		% [own.size(), cap])
	_check(own.has(near), "ближний к Котлу — среди связанных")
	var spread := float(_const(LegionCfg, "STAMP_LINK_SPREAD", 0.0))
	var apart := true
	var keys: Array = own.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var a: Foe = keys[i]
			var b: Foe = keys[j]
			apart = apart and a.stamp_pos.distance_to(b.stamp_pos) \
				>= float(a.def["stamp_r"]) * spread
	_check(spread > 0.0 and apart, "одно кольцо — одна нить: связанные кольца врозь")


## Константа класса-конфига; нет такой (код до правки) — запасное значение.
func _const(cfg: Script, key: String, fallback: Variant) -> Variant:
	return cfg.get_script_constant_map().get(key, fallback)


# ── OKLab (тот же расчёт, что legion_vfx_clarity_test) ──────────────────────

static func oklab_de(a: Color, b: Color) -> float:
	return _oklab(a).distance_to(_oklab(b))


static func _chroma(c: Color) -> float:
	var v := _oklab(c)
	return Vector2(v.y, v.z).length()


static func _hue(c: Color) -> float:
	var v := _oklab(c)
	return rad_to_deg(atan2(v.z, v.y))


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
