# gdlint: disable=max-returns
extends SceneTree
## Все13 механик и3 синергии: positive owner1 vs empty и negative non-owner0.
const DT := 1.0 / 60.0
var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _run() -> void:
	Campaign.set_save_path("user://pvp_items_parity.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	for id in LegionItemDb.ids():
		var entry := LegionItemDb.item(id)
		for key: String in entry.get("mods", {}):
			_fresh()
			var base := _number(key, 1)
			_grant([id], 0)
			_check(is_equal_approx(_number(key, 1), base), "%s/%s чужой не влияет" % [id, key])
			_grant([id], 1)
			var after := _number(key, 1)
			_check((after - base) * signf(float(entry["mods"][key])) > 0.0,
				"%s/%s свой меняет %.2f→%.2f" % [id, key, base, after])
		if entry.has("on"):
			var base := _measure(String(id), [])
			var own := _measure(String(id), [id], 1)
			var other := _measure(String(id), [id], 0)
			_check(own > base, "%s свой эффект %.2f>%.2f" % [id, own, base])
			_check(is_equal_approx(other, base), "%s чужой эффект %.2f=%.2f" % [id, other, base])
	for id in LegionItemDb.synergy_ids():
		var ids: Array = LegionItemDb.synergy(id)["items"]
		var base := _measure(String(id), ids.slice(1))
		var own := _measure(String(id), ids, 1)
		var other := _measure(String(id), ids, 0)
		var empty := _measure(String(id), [])
		_check(own > base, "%s собственная синергия усиливает эффект" % id)
		_check(is_equal_approx(other, empty), "%s чужая синергия не влияет" % id)
	_test_q_and_bar()
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION PVP ITEMS PARITY: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)


func _fresh() -> void:
	w.dev = {"spawn_units": "0", "no_waves": "1", "pvp_nobot": "1", "noview": "1"}
	w.start_map("pvp:duel")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({"size": [1600, 900]})
	w.grid.rebuild()
	for side in w.sides:
		side.contracts.active = true
		side.contracts.mana = 100.0
		side.hero.reset()


func _foe(kind: String, at: Vector2, hp := -1.0) -> Foe:
	var f := w.spawn_foe_on_path(kind, PackedVector2Array([at, w.cauldron_of(1)]), at)
	if hp > 0.0:
		f.hp = hp
		f.max_hp = hp
	return f


func _kill(f: Foe) -> void:
	f.last_hit_side = 1
	f.take_damage(f.hp + 1.0, f.position + Vector2(10, 0))


func _line(at: Vector2) -> Contract:
	return w.sides[1].contracts.add_contract(PackedVector2Array([at, at + Vector2(0, 128)]), 1, false)


func _tick_items(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		for side in w.sides:
			side.items.tick(DT)
		t += DT


func _grant(ids: Array, side: int) -> void:
	for id in ids:
		w.items_of(side).grant(StringName(id))


func _number(key: String, side: int) -> float:
	var h := w.hero_of(side)
	match key:
		"q_chain": return h.q_chain_len()
		"q_stun": return h.q_stun()
		"w_raise": return h.w_raise_max()
		"e_dur": return h.e_duration()
		"e_radius": return h.e_radius()
		"line_cost": return w.sides[side].contracts.mana_cost_mult
		"mana_regen": return w.sides[side].contracts.mana_regen
		"rally_cd": return w.rally_cd_total(side)
		"twin_spawn":
			var b: LegionBuilding = w.sides[side].staff.cauldron
			b.set_staff(4, 30.0)
			b.fill_now(10)
			for u in b.slot_unit.duplicate():
				if u != null:
					u.take_damage(9999.0, u.position)
			for i in b.slot_t.size():
				b.slot_t[i] = 1.0 + float(i) * 10.0
			var before := b.alive_count()
			b.tick(1.05, 99)
			return b.alive_count() - before
	return NAN


func _measure(id: String, grant: Array, recipient := 1) -> float:
	_fresh()
	_grant(grant, recipient)
	var h := w.hero_of(1)
	match id:
		"golden_pen":
			h._cd[LegionHero.SLOT_Q] = 5.0
			w._charge_feedback(Vector2(1000, 300), true, 1)
			return 5.0 - h.cd_left(LegionHero.SLOT_Q)
		"lightning_rod":
			_foe("zombie", Vector2(1000, 300), 1.0)
			_foe("zombie", Vector2(1060, 300), 500.0)
			h.cast(LegionHero.SLOT_Q, Vector2(1000, 300))
			return float(w.stats.get("item_bolt_hops", 0))
		"thunder_office":
			_foe("zombie", Vector2(1000, 300), 500.0)
			_foe("zombie", Vector2(1050, 300), 500.0)
			h.cast(LegionHero.SLOT_Q, Vector2(1000, 300))
			return float(w.items_of(1).hazards.filter(func(x: Dictionary) -> bool:
				return x["kind"] == &"stun").size())
		"exploding_stamp":
			# павший боец постройки взрывается печатью
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(1000, 300), w.sides[1].staff.cauldron)
			var nb := _foe("zombie", Vector2(1030, 300), 500.0)
			u.take_damage(9999.0, u.position)
			_tick_items(0.3)
			return 500.0 - nb.hp
		"kamikaze_brigade":
			# синергия: взрыв павшего бойца ×1,5 (с одной «Взрывной печатью» — ×1)
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(1000, 300), w.sides[1].staff.cauldron)
			var nb := _foe("zombie", Vector2(1030, 300), 500.0)
			u.take_damage(9999.0, u.position)
			_tick_items(0.3)
			return 500.0 - nb.hp
		"temp_contract":
			var p := Vector2(1000, 300)
			_kill(_foe("zombie", p))
			var nb := _foe("zombie", p + Vector2(40, 0), 500.0)
			h.cast(LegionHero.SLOT_W, p)
			for v in h._vassals:
				v.life = 0.001
			h.tick(0.02)
			return 500.0 - nb.hp
		"burning_seal":
			# бегущий натиском боец роняет горящие пятна, враг на следе горит
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(960, 300), null, 1)
			var f := _foe("zombie", Vector2(1020, 300), 500.0)
			u.start_charge(Vector2.RIGHT)
			for i in 10:
				u.position += Vector2(12, 0)
				w.items_of(1).tick(DT)
			_tick_items(1.0)
			return 500.0 - f.hp
		"prolongation", "hot_line":
			var c := _line(Vector2(1000, 300))
			var f := _foe("zombie", c.seg_center(0), 500.0)
			w.release_segment(c, 0, &"melt")
			_tick_items(1.0)
			return 500.0 - f.hp
		"megaphone":
			var f := _foe("zombie", Vector2(1060, 300), 500.0)
			# E-1005: «Рупор» оглушает только за настоящий сбор — в радиусе нужен свой боец,
			# иначе «Сбор» не позовёт никого и оглушения не будет.
			w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(1000, 300), null, 1)
			w.sides[1].rally_cd = 0.0
			w.rally(Vector2(1000, 300), 1)
			return f.stun_t
		"soul_magnet":
			w.sides[1].cauldron_hp = 50.0
			_kill(_foe("zombie", Vector2(1000, 300)))
			return w.sides[1].cauldron_hp - 50.0
		"cauldron_ward":
			var f := _foe("zombie", w.cauldron_of(1) + Vector2(50, 0), 500.0)
			w.damage_cauldron(1.0, "", 1)
			return f.stun_t + (500.0 - f.hp)
	return NAN


func _test_q_and_bar() -> void:
	_fresh()
	_grant(["clip_of_fate", "lightning_rod"], 1)
	var own := w.hero_of(1).q_look()
	var other := w.hero_of(0).q_look()
	_check(float(own["width"]) == 1.4 and int(own["branches"]) == 3,
		"Q владельца имеет ширину Скрепки и ветви Громоотвода")
	_check(float(other["width"]) == 1.0 and int(other["branches"]) == 0,
		"Q соперника не меняет вид")
	var bar := LegionItemBar.new()
	root.add_child(bar)
	bar.setup(w, 1)
	_check(bar.shown_count(&"clip_of_fate") == 1, "side1 bar восстанавливает свои предметы")
	w.items.grant(&"golden_pen")
	_check(bar.shown_count(&"golden_pen") == 0, "side1 bar не принимает чужой предмет")
	w.items_of(1).grant(&"megaphone")
	_check(bar.shown_count(&"megaphone") == 1, "side1 bar принимает свой предмет")
	bar.bind_side(0)
	_check(bar.shown_count(&"golden_pen") == 1 and bar.shown_count(&"megaphone") == 0,
		"смена local side переподключает inventory")
	for i in 120:
		bar._process(DT)
	_check(not bar.shown_synergies.has(&"thunder_office"), "смена стороны удаляет чужую синергию")
	bar.queue_free()
	_fresh()
	_grant(["lightning_rod"], 1)
	var carrier := _foe("zombie", Vector2(1000, 300), 1.0)
	carrier.make_elite(true)
	carrier.hp = 1.0
	var next := _foe("zombie", Vector2(1060, 300), 500.0)
	w.hero_of(1).cast(LegionHero.SLOT_Q, carrier.position)
	w._flush_carrier_hits()
	_check(not carrier.alive and int(w.stats.get("item_bolt_hops", 0)) > 0 and next.hp < 500.0,
		"deferred carrier death запускает kill jump владельца")
