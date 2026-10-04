extends SceneTree
##
## Таб — стереть кусок линии под курсором (slow/tab-erase, Игорь 29.09.2026: «чтобы линия
## полностью стиралась под мышкой. Но если перед этим линия была разрезана на несколько
## фрагментов, чтобы стирался только этот фрагмент»; «бойцы при таком стирании тоже должны идти
## в натиск»). Всё — НАСТОЯЩИМИ событиями ввода (Input.parse_input_event в координатах окна):
##  1) линия без разрывов — Таб выпускает все живые участки, бойцы в натиске по стрелке договора,
##     мана не выросла;
##  2) линия с мёртвым участком — Таб над левым куском выпускает только его, правый стоит;
##  3) золотой участок в куске — «Точно!» только у него; залпы куска — одна группа (комбо раз);
##  4) кольцо — выпускается целиком, как щелчок ПКМ («Сжать кольцо!»);
##  5) Таб над пустым местом, во время штриха ЛКМ, натяжки рогатки, прицела Пробела — ничего;
##  6) фокус интерфейса: в бою Таб не двигает фокус кнопок, на паузе — двигает, как раньше;
##  7) обучение, шаг «Точно!»: Таб по не золотому участку (золотой сосед) шаг не засчитывает.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_tab_erase_test.gd -- --mute
##
## Новый API не зовётся: на старом коде тест не падает разбором, а честно проваливает проверки.
## Итог «LEGION TAB ERASE: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_tab_erase_test.cfg"
## Полоса карты _gray между рекой (x 620–706) и скалой (x 870+), вдали от Котла.
const LAB := Vector2(760, 120)
const DEVICE := 9

var w: LegionWorld
var f: ContractField
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


func _line(a: Vector2, b: Vector2, step := 8.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in n + 1:
		pts.append(a.lerp(b, float(i) / n))
	return pts


# ── Настоящие события ввода ──────────────────────────────────────────────────

func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2, mask: int = 0) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


## Клавиша — с устройством по умолчанию (клавиатура): действия ui_* в 4.7 привязаны к устройству
## клавиатуры, и с чужим device ui_focus_next не сработал бы и на старом коде (проверено пробой).
func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(1)


## Таб над точкой at: курсор туда, нажатие и отпускание.
func _tab_at(at: Vector2, mask: int = 0) -> void:
	await _move(at, mask)
	await _key(KEY_TAB, true)
	await _key(KEY_TAB, false)


# ── Мир ──────────────────────────────────────────────────────────────────────

func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.start_map("_gray")
	w.dev_invuln = false
	f = w.contracts
	f.mana = f.mana_max


## Договор-столбик в лаборатории: n участков по 64 px, стрелка по умолчанию — от Котла (+x).
func _column(n: int, y0 := 0.0) -> Contract:
	var a := LAB + Vector2(0, y0)
	return f.add_contract(_line(a, a + Vector2(0, 64.0 * n)), 1, false)


func _man(c: Contract) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if p["unit"] != null or p["dead"]:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _seg_units(squad: Array[Legionnaire], seg: int) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in squad:
		if not u.post.is_empty() and int(u.post["seg"]) == seg:
			out.append(u)
	return out


func _still_foe(at: Vector2) -> Foe:
	var foe := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	foe.speed = 0.0
	foe.hp = 100000.0
	foe.max_hp = foe.hp
	return foe


func _alive_segs(c: Contract) -> Array[int]:
	var out: Array[int] = []
	for s in c.seg_count():
		if c.seg_alive(s):
			out.append(s)
	return out


func _all_charge(units: Array[Legionnaire], dir: Vector2) -> bool:
	if units.is_empty():
		return false
	for u in units:
		if u.state != Legionnaire.State.CHARGE or not u._charge_dir.is_equal_approx(dir):
			return false
	return true


func _all_posted(units: Array[Legionnaire]) -> bool:
	if units.is_empty():
		return false
	for u in units:
		if u.state != Legionnaire.State.POSTED:
			return false
	return true


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	await _test_whole_line()
	await _test_split_line()
	await _test_gold()
	await _test_ring()
	await _test_nothing()
	await _test_focus()
	await _test_tutorial_perfect()
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION TAB ERASE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## 1) Линия без разрывов: весь договор в натиск, мана не выросла.
func _test_whole_line() -> void:
	print("— линия без разрывов")
	_fresh()
	var c := _column(4)
	_check(c != null and c.seg_count() == 4, "договор из 4 участков поставлен")
	var squad := _man(c)
	await _frames(1)
	f.mana_regen = 0.0
	f.mana = 40.0
	var releases: int = int(w.stats["releases_manual"])
	# на _gray стоит неподвижный враг (860, 330) — участок рядом с ним золотой: запоминаем,
	# у кого «Точно!» по правилу щелчка, до Таба
	var gold: Array[bool] = []
	var by_seg: Array = []
	for s in 4:
		gold.append(f.seg_gold(c, s))
		by_seg.append(_seg_units(squad, s))
	await _tab_at(c.seg_center(1))
	_check(_alive_segs(c).is_empty(), "Таб над участком 1 — все 4 участка сорваны (живы: %s)"
		% [_alive_segs(c)])
	_check(int(w.stats["releases_manual"]) - releases == 4, "4 ручных выпуска (%d)"
		% (int(w.stats["releases_manual"]) - releases))
	_check(_all_charge(squad, c.dir),
		"все %d бойцов линии в натиске по стрелке договора" % squad.size())
	var ok := true
	var golds := 0
	for s in 4:
		for u: Legionnaire in by_seg[s]:
			if gold[s]:
				ok = ok and bool(u._volley.get("perfect", false))
			else:
				ok = ok and is_equal_approx(float(u._volley.get("dmg", 0.0)), 1.0) \
					and not bool(u._volley.get("perfect", true))
		golds += 1 if gold[s] else 0
	_check(ok, "натиск как от щелчка ПКМ: золотой участок — «Точно!», прочие — множители 1.0 "
		+ "(золотых %d)" % golds)
	_check(int(w.stats.get("perfect_releases", 0)) == golds, "«Точно!» посчитано по золотым")
	_check(f.mana <= 40.0 + 0.001, "мана за стёртое не вернулась (%.2f)" % f.mana)
	f.mana_regen = LegionCfg.MANA_REGEN


## 2) Мёртвый участок посередине: Таб над левым куском — только он.
func _test_split_line() -> void:
	print("— линия с мёртвым участком посередине")
	_fresh()
	var c := _column(4)
	var squad := _man(c)
	w.release_segment(c, 2)
	var right := _seg_units(squad, 3)
	var left := _seg_units(squad, 0) + _seg_units(squad, 1)
	await _frames(1)
	await _tab_at(c.seg_center(0))
	_check(_alive_segs(c) == [3], "Таб над левым куском: сорваны 0 и 1, жив только 3 (живы: %s)"
		% [_alive_segs(c)])
	_check(_all_charge(left, c.dir), "бойцы левого куска в натиске (%d)" % left.size())
	_check(_all_posted(right), "бойцы правого куска стоят (%d)" % right.size())
	# второй Таб над правым куском — стирает и его
	await _tab_at(c.seg_center(3))
	_check(_alive_segs(c).is_empty(), "второй Таб над правым куском — сорван и он")
	_check(_all_charge(right, c.dir), "бойцы правого куска в натиске")


## 3) Золото и комбо: «Точно!» — только у золотого участка, залпы куска — одна группа.
func _test_gold() -> void:
	print("— золотой участок в куске")
	_fresh()
	var c := _column(2)
	var squad := _man(c)
	_still_foe(c.seg_center(1) + c.dir * 40.0)
	await _frames(1)
	var gold0 := f.seg_gold(c, 0)
	var gold1 := f.seg_gold(c, 1)
	_check(gold1 and not gold0, "участок 1 золотой, 0 — нет (%s/%s)" % [gold0, gold1])
	var u0 := _seg_units(squad, 0)
	var u1 := _seg_units(squad, 1)
	await _tab_at(c.seg_center(0))
	_check(_alive_segs(c).is_empty(), "кусок сорван целиком")
	_check(int(w.stats.get("perfect_releases", 0)) == 1, "«Точно!» ровно одно — у золотого (%d)"
		% int(w.stats.get("perfect_releases", 0)))
	var ok := not u0.is_empty() and not u1.is_empty()
	# боец, не успевший встать в строй к срыву, отпускается свободным (общий _release) — не в счёт
	for u in u0:
		if u.state == Legionnaire.State.CHARGE:
			ok = ok and not bool(u._volley.get("perfect", true))
	for u in u1:
		if u.state == Legionnaire.State.CHARGE:
			ok = ok and bool(u._volley.get("perfect", false))
	_check(ok, "залп участка 1 — «Точно!», участка 0 — обычный")
	var g0 := _group_of(u0)
	var g1 := _group_of(u1)
	_check(not g0.is_empty() and is_same(g0, g1),
		"залпы куска связаны одной группой — комбо растёт раз за жест")


func _group_of(units: Array[Legionnaire]) -> Dictionary:
	for u in units:
		if u.state == Legionnaire.State.CHARGE:
			return u._volley.get("group", {})
	return {}


## 7) Обучение «Пустыря», шаг «Точно!»: Таб по НЕ золотому участку куска с золотым соседом —
## «Точно!» в бою есть, но шаг не засчитан: урок учит щелчку по золоту (verifier slow/tab-erase,
## на faac7da шаг сразу уходил дальше). Зачёт щелчком по золоту — в legion_tutorial_test.
func _test_tutorial_perfect() -> void:
	print("— обучение: шаг «Точно!» и Таб")
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {}
	w.args.erase("bot")
	w.start_map("wasteland")
	w.start_tutorial()
	await _frames(2)
	f = w.contracts
	var t := w.tutorial
	var k := -1
	for i in 40:
		t.force_step(i)
		if t.step_kind() == &"perfect":
			k = i
			break
	_check(k >= 0, "в обучении есть шаг «Точно!» (%d)" % k)
	if k < 0:
		return
	await _frames(180)   # урок ставит учебную линию, бойцы встают, зомби подходит
	var c: Contract = null
	var s := -1
	for line in f.contracts:
		for i in line.seg_count():
			if not line.seg_alive(i) or f.click_gold(line, i):
				continue
			for j in ContractErase.run_of(line, i):
				if f.click_gold(line, j):
					c = line
					s = i
		if c != null:
			break
	_check(c != null, "учебная линия: есть не золотой участок с золотым соседом")
	if c == null:
		return
	var step := t.step()
	var perfects := int(w.stats.get("perfect_releases", 0))
	await _tab_at(c.seg_center(s))
	await _frames(10)
	_check(int(w.stats.get("perfect_releases", 0)) > perfects,
		"Таб дал «Точно!» в бою (золотой сосед)")
	_check(t.step() == step and t.step_kind() == &"perfect",
		"Таб по не золотому участку шаг «Точно!» не засчитал (шаг %d → %d)" % [step, t.step()])


## 4) Кольцо — фигура: выпускается целиком, как щелчок ПКМ.
func _test_ring() -> void:
	print("— кольцо")
	_fresh()
	var center := Vector2(1130.0, 200.0)
	var pts := PackedVector2Array()
	for i in 40:
		pts.append(center + Vector2.from_angle(TAU * i / 40.0) * 80.0)
	pts.append(pts[0])
	var ring: Contract = f._create(pts, 1, LegionCfg.KIND_LABORER, true)
	_man(ring)
	var squeezes := int(w.stats.get("ring_squeezes", 0))
	await _frames(1)
	await _tab_at(ring.seg_center(0))
	_check(_alive_segs(ring).is_empty(), "Таб над кольцом — сорвано всё кольцо")
	_check(int(w.stats.get("ring_squeezes", 0)) == squeezes + 1, "это обычное «Сжать кольцо!»")


## 5) Где Таб ничего не делает.
func _test_nothing() -> void:
	print("— Таб без дела")
	_fresh()
	var c := _column(2)
	var squad := _man(c)
	await _frames(1)
	var releases: int = int(w.stats["releases"])
	await _tab_at(c.seg_center(0) + Vector2(90.0, 0.0))
	_check(_alive_segs(c) == [0, 1] and int(w.stats["releases"]) == releases,
		"Таб над пустым местом — ничего")
	# натяжка рогатки: ПКМ зажата над участком
	await _move(c.seg_center(0))
	await _button(c.seg_center(0), MOUSE_BUTTON_RIGHT, true)
	await _key(KEY_TAB, true)
	await _key(KEY_TAB, false)
	_check(_alive_segs(c) == [0, 1], "Таб во время натяжки рогатки — ничего")
	await _key(KEY_ESCAPE, true)   # Esc снимает захват без выпуска
	await _key(KEY_ESCAPE, false)
	if w.paused:
		w.set_paused(false)
	await _button(c.seg_center(0), MOUSE_BUTTON_RIGHT, false)
	_check(_alive_segs(c) == [0, 1], "после отмены рогатки линия цела")
	# прицел Пробела
	await _key(KEY_SPACE, true)
	await _key(KEY_TAB, true)
	await _key(KEY_TAB, false)
	await _key(KEY_SPACE, false)
	_check(_alive_segs(c) == [0, 1], "Таб с зажатым Пробелом — ничего")
	# штрих ЛКМ: начат рядом, курсор над линией
	var from := c.seg_center(0) + Vector2(-120.0, 0.0)
	await _move(from)
	await _button(from, MOUSE_BUTTON_LEFT, true)
	for i in range(1, 9):
		await _move(from.lerp(c.seg_center(0), float(i) / 8.0), MOUSE_BUTTON_MASK_LEFT)
	var drawing := f.is_gesturing()
	await _key(KEY_TAB, true)
	await _key(KEY_TAB, false)
	_check(drawing and f.is_gesturing(), "штрих идёт и после Таба")
	_check(_alive_segs(c) == [0, 1] and _all_posted(squad), "Таб во время штриха — линия цела")
	f.cancel()
	await _button(c.seg_center(0), MOUSE_BUTTON_LEFT, false)


## 6) Фокус: в бою Таб не уводит фокус на кнопки, на паузе — ходит по ним, как раньше.
func _test_focus() -> void:
	print("— фокус интерфейса")
	_fresh()
	var c := _column(2)
	_man(c)
	# две кнопки в общем контейнере: иначе «следующая» у одиночной кнопки — она сама
	var layer := CanvasLayer.new()
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(layer)
	var box := HBoxContainer.new()
	box.position = Vector2(20, 600)
	layer.add_child(box)
	var b1 := Button.new()
	b1.text = "раз"
	b1.focus_mode = Control.FOCUS_ALL
	var b2 := Button.new()
	b2.text = "два"
	b2.focus_mode = Control.FOCUS_ALL
	box.add_child(b1)
	box.add_child(b2)
	await _frames(1)
	b1.grab_focus()
	await _frames(1)
	var vp := root
	await _tab_at(c.seg_center(0))
	_check(vp.gui_get_focus_owner() == b1, "в бою Таб не сдвинул фокус (у %s)"
		% [vp.gui_get_focus_owner()])
	_check(_alive_segs(c).is_empty(), "и стёр линию под курсором")
	var c2 := _column(2, 200.0)
	w.set_paused(true)
	await _frames(1)
	b1.grab_focus()
	await _tab_at(c2.seg_center(0))
	_check(vp.gui_get_focus_owner() == b2, "на паузе Таб ходит по кнопкам, как раньше (у %s)"
		% [vp.gui_get_focus_owner()])
	_check(_alive_segs(c2) == [0, 1], "на паузе Таб линию не трогает")
	w.set_paused(false)
	layer.queue_free()
	await _frames(1)
