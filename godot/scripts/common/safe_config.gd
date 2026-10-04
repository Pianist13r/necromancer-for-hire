class_name SafeConfig
extends RefCounted
## Маленький профиль: проверяемая запись, последняя рабочая копия и явный отказ вместо потери.
## Комментарий с хешем совместим с ConfigFile; старые файлы без заголовка читаются как раньше.

const PREFIX := "; necro-save-v1 "
const FAMILY := "; necro-save-"
static var notices: Dictionary = {}
static var _blocked: Dictionary = {}


static func load_file(path: String) -> ConfigFile:
	_blocked.erase(path)
	var current := _read(path)
	if current["error"] == OK:
		return current["config"]
	# Новая версия могла изменить смысл данных: откат к старому backup здесь опасен.
	if current["error"] == ERR_UNAVAILABLE:
		return _refuse(path, "Сохранение создано более новой версией игры. Запись отключена.")
	var backup := _read(path + ".bak")
	if backup["error"] == OK:
		notices[path] = "Данные восстановлены из резервной копии."
		return backup["config"]
	if current["error"] == ERR_FILE_NOT_FOUND and backup["error"] == ERR_FILE_NOT_FOUND:
		notices.erase(path)
		return ConfigFile.new()
	return _refuse(path,
		"Не удалось прочитать сохранение. Исходные файлы сохранены; запись отключена.")


static func _refuse(path: String, message: String) -> ConfigFile:
	_blocked[path] = true
	notices[path] = message
	push_warning("SafeConfig: %s (%s)" % [message, path])
	return ConfigFile.new()


static func _read(path: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if not FileAccess.file_exists(path):
		return {"error": ERR_FILE_NOT_FOUND, "config": cfg}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": FileAccess.get_open_error(), "config": cfg}
	var text := file.get_as_text()
	file.close()
	var verified := false
	if text.begins_with(FAMILY):
		if not text.begins_with(PREFIX):
			return {"error": ERR_UNAVAILABLE, "config": cfg}
		var line_end := text.find("\n")
		if line_end < 0:
			return {"error": ERR_FILE_CORRUPT, "config": cfg}
		var expected := text.substr(PREFIX.length(), line_end - PREFIX.length())
		text = text.substr(line_end + 1)
		if text.sha256_text() != expected:
			return {"error": ERR_FILE_CORRUPT, "config": cfg}
		verified = true
	elif text.strip_edges().is_empty():
		# Старый reset() писал пустой файл. Если есть копия, пустота может быть обрывом.
		if FileAccess.file_exists(path + ".bak"):
			return {"error": ERR_FILE_CORRUPT, "config": cfg}
	var err := cfg.parse(text)
	# Обрыв внутри заголовка («; necro») тоже синтаксически верный INI-комментарий.
	# Его нельзя принять за пустой старый профиль и переписать им рабочую копию.
	if err == OK and not verified and cfg.get_sections().is_empty() \
			and not text.strip_edges().is_empty():
		err = ERR_FILE_CORRUPT
	return {"error": err, "config": cfg}


static func save_file(cfg: ConfigFile, path: String, reset_history := false) -> Error:
	if _blocked.has(path) and not reset_history:
		return ERR_FILE_CORRUPT
	var payload := cfg.encode_to_text()
	var contents := PREFIX + payload.sha256_text() + "\n" + payload
	var err := _write_verified(path + ".tmp", contents)
	if err != OK:
		return _failed(path, err)
	var old := _read(path)
	if old["error"] == ERR_UNAVAILABLE and not reset_history:
		_refuse(path, "Сохранение создано более новой версией игры. Запись отключена.")
		return ERR_UNAVAILABLE
	# При восстановлении нельзя затереть хорошую копию повреждённым основным файлом.
	if reset_history or old["error"] == OK:
		var backup_text := contents if reset_history else FileAccess.get_file_as_string(path)
		err = _write_verified(path + ".bak.tmp", backup_text)
		if err == OK:
			err = DirAccess.rename_absolute(path + ".bak.tmp", path + ".bak")
		if err != OK:
			return _failed(path, err)
	# Повреждённый оригинал сохраняем для ручного восстановления, не затираем молча.
	if old["error"] != OK and old["error"] != ERR_FILE_NOT_FOUND:
		var archive := path + ".corrupt-" + str(Time.get_unix_time_from_system()).replace(".", "-")
		err = DirAccess.copy_absolute(path, archive)
		if err != OK:
			return _failed(path, err)
	err = DirAccess.rename_absolute(path + ".tmp", path)
	if err != OK:
		return _failed(path, err)
	_blocked.erase(path)
	if reset_history or not String(notices.get(path, "")).contains("резервной копии"):
		notices.erase(path)
	return OK


static func _write_verified(path: String, contents: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(contents)
	file.flush()
	var err := file.get_error()
	file.close()
	if err != OK:
		return err
	if FileAccess.get_file_as_string(path) != contents:
		return ERR_FILE_CORRUPT
	return OK


static func _failed(path: String, err: Error) -> Error:
	notices[path] = ("Не удалось сохранить изменения. "
		+ "Проверьте свободное место и доступ к папке сохранений.")
	push_warning("SafeConfig: запись %s не выполнена (%d)" % [path, err])
	return err
