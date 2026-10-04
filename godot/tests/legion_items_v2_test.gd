extends SceneTree
##
## Артефакты v2 (Игорь 27.09, D-0927-163: «выпадают слишком часто и не очень заметно влияют…
## зря они в конце выпадают… сохранялись в течение всего забега… визуально импульс… один-два
## раза за битву максимум, и то не каждую битву»; уточнение: «чтобы молния цвет меняла»):
##   A) редкость: бюджет боя 0–2, часть боёв без артефактов, носители только со второй половины
##      боя и не в последней волне; потолок выпадений за бой держится при любом источнике;
##      не-носитель не роняет; артефакт уникален; потолок забега;
##   B) сохранение: кампания — между картами (победой), «Бесконечный подряд» / «Вызов дня» —
##      в своих разделах; поражение находки не сохраняет; новый забег и сброс — чистят;
##      одиночный бой (без carry_items) — ничего не переносит; полоска полна с начала боя;
##   C) вид: у каждого артефакта look {target, channel, color}; каналы одной цели не
##      пересекаются; вид каждого артефакта ложится на объект (items.note_look) — с артефактом
##      есть, без него нет; молния со «Скрепкой» и «Громоотводом» — золото с фиолетовыми
##      ветками; импульс получения (вспышка, карточка ≤ 2 с, свечение цели).
## Новые API зовутся через has_method/get — на старом коде файл разбирается, проверки падают
## строками FAIL.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_items_v2_test.gd -- --mute
##
## Итог «LEGION ITEMS V2: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_items_v2_test.cfg"
const DT := 1.0 / 60.0

var w: LegionWorld
var _fails := 0
var _checks := 0
var _spot := 0


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
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	root.size = Vector2i(1280, 720)
	await process_frame
	_test_budget()
	_test_carrier()
	_test_cap()
	_test_unique()
	_test_persist()
	await _test_look()
	await _test_impulse()
	await _test_vassals_cleared()
	Campaign.use_campaign_scope()
	Campaign.reset()
	print("LEGION ITEMS V2: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── оснастка ────────────────────────────────────────────────────────────────

## Константа CfgItems по имени (на старом коде её может не быть — тогда fallback).
func _cfg(key: String, fallback: Variant) -> Variant:
	return (CfgItems as Script).get_script_constant_map().get(key, fallback)


func _fresh(map_id := "wasteland") -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	for k in ["elite", "drop", "carriers"]:
		w.dev.erase(k)
	w.start_map(map_id)
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.contracts.active = true
	w.hero.reset()
	_spot = 0


func _foe(type: String, at: Vector2, hp := -1.0, wave := 0) -> Foe:
	var origin := {"wave": wave} if wave > 0 else {}
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at, w.cauldron_pos]), at, false, origin)
	if hp > 0.0:
		f.hp = hp
		f.max_hp = hp
	return f


func _next_spot() -> Vector2:
	_spot += 1
	return Vector2(560.0 + float(_spot % 6) * 90.0, 140.0 + float(_spot / 6) * 90.0)


func _kill(f: Foe) -> void:
	f.take_damage(f.hp + 1.0, f.position + Vector2(10, 0))


func _items_tick(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		w.items.tick(DT)
		t += DT


## Перерисовать слои вида и дать движку два кадра (мир стоит — перерисовку просим сами).
func _frames() -> void:
	for n: Node in [w.contracts, w.contracts.overlay, w.get_node_or_null("Fx"),
			w.get_node_or_null("ItemLook"), w.get_node_or_null("ItemFx")]:
		if n != null:
			(n as CanvasItem).queue_redraw()
	await process_frame
	await process_frame


func _looked(key: String) -> int:
	if not w.items.has_method("look_count"):
		return 0
	return int(w.items.call("look_count", key))


func _plan() -> Array:
	var p: Variant = w.items.get("plan")
	return p if p is Array else []


# ── A. редкость ─────────────────────────────────────────────────────────────

func _test_budget() -> void:
	print("— бюджет боя: 0–2 артефакта, часть боёв без них, окно — вторая половина без последней")
	_fresh()
	if not w.items.has_method("plan_battle"):
		_check(false, "нет LegionItems.plan_battle — носителей по волнам нет")
		return
	for n_waves in [5, 6]:
		var zero := 0
		var sum := 0
		var worst := 0
		var outside := 0
		var runs := 400
		var window := range(ceili(n_waves * 0.5), n_waves)
		for s in runs:
			w._base_seed = 1000 + s
			w.items.call("plan_battle", n_waves)
			var p := _plan()
			sum += p.size()
			worst = maxi(worst, p.size())
			if p.is_empty():
				zero += 1
			for wn: int in p:
				if not window.has(wn):
					outside += 1
		w._base_seed = 1
		var mean := float(sum) / runs
		_check(worst <= 2, "%d волн: больше двух за бой не бывает (макс. %d)" % [n_waves, worst])
		_check(zero >= runs * 0.25 and zero <= runs * 0.45,
			"%d волн: боёв без артефакта %d из %d (≈ треть)" % [n_waves, zero, runs])
		_check(mean >= 0.7 and mean <= 1.0, "%d волн: в среднем %.2f за бой" % [n_waves, mean])
		_check(outside == 0, "%d волн: носители только в волнах %s (мимо окна: %d)"
			% [n_waves, str(window), outside])
	# реальный старт карты: план от сида и карты воспроизводим; при одном сиде игры (1) бои
	# разных карт получают разный бюджет — иначе вся кампания была бы «всегда 1» или «никогда»
	w.dev.erase("no_waves")
	var plans := {}
	for m in ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze", "swamp", "boss"]:
		w._base_seed = 1
		w.start_map(m)
		w.set_process(false)
		var a := _plan().duplicate()
		w.start_map(m)
		w.set_process(false)
		_check(a == _plan(), "%s: план носителей воспроизводим (%s)" % [m, str(a)])
		plans[a.size()] = int(plans.get(a.size(), 0)) + 1
	_check(plans.size() >= 2, "сид 1, восемь карт — бюджеты разные: %s" % str(plans))
	w.dev["no_waves"] = "1"
	w._base_seed = 1


func _test_carrier() -> void:
	print("— носитель: второй пехотинец своей волны, элитный с портфелем; только он роняет")
	_fresh("fork")
	w.dev["carriers"] = "3"
	w.dev["elite"] = "0"
	if w.items.has_method("plan_battle"):
		w.items.call("plan_battle", 5)
	var got: Array[bool] = []
	var carriers: Array[Foe] = []
	for i in 3:
		var f := _foe("zombie", Vector2(900, 120 + i * 60), -1.0, 3)
		got.append(f.elite)
		if f.get("carrier") == true:
			carriers.append(f)
	_check(got == [false, true, false], "волна 3: элитный — только второй (%s)" % str(got))
	_check(carriers.size() == 1, "носитель отмечен (carrier), один")
	var mark_ok := false
	if not carriers.is_empty():
		for ch in carriers[0].get_children():
			if ch is LegionEliteMark and ch.get("carrier") == true:
				mark_ok = true
	_check(mark_ok, "у носителя знак с портфелем (LegionEliteMark.carrier)")
	var e1 := _foe("zombie", Vector2(900, 400), -1.0, 1)
	_check(not e1.elite, "первая волна — не носитель (план — только волна 3)")
	# обычный элитный (не носитель) артефакт не роняет
	w.dev["elite"] = "1"
	_kill(_foe("zombie", Vector2(700, 300), -1.0, 4))
	_check(w.items.total() == 0, "убит элитный НЕ носитель — артефакта нет")
	w.dev["elite"] = "0"
	if not carriers.is_empty():
		_kill(carriers[0])
	_check(w.items.total() == 1, "убит носитель — выпал артефакт (%d)" % w.items.total())
	_check(int(w.stats.get("items", 0)) == 1, "находка посчитана в stats")


func _test_cap() -> void:
	print("— потолок за бой: не больше двух при любом источнике")
	_fresh("fork")
	w.dev["elite"] = "1"
	w.dev["drop"] = "1"
	for i in 6:
		_kill(_foe("zombie", Vector2(700 + i * 20, 300), -1.0, 3))
	var cap := int(_cfg("MAX_PER_BATTLE", 2))
	_check(cap == 2 and w.items.total() == 2, "6 элитных с --dev drop=1 → %d артефакта" % w.items.total())
	var before := w.items.total()
	_kill(_foe("zombie", Vector2(900, 300), -1.0, 3))
	_check(w.items.total() == before, "седьмой элитный с тем же --dev drop=1 — ничего (потолок)")
	w.dev.erase("drop")
	w.dev.erase("elite")


func _test_unique() -> void:
	print("— артефакт уникален; потолок забега")
	_fresh()
	w.items.grant(&"clip_of_fate")
	w.items.grant(&"clip_of_fate")
	_check(w.items.count(&"clip_of_fate") == 1, "второй раз тот же не выдаётся")
	var base := LegionCfg.Q_CHAIN_BASE_TARGETS
	_check(w.hero.q_chain_len() == base + 2, "цепь Ку +2 один раз (%d)" % w.hero.q_chain_len())
	var owned := {}
	for id in LegionItemDb.ids():
		owned[id] = 1
	owned.erase(&"megaphone")
	var rng := RandomNumberGenerator.new()
	var picked_ok := true
	for s in 30:
		rng.seed = s
		var p: Variant = (LegionItemDb as Script).callv("pick", [rng, owned])
		picked_ok = picked_ok and p == &"megaphone"
	_check(picked_ok, "выбор — только среди ещё не взятых")
	if not w.items.has_method("plan_battle"):
		_check(false, "нет потолка забега (plan_battle)")
		return
	var run_max := int(_cfg("RUN_MAX", 8))
	var ids := LegionItemDb.ids()
	for i in mini(run_max, ids.size()):
		w.items.grant(ids[i])
	var empty := true
	for s in 40:
		w._base_seed = 2000 + s
		w.items.call("plan_battle", 5)
		empty = empty and _plan().is_empty()
	w._base_seed = 1
	_check(empty, "собрано %d (потолок забега) — носителей больше нет" % w.items.total())


# ── B. сохранение ───────────────────────────────────────────────────────────

func _start(map_id: String, carry: bool) -> void:
	w.set("carry_items", carry)
	w.in_campaign = true
	w.mods = Campaign.active_mods()
	_fresh(map_id)


func _owned() -> Array:
	var out: Array = []
	for id: StringName in w.items.counts:
		out.append(String(id))
	return out


func _test_persist() -> void:
	print("— сохранение: кампания между картами, забег в своём разделе, одиночный бой — нет")
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	_start("wasteland", true)
	w.items.grant(&"clip_of_fate", Vector2(600, 300))
	w.items.grant(&"megaphone", Vector2(620, 300))
	w._end(true)
	_start("fork", true)
	_check(_owned() == ["clip_of_fate", "megaphone"], "кампания: следующая карта — с артефактами %s"
		% str(_owned()))
	_check(bar.shown.size() == 2 and bar.in_flight() == 0,
		"полоска полна с начала боя, без полёта (%d)" % bar.shown.size())
	_check(bar.current_card().is_empty(), "загруженные артефакты — без карточек")
	_check(w.hero.q_chain_len() == LegionCfg.Q_CHAIN_BASE_TARGETS + 2, "и действуют (цепь Ку)")
	_check(int(w.stats.get("items", 0)) == 0, "загруженные — не находки этого боя")
	w.items.grant(&"soul_magnet", Vector2(600, 300))
	w._end(false)
	_start("fork", true)
	_check(_owned().size() == 2, "поражение: находка проигранного боя не сохранилась (%s)"
		% str(_owned()))
	# «Бесконечный подряд» — свой раздел
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(123)
	_start("wasteland", true)
	_check(_owned().is_empty(), "новый забег начинается без артефактов кампании")
	w.items.grant(&"golden_pen", Vector2(600, 300))
	w._end(true)
	_start("fork", true)
	_check(_owned() == ["golden_pen"], "забег: следующий объект — с артефактом забега")
	Campaign.use_daily_scope()
	LegionRunStore.endless_start(5, "2026-09-27")
	_start("fork", true)
	_check(_owned().is_empty(), "«Вызов дня» — свой раздел, пуст")
	Campaign.use_campaign_scope()
	_start("fork", true)
	_check(_owned().size() == 2, "кампания свои артефакты не потеряла")
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(9)
	_start("fork", true)
	_check(_owned().is_empty(), "новый «Бесконечный подряд» чистит артефакты забега")
	# одиночный бой (--map, бот, переигровка вне забега): carry_items выключен
	Campaign.use_campaign_scope()
	_start("fork", false)
	_check(_owned().is_empty(), "одиночный бой — без переноса, хотя в кампании 2 сохранены")
	w.items.grant(&"soul_magnet", Vector2(600, 300))
	w._end(true)
	_start("fork", true)
	_check(_owned().size() == 2, "победа одиночного боя в сохранение не пишет")
	Campaign.reset()
	_start("fork", true)
	_check(_owned().is_empty(), "сброс сохранения чистит артефакты")
	w.set("carry_items", false)
	w.in_campaign = false
	w.mods = {}


# ── C. вид ──────────────────────────────────────────────────────────────────

func _test_look() -> void:
	print("— вид: у каждого артефакта свой ключ вида, и он ложится на объект")
	var targets: Array = _cfg("LOOK_TARGETS", [])
	var by_target := {}
	for id in LegionItemDb.ids():
		var lk: Dictionary = LegionItemDb.item(id).get("look", {})
		var ok := not lk.is_empty() and targets.has(lk.get("target", &"")) \
			and String(lk.get("channel", "")) != "" and lk.get("color") is Color
		_check(ok, "%s: look {target, channel, color} = %s" % [id, str(lk)])
		if not ok:
			continue
		var key := String(lk["target"]) + "." + String(lk["channel"])
		_check(not by_target.has(key), "%s: канал %s не занят другим артефактом" % [id, key])
		by_target[key] = id
	for key: String in by_target:
		var id: StringName = by_target[key]
		var without := await _scene(key, [])
		var with := await _scene(key, [id])
		_check(with > 0 and without == 0, "%s → %s: без артефакта %d, с ним %d" % [id, key,
			without, with])
	await _test_bolt_mix()
	await _test_mechanics()


## Сценарий, в котором вид цели должен лечь на объект; число отметок note_look.
func _scene(key: String, grant: Array) -> int:
	_fresh()
	for id in grant:
		w.items.grant(StringName(id))
	var p := Vector2(600, 300)
	match key.get_slice(".", 0):
		"q_bolt":
			_foe("zombie", p, 500.0)
			_foe("zombie", p + Vector2(40, 0), 500.0)
			w.hero.cast(LegionHero.SLOT_Q, p)
		"unit":
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, p)
			u.start_charge(Vector2.RIGHT)
		"vassal":
			_kill(_foe("zombie", p))
			w.hero.cast(LegionHero.SLOT_W, p)
		"contract":
			var c := w.contracts.add_contract(PackedVector2Array([p, p + Vector2(0, 128)]), 1, false)
			if key.ends_with("ghost"):
				w.release_segment(c, 0, &"melt")
		"e_haste":
			w.spawn_unit(LegionCfg.KIND_LABORER, p)
			w.hero.cast(LegionHero.SLOT_E, p)
			if w.gfx_fx() != null:
				w.gfx_fx().impact.tick(0.2)
		"rally":
			w.spawn_unit(LegionCfg.KIND_LABORER, p + Vector2(20, 0))
			w.rally_cd = 0.0
			w.rally(p)
	await _frames()
	return _looked(key)


func _test_bolt_mix() -> void:
	print("— молния: «Скрепка» красит канал, «Громоотвод» — ветки; вместе без каши")
	var fx := w.gfx_fx()
	if fx == null:
		_check(false, "нет слоя эффектов (полная графика)")
		return
	var colors := {}
	for grant: Array in [[], [&"clip_of_fate"], [&"clip_of_fate", &"lightning_rod"]]:
		_fresh()
		fx.impact.clear()
		for id in grant:
			w.items.grant(id)
		_foe("zombie", Vector2(600, 300), 500.0)
		w.hero.cast(LegionHero.SLOT_Q, Vector2(600, 300))
		var b: Dictionary = {}
		for x: Dictionary in fx.impact._bolts:
			if not bool(x["micro"]):
				b = x
				break
		colors[grant.size()] = b
	var clip: Color = LegionItemDb.item(&"clip_of_fate").get("look", {}).get("color", Color.BLACK)
	var rod: Color = LegionItemDb.item(&"lightning_rod").get("look", {}).get("color", Color.BLACK)
	var b0: Dictionary = colors[0]
	var b1: Dictionary = colors[1]
	var b2: Dictionary = colors[2]
	_check(b0.get("c") == LegionCfg.Q_COLOR, "без артефактов — прежний цвет молнии")
	_check(b1.get("c") == clip and float(b1.get("w", 1.0)) > 1.0,
		"«Скрепка»: канал золотой и толще (w %.2f)" % float(b1.get("w", 0.0)))
	_check(b2.get("c") == clip and b2.get("bc") == rod and int(b2.get("brx", 0)) > 0,
		"«Скрепка» + «Громоотвод»: канал золотой, ветки фиолетовые (+%d)" % int(b2.get("brx", 0)))
	_check((b2.get("br", []) as Array).size() > (b0.get("br", []) as Array).size(),
		"веток больше, чем без артефакта (%d > %d)" % [(b2.get("br", []) as Array).size(),
			(b0.get("br", []) as Array).size()])


## Механика: каждый особый артефакт действительно меняет игру (короткий замер на артефакт).
func _test_mechanics() -> void:
	print("— механика: артефакт меняет игру")
	var p := Vector2(600, 300)
	# «Взрывная печать»: павший боец взрывается
	for grant: Array in [[], [&"exploding_stamp"]]:
		_fresh()
		for id in grant:
			w.items.grant(id)
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, p, w.buildings[0])
		var f := _foe("zombie", p + Vector2(30, 0), 500.0)
		u.take_damage(9999.0, p)
		_items_tick(0.3)
		_check((f.hp < 500.0) == (not grant.is_empty()), "«Взрывная печать» %s: враг рядом %.0f HP"
			% ["есть" if grant else "нет", f.hp])
	# «Сургуч с огоньком»: бегущий натиском боец роняет горящие пятна
	for grant: Array in [[], [&"burning_seal"]]:
		_fresh()
		for id in grant:
			w.items.grant(id)
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, p)
		u.start_charge(Vector2.RIGHT)
		for i in 6:
			u.position += Vector2(12, 0)
			w.items.tick(DT)
		var burns := w.items.hazards.filter(func(h: Dictionary) -> bool: return h["kind"] == &"trail")
		_check((burns.size() > 0) == (not grant.is_empty()), "«Сургуч» %s: огненных пятен %d"
			% ["есть" if grant else "нет", burns.size()])
	# «Пролонгация»: растаявший участок держит призрачную линию, враг на ней вязнет
	for grant: Array in [[], [&"prolongation"]]:
		_fresh()
		for id in grant:
			w.items.grant(id)
		var c := w.contracts.add_contract(PackedVector2Array([p, p + Vector2(0, 128)]), 1, false)
		var f := _foe("zombie", c.seg_center(0), 500.0)
		w.release_segment(c, 0, &"melt")
		_items_tick(0.5)
		_check((f.seal_slow_t > 0.0 and f.hp < 500.0) == (not grant.is_empty()),
			"«Пролонгация» %s: враг на линии вяз %.1f с, HP %.0f"
			% ["есть" if grant else "нет", f.seal_slow_t, f.hp])
	# «Штатное расписание»: постройка рождает бойцов по двое
	_test_twin()
	# «Рупор завхоза»: «Сбор» оглушает
	for grant: Array in [[], [&"megaphone"]]:
		_fresh()
		for id in grant:
			w.items.grant(id)
		var f := _foe("zombie", p + Vector2(60, 0), 500.0)
		w.rally_cd = 0.0
		w.rally(p)
		_check((f.stun_t > 0.0) == (not grant.is_empty()), "«Рупор» %s: оглушение %.1f"
			% ["есть" if grant else "нет", f.stun_t])
	# «Печать на Котле»: удар по Котлу — взрыв вокруг
	for grant: Array in [[], [&"cauldron_ward"]]:
		_fresh()
		for id in grant:
			w.items.grant(id)
		var f := _foe("zombie", w.cauldron_pos + Vector2(60, 0), 500.0)
		w.damage_cauldron(1.0)
		_check((f.hp < 500.0) == (not grant.is_empty()), "«Печать на Котле» %s: враг %.0f HP"
			% ["есть" if grant else "нет", f.hp])
	await process_frame


## Отдельно и точно: таймеры мест разные — с артефактом за шаг рождается вдвое больше.
func _test_twin() -> void:
	var born_by := {}
	for grant: Array in [[], [&"staff_schedule"]]:
		_fresh()
		for id in grant:
			w.items.grant(id)
		var b: LegionBuilding = w.staff.cauldron
		b.set_staff(4, 30.0)   # штат Котла в тесте нулевой (spawn_units=0) — даём четыре места
		b.fill_now(10)
		for u in b.slot_unit.duplicate():
			if u != null:
				u.take_damage(9999.0, u.position)
		for i in b.slot_t.size():
			b.slot_t[i] = 1.0 + float(i) * 10.0   # истекают по одному
		var n0 := b.alive_count()
		b.tick(1.05, 99)
		born_by[grant.size()] = b.alive_count() - n0
	_check(born_by[0] == 1 and born_by[1] == 2, "«Штатное расписание»: за шаг без него %d, с ним %d"
		% [born_by[0], born_by[1]])


## Находка кадров items-v2: внештатники прошлого боя оставались застывшими фигурами.
func _test_vassals_cleared() -> void:
	print("— новый бой убирает внештатников прошлого")
	_fresh()
	_kill(_foe("zombie", Vector2(600, 300)))
	w.hero.cast(LegionHero.SLOT_W, Vector2(600, 300))
	var left: Array = w.hero.vassals().duplicate() if w.hero.has_method("vassals") else []
	var before := left.size()
	_fresh()
	await process_frame
	var after := 0
	for v: Variant in left:
		if is_instance_valid(v):
			after += 1
	_check(before > 0 and after == 0, "внештатников было %d, после нового боя осталось %d"
		% [before, after])


func _test_impulse() -> void:
	print("— импульс получения: вспышка у носителя, карточка ≤ 2 с, цель светится")
	_fresh()
	var events: Array = []
	var cb := func(kind: StringName, _d: Dictionary) -> void: events.append(kind)
	w.items.fx_event.connect(cb)
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	w.items.grant(&"exploding_stamp", Vector2(600, 300))
	_check(events.has(&"gain"), "вспышка находки у места выпадения")
	var t := 0.0
	while bar.in_flight() > 0 and t < 4.0:
		bar._process(DT)
		t += DT
	var card := bar.current_card()
	_check(String(card.get("title", "")).begins_with("Артефакт: ") and String(card.get("text", ""))
		!= "", "карточка «%s — %s»" % [card.get("title", ""), card.get("text", "")])
	_check(float(_cfg("CARD_T", 3.2)) <= 2.0, "карточка на виду ~1,5 с (CARD_T %.1f)"
		% float(_cfg("CARD_T", 3.2)))
	var pulse := float(w.items.call("pulse", &"unit")) if w.items.has_method("pulse") else 0.0
	_check(pulse > 0.5, "на посадке то, на что действует артефакт (бойцы), вспыхивает (%.2f)" % pulse)
	w.items.fx_event.disconnect(cb)
