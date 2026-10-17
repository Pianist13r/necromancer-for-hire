extends SceneTree
## Синтетические остатки прерванной записи; не имитация отключения питания.

const BASE := "user://save_leftovers_"
var checks := 0
var failures := 0


func _initialize() -> void:
	_run()
	print("SAVE LEFTOVERS: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("OK " if ok else "FAIL ", message)


func profile(seq: int) -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.set_value("fixture", "seq", seq)
	cfg.set_value("fixture", "souls", seq * 17)
	cfg.set_value("fixture", "items", ["stamp_%d" % seq, "ink_%d" % seq])
	return cfg


func write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func envelope(cfg: ConfigFile) -> String:
	var payload := cfg.encode_to_text()
	return SafeConfig.PREFIX + payload.sha256_text() + "\n" + payload


func whole(cfg: ConfigFile, seq: int) -> bool:
	return cfg.encode_to_text() == profile(seq).encode_to_text()


func scenario(label: String, suffix: String, corrupt: bool = false) -> void:
	var path := BASE + label + ".cfg"
	check(SafeConfig.save_file(profile(1), path, true) == OK, label + ": backup создан")
	check(SafeConfig.save_file(profile(2), path) == OK, label + ": current создан")
	if corrupt:
		write_text(path, "; necro-save-v1 invalid\n[fixture]\nseq=88\n")
		write_text(path + suffix, envelope(profile(99)))
	else:
		write_text(path + suffix, "; necro-save-v1 incomplete\n[fixture]\nseq=")
	var before := FileAccess.get_file_as_bytes(path)
	var backup := FileAccess.get_file_as_bytes(path + ".bak")
	var leftover := FileAccess.get_file_as_bytes(path + suffix)
	var loaded := SafeConfig.load_file(path)
	check(whole(loaded, 1 if corrupt else 2), label + ": загружен целый подтверждённый профиль")
	check(FileAccess.get_file_as_bytes(path) == before
		and FileAccess.get_file_as_bytes(path + ".bak") == backup
		and FileAccess.get_file_as_bytes(path + suffix) == leftover,
		label + ": чтение не переписывает файлы и не продвигает tmp")
	check(String(SafeConfig.notices.get(path, "")).contains("резервной копии") == corrupt,
		label + ": уведомление соответствует восстановлению")
	check(SafeConfig.save_file(profile(3), path) == OK, label + ": последующая запись разрешена")
	check(whole(SafeConfig.load_file(path), 3), label + ": следующий профиль пережил загрузку")
	var saved_backup := ConfigFile.new()
	check(saved_backup.load(path + ".bak") == OK and whole(saved_backup, 1 if corrupt else 2),
		label + ": backup остаётся целым предыдущим подтверждённым профилем")


func _run() -> void:
	scenario("partial_tmp", ".tmp")
	scenario("partial_backup_tmp", ".bak.tmp")
	scenario("corrupt_current", ".tmp", true)
	# Только tmp не является опубликованным сохранением: существующий контракт — пустой профиль.
	var path := BASE + "tmp_only.cfg"
	# Повтор теста в том же user:// не должен унаследовать опубликованный файл прошлой пробы.
	for suffix: String in ["", ".bak", ".tmp", ".bak.tmp"]:
		if FileAccess.file_exists(path + suffix):
			var error := DirAccess.remove_absolute(path + suffix)
			assert(error == OK, "tmp-only cleanup: " + suffix)
	write_text(path + ".tmp", envelope(profile(99)))
	var before := FileAccess.get_file_as_bytes(path + ".tmp")
	check(SafeConfig.load_file(path).get_sections().is_empty(), "только tmp: профиль пуст")
	check(not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bak")
		and FileAccess.get_file_as_bytes(path + ".tmp") == before,
		"только tmp: чтение не публикует неподтверждённый файл")
	check(SafeConfig.save_file(profile(1), path) == OK and whole(SafeConfig.load_file(path), 1),
		"только tmp: первая штатная запись и загрузка работают")
