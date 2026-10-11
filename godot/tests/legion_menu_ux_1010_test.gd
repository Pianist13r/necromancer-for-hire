extends SceneTree
## Мелкие заносы удобства 10.10 (slow/menu-ux): ссылки сообщества в меню и на итоге (B-467),
## подсказка нотариуса — рано и в полосе HUD, а не поверх поля (B-273), меню участка не
## закрывает тост (B-010). Клики — настоящими событиями Input.parse_input_event в центр
## фактического прямоугольника, не signal.emit(): иначе дефект вёрстки (кнопка за кадром,
## перехват мыши соседом) прячется. Браузер не открывается — ReleaseInfo.url_opener подменён.
## Запуск: --headless --path godot --fixed-fps 60
##   --script res://tests/legion_menu_ux_1010_test.gd -- --mute

const SAVE := "user://legion_menu_ux_1010_test.cfg"
const VIEW := Rect2(Vector2.ZERO, Vector2(1280, 720))

var w: LegionWorld
var _checks := 0
var _fails := 0
var _opened: Array[String] = []
var _toasts: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	ReleaseInfo.url_opener = func(url: String) -> void: _opened.append(url)
	await _test_menu_links()
	await _test_result_link()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	w.toast_posted.connect(func(text: String, _kind: StringName) -> void: _toasts.append(text))
	await _frames(2)
	await _test_signer_hint()
	await _test_door_hint_in_hud()
	await _test_plot_menu_vs_toast()
	ReleaseInfo.url_opener = Callable()
	ReleaseInfo.channel_override = ""
	Settings.hints_override = ""
	Campaign.reset()
	_cleanup_save()
	print("LEGION MENU UX 1010: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Свой save и его .bak — прочь: прогон не оставляет следов в user://.
func _cleanup_save() -> void:
	for path in [SAVE, SAVE + ".bak"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _click(at: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = at
	move.global_position = at
	Input.parse_input_event(move)
	await process_frame
	var press := InputEventMouseButton.new()
	press.position = at
	press.global_position = at
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	Input.parse_input_event(release)
	await _frames(2)


# ── B-467: ссылки сообщества ────────────────────────────────────────────────────

func _test_menu_links() -> void:
	print("— B-467: «Сообщество» в главном меню")
	ReleaseInfo.channel_override = "standalone"
	var menu := LegionMenu.new()
	root.add_child(menu)
	await _frames(5)
	var want := {"CommunityChannel": ReleaseInfo.TELEGRAM_CHANNEL_URL,
		"CommunityChat": ReleaseInfo.TELEGRAM_CHAT_URL, "CommunitySite": ReleaseInfo.SITE_URL}
	var others: Array[Rect2] = []
	for node in menu.find_children("*", "Button", true, false):
		if not String(node.name).begins_with("Community") and (node as Control).is_visible_in_tree():
			others.append((node as Control).get_global_rect())
	for button_name: String in want:
		var btn := menu.find_child(button_name, true, false) as Button
		_check(btn != null and btn.is_visible_in_tree(), "кнопка %s есть" % button_name)
		if btn == null:
			continue
		var rect := btn.get_global_rect()
		_check(VIEW.encloses(rect), "%s в кадре: %s" % [button_name, rect])
		_check(not others.any(func(r: Rect2) -> bool: return r.intersects(rect)),
			"%s не наезжает на кнопки меню" % button_name)
		_opened.clear()
		await _click(rect.get_center())
		_check(_opened == [String(want[button_name])],
			"клик по %s открывает %s (%s)" % [button_name, want[button_name], _opened])
	menu.free()
	# Steam-сборка: сайт раздаёт сборки вне Steam — ссылки на него нет, Telegram остаётся
	ReleaseInfo.channel_override = "steam"
	menu = LegionMenu.new()
	root.add_child(menu)
	await _frames(3)
	_check(menu.find_child("CommunitySite", true, false) == null, "в Steam-сборке «Сайт» скрыт")
	_check(menu.find_child("CommunityChat", true, false) != null, "в Steam-сборке чат остаётся")
	menu.free()
	ReleaseInfo.channel_override = ""


func _test_result_link() -> void:
	print("— B-467: строка «Поделиться впечатлением» на итоге")
	var r := LegionResult.new()
	root.add_child(r)
	r.show_result(true, {"map_title": "Развилка", "kills": 10, "lost": 2, "time": 60.0}, 3, true)
	await _frames(4)
	var link := r.find_child("ShareChat", true, false) as Button
	_check(link != null and link.is_visible_in_tree(), "ссылка на чат на экране итога")
	if link == null:
		r.free()
		return
	var rect := link.get_global_rect()
	_check(VIEW.encloses(rect), "ссылка в кадре: %s" % rect)
	var over := false
	for node in r.find_children("*", "Button", true, false):
		if node != link and (node as Control).get_global_rect().intersects(rect):
			over = true
	_check(not over, "ссылка не лежит на кнопках итога")
	var focus := root.gui_get_focus_owner()
	_check(focus != null and focus.name == "NavPrimary", "фокус остаётся у главного действия")
	_opened.clear()
	await _click(rect.get_center())
	_check(_opened == [ReleaseInfo.TELEGRAM_CHAT_URL], "клик открывает чат (%s)" % [_opened])
	r.free()


# ── B-273: печати нотариуса ─────────────────────────────────────────────────────

func _start(map_id: String) -> void:
	Campaign.reset()
	Settings.hints_override = "on"
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1", "spawn_units": "0"}
	w.args["bot"] = "off"
	w.start_map(map_id)


## Первый нотариус на поле — плашка сразу, до первой печати; плашка — в верхней полосе HUD.
func _test_signer_hint() -> void:
	print("— B-273: подсказка про нотариуса при его появлении")
	_start("fork")
	await _frames(3)
	_toasts.clear()
	var far := Vector2(1100.0, 600.0)
	w.spawn_foe_on_path("signer", PackedVector2Array([far, far + Vector2(1, 0)]), far)
	await _frames(3)
	var got := _toasts.filter(func(t: String) -> bool: return t.begins_with("Нотариус"))
	_check(got.size() == 1, "первый нотариус — плашка-подсказка сразу (%d)" % got.size())
	_check(w.stats.get("lost", 0) == 0, "плашка пришла до первой потери")
	var rects := w.hud.toast_rects()
	var top_band := not rects.is_empty() and rects.all(func(r: Rect2) -> bool:
		return r.end.y <= VIEW.size.y * 0.35)
	_check(top_band, "плашка в верхней полосе HUD, не в центре поля: %s" % [rects])
	_check(Campaign.hint_seen(&"foe_signer"), "флаг стоит — в следующем бою не повторится")
	if not rects.is_empty():
		# над подсказкой может стоять вводный тост карты — щёлкаем саму подсказку (нижнюю)
		await _click(rects[-1].get_center())
		await _frames(2)
		_check(w.hud.toast_rects().size() == rects.size() - 1,
			"щелчок по плашке убирает её одну (%d → %d)" % [rects.size(), w.hud.toast_rects().size()])
		_check(not w.plot_menu.is_open(), "щелчок по плашке не уходит в поле (меню участка)")
	_toasts.clear()
	var far2 := far + Vector2(0, -60)
	w.spawn_foe_on_path("signer", PackedVector2Array([far2, far2 + Vector2(1, 0)]), far2)
	await _frames(3)
	_check(_toasts.filter(func(t: String) -> bool: return t.begins_with("Нотариус")).is_empty(),
		"второй нотариус — без повтора")


## B-124-совет «печати у двери» — плашкой HUD, а не подписью над постройкой посреди поля.
func _test_door_hint_in_hud() -> void:
	print("— B-273: совет «у двери» — в полосе HUD")
	_start("fork")
	w.souls = 1000
	var b := w.staff.build(w.staff.plots[1], LegionCfg.KIND_LABORER)
	for i in 3:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, b.entry + Vector2(8.0 * i, 12.0))
		u.take_damage(u.hp + 1.0, u.position)
	var at := b.entry + Vector2(180.0, 0.0)
	w.spawn_foe_on_path("signer", PackedVector2Array([at, at + Vector2(1, 0)]), at)
	_toasts.clear()
	w.intuit.scan()
	await _frames(2)
	_check(w.intuit.hints_shown(&"door") == 1, "совет показан (%d)" % w.intuit.hints_shown(&"door"))
	_check(not w.intuit.label_rect(&"door").has_area(), "подписи над постройкой на поле нет")
	var door := Controls.text(IntuitCfg.HINT_DOOR)
	_check(_toasts.has(door), "совет пришёл плашкой HUD (%s)" % [_toasts])


# ── B-010: меню участка и тост ──────────────────────────────────────────────────

func _top_plot() -> Dictionary:
	var best: Dictionary = {}
	for p: Dictionary in w.staff.plots:
		if p["building"] == null and (best.is_empty()
				or (p["pos"] as Vector2).y < (best["pos"] as Vector2).y):
			best = p
	return best




## Ни один тост (столбик и вынесенные) не пересекается с карточкой меню — по глобальным rect.
func _menu_vs_toasts(label: String) -> void:
	var menu_rect: Rect2 = w.plot_menu._panel.get_global_rect()
	var hit := w.hud.toast_rects().filter(func(r: Rect2) -> bool: return r.intersects(menu_rect))
	_check(hit.is_empty(), "%s: тост не пересекает меню участка (меню %s, тосты %s)"
		% [label, menu_rect, w.hud.toast_rects()])


## Видим ли сейчас тост с этим текстом.
func _toast_shown(text: String) -> bool:
	for t in w.hud._toast_nodes():
		for l in t.find_children("*", "Label", true, false):
			if (l as Label).text == text:
				return true
	return false


func _test_plot_menu_vs_toast() -> void:
	print("— B-010: меню участка у верхней кромки и тост HUD")
	_start("archive")   # площадка (700, 150) — у верхней кромки, под столбиком тостов
	await _frames(3)
	w.hud.drop_toasts()
	await _frames(1)
	var p := _top_plot()
	_check(not p.is_empty(), "свободная площадка найдена")
	if p.is_empty():
		return
	# 1) тост висит — открываем меню реальным кликом
	w.toast("Проверка: длинная подсказка карты в две строки стоит поверх поля, и меню участка, "
		+ "открытое у верхней кромки, не должно её закрывать ни краем.", &"info", 30.0)
	await _frames(2)
	await _click(w.world_to_screen(p["pos"]))
	_check(w.plot_menu.is_open(), "клик по площадке у кромки (%s) открыл меню" % [p["pos"]])
	_menu_vs_toasts("тост раньше меню")
	# 2) меню открыто — приходят новые тосты: мимо карточки, лишние — в очередь до закрытия
	w.toast("Второй тост приходит, пока меню открыто", &"warn", 30.0)
	await _frames(2)
	_menu_vs_toasts("тост позже меню")
	var last := ""
	for i in 8:
		last = "Тост %d при открытом меню: длинный текст, чтобы бумажка заняла две строки " % i \
			+ "и место вокруг меню кончилось."
		w.toast(last, &"info", 30.0)
		await _frames(1)
	_menu_vs_toasts("поток тостов при открытом меню")
	var queued := w.hud.queued_toasts()
	_check(queued > 0, "места нет — тосты ждут закрытия меню (%d в очереди)" % queued)
	_check(not _toast_shown(last), "последний тост пока не показан")
	w.plot_menu.close()
	await _frames(3)
	_check(w.hud.queued_toasts() == 0, "меню закрыто — очередь разобрана")
	_check(_toast_shown(last), "отложенный тост показан после закрытия меню")
	w.hud.drop_toasts()
