# gdlint: disable=max-file-lines
extends SceneTree
##
## Регресс независимого ревью J, находки J7 и J8 (05.10.2026).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_bindings_save_test.gd -- --mute
##
## J7 — скрытая Эн («Вызвать волну» на штатной Эф) возвращалась поверх другого назначения:
##      F→свободная, Ку→N, волна→F проходило проверку конфликта, и Эн висела на двух действиях.
## J8 — экран писал «Клавиша сохранена» после ОТКАЗА записи settings.cfg. Теперь rebind/reset
##      возвращают причину, а плашка SaveNotice даёт кнопку «Повторить запись», которая доводит
##      запись до диска, когда причина ушла.
##
## Итог «LEGION BINDINGS SAVE: N/M OK»; код выхода 1, если что-то упало.
##

const PREFS := "user://legion_bindings_save_settings.cfg"

var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])


func key_event(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	return event


func _frames(n := 1) -> void:
	for i in n:
		await process_frame


func _fresh() -> void:
	Settings.path = PREFS
	Settings._cfg = null
	Settings.apply()
	Controls.reset()


func _read_prefs() -> String:
	return FileAccess.get_file_as_string(PREFS) if FileAccess.file_exists(PREFS) else ""


## Барьер записи: каталог на месте временного файла — FileAccess на нём всегда отказывает.
func _raise_barrier() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PREFS + ".tmp"))


func _drop_barrier() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS + ".tmp"))


func _run() -> void:
	_test_alias_conflict()
	await _test_write_refusal()
	_cleanup()
	print("LEGION BINDINGS SAVE: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


# ── J7: скрытая Эн и чужие назначения ────────────────────────────────────────

func _test_alias_conflict() -> void:
	print("— J7: скрытая Эн «Вызвать волну»")
	_fresh()
	check(Controls.key(&"call_wave") == KEY_F and key_event(KEY_N).is_action_pressed(&"call_wave"),
		"штатная раскладка: Эн вызывает волну вместе с Эф")
	check(Controls.rebind(&"call_wave", KEY_J).is_empty(), "волна переехала на свободную клавишу")
	check(Controls.key(&"call_wave") == KEY_J
			and not key_event(KEY_N).is_action_pressed(&"call_wave"),
		"без штатной Эф скрытая Эн не висит на волне")
	check(Controls.rebind(&"cast_q", KEY_N).is_empty(), "пока волна не на Эф, Эн свободна для «Ку»")
	check(Controls.key(&"cast_q") == KEY_N, "«Ку» заняла Эн")
	check(not Controls.rebind(&"call_wave", KEY_F).is_empty(),
		"возврат волны на Эф при занятой Эн отклонён (J7)")
	check(Controls.key(&"call_wave") == KEY_J, "волна осталась на прежней клавише")
	check(key_event(KEY_N).is_action_pressed(&"cast_q")
			and not key_event(KEY_N).is_action_pressed(&"call_wave"),
		"Эн делает только «Ку»")
	# Словарь «волна на Эф и чужое на Эн» негоден целиком: иначе Эн повесилась бы дважды.
	Settings.set_value(Controls.SECTION, "keyboard", {"call_wave": KEY_F, "cast_q": KEY_N})
	Controls.apply()
	check(Controls.key(&"cast_q") == KEY_Q and Controls.key(&"call_wave") == KEY_F,
		"сохранённый словарь с двойной Эн отвергнут целиком, взяты умолчания")
	check(not key_event(KEY_N).is_action_pressed(&"cast_q"),
		"в отвергнутом словаре «Ку» на Эн не осталась")
	_fresh()


# ── J8: отказ записи виден, повтор кнопкой доводит запись ────────────────────

func _test_write_refusal() -> void:
	print("— J8: отказ записи settings.cfg")
	_fresh()
	var before := _read_prefs()
	_raise_barrier()
	var message := Controls.rebind(&"kassa", KEY_H)
	check(not message.is_empty(), "отказ записи настроек возвращён вызывающему, а не «пусто»")
	check(Controls.key(&"kassa") == KEY_H, "раскладка в этой сессии уже новая (InputMap применён)")
	check(_read_prefs() == before, "на диск ничего не легло — обещать «сохранено» нельзя")
	check(SafeConfig.notices.has(Settings.path), "SafeConfig поднял извещение о сбое записи")
	# Плашка «Не удалось сохранить»: кнопка повтора доводит запись до диска, когда причина ушла
	var notice := SaveNotice.new()
	root.add_child(notice)
	await _frames(2)
	var retry: Variant = notice.get("_retry")
	check(retry != null, "плашка умеет повторять запись (кнопка есть)")
	if retry == null:
		notice.queue_free()
		_drop_barrier()
		return
	check((retry as Button).visible, "кнопка «Повторить запись» показана при сбое записи")
	_drop_barrier()
	(retry as Button).pressed.emit()
	await _frames(2)
	check(not SafeConfig.notices.has(Settings.path), "повтор записи снял извещение об отказе")
	check(_read_prefs().contains("kassa"), "повтор записал раскладку на диск")
	notice.queue_free()
	await _frames()
	# Перечитка файла без сброса раскладки: клавиша должна прийти с диска
	Settings._cfg = null
	Settings.apply()
	check(Controls.key(&"kassa") == KEY_H, "назначенная клавиша пережила перезапись из файла")


func _cleanup() -> void:
	Settings.path = Settings.PATH
	Settings._cfg = null
	SafeConfig.notices.erase(PREFS)
	_drop_barrier()
	for suffix: String in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS + suffix))
	Controls.reset()
