extends SceneTree
##
## Регресс настроек запуска (v19, 26.09.2026): Игорь — «надо, чтобы стартовало в
## полноэкранном». С выпила старого режима (2939a60) Settings.apply() никто не звал: громкости,
## выключенный звук и полный экран из settings.cfg при запуске не применялись.
##
##   "$GODOT" --headless --path godot --script res://tests/legion_settings_test.gd -- --mute
##
## 1) без записанного ключа полный экран по умолчанию включён;
## 2) записанный выбор игрока (оконный) уважается;
## 3) прогон с --mute — агентный: полный экран ему не применяется (файл настроек общий с
##    владельцем — иначе окно агента развернулось бы на весь его экран);
## 4) главная сцена применяет настройки при старте (вызов Settings.apply() в LegionMain._ready).
## Файл настроек владельца не читается и не пишется: конфиг подменяется пустым в памяти.
## Итог «LEGION SETTINGS: N/M OK»; код выхода 1, если что-то упало.
##

var _fails := 0
var _checks := 0


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
	# пустой конфиг в памяти вместо user://settings.cfg владельца; set_* не зовём (они пишут файл)
	Settings._cfg = ConfigFile.new()
	_check(Settings.is_fullscreen(), "без записи — полный экран по умолчанию")
	Settings._cfg.set_value(Settings.SEC_VIDEO, "fullscreen", false)
	_check(not Settings.is_fullscreen(), "записанный оконный режим уважается")
	Settings._cfg.set_value(Settings.SEC_VIDEO, "fullscreen", true)
	_check(Settings.is_fullscreen(), "записанный полный экран уважается")
	_check(Settings.is_agent_run(), "прогон с --mute — агентный (окно не разворачивается)")
	var main_src := FileAccess.get_file_as_string("res://scripts/legion/legion_main.gd")
	var ready_at := main_src.find("func _ready() -> void:")
	var next_func := main_src.find("\nfunc ", ready_at + 1)
	var ready_body := main_src.substr(ready_at, next_func - ready_at)
	_check(ready_at >= 0 and ready_body.contains("Settings.apply()"),
		"главная сцена применяет настройки при старте")
	Settings._cfg = null
	print("LEGION SETTINGS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
