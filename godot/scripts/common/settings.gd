class_name Settings
extends RefCounted
##
## Настройки игрока в `user://settings.cfg` (ConfigFile): громкости шин, мьют, полноэкранный
## режим, VSync — и флаги пакетов (стажировка пройдена, интро просмотрено…) в своих секциях.
## Экран настроек в меню и в паузе — пакет P6; здесь только хранение и применение.
##
## Правила:
## - любое чтение терпит отсутствие файла и ключа (первый запуск, чужая машина);
## - файл пишется ТОЛЬКО из set_*: агентный `--mute` глушит игру на лету и НЕ сохраняется,
##   иначе агентный прогон навсегда заглушил бы игру владельцу;
## - apply() трогает только то, что реально записано в файле: без файла поведение прежнее —
##   кроме полноэкранного режима: он по умолчанию включён (v19, Игорь 26.09: «надо, чтобы
##   стартовало в полноэкранном»), а агентному прогону окно не разворачивается никогда.
##

const PATH := "user://settings.cfg"
const BUSES: Array[StringName] = [&"Master", &"Music", &"SFX", &"Voice"]
const SEC_AUDIO := "audio"
const SEC_VIDEO := "video"

## v17: схема управления — рогатка на ПКМ (по умолчанию) или классика (ПКМ — только щелчок).
const SEC_CONTROLS := "controls"
const SCHEME_SLING := "sling"
const SCHEME_CLASSIC := "classic"

## v20 (26.09.2026, B-053/B-054): «Графика: полная/экономная». Экономная выключает слой
## эффектов LegionFx с фоновой жизнью карт, тени CharShadows и процедурную «живость» CharView
## (дыхание, раскачка, наклон, пружина удара, подскок появления) — клипы играют как есть.
## Бой не меняется: настройка чисто вид, world.rng её не видит (legion_gfx_test).
## Тот же раздел, что fullscreen/vsync — общий «video».
const KEY_ECONOMY := "economy_graphics"

## Уровень сложности режима «По истечении договора» (LegionChallenge): предпочтение игрока,
## одно на кампанию и свободную игру, поэтому здесь, а не в legion.cfg прогресса.
const SEC_GAME := "game"
const KEY_DIFFICULTY := "difficulty"
## Подсказки боя (slow/intuit): когда жать Ку/Дубль-вэ/Е, «щёлкни золотой», «сорви пружину».
## По умолчанию включены. Золото, метка пружины и оглушённых — не советы, видны всегда.
const KEY_HINTS := "hints"

static var _cfg: ConfigFile = null
## Файл настроек. Тест переключателя сложности ставит свой (в user://settings.cfg владельца
## тесты не пишут); после смены — `_cfg = null`, чтобы перечитать.
static var path := PATH
## Сложность только в памяти: не пусто — перекрывает файл (--dev difficulty=…, тесты).
static var difficulty_override := ""
## Схема только в памяти (тесты, приёмочные кадры): не пусто — перекрывает файл и НЕ пишется
## в user://settings.cfg владельца.
static var scheme_override := ""
## Тот же приём для графики: "" — как в файле, "on"/"off" — перекрывает (замеры, тесты,
## `--dev gfx=economy|full`), в user://settings.cfg владельца не пишется.
static var economy_override := ""
## Подсказки только в памяти: "" — как в файле, "on"/"off" — перекрывает (тесты, агентный прогон).
static var hints_override := ""


## B-062: `--dev save=user://имя.cfg` (прогон на своём сохранении) уводит и настройки в парный
## `user://имя_settings.cfg` — галочки «Настроек» не пишут в настоящий settings.cfg владельца.
## Звать ДО Settings.apply(). Пустой путь — обратно общий файл.
static func use_dev_save(save_path: String) -> void:
	if save_path == "" or not Campaign.is_safe_dev_save(save_path):
		path = PATH
	else:
		path = "user://%s_settings.cfg" % save_path.trim_prefix("user://").get_basename()
	_cfg = null


static func _file() -> ConfigFile:
	if _cfg == null:
		_cfg = SafeConfig.load_file(path)
	return _cfg


## Произвольное значение (секция пакета: "flow", "tutorial", "story"…).
static func get_value(section: String, key: String, default: Variant = null) -> Variant:
	return _file().get_value(section, key, default)


static func set_value(section: String, key: String, value: Variant) -> void:
	_file().set_value(section, key, value)
	_save()
	if GameBus.inst != null:
		GameBus.inst.settings_changed.emit("%s/%s" % [section, key], value)


## Громкость шины 0..1 (линейно). Шины: Master, Music, SFX, Voice (default_bus_layout.tres).
static func get_bus_volume(bus: StringName) -> float:
	return float(get_value(SEC_AUDIO, String(bus), 1.0))


static func set_bus_volume(bus: StringName, linear: float) -> void:
	var v := clampf(linear, 0.0, 1.0)
	_apply_bus_volume(bus, v)
	set_value(SEC_AUDIO, String(bus), v)


static func is_muted() -> bool:
	return bool(get_value(SEC_AUDIO, "muted", false))


static func set_muted(on: bool) -> void:
	_apply_mute(on)
	set_value(SEC_AUDIO, "muted", on)


static func is_fullscreen() -> bool:
	return bool(get_value(SEC_VIDEO, "fullscreen", true))


## Агентный прогон (--mute после «--» или файл res://.agent_mute — как у AgentWindow): его окно
## спрятано за экраном, и полноэкранный режим владельца ему применять нельзя — файл настроек
## общий, окно развернулось бы на весь экран владельца.
static func is_agent_run() -> bool:
	return OS.get_cmdline_user_args().has("--mute") or FileAccess.file_exists("res://.agent_mute")


static func set_fullscreen(on: bool) -> void:
	_apply_fullscreen(on)
	set_value(SEC_VIDEO, "fullscreen", on)


static func is_vsync() -> bool:
	return bool(get_value(SEC_VIDEO, "vsync", true))


static func set_vsync(on: bool) -> void:
	_apply_vsync(on)
	set_value(SEC_VIDEO, "vsync", on)


## Схема управления: "sling" | "classic". Неизвестное значение в файле — рогатка.
static func control_scheme() -> String:
	if scheme_override != "":
		return scheme_override
	var s := String(get_value(SEC_CONTROLS, "scheme", SCHEME_SLING))
	return s if s == SCHEME_CLASSIC else SCHEME_SLING


static func set_control_scheme(s: String) -> void:
	set_value(SEC_CONTROLS, "scheme", SCHEME_CLASSIC if s == SCHEME_CLASSIC else SCHEME_SLING)


## «Экономная» графика (по умолчанию — «полная», false).
static func is_economy_graphics() -> bool:
	if economy_override != "":
		return economy_override == "on"
	return bool(get_value(SEC_VIDEO, KEY_ECONOMY, false))


## «Живость» CharView — статик-флаг, ни одного узла не пересобираем. Слой эффектов (LegionFx)
## и тени (CharShadows) — узлы; LegionWorld._sync_gfx_layers() создаёт/освобождает их сама
## каждый кадр (verifier 26.09: LegionMain создаёт LegionWorld один раз на сессию, а не на
## бой, — «со следующего боя» через _build() было неправдой, тот же мир возвращался в меню и в
## новый бой со старыми узлами). Применяется сразу, из паузы и из меню тоже. Оба варианта —
## вид, бой не видит ни то, ни другое.
static func set_economy_graphics(on: bool) -> void:
	set_value(SEC_VIDEO, KEY_ECONOMY, on)
	CharView.economy_motion = on


## Уровень сложности: "intern" | "normal" | "hell" (LegionChallenge.ORDER).
## Агентный прогон (--mute: гейт, тесты, серии) предпочтение владельца из файла НЕ наследует —
## иначе выбранный Игорем «Ад» молча менял бы серии бота и тесты; ему — LegionChallenge.DEFAULT,
## пока сам не выберет (set_difficulty в агентном прогоне кладёт и в память).
static func difficulty() -> String:
	if difficulty_override != "":
		return LegionChallenge.valid(difficulty_override)
	if is_agent_run() and path == PATH:
		return LegionChallenge.DEFAULT
	return LegionChallenge.valid(String(get_value(SEC_GAME, KEY_DIFFICULTY, LegionChallenge.DEFAULT)))


## Выбор в меню или в выборе карт; действует со следующего боя (волны боя уже разложены).
## Агентный прогон (--mute) с настоящим файлом — только в память, как scheme_override и
## economy_override: иначе приёмка меню записала бы «Ад» в user://settings.cfg владельца
## (verifier 26.09: DifficultyPicker.select("hell") записал difficulty="hell").
static func set_difficulty(d: String) -> void:
	var v := LegionChallenge.valid(d)
	if is_agent_run() and path == PATH:
		difficulty_override = v
		return
	set_value(SEC_GAME, KEY_DIFFICULTY, v)


## Подсказки боя (по умолчанию ВКЛ).
static func hints_enabled() -> bool:
	if hints_override != "":
		return hints_override == "on"
	return bool(get_value(SEC_GAME, KEY_HINTS, true))


## Галочка «Подсказки». Агентный прогон с настоящим файлом — только в память (как
## set_difficulty): приёмка настроек не должна выключать подсказки владельцу.
static func set_hints(on: bool) -> void:
	if is_agent_run() and path == PATH:
		hints_override = "on" if on else "off"
		return
	set_value(SEC_GAME, KEY_HINTS, on)


## Применить сохранённое при старте (LegionMain._ready). Записанные ключи + полный экран по
## умолчанию. С выпила старого режима (2939a60, v15) вызова не было вовсе: громкости,
## выключенный звук и полный экран из настроек при запуске не применялись (нашли 26.09).
static func apply() -> void:
	var cfg := _file()
	for bus in BUSES:
		if cfg.has_section_key(SEC_AUDIO, String(bus)):
			_apply_bus_volume(bus, float(cfg.get_value(SEC_AUDIO, String(bus))))
	if cfg.has_section_key(SEC_AUDIO, "muted"):
		_apply_mute(bool(cfg.get_value(SEC_AUDIO, "muted")))
	# «живость» — статик-флаг CharView, экрана не трогает: применяем и в безголовом/агентном
	# прогоне (серии бота на экономной графике должны совпадать с полной по числам боя).
	CharView.economy_motion = is_economy_graphics()
	if DisplayServer.get_name() == "headless" or is_agent_run():
		return
	_apply_fullscreen(is_fullscreen())
	if cfg.has_section_key(SEC_VIDEO, "vsync"):
		_apply_vsync(bool(cfg.get_value(SEC_VIDEO, "vsync")))


static func _save() -> void:
	var err := SafeConfig.save_file(_file(), path)
	if err != OK:
		push_warning("Settings: не удалось сохранить %s (%d)" % [path, err])


static func _apply_bus_volume(bus: StringName, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))


static func _apply_mute(on: bool) -> void:
	var idx := AudioServer.get_bus_index(&"Master")
	if idx >= 0:
		AudioServer.set_bus_mute(idx, on)


static func _apply_fullscreen(on: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED
	)


static func _apply_vsync(on: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED
	)
