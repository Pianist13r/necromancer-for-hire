# gdlint: disable=max-file-lines
extends SceneTree
##
## H — проход меню НАСТОЯЩЕЙ мышью в настоящем окне (не headless), два разрешения.
##
## Запуск (из корня дерева; окно обязательно, headless не годится):
##   export APPDATA=C:/AI/necro/batches/int-oct05/appdata-H-1280x720 NECRO_NO_DEV_BRIDGE=1
##   G=C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe
##   "$G" --path godot --fixed-fps 60 --script res://tests/clickwalk_menu.gd -- \
##     --mute --res 1280x720 --dev save=user://clickwalk_1280x720.cfg --dev items=clip_of_fate
## (для 960×540 — --res 960x540 и save=user://clickwalk_960x540.cfg; --res и имя save обязаны
##  сходиться, иначе скрипт отказывается стартовать, чтобы не тронуть сохранение владельца).
##
## Почему так, а не проще:
##  * клики — НЕ button.pressed.emit(): Input.parse_input_event (InputEventMouseMotion + Button
##    pressed/released) в центр ФАКТИЧЕСКОГО get_global_rect() кнопки, найденной по тексту.
##    Координаты сценария — логические (1280×720); в координаты окна их переводит
##    get_final_transform() корневого вьюпорта (растяжение canvas_items) — как в
##    scripts/dev/legion_tutorial_driver.gd. Без этой поправки окно 960×540 получило бы клики
##    мимо: логический холст тот же, а окно меньше.
##  * кадр после каждого шага — get_texture().get_image().save_png в <out>/<NN>_<шаг>.png;
##    строка в steps.tsv: шаг, кнопка, rect, ожидание, факт, paused, слои боя, вердикт, примечание.
##  * «ожидание» — не украшение: не сошлось — FAIL в steps.tsv и в итоге прогона.
##  * save — только свой (user://clickwalk_<res>.cfg); прогон не имеет права читать или писать
##    legion.cfg владельца (--dev save у LegionMain проходит ту же проверку).
##  * ожидание шага ограничено двумя счётчиками сразу — дельтой кадра (секунды игрового времени)
##    и числом кадров (при --fixed-fps 60 кадр = 1/60 с): движок забирает --fixed-fps себе, в
##    OS.get_cmdline_args() его не видно (проверено), а зависнуть шаг не должен в любом режиме.
##  * клик, не давший ожидаемого, повторяется ОДИН раз, и обе попытки видны в примечании. Так
##    одиночный пропуск (у кнопки паузы HUD есть штатный запрет вне BATTLE) не выглядит FAIL'ом,
##    но и не прячется: вердикт ставится по последней попытке.
##
## Победа и поражение: dev-ключа на мгновенный исход у мира НЕТ (проверено по
## LegionWorld.parse_args — есть invuln/items/spawn_*/no_waves/..., исхода нет). Исход задаётся
## штатным рантайм-путём LegionWorld.force_end() — тем же, которым пользуются тесты: бой настоящий,
## итог, награда и переходы идут обычным путём (match_ended → _on_match_ended → Campaign).
##
## Третья активная поправка (маршрут 5) дописывается API Campaign в свой save — задание H это
## разрешает явно; маршрут 3 начинает «новую кампанию» сбросом прогресса своего save (то же, что
## кнопка «Стереть» в настройках) — иначе вступление уже показано и шаг с катсценой выпал бы.

const OUT_ROOT := "C:/AI/necro/batches/int-oct05/clicks"
const DEVICE := 8
## Сколько игровых секунд ждать ожидаемую картину, прежде чем записать FAIL.
const WAIT_SCREEN := 8.0
const TSV_HEADER := "step\tbutton\trect\texpected\tactual\tpaused\tlayers\tverdict\tnote"
## Оверлеи main, по которым проверяется ожидание overlay=<Class>.
const OVERLAY_CLASSES := ["SettingsScreen", "HowtoLegion", "LegionPause", "LegionItemDossier"]
## Аудит вёрстки (§5): классы-«предметы» — то, что действительно рисует (кнопка, надпись,
## иконка, панель). Чистые контейнеры (VBox/Grid/Margin/Center/Control) держат раскладку, но
## ничего не рисуют — в парах они только мешают, поэтому предметом не считаются.
const AUDIT_SUBJECTS := ["Button", "Label", "RichTextLabel", "TextureRect", "Panel",
	"PanelContainer", "ProgressBar"]
## Пересечение короче этого по любой оси — касание рамками, а не наложение.
const AUDIT_MIN_OVERLAP := 4.0
## Модальные оверлеи боя: перекрывают экран по замыслу и держат ввод. Их пары с боевым
## интерфейсом — не находка; всё остальное в бою сравнивается МЕЖДУ слоями (HUD 5, уроки и
## способности 6, досье 20) — аудит K считал пары только внутри одного слоя.
const MODAL_CLASSES := OVERLAY_CLASSES + ["PlotMenu"]
## Кромка вьюпорта: полноэкранная картинка катсцены встаёт на −0,4 px от дробей центрирования —
## это не «за экраном».
const AUDIT_VIEW_TOLERANCE := 1.0


## Глушит настоящую мышь и клавиатуру владельца на время прогона: событие с чужим device не должно
## попасть в игру и сбить шаг (так же делает водитель обучения). Наши события — device 8.
class InputMute extends Node:
	const MINE := 8

	func _input(event: InputEvent) -> void:
		if event is InputEventMouseButton or event is InputEventMouseMotion or event is InputEventKey:
			if event.device != MINE:
				get_viewport().set_input_as_handled()


var main: LegionMain
var _res_name := ""
var _res_size := Vector2i.ZERO
var _out_dir := ""
var _steps := 0
var _step_fails := 0
var _fails: Array[String] = []
var _tsv: FileAccess
var _offered_before: Array[StringName] = []
var _audit_seen: Dictionary = {}
var _last_win := Vector2.ZERO
var _hover_txt := ""
var _post_txt := ""
var _delta_n := 0
var _delta_sum := 0.0
var _delta_min := 0.0
var _delta_max := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_res_name = _arg(args, "--res")
	if _res_name == "":
		push_error("нужен аргумент --res <ШxВ> (например 1280x720)")
		quit(2)
		return
	var parts := _res_name.split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		push_error("--res ожидает ШxВ цифрами, получено: " + _res_name)
		quit(2)
		return
	_res_size = Vector2i(int(parts[0]), int(parts[1]))
	# Свой save обязателен и должен совпасть с ожидаемым именем: без этой проверки прогон пошёл бы
	# в настоящее сохранение владельца (LegionMain читает тот же --dev save).
	var want := "user://clickwalk_%s.cfg" % _res_name
	if _dev_arg(args, "save") != want:
		push_error("нужен --dev save=%s (получено «%s»)" % [want, _dev_arg(args, "save")])
		quit(2)
		return
	_out_dir = OUT_ROOT.path_join(_res_name)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_tsv = FileAccess.open(_out_dir.path_join("steps.tsv"), FileAccess.WRITE)
	if _tsv == null:
		push_error("не открыть " + _out_dir.path_join("steps.tsv"))
		quit(2)
		return
	_tsv.store_line(TSV_HEADER)
	# Файлы находок пишутся дописыванием — прошлый прогон надо обнулить, иначе находки копятся.
	for file_name in ["ui_audit.tsv", "ui_scroll.tsv"]:
		var fresh := FileAccess.open(_out_dir.path_join(file_name), FileAccess.WRITE)
		if fresh != null:
			fresh.close()
	DisplayServer.window_set_size(_res_size)
	await _frames(2)
	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	root.add_child(main)
	root.add_child(InputMute.new())   # настоящий ввод владельца не должен мешать шагам
	await _frames(6)
	# Settings.apply() в LegionMain._ready мог поставить своё окно — свой размер ставим ПОСЛЕ него.
	DisplayServer.window_set_size(_res_size)
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	await _frames(3)
	_write_meta()

	await _phase_a_maps()
	await _phase_b_overlays()
	await _phase_c_pause()
	await _phase_d_victory()
	await _phase_e_replacement()
	await _phase_f_dossier()
	await _phase_g_defeat()
	await _phase_h_meta_screens()
	await _phase_i_endless()
	await _phase_j_pvp()
	await _phase_k_battle_maps()

	_finish()


# ── Маршрут 1: меню → карты → карточка → брифинг → назад ─────────────────────────────────────

func _phase_a_maps() -> void:
	await _click_text("A1_maps", ["Карты"], "screen=MapSelect")
	var first_map := String(Campaign.maps()[0].get("id", ""))
	var title := String(Campaign.map(first_map).get("title", first_map))
	# Вступление кампании играет ПЕРЕД первым брифингом (legion_main.show_briefing), а не после
	# «В бой»; в задании H оно названо в шаге 3 — фактический порядок виден в примечании.
	var cut := not Campaign.intro_cutscene_seen()
	await _click_text("A2_map_card", [title], "screen=LegionCutscene" if cut else "screen=Briefing")
	if cut:
		await _click_text("A3_cutscene_skip", ["Пропустить ▸▸"], "screen=Briefing")
	await _click_nav_back("A4_briefing_back", "screen=MapSelect")
	await _click_nav_back("A5_maps_back", "screen=LegionMenu")


# ── Маршрут 2: «Как играть» и «Настройки» из меню ────────────────────────────────────────────

func _phase_b_overlays() -> void:
	await _click_text("B1_howto", ["Как играть"], "screen=LegionMenu,overlay=HowtoLegion")
	await _click_in("B2_howto_back", ["← Назад"], HowtoLegion, "screen=LegionMenu,overlay=none")
	await _click_text("B3_settings", ["Настройки"], "screen=LegionMenu,overlay=SettingsScreen")
	await _click_in("B4_settings_back", ["← Назад"], SettingsScreen, "screen=LegionMenu,overlay=none",
		"", func() -> String: return "фокус после закрытия: " + _focus_name())


# ── Маршрут 3: новая кампания → бой → пауза и оверлеи ────────────────────────────────────────

func _phase_c_pause() -> void:
	main.reset_progress()          # ровно то же, что делает кнопка «Стереть» в настройках
	Campaign.set_tutorial_done()   # маршрут H обучение не проверяет (оно — маршрут B)
	await _frames(4)
	await _api_step("C0_new_campaign", "screen=LegionMenu",
		"новая кампания своего save: сброс прогресса")
	await _click_cta("C1_start_campaign", "screen=LegionCutscene")
	await _click_text("C2_cutscene_skip", ["Пропустить ▸▸"], "screen=Briefing")
	await _click_text("C3_to_battle", ["В бой"], "screen=none,hud=1,paused=0")
	await _click_text("C4_pause", ["❚❚ Пауза"], "paused=1,overlay=LegionPause")
	await _click_in("C5_pause_settings", ["Настройки"], LegionPause, "paused=1,overlay=SettingsScreen")
	await _click_in("C6_settings_back", ["← Назад"], SettingsScreen, "paused=1,overlay=LegionPause")
	await _click_in("C7_pause_howto", ["Как играть"], LegionPause, "paused=1,overlay=HowtoLegion")
	await _click_in("C8_howto_back", ["← Назад"], HowtoLegion, "paused=1,overlay=LegionPause")
	await _click_in("C9_resume", ["Продолжить"], LegionPause,
		"screen=none,hud=1,paused=0,overlay=none")
	await _click_text("C10_pause_again", ["❚❚ Пауза"], "paused=1,overlay=LegionPause")
	await _click_in("C11_menu_click", ["В главное меню"], LegionPause, "paused=1,dialog=Confirm")
	await _click_text("C12_confirm_cancel", ["Отмена"], "paused=1,overlay=LegionPause,dialog=none")
	await _click_in("C13_menu_click2", ["В главное меню"], LegionPause, "paused=1,dialog=Confirm")
	await _click_text("C14_confirm_ok", ["Подтвердить", "Да"],
		"screen=LegionMenu,paused=0,dialog=none")


# ── Маршрут 4: победа → итог → поправка → выход в меню → те же варианты → брифинг ─────────────

func _phase_d_victory() -> void:
	await _click_cta("D1_to_briefing", "screen=Briefing")
	await _click_text("D2_to_battle", ["В бой"], "screen=none,hud=1")
	await _force_end("D3_force_win", true)
	await _click_text("D4_result_next", ["Дальше: выбор поправки"], "screen=UpgradePicker")
	_offered_before = _picker_options()
	await _click_text("D5_picker_menu", ["В главное меню"], "screen=LegionMenu",
		"предложено: " + _ids(_offered_before), false,
		func() -> String: return "награда не забрана: pending=" + Campaign.pending_reward())
	await _click_cta("D6_continue", "screen=UpgradePicker")
	_check_same_options(_picker_options())
	await _click_amendment("D7_pick_card", _first(_offered_before), "screen=Briefing")
	await _click_text("D8_office", ["Контора ("], "screen=OfficeShop", "", true)
	await _click_nav_back("D9_office_back", "screen=Briefing")
	await _click_text("D10_to_battle", ["В бой"], "screen=none,hud=1")


# ── Маршрут 5: замена поправки на четвёртой ──────────────────────────────────────────────────

func _phase_e_replacement() -> void:
	await _force_end("E1_force_win", true)
	# Доведение до трёх активных: две поправки дописываем API в свой save ДО четвёртого выбора
	# (первую дал выбор в D7). Задание H разрешает это прямо.
	var seeded: Array[StringName] = []
	for raw in AmendmentDb.ORDER:
		if seeded.size() >= 2:
			break
		var sid := StringName(String(raw))
		if RunProgression.available(sid) and not Campaign.upgrades().has(sid):
			Campaign.add_upgrade(sid)
			seeded.append(sid)
	await _api_step("E2_seed_three", "screen=LegionResult",
		"активных стало %d (добавлены %s)" % [Campaign.upgrades().size(), _ids(seeded)])
	var was := Campaign.upgrades()
	await _click_text("E3_result_next", ["Дальше: выбор поправки"], "screen=UpgradePicker")
	var offered := _picker_options()
	await _click_amendment("E4_pick_card", _first(offered), "screen=UpgradePicker",
		"режим замены: активных %d" % Campaign.upgrades().size())
	await _click_text("E5_replace_slot", ["Вычеркнуть этот пункт"], "screen=Briefing")
	_check_replacement(was, offered)


# ── Маршрут 6: досье артефактов из паузы ─────────────────────────────────────────────────────

func _phase_f_dossier() -> void:
	await _click_text("F1_to_battle", ["В бой"], "screen=none,hud=1")
	await _click_text("F2_pause", ["❚❚ Пауза"], "paused=1,overlay=LegionPause")
	await _click_in("F3_dossier", ["Досье артефактов"], LegionPause, "overlay=LegionItemDossier")
	await _click_in("F4_dossier_back", ["← Назад"], LegionItemDossier, "paused=1,overlay=LegionPause")
	await _click_in("F5_resume", ["Продолжить"], LegionPause, "screen=none,hud=1,paused=0")


# ── Маршрут 7: поражение → «Ещё раз» → пауза → меню ─────────────────────────────────────────

func _phase_g_defeat() -> void:
	await _force_end("G1_force_lose", false)
	await _click_text("G2_retry", ["Ещё раз"], "screen=none,hud=1")
	await _click_text("G3_pause", ["❚❚ Пауза"], "paused=1,overlay=LegionPause")
	await _click_in("G4_menu", ["В главное меню"], LegionPause, "paused=1,dialog=Confirm")
	await _click_text("G5_confirm", ["Подтвердить", "Да"], "screen=LegionMenu,paused=0")


# ── Маршрут 8: экраны меты, которых маршрут H не касался ─────────────────────────────────────

func _phase_h_meta_screens() -> void:
	await _click_text("H1_hero", ["Герой"], "screen=HeroScreen")
	await _click_nav_back("H2_hero_back", "screen=LegionMenu")
	await _click_text("H3_office_card", ["Контора"], "screen=OfficeShop")
	await _click_in("H4_office_hero", ["Досье некроманта"], OfficeShop, "screen=HeroScreen")
	await _click_nav_back("H5_hero_back2", "screen=OfficeShop")
	await _click_nav_back("H6_office_back", "screen=LegionMenu")
	# Коллекция: кладём в неё запись сами (маршрут её не собирал) — кнопка меню появляется
	# только у непустой коллекции (legion_menu.gd CollectionAction), и только при СБОРКЕ меню,
	# поэтому меню перестраиваем: show_menu() создаёт экран заново.
	LegionCollection.save({"map_id": String(Campaign.maps()[0].get("id", "")),
		"title": "Проход меню"})
	main.show_menu()
	await _frames(4)
	await _click_named("H7_collection", "CollectionAction", "screen=LegionCollectionScreen")
	await _click_nav_back("H8_collection_back", "screen=LegionMenu")


# ── Маршрут 9: забег — брифинг, бой с подсказками, некролог самовольного ухода ────────────────

func _phase_i_endless() -> void:
	await _click_named("I1_endless", "EndlessAction", "screen=EndlessBriefing")
	await _click_text("I2_endless_battle", ["В бой"], "screen=none,hud=1")
	await _battle_hints("I3_endless_hints", "забег")
	# Уход из боя забега — «самовольный уход»: засчитанная попытка и некролог (не меню).
	await _click_text("I4_pause", ["❚❚ Пауза"], "paused=1,overlay=LegionPause")
	await _click_in("I5_menu", ["В главное меню"], LegionPause, "paused=1,dialog=Confirm")
	# Куда именно выводит подтверждённый выход из боя забега (некролог или меню) — пусть скажет
	# примечание: у «забега» и «Вызова дня» это разные ветки, а кадр-аудит снимается здесь же.
	await _click_text("I6_confirm", ["Подтвердить"], "")
	await _api_step("I7_after_leave", "", "выход из боя забега")
	main.show_menu()
	await _frames(4)
	await _api_step("I8_menu", "screen=LegionMenu", "снова меню")


# ── Маршрут 10: «Схватка» — выбор поля, лобби, бой и итог ────────────────────────────────────

func _phase_j_pvp() -> void:
	await _click_named("J1_pvp", "PvpAction", "screen=PvpFieldSelect")
	await _click_text("J2_pvp_net", ["По сети"], "screen=NetLobby")
	await _click_nav_back("J3_lobby_back", "")
	await _api_step("J4_after_lobby", "", "лобби закрыто")
	main.show_menu()
	await _frames(4)
	await _click_named("J5_pvp_again", "PvpAction", "screen=PvpFieldSelect",
		"повторный вход в «Схватку» из меню")
	await _click_in("J6_pvp_duel", ["Дуэль"], PvpFieldSelect, "screen=none,hud=1")
	# Итог «Схватки» — не экран, а свой слой HUD (PvpResult), поэтому ожидания экрана нет:
	# что именно встало поверх — скажет столбец фактического состояния и кадр-аудит.
	if main.world != null:
		main.world.force_end(true)
		await _frames(30)
	await _api_step("J7_pvp_result", "", "итог «Схватки» поверх боя")
	main.show_menu()
	await _frames(4)
	await _api_step("J8_menu", "screen=LegionMenu", "после «Схватки» вернулись в меню")


# ── Маршрут 11: бой двух карт кампании с уроками (Пустырь и Мост) ────────────────────────────

func _phase_k_battle_maps() -> void:
	for map_id: String in ["wasteland", "bridge"]:
		main.start_battle(map_id)
		await _frames(10)
		await _api_step("K1_%s" % map_id, "screen=none,hud=1", "бой кампании на «%s»" % map_id)
		await _battle_hints("K2_%s" % map_id, map_id)


## Подсказки боя, которые просит аудит (задание K п.5): плашка урока карты, всплывающая подсказка
## предмета и меню площадки — всё это на экране в момент кадра-аудита. Мышь остаётся на слоте
## артефакта, поэтому подсказка предмета попадает и в кадр, и в аудит.
func _battle_hints(id: String, where: String) -> void:
	var w := main.world
	if w == null:
		await _record(id, "—", Rect2(), "screen=none,hud=1", "мира нет", "")
		return
	w.start_lessons(true)          # уроки карты поверх идущего боя, даже уже пройденные
	# Активное комбо (L): счётчик комбо — свой CanvasItem на слое HUD, и аудит обязан видеть его
	# вместе с уроком и подсказкой предмета, а не по отдельности.
	w.call("_set_combo", 4)
	w.set("_combo_hit_t", float(w.now))   # иначе окно комбо истечёт на первом же шаге мира
	await _frames(10)
	var note := "уроки «%s» открыты; комбо ×4" % where
	var bar := w.hud.find_child("ItemBar", true, false) as Control
	if bar != null and int(bar.call("slot_count")) > 0:
		await _move((bar.call("slot_rect", 0) as Rect2).get_center())
		note += "; мышь на слоте предмета (подсказка %d)" % int(bar.call("hovered_slot"))
	else:
		note += "; полоска артефактов пуста"
	await _api_step(id, "screen=none,hud=1", note)
	if w.staff != null and not w.staff.plots.is_empty():
		var plot: Dictionary = w.staff.plots[0]
		w.plot_menu.open(plot, plot["pos"])
		await _frames(4)
		await _api_step(id + "_plot", "screen=none,hud=1", "меню площадки открыто")


# ── Шаги ─────────────────────────────────────────────────────────────────────────────────────

## Клик по кнопке, найденной ПО ТЕКСТУ (кнопка или надпись внутри карточки-кнопки).
## after — необязательный расчёт ПРИМЕЧАНИЯ уже после клика (фокус, состояние награды).
func _click_text(id: String, texts: Array, expect: String, note := "", prefix := false,
		after := Callable()) -> void:
	var btn := _find_button(main, texts, prefix)
	if btn == null:
		await _record(id, "(%s)" % " | ".join(texts), Rect2(), expect,
			"кнопка не найдена: " + " | ".join(texts), note)
		return
	await _click_control(id, btn, expect, note, after)


## Клик по кнопке внутри конкретного слоя: «← Назад» есть и у паузы, и у открытого поверх неё окна.
func _click_in(id: String, texts: Array, kind: Variant, expect: String, note := "",
		after := Callable()) -> void:
	var host := _find_child_of_type(kind)
	if host == null:
		await _record(id, "(%s)" % " | ".join(texts), Rect2(), expect,
			"слой %s не открыт" % _class_of_kind(kind), note)
		return
	var btn := _find_button(host, texts)
	if btn == null:
		await _record(id, "(%s)" % " | ".join(texts), Rect2(), expect,
			"в слое нет кнопки: " + " | ".join(texts), note)
		return
	await _click_control(id, btn, expect, note, after)


## Общий путь клика: подпись и rect снимаем ДО нажатия (карточка после выбора прячет свои надписи),
## примечание «после» считаем уже после ожидания.
func _click_control(id: String, btn: Button, expect: String, note: String,
		after: Callable) -> void:
	var label := _btn_label(btn)
	var rect := _root_rect(btn)
	var fail := await _click_once(btn, expect)
	var extra := ""
	if fail != "" and is_instance_valid(btn) and btn.is_inside_tree():
		# Не давший ожидаемого клик повторяем РОВНО один раз: у кнопки паузы HUD есть штатный
		# запрет (мир не в BATTLE — нажатие молчит), и одна попытка дала бы ложный FAIL.
		# Обе попытки видны в примечании, вердикт — по последней.
		extra = "первый клик не дал ожидаемого (" + fail + ")"
		fail = await _click_once(btn, expect)
		extra += " — повтор сработал" if fail == "" else "; повтор тоже (" + fail + ")"
	var full := note
	if extra != "":
		full = extra if full == "" else full + "; " + extra
	if after.is_valid():
		var tail := String(after.call())
		if tail != "":
			full = tail if full == "" else full + "; " + tail
	await _record(id, label, rect, expect, fail, full)


## Один клик: нажатие, ожидание, проверка. Возврат — причина провала или "".
func _click_once(btn: Button, expect: String) -> String:
	await _press(btn)
	await _settle(expect)
	return _check(expect)


## Главное действие меню: подпись меняется («Начать смену»/«Продолжить»), поэтому ищем по обеим.
func _click_cta(id: String, expect: String, note := "") -> void:
	await _click_text(id, ["Начать смену", "Продолжить"], expect, note)


## Возврат нижней панели: подпись читаем у NavBack (у карт это «← Назад», а не «В главное меню»).
func _click_nav_back(id: String, expect: String, note := "") -> void:
	var back: Button = null
	if main.screen != null:
		back = main.screen.find_child("NavBack", true, false) as Button
	if back == null:
		await _record(id, "NavBack", Rect2(), expect, "на экране нет нижнего возврата", note)
		return
	await _click_text(id, [back.text], expect, note)


## Клик по кнопке по ИМЕНИ узла: подпись у части кнопок меняется по состоянию («Забег
## (объект 3)» / «Бесконечный», «Коллекция (2)»), а имя стабильно.
func _click_named(id: String, node_name: String, expect: String, note := "") -> void:
	var btn := _find_named(main, node_name)
	if btn == null:
		await _record(id, node_name, Rect2(), expect, "кнопки «%s» нет на экране" % node_name, note)
		return
	await _click_control(id, btn, expect, note, Callable())


func _find_named(from: Node, node_name: String) -> Button:
	if from == null:
		return null
	for n in from.find_children(node_name, "Button", true, false):
		var btn := n as Button
		if btn.is_visible_in_tree() and not btn.disabled:
			return btn
	return null


## Карточка поправки: у неё text пуст, ищем по заголовку внутри.
func _click_amendment(id: String, amend: StringName, expect: String, note := "") -> void:
	if amend == &"":
		await _record(id, "поправка", Rect2(), expect, "пустой список предложенных поправок", note)
		return
	var title := String(AmendmentDb.card(amend).get("title", String(amend)))
	var btn := _find_button(main.screen, [title])
	if btn == null:
		await _record(id, "поправка " + String(amend), Rect2(), expect,
			"карточки «%s» нет на экране" % title, note)
		return
	await _click_control(id, btn, expect, note, Callable())


## Победа/поражение штатным рантайм-путём мира (dev-ключа исхода у проекта нет).
func _force_end(id: String, win: bool) -> void:
	if main.world == null:
		await _record(id, "—", Rect2(), "screen=LegionResult", "мира нет", "")
		return
	main.world.force_end(win)
	await _wait_screen("screen=LegionResult", WAIT_SCREEN)
	await _record(id, "—", Rect2(), "screen=LegionResult", "",
		"LegionWorld.force_end(%s)" % ("true" if win else "false"))


## Шаг без клика (состояние после API-действия) — тоже кадр и строка.
func _api_step(id: String, expect: String, note := "") -> void:
	await _record(id, "—", Rect2(), expect, "", note)


## Кадр, состояние и строка steps.tsv. fail != "" — шаг провален.
func _record(id: String, button: String, rect: Rect2, expect: String, fail: String,
		note := "") -> void:
	_steps += 1
	var shot := "%02d_%s" % [_steps, id]
	await _shot(shot)
	var bad := _check(expect)
	var verdict := "OK" if (bad == "" and fail == "") else "FAIL"
	var why := fail if fail != "" else bad
	if verdict == "FAIL":
		_step_fails += 1
		_fails.append("%s: %s (кадр %s.png)" % [id, why, shot])
	var notes: Array[String] = []
	if note != "":
		notes.append(note)
	if why != "":
		notes.append("причина: " + why)
	notes.append("win=%d,%d" % [int(_last_win.x), int(_last_win.y)])
	if _hover_txt != "":
		notes.append("курсор был на: " + _hover_txt)
	if _post_txt != "":
		notes.append(_post_txt)
	var line := "%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s" % [
		shot, button, _rect_txt(rect), expect, _actual(), int(self.paused), _layers_str(),
		verdict, "; ".join(notes)]
	_tsv.store_line(line)
	_tsv.flush()
	print("CLICKWALK ", line)
	_ui_audit(id)


# ── Мышь как у ОС ────────────────────────────────────────────────────────────────────────────

## Нажать и отпустить ЛКМ в реальном прямоугольнике контрола. Сперва движение: без него кнопка
## не получит hover, и press уйдёт «в пустоту».
##
## Отпускание идёт ТЕМ ЖЕ КАДРОМ, что повторное движение на ту же кнопку. Причина (разбор
## «осечки первого клика», H_report п.3): Button гасит нажатие, если курсор успел уйти с него
## между press и release — NOTIFICATION_MOUSE_EXIT снимает `pressing_inside`, и `pressed` не
## летит, хотя нажатие дошло (button_down/button_up есть). Проверено опытом на живой кнопке:
## press → ход мыши в сторону → release дал pressed=0; press → release одним кадром — 1;
## press → пауза 4 кадра без хода — 1 (задержка не виновата, виноват именно ход); чужое
## устройство глушит InputMute (press → чужой ход → release — 1), а возврат курсора тем же
## кадром, что отпускание, вылечивает потерянный клик (1). Отсюда и «первый клик после смены
## экрана»: клик разнесён на три кадра, и любой ход мыши в это окно его терял.
func _press(control: Control) -> void:
	var at := _root_center(control)
	await _move(at)
	# Что интерфейс видит под курсором ДО нажатия: если это не та кнопка, клик уйдёт мимо —
	# без этой пробы провал неотличим от «кнопка исчезла».
	var h := root.gui_get_hovered_control()
	_hover_txt = "<пусто>" if h == null else "%s:%s" % [_class_of(h), String(h.name)]
	await _button(at, true)
	await _frames(2)
	var back := _root_center(control)   # кнопка могла уехать, курсор — с неё уйти
	if back != at:
		_hover_txt += " → кнопка уехала на %.0f,%.0f" % [back.x - at.x, back.y - at.y]
	_send_motion(back)
	_send_button(back, false)
	await _frames(2)
	# Проба сразу после отпускания: видно, дошло ли нажатие до игры. Кнопка паузы HUD молчит, если
	# мир не в BATTLE (штатный запрет) — тогда «клик мимо» и «нажатие до игры не дошло» различимы.
	if main != null and main.world != null:
		_post_txt = "мир после клика: paused=%d, phase=%d, курсор на %s" % [
			int(main.world.paused), int(main.world.phase), _hover_txt]


func _move(p: Vector2) -> void:
	_send_motion(p)
	await _frames(1)


## Отправка без ожидания кадра — чтобы движение и отпускание ушли в один кадр (см. _press).
func _send_motion(p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.relative = sp - _last_win
	ev.button_mask = 0
	_last_win = sp
	Input.parse_input_event(ev)


func _button(p: Vector2, pressed: bool) -> void:
	_send_button(p, pressed)
	await _frames(1)


func _send_button(p: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(ev)


## Логическая точка → координата окна (растяжение canvas_items), как у водителя обучения.
func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _root_center(c: Control) -> Vector2:
	return _root_rect(c).get_center()


## Прямоугольник контрола в логических координатах. Всплывающие окна (подтверждение) — вложенные
## подокна: их контролы считают rect от своего окна, поэтому прибавляем позицию окна.
func _root_rect(c: Control) -> Rect2:
	var r := c.get_global_rect()
	var vp := c.get_viewport()
	if vp != null and vp != root and vp is Window:
		r.position += Vector2((vp as Window).position)
	return r


# ── Поиск кнопок ─────────────────────────────────────────────────────────────────────────────

## Кнопка по тексту: сравниваем и text кнопки, и НАДПИСИ ВНУТРИ неё (карточки-кнопки рисуют подпись
## дочерним Label, у самой кнопки text пуст). Берём первую видимую и включённую.
func _find_button(from: Node, texts: Array, prefix := false) -> Button:
	if from == null:
		return null
	for node in from.find_children("*", "Button", true, false):
		var btn := node as Button
		if not btn.is_visible_in_tree() or btn.disabled:
			continue
		if _btn_has_text(btn, texts, prefix):
			return btn
	return null


func _btn_has_text(btn: Button, texts: Array, prefix: bool) -> bool:
	if btn.text.strip_edges() != "" and _text_matches(btn.text.strip_edges(), texts, prefix):
		return true
	for l in btn.find_children("*", "Label", true, false):
		var lbl := l as Label
		if lbl.is_visible_in_tree() and _text_matches(lbl.text.strip_edges(), texts, prefix):
			return true
	return false


func _text_matches(got: String, texts: Array, prefix: bool) -> bool:
	for want in texts:
		var w := String(want)
		if (prefix and got.begins_with(w)) or (not prefix and got == w):
			return true
	return false


## Подпись кнопки для отчёта: своя, а если пуста — склейка видимых надписей внутри.
func _btn_label(btn: Button) -> String:
	if btn.text.strip_edges() != "":
		return btn.text.strip_edges()
	var parts: Array[String] = []
	for l in btn.find_children("*", "Label", true, false):
		var lbl := l as Label
		if lbl.is_visible_in_tree() and lbl.text.strip_edges() != "":
			parts.append(lbl.text.strip_edges())
	return " | ".join(parts) if not parts.is_empty() else "<%s>" % String(btn.name)


func _find_child_of_type(kind: Variant) -> Node:
	for c in main.get_children():
		if is_instance_of(c, kind) and not c.is_queued_for_deletion():
			return c
	return null


# ── Состояние ────────────────────────────────────────────────────────────────────────────────

## Проверка ожидания. Токены через запятую: screen=<Class|none>, overlay=<Class|none>,
## paused=0|1, hud=0|1, dialog=Confirm|none. Возврат — причина провала или "".
func _check(expect: String) -> String:
	var bad: Array[String] = []
	for token in expect.split(",", false):
		var kv := token.split("=", true, 1)
		var key := kv[0]
		var val := kv[1] if kv.size() > 1 else ""
		match key:
			"screen":
				var got := _screen_class()
				if val == "none":
					if got != "":
						bad.append("ожидался бой, на экране " + got)
				elif got != val:
					bad.append("экран %s вместо %s" % [got if got != "" else "<бой>", val])
			"overlay":
				var ov := _overlays()
				if val == "none":
					if ov != "":
						bad.append("лишний оверлей " + ov)
				elif not _has_overlay(val):
					bad.append("нет оверлея %s (есть: %s)" % [val, ov if ov != "" else "—"])
			"paused":
				if str(int(self.paused)) != val:
					bad.append("paused=%d вместо %s" % [int(self.paused), val])
			"hud":
				if str(int(_hud_visible())) != val:
					bad.append("HUD видим=%d вместо %s" % [int(_hud_visible()), val])
			"dialog":
				var d := _dialog() != null
				if (val == "Confirm") != d:
					bad.append("подтверждение не открылось" if val == "Confirm"
						else "подтверждение осталось открытым")
	return "; ".join(bad)


func _screen_class() -> String:
	if main == null or main.screen == null:
		return ""
	return _class_of(main.screen)


func _class_of(n: Object) -> String:
	if n is Node:
		var scr: Script = (n as Node).get_script()
		if scr != null:
			var gname := String(scr.get_global_name())
			if gname != "":
				return gname
		return (n as Node).get_class()
	return ""


func _class_of_kind(kind: Variant) -> String:
	return String((kind as Script).get_global_name()) if kind is Script else String(kind)


func _has_overlay(cls: String) -> bool:
	for c in main.get_children():
		if c.is_queued_for_deletion():
			continue
		if _class_of(c) == cls and (not (c is CanvasItem) or (c as CanvasItem).is_visible_in_tree()):
			return true
	return false


func _overlays() -> String:
	var parts: Array[String] = []
	for c in main.get_children():
		if c.is_queued_for_deletion():
			continue
		var cls := _class_of(c)
		if OVERLAY_CLASSES.has(cls) and (not (c is CanvasItem) or (c as CanvasItem).is_visible_in_tree()):
			parts.append(cls)
	return "|".join(parts)


func _dialog() -> ConfirmationDialog:
	for n in main.find_children("*", "ConfirmationDialog", true, false):
		var d := n as ConfirmationDialog
		if not d.is_queued_for_deletion() and d.visible:
			return d
	return null


func _hud_visible() -> bool:
	return main != null and main.world != null and main.world.hud != null and main.world.hud.visible


func _layers_str() -> String:
	if main == null or main.world == null:
		return "-"
	var parts: Array[String] = []
	for n in main.world.find_children("*", "CanvasLayer", true, false):
		var l := n as CanvasLayer
		parts.append("%d:%s=%d" % [l.layer, String(l.name), int(l.visible)])
		if parts.size() >= 12:
			break
	return ",".join(parts) if not parts.is_empty() else "-"


func _actual() -> String:
	var scr := _screen_class()
	return "screen=%s; overlays=%s" % [scr if scr != "" else "<none>", _overlays()]


func _focus_name() -> String:
	var f := root.gui_get_focus_owner()
	return "<none>" if f == null else "%s:%s" % [_class_of(f), String(f.name)]


func _picker_options() -> Array[StringName]:
	var p := main.screen as UpgradePicker
	if p == null:
		return [] as Array[StringName]
	return p.offered()


func _ids(list: Array) -> String:
	var out: Array[String] = []
	for id in list:
		out.append(String(id))
	return ",".join(out) if not out.is_empty() else "—"


func _first(list: Array) -> StringName:
	return StringName(String(list[0])) if not list.is_empty() else &""


# ── Ожидание и проверки исходов ──────────────────────────────────────────────────────────────

## Ждать факт после клика (переход не мгновенный: populate() у части экранов отложен).
func _settle(expect: String) -> void:
	if expect == "":
		await _frames(4)
		return
	var ok := await _until(func() -> bool: return _check(expect) == "", WAIT_SCREEN)
	if not ok:
		await _frames(6)   # дать кадру устояться перед снимком, даже если шаг провален


func _wait_screen(expect: String, limit: float) -> void:
	await _until(func() -> bool: return _check(expect) == "", limit)


## Маршрут 4: повторный показ награды обязан дать ТЕ ЖЕ варианты (состав id сравнивается).
func _check_same_options(after: Array[StringName]) -> void:
	var a := _ids(_offered_before)
	var b := _ids(after)
	var ok := a == b
	if not ok:
		_fails.append("D6_continue: после выхода в меню варианты другие (%s → %s)" % [a, b])
	_extra_row("D6_same_options", ok, "было=" + a, "стало=" + b)


## Маршрут 5: после замены активных снова три, новая поправка встала на место старой, награда
## забрана (pending_reward пуст) — значит выдана один раз, а не дважды.
func _check_replacement(was: Array[StringName], offered: Array[StringName]) -> void:
	var now := Campaign.upgrades()
	var new_id := _first(offered)
	var gone: Array[StringName] = []
	for old in was:
		if not now.has(old):
			gone.append(old)
	var problems: Array[String] = []
	if now.size() != AmendmentDb.MAX_ACTIVE:
		problems.append("активных %d, не %d" % [now.size(), AmendmentDb.MAX_ACTIVE])
	if not now.has(new_id):
		problems.append("новая поправка %s не встала" % String(new_id))
	if gone.size() != 1:
		problems.append("вычеркнуто %d пунктов, ожидался один" % gone.size())
	if Campaign.pending_reward() != "":
		problems.append("награда не забрана: pending=" + Campaign.pending_reward())
	var ok := problems.is_empty()
	if not ok:
		_fails.append("E5_replace_slot: " + "; ".join(problems))
	_extra_row("E5_replace_check", ok,
		"было=[%s]" % _ids(was), "стало=[%s] вычеркнут=[%s]" % [_ids(now), _ids(gone)])


## Дополнительная строка-проверка (не шаг с кадром): результат сравнения состояний.
func _extra_row(id: String, ok: bool, before: String, after: String) -> void:
	_tsv.store_line("%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s" % [
		id, "состояние", "-", before, _actual(), int(self.paused), _layers_str(),
		"OK" if ok else "FAIL", after])
	_tsv.flush()
	print("CLICKWALK ", id, "\t", "OK" if ok else "FAIL", "\t", before, "\t", after)


# ── Проверка вёрстки (задание K, п.5) ───────────────────────────────────────────────────────

## Аудит вёрстки: видимые Control, включая Label/RichTextLabel/TextureRect (проход H смотрел
## только кнопки). Находки:
##  (а) пара, где верхний накрывает нижний не целиком — один закрывает текст или кнопку другого;
##      родитель/потомок и фон-панель под своим содержимым не в счёт (так и задумано);
##  (б) текст шире своего прямоугольника (надпись без переноса, кнопка с обрезанной подписью);
##  (в) элемент за кромкой вьюпорта.
## Пары считаются ВНУТРИ одного слоя-хозяина: элементы меню и открытого поверх него оверлея
## лежат друг под другом по устройству — это не находка. Содержимое ScrollContainer исключено
## (обрезается самим окном прокрутки), сведения о прокрутке — отдельной строкой.
## Одинаковая находка пишется один раз: набор строк на 1280×720 и 960×540 совпадает побайтово.
func _ui_audit(tag: String) -> void:
	var view := Rect2(Vector2.ZERO, root.get_visible_rect().size)
	var subjects: Array[Control] = []
	for n in main.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree() or _in_scroll(c):
			continue
		if _audit_kind(c) == "" or not _draws(c):
			continue
		var r := _root_rect(c)
		if r.size.x <= 1.0 or r.size.y <= 1.0:
			continue
		if _on_screen_space(c) and not view.grow(AUDIT_VIEW_TOLERANCE).encloses(r):
			_audit(tag, "вне вьюпорта (слой %s): %s «%s» %s"
				% [_class_of(_host_of(c)), _audit_kind(c), _audit_name(c), _rect_txt(r)])
		if _text_overflows(c):
			_audit(tag, "текст шире прямоугольника (слой %s): %s «%s» %s"
				% [_class_of(_host_of(c)), _audit_kind(c), _audit_name(c), _rect_txt(r)])
		subjects.append(c)
	var battle := _in_battle()
	for i in subjects.size():
		var a := subjects[i]
		for j in range(i + 1, subjects.size()):
			var b := subjects[j]
			if a.is_ancestor_of(b) or b.is_ancestor_of(a) or _in_modal(a) or _in_modal(b):
				continue
			# Разные хозяева — разные слои экрана. В бою их сравниваем: интерфейс разложен по
			# нескольким CanvasLayer (HUD, уроки/способности, комбо, превью волн), и наложение
			# между ними видно игроку так же, как внутри одного. В меню — нет: там «слой» и есть
			# экран, чужой слой нарочно лежит ниже.
			if not battle and _host_of(a) != _host_of(b):
				continue
			var ra := _root_rect(a)
			var rb := _root_rect(b)
			var inter := ra.intersection(rb)
			if inter.size.x <= AUDIT_MIN_OVERLAP or inter.size.y <= AUDIT_MIN_OVERLAP:
				continue
			# Накрытие целиком «нарисовано ниже» — подложка/фон под своим содержимым, не находка.
			if (ra.encloses(rb) and not _above(a, b)) or (rb.encloses(ra) and not _above(b, a)):
				continue
			var names := [_audit_kind(a), _audit_name(a), _audit_kind(b), _audit_name(b)]
			if not _above(a, b):
				names = [names[2], names[3], names[0], names[1]]
			_audit(tag, "наложение %.0fx%.0f (слой %s): %s «%s» накрывает %s «%s»"
				% [inter.size.x, inter.size.y, _class_of(_host_of(a)),
					names[0], names[1], names[2], names[3]])
	_scroll_note(tag)


## Класс-предмет для отчёта или "" — узел в аудит не берётся.
func _audit_kind(c: Control) -> String:
	for k in AUDIT_SUBJECTS:
		if c.is_class(k):
			return k
	return ""


## Рисует ли предмет хоть что-то. Пустая надпись не рисует ничего — в пары она не идёт: её
## прямоугольник есть, а наложения на экране нет (L: аудит K считал пустые Label находками).
func _draws(c: Control) -> bool:
	if c is Label:
		return not String((c as Label).text).strip_edges().is_empty()
	if c is RichTextLabel:
		return not (c as RichTextLabel).get_parsed_text().strip_edges().is_empty()
	return true


## Имя узла для отчёта: у кнопки — подпись, у надписи — её текст, у иконки — файл текстуры.
func _audit_name(c: Control) -> String:
	if c is Label:
		return String((c as Label).text).strip_edges().left(60)
	if c is RichTextLabel:
		return (c as RichTextLabel).get_parsed_text().strip_edges().left(60)
	if c is Button:
		return _btn_label(c as Button)
	if c is TextureRect:
		var tr := c as TextureRect
		return tr.texture.resource_path.get_file() if tr.texture != null else "<без текстуры>"
	# Подложка/панель: своё имя у неё машинное (@PanelContainer@4200) — берём первую надпись
	# внутри, иначе находку не с чем соотнести на экране.
	for n in c.find_children("*", "Label", true, false):
		var text := String((n as Label).text).strip_edges()
		if not text.is_empty():
			return "%s:%s «%s»" % [c.get_class(), String(c.name), text.left(40)]
	return "%s:%s" % [c.get_class(), String(c.name)]


## Текст не влезает в свой прямоугольник: у надписи без переноса и у кнопки минимум шире факта.
func _text_overflows(c: Control) -> bool:
	if c is Label:
		var l := c as Label
		if l.autowrap_mode != TextServer.AUTOWRAP_OFF or l.clip_text:
			return false
		return l.get_minimum_size().x > l.size.x + 1.0
	if c is BaseButton:
		var b := c as BaseButton
		if b.clip_text:
			return false
		return b.get_minimum_size().x > b.size.x + 1.0
	return false


## Экранный ли это Control. У экранов, оверлеев и HUD над узлом стоит CanvasLayer (или он сам
## ребёнок main), а мировые Control (фон арены, меню площадки) живут под камерой: их
## прямоугольник честно уезжает за кромку вместе с камерой — «вне вьюпорта» для них не дефект.
func _on_screen_space(c: Control) -> bool:
	var cur: Node = c.get_parent()
	while cur != null and cur != main:
		if cur is CanvasLayer:
			return true
		cur = cur.get_parent()
	return _host_of(c) != main.world


## Слой-хозяин узла — прямой ребёнок main (экран кампании, мир или оверлей).
func _host_of(node: Node) -> Node:
	var cur: Node = node
	while cur.get_parent() != null and cur.get_parent() != main:
		cur = cur.get_parent()
	return cur


## a нарисован ПОЗЖЕ b (то есть выше, ближе к игроку): сперва номер CanvasLayer (у боя их
## несколько — HUD 5, уроки/способности/площадка 6, досье 20), затем путь индексов от корня.
## Порядок детей в дереве — порядок отрисовки; z_index в наших экранах не используется (кроме
## модальных оверлеев, а их пары в аудит не идут).
func _above(a: Control, b: Control) -> bool:
	var la := _paint_layer(a)
	var lb := _paint_layer(b)
	if la != lb:
		return la > lb
	var pa := _index_path(main, a)
	var pb := _index_path(main, b)
	for i in mini(pa.size(), pb.size()):
		if pa[i] != pb[i]:
			return pa[i] > pb[i]
	return pa.size() > pb.size()


## Номер CanvasLayer, под которым живёт узел (0 — обычный холст): порядок отрисовки между слоями.
func _paint_layer(node: Node) -> int:
	var cur := node.get_parent()
	while cur != null:
		if cur is CanvasLayer:
			return int((cur as CanvasLayer).layer)
		cur = cur.get_parent()
	return 0


## Узел живёт в модальном оверлее: их пары с боевым интерфейсом — замысел, не дефект.
func _in_modal(node: Node) -> bool:
	var cur: Node = node
	while cur != null and cur != main:
		# _class_of, а не is_class: оверлеи объявлены через class_name, и is_class их не знает
		if MODAL_CLASSES.has(_class_of(cur)):
			return true
		cur = cur.get_parent()
	return false


## Бой идёт: экрана нет, мир в BATTLE. Только здесь пары считаются между разными слоями.
func _in_battle() -> bool:
	return main != null and main.screen == null and main.world != null \
		and main.world.phase == LegionWorld.Phase.BATTLE


func _index_path(host: Node, node: Node) -> Array:
	var out: Array = []
	var cur := node
	while cur != null and cur != host:
		out.push_front(cur.get_index())
		cur = cur.get_parent()
	return out


func _in_scroll(node: Node) -> bool:
	var cur := node.get_parent()
	while cur != null:
		if cur is ScrollContainer:
			return true
		cur = cur.get_parent()
	return false


func _audit(tag: String, finding: String) -> void:
	if _audit_seen.has(finding):
		return
	_audit_seen[finding] = true
	_audit_write(tag, finding)


## Прокрутка: содержимое выше своего окна — сведения, а НЕ находка (список экранов нарочно
## прокручивается). Пишутся отдельным файлом ui_scroll.tsv: в ui_audit.tsv остаются только
## дефекты вёрстки, и «0 строк наложений» читается буквально.
func _scroll_note(tag: String) -> void:
	for n in main.find_children("*", "ScrollContainer", true, false):
		var s := n as ScrollContainer
		if not s.is_visible_in_tree() or s.get_child_count() == 0:
			continue
		var content := s.get_child(0) as Control
		if content == null:
			continue
		var over := content.size.y - s.size.y
		if over <= 8.0:
			continue
		var line := "слой %s: прокрутка — содержимое выше окна на %.0f px (окно %.0f px)" \
			% [_class_of(_host_of(s)), over, s.size.y]
		if _audit_seen.has(line):
			continue
		_audit_seen[line] = true
		_scroll_write(tag, line)


func _audit_write(tag: String, finding: String) -> void:
	_write_row("ui_audit.tsv", tag, finding)


## Сведения о прокрутке — отдельным файлом, чтобы в ui_audit.tsv остались только дефекты.
func _scroll_write(tag: String, line: String) -> void:
	_write_row("ui_scroll.tsv", tag, line)


func _write_row(file_name: String, tag: String, text: String) -> void:
	var f := FileAccess.open(_out_dir.path_join(file_name), FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_out_dir.path_join(file_name), FileAccess.WRITE)
	f.seek_end()
	f.store_line("%s\t%s" % [tag, text])
	f.close()


func _rect_txt(r: Rect2) -> String:
	if r.size == Vector2.ZERO:
		return "-"
	return "%.0f,%.0f %.0fx%.0f" % [r.position.x, r.position.y, r.size.x, r.size.y]


# ── Служебное ────────────────────────────────────────────────────────────────────────────────

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img == null:
		push_error("кадр " + name + ": пустая текстура вьюпорта")
		return
	var path := _out_dir.path_join(name + ".png")
	var err := img.save_png(path)
	if err != OK:
		push_error("кадр %s не сохранён (%d)" % [path, err])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Ждать выполнения условия не дольше limit_sec ИГРОВЫХ секунд. Меряем двумя ограничителями сразу:
## дельтой кадра (верно при любом режиме) и числом кадров (при --fixed-fps 60 кадр = 1/60 с) — на
## случай, если движок в этом контексте дельту не отдаёт. Бесконечного ожидания быть не может.
func _until(cond: Callable, limit_sec: float) -> bool:
	var cap := maxi(30, roundi(limit_sec * 60.0))
	var spent := 0.0
	for _i in cap:
		if bool(cond.call()):
			return true
		await process_frame
		spent += _delta()
		if spent >= limit_sec:
			break
	return bool(cond.call())


## Дельта текущего кадра (в SceneTree-скрипте нет get_process_delta_time — берём у корня).
func _delta() -> float:
	var d := maxf(root.get_process_delta_time(), 0.0)
	if d > 0.0:
		_delta_n += 1
		_delta_sum += d
		_delta_min = d if _delta_n == 1 else minf(_delta_min, d)
		_delta_max = maxf(_delta_max, d)
	return d


func _write_meta() -> void:
	var f := FileAccess.open(_out_dir.path_join("meta.txt"), FileAccess.WRITE)
	if f == null:
		return
	var lines: Array[String] = [
		"аргументы движка: " + " ".join(OS.get_cmdline_args()),
		"аргументы после --: " + " ".join(OS.get_cmdline_user_args()),
		"разрешение-аргумент: " + _res_name,
		"окно: %dx%d" % [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"режим окна: %d (0 — оконный)" % DisplayServer.window_get_mode(),
		"вьюпорт (логический холст): %s" % str(root.get_visible_rect().size),
		"final_transform (логика → окно): %s" % str(root.get_final_transform()),
		"max_fps=%d, time_scale=%.2f" % [Engine.max_fps, Engine.time_scale],
		"проба дельты кадра: %.5f" % root.get_process_delta_time(),
	]
	for l in lines:
		f.store_line(l)
		print("CLICKWALK meta ", l)
	f.close()


func _finish() -> void:
	_tsv.store_line("ИТОГ\tшагов %d, провалов %d" % [_steps, _step_fails])
	_tsv.close()
	var meta := FileAccess.open(_out_dir.path_join("meta.txt"), FileAccess.READ_WRITE)
	if meta != null:
		meta.seek_end()
		if _delta_n > 0:
			meta.store_line("дельта кадра: мин %.5f, сред %.5f, макс %.5f (кадров %d)"
				% [_delta_min, _delta_sum / float(_delta_n), _delta_max, _delta_n])
		meta.close()
	print("CLICKWALK ИТОГ %d/%d OK" % [_steps - _step_fails, _steps])
	for f in _fails:
		print("CLICKWALK FAIL ", f)
	print("CLICKWALK кадры: ", _out_dir)
	quit(1 if not _fails.is_empty() else 0)


func _arg(args: PackedStringArray, key: String) -> String:
	for i in args.size():
		if args[i] == key and i + 1 < args.size():
			return args[i + 1]
	return ""


## Значение ключа из пары «--dev key=value» (разбор тот же, что у LegionWorld.parse_args).
func _dev_arg(args: PackedStringArray, key: String) -> String:
	for i in args.size():
		if args[i] == "--dev" and i + 1 < args.size():
			var kv := args[i + 1].split("=", true, 1)
			if kv.size() == 2 and kv[0] == key:
				return kv[1]
	return ""
