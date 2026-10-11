extends SceneTree
##
## B-489 (Игорь 11.10.2026, живая игра): на выборе поправки щелчок срабатывал только по верхней
## полосе карточки — кнопкой была лишь строка-заголовок, а чипы и раскрытые детали под ней лежали
## в рамке, которая ловила только двойной щелчок. Регресс — НАСТОЯЩИМИ событиями
## (Input.parse_input_event, как clickwalk_menu): прямой emit прячет дефекты вёрстки.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_card_click_1011_test.gd -- --mute
## Кадр карточек (окно, не headless): добавить «--shot <папка>» после --mute.
##
## 1) щелчок в 85 % высоты невыделенной карточки выделяет её и даёт ей фокус клавиатуры;
## 2) двойной щелчок в нижнюю часть (раскрытые детали) подписывает ровно один раз;
## 3) щелчок и двойной щелчок по заголовку — как раньше;
## 4) Enter на строке в фокусе подписывает один раз; Tab ведёт фокус и выделение;
## 5) после «Другое предложение» новые карточки так же целиком кликабельны;
## 6) три места заняты: двойной щелчок по низу карточки — режим замены, без подписи; после
##    возврата щелчок по низу снова выделяет.
## Итог «CARD CLICK 1011: N/M OK»; код выхода 1 при провале. Сохранение временное.
##

const SAVE := "user://legion_card_click_1011.cfg"

var _fails := 0
var _checks := 0
var _shot_dir := ""


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
	var args := OS.get_cmdline_user_args()
	var at := args.find("--shot")
	if at >= 0 and at + 1 < args.size():
		_shot_dir = args[at + 1]
	Campaign.set_save_path(SAVE)
	Settings.path = "user://legion_card_click_1011_settings.cfg"
	Settings._cfg = null
	await _test_offer()
	await _test_replace()
	await _test_shift_and_hover()
	print("CARD CLICK 1011: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh(upgrades: Array) -> void:
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.unlock_all()
	Campaign.add_bounty(90)
	Campaign.set_pending_reward("gatehouse")
	Campaign.raw_file().set_value("meta", "upgrades", upgrades)
	Campaign.save_raw()


func _rows(p: UpgradePicker) -> Array[ProgressionRow]:
	var out: Array[ProgressionRow] = []
	for c in p._cards_box.get_children():
		if c is ProgressionRow and not c.is_queued_for_deletion():
			out.append(c as ProgressionRow)
	return out


## Точка на 85 % высоты карточки (в чипах или раскрытых деталях), заведомо вне кнопки-заголовка.
func _low(row: ProgressionRow) -> Vector2:
	var r := row.get_global_rect()
	var pt := Vector2(r.position.x + r.size.x * 0.3, r.position.y + r.size.y * 0.85)
	_check(not row.button().get_global_rect().has_point(pt)
		and root.get_visible_rect().has_point(pt),
		"точка %s ниже заголовка %s и на экране" % [pt, row.button().get_global_rect()])
	return pt


## Толщина рамки строки (обводка фокуса рисуется на рамке, а не на кнопке-заголовке).
func _border(row: ProgressionRow) -> int:
	var st := row.hit_area().get_theme_stylebox("panel") as StyleBoxFlat
	return st.border_width_top if st != null else -1


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _click(at: Vector2, double := false) -> void:
	var sp := root.get_final_transform() * at
	var mv := InputEventMouseMotion.new()
	mv.device = 8
	mv.position = sp
	mv.global_position = sp
	Input.parse_input_event(mv)
	await process_frame
	var down := InputEventMouseButton.new()
	down.device = 8
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.double_click = double
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.position = sp
	down.global_position = sp
	Input.parse_input_event(down)
	await process_frame
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	up.double_click = false
	up.button_mask = 0
	Input.parse_input_event(up)
	await _frames(2)


func _key(code: Key, shift := false) -> void:
	var key := InputEventKey.new()
	key.keycode = code
	key.physical_keycode = code
	key.shift_pressed = shift
	key.pressed = true
	Input.parse_input_event(key)
	await process_frame
	var up := key.duplicate() as InputEventKey
	up.pressed = false
	Input.parse_input_event(up)
	await _frames(3)


func _picker(got: Array[StringName]) -> UpgradePicker:
	var p := UpgradePicker.new()
	root.add_child(p)
	p.picked.connect(func(id: StringName) -> void: got.append(id))
	p.offer([&"bulk_ink", &"paper_shield", &"ghost_clause"])
	await _frames(12)
	return p


func _shot(name: String) -> void:
	if _shot_dir == "":
		return
	await _frames(20)
	DirAccess.make_dir_recursive_absolute(_shot_dir)
	var path := _shot_dir.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("  shot ", path)


func _test_offer() -> void:
	print("— выбор поправки: щелчок по нижней части карточки")
	_fresh([])
	var got: Array[StringName] = []
	var p: UpgradePicker = await _picker(got)
	var rows := _rows(p)
	_check(rows.size() == 3 and p.chosen() == rows[0].amendment_id, "три строки, первая выделена")
	var second := rows[1]
	await _click(_low(second))
	_check(p.chosen() == second.amendment_id,
		"щелчок в низ невыделенной карточки выделил её: %s" % p.chosen())
	_check(second.button().has_focus(), "фокус клавиатуры — на выделенной карточке")
	_check(got.is_empty(), "одиночный щелчок ничего не подписал: %s" % [got])
	_check(_border(second) == ProgressionRow.FOCUS_BORDER
		and second.button().get_theme_stylebox("focus") is StyleBoxEmpty,
		"обводка фокуса — на всей рамке (%d), у кнопки-заголовка своей нет" % _border(second))
	await _shot("01_second_selected_by_lower_click")
	# Выделенная карточка раскрылась — щёлкаем в раскрытые детали.
	var low := _low(second)
	await _click(low)
	_check(p.chosen() == second.amendment_id and got.is_empty(),
		"щелчок в детали выделенной — выделение то же, без подписи")
	await _click(low, true)
	_check(got == [second.amendment_id],
		"двойной щелчок по деталям подписал ровно один раз: %s" % [got])
	got.clear()
	var third := rows[2]
	var head := third.button().get_global_rect().get_center()
	await _click(head)
	_check(p.chosen() == third.amendment_id, "щелчок по заголовку выделяет, как раньше")
	await _click(head, true)
	_check(got == [third.amendment_id], "двойной щелчок по заголовку — одна подпись: %s" % [got])
	got.clear()
	rows[0].button().grab_focus()
	await _frames(2)
	_check(p.chosen() == rows[0].amendment_id, "фокус на строке выделяет её")
	await _key(KEY_TAB)
	_check(p.chosen() == rows[1].amendment_id, "Tab ведёт выделение к следующей строке")
	_check(_border(rows[1]) == ProgressionRow.FOCUS_BORDER
		and _border(rows[0]) < ProgressionRow.FOCUS_BORDER,
		"обводка фокуса ушла с рамки первой на рамку второй (%d → %d)"
		% [_border(rows[0]), _border(rows[1])])
	await _key(KEY_ENTER)
	_check(got == [rows[1].amendment_id], "Enter на строке — одна подпись: %s" % [got])
	got.clear()
	# «Другое предложение» пересобирает строки — новые тоже кликабельны целиком.
	var before := p.offered()
	await _click(p._reroll.get_global_rect().get_center())
	await _frames(4)
	_check(p.offered() != before and Campaign.bounty() < 90,
		"переброска сменила предложение: %s → %s" % [before, p.offered()])
	rows = _rows(p)
	_check(rows.size() == 3, "после переброски три строки")
	if rows.size() == 3:
		await _click(_low(rows[2]))
		_check(p.chosen() == rows[2].amendment_id and got.is_empty(),
			"после переброски щелчок в низ карточки выделяет: %s" % p.chosen())
		await _shot("02_after_reroll_lower_click")
	p.queue_free()
	await _frames(2)


## Первый щелчок по низу третьей карточки сворачивает первую — третья уезжает вверх; второй
## щелчок двойного в ту же точку экрана всё равно подписывает третью. Подсветка наведения не
## гаснет, когда курсор уходит с заголовка в детали той же карточки.
func _test_shift_and_hover() -> void:
	print("— сдвиг строк между щелчками двойного и подсветка наведения")
	_fresh([])
	var got: Array[StringName] = []
	var p: UpgradePicker = await _picker(got)
	var rows := _rows(p)
	var third := rows[2]
	var low := _low(third)
	await _click(low)
	_check(p.chosen() == third.amendment_id, "щелчок в низ третьей выделил её")
	await _click(low, true)
	_check(got == [third.amendment_id], "второй щелчок двойного после сдвига — одна подпись: %s"
		% [got])
	# Наведение проверяется только headless: в окне за экраном настоящий курсор ОС вне окна, и
	# вьюпорт не шлёт mouse_entered на подставные движения (кадровый прогон 11.10).
	if DisplayServer.get_name() != "headless":
		p.queue_free()
		await _frames(2)
		return
	var second := rows[1]
	var mv := InputEventMouseMotion.new()
	mv.device = 8
	mv.position = root.get_final_transform() * second.button().get_global_rect().get_center()
	mv.global_position = mv.position
	Input.parse_input_event(mv)
	await _frames(2)
	var on_head := second._hover
	var mv2 := mv.duplicate() as InputEventMouseMotion
	mv2.position = root.get_final_transform() * _low(second)
	mv2.global_position = mv2.position
	Input.parse_input_event(mv2)
	await _frames(2)
	_check(on_head and second._hover,
		"подсветка держится с заголовка до низа карточки (%s, %s)" % [on_head, second._hover])
	p.queue_free()
	await _frames(2)


func _test_replace() -> void:
	print("— три места заняты: двойной щелчок по низу карточки — режим замены")
	_fresh(["living_queue", "temp_agency", "lean_staff"])
	var got: Array[StringName] = []
	var p: UpgradePicker = await _picker(got)
	var rows := _rows(p)
	var second := rows[1]
	var low := _low(second)
	await _click(low)
	_check(p.chosen() == second.amendment_id, "щелчок в низ выделил вторую")
	await _click(low, true)
	_check(p._replacing == second.amendment_id and got.is_empty() and not p._cards_box.visible,
		"двойной щелчок по низу — режим замены, без подписи (%s, %s)" % [p._replacing, got])
	await _key(KEY_ESCAPE)
	_check(p._replacing == &"" and p._cards_box.visible and p.chosen() == second.amendment_id,
		"Esc вернул к предложению с тем же выделением: %s" % p.chosen())
	await _frames(2)
	await _click(_low(rows[2]))
	_check(p.chosen() == rows[2].amendment_id and p._replacing == &"",
		"после возврата щелчок в низ карточки снова выделяет: %s" % p.chosen())
	await _shot("03_replace_return_lower_click")
	p.queue_free()
	await _frames(2)
