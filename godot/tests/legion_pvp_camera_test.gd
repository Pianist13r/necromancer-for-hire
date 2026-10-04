extends SceneTree
##
## P5a «Схватки» (docs/dev/PVP_PLAN_0929.md): камера показывает всё поле 1600×900 в логическом
## экране 1280×720, мышь переводится в мир ОДНОЙ трансформацией. Всё — НАСТОЯЩИМИ событиями
## ввода (Input.parse_input_event в координатах окна), как у человека:
##  1) одиночка — вид тождественный: точка мыши = точка мира (прицел, курсор поля), камера ×1,
##     радиус захвата участка и якорь меню площадки прежние;
##  2) PvP — масштаб 0,8, оба Котла на экране; мышь над чужим Котлом — прицел в чужом Котле;
##  3) PvP — штрих ЛКМ по экрану создаёт договор в мировых координатах под курсором;
##  4) PvP — рогатка ПКМ и Таб берут участок под курсором; радиус захвата на экране — как в
##     одиночке (PICK_R_MAX экранных px), а не ужат масштабом;
##  5) PvP — Ку по чужому бойцу у чужого Котла, «Сбор» (R) — в точку мира под курсором;
##  6) PvP — щелчок по своей площадке открывает меню у неё на экране, кнопка строит.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_camera_test.gd -- --mute
##
## Новый API мира не зовётся: на старом коде тест не падает разбором, а честно проваливает
## проверки. Итог «LEGION PVP CAMERA: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pvp_camera_test.cfg"
const DUEL := "pvp:duel"
const DEVICE := 9
## Логический экран (stretch canvas_items, aspect keep) — он же мир одиночки.
const SCREEN := Vector2(1280.0, 720.0)
## Своя половина «Дуэли» между валунами (480,250 r42) и (640,450 r36), левее стыка (x 770).
const LAB := Vector2(580.0, 150.0)

var w: LegionWorld
var f: ContractField
var _fails := 0
var _checks := 0
## Ожидаемый вид мира: масштаб и сдвиг (считается тестом независимо от кода игры).
var _scale := 1.0
var _shift := Vector2.ZERO


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


func _near(a: Vector2, b: Vector2, eps := 1.0) -> bool:
	return a.distance_to(b) <= eps


# ── Вид и настоящие события ввода ────────────────────────────────────────────

## Всё поле в экран, по центру: так должен показывать мир человек-игрок.
func _expect_view(size: Vector2) -> void:
	_scale = minf(SCREEN.x / size.x, SCREEN.y / size.y)
	_shift = SCREEN * 0.5 - size * 0.5 * _scale


## Точка мира → логический экран (ожидаемо).
func _view(p: Vector2) -> Vector2:
	return p * _scale + _shift


## Логический экран → окно (растяжение canvas_items), как у водителя приёмки.
func _window(p: Vector2) -> Vector2:
	return root.get_final_transform() * _view(p)


func _move(p: Vector2, mask: int = 0) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _window(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _window(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


## Щелчок по точке ЭКРАНА (кнопки интерфейса живут в экранных координатах).
func _click_screen(s: Vector2) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.device = DEVICE
		ev.position = root.get_final_transform() * s
		ev.global_position = ev.position
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		Input.parse_input_event(ev)
		await _frames(1)


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(1)


func _stroke(a: Vector2, b: Vector2) -> void:
	await _move(a)
	await _button(a, MOUSE_BUTTON_LEFT, true)
	var n := maxi(1, ceili(a.distance_to(b) / 8.0))
	for i in range(1, n + 1):
		await _move(a.lerp(b, float(i) / n), MOUSE_BUTTON_MASK_LEFT)
	await _button(b, MOUSE_BUTTON_LEFT, false)
	await _frames(2)


# ── Мир ──────────────────────────────────────────────────────────────────────

func _cam_zoom() -> float:
	var cam := w.get_viewport().get_camera_2d()
	return cam.zoom.x if cam != null else 1.0


func _single() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w.start_map("_gray")
	w.dev_invuln = false
	f = w.contracts
	f.mana = f.mana_max
	_expect_view(LegionCfg.WORLD_SIZE)
	await _frames(3)


func _duel() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w._base_seed = 7
	w.start_map(DUEL)
	w.dev_invuln = false
	f = w.contracts
	f.mana = f.mana_max
	_expect_view(w.world_size)
	await _frames(3)


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


func _column(a: Vector2, n: int) -> Contract:
	var pts := PackedVector2Array()
	var b := a + Vector2(0, 64.0 * n)
	for i in 8 * n + 1:
		pts.append(a.lerp(b, float(i) / (8 * n)))
	return f.add_contract(pts, 1, false)


# ── 1) одиночка: тождество ──────────────────────────────────────────────────

func _test_single() -> void:
	print("— одиночка: вид тождественный")
	await _single()
	_check(w.world_size == LegionCfg.WORLD_SIZE and is_equal_approx(_cam_zoom(), 1.0),
		"поле 1280×720, камера ×1 (zoom %.3f)" % _cam_zoom())
	var ok := true
	for p: Vector2 in [Vector2(3, 5), Vector2(640, 360), Vector2(1277, 716), Vector2(911.5, 77.25)]:
		await _move(p)
		# допуск — только на округление окно→вьюпорт у водителя (0,0001 px), не на вид
		if not _near(w.aim_pos(), p, 0.01) or not _near(f._pointer, p, 0.01):
			ok = false
			print("    мышь %s → прицел %s, курсор поля %s" % [p, w.aim_pos(), f._pointer])
	_check(ok, "точка мыши = точка мира (прицел и курсор поля)")
	_check(is_equal_approx(f.pick_radius(), clampf(LegionCfg.PICK_SCREEN_R
		/ (root.get_final_transform().get_scale().x), LegionCfg.PICK_R_MIN, LegionCfg.PICK_R_MAX)),
		"радиус захвата прежний: %.2f" % f.pick_radius())
	# у «_gray» площадок нет — меню открываем на пустой площадке-заглушке
	var plot := {"id": "probe", "pos": Vector2(500, 300), "building": null}
	w.plot_menu.open(plot, plot["pos"])
	var at: Vector2 = w.plot_menu._anchor
	w.plot_menu.close()
	_check(at == plot["pos"], "меню площадки — у самой точки (якорь %s)" % at)


# ── 2) PvP: камера и прицел ─────────────────────────────────────────────────

func _test_camera() -> void:
	print("— PvP: всё поле в кадре")
	await _duel()
	_check(w.pvp and w.world_size == Vector2(1600, 900),
		"«Дуэль»: поле %s, PvP %s" % [w.world_size, w.pvp])
	_check(is_equal_approx(_cam_zoom(), 0.8), "камера ×0,8 (zoom %.3f)" % _cam_zoom())
	var xf := w.get_viewport().get_canvas_transform()
	var screen := Rect2(Vector2.ZERO, SCREEN)
	var own := xf * w.cauldron_of(0)
	var foe := xf * w.cauldron_of(1)
	_check(screen.has_point(own) and screen.has_point(foe),
		"оба Котла на экране: свой %s, чужой %s" % [own, foe])
	_check(_near(foe, _view(w.cauldron_of(1))), "вид совпадает с ожидаемым: %s" % foe)
	await _move(w.cauldron_of(1))
	_check(_near(w.aim_pos(), w.cauldron_of(1)),
		"мышь над чужим Котлом — прицел в нём: %s (Котёл %s)" % [w.aim_pos(), w.cauldron_of(1)])
	_check(_near(f._pointer, w.cauldron_of(1)), "курсор поля — там же: %s" % f._pointer)


# ── 3) PvP: штрих ───────────────────────────────────────────────────────────

func _test_stroke() -> void:
	print("— PvP: штрих ЛКМ")
	await _duel()
	var before := f.contracts.size()
	var a := LAB
	var b := LAB + Vector2(0, 150)
	await _stroke(a, b)
	_check(f.contracts.size() == before + 1, "штрих создал договор (%d → %d)" % [before,
		f.contracts.size()])
	if f.contracts.size() == before + 1:
		var c: Contract = f.contracts[f.contracts.size() - 1]
		var p0 := c.points[0]
		var p1 := c.points[c.points.size() - 1]
		_check(_near(p0, a, 10.0) and _near(p1, b, 10.0) and c.owner_side == 0,
			"договор в мире под курсором: %s … %s (ждали %s … %s), сторона %d" % [p0, p1, a, b,
				c.owner_side])


# ── 4) PvP: рогатка, Таб, радиус ────────────────────────────────────────────

func _test_sling_tab() -> void:
	print("— PvP: рогатка ПКМ, Таб, радиус захвата")
	await _duel()
	_check(f.pick_radius() * _scale >= LegionCfg.PICK_R_MAX - 0.5,
		"радиус захвата на экране %.1f px (в одиночке %.0f)" % [f.pick_radius() * _scale,
			LegionCfg.PICK_R_MAX])
	var c := _column(LAB, 2)
	_man(c)
	await _frames(2)
	# рогатка: ПКМ на участке 1, оттяжка назад (против стрелки), отпустить
	var grip := c.seg_center(1)
	await _move(grip)
	await _button(grip, MOUSE_BUTTON_RIGHT, true)
	for i in range(1, 9):
		await _move(grip - c.dir * 10.0 * i, MOUSE_BUTTON_MASK_RIGHT)
	await _button(grip - c.dir * 80.0, MOUSE_BUTTON_RIGHT, false)
	await _frames(2)
	_check(not c.seg_alive(1) and c.seg_alive(0),
		"рогатка сорвала участок под курсором (1 — %s, 0 — %s)" % [c.seg_alive(1), c.seg_alive(0)])
	_check(int(w.stats.get("sling_releases", 0)) == 1,
		"срыв рогаткой посчитан (%d)" % int(w.stats.get("sling_releases", 0)))
	# Таб над живым участком 0
	await _move(c.seg_center(0))
	await _key(KEY_TAB, true)
	await _key(KEY_TAB, false)
	await _frames(1)
	_check(not c.seg_alive(0), "Таб стёр участок под курсором")


# ── 5) PvP: Ку и «Сбор» ─────────────────────────────────────────────────────

func _test_cast() -> void:
	print("— PvP: Ку в чужого бойца, «Сбор»")
	await _duel()
	var spot := w.cauldron_of(1) + Vector2(-140.0, 0.0)
	var enemy := w.spawn_unit(LegionCfg.KIND_LABORER, spot, null, 1)
	await _frames(1)
	spot = enemy.position
	var hp0 := enemy.hp
	await _move(Vector2(200, 200))
	await _key(KEY_Q, true)
	await _move(spot)
	await _key(KEY_Q, false)
	await _frames(1)
	var at: Vector2 = w.hero.last_cast.get("at", Vector2.INF)
	_check(_near(at, spot, 2.0), "Ку — в точку мира под курсором: %s (боец %s)" % [at, spot])
	_check(enemy.hp < hp0 or not enemy.alive, "чужой боец задет: %.1f → %.1f" % [hp0, enemy.hp])
	# «Сбор» без маны — кольцо отказа ровно в точке курсора
	f.mana = 0.0
	var rally_at := LAB + Vector2(40, 300)
	await _move(rally_at)
	await _key(KEY_R, true)
	await _key(KEY_R, false)
	var last: Dictionary = w._rallies[w._rallies.size() - 1] if not w._rallies.is_empty() else {}
	_check(not last.is_empty() and _near(last["pos"], rally_at),
		"«Сбор» — в точку мира под курсором: %s (ждали %s)" % [last.get("pos"), rally_at])


# ── 6) PvP: площадка ────────────────────────────────────────────────────────

func _test_plot() -> void:
	print("— PvP: площадка щелчком")
	await _duel()
	w.souls = 99999
	var plot: Dictionary = {}
	for p: Dictionary in w.staff.plots:
		if String(p.get("id", "")) == "s0_a":
			plot = p
	_check(not plot.is_empty(), "площадка s0_a есть")
	if plot.is_empty():
		return
	var pos: Vector2 = plot["pos"]
	await _move(pos)
	await _button(pos, MOUSE_BUTTON_LEFT, true)
	await _button(pos, MOUSE_BUTTON_LEFT, false)
	await _frames(1)
	var menu := w.plot_menu
	_check(menu.is_open() and menu.plot == plot, "щелчок открыл меню своей площадки")
	if not menu.is_open():
		return
	var panel: Rect2 = menu._panel.get_global_rect()
	var anchor := _view(pos)
	_check(absf(panel.position.x - (anchor.x + PlotMenu.MARGIN * 2.0)) < 1.0
		and panel.position.x < SCREEN.x,
		"карточка у площадки на экране: x %.0f (площадка на экране %.0f)" % [panel.position.x,
			anchor.x])
	var btn: Button = null
	for b in menu.buttons():
		if not b.disabled:
			btn = b
			break
	_check(btn != null, "есть доступная кнопка постройки")
	if btn == null:
		return
	await _click_screen(btn.get_global_rect().get_center())
	await _frames(2)
	_check(plot["building"] != null, "кнопка по щелчку построила постройку")


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	await _test_single()
	await _test_camera()
	await _test_stroke()
	await _test_sling_tab()
	await _test_cast()
	await _test_plot()
	# одиночка после PvP в том же мире (LegionMain держит мир один на сеанс) — снова ×1
	await _single()
	await _move(Vector2(640, 360))
	_check(is_equal_approx(_cam_zoom(), 1.0) and _near(w.aim_pos(), Vector2(640, 360), 0.01),
		"одиночка после «Схватки»: камера ×1, мышь = мир")
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION PVP CAMERA: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
