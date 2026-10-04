extends SceneTree
##
## Регресс прицела способностей (медленная сессия clarity, 26.09.2026). Игорь: «надо ещё сделать,
## чтобы понятнее было, что обилки делают в целом».
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_ability_aim_test.gd -- --mute
##
## Ввод — НАСТОЯЩИЙ: Input.parse_input_event (тот же путь, что у ОС), окно 1280×720.
## Проверки:
##  1) зажатая Q не кастует, пока держишь; отпускание кастует в точку ОТПУСКАНИЯ;
##  2) цели прицела Ку — ровно цепь удара, в том же порядке и с тем же уроном;
##  3) быстрое нажатие-отпускание кастует, как раньше;
##  4) пауза, потеря фокуса, Esc и другая клавиша способности гасят прицел без каста;
##  5) Дубль-вэ и Е: прицел показывает тот же труп и тех же бойцов, что возьмёт каст;
##  6) подписи: превью с числами из LegionCfg, «что сделал» у целей, отказ у курсора;
##  7) HUD способностей мышь не ловит; прямой hero.cast() (бот, обучение) работает без прицела.
## На старом коде (каст по нажатию) проверки 1, 4, 5 и 6 падают.
## Итог «LEGION ABILITY AIM: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_ability_aim_test.cfg"
const WORLD := Vector2(1280.0, 720.0)
## Две кучки врагов в тихой части серой карты (как LAB в legion_hero_test).
const A := Vector2(760, 140)
const B := Vector2(420, 460)

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


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Input.use_accumulated_input = false
	root.size = Vector2i(WORLD)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.in_campaign = true
	root.add_child(w)
	await process_frame
	await process_frame
	Campaign.unlock_all()
	await _test_hold_and_release()
	await _test_quick_tap()
	await _test_cancels()
	await _test_switch()
	await _test_w_and_e()
	await _test_texts()
	await _test_api_and_hud()
	Campaign.reset()
	print("LEGION ABILITY AIM: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Настоящий ввод ──────────────────────────────────────────────────────────

func _win(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = _win(p)
	m.global_position = m.position
	Input.parse_input_event(m)
	await process_frame


func _key(code: Key, pressed: bool) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.keycode = code
	k.pressed = pressed
	Input.parse_input_event(k)
	await process_frame


# ── Мир ─────────────────────────────────────────────────────────────────────

func _fresh() -> void:
	if w.paused:
		w.set_paused(false)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.set_process(false)   # мир стоит: враги не ходят, откаты не тикают — проверяем только ввод
	w.dev_invuln = false
	hero = w.hero
	hero.reset()


func _still_foe(type: String, at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at]), at)
	f.speed = 0.0
	return f


## Кучка из n зомби вокруг точки (первый — ровно в ней).
func _pack(at: Vector2, n: int) -> Array[Foe]:
	var out: Array[Foe] = []
	for i in n:
		out.append(_still_foe("zombie", at + Vector2(18.0 * i, 9.0 * (i % 2))))
	return out


func _hurt(f: Foe) -> bool:
	return f.hp < float(f.def["hp"])


## Новое API героя — через call/get: на старом коде тест должен ПАДАТЬ проверками, а не разбором.
func _chain_len() -> int:
	return int(hero.call("q_chain_len")) if hero.has_method("q_chain_len") else -1


func _q_dmg(i: int) -> float:
	return float(hero.call("q_damage", i)) if hero.has_method("q_damage") else -1.0


func _last_cast() -> Dictionary:
	var v: Variant = hero.get("last_cast")
	return v if v is Dictionary else {}


func _aim_slot() -> int:
	var aim: Object = w.get("ability_aim")
	return int(aim.get("slot")) if aim != null else -1


# ── 1–2. Зажал — прицел, отпустил — каст; превью = цепь ────────────────────────

func _test_hold_and_release() -> void:
	print("— Q: зажал — прицел, отпустил — каст в точку отпускания")
	_fresh()
	var pa := _pack(A, 3)
	var pb := _pack(B, 5)
	await _move(A)
	await _key(KEY_Q, true)
	var any_hurt := false
	for f in pa + pb:
		any_hurt = any_hurt or _hurt(f)
	_check(not any_hurt and hero.cd_left(LegionHero.SLOT_Q) == 0.0, "Q зажата — молния ещё не ударила")
	_check(_aim_slot() == LegionHero.SLOT_Q, "Q зажата — прицел Ку включён")
	await _move(B)
	var preview: Array = hero.call("q_targets", B) if hero.has_method("q_targets") else []
	await _key(KEY_Q, false)
	_check(hero.cd_left(LegionHero.SLOT_Q) > 0.0, "Q отпущена — каст состоялся")
	var a_hurt := 0
	for f in pa:
		a_hurt += int(_hurt(f))
	_check(a_hurt == 0 and _hurt(pb[0]), "удар — у точки отпускания (кучка Б), а не нажатия (задето у А: %d)" % a_hurt)
	var hurt_b: Array[Foe] = []
	for f in pb:
		if _hurt(f):
			hurt_b.append(f)
	_check(preview.size() == _chain_len() and preview.size() == hurt_b.size(),
		"превью Ку: столько же целей, сколько ударило (%d и %d)" % [preview.size(), hurt_b.size()])
	var same := preview.size() > 0
	for i in preview.size():
		var f: Foe = preview[i]
		var lost := float(f.def["hp"]) - f.hp
		same = same and hurt_b.has(f) and is_equal_approx(lost, _q_dmg(i))
	_check(same, "превью Ку: те же враги в том же порядке — урон по номеру цепи совпал")
	var hits: Array = _last_cast().get("hits", [])
	var order_ok := hits.size() == preview.size()
	for i in mini(hits.size(), preview.size()):
		order_ok = order_ok and (hits[i]["pos"] as Vector2).is_equal_approx((preview[i] as Foe).position)
	_check(order_ok, "порядок колец-номеров = порядок молнии (last_cast.hits)")
	_check(_aim_slot() == -1, "после каста прицел погас")


# ── 3. Быстрое нажатие ────────────────────────────────────────────────────────

func _test_quick_tap() -> void:
	print("— быстрое нажатие-отпускание кастует, как раньше")
	_fresh()
	var pa := _pack(A, 2)
	await _move(A)
	await _key(KEY_Q, true)
	await _key(KEY_Q, false)
	_check(_hurt(pa[0]) and hero.cd_left(LegionHero.SLOT_Q) > 0.0, "нажал-отпустил Q — молния по курсору")


# ── 4. Отмена прицела ─────────────────────────────────────────────────────────

func _test_cancels() -> void:
	print("— пауза, потеря фокуса и Esc гасят прицел без каста")
	for how: String in ["пауза", "фокус", "Esc"]:
		_fresh()
		var pa := _pack(A, 2)
		await _move(A)
		await _key(KEY_Q, true)
		if how == "пауза":
			w.set_paused(true)
			await _key(KEY_Q, false)       # отпускание на паузе игра не видит
			w.set_paused(false)
		elif how == "фокус":
			root.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
			await process_frame
			await _key(KEY_Q, false)       # и даже если отпускание всё же придёт — не каст
		else:
			await _key(KEY_ESCAPE, true)
			await _key(KEY_ESCAPE, false)
			_check(not w.paused, "Esc посреди прицела — отмена прицела, а не пауза")
			await _key(KEY_Q, false)
		_check(not _hurt(pa[0]) and hero.cd_left(LegionHero.SLOT_Q) == 0.0,
			"%s: Ку не ударила, откат цел" % how)
		_check(_aim_slot() == -1, "%s: прицел не залип" % how)
		await _key(KEY_Q, true)
		await _key(KEY_Q, false)
		_check(_hurt(pa[0]), "%s: следующее нажатие Q работает" % how)


func _test_switch() -> void:
	print("— другая клавиша способности переключает прицел без каста")
	_fresh()
	var pa := _pack(A, 2)
	await _move(A)
	await _key(KEY_Q, true)
	await _key(KEY_E, true)
	_check(_aim_slot() == LegionHero.SLOT_E, "Q зажата, нажата E — в прицеле Е")
	await _key(KEY_Q, false)
	_check(not _hurt(pa[0]) and hero.cd_left(LegionHero.SLOT_Q) == 0.0, "отпустил Q после переключения — Ку не ударила")
	_check(_aim_slot() == LegionHero.SLOT_E, "прицел Е жив, пока E зажата")
	await _key(KEY_E, false)
	_check(_aim_slot() == -1 and hero.cd_left(LegionHero.SLOT_Q) == 0.0,
		"отпустил E — прицел погас, Ку так и не кастовалась")
	await _key(KEY_Q, true)
	await _key(KEY_R, true)
	_check(_aim_slot() == -1, "R посреди прицела Ку — прицел один, Ку снят")
	await _key(KEY_Q, false)
	await _key(KEY_R, false)
	_check(not _hurt(pa[0]), "…и отпускание Q после R не кастует")


# ── 5. Дубль-вэ и Е ───────────────────────────────────────────────────────────

func _test_w_and_e() -> void:
	print("— Дубль-вэ и Е: прицел берёт то же, что каст")
	_fresh()
	var dead := _still_foe("zombie", A)
	var far_dead := _still_foe("zombie", A + Vector2(55, 0))
	dead.take_damage(100000.0, dead.position + Vector2.RIGHT)
	far_dead.take_damage(100000.0, far_dead.position + Vector2.RIGHT)
	var out_dead := _still_foe("zombie", A + Vector2(LegionCfg.W_RAISE_RADIUS + 40.0, 0))
	out_dead.take_damage(100000.0, out_dead.position + Vector2.RIGHT)
	var at := A + Vector2(10, 0)
	await _move(at)
	await _key(KEY_W, true)
	# сколько трупов за каст — W_RAISE_MAX (ветка slow/action), без неё 1: тест верен при любом
	var cap := int(hero.call("w_raise_max")) if hero.has_method("w_raise_max") else -1
	var shown: Array = hero.call("w_corpses", at) if hero.has_method("w_corpses") else []
	_check(shown.size() == mini(cap, 2) and shown.size() > 0 and shown[0] == dead
		and hero.vassal_count() == 0,
		"W зажата: выделено %d из %d свежих в круге, ближний первым, никто ещё не встал" % [shown.size(), 2])
	_check(not shown.has(out_dead), "труп за радиусом Дубль-вэ не выделен")
	# до отпускания: поднятые трупы освобождаются, и сравнивать с ними после уже нельзя
	var far_shown := shown.has(far_dead)
	await _key(KEY_W, false)
	var raised_ok := hero.vassal_count() == shown.size()
	for f in shown:   # без типа: поднятый труп уже освобождён, типизированный цикл падает
		raised_ok = raised_ok and (not is_instance_valid(f) or (f as Node).is_queued_for_deletion())
	_check(raised_ok, "W отпущена: подняты ровно выделенные трупы (%d)" % hero.vassal_count())
	var left_ok := is_instance_valid(out_dead) and not out_dead.is_queued_for_deletion()
	if not far_shown:
		left_ok = left_ok and is_instance_valid(far_dead) and not far_dead.is_queued_for_deletion()
	_check(left_ok, "невыделенные трупы остались лежать")
	var has_cfg := hero.has_method("cfg_or")
	_check(has_cfg and hero.call("cfg_or", &"Q_RADIUS", -1.0) == LegionCfg.Q_RADIUS
		and hero.call("cfg_or", &"NO_SUCH_CONST", 7) == 7,
		"cfg_or: есть константа — её значение, нет — запасное")

	_fresh()
	var near: Array[Legionnaire] = []
	for i in 3:
		near.append(w.spawn_unit(LegionCfg.KIND_LABORER, B + Vector2(30.0 * i, 0.0)))
	var out := w.spawn_unit(LegionCfg.KIND_LABORER, B + Vector2(LegionCfg.E_RADIUS + 40.0, 0.0))
	await _move(B)
	await _key(KEY_E, true)
	var boosted: Array = hero.call("e_targets", B) if hero.has_method("e_targets") else []
	_check(boosted.size() == 3 and not boosted.has(out), "E зажата: кольца под тремя бойцами в круге (%d)" % boosted.size())
	_check(near[0].haste_speed_mult == 1.0, "E зажата — Аврал ещё не начался")
	await _key(KEY_E, false)
	var all_on := true
	for u in near:
		all_on = all_on and u.haste_speed_mult == LegionCfg.E_SPEED_MULT
	_check(all_on and out.haste_speed_mult == 1.0, "E отпущена — ускорены ровно те, кого показал прицел")


# ── 6. Подписи ────────────────────────────────────────────────────────────────

func _test_texts() -> void:
	print("— подписи прицела и каста")
	_fresh()
	var aim: Object = w.get("ability_aim")
	_check(aim != null, "у мира есть прицел способностей")
	if aim == null:
		return
	_pack(A, 5)
	var n := _chain_len()
	var q_text := String(aim.call("preview_text", LegionHero.SLOT_Q, A))
	_check(q_text.begins_with("молния: %d" % n), "превью Ку: «%s» (целей по LegionCfg — %d)" % [q_text, n])
	_check(q_text.ends_with("оглушит на %s с" % str(LegionCfg.Q_STUN).replace(".", ",")),
		"превью Ку называет оглушение числом из LegionCfg.Q_STUN")
	_check(String(aim.call("preview_text", LegionHero.SLOT_Q, Vector2(80, 680))) == "нет цели рядом",
		"превью Ку вдали от врагов — «нет цели рядом»")
	var e_text := String(aim.call("preview_text", LegionHero.SLOT_E, Vector2(80, 680)))
	_check(e_text == "некого ускорять", "превью Е без бойцов — «некого ускорять»")
	var w_text := String(aim.call("preview_text", LegionHero.SLOT_W, A))
	_check(w_text == "нет свежего трупа", "превью Дубль-вэ без трупов — «нет свежего трупа»")
	var d_q := String(aim.call("describe", LegionHero.SLOT_Q))
	_check(d_q.contains("Ку") and d_q.contains(str(n)), "строка «что делает» Ку: «%s»" % d_q)
	var d_e := String(aim.call("describe", LegionHero.SLOT_E))
	_check(d_e.contains(str(LegionCfg.E_SPEED_MULT).replace(".", ",")), "строка «что делает» Е берёт множитель из LegionCfg: «%s»" % d_e)
	await _move(A)
	await _key(KEY_Q, true)
	await _key(KEY_Q, false)
	var notes: Array = aim.get("notes")
	var dmg_notes := 0
	for nt: Dictionary in notes:
		if String(nt["text"]).begins_with("−"):
			dmg_notes += 1
	_check(dmg_notes == n, "после Ку — урон у каждой цели цепи (%d подписей)" % dmg_notes)
	await _key(KEY_Q, true)
	await _key(KEY_Q, false)
	var last := String((aim.get("notes") as Array).back()["text"])
	_check(last.begins_with("откат"), "Ку на откате — у курсора «%s»" % last)
	await _move(Vector2(80, 680))
	await _key(KEY_W, true)
	await _key(KEY_W, false)
	last = String((aim.get("notes") as Array).back()["text"])
	_check(last == "нет трупа", "Дубль-вэ без трупа — у курсора «%s»" % last)
	# прицел рисуется без ошибок: кадр с зажатой клавишей (ошибки отрисовки — в лог гейта)
	await _key(KEY_Q, true)
	w._fx.queue_redraw()
	await process_frame
	await _key(KEY_Q, false)


# ── 7. API бота и обучения, HUD ───────────────────────────────────────────────

func _test_api_and_hud() -> void:
	print("— hero.cast() напрямую и HUD без захвата мыши")
	_fresh()
	var pa := _pack(A, 2)
	_check(hero.cast(LegionHero.SLOT_Q, A) and _hurt(pa[0]), "hero.cast(Q, точка) бьёт сразу — бот и обучение не сломаны")
	_check(_aim_slot() == -1, "прямой каст прицела не включает")
	var bars: Array[Node] = []
	for nd in root.find_children("*", "", true, false):
		if nd is AbilityBar:
			bars.append(nd)
	var ok := bars.size() > 0
	for b in bars:
		var r: Control = b.get("_root")
		ok = ok and r != null and r.mouse_filter == Control.MOUSE_FILTER_IGNORE
	_check(ok, "панель способностей не ловит мышь (%d шт.)" % bars.size())
