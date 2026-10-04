extends SceneTree
## B-402: готовый навык с допустимой целью иногда ждёт ресурс, а не только откат.
## Два человеческих сценария без резерва бота: полный запас и два ранга Маны + линия.

class ChoiceWorld extends LegionWorld:
	var ranks := 0

	func _bonus(key: StringName) -> float:
		if key == &"mana_max_bonus":
			return float(ranks * 20)
		if key == &"mana_regen_bonus":
			return float(ranks * 2)
		return super._bonus(key)

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	_fails += int(not ok)
	print("  %s %s" % ["ok" if ok else "FAIL", what])


func _run() -> void:
	Campaign.set_save_path("user://legion_mana_choice_test.cfg")
	Campaign.reset()
	var w := ChoiceWorld.new()
	w.embedded = true
	root.add_child(w)
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	for ranks in [0, 2]:
		w.ranks = ranks
		w.start_map("_gray")
		w.ability_mana_reserve = 0.0
		var f := w.contracts
		var own := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(250, 300))
		var target := Vector2(700, 200)
		var corpse_at := Vector2(700, 250)
		w.spawn_foe_on_path("zombie", PackedVector2Array([target]), target)
		var corpse := w.spawn_foe_on_path("zombie", PackedVector2Array([corpse_at]), corpse_at)
		corpse.take_damage(10000.0, corpse_at)
		if ranks == 2:
			f.begin(Vector2(200, 200))
			for x in range(212, 381, 12):
				f.extend(Vector2(x, 200))
			f.finish()
			_check(not f.contracts.is_empty() and is_equal_approx(f.mana, 118.4),
				"два ранга: обычная линия 180 px стоит прежние 21,6 из 140")
		_check(w.hero.cast(LegionHero.SLOT_Q, target), "Q по живой цели проходит, рангов %d" % ranks)
		_check(w.hero.cast(LegionHero.SLOT_W, corpse_at),
			"W по свежему трупу проходит, рангов %d" % ranks)
		_check(w.hero.cd_left(LegionHero.SLOT_E) == 0.0
			and not w.hero.e_targets(own.position).is_empty(),
			"E готов и рядом есть допустимый свой боец")
		var before := f.mana
		_check(not w.hero.cast(LegionHero.SLOT_E, own.position),
			"после Q/W ресурса на E недостаточно, хотя откат готов")
		_check(is_equal_approx(f.mana, before) and w.hero.cd_left(LegionHero.SLOT_E) == 0.0,
			"отказ сохраняет ману и готовность E")
		var wait := maxf(0.0, (w.ability_mana(LegionHero.SLOT_E) - f.mana) / f.mana_regen)
		_check(wait > 0.5 and wait < 4.0, "ожидание ресурса ощутимо, но короче четырёх секунд")
		if wait > 0.01:
			f.tick(wait - 0.01, wait - 0.01)
			_check(not w.can_pay_ability(LegionHero.SLOT_E), "перед точной границей маны ещё мало")
			f.tick(0.0101, wait + 0.0001)
			_check(w.hero.cast(LegionHero.SLOT_E, own.position), "восстановленная мана разрешает готовый E")
			_check(w.hero.cd_left(LegionHero.SLOT_E) > 0.0, "только состоявшийся E запускает откат")
	for side in w.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	w.free()
	Campaign.reset()
	print("LEGION MANA CHOICE: %d/%d OK" % [_checks - _fails, _checks])
	quit(int(_fails > 0))
