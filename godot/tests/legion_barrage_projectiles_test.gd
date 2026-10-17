extends SceneTree
## B-494: огневой вал счетоводов стреляет настоящими печатями. Путь «вылетел → долетел → попал»
## через общий шаг мира: до прилёта HP цели прежнее, урон ровно один раз по прилёту, вспышка
## конечна; павшая цель, отменённый приказ и снимок посреди полёта не дают вечных снарядов и
## повторного урона; убийство печатью вала — удар с разбега; обычные печати прежние.
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_barrage_projectiles_test.gd -- --mute

const SAVE := "user://legion_barrage_projectiles_test.cfg"
const DT := 1.0 / 60.0
const ORIGIN := Vector2(350, 240)
## Дальняя полоса вала (глубина 230 при полной рогатке) и дальше досягаемости счетовода
## (150 + тело): свободные после приказа стрелки не добивают цель обычной печатью.
const FAR := 200.0
## Словарь обычной печати до B-494 — её снимок и поведение не должны меняться.
const ORDINARY_KEYS := ["color", "dmg", "from", "pos", "sealed", "side", "speed", "target"]
const DEV := {"spawn_units": "0", "no_waves": "1", "pvp_nobot": "1"}

var w: LegionWorld
var _scene: PackedScene
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", what])


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_scene = load("res://scenes/legion_world.tscn") as PackedScene
	w = _scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	_flight_and_single_impact()
	_ghost()
	_target_dies_in_flight()
	await _target_freed_in_flight()
	await _order_interrupted()
	_rally_after_launch()
	_snapshot_mid_flight()
	_snapshot_coverage()
	_charge_kill_on_impact()
	_sealed_barrage()
	_ordinary_seal()
	_pvp_sides()
	_pvp_mirror_side()
	_pvp_enemy_cauldron()
	await _wire_fresh_world()
	Campaign.reset()
	for s in w.sides:
		s.items.effects.items = null   # как в legion_role_repair_test: снять ссылку перед уборкой
	w.queue_free()
	await process_frame
	print("LEGION BARRAGE PROJECTILES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Подготовка ──────────────────────────────────────────────────────────────

## keep_terrain — рельеф карты как есть: свежий мир снимка строит его тем же start_map.
func _fresh(map_id := "_gray", keep_terrain := false) -> void:
	w.dev = DEV.duplicate()
	w.args.erase("bot")
	w.start_map(map_id)
	if not keep_terrain:
		w.terrain.setup({"size": [1280, 720] if map_id == "_gray" else [1600, 900]})
	w.dev_invuln = false
	for s in w.sides:
		s.contracts.mana = s.contracts.mana_max


## Строй счетоводов стороны side: вертикальная линия 64 px от at, все на местах.
func _squad(at := ORIGIN, side := 0) -> Array[Legionnaire]:
	var points := PackedVector2Array()
	for i in 9:
		points.append(at + Vector2(0, i * 8.0))
	var field := w.sides[side].contracts if side < w.sides.size() else w.contracts
	var c := field.add_contract(points, 1, false, LegionCfg.KIND_CLERK)
	var out: Array[Legionnaire] = []
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"], null, side)
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


## Неподвижная безвредная цель: бой меряет только огонь вала.
func _foe(at: Vector2, kind := "zombie", hp := 1000.0) -> Foe:
	var f := w.spawn_foe_on_path(kind, PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = hp
	f.max_hp = hp
	f.def = f.def.duplicate()
	f.def["dmg"] = 0.0
	return f


## Рогатка на полную глубину (по умолчанию вправо): ручной выпуск (растит комбо), без точного
## срыва.
func _release(squad: Array[Legionnaire], dir := Vector2.RIGHT) -> void:
	w.release_segment_aimed(squad[0].contract, 0, dir, 1.0, false)


## Шаги мира до первой печати вала (не больше n); возвращает её словарь или {}.
func _until_barrage_shot(n := 150) -> Dictionary:
	for i in n:
		w._step(DT)
		for sh: Dictionary in w.projectiles.shots:
			if bool(sh.get("barrage", false)):
				return sh
	return {}


## Шаги до опустевшего списка снарядов (не больше n); возвращает число шагов.
func _until_no_shots(n := 150) -> int:
	for i in n:
		if w.projectiles.shots.is_empty():
			return i
		w._step(DT)
	return n


func _barrage_count() -> int:
	var n := 0
	for sh: Dictionary in w.projectiles.shots:
		n += int(bool(sh.get("barrage", false)))
	return n


func _all_free(squad: Array[Legionnaire]) -> bool:
	for u in squad:
		if is_instance_valid(u) and u.alive and u.state != Legionnaire.State.FREE:
			return false
	return true


func _combo_souls() -> float:
	return float(w.stats.get("combo_souls", 0)) + w._combo_soul_frac


# ── Сценарии ────────────────────────────────────────────────────────────────

func _flight_and_single_impact() -> void:
	print("— полёт и одно попадание")
	_fresh()
	var squad := _squad()
	var f := _foe(squad[0].position + Vector2(FAR, 0))
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty(), "дальняя полоса вала выпускает настоящую печать")
	if shot.is_empty():
		return
	_check(f.hp == f.max_hp, "в момент выпуска урона ещё нет (прежний вал бил мгновенно)")
	_check(shot["target"] == f and bool(shot.get("charged", false)),
		"печать летит в выбранную полосой цель и несёт признак удара с разбега")
	_check(shot["color"] != squad[0].spec["color"], "печать вала отличается от обычной мятной")
	var dmg := float(shot["dmg"])
	var at: Vector2 = shot["pos"]
	var gap := at.distance_to(f.position)
	w._step(DT)
	var now_at: Vector2 = shot["pos"]
	_check(f.hp == f.max_hp and now_at.distance_to(f.position) < gap - 1.0,
		"печать приближается к цели, HP прежнее")
	var flown := 1
	var peak := _barrage_count()
	while not w.projectiles.shots.is_empty() and flown < 150:
		w._step(DT)
		flown += 1
		peak = maxi(peak, _barrage_count())
	print("  BARRAGE flight %d кадров, урон %.3f, HP %.3f → %.3f" % [flown, dmg, f.max_hp, f.hp])
	# 200 px при скорости печати 420 px/с — около 28 кадров; мгновенный удар дал бы 0
	_check(flown >= 10, "полёт виден: печать летит не меньше 10 кадров (%d)" % flown)
	_check(dmg > 0.0 and is_equal_approx(f.max_hp - f.hp, dmg),
		"по прилёту — ровно рассчитанный при выпуске урон")
	_check(peak == 1, "одна цель — одна печать за весь вал (было %d)" % peak)
	_check(w.projectiles.impacts.size() == 1, "попадание отмечено вспышкой")
	var hp := f.hp
	for i in 20:
		w._step(DT)
	_check(w.projectiles.impacts.is_empty(), "вспышка гаснет сама (≈0,18 с)")
	for i in 120:
		w._step(DT)
	_check(_all_free(squad), "вал конечен: стрелки свободны")
	_check(f.hp == hp and w.projectiles.shots.is_empty(),
		"после попадания и конца приказа повторного урона и снарядов нет")


func _ghost() -> void:
	print("— призрак")
	_fresh()
	var squad := _squad()
	var g := _foe(squad[0].position + Vector2(FAR, 0), "ghost")
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and shot["target"] == g and g.hp == g.max_hp,
		"вал по-прежнему стреляет в призрака, урон ещё не нанесён")
	var dmg := float(shot.get("dmg", 0.0))
	_until_no_shots()
	_check(dmg > 0.0 and is_equal_approx(g.max_hp - g.hp, dmg),
		"призрак получает урон по прилёту")


func _target_dies_in_flight() -> void:
	print("— цель пала до прилёта")
	_fresh()
	var squad := _squad()
	var f := _foe(squad[0].position + Vector2(FAR, 0))
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty(), "печать выпущена")
	f.take_damage(f.hp + 1.0, f.position)   # добил кто-то другой
	w._step(DT)
	_check(w.projectiles.shots.is_empty() and w.projectiles.impacts.is_empty(),
		"печать к павшей цели исчезает сразу, без вспышки (не летит вечно к трупу)")
	for i in 120:
		w._step(DT)
	_check(_barrage_count() == 0 and _all_free(squad),
		"новых печатей в труп нет, вал завершён")


## Отменённый приказ: печать, уже выпущенная, долетает один раз; поздние полосы не стреляют.
## Тела павших стрелков действительно освобождаются (кадр дерева между шагами).
func _order_interrupted() -> void:
	print("— приказ прерван гибелью стрелков")
	_fresh()
	var squad := _squad()
	var near := _foe(squad[0].position + Vector2(60, 0))
	var far := _foe(squad[0].position + Vector2(FAR, 0))
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and shot["target"] == near, "ближняя полоса выпустила печать")
	var dmg := float(shot.get("dmg", 0.0))
	# номер, а не ссылка: читать освобождённый узел из типизированного массива — ошибка Godot
	var first_id := squad[0].get_instance_id()
	for u in squad:
		u.take_damage(1000000.0, u.position)
	var far_shots := 0
	var peak := 0
	for i in 150:
		w._step(DT)
		await process_frame
		peak = maxi(peak, _barrage_count())
		for sh: Dictionary in w.projectiles.shots:
			far_shots += int(sh["target"] == far)
	_check(not is_instance_id_valid(first_id),
		"тела павших стрелков удалены из дерева (печать не держит ссылку на стрелка)")
	_check(dmg > 0.0 and is_equal_approx(near.max_hp - near.hp, dmg),
		"уже выпущенная печать долетает и бьёт ровно один раз")
	_check(far_shots == 0 and far.hp == far.max_hp and peak <= 1,
		"после гибели стрелков поздние полосы не стреляют")
	_check(w.projectiles.shots.is_empty() and w.projectiles.impacts.is_empty(),
		"после отмены не остаётся снарядов и вспышек")


func _snapshot_mid_flight() -> void:
	print("— снимок посреди полёта")
	_fresh()
	var squad := _squad()
	var f := _foe(squad[0].position + Vector2(FAR, 0))
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty(), "печать выпущена")
	for i in 3:
		w._step(DT)
	_check(_barrage_count() == 1, "снимок застаёт печать вала в полёте")
	var dmg := float(shot.get("dmg", 0.0))
	var saved := NetSnap.save(w)
	for i in 90:
		w._step(DT)
	var want := NetSnap.save(w)
	var want_hp := f.hp
	var result := NetSnap.load(w, saved)
	# загрузка на месте переиспользует тот же узел врага (тот же номер и вид)
	_check(result.misses.is_empty() and result.errors.is_empty() and _barrage_count() == 1
		and is_instance_valid(f) and f.hp == f.max_hp,
		"снимок восстанавливает летящую печать вала и цель до попадания")
	for i in 90:
		w._step(DT)
	_check(var_to_bytes(NetSnap.save(w)) == var_to_bytes(want),
		"продолжение после снимка побайтно совпадает")
	_check(f.hp == want_hp and is_equal_approx(f.max_hp - f.hp, dmg),
		"после загрузки печать бьёт ровно один раз — ни потери, ни повтора")


## Прежний вал засчитывал убийство ударом с разбега сразу; теперь — когда печать долетела.
func _charge_kill_on_impact() -> void:
	print("— убийство печатью вала — удар с разбега")
	_fresh()
	var squad := _squad()
	var f := _foe(squad[0].position + Vector2(FAR, 0), "zombie", 1.0)
	w.combo = 9
	w._combo_hit_t = w.now
	var souls := _combo_souls()
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and f.alive and is_equal_approx(_combo_souls(), souls),
		"до прилёта цель жива и души комбо не начислены")
	_until_no_shots()
	print("  BARRAGE combo %d, души комбо %.2f → %.2f" % [w.combo, souls, _combo_souls()])
	_check(not f.alive and _combo_souls() > souls,
		"убийство по прилёту даёт души комбо, как прежний удар вала")


## Обычная печать (и в окне после натиска) остаётся прежней: тот же словарь, цвет, без вспышки
## и без награды удара с разбега — частная проба давала её всем дальним выстрелам.
func _ordinary_seal() -> void:
	print("— обычная печать прежняя")
	_fresh()
	var clerk := w.spawn_unit(LegionCfg.KIND_CLERK, Vector2(500, 400))
	var f := _foe(clerk.position + Vector2(60, 0), "zombie", 1.0)
	w.combo = 9
	w._combo_hit_t = w.now
	var souls := _combo_souls()
	clerk._bonus_t = 1.0   # окно после натиска: _strike(..., charged = true)
	clerk._atk_cd = 0.0
	clerk._free_strike(f)
	_check(w.projectiles.shots.size() == 1, "свободный счетовод мечет обычную печать")
	if w.projectiles.shots.is_empty():
		return
	var shot: Dictionary = w.projectiles.shots[0]
	var keys := shot.keys()
	keys.sort()
	_check(keys == ORDINARY_KEYS, "словарь обычной печати прежний: %s" % str(keys))
	_check(shot["color"] == clerk.spec["color"], "обычная печать прежнего цвета")
	var hp := f.hp
	_check(hp == f.max_hp, "обычная печать тоже бьёт по прилёту")
	for i in 60:
		w.projectiles.tick(DT)
	_check(not f.alive and w.projectiles.impacts.is_empty(),
		"обычное попадание без вспышки вала")
	_check(is_equal_approx(_combo_souls(), souls),
		"убийство обычной печатью в окне после натиска душ комбо не даёт (как до B-494)")


## PvP: печать вала бьёт только армию соперника, попадание записано стороне стрелка.
func _pvp_sides() -> void:
	_pvp_side_case(0, Vector2(650, 350), Vector2.RIGHT)


## Зеркально: сторона 1 стреляет влево по бойцу стороны 0.
func _pvp_mirror_side() -> void:
	_pvp_side_case(1, Vector2(950, 350), Vector2.LEFT)


func _pvp_side_case(side: int, origin: Vector2, dir: Vector2) -> void:
	print("— PvP: огонь стороны %d" % side)
	_fresh("pvp:duel")
	var squad := _squad(origin, side)
	var at := squad[0].position
	var enemy := w.spawn_unit(LegionCfg.KIND_LABORER, at + dir * FAR, null, 1 - side)
	var ally := w.spawn_unit(LegionCfg.KIND_LABORER, at + dir * 120.0, null, side)
	for u in [enemy, ally]:
		u.hp = 10000.0
		u.max_hp = u.hp
	_release(squad, dir)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and shot["target"] == enemy and int(shot["side"]) == side
		and enemy.hp == enemy.max_hp,
		"сторона %d: печать вала летит в бойца соперника, урона ещё нет" % side)
	var dmg := float(shot.get("dmg", 0.0))
	_until_no_shots()
	_check(dmg > 0.0 and is_equal_approx(enemy.max_hp - enemy.hp, dmg)
		and enemy.last_hit_side == side,
		"сторона %d: по прилёту боец соперника получает урон стороны стрелка" % side)
	_check(ally.hp == ally.max_hp, "сторона %d: свой боец в полосе огня не задет" % side)


## Чужой Котёл — штатная цель полосы (LegionRoleRelease._targets); рисовать линию у чужого
## Котла поле не запрещает. Урон Котлу — по прилёту, с множителем «Печатей Котла» момента
## попадания (PvpRules.cauldron_mult), ровно один раз за вал.
func _pvp_enemy_cauldron() -> void:
	print("— PvP: чужой Котёл")
	_fresh("pvp:duel")
	var home := w.cauldron_of(1)
	var squad := _squad(home + Vector2(-150, -32))
	var cauldron: Node2D = w.sides[1].staff.cauldron
	var hp0: float = w.sides[1].cauldron_hp
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and shot["target"] == cauldron and w.sides[1].cauldron_hp == hp0,
		"печать вала летит в чужой Котёл, урона ещё нет")
	var dmg := float(shot.get("dmg", 0.0))
	_until_no_shots()
	var drop := hp0 - w.sides[1].cauldron_hp
	print("  BARRAGE Котёл: урон печати %.3f × %.3f = %.3f" % [dmg, PvpRules.cauldron_mult(w.now),
		drop])
	_check(dmg > 0.0 and is_equal_approx(drop, dmg * PvpRules.cauldron_mult(w.now)),
		"по прилёту Котёл теряет урон печати с множителем момента попадания")
	var extra := 0
	for i in 120:
		if _all_free(squad):
			break
		w._step(DT)
		extra += _barrage_count()
	_check(extra == 0 and is_equal_approx(hp0 - w.sides[1].cauldron_hp, drop),
		"до конца приказа второй печати вала в Котёл нет")


## Цель освобождена (queue_free + кадр дерева), пока печать летит: ни ошибки скрипта при
## чтении ссылки, ни урона, ни вспышки; печать снимается. Хвост (visible_trail, его зовёт
## draw) тоже читает ссылку на цель.
func _target_freed_in_flight() -> void:
	print("— цель освобождена до прилёта")
	_fresh()
	var squad := _squad()
	var f := _foe(squad[0].position + Vector2(FAR, 0))
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty(), "печать выпущена")
	if shot.is_empty():
		return
	var id := f.get_instance_id()
	w.foes.erase(f)
	w._damage_hp.erase(f)
	f.queue_free()
	await process_frame
	_check(not is_instance_id_valid(id), "узел цели действительно освобождён")
	var trail := w.projectiles.visible_trail(shot)
	_check(trail.size() == 2, "хвост печати строится и без цели (по направлению полёта)")
	w.projectiles.tick(DT)
	_check(w.projectiles.shots.is_empty() and w.projectiles.impacts.is_empty(),
		"печать к освобождённой цели снята без вспышки")
	_fresh()


## «Сбор» (клавиша R, LegionWorld.rally) после первой печати: она долетает один раз, дальние
## полосы уже не стреляют, стрелки бегут к точке Сбора.
func _rally_after_launch() -> void:
	print("— Сбор после выпуска первой печати")
	_fresh()
	var squad := _squad()
	var near := _foe(squad[0].position + Vector2(60, 0))
	var far := _foe(squad[0].position + Vector2(FAR, 0))
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and shot["target"] == near, "ближняя полоса выпустила печать")
	var dmg := float(shot.get("dmg", 0.0))
	var called := w.rally(ORIGIN + Vector2(-45, 0))
	var rallied := true
	for u in squad:
		rallied = rallied and u.state == Legionnaire.State.RALLY and not u.role_command_active()
	_check(called == squad.size() and rallied, "Сбор снимает приказ вала со всех стрелков")
	_until_no_shots(30)
	_check(dmg > 0.0 and is_equal_approx(near.max_hp - near.hp, dmg),
		"уже выпущенная печать долетает и бьёт ровно один раз")
	var far_shots := 0
	var barrage := 0
	for i in 150:
		w._step(DT)
		barrage += _barrage_count()
		for sh: Dictionary in w.projectiles.shots:
			far_shots += int(sh["target"] == far)
	_check(barrage == 0 and far_shots == 0 and far.hp == far.max_hp,
		"после Сбора поздние полосы вала не стреляют")


## «Сургуч» стрелка у печати вала: та же печать (замедление ×SEAL), но по прилёту.
func _sealed_barrage() -> void:
	print("— печать вала с печатью (Сургуч)")
	_fresh()
	var squad := _squad()
	var f := _foe(squad[0].position + Vector2(FAR, 0))
	_release(squad)
	for u in squad:
		u._seal_t = LegionCfg.SEAL_TIME
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and bool(shot.get("sealed", false)) and f.seal_slow_t == 0.0,
		"печать вала несёт Сургуч, замедления до прилёта нет")
	_until_no_shots()
	_check(f.seal_slow_t > 0.0 and f.hp < f.max_hp, "по прилёту — урон и замедление Сургуча")


## Полнота снимка: каждое поле LegionProjectiles учтено (тот же разбор, что в
## legion_snapshot_test): shots — в снимке, impacts — пропуск с причиной.
func _snapshot_coverage() -> void:
	for cov: Array in SnapUnits.coverage():
		var script: Script = cov[0]
		if script != LegionProjectiles:
			continue
		var vars := NetSnap.script_vars(script)
		var known: Array = cov[1]
		var all_known := vars.size() == known.size()
		for v in vars:
			all_known = all_known and known.has(v)
		_check(all_known and vars.has("impacts"),
			"полнота снимка снарядов: %s учтены %s" % [str(vars), str(known)])


## Снимок «как по сети» (bytes_to_var(var_to_bytes(...))) посреди полёта — в свежий мир; оба мира
## дальше одинаковы побайтно, печать бьёт один раз, души за убийство — один раз.
func _wire_fresh_world() -> void:
	print("— снимок в полёте по сети в свежий мир")
	_fresh("pvp:duel", true)
	var squad := _squad(Vector2(250, 400))
	var at := squad[0].position
	var zombie := _foe(at + Vector2(120, 0), "zombie", 1.0)
	var enemy := w.spawn_unit(LegionCfg.KIND_LABORER, at + Vector2(FAR, 0), null, 1)
	enemy.hp = 10000.0
	enemy.max_hp = enemy.hp
	_release(squad)
	var shot := _until_barrage_shot()
	_check(not shot.is_empty() and shot["target"] == zombie, "печать в зомби выпущена")
	w._step(DT)
	w._step(DT)
	_check(_barrage_count() == 1 and zombie.alive, "снимок застаёт печать в полёте")
	var souls: int = w.sides[0].souls
	var wire: Dictionary = bytes_to_var(var_to_bytes(NetSnap.save(w)))
	var b := _scene.instantiate() as LegionWorld
	b.embedded = true
	root.add_child(b)
	await process_frame
	b.set_process(false)
	b.dev = DEV.duplicate()
	var reg := b.load_snapshot(wire)
	_check(reg.errors.is_empty() and reg.misses.is_empty(),
		"свежий мир принял снимок: ошибки %s, потери %s" % [str(reg.errors), str(reg.misses)])
	var b_shots := 0
	for sh: Dictionary in b.projectiles.shots:
		b_shots += int(bool(sh.get("barrage", false)) and is_instance_valid(sh["target"])
			and (sh["target"] as Node).get_parent() != null and sh["target"] in b.foes)
	_check(b_shots == 1, "в свежем мире летящая печать указывает на его собственного врага")
	_check(var_to_bytes(b.snapshot()) == var_to_bytes(NetSnap.save(w)),
		"снимок свежего мира совпадает с исходным")
	var enemy_dmg := 0.0
	for i in 90:
		w._step(DT)
		b._step(DT)
		for sh: Dictionary in w.projectiles.shots:
			if bool(sh.get("barrage", false)) and sh["target"] == enemy:
				enemy_dmg = float(sh["dmg"])
	_check(var_to_bytes(b.snapshot()) == var_to_bytes(w.snapshot()),
		"через 90 шагов оба мира побайтно одинаковы")
	var b_enemy: Legionnaire = null
	for u in b.units:
		if u.side == 1:
			b_enemy = u
	var b_zombie_dead := true
	for f in b.foes:
		b_zombie_dead = b_zombie_dead and f.type_id != "zombie"
	_check(not zombie.alive and b_zombie_dead, "зомби убит печатью в обоих мирах")
	_check(enemy_dmg > 0.0 and is_equal_approx(enemy.max_hp - enemy.hp, enemy_dmg)
		and b_enemy != null and is_equal_approx(b_enemy.hp, enemy.hp),
		"поздняя полоса после загрузки бьёт соперника один раз в обоих мирах")
	var gained: int = w.sides[0].souls - souls
	print("  BARRAGE wire: души стороны 0 +%d (A) / %d → %d (B)" % [gained, souls,
		b.sides[0].souls])
	_check(gained > 0 and b.sides[0].souls == w.sides[0].souls,
		"души за убийство печатью начислены один раз и одинаково")
	for s in b.sides:
		s.items.effects.items = null
	b.queue_free()
	await process_frame
