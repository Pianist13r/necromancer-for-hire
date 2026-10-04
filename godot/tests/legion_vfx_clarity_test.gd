extends SceneTree
##
## Регресс slow/vfx-clarity 29.09: «каша из эффектов… непонятно, что как нажать», «остаётся
## фиолетовый след, ещё непонятный мне», «такая же красная печать… не получает дамага —
## несогласованность» (Игорь 29.09). Один цвет — один смысл; шум тише, действие ярче.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_vfx_clarity_test.gd -- --mute
##
## 1) таблица смыслов CfgFx.MEANING_COLOR без повторов: цвета разных смыслов различимы
##    (ΔE в OKLab ≥ CfgFx.MEANING_MIN_DE);
## 2) живые метки боя берут цвет своего смысла: угроза — печать нотариуса, таран Прораба, Юрист
##    (выбор цели и разрыв), давка, «стена»; шанс — золото «Точно!»; оглушение — орбита слоя
##    подсказок и круги артефактов; простой — пузыри «Zz» и «…»;
## 3) метки артефактов не цвета угрозы и не цвета шанса: постоянный вид на бойцах, Котле,
##    постройках и линиях («Золотое перо» — исключение: оно само про «Точно!»), взрывы «Взрывной
##    печати» и «Печати на Котле»;
## 4) пузыри простоя: толпа в шести кучках даёт не больше LegionCfg.IDLE_ICON_MAX значков;
## 5) «Взрывная печать»: метки — только пока печать готова и не больше CfgItems.BADGE_MAX бойцов,
##    раненые первыми;
## 6) «Пролонгация»: призрачный участок подписан в первый раз за бой (подпись называет артефакт),
##    а его значок в полоске артефактов вздрагивает;
## 7) кольцо «Печати на Котле» — на земляном слое под Котлом, центр у его ног;
## 8) маркеры сторон PvP — свои смыслы таблицы (side_0/side_1), не цвет оглушения и простоя;
## 9) «Сбор» (R) — свой смысл «rally» (сиреневый, цвет некроманта): ΔE ≥ порога со всеми смыслами,
##    тон дальше 25° от каждого, кольцо/метки/слот R берут цвет таблицы (B-272; был голубым, ΔE 0,020
##    до оглушения).
## Итог «LEGION VFX CLARITY: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_vfx_clarity_test.cfg"
const DT := 1.0 / 60.0

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
	_test_meanings()
	_test_live_marks()
	_test_side_marks()
	_test_rally()
	_test_item_looks()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_blast_colors()
	_test_ward_ground()
	_test_idle_cap()
	await _test_badges()
	await _test_ghost()
	Campaign.reset()
	print("LEGION VFX CLARITY: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.contracts.active = true
	w.hero.reset()


# ── 1–3. Цвета ──────────────────────────────────────────────────────────────

func _test_meanings() -> void:
	print("— таблица смыслов без повторов")
	var keys: Array = CfgFx.MEANING_COLOR.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			var de := oklab_de(CfgFx.MEANING_COLOR[keys[i]], CfgFx.MEANING_COLOR[keys[j]])
			_check(de >= CfgFx.MEANING_MIN_DE, "%s ≠ %s: ΔE %.3f ≥ %.2f"
				% [keys[i], keys[j], de, CfgFx.MEANING_MIN_DE])


func _test_live_marks() -> void:
	print("— метки боя берут цвет своего смысла")
	var marks := {
		"печать нотариуса": [LegionWorld.STAMP_COLOR, &"danger"],
		"таран Прораба": [LegionCfg.BOSS_RAM_COLOR, &"danger"],
		"Юрист: выбор участка": [LegionCfg.LAWYER_COLOR, &"danger"],
		"Юрист: разрыв": [LegionCfg.LAWYER_TEAR_COLOR, &"danger"],
		"давка": [LegionCfg.PRESS_COLOR, &"danger"],
		"стена": [IntuitCfg.WALL_COLOR, &"danger"],
		"«Точно!» и золотой участок": [LegionCfg.PERFECT_COLOR, &"chance"],
		"оглушённый (подсказки)": [IntuitCfg.STUN_COLOR, &"stun"],
		"оглушение артефактов": [LegionItemEffects.COLOR_STUN, &"stun"],
		"простой «Zz»": [LegionCfg.IDLE_ICON_FAR_COLOR, &"idle"],
		"простой «…»": [LegionCfg.IDLE_ICON_FULL_COLOR, &"idle"],
	}
	for name: String in marks:
		var col: Color = marks[name][0]
		var meaning: StringName = marks[name][1]
		var want: Color = CfgFx.MEANING_COLOR[meaning]
		_check(col.is_equal_approx(want), "%s — цвет смысла «%s» (%s, нужен %s)"
			% [name, meaning, col.to_html(false), want.to_html(false)])


## Маркер стороны PvP (овал/ромб под бойцом и постройкой) — свой смысл «чей», в таблице смыслов;
## голубой маркер стороны 0 читался бы «оглушён» (ΔE 0,04 до правки P4, B-250).
func _test_side_marks() -> void:
	print("— маркеры сторон PvP — свой смысл, не чужой цвет")
	for side in 2:
		var own := StringName("side_%d" % side)
		var col := PvpRules.marker_color(side)
		_check(CfgFx.MEANING_COLOR.has(own)
			and col.is_equal_approx(CfgFx.MEANING_COLOR[own]),
			"маркер стороны %d — цвет смысла «%s»" % [side, own])
		for key: StringName in CfgFx.MEANING_COLOR:
			if key == own:
				continue
			var de := oklab_de(col, CfgFx.MEANING_COLOR[key])
			_check(de >= CfgFx.MEANING_MIN_DE, "маркер стороны %d ≠ %s: ΔE %.3f"
				% [side, key, de])


## «Сбор» (R): круг на земле, метки под бойцами, слот на панели, вспышка призыва — один цвет, и
## это НЕ цвет оглушения (круги оглушения артефактов лежат на той же земле, B-272).
func _test_rally() -> void:
	print("— «Сбор» — свой смысл, не цвет оглушения")
	_check(CfgFx.MEANING_COLOR.has(&"rally"), "«Сбор» есть в таблице смыслов")
	_check(LegionCfg.RALLY_COLOR.is_equal_approx(CfgFx.MEANING_COLOR.get(&"rally", Color.BLACK)),
		"LegionCfg.RALLY_COLOR — цвет смысла «rally» (%s)" % LegionCfg.RALLY_COLOR.to_html(false))
	var col: Color = LegionCfg.RALLY_COLOR
	for key: StringName in CfgFx.MEANING_COLOR:
		if key == &"rally":
			continue
		var other: Color = CfgFx.MEANING_COLOR[key]
		var de := oklab_de(col, other)
		_check(de >= CfgFx.MEANING_MIN_DE, "«Сбор» ≠ %s: ΔE %.3f ≥ %.2f"
			% [key, de, CfgFx.MEANING_MIN_DE])
		var dh := rad_to_deg(absf(angle_difference(deg_to_rad(_hue(col)), deg_to_rad(_hue(other)))))
		_check(dh >= 25.0, "«Сбор» ≠ %s по тону: %.0f° ≥ 25°" % [key, dh])
	_check(oklab_de(col, LegionItemEffects.COLOR_STUN) >= CfgFx.MEANING_MIN_DE,
		"«Сбор» ≠ круги оглушения артефактов")
	# живые места рисования берут константу, а не свой литерал голубого
	for path: String in ["res://scripts/legion/legion_world.gd",
			"res://scripts/legion/ui/ability_bar.gd"]:
		var src := FileAccess.get_file_as_string(path)
		_check(src.contains("LegionCfg.RALLY_COLOR") and not src.contains("Color(0.55, 0.85, 1.0)"),
			"%s: «Сбор» рисуется LegionCfg.RALLY_COLOR" % path.get_file())


## Постоянный вид артефакта — цели, где метка живёт на поле дольше вспышки.
func _test_item_looks() -> void:
	print("— метки артефактов не цвета угрозы и не цвета шанса")
	var lasting: Array[StringName] = [&"unit", &"cauldron", &"building", &"contract"]
	for id in LegionItemDb.ids():
		var lk := LegionItemDb.look(id)
		if not lasting.has(StringName(lk.get("target", &""))):
			continue
		var col: Color = lk["color"]
		var de := oklab_de(col, CfgFx.C_DANGER)
		_check(de >= CfgFx.MEANING_MIN_DE, "%s: не цвет угрозы (ΔE %.3f)" % [id, de])
		if id == &"golden_pen":
			continue   # позолота договора — сам артефакт «Точно!», золото тут и есть смысл
		de = oklab_de(col, CfgFx.C_CHANCE)
		_check(de >= CfgFx.MEANING_MIN_DE, "%s: не цвет шанса (ΔE %.3f)" % [id, de])


func _test_blast_colors() -> void:
	print("— взрывы артефактов не цвета угрозы")
	for id: StringName in [&"exploding_stamp", &"cauldron_ward"]:
		_fresh()
		w.items.grant(id)
		var got: Array[Color] = []
		var cb := func(kind: StringName, d: Dictionary) -> void:
			if kind == &"blast":
				got.append(d["color"])
		w.items.fx_event.connect(cb)
		if id == &"exploding_stamp":
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(600, 300), w.buildings[0])
			u.take_damage(9999.0, u.position)
		else:
			w.damage_cauldron(1.0, "zombie")
		var t := 0.0
		while t < 0.5:
			w.items.tick(DT)
			t += DT
		w.items.fx_event.disconnect(cb)
		_check(got.size() == 1, "%s: взрыв был (%d)" % [id, got.size()])
		if got.size() == 1:
			var de := oklab_de(got[0], CfgFx.C_DANGER)
			_check(de >= CfgFx.MEANING_MIN_DE, "%s: взрыв %s не цвета угрозы (ΔE %.3f)"
				% [id, got[0].to_html(false), de])


## Игорь 29.09 по листу fork_items: кольцо «Печати на Котле» лежало ПОВЕРХ Котла (слой вида
## артефактов — после фигур). Кольцо — на земляном узле под Contracts (до Entities), центр у ног.
func _test_ward_ground() -> void:
	print("— «Печать на Котле»: кольцо на земле под Котлом")
	var g := w.contracts.get_node_or_null("ItemLookGround")
	_check(g != null and w.contracts.get_index() < w.entities.get_index(),
		"земляной слой кольца — под полем договоров, перед фигурами (Котёл рисуется поверх)")
	var dy := float(_const(CfgItems, "WARD_DY", 18.0))
	_check(absf(dy) < CfgItems.WARD_R.y * 0.5, "центр кольца у ног Котла (сдвиг %.0f px)" % dy)


# ── 4. Пузыри простоя ───────────────────────────────────────────────────────

func _test_idle_cap() -> void:
	print("— пузыри простоя: не больше IDLE_ICON_MAX на поле")
	_fresh()
	# договор вида далеко: значок оправдан (иначе он молчит вовсе)
	var far := PackedVector2Array([Vector2(1100, 600), Vector2(1100, 680)])
	w.contracts.add_contract(far, 1, false)
	for k in 6:
		for i in 5:
			w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(160 + k * 160, 200 + i * 8))
	w.grid.rebuild()
	for u in w.units:
		u.tick(3.0)
	var shown := 0
	if w.units[0].has_method("idle_icon_owners"):
		shown = (w.units[0].call("idle_icon_owners", w) as Dictionary).size()
	else:
		# прежнее правило: по значку на кучку — шесть кучек, шесть значков
		for u in w.units:
			if u.idle_time >= LegionCfg.IDLE_NOTICE_TIME and u._idle_worth_flagging() \
					and not u._cluster_has_representative():
				shown += 1
	var cap := int(_const(LegionCfg, "IDLE_ICON_MAX", 0))
	_check(shown >= 1 and shown <= cap, "шесть кучек простоя — значков %d (потолок %d)"
		% [shown, cap])


# ── 5. «Взрывная печать» ────────────────────────────────────────────────────

func _look() -> LegionItemLook:
	return w.get_node("ItemLook") as LegionItemLook


func _badges() -> Array:
	var look := _look()
	if look.has_method("badge_units"):
		return look.call("badge_units")
	var all: Array = []
	for u in w.units:
		if u.alive:
			all.append(u)
	return all   # прежний вид: печать на груди у каждого


func _test_badges() -> void:
	print("— «Взрывная печать»: метки только у готовой печати, не больше BADGE_MAX")
	_fresh()
	w.items.grant(&"exploding_stamp")
	for i in 20:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300 + i * 20, 300))
	var hurt := w.units[7]
	hurt.hp = hurt.max_hp * 0.3
	var cap := int(_const(CfgItems, "BADGE_MAX", 0))
	var got := _badges()
	_check(got.size() >= 1 and got.size() <= cap, "печать готова: меток %d (потолок %d)"
		% [got.size(), cap])
	_check(got.has(hurt), "раненый боец — среди помеченных")
	w.items.state[&"stamp_ready"] = w.now + 5.0
	_check(_badges().is_empty(), "печать перезаряжается — меток нет (%d)" % _badges().size())
	await process_frame


# ── 6. «Пролонгация» ────────────────────────────────────────────────────────

func _test_ghost() -> void:
	print("— «Пролонгация»: след подписан и связан со значком в полоске")
	_fresh()
	w.items.grant(&"prolongation")
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	var t := 0.0
	while t < 4.0:
		bar._process(DT)
		t += DT
	var before := float(bar._punch.get(&"prolongation", 0.0))
	var look := _look()
	var p := Vector2(600, 300)
	var c := w.contracts.add_contract(PackedVector2Array([p, p + Vector2(0, 128)]), 1, false)
	w.release_segment(c, 0, &"melt")
	_check(w.items.hazard_count(&"ghost") == 1, "растаявший участок оставил призрачный след")
	var after := float(bar._punch.get(&"prolongation", 0.0))
	_check(after > before + 0.5, "значок «Пролонгации» в полоске вздрогнул (%.2f → %.2f)"
		% [before, after])
	var cap := ""
	if look.has_method("ghost_caption"):
		cap = String(look.call("ghost_caption", w.items.hazards[0]))
	_check(cap.contains("Пролонгация"), "у первого следа подпись с именем артефакта: «%s»" % cap)
	# следующие следы боя — без подписи (значок остаётся): подпись не шумит каждый раз
	var extra := int(_const(CfgItems, "GHOST_CAPTIONS", 1))
	for i in int(extra) + 1:
		var c2 := w.contracts.add_contract(PackedVector2Array([p + Vector2(60 + i * 40, 0),
			p + Vector2(60 + i * 40, 128)]), 1, false)
		w.release_segment(c2, 0, &"melt")
	var last := ""
	if look.has_method("ghost_caption"):
		last = String(look.call("ghost_caption", w.items.hazards[w.items.hazards.size() - 1]))
	_check(last == "", "после %s подписей за бой — без подписи («%s»)" % [extra, last])
	await process_frame


## Константа класса-конфига; нет такой (код до правки) — запасное значение.
func _const(cfg: Script, key: String, fallback: Variant) -> Variant:
	return cfg.get_script_constant_map().get(key, fallback)


# ── OKLab (тот же расчёт, что legion_lines_test) ────────────────────────────

static func oklab_de(a: Color, b: Color) -> float:
	return _oklab(a).distance_to(_oklab(b))


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
