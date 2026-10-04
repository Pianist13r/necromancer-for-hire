extends SceneTree
## Проверка ownership/credit/геометрии в настоящем мире; без сетевого клиента.
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
	Campaign.set_save_path("user://pvp_items_test.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
	for id in ["pvp:duel", "gen:7:3:pvp"]:
		w.start_map(id)
		for contested in [false, true]:
			for side in 2:
				var f := w._spawn_pvp_carrier(side, contested)
				_check(f != null, "%s carrier side%d contested%s" % [id, side, contested])
				if f == null:
					continue
				_check(f.elite and f.carrier, "носитель элитный и помечен")
				_check(w.terrain.connected(f.position, w.cauldron_of(0))
					and w.terrain.connected(f.position, w.cauldron_of(1)), "до носителя есть путь обоим")
				var winner := 1 - side
				var before := w.items_of(winner).total()
				var loser_before := w.items_of(side).total()
				f.last_hit_side = winner
				f.take_damage(f.hp + 1.0, f.position)
				w._flush_carrier_hits()
				_check(w.items_of(winner).total() == before + 1, "предмет получает убийца")
				_check(w.items_of(side).total() == loser_before, "целевая половина не получает предмет")
				f.last_hit_side = side
				f.take_damage(1000.0, f.position)
				w.items_of(side)._on_foe_killed(f, f.position)
				_check(w.items_of(side).total() == loser_before, "повторная смерть не даёт вторую награду")
	w.start_map("pvp:duel")
	var base0 := w.sides[0].hero.q_chain_len()
	w.items_of(1).grant(&"clip_of_fate")
	_check(w.sides[0].hero.q_chain_len() == base0, "предмет стороны1 не меняет сторону0")
	_check(w.sides[1].hero.q_chain_len() == base0 + 2, "предмет стороны1 действует")
	var summoned := w._spawn_pvp_carrier(0, false)
	summoned.set_meta(&"summoned", true)
	summoned.last_hit_side = 1
	var owned := w.items_of(1).total()
	summoned.take_damage(summoned.hp + 1.0, summoned.position)
	w._flush_carrier_hits()
	_check(w.items_of(1).total() == owned, "призванный elite не фармит предметы")
	_test_ties()
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION PVP ITEMS: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)


func _tie(seed_value: int, reverse: bool) -> int:
	w._base_seed = seed_value
	w.start_map("pvp:duel")
	var f := w._spawn_pvp_carrier(0, false)
	if f == null:
		return -1
	var amount := f.hp * 0.6
	var order := [1, 0] if reverse else [0, 1]
	for side: int in order:
		f.last_hit_side = side
		f.take_damage(amount, f.position)
	_check(f.alive, "одновременный урон ждёт конца тика")
	w._flush_carrier_hits()
	_check(not f.alive and w.items_of(0).total() + w.items_of(1).total() == 1,
		"одна смерть и одна награда после суммарного смертельного урона")
	return f.last_hit_side


func _test_ties() -> void:
	var wins := [0, 0]
	for seed_value in range(1, 17):
		var first := _tie(seed_value, false)
		var reverse := _tie(seed_value, true)
		_check(first == reverse, "перестановка атак не меняет credit seed%d" % seed_value)
		if first >= 0:
			wins[first] += 1
	_check(wins[0] > 0 and wins[1] > 0, "точные ничьи не отдаются всегда стороне0")
