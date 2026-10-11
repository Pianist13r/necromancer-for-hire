extends SceneTree
##
## B-448: режим левши (ЛКМ↔ПКМ в бою) и инверсия колеса — НАСТОЯЩИМИ событиями
## (Input.parse_input_event в координатах окна, путь мыши ОС → _unhandled_input поля).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_mouse_rebind_1010_test.gd -- --mute
##
##  а) по умолчанию: ЛКМ чертит договор, ПКМ — рогатка (захват участка), ПКМ-штрих не чертит;
##  б) левша: ПКМ чертит, ЛКМ — рогатка и срыв, ПКМ во время захвата — отмена, ЛКМ-штрих не
##     чертит; классика у левши — щелчок ЛКМ распускает;
##  в) меню участка открывается кнопкой пера (ЛКМ / у левши ПКМ), другой — нет;
##  г) колесо: вниз — следующий вид, при инверсии — предыдущий; зажатое колесо — прицел, как было;
##  д) тексты: {mouse:draw|sling} и проза «ЛКМ»/«ПКМ» называют актуальную кнопку (один проход),
##     смена режима поднимает Controls.revision; значок мыши урока — та же кнопка; голос урока,
##     называющий кнопку мыши (LessonsCfg.VOICE_MOUSE), у левши молчит, прочие реплики — нет;
##  е) хранение: свой файл настроек (Settings.path) пишет и читает раздел controls; дефолт —
##     выключено; с настоящим путём агентный прогон пишет только в память; экран настроек —
##     галочки «Режим левши» и «Колесо», подпись рогатки называет кнопку заново.
## Итог «LEGION MOUSE REBIND 1010: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_mouse_rebind_1010_test.cfg"
const SETTINGS := "user://legion_mouse_rebind_1010_settings.cfg"
const WORLD := Vector2(1280.0, 720.0)

var w: LegionWorld
var f: ContractField
var _fails := 0
var _checks := 0
var _settings_existed := false
var _settings_mtime := 0


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
	_settings_existed = FileAccess.file_exists(Settings.PATH)
	if _settings_existed:
		_settings_mtime = FileAccess.get_modified_time(Settings.PATH)
	_drop_settings()
	Settings.path = SETTINGS
	Settings._cfg = null
	Settings.lefty_override = ""
	Settings.wheel_invert_override = ""
	Input.use_accumulated_input = false
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	root.size = Vector2i(WORLD)
	await process_frame
	f = w.contracts
	_check(not Settings.is_left_handed() and not Settings.is_wheel_inverted(),
		"дефолт: режим левши и инверсия колеса выключены")
	await _test_default()
	await _test_lefty()
	await _test_plot_menu()
	await _test_wheel()
	_test_texts()
	await _test_storage()
	Settings.set_left_handed(false)
	Settings.set_wheel_inverted(false)
	Settings.scheme_override = ""
	Settings.path = Settings.PATH
	Settings._cfg = null
	Settings.lefty_override = ""
	Settings.wheel_invert_override = ""
	_check(FileAccess.file_exists(Settings.PATH) == _settings_existed
		and (not _settings_existed or FileAccess.get_modified_time(Settings.PATH) == _settings_mtime),
		"user://settings.cfg не тронут (был: %s)" % _settings_existed)
	_drop_settings()
	Campaign.reset()
	print("LEGION MOUSE REBIND 1010: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Свой файл настроек и его копию: SafeConfig поднимает .bak, если основного нет, — оборванный
## прошлый прогон иначе оставил бы «левшу» включённым.
func _drop_settings() -> void:
	for p: String in [SETTINGS, SETTINGS + ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# ── Настоящий ввод ──────────────────────────────────────────────────────────

func _win(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2, mask: int = 0) -> void:
	var m := InputEventMouseMotion.new()
	m.position = _win(p)
	m.global_position = m.position
	m.button_mask = mask
	Input.parse_input_event(m)
	await process_frame


func _btn(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var b := InputEventMouseButton.new()
	b.position = _win(p)
	b.global_position = b.position
	b.button_index = button
	b.pressed = pressed
	Input.parse_input_event(b)
	await process_frame


func _mask(button: MouseButton) -> int:
	return MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT


## Штрих физической кнопкой button от a до b шагами по 10 px.
func _stroke(a: Vector2, b: Vector2, button: MouseButton) -> void:
	await _move(a)
	await _btn(a, button, true)
	var n := maxi(2, ceili(a.distance_to(b) / 10.0))
	for i in range(1, n + 1):
		await _move(a.lerp(b, float(i) / n), _mask(button))
	await _btn(b, button, false)


func _click(p: Vector2, button: MouseButton) -> void:
	await _move(p)
	await _btn(p, button, true)
	await _btn(p, button, false)


func _esc() -> void:
	for pressed: bool in [true, false]:
		var k := InputEventKey.new()
		k.keycode = KEY_ESCAPE
		k.physical_keycode = KEY_ESCAPE
		k.pressed = pressed
		Input.parse_input_event(k)
		await process_frame


# ── Мир ──────────────────────────────────────────────────────────────────────

## Чистое поле: плоская земля без скал, полная мана, без волн и бойцов, все виды открыты.
func _fresh(scheme: String = Settings.SCHEME_SLING) -> void:
	Settings.scheme_override = scheme
	if w.paused:
		w.set_paused(false)
	w.plot_menu.close()
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	f.active = true
	f.human_input = true
	f.mana = f.mana_max
	f.unlocked = {}
	f.set_kind(LegionCfg.KIND_LABORER)


## Горизонтальный договор с бойцами на постах; стрелка вверх.
func _manned_line(y: float) -> Contract:
	var pts := PackedVector2Array()
	var x := 440.0
	while x < 760.0:
		pts.append(Vector2(x, y))
		x += LegionCfg.POINT_STEP
	pts.append(Vector2(760.0, y))
	var c := f.add_contract(pts, 1, false, LegionCfg.KIND_LABORER)
	c.set_dir(Vector2.UP)
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
	return c


# ── а) дефолт ────────────────────────────────────────────────────────────────

func _test_default() -> void:
	print("— а) по умолчанию: ЛКМ — перо, ПКМ — рогатка")
	_fresh()
	await _stroke(Vector2(460, 520), Vector2(760, 520), MOUSE_BUTTON_LEFT)
	_check(f.contracts.size() == 1, "ЛКМ-штрих начертил договор (%d)" % f.contracts.size())
	await _stroke(Vector2(460, 600), Vector2(760, 600), MOUSE_BUTTON_RIGHT)
	_check(f.contracts.size() == 1 and not f.has_draft(),
		"ПКМ-штрих по пустому месту договора не чертит (%d)" % f.contracts.size())
	_fresh()
	var c := _manned_line(300.0)
	var at := c.seg_center(0)
	await _move(at)
	await _btn(at, MOUSE_BUTTON_RIGHT, true)
	_check(not f._grab.is_empty(), "ПКМ по участку — захват рогатки")
	await _esc()
	_check(f._grab.is_empty() and c.seg_alive(0), "Esc отменил захват, участок цел")
	await _btn(at, MOUSE_BUTTON_RIGHT, false)


# ── б) левша ─────────────────────────────────────────────────────────────────

func _test_lefty() -> void:
	print("— б) режим левши: ПКМ — перо, ЛКМ — рогатка")
	Settings.set_left_handed(true)
	_check(Settings.is_left_handed(), "режим левши включён")
	_fresh()
	await _stroke(Vector2(460, 520), Vector2(760, 520), MOUSE_BUTTON_RIGHT)
	_check(f.contracts.size() == 1, "левша: ПКМ-штрих начертил договор (%d)" % f.contracts.size())
	await _stroke(Vector2(460, 600), Vector2(760, 600), MOUSE_BUTTON_LEFT)
	_check(f.contracts.size() == 1 and not f.has_draft(),
		"левша: ЛКМ-штрих по пустому месту договора не чертит (%d)" % f.contracts.size())

	_fresh()
	var c := _manned_line(300.0)
	var at := c.seg_center(0)
	await _move(at)
	await _btn(at, MOUSE_BUTTON_LEFT, true)
	_check(not f._grab.is_empty(), "левша: ЛКМ по участку — захват рогатки")
	# ПКМ (перо у левши) посреди захвата — отмена без выпуска, как ЛКМ у правши
	await _btn(at, MOUSE_BUTTON_RIGHT, true)
	_check(f._grab.is_empty() and c.seg_alive(0), "левша: ПКМ во время захвата — отмена, участок цел")
	await _btn(at, MOUSE_BUTTON_RIGHT, false)
	await _btn(at, MOUSE_BUTTON_LEFT, false)
	_check(c.seg_alive(0), "левша: отпускание ЛКМ после отмены ничего не срывает")

	# натяжка ЛКМ назад (вниз, стрелка вверх) и отпускание — срыв участка
	await _move(at)
	await _btn(at, MOUSE_BUTTON_LEFT, true)
	var pull := at + Vector2(0, LegionCfg.SLING_ARM + 30.0)
	for i in range(1, 9):
		await _move(at.lerp(pull, i / 8.0), MOUSE_BUTTON_MASK_LEFT)
	_check(f.is_slinging(), "левша: оттяжка ЛКМ — натяжка рогатки")
	await _btn(pull, MOUSE_BUTTON_LEFT, false)
	_check(not f.is_slinging() and not c.seg_alive(0), "левша: отпускание ЛКМ сорвало участок")

	_fresh(Settings.SCHEME_CLASSIC)
	var c2 := _manned_line(300.0)
	var at2 := c2.seg_center(1)
	await _move(at2)
	await _btn(at2, MOUSE_BUTTON_LEFT, true)
	_check(not c2.seg_alive(1), "левша, классика: нажатие ЛКМ по участку распускает сразу")
	await _btn(at2, MOUSE_BUTTON_LEFT, false)
	Settings.set_left_handed(false)


# ── в) меню участка ──────────────────────────────────────────────────────────

func _test_plot_menu() -> void:
	print("— в) меню участка — кнопкой пера")
	Settings.scheme_override = Settings.SCHEME_SLING
	for lefty: bool in [false, true]:
		Settings.set_left_handed(lefty)
		w.dev["spawn_units"] = "0"
		w.dev["no_waves"] = "1"
		w.start_map("maze")
		w.set_process(false)
		f = w.contracts
		f.active = true
		f.human_input = true
		var menu := w.plot_menu
		var p: Dictionary = w.staff.plots[4]
		var at := w.world_to_screen(p["pos"])
		var pen := MOUSE_BUTTON_RIGHT if lefty else MOUSE_BUTTON_LEFT
		var other := MOUSE_BUTTON_LEFT if lefty else MOUSE_BUTTON_RIGHT
		menu.close()
		await _click(at, other)
		_check(not menu.is_open(), "%s: щелчок %s по площадке меню не открывает"
			% ["левша" if lefty else "правша", MouseBind.NAMES[other]])
		await _click(at, pen)
		_check(menu.is_open(), "%s: щелчок %s по площадке открыл меню"
			% ["левша" if lefty else "правша", MouseBind.NAMES[pen]])
		# мимо меню той же кнопкой — закрыть (press_consumer поля)
		await _click(Vector2(640, 120), pen)
		_check(not menu.is_open(), "%s: щелчок пером мимо меню закрыл его"
			% ["левша" if lefty else "правша"])
		menu.close()
	Settings.set_left_handed(false)


# ── г) колесо ────────────────────────────────────────────────────────────────

func _tick(at: Vector2, down: bool) -> void:
	var b := MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
	await _btn(at, b, true)
	await _btn(at, b, false)


func _test_wheel() -> void:
	print("— г) колесо: вид договора, инверсия")
	_fresh()
	var at := Vector2(640, 400)
	await _move(at)
	f.choose_kind(LegionCfg.KIND_LABORER)
	await _tick(at, true)
	_check(f.current_kind == LegionCfg.KIND_ORDER[1], "колесо вниз — следующий вид (%s)" % f.current_kind)
	f.choose_kind(LegionCfg.KIND_LABORER)
	Settings.set_wheel_inverted(true)
	await _tick(at, true)
	_check(f.current_kind == LegionCfg.KIND_ORDER[LegionCfg.KIND_ORDER.size() - 1],
		"инверсия: колесо вниз — предыдущий вид (%s)" % f.current_kind)
	f.choose_kind(LegionCfg.KIND_LABORER)
	await _tick(at, false)
	_check(f.current_kind == LegionCfg.KIND_ORDER[1], "инверсия: колесо вверх — следующий вид (%s)" % f.current_kind)
	Settings.set_left_handed(true)
	await _btn(at, MOUSE_BUTTON_MIDDLE, true)
	_check(f._aim_held & ContractField.AIM_WHEEL != 0, "зажатое колесо — прицел и у левши с инверсией")
	await _btn(at, MOUSE_BUTTON_MIDDLE, false)
	_check(f._aim_held & ContractField.AIM_WHEEL == 0, "отпущенное колесо — прицел снят")
	Settings.set_left_handed(false)
	Settings.set_wheel_inverted(false)


# ── д) тексты ────────────────────────────────────────────────────────────────

func _test_texts() -> void:
	print("— д) тексты называют актуальную кнопку")
	var src := "{mouse:draw} — чертить · {mouse:sling} — рогатка"
	var prose := "Круг ЛКМ — «Оцепление»: ПКМ по кольцу срывает его · {key:aim_contract}"
	_check(Controls.text(src) == "ЛКМ — чертить · ПКМ — рогатка", "токены по умолчанию: %s" % Controls.text(src))
	var plain := Controls.text(prose)
	_check(plain == prose.replace("{key:aim_contract}", "Пробел"), "проза по умолчанию как написана: %s" % plain)
	var rev := Controls.revision
	Settings.set_left_handed(true)
	_check(Controls.revision > rev, "смена режима поднимает Controls.revision (плашка пересчитается)")
	_check(Controls.text(src) == "ПКМ — чертить · ЛКМ — рогатка", "левша, токены: %s" % Controls.text(src))
	var swapped := Controls.text(prose)
	_check(swapped == "Круг ПКМ — «Оцепление»: ЛКМ по кольцу срывает его · Пробел",
		"левша, проза ЛКМ↔ПКМ одним проходом: %s" % swapped)
	_check(Controls.text("{mouse:nope} ЛКМов") == "{mouse:nope} ЛКМов", "чужой токен и часть слова не трогаются")
	_check(MouseBind.physical(&"sling") == MOUSE_BUTTON_LEFT and MouseBind.physical(&"draw") == MOUSE_BUTTON_RIGHT,
		"левша: значок мыши урока горит ЛКМ у рогатки, ПКМ у пера")
	var gold := Controls.text(IntuitCfg.HINT_GOLD)
	_check(gold.contains("ЛКМ") and not gold.contains("ПКМ"), "совет «золото» у левши — ЛКМ: %s" % gold)
	Settings.set_left_handed(false)
	_check(Controls.text(src) == "ЛКМ — чертить · ПКМ — рогатка", "выключили — снова как было")
	_test_voice()


## Озвучка, называющая кнопку мыши, у левши молчит (voice_muted), прочие реплики — нет.
func _test_voice() -> void:
	print("— д) голос с кнопкой мыши у левши молчит")
	var others: Array[StringName] = [&"lg_tut_3", &"lg_tut_guard", &"lg_tut_perfect_b", &"lg_tut_eight"]
	var spoken := true
	for v: StringName in LessonsCfg.VOICE_MOUSE:
		spoken = spoken and not LegionTutorial.voice_muted(v)
	_check(spoken, "без левши реплики с кнопкой мыши звучат")
	Settings.set_left_handed(true)
	var muted := true
	for v: StringName in LessonsCfg.VOICE_MOUSE:
		muted = muted and LegionTutorial.voice_muted(v)
	_check(LessonsCfg.VOICE_MOUSE.size() == 6 and muted,
		"левша: %d реплик с кнопкой мыши молчат" % LessonsCfg.VOICE_MOUSE.size())
	var others_ok := true
	for v: StringName in others:
		others_ok = others_ok and not LegionTutorial.voice_muted(v)
	_check(others_ok, "левша: реплики без кнопки мыши звучат (%s)" % ", ".join(others))
	Settings.set_left_handed(false)
	# линтер: каждая реплика урока, называющая кнопку мыши, — в VOICE_MOUSE
	var tsv := ProjectSettings.globalize_path("res://").path_join("../tools/voice/lines.tsv")
	var text := FileAccess.get_file_as_string(tsv)
	var missing := PackedStringArray()
	for line in text.split("\n"):
		var cols := line.split("\t")
		if cols.size() < 3 or not cols[0].begins_with("lg_tut_"):
			continue
		var low := cols[2].to_lower()
		if (low.contains(" кнопк") or low.contains("лкм") or low.contains("пкм")) \
				and not LessonsCfg.VOICE_MOUSE.has(StringName(cols[0])):
			missing.append(cols[0])
	_check(text != "" and missing.is_empty(),
		"lines.tsv: все реплики уроков с кнопкой мыши в VOICE_MOUSE (не хватает: %s)" % ", ".join(missing))


# ── е) хранение и экран настроек ─────────────────────────────────────────────

func _test_storage() -> void:
	print("— е) хранение и экран настроек")
	Settings.set_left_handed(true)
	Settings.set_wheel_inverted(true)
	var cfg := ConfigFile.new()
	_check(cfg.load(SETTINGS) == OK and bool(cfg.get_value("controls", "left_handed", false))
		and bool(cfg.get_value("controls", "wheel_invert", false)),
		"свой файл настроек: controls/left_handed и wheel_invert записаны")
	Settings._cfg = null
	_check(Settings.is_left_handed() and Settings.is_wheel_inverted(), "перечитано из файла — включено")
	Settings.set_left_handed(false)
	Settings.set_wheel_inverted(false)

	# экран настроек: галочки и подпись рогатки
	var screen := SettingsScreen.new()
	root.add_child(screen)
	await process_frame
	var lefty := screen.find_child("LeftHanded", true, false) as CheckBox
	var wheel := screen.find_child("WheelInvert", true, false) as CheckBox
	var sling := screen.find_child("SlingScheme", true, false) as CheckBox
	_check(lefty != null and wheel != null and sling != null, "экран: галочки «Режим левши», «Колесо», рогатка")
	if lefty != null and wheel != null and sling != null:
		_check(not lefty.button_pressed and not wheel.button_pressed and sling.text.contains("ПКМ"),
			"экран: по умолчанию сняты, рогатка — «%s»" % sling.text)
		lefty.button_pressed = true
		wheel.button_pressed = true
		_check(Settings.is_left_handed() and Settings.is_wheel_inverted(), "экран: галочки включили режимы")
		_check(sling.text.contains("ЛКМ") and not sling.tooltip_text.contains("ПКМ"),
			"экран: подпись рогатки назвала ЛКМ — «%s»" % sling.text)
		lefty.button_pressed = false
		wheel.button_pressed = false
		_check(not Settings.is_left_handed() and sling.text.contains("ПКМ"), "экран: снятая галочка вернула ПКМ")
	screen.queue_free()
	await process_frame

	# настоящий путь в агентном прогоне (--mute) — только память, файл владельца не пишется
	Settings.path = Settings.PATH
	Settings._cfg = null
	Settings.set_left_handed(true)
	_check(Settings.is_left_handed() and Settings.lefty_override == "on",
		"агентный прогон с настоящим путём: режим левши только в памяти")
	Settings.set_left_handed(false)
	Settings.set_wheel_inverted(true)
	_check(Settings.wheel_invert_override == "on", "агентный прогон: инверсия колеса только в памяти")
