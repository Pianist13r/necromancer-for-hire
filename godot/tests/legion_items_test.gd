extends SceneTree
##
## Артефакты и элитные враги (Игорь 26.09: «предметы, как в Айзеке… выпадали из элитных… но
## не всегда»; v2 27.09, D-0927-163: 13 артефактов, каждый меняет, как играешь; редкость,
## забег и вид — tests/legion_items_v2_test.gd):
##   1) элитный рождается с шансом по сиду воспроизводимо; только враг волны и нужных видов;
##   2) элитный толще втрое, в короне, даёт больше душ;
##   3) обычный элитный артефакт не роняет; --dev drop — роняет; выпавший долетает в полоску
##      и показывает карточку;
##   4) ЦИКЛ ПО РЕЕСТРУ: каждый числовой артефакт меняет своё число игры; каждый особый
##      срабатывает на своё событие (с ним эффект есть, без — нет); каждая синергия
##      добавляет эффект сверх своих артефактов;
##   5) артефакт уникален; новый одиночный бой сбрасывает артефакты;
##   6) полоска не перехватывает мышь и не заезжает на карточки видов; подсказка по курсору;
##   7) колода поправок к договору (AmendmentDb) — это пул меты целиком, старые поправки
##      переведены миграцией, и каждая карточка меняет число игры.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_items_test.gd -- --mute
##
## Итог «LEGION ITEMS: N/M OK»; код выхода 1, если что-то упало. Мир настоящий, сохранение
## временное, рельеф плоский; время ведём сами (тикаем только то, что проверяем).
##

const SAVE := "user://legion_items_test.cfg"
const DT := 1.0 / 60.0
## Поправки, которые были до расширения пула 26.09 (их проверяют другие тесты).
const OLD_UPGRADES := [
	"overtime_clause", "aggressive_lawyers", "courier_bonus", "night_shift_hr",
	"outstaff_partner", "signing_bonus", "coffee_machine", "expanded_budget",
	"union_contract", "cauldron_insurance",
]

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
	_test_elite_roll()
	_test_elite_body()
	_test_drop()
	_test_numeric_items()
	_test_behavior_items()
	_test_synergies()
	_test_unique()
	_test_reset()
	_test_bar()
	_test_upgrades()
	_test_verify_fixes()
	Campaign.reset()
	print("LEGION ITEMS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── оснастка ────────────────────────────────────────────────────────────────

func _fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.dev.erase("elite")
	w.dev.erase("drop")
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.dev_invuln = false
	w.contracts.active = true
	# тесты эффектов предметов кастуют реальный Q/W/R — нужна мана (zero-cost способности больше нет)
	w.contracts.mana = LegionCfg.MANA_MAX
	w.hero.reset()
	_spot = 0


## Враг, стоящий в точке at (путь — к Котлу). wave > 0 — как из волны (бросок на элитного).
func _foe(type: String, at: Vector2, hp := -1.0, wave := 0) -> Foe:
	var origin := {"wave": wave} if wave > 0 else {}
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at, w.cauldron_pos]), at, false, origin)
	if hp > 0.0:
		f.hp = hp
		f.max_hp = hp
	return f


## Каждый вызов — новая точка, чтобы враги прошлых замеров не мешали.
func _next_spot() -> Vector2:
	_spot += 1
	return Vector2(560.0 + float(_spot % 6) * 90.0, 140.0 + float(_spot / 6) * 90.0)


func _kill(f: Foe) -> void:
	f.take_damage(f.hp + 1.0, f.position + Vector2(10, 0))


func _line(at: Vector2, length := 128.0) -> Contract:
	return w.contracts.add_contract(PackedVector2Array([at, at + Vector2(0, length)]), 1, false)


func _ring(center: Vector2, r: float) -> Contract:
	var pts := PackedVector2Array()
	for i in 25:
		var a := TAU * float(i) / 24.0
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return w.contracts._create(pts, 1, LegionCfg.KIND_LABORER, true)


func _man(c: Contract) -> int:
	var n := 0
	for p in c.posts:
		if p["dead"] or p["unit"] != null:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		n += 1
	return n


func _tick_items(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		w.items.tick(DT)
		t += DT


func _grant(ids: Array) -> void:
	for id in ids:
		w.items.grant(StringName(id))


# ── 1–3. элитные и выпадение ────────────────────────────────────────────────

func _elite_pattern(seed_v: int, n: int) -> Array[int]:
	_fresh()
	w.rng.seed = seed_v
	var out: Array[int] = []
	for i in n:
		var f := _foe("zombie", Vector2(900, 100 + (i % 50) * 10), -1.0, 1)
		if f.elite:
			out.append(i)
	return out


func _test_elite_roll() -> void:
	print("— элитный: шанс по сиду, воспроизводимо")
	var a := _elite_pattern(42, 300)
	var b := _elite_pattern(42, 300)
	var c := _elite_pattern(43, 300)
	_check(a == b, "тот же сид — те же элитные (%d из 300)" % a.size())
	_check(a != c, "другой сид — другие элитные")
	_check(a.size() >= 4 and a.size() <= 25, "частота около %d %% (%d/300)" % [
		int(CfgItems.ELITE_CHANCE * 100), a.size()])
	_fresh()
	w.dev["elite"] = "1"
	var plain := _foe("zombie", Vector2(900, 200))
	_check(not plain.elite, "не из волны (свита, тестовые) — не элитный")
	var kinds_ok := true
	for t in ["boss", "lawyer", "mimic"]:
		if _foe(t, Vector2(900, 300), -1.0, 1).elite:
			kinds_ok = false
	_check(kinds_ok, "босс, Юрист, мимик элитными не бывают")
	_check(_foe("beetle", Vector2(900, 400), -1.0, 1).elite, "курьер из волны при шансе 1 — элитный")
	w.tutorial = LegionTutorial.new()
	# урок, держащий волну (обучение «Пустыря»), — без элитных (v20: уроки идут на всех картах,
	# элитных глушит только держащий)
	w.tutorial.active = true
	w.tutorial._hold_on = true
	_check(not _foe("zombie", Vector2(900, 500), -1.0, 1).elite, "во время обучения — не элитный")
	w.tutorial = null
	w.dev.erase("elite")
	_test_elite_guaranteed()


## Карта «Архив»: поле группы `elite: N` — первые N врагов группы элитные без броска (урок
## «элитный и первый предмет»); остальные бросают обычный шанс (здесь шанс 0 — не элитные).
func _test_elite_guaranteed() -> void:
	print("— гарантированный элитный из поля волны")
	_fresh()
	w.dev["elite"] = "0"
	var runner := WaveRunner.new()
	runner.setup(w, {"waves": [{"pause": 0.0, "groups": [
		{"road": "east", "type": "zombie", "count": 3, "elite": 1, "interval": 0.1}]}]})
	for i in 60:
		runner.tick(1.0 / 30.0)
	var flags: Array[bool] = []
	for f in w.foes:
		if f.alive and int(f.origin.get("wave", 0)) == 1:
			flags.append(f.elite)
	_check(flags == [true, false, false], "первый из трёх элитный, остальные нет (%s)" % [flags])
	w.dev.erase("elite")


func _test_elite_body() -> void:
	print("— элитный толще, в короне, даёт больше душ")
	_fresh()
	w.dev["elite"] = "1"
	var e := _foe("zombie", Vector2(700, 300), -1.0, 1)
	w.dev.erase("elite")
	var n := _foe("zombie", Vector2(700, 400))
	# враг волны: сначала темп читаемости и уровень (LegionChallenge.toughen, D-0927-49), потом ×3
	var base := float(LegionCfg.FOES["zombie"]["hp"]) * LegionChallenge.PACE_HP \
		* LegionChallenge.value(w.difficulty, "hp")
	_check(is_equal_approx(e.hp, base * CfgItems.ELITE_HP_MULT) and is_equal_approx(e.max_hp, e.hp),
		"HP элитного ×%s (%.0f)" % [CfgItems.ELITE_HP_MULT, e.hp])
	_check(e.view.scale.x > 1.1 and n.view.scale.x == 1.0, "элитный крупнее")
	var marked := false
	for ch in e.get_children():
		marked = marked or ch is LegionEliteMark
	_check(marked, "ореол и корона (LegionEliteMark)")
	var s0 := w.souls
	_kill(n)
	var plain_souls := w.souls - s0
	s0 = w.souls
	_kill(e)
	var elite_souls := w.souls - s0
	_check(elite_souls == int(round(plain_souls * CfgItems.ELITE_SOULS_MULT)) and elite_souls > plain_souls,
		"души: обычный %d, элитный %d" % [plain_souls, elite_souls])
	_check(int(w.stats.get("elites_killed", 0)) == 1, "убитый элитный посчитан")


func _test_drop() -> void:
	print("— выпадение по шансу, полёт в полоску, карточка")
	_fresh()
	w.dev["elite"] = "1"
	w.dev["drop"] = "0"
	_kill(_foe("zombie", Vector2(700, 300), -1.0, 1))
	_check(w.items.total() == 0, "шанс 0 — ничего не выпало")
	w.dev["drop"] = "1"
	var e := _foe("zombie", Vector2(700, 300), -1.0, 1)
	_kill(e)
	_check(w.items.total() == 1, "шанс 1 — выпал предмет")
	_kill(_foe("zombie", Vector2(720, 300), -1.0, 0))
	_check(w.items.total() == 1, "обычный враг не роняет")
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	_check(bar.in_flight() == 1 and bar.shown.is_empty(), "предмет сначала летит, полоска пуста")
	var t := 0.0
	while t < 1.0:
		bar._process(DT)
		t += DT
	_check(bar.in_flight() == 1, "через 1 с ещё лежит на земле (видно, что выпало)")
	while t < 3.0:
		bar._process(DT)
		t += DT
	var id: StringName = w.items.counts.keys()[0]
	_check(bar.in_flight() == 0 and bar.shown_count(id) == 1, "долетел в полоску: %s" % id)
	var card := bar.current_card()
	_check(String(card.get("title", "")).begins_with("Артефакт: ") and card.get("id") == id,
		"карточка «%s — %s»" % [card.get("title", ""), card.get("text", "")])
	# v2: без --dev drop обычный элитный (не носитель) не роняет никогда
	w.dev.erase("drop")
	w.items.reset()
	var drops := 0
	for i in 100:
		var f := _foe("zombie", Vector2(900, 100 + (i % 40) * 12), -1.0, 1)
		var before := w.items.total()
		_kill(f)
		if w.items.total() > before:
			drops += 1
	_check(drops == 0, "100 обычных элитных — артефактов %d (роняет только носитель)" % drops)
	w.dev.erase("elite")


# ── 4. реестр: числа ────────────────────────────────────────────────────────

## Замер числа игры по ключу mods. Все замеры растут вместе с суммой ключа, поэтому знак
## изменения обязан совпасть со знаком прибавки предмета.
func _probe(key: String) -> float:
	var h := w.hero
	match key:
		"q_chain":
			return float(h.q_chain_len())
		"q_stun":
			return h.q_stun()
		"q_dmg":
			return h.q_damage(0)
		"w_raise":
			return float(h.w_raise_max())
		"e_dur":
			return h.e_duration()
		"mana_regen":
			return w.contracts.mana_regen
		"seg_ttl", "seg_ttl_bonus":
			return _line(_next_spot()).ttl
		"charge_dmg":
			var at := _next_spot()
			var z := _foe("zombie", at, 1000.0)
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, at + Vector2(-12, 0))
			u._atk_cd = 0.0
			u._strike(z, 1.0, true)
			return 1000.0 - z.hp
		"perfect_zone":
			return w.perfect_zone_frac()
		"press_hold":
			var c := _line(_next_spot())
			_man(c)
			var posted := 0
			for p in c.posts:
				posted += 1 if int(p["seg"]) == 0 and p["unit"] != null else 0
			# перевес толпы полуторный — ниже потолка PRESS_RATIO_CAP, иначе прогиб одинаков
			var mass := float(posted) * 1.5
			var mid := c.seg_center(0)
			w.grid.press_scan(c, LegionCfg.PRESS_BAND)   # размечает массивы давки участков
			c.press_mass[0] = mass
			c.press_sum[0] = (mid + c.seg_dir(0) * 20.0) * mass
			c.seg_bend[0] = 0.0
			w._press_segment(c, 0, 0.1)
			return -c.seg_bend[0]
		"souls":
			var s0 := w.souls
			_kill(_foe("zombie", _next_spot()))
			return float(w.souls - s0)
		"rally_cd":
			return w.rally_cd_total()
		"line_cost":
			return w.contracts.mana_cost_mult
		"elite_chance":
			w.rng.seed = 11
			var n := 0
			for i in 300:
				if _foe("zombie", Vector2(1000, 100 + (i % 50) * 10), -1.0, 1).elite:
					n += 1
			return float(n)
		"item_luck":
			# боёв с носителями из 200 сидов («Стол находок» перебрасывает пустой бой)
			var n := 0
			for s in 200:
				w._base_seed = 500 + s
				w.items.plan_battle(5)
				n += 0 if w.items.plan.is_empty() else 1
			w._base_seed = 1
			return float(n)
		"twin_spawn":
			# сколько бойцов рождает Котёл за шаг, когда истёк один таймер места
			var b: LegionBuilding = w.staff.cauldron
			b.set_staff(4, 30.0)
			b.fill_now(10)
			for u in b.slot_unit.duplicate():
				if u != null:
					u.take_damage(9999.0, u.position)
			for i in b.slot_t.size():
				b.slot_t[i] = 1.0 + float(i) * 10.0
			var n0 := b.alive_count()
			b.tick(1.05, 99)
			return float(b.alive_count() - n0)
		"e_radius":
			return w.hero.e_radius()
		"start_souls":
			return float(w.souls)
		"mana_cost_mult":
			return w.contracts.mana_cost_mult
		# ── ключи карточек поправок AmendmentDb (пул постоянных процентов заменён рогаликом) ──
		# Штат и возрождение построек: множитель вида → сколько мест/секунд даёт база 100/10.
		"cap_mult_laborer", "cap_mult_guard", "cap_mult_clerk":
			return float(w.staff.staff_cap(StringName(key.trim_prefix("cap_mult_")), 100))
		"respawn_mult_laborer", "respawn_mult_guard", "respawn_mult_clerk":
			return w.staff.staff_respawn(StringName(key.trim_prefix("respawn_mult_")), 10.0)
		# Радиус набора договора: поле хранит итоговый радиус (база вида + прибавка меты).
		"recruit_r_laborer", "recruit_r_guard", "recruit_r_clerk":
			return float(w.contracts.recruit_r.get(StringName(key.trim_prefix("recruit_r_")), 0.0))
		"settlement_mult":
			return w.contracts.settlement_mult
		"mana_max_bonus":
			return w.contracts.mana_max
		"ability_mana_mult":
			return w.ability_mana(0)
		"hold_armor":
			# Единственный замер «наоборот»: выше броня — меньше урон, поэтому возвращаем −урон,
			# чтобы знак изменения совпал со знаком прибавки (как у press_hold).
			var c := _line(_next_spot())
			_man(c)
			var target: Legionnaire = null
			for p in c.posts:
				if p["unit"] != null:
					target = p["unit"]
					break
			if target == null:
				return NAN
			var hp0 := target.hp
			target.take_damage(100.0, target.position + (c.posts[0]["normal"] as Vector2) * 10.0)
			return -(hp0 - target.hp)
		"charge_dmg_mult":
			# урон натиска: _free_strike бьёт множителем натиска только в окне _bonus_t после
			# рывка (вне окна — обычный удар ×1), поэтому окно ставим сами
			var at2 := _next_spot()
			var z2 := _foe("zombie", at2, 100000.0)
			var u2 := w.spawn_unit(LegionCfg.KIND_LABORER, at2 + Vector2(-12, 0))
			u2._bonus_t = LegionCfg.CHARGE_BONUS_TIME
			u2._free_strike(z2)
			return 100000.0 - z2.hp
		"charge_speed_mult":
			# натиск по прямой без врагов: сколько боец пробегает за первые 10 шагов (далеко до
			# предела дальности, поэтому замер не упирается в потолок)
			var u3 := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(200, 360))
			var from := u3.position
			u3.start_charge(Vector2.RIGHT)
			for i in 10:
				w.now += DT
				w.grid.rebuild()
				u3.tick(DT)
			return u3.position.x - from.x
	return NAN


func _test_numeric_items() -> void:
	print("— реестр: каждый числовой предмет меняет своё число игры")
	var n := 0
	for id in LegionItemDb.ids():
		var e := LegionItemDb.item(id)
		var mods: Dictionary = e.get("mods", {})
		if mods.is_empty():
			continue
		n += 1
		for key: String in mods:
			_fresh()
			var before := _probe(key)
			if is_nan(before):
				_check(false, "%s: нет замера для ключа %s" % [id, key])
				continue
			w.items.grant(id)
			var after := _probe(key)
			_check((after - before) * signf(float(mods[key])) > 0.0,
				"%s «%s»: %s %.3f → %.3f" % [id, e["title"], key, before, after])
	# Ку по-настоящему: оглушение цели цепи со «Скрепкой судьбы» ×1,5
	_fresh()
	w.items.grant(&"clip_of_fate")
	var z := _foe("zombie", Vector2(700, 300), 500.0)
	w.hero.cast(LegionHero.SLOT_Q, z.position)
	_check(is_equal_approx(z.stun_t, LegionCfg.Q_STUN * 1.5), "каст Ку оглушает на %.2f с" % z.stun_t)
	print("  (числовых предметов: %d)" % n)


# ── 4. реестр: особое поведение и синергии ──────────────────────────────────

## Замер эффекта особого предмета или синергии id, при выданных предметах grant.
## Возвращает число, которое растёт, только если эффект сработал.
func _measure(id: String, grant: Array) -> float:
	_fresh()
	_grant(grant)
	var h := w.hero
	match id:
		"golden_pen":
			h._cd[LegionHero.SLOT_Q] = 5.0
			w._charge_feedback(Vector2(600, 300), true)
			return 5.0 - h.cd_left(LegionHero.SLOT_Q)
		"lightning_rod":
			_foe("zombie", Vector2(600, 300), 1.0)
			_foe("zombie", Vector2(660, 300), 500.0)
			h.cast(LegionHero.SLOT_Q, Vector2(600, 300))
			return float(w.stats.get("item_bolt_hops", 0))
		"thunder_office":
			_foe("zombie", Vector2(600, 300), 500.0)
			_foe("zombie", Vector2(650, 300), 500.0)
			h.cast(LegionHero.SLOT_Q, Vector2(600, 300))
			return float(w.items.hazards.filter(func(x: Dictionary) -> bool:
				return x["kind"] == &"stun").size())
		"exploding_stamp":
			# павший боец постройки взрывается печатью
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(600, 300), w.buildings[0])
			var nb := _foe("zombie", Vector2(630, 300), 500.0)
			u.take_damage(9999.0, u.position)
			_tick_items(0.3)
			return 500.0 - nb.hp
		"kamikaze_brigade":
			# синергия: взрыв павшего бойца ×1,5 (с одной «Взрывной печатью» — ×1)
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(600, 300), w.buildings[0])
			var nb := _foe("zombie", Vector2(630, 300), 500.0)
			u.take_damage(9999.0, u.position)
			_tick_items(0.3)
			return 500.0 - nb.hp
		"temp_contract":
			var p := Vector2(600, 300)
			_kill(_foe("zombie", p))
			var nb := _foe("zombie", p + Vector2(40, 0), 500.0)
			h.cast(LegionHero.SLOT_W, p)
			for v in h._vassals:
				v.life = 0.001
			h.tick(0.02)
			return 500.0 - nb.hp
		"burning_seal":
			# бегущий натиском боец роняет горящие пятна, враг на следе горит
			var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(560, 300))
			var f := _foe("zombie", Vector2(620, 300), 500.0)
			u.start_charge(Vector2.RIGHT)
			for i in 10:
				u.position += Vector2(12, 0)
				w.items.tick(DT)
			_tick_items(1.0)
			return 500.0 - f.hp
		"prolongation", "hot_line":
			var c := _line(Vector2(600, 300))
			var f := _foe("zombie", c.seg_center(0), 500.0)
			w.release_segment(c, 0, &"melt")
			_tick_items(1.0)
			return 500.0 - f.hp
		"megaphone":
			var f := _foe("zombie", Vector2(660, 300), 500.0)
			# E-1005: «Рупор» глушит только за НАСТОЯЩИЙ «Сбор» (n > 0) — нужен свободный боец в
			# круге. Раньше замер проходил и на пустом сборе: это и был баг (ошибка 2 разбора).
			w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(600, 300))
			w.rally_cd = 0.0
			w.rally(Vector2(630, 300))
			return f.stun_t
		"soul_magnet":
			w.cauldron_hp = 50.0
			_kill(_foe("zombie", Vector2(600, 300)))
			return w.cauldron_hp - 50.0
		"cauldron_ward":
			var f := _foe("zombie", w.cauldron_pos + Vector2(50, 0), 500.0)
			w.damage_cauldron(1.0)
			return f.stun_t + (500.0 - f.hp)
	return NAN


func _test_behavior_items() -> void:
	print("— реестр: каждый особый предмет срабатывает на своё событие")
	var n := 0
	for id in LegionItemDb.ids():
		var e := LegionItemDb.item(id)
		if not e.has("on"):
			continue
		n += 1
		_check(LegionItems.EVENTS.has(StringName(e["on"])), "%s: событие %s известно" % [id, e["on"]])
		_check(w.items.effects.has_method("fx_" + String(e["fx"])), "%s: обработчик fx_%s есть" % [id, e["fx"]])
		var without := _measure(String(id), [])
		var with := _measure(String(id), [id])
		if is_nan(with):
			_check(false, "%s: нет сценария в тесте" % id)
			continue
		_check(with > without, "%s «%s»: без %.2f → с предметом %.2f" % [id, e["title"], without, with])
	var total := LegionItemDb.ids().size()
	_check(total >= 10 and total <= 16, "артефактов в реестре: %d (v2: меньше, но каждый ощутим)"
		% total)
	_check(n * 2 > total, "поведение меняют больше половины: %d из %d" % [n, total])


func _test_synergies() -> void:
	print("— синергии: набор собран — эффект сверх предметов, карточка и значок")
	var sids := LegionItemDb.synergy_ids()
	_check(sids.size() >= 2 and sids.size() <= 4, "синергий: %d (немного)" % sids.size())
	for sid in sids:
		var s := LegionItemDb.synergy(sid)
		var full: Array = s["items"]
		var base: Array = full.slice(1)
		var with := _measure(String(sid), full)
		var without := _measure(String(sid), base)
		if is_nan(with):
			_check(false, "%s: нет сценария в тесте" % sid)
			continue
		_check(with > without, "%s «%s»: без «%s» %.2f → набор %.2f" % [sid, s["title"],
			LegionItemDb.item(StringName(full[0]))["title"], without, with])
	# сбор набора: сигнал, отметка, значок и карточка «Синергия: …»
	_fresh()
	var got: Array = []
	w.items.synergy_gained.connect(func(id: StringName) -> void: got.append(id))
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	w.items.grant(&"clip_of_fate", Vector2(600, 300))
	w.items.grant(&"lightning_rod", Vector2(620, 300))
	_check(got == [&"thunder_office"] and w.items.has_synergy(&"thunder_office"),
		"второй предмет набора собирает синергию")
	for i in 240:
		bar._process(DT)
	_check(bar.shown_synergies.has(&"thunder_office"), "значок-связка в полоске")
	var saw_card := false
	for i in 400:
		if String(bar.current_card().get("title", "")).begins_with("Синергия: "):
			saw_card = true
			break
		bar._process(DT)
	_check(saw_card, "карточка «Синергия: Громовая канцелярия»")


# ── 5. уникальность и сброс ─────────────────────────────────────────────────

func _test_unique() -> void:
	print("— артефакт уникален (v2): второй раз тот же не выдаётся")
	_fresh()
	var base := w.hero.q_chain_len()
	_grant([&"clip_of_fate", &"clip_of_fate"])
	_check(w.items.count(&"clip_of_fate") == 1, "одна копия")
	_check(w.hero.q_chain_len() == base + 2, "цепь Ку %d → %d" % [base, w.hero.q_chain_len()])


func _test_reset() -> void:
	print("— новый одиночный бой сбрасывает артефакты")
	_fresh()
	var base := w.hero.q_chain_len()
	_grant([&"clip_of_fate", &"wholesale_ink", &"megaphone", &"lightning_rod"])
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	_check(bar.shown.size() == 4, "в полоске 4 предмета")
	_fresh()
	_check(w.items.total() == 0 and w.items.synergies.is_empty(), "предметов и синергий нет")
	_check(w.hero.q_chain_len() == base, "цепь Ку снова %d" % base)
	_check(is_equal_approx(w.contracts.mana_regen, LegionCfg.MANA_REGEN), "реген маны снова базовый")
	_check(bar.shown.is_empty() and bar.shown_synergies.is_empty(), "полоска пуста")


# ── 6. полоска ──────────────────────────────────────────────────────────────

func _test_bar() -> void:
	print("— полоска не перехватывает мышь и не заезжает на карточки видов")
	_fresh()
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	_check(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "MOUSE_FILTER_IGNORE")
	var full := CfgItems.BAR_PER_ROW * CfgItems.BAR_MAX_ROWS - 1
	_check(bar.slot_rect(CfgItems.BAR_PER_ROW - 1).end.x < LegionCfg.KIND_BAR_POS.x
		and bar.slot_rect(full).position.y > 300.0, "полоска слева от карточек видов")
	_check(CfgItems.BAR_ORIGIN.x + CfgItems.CARD_SIZE.x < LegionCfg.KIND_BAR_POS.x,
		"карточка «Новый предмет» не заходит на карточки видов")
	_grant([&"golden_pen", &"wholesale_ink"])
	w._mouse_pos = bar.slot_rect(0).get_center()
	w._mouse_seen = true
	_check(bar.hovered_slot() == 0, "курсор над первой иконкой — подсказка")
	_check(String(bar.slot_info(0)["title"]) == "Золотое перо", "подсказка: название предмета")
	w._mouse_pos = Vector2(640, 360)
	_check(bar.hovered_slot() == -1, "курсор над ареной — подсказки нет")
	# ЛКМ по арене доходит до мира: HUD-полоска событие не съедает
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = bar.slot_rect(0).get_center()
	ev.global_position = ev.position
	var handled := false
	bar.gui_input.connect(func(_e: InputEvent) -> void: handled = true)
	root.push_input(ev)
	_check(not handled, "клик по иконке не уходит в полоску")


# ── 7. пул поправок ─────────────────────────────────────────────────────────

func _test_upgrades() -> void:
	print("— поправки к договору: колода рогалика, каждая карточка меняет число игры")
	# Пул постоянных процентов (22 поправки + 35 узлов) заменён колодой AmendmentDb из 12 карточек
	# с крупными правилами (OVERHAUL 05.10). Прежнее «поправок в пуле ≥ старых + 8» потеряло смысл:
	# теперь колода — сам UPGRADE_ORDER, и важно, что каждый старый id из неё переведён миграцией.
	var order := LegionMetaCfg.UPGRADE_ORDER
	var covers := order.size() == AmendmentDb.CARDS.size()
	for card_id: String in AmendmentDb.CARDS:
		covers = covers and order.has(card_id)
	_check(covers and order.size() >= 12, "поправок в колоде: %d" % order.size())
	var all_in := true
	for id: String in order:
		all_in = all_in and LegionMetaCfg.UPGRADE_POOL.has(id)
	_check(all_in and LegionMetaCfg.UPGRADE_POOL.size() == order.size(), "порядок и пул совпадают")
	# У каждой старой поправки определена судьба: перевод в карточку (LEGACY_MAP) либо архив.
	# «Кофемашина» (реген маны) и «Расширенный бюджет» (запас маны) осмысленного аналога в колоде
	# не имеют — новых постоянных процентов не заводим (OVERHAUL 05.10), обе уходят в архив, как
	# и весь остальной пул (сам архив и возврат премии за покупки проверяет progression-тест).
	const RETIRED := ["coffee_machine", "expanded_budget"]
	var legacy_ok := true
	for id: String in OLD_UPGRADES:
		if RETIRED.has(id):
			legacy_ok = legacy_ok and not AmendmentDb.LEGACY_MAP.has(id)
		else:
			legacy_ok = legacy_ok and AmendmentDb.CARDS.has(String(AmendmentDb.LEGACY_MAP.get(id, "")))
	_check(legacy_ok, "у каждой старой поправки определена судьба: карточка или архив (%d id)"
		% OLD_UPGRADES.size())
	# Выбор 3 из колоды случайный. RunProgression кэширует чертёж в сохранении (переоткрытие
	# экрана не подкручивает выбор), поэтому между пробами сбрасываем прогресс — иначе все 20
	# проб вернули бы один и тот же чертёж (прежняя проверка «новых поправок ≥ 5» так и ломалась).
	var seen := {}
	for s in 20:
		Campaign.reset()
		var rng := RandomNumberGenerator.new()
		rng.seed = s + 1
		for id in Campaign.offer_upgrades(rng):
			seen[String(id)] = true
	_check(seen.size() >= 5, "за 20 выборов предложено разных поправок: %d" % seen.size())
	# Каждая карточка обязана менять настоящее число игры: берём её, читаем все её ключи через
	# мир (_probe) до и после и требуем, чтобы каждый сдвинулся в сторону, названную в mods.
	for id: String in order:
		var card := AmendmentDb.card(StringName(id))
		var card_mods: Dictionary = card.get("mods", {})
		_check(not card_mods.is_empty(), "карточка «%s» меняет числа" % String(card["title"]))
		Campaign.reset()
		Campaign.unlock_all()   # v20: элитные и предметы открывает «Архив» — здесь всё открыто
		w.in_campaign = true
		w.mods = Campaign.active_mods()
		_fresh()
		var before := {}
		for key: String in card_mods:
			before[key] = _probe(key)
		Campaign.add_upgrade(StringName(id))
		w.mods = Campaign.active_mods()
		_fresh()
		var moved := true
		var report := ""
		for key: String in card_mods:
			var after := _probe(key)
			var value := float(card_mods[key])
			var ok: bool = not is_nan(before[key]) and (after - before[key]) * signf(value) > 0.0
			moved = moved and ok
			report += "%s%s %.3f→%.3f " % ["!" if not ok else "", key, before[key], after]
		_check(moved, "поправка %s «%s»: %s" % [id, String(card["title"]), report.strip_edges()])
	w.in_campaign = false
	w.mods = {}
	Campaign.reset()


## Правка координатора по verify-items (26.09): «Громоотвод» не прыгает с мёртвых звеньев цепи Ку.
func _test_verify_fixes() -> void:
	print("— правки по verify-items")
	_fresh()
	_grant([&"lightning_rod"])
	# восемь зомби по 1 HP в ряд: цепь Ку убивает первого, «Громоотвод» прыгает дальше — но только
	# с живых звеньев, которые убил сам Ку
	for i in 8:
		_foe("zombie", Vector2(560 + i * 24, 300), 1.0)
	w.grid.rebuild()
	w.hero.cast(LegionHero.SLOT_Q, Vector2(560, 300))
	var hops := int(w.stats.get("item_bolt_hops", 0))
	# цепь [0,1,2,3], v2 — до двух прыжков подряд: Ку убивает 0 — прыжки убивают 1 и 2 (звенья 1 и
	# 2 уже мёртвые — пропуск), Ку убивает 3 — прыжки убивают 4 и 5; итого 4 (с мёртвых звеньев
	# прыгал бы и дальше)
	_check(hops == 4, "«Громоотвод»: прыжков %d (нужно 4 — только с убитых самим Ку)" % hops)
