extends SceneTree
##
## Самопроверка способностей некроманта (пакет hero, DESIGN_V15 §6, §12 п.8–9):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_hero_test.gd -- --mute
##
## Итог «LEGION HERO: N/M OK»; код выхода 1, если что-то упало. Мир настоящий (карта _gray,
## без волн и стартовой армии, in_campaign = true — мета читается из сохранения), ранги и перки —
## настоящим API героя Campaign.hero_rank_up/hero_take_perk на временный save-путь
## (Campaign.set_save_path), реальный user://legion.cfg владельца не трогаем.
##

const SAVE := "user://legion_hero_test.cfg"
const LAB := Vector2(760, 120)   ## та же лаборатория, что у API-теста f0 — тихий кусок _gray

## Мир, где Е закрыта (как профиль серии без открытий, legion_balance_runner): кампания с 26.09
## открывает все три способности сразу, а путь отказа «locked» проверять всё равно надо.
class LockedEWorld extends LegionWorld:
	func camp_stat(key: StringName) -> float:
		return 0.0 if key == &"ability_unlocked_e" else super.camp_stat(key)


var w: LegionWorld
var hero: LegionHero
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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.in_campaign = true
	root.add_child(w)
	await _frames(2)
	Campaign.unlock_all()           # все три слота открыты кампанией
	Campaign._add_hero_xp(3200)     # потолок уровня — 9 очков героя на ранги и перки
	_fresh()
	_test_q_chain()
	_test_q_no_target()
	_test_q_rank_and_perk()
	_test_w_fresh_corpse_only()
	_test_w_cap_evicts_oldest()
	_test_w_boss_excluded()
	_test_e_radius_and_stack()
	_test_e_rank_perk_cap()
	_test_fine_print_perk()
	await _test_unlock_gate()
	Campaign.reset()
	print("LEGION HERO: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.dev_invuln = false
	hero = w.hero
	hero.reset()


## Враг, вкопанный на месте (как _still_foe в API-тесте f0) — удобная цель для опытов.
func _still_foe(type: String, at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at]), at)
	f.speed = 0.0
	return f


func _kill(f: Foe) -> void:
	f.take_damage(100000.0, f.position + Vector2.RIGHT)


func _test_q_chain() -> void:
	_fresh()
	var main := _still_foe("zombie", LAB)
	var near1 := _still_foe("zombie", LAB + Vector2(20, 0))
	var near2 := _still_foe("zombie", LAB + Vector2(-20, 0))
	var near3 := _still_foe("zombie", LAB + Vector2(0, 20))
	var far := _still_foe("zombie", LAB + Vector2(400, 400))
	var ok := hero.cast(LegionHero.SLOT_Q, LAB)
	_check(ok, "Ку срабатывает по цели у курсора")
	var dmg := LegionCfg.Q_CHAIN_DMG
	_check(is_equal_approx(main.hp, float(main.def["hp"]) - float(dmg[0])),
		"главная цель — первое число цепи (HP %.1f)" % main.hp)
	var hit_neighbours := int(near1.hp < float(near1.def["hp"])) \
		+ int(near2.hp < float(near2.def["hp"])) + int(near3.hp < float(near3.def["hp"]))
	_check(hit_neighbours == 3, "цепь без перка достаёт 3 соседей (задето %d)" % hit_neighbours)
	_check(far.hp == float(far.def["hp"]), "цель за радиусом захвата не задета")
	_check(hero.cd_left(LegionHero.SLOT_Q) > 0.0, "Ку ушёл на откат")
	for f in [main, near1, near2, near3, far]:
		_kill(f)


func _test_q_no_target() -> void:
	_fresh()
	var cd0 := hero.cd_left(LegionHero.SLOT_Q)
	var ok := hero.cast(LegionHero.SLOT_Q, LAB + Vector2(900, 900))
	_check(not ok and hero.cd_left(LegionHero.SLOT_Q) == cd0,
		"нет цели — Ку не срабатывает и откат не тратится")


func _test_q_rank_and_perk() -> void:
	_fresh()
	var main := _still_foe("zombie", LAB)
	hero.cast(LegionHero.SLOT_Q, LAB)
	var hp_norank := float(main.def["hp"]) - main.hp
	_kill(main)
	_fresh()
	Campaign.hero_rank_up(&"q")
	Campaign.hero_rank_up(&"q")
	_check(hero.rank(LegionHero.SLOT_Q) == 2, "два ранга Ку читаются из Campaign.stat")
	var main2 := _still_foe("zombie", LAB)
	hero.cast(LegionHero.SLOT_Q, LAB)
	var hp_rank2 := float(main2.def["hp"]) - main2.hp
	_check(hp_rank2 > hp_norank, "ранг 2 бьёт сильнее ранга 0 (%.1f > %.1f)" % [hp_rank2, hp_norank])
	_kill(main2)
	_fresh()
	Campaign.hero_take_perk(&"perk_short_cd")     # ветка Чернокнижника по порядку
	Campaign.hero_take_perk(&"perk_chain_reaction")
	var m := _still_foe("zombie", LAB)
	var extras: Array[Foe] = []
	for i in 4:
		extras.append(_still_foe("zombie", LAB + Vector2(10.0 * (i + 1), 0)))
	hero.cast(LegionHero.SLOT_Q, LAB)
	var hit := 0
	for f in extras:
		if f.hp < float(f.def["hp"]):
			hit += 1
	_check(hit == 4, "перк «Цепная реакция» добавляет пятую цель (задето соседей %d/4)" % hit)
	_kill(m)
	for f in extras:
		_kill(f)


func _test_w_fresh_corpse_only() -> void:
	_fresh()
	var fresh := _still_foe("zombie", LAB)
	_kill(fresh)
	var old := _still_foe("zombie", LAB + Vector2(200, 0))
	_kill(old)
	old._dead_t = LegionCfg.HERO_CORPSE_TTL + 1.0   # состарить труп мимо окна подъёма
	var ok_old := hero.cast(LegionHero.SLOT_W, old.position)
	_check(not ok_old and hero.vassal_count() == 0, "старый труп Дубль-вэ не поднимает")
	var ok_fresh := hero.cast(LegionHero.SLOT_W, fresh.position)
	_check(ok_fresh and hero.vassal_count() == 1, "свежий труп встаёт внештатником")
	_check(not w.foes.has(fresh), "поднятый труп убран из world.foes")
	_fresh()
	var first := _still_foe("zombie", LAB)
	var live := _still_foe("zombie", LAB + Vector2(30, 0))
	w.grid.rebuild()
	_kill(first)
	hero.cast(LegionHero.SLOT_W, LAB)
	_check(w.grid.nearest_foe(live.position, 50.0, true) == live,
		"W после rebuild сохраняет поиск живого врага со сдвинутым индексом")
	_fresh()
	var shield := _still_foe("shield_inspector", LAB)
	_kill(shield)
	hero.cast(LegionHero.SLOT_W, LAB)
	_check(hero._vassals[0]._view.char_id == LegionCfg.CORE_SHIELD_INSPECTOR["char"],
		"поднятый щитоносец использует персонажа из определения врага")


## v20 (D-0926-39): Дубль-вэ поднимает бригадой до W_RAISE_MAX; потолок W_MAX_ALLIES — два каста
## бригадой; сверх потолка вытесняются самые давние. (До v20: по одному, потолок 2.)
func _test_w_cap_evicts_oldest() -> void:
	_fresh()
	# три кучки трупов по W_RAISE_MAX, кучки дальше двух радиусов друг от друга
	var spots: Array[Vector2] = [LAB, LAB + Vector2(220, 0), LAB + Vector2(440, 0)]
	for at in spots:
		for i in LegionCfg.W_RAISE_MAX:
			_kill(_still_foe("zombie", at + Vector2(i * 20, 0)))
	_check(hero.cast(LegionHero.SLOT_W, spots[0]), "первая бригада поднята")
	var first_batch: Array = hero._vassals.duplicate()
	# Проверяем вытеснение бригад: откат и ресурс между отдельными подъёмами восполняем.
	hero._cd[LegionHero.SLOT_W] = 0.0
	w.contracts.mana = w.contracts.mana_max
	_check(hero.cast(LegionHero.SLOT_W, spots[1]), "вторая бригада поднята")
	hero._cd[LegionHero.SLOT_W] = 0.0
	_check(hero.vassal_count() == LegionCfg.W_MAX_ALLIES,
		"два каста бригадой — потолок %d внештатников" % LegionCfg.W_MAX_ALLIES)
	w.contracts.mana = w.contracts.mana_max
	_check(hero.cast(LegionHero.SLOT_W, spots[2]), "третья бригада поднята")
	var evicted := true
	for v in first_batch:
		evicted = evicted and not hero._vassals.has(v)
	_check(hero.vassal_count() == LegionCfg.W_MAX_ALLIES and evicted,
		"третья бригада вытесняет самых давних, потолок держится")


func _test_w_boss_excluded() -> void:
	_fresh()
	var boss := _still_foe("boss", LAB)
	_kill(boss)
	var ok := hero.cast(LegionHero.SLOT_W, boss.position)
	_check(not ok and hero.vassal_count() == 0, "босс недоступен Дубль-вэ даже свежим трупом")


func _test_e_radius_and_stack() -> void:
	_fresh()
	var inside := w.spawn_unit(LegionCfg.KIND_LABORER, LAB + Vector2(50, 0))
	var outside := w.spawn_unit(LegionCfg.KIND_LABORER, LAB + Vector2(400, 0))
	var ok := hero.cast(LegionHero.SLOT_E, LAB)
	_check(ok, "Аврал срабатывает при живых бойцах в радиусе")
	_check(is_equal_approx(inside.haste_speed_mult, LegionCfg.E_SPEED_MULT)
			and is_equal_approx(inside.haste_dmg_mult, LegionCfg.E_DMG_MULT),
		"боец в радиусе получает ускорение и бонус урона")
	_check(is_equal_approx(outside.haste_speed_mult, 1.0), "боец за радиусом не тронут")
	hero._cd[LegionHero.SLOT_E] = 0.0
	hero.cast(LegionHero.SLOT_E, LAB)
	_check(is_equal_approx(inside.haste_speed_mult, LegionCfg.E_SPEED_MULT),
		"повторный каст не складывает множитель (не ×2,25)")
	hero.tick(LegionCfg.E_DURATION_CAP + 1.0)
	_check(is_equal_approx(inside.haste_speed_mult, 1.0) and is_equal_approx(inside.haste_dmg_mult, 1.0),
		"по истечении Аврала бонус снят")
	inside.take_damage(100000.0, LAB)
	outside.take_damage(100000.0, LAB)


func _test_e_rank_perk_cap() -> void:
	_fresh()
	Campaign.hero_rank_up(&"e")
	Campaign.hero_rank_up(&"e")
	Campaign.hero_take_perk(&"perk_overtime")
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, LAB)
	hero.cast(LegionHero.SLOT_E, LAB)
	_check(is_equal_approx(hero._haste_left, LegionCfg.E_DURATION_CAP),
		"ранг 2 + перк «Сверхурочные» упираются в потолок 8 с (сейчас %.1f)" % hero._haste_left)
	u.take_damage(100000.0, LAB)


## polish1 (ревью 25.09.2026): перк «Мелкий шрифт» (ветка «Юрист») был описан, но нигде не
## переводился в ключ боя — бой его не применял. Проверяем всю цепочку: camp_stat("mana_cost_mult")
## после взятия перка, ContractField.setup() снимает его в поле при старте карты, а новый Contract
## несёт множитель сам (Contract.mana_per_px() == Contract.base_price(kind) * mult).
func _test_fine_print_perk() -> void:
	# свежий прогресс: предыдущие тесты этого файла уже разобрали 7 из 9 очков героя на ранги
	# и другие ветки — на «Юриста» (3 перка подряд) их не хватит.
	Campaign.reset()
	Campaign.unlock_all()
	Campaign._add_hero_xp(3200)
	_fresh()
	var kind: StringName = LegionCfg.KIND_LABORER
	var base := Contract.base_price(kind)
	_check(is_equal_approx(w.contracts.mana_cost_mult, 1.0),
		"mana_cost_mult 1.0 до «Мелкого шрифта»")
	var c := w.contracts.add_contract(
		PackedVector2Array([LAB, LAB + Vector2(100, 0)]), 1, false, kind)
	_check(c != null and is_equal_approx(c.mana_per_px(), base),
		"цена договора без перка — базовая (Contract.mana_per_px == base_price)")
	_check(Campaign.hero_take_perk(&"perk_settlement_on_time"), "«Расчёт в срок» берётся")
	_check(Campaign.hero_take_perk(&"perk_far_call"),
		"«Дальний призыв» берётся после «Расчёта в срок»")
	_check(Campaign.hero_take_perk(&"perk_fine_print"),
		"«Мелкий шрифт» берётся после «Дальнего призыва»")
	_check(is_equal_approx(Campaign.stat(&"mana_cost_mult"), 0.9),
		"camp_stat mana_cost_mult = 0.9 (−10 %) после «Мелкого шрифта»")
	_fresh()   # новая карта — ContractField.setup() перечитывает camp_stat заново
	_check(is_equal_approx(w.contracts.mana_cost_mult, 0.9),
		"ContractField снимает perk_fine_print при setup()")
	var c2 := w.contracts.add_contract(
		PackedVector2Array([LAB, LAB + Vector2(100, 0)]), 1, false, kind)
	_check(c2 != null and is_equal_approx(c2.mana_per_px(), base * 0.9),
		"новый договор несёт множитель перка — цена линии на 10% ниже")


func _test_unlock_gate() -> void:
	# одно правило открытий (integrate1): в кампании — по порядку карт (meta), вне — всё открыто
	Campaign.reset()
	_fresh()
	# кампания v20 (D-0926-46): Ку — с первой карты, Дубль-вэ и Е — с «Развилки»
	_check(hero.is_unlocked(LegionHero.SLOT_Q) and not hero.is_unlocked(LegionHero.SLOT_W)
			and not hero.is_unlocked(LegionHero.SLOT_E),
		"новая кампания: Ку открыта с первой карты, Дубль-вэ и Е — ещё нет")
	var locked := LockedEWorld.new()
	locked.embedded = true
	locked.in_campaign = true
	locked.dev["no_waves"] = "1"
	locked.dev["spawn_units"] = "0"
	root.add_child(locked)
	await _frames(2)
	locked.start_map("_gray")
	var failed := []
	locked.hero.cast_failed.connect(
		func(slot: int, reason: StringName) -> void: failed.append([slot, reason]))
	var ok := locked.hero.cast(LegionHero.SLOT_E, LAB)
	_check(not ok and failed.size() == 1 and failed[0][1] == &"locked",
		"закрытый Е не кастуется, отказ с причиной locked")
	locked.queue_free()
	await _frames(1)
	Campaign.unlock_all()
	_check(hero.is_unlocked(LegionHero.SLOT_W) and hero.is_unlocked(LegionHero.SLOT_E),
		"пройденные карты открывают Дубль-вэ и Е")
	Campaign.reset()
	w.in_campaign = false
	_check(hero.is_unlocked(LegionHero.SLOT_W) and hero.is_unlocked(LegionHero.SLOT_E),
		"вне кампании (гейт, серии) все слоты открыты")
	Campaign._add_hero_xp(3200)
	Campaign.hero_rank_up(&"q")
	_check(hero.rank(LegionHero.SLOT_Q) == 0, "вне кампании прокачка нейтральна (ранг 0)")
	w.in_campaign = true
