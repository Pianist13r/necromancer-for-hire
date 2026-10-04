extends SceneTree
## Стык L1/L2 и экономики master: настоящее поле генератора распознаётся как PvP,
## а срочный найм стороны оплачивается её душами, независимо от богатства соперника.

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
	Campaign.set_save_path("user://legion_pvp_integration_test.cfg")
	Campaign.reset()
	_test_generated_map()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_generated_world()
	_test_rush_ownership()
	Campaign.reset()
	w.queue_free()
	await process_frame
	print("LEGION PVP INTEGRATION: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)


func _test_generated_map() -> void:
	var raw := ProcGen.map_from_id("gen:7:3:pvp")
	var digest := ProcGen.digest(raw)
	var map := LegionWorld.load_map("gen:7:3:pvp")
	var sides: Array = map.get("sides", [])
	_check(sides.size() == 2, "генерированное поле имеет две игровые стороны")
	_check(float(map.get("cauldron_hp", 0)) == PvpRules.CAULDRON_HP,
		"Котлы генератора используют правила PvP")
	_check(int(map.get("start_army", 0)) == PvpMaps.START_ARMY,
		"стартовый штат генератора совпадает с PvP")
	_check(ProcGen.digest(ProcGen.map_from_id("gen:7:3:pvp")) == digest,
		"адаптация игрового поля не меняет кэш генератора")
	if sides.size() == 2:
		_check(sides[0]["cauldron"] == raw["cauldrons"][0]["pos"]
			and sides[1]["cauldron"] == raw["cauldrons"][1]["pos"], "Котлы сторон на местах L2")


func _test_generated_world() -> void:
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
	w.start_map("gen:7:3:pvp")
	_check(w.pvp and w.sides.size() == 2, "мир генератора запускает настоящий бой двух сторон")
	if w.sides.size() != 2:
		return
	_check(w.sides[0].cauldron_hp == w.sides[1].cauldron_hp
		and w.sides[0].cauldron_hp == PvpRules.CAULDRON_HP, "у обоих Котлов одинаковое PvP-здоровье")
	_check(w.sides[0].staff.plots.size() == w.sides[1].staff.plots.size()
		and not w.sides[1].staff.plots.is_empty(), "обе стороны владеют своими площадками")
	_check(not w.sides[0].contracts.delay_enabled and not w.sides[1].contracts.delay_enabled,
		"на поле генератора нет одиночной Отсрочки")
	for i in 60:
		w._step(1.0 / 60.0)
	_check(w.phase == LegionWorld.Phase.BATTLE, "генерированный PvP-мир живёт после 60 шагов")


func _rush_fixture() -> LegionBuilding:
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
	w.start_map("pvp:duel")
	w.sides[1].souls = 1000
	var st: LegionStaff = w.sides[1].staff
	var b := st.build(st.plots[0], LegionCfg.KIND_LABORER)
	# Свежие пустые места превращаем в места павших, не вмешиваясь в правила оплаты.
	b.slot_fresh.fill(0)
	return b


func _test_rush_ownership() -> void:
	var b := _rush_fixture()
	w.sides[0].souls = 1000
	w.sides[1].souls = 0
	_check(w.sides[1].staff.rush(b) == 0 and b.alive_count() == 0,
		"богатство соперника не оплачивает найм бедной стороны")
	b = _rush_fixture()
	w.sides[0].souls = 0
	w.sides[1].souls = 1000
	var price := w.sides[1].staff.rush_price(b)
	var count := b.waiting_count()
	_check(w.sides[1].staff.rush(b) == count and w.sides[1].souls == 1000 - price
		and w.sides[0].souls == 0, "свои души оплачивают найм при пустом кошельке соперника")
