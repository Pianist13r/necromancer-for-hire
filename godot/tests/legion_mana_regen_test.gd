extends SceneTree
## B-402: восстановление оставляет выбор между длинной линией и повторным кастом.
## Контракт кандидата 10/с: точная оплата Ку, бонусы и прежняя экономика обеих сторон PvP.

class ManaWorld extends LegionWorld:
	var mana_bonus := 0.0
	var capacity_bonus := 0.0

	func _bonus(key: StringName) -> float:
		return camp_stat(key)

	func camp_stat(key: StringName) -> float:
		if key == &"mana_regen_bonus":
			return mana_bonus
		if key == &"mana_max_bonus":
			return capacity_bonus
		return super.camp_stat(key)

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _run() -> void:
	Campaign.set_save_path("user://legion_mana_regen_test.cfg")
	Campaign.reset()
	var w := ManaWorld.new()
	w.embedded = true
	root.add_child(w)
	w.dev["no_waves"] = "1"
	w.start_map("_gray")
	w.set_process(false)
	var f := w.contracts
	f.mana = 20.0
	for i in 300:
		f.tick(1.0 / 60.0, float(i) / 60.0)
	_check(is_equal_approx(f.mana, 70.0), "за пять секунд вернулись 50 маны, а не 60")
	f.mana = 0.0
	f.tick(4.0, 4.0)
	_check(not w.can_pay_ability(LegionHero.SLOT_Q), "четырёх секунд от нуля ещё мало для Ку")
	f.tick(0.5, 4.5)
	_check(w.can_pay_ability(LegionHero.SLOT_Q) and is_equal_approx(f.mana, 45.0),
		"через 4,5 с хватает ровно на Ку")
	f.mana = 99.0
	f.tick(1.0, 3.5)
	_check(is_equal_approx(f.mana, 100.0), "потолок маны сохранён")
	w.mana_bonus = 4.0
	w.capacity_bonus = 40.0
	w.configure_contract_mana(f)
	f.mana = 0.0
	f.tick(5.0, 8.5)
	_check(is_equal_approx(f.mana, 70.0), "два ранга Маны добавляют прежние +4/с")
	_check(is_equal_approx(f.mana_max, 140.0), "два ранга сохраняют +40 запаса")
	w.mana_bonus = 0.0
	w.capacity_bonus = 0.0
	w.start_map("pvp:duel")
	w.set_process(false)
	for side in w.sides:
		side.contracts.mana = 0.0
		side.contracts.tick(5.0, 5.0)
		_check(is_equal_approx(side.contracts.mana, 60.0),
			"PvP сторона %d сохраняет 12 маны/с" % side.index)
	_check(w.ability_mana(LegionHero.SLOT_Q) == 25.0
		and w.ability_mana(LegionHero.SLOT_W) == 30.0
		and w.ability_mana(LegionHero.SLOT_E) == 20.0, "PvP сохраняет цены 25/30/20")
	for side in w.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	w.free()
	print("LEGION MANA REGEN: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
