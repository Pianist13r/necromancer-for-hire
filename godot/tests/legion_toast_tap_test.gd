extends SceneTree
## B-487: щелчок поля и тосты HUD. Тост мышь не ловит, его щелчок разбирает LegionHud.ui_tap из
## ContractField._release (B-273). Проверяем:
##  1) площадка под плашкой тоста — меню участка открывается ОДНИМ щелчком (раньше первый щелчок
##     только снимал плашку);
##  2) видимый тост не над площадкой по-прежнему снимается щелчком и в поле не уходит;
##  3) невидимый тост щелчок не ловит: кино-режим записи, спрятанный HUD, прозрачность 0 —
##     щелчок доходит до поля (tap), плашка остаётся;
##  4) «Подсказки: выкл» — разовые подсказки карт (LegionMapHints) не показываются и не
##     помечаются виденными: включили галочку — подсказка приходит, пока повод ещё на поле.
## Клики — настоящими событиями Input.parse_input_event, как у человека, не вызовом ui_tap():
## иначе порядок «ui_tap раньше tap» в ContractField._release не проверяется.
## Запуск: --headless --path godot --fixed-fps 60
##   --script res://tests/legion_toast_tap_test.gd -- --mute
## Кадры приёмки (не headless; --mute держит окно за экраном, AgentWindow):
##   --path godot --fixed-fps 60 --script res://tests/legion_toast_tap_test.gd
##   -- --mute --shots <папка>   — PNG до/после щелчка: площадка под тостом и кино-режим.

const SAVE := "user://legion_toast_tap_test.cfg"
const LONG := 30.0
## Ждать, пока тост проявится целиком (вход 0,12 с при 60 кадрах — 8 кадров, с запасом).
const FADE_IN_FRAMES := 14

var w: LegionWorld
var _checks := 0
var _fails := 0
var _taps: Array[Vector2] = []
var _toasts: Array[String] = []
## --shots <папка>: куда класть кадры; "" — без кадров (headless кадров не рисует).
var _shots := ""


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
	var argv := OS.get_cmdline_user_args()
	var at := argv.find("--shots")
	if at >= 0 and at + 1 < argv.size() and DisplayServer.get_name() != "headless":
		_shots = argv[at + 1]
		DirAccess.make_dir_recursive_absolute(_shots)
		print("SHOTS %s · окно %s, режим %d" % [_shots, root.position, root.mode])
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	w.toast_posted.connect(func(text: String, _kind: StringName) -> void: _toasts.append(text))
	await _frames(2)
	w.contracts.tap.connect(func(pos: Vector2) -> void: _taps.append(pos))
	await _test_plot_under_toast()
	await _test_visible_toast_dismiss()
	await _test_cinematic()
	await _test_hidden_hud()
	await _test_zero_alpha()
	await _test_hints_off_on()
	Settings.hints_override = ""
	Campaign.reset()
	_cleanup_save()
	print("LEGION TOAST TAP: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Свой save и его .bak — прочь: прогон не оставляет следов в user://.
func _cleanup_save() -> void:
	for path in [SAVE, SAVE + ".bak"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Кадр окна в папку --shots (только не headless).
func _shot(file: String) -> void:
	if _shots == "":
		return
	await RenderingServer.frame_post_draw
	var path := _shots.path_join(file)
	var err := root.get_texture().get_image().save_png(path)
	print("SHOT %s err=%d" % [path, err])


func _click(at: Vector2) -> void:
	print("CLICK %s" % at)
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


func _start(map_id: String) -> void:
	Campaign.reset()
	Settings.hints_override = "on"
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1", "spawn_units": "0"}
	w.args["bot"] = "off"
	w.start_map(map_id)


## Чистая HUD-полоса тостов: без вводного тоста карты, столбик на обычном месте.
func _clean_toasts() -> void:
	w.hud.set_cinematic(false)
	w.hud.visible = true
	w.hud.set_toast_floor(0.0)
	w.hud.drop_toasts()
	w.plot_menu.close()
	await _frames(2)
	_taps.clear()


## Живой тост с этим текстом (столбик или вынесенный мимо меню); null — нет такого.
func _toast_panel(text: String) -> Control:
	for t in w.hud._toast_nodes():
		for l in t.find_children("*", "Label", true, false):
			if (l as Label).text == text:
				return t
	return null


## Без типа у параметра: снятая щелчком плашка уже освобождена, а типизированный аргумент
## на освобождённом объекте — SCRIPT ERROR вместо честного «нет».
func _alive(panel: Variant) -> bool:
	return is_instance_valid(panel) and not (panel as Control).is_queued_for_deletion()


## Площадка под этой экранной точкой — та же выборка, что у меню участка (PlotMenu._on_tap).
func _plot_under(screen: Vector2) -> Dictionary:
	return w.my_side().staff.plot_at(w.screen_to_world(screen),
		LegionCfg.PLOT_PICK_R / w.view_scale())


## Свободная площадка в средней полосе экрана (под столбик тостов ширины HUD_TOAST_MAX_W).
func _middle_plot() -> Dictionary:
	var best: Dictionary = {}
	for p: Dictionary in w.staff.plots:
		var s := w.world_to_screen(p["pos"])
		if p["building"] != null or s.x < 420.0 or s.x > 860.0 or s.y < 120.0 or s.y > 520.0:
			continue
		if best.is_empty() or s.y < w.world_to_screen(best["pos"]).y:
			best = p
	return best


## Тост в столбике, проявленный целиком; точка щелчка — центр, площадки под ней нет.
func _nonplot_toast(text: String) -> Control:
	w.toast(text, &"info", LONG)
	await _frames(FADE_IN_FRAMES)
	var panel := _toast_panel(text)
	_check(panel != null, "тост «%s» висит" % text)
	if panel == null:
		return null
	var at := panel.get_global_rect().get_center()
	_check(_plot_under(at).is_empty(), "под центром тоста площадки нет (%s)" % at)
	return panel


# ── 1. площадка под тостом ──────────────────────────────────────────────────────

func _test_plot_under_toast() -> void:
	print("— B-487: площадка под плашкой тоста — меню одним щелчком")
	_start("archive")
	await _frames(3)
	await _clean_toasts()
	var p := _middle_plot()
	_check(not p.is_empty(), "свободная площадка в средней полосе найдена")
	if p.is_empty():
		return
	var at := w.world_to_screen(p["pos"])
	# Столбик тостов опускаем так, чтобы плашка легла ровно на площадку: в игре туда же его
	# сдвигает плашка урока (set_toast_floor), а стопка из вводного тоста и подсказки — сама.
	w.hud.set_toast_floor(at.y - 14.0)
	var text := "Проверка B-487: длинная подсказка лежит поверх площадки, щелчок по площадке " \
		+ "должен открыть меню участка сразу, а не только снять эту плашку."
	w.toast(text, &"info", LONG)
	await _frames(FADE_IN_FRAMES)
	var panel := _toast_panel(text)
	_check(panel != null, "тост висит")
	if panel == null:
		return
	var rect := panel.get_global_rect()
	# Предусловие RED: без перекрытия старый код тоже открыл бы меню, и тест ничего не доказал бы
	_check(rect.has_point(at), "тост действительно накрывает точку щелчка (тост %s, точка %s)"
		% [rect, at])
	_check(panel.modulate.a > 0.99 and panel.is_visible_in_tree(),
		"тост проявлен целиком (альфа %.2f)" % panel.modulate.a)
	_check(String(_plot_under(at).get("id", "")) == String(p["id"]),
		"меню участка выбрало бы эту площадку по точке щелчка")
	await _shot("1_plot_under_toast_before.png")
	await _click(at)
	await _shot("2_plot_under_toast_after_click.png")
	_check(w.plot_menu.is_open(), "один щелчок по площадке под тостом открыл меню участка")
	_check(w.plot_menu.is_open() and String(w.plot_menu.plot.get("id", "")) == String(p["id"]),
		"меню открыто именно у этой площадки")
	_check(_alive(_toast_panel(text)), "плашка не снята: щелчок был по площадке, а не по ней")
	var card := w.plot_menu.panel_rect()
	_check(card.has_area() and not card.has_point(at), "карточка меню не легла на точку щелчка")
	# Меню открыто: щелчок по той же площадке под тостом — «щелчок мимо меню» (PlotMenu): меню
	# закрывается, щелчок больше ничего не делает — ни нового меню, ни снятия плашки.
	await _click(at)
	_check(not w.plot_menu.is_open(), "щелчок при открытом меню только закрыл его")
	_check(_alive(_toast_panel(text)), "закрывающий щелчок плашку не снял")
	await _click(at)
	_check(w.plot_menu.is_open(), "следующий щелчок снова открыл меню одним щелчком")
	w.plot_menu.close()
	# «Схватка»/сеть: щелчок чужого поля (не того, что слушает меню) тосты не пропускает
	if w.plot_menu.has_method("takes_tap"):
		var other := ContractField.new()
		_check(not bool(w.plot_menu.call("takes_tap", other, p["pos"])),
			"чужое поле: площадка под точкой не забирает щелчок у тоста")
		_check(bool(w.plot_menu.call("takes_tap", w.my_field(), p["pos"])),
			"своё поле: площадка под точкой забирает щелчок")
		other.free()
	else:
		_check(false, "PlotMenu.takes_tap есть (маршрут щелчка площадки)")
	w.hud.set_toast_floor(0.0)


# ── 2. видимый тост не над площадкой ────────────────────────────────────────────

func _test_visible_toast_dismiss() -> void:
	print("— B-273: видимый тост мимо площадок снимается щелчком")
	await _clean_toasts()
	var text := "Проверка: обычная плашка мимо площадок"
	var panel: Control = await _nonplot_toast(text)
	if panel == null:
		return
	await _click(panel.get_global_rect().get_center())
	_check(not _alive(panel) and _toast_panel(text) == null, "щелчок снял плашку")
	_check(_taps.is_empty(), "щелчок по плашке не ушёл в поле (tap: %s)" % [_taps])
	_check(not w.plot_menu.is_open(), "меню участка не открылось")


# ── 3. невидимые тосты ──────────────────────────────────────────────────────────

func _test_cinematic() -> void:
	print("— B-487: кино-режим записи — спрятанный тост щелчок не ловит")
	await _clean_toasts()
	var text := "Проверка: тост под кино-режимом"
	var panel: Control = await _nonplot_toast(text)
	if panel == null:
		return
	var at := panel.get_global_rect().get_center()
	await _shot("3_cinematic_toast_visible.png")
	w.hud.set_cinematic(true)
	await _frames(1)
	await _shot("4_cinematic_on_before_click.png")
	await _click(at)
	await _shot("5_cinematic_on_after_click.png")
	_check(_taps.size() == 1, "щелчок дошёл до поля (tap: %s)" % [_taps])
	_check(_alive(panel), "спрятанная плашка щелчком не снята")
	w.hud.set_cinematic(false)
	await _frames(1)
	await _shot("6_cinematic_off_toast_kept.png")
	_taps.clear()
	await _click(at)
	_check(not _alive(panel), "кино-режим выключен — та же плашка снова снимается щелчком")
	_check(_taps.is_empty(), "и щелчок по ней снова не уходит в поле")


func _test_hidden_hud() -> void:
	print("— B-487: HUD спрятан — тост щелчок не ловит")
	await _clean_toasts()
	var text := "Проверка: тост под спрятанным HUD"
	var panel: Control = await _nonplot_toast(text)
	if panel == null:
		return
	var at := panel.get_global_rect().get_center()
	w.hud.visible = false
	await _frames(1)
	_check(panel.visible, "сама плашка видима — спрятан предок (HUD)")
	await _click(at)
	_check(_taps.size() == 1, "щелчок дошёл до поля (tap: %s)" % [_taps])
	_check(_alive(panel), "плашка под спрятанным HUD щелчком не снята")
	w.hud.visible = true
	await _frames(1)


func _test_zero_alpha() -> void:
	print("— B-487: тост прозрачен — щелчок не ловит, место в раскладке держит")
	await _clean_toasts()
	var text := "Проверка: прозрачный тост"
	var panel: Control = await _nonplot_toast(text)
	if panel == null:
		return
	var at := panel.get_global_rect().get_center()
	# твин тоста сейчас в паузе показа (tween_interval) — альфу не трогает до затухания
	panel.modulate.a = 0.0
	await _frames(1)
	_check(panel.visible and panel.modulate.a == 0.0,
		"плашка прозрачна (альфа %.2f)" % panel.modulate.a)
	_check(w.hud.toast_rects().has(panel.get_global_rect()),
		"прозрачная плашка по-прежнему учтена в раскладке тостов (toast_rects)")
	await _click(at)
	_check(_taps.size() == 1, "щелчок по прозрачной плашке дошёл до поля (tap: %s)" % [_taps])
	_check(_alive(panel), "прозрачная плашка щелчком не снята")
	w.hud.drop_toasts()
	await _frames(1)


# ── 4. «Подсказки: выкл» ────────────────────────────────────────────────────────

func _hint_count(prefix: String) -> int:
	return _toasts.filter(func(t: String) -> bool: return t.begins_with(prefix)).size()


func _test_hints_off_on() -> void:
	print("— B-487: «Подсказки: выкл» — разовые подсказки карт молчат и не тратятся")
	_start("fork")
	await _frames(3)
	await _clean_toasts()
	Settings.hints_override = "off"
	_toasts.clear()
	var far := Vector2(1100.0, 600.0)
	w.spawn_foe_on_path("signer", PackedVector2Array([far, far + Vector2(1, 0)]), far)
	w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(400.0, 400.0))
	await _frames(4)
	_check(_hint_count("Нотариус") == 0, "подсказки выкл — про нотариуса молчит (%s)" % [_toasts])
	_check(_hint_count("Вахтёры") == 0, "подсказки выкл — про вахтёров молчит")
	_check(not Campaign.hint_seen(&"foe_signer"), "подсказка нотариуса не помечена виденной")
	_check(not Campaign.hint_seen(&"unit_guard_front"), "подсказка вахтёров не помечена виденной")
	Settings.hints_override = "on"
	await _frames(3)
	# Нотариус — опрос поля каждый кадр: стоит на поле — подсказка приходит сама. Вахтёр —
	# по рождению бойца: уже родившийся при «выкл» её не принесёт, нужен новый.
	_check(_hint_count("Вахтёры") == 0, "включили — про вахтёров молчит до нового вахтёра")
	_check(_hint_count("Нотариус") == 1,
		"подсказки вкл — нотариус ещё на поле, подсказка пришла (%d)" % _hint_count("Нотариус"))
	_check(Campaign.hint_seen(&"foe_signer"), "теперь подсказка нотариуса помечена")
	w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(420.0, 400.0))
	await _frames(2)
	_check(_hint_count("Вахтёры") == 1, "подсказки вкл — новый вахтёр приносит подсказку")
	_check(Campaign.hint_seen(&"unit_guard_front"), "теперь подсказка вахтёров помечена")
	w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(440.0, 400.0))
	await _frames(2)
	_check(_hint_count("Вахтёры") == 1, "разовая подсказка не повторяется")
