class_name I18n
extends RefCounted
## Перевод только представления: ключи сохранений и состояние симуляции остаются прежними.

const CATALOGS := ["res://localization/en_a.json", "res://localization/en_b.json",
	"res://localization/en_extra.json"]
const VOICE_ROOT := "res://assets/legion/voice/"
static var language := "ru"
static var _loaded := false
static var _english: Dictionary = {}
static var _translation: Translation
static var _map_version_pattern: RegEx


static func initialize(system_language: String = "") -> void:
	_load_catalogs()
	var saved := String(Settings.get_value("language", "locale", ""))
	var system := OS.get_locale_language() if system_language.is_empty() else system_language
	var preferred := system if saved.is_empty() else saved
	# Существующий русский профиль не меняет язык сам после обновления.
	if saved.is_empty() and FileAccess.file_exists(Settings.path):
		preferred = "ru"
	# Фиксируем язык до других настроек: иначе новый EN-профиль после первой записи
	# settings.cfg выглядел бы как старый RU-профиль на следующем запуске.
	if saved.is_empty():
		Settings.set_value("language", "locale", "ru" if preferred.begins_with("ru") else "en")
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--language="):
			preferred = arg.trim_prefix("--language=")
	language = "ru" if preferred.begins_with("ru") else "en"
	TranslationServer.set_locale(language)
	DisplayServer.window_set_title(t("Некромант по найму"))


static func _load_catalogs() -> void:
	if _loaded:
		return
	_loaded = true
	_translation = Translation.new()
	_translation.locale = "en"
	for path: String in CATALOGS:
		if not FileAccess.file_exists(path):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			_english.merge(parsed, true)
	for source: String in _english:
		_translation.add_message(source, String(_english[source]))
	TranslationServer.add_translation(_translation)


static func t(source: String) -> String:
	if language != "en":
		return source
	_load_catalogs()
	return String(_english.get(source, source))


static func select(locale: String) -> void:
	if locale not in ["ru", "en"]:
		return
	Settings.set_value("language", "locale", locale)
	language = locale
	TranslationServer.set_locale(locale)
	Controls.revision += 1
	DisplayServer.window_set_title(t("Некромант по найму"))


static func map_text(source: String) -> String:
	if language != "en":
		return source
	if source.begins_with("Карта собрана новой версией генератора ("):
		if _map_version_pattern == null:
			_map_version_pattern = RegEx.create_from_string(
				"^Карта собрана новой версией генератора \\(v([0-9]+) → v([0-9]+)\\)\\. (.*)$")
		var match_version := _map_version_pattern.search(source)
		if match_version != null:
			return "Map rebuilt with a newer generator (v%s → v%s). %s" % [
				match_version.get_string(1), match_version.get_string(2),
				map_text(match_version.get_string(3))]
	var translated := t(source)
	return translated if translated != source else PgNames.display_text(source)


static func voice_path(id: StringName) -> String:
	# Отсутствие EN-клипа ловит гейт покрытия; русскую реплику вместо него не подмешиваем.
	var directory := VOICE_ROOT + "en/" if language == "en" else VOICE_ROOT
	return directory + String(id) + ".ogg"
