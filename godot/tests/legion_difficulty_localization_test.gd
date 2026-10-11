extends SceneTree
## Exercise real picker button signals, including the joined Staff Member description.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL ", label)


func _run() -> void:
	Settings.path = "user://difficulty_localization_test.cfg"
	var original := JSON.stringify(LegionChallenge.TABLE)
	var english: Array[String] = [
		"The lightest workload: you can win with just one contract type.",
		"Shieldbearers push through Contract Work and resist head-on charges; "
			+ "ghosts come in waves. The climax includes a bonus.",
		"Denser, tougher, no breathing room. For those who have outgrown Staff Member.",
	]
	for locale in ["en", "ru"]:
		I18n.language = locale
		TranslationServer.set_locale(locale)
		Settings.set_difficulty(LegionChallenge.NORMAL)
		var picker := DifficultyPicker.new()
		root.add_child(picker)
		var expected_initial := english[1] if locale == "en" else String(
			LegionChallenge.TABLE[LegionChallenge.NORMAL]["desc"])
		_check(picker._desc.text == expected_initial, locale + " initial description")
		for index in range(LegionChallenge.ORDER.size()):
			var id := LegionChallenge.ORDER[index]
			(picker.buttons[id] as Button).pressed.emit()
			var expected := english[index] if locale == "en" else String(
				LegionChallenge.TABLE[id]["desc"])
			_check(picker._desc.text == expected, locale + " selected " + id)
			_check(Settings.difficulty() == id, locale + " canonical saved id " + id)
			_check((picker.buttons[id] as Button).button_pressed, locale + " selection " + id)
		picker.free()
	_check(JSON.stringify(LegionChallenge.TABLE) == original, "difficulty data unchanged")
	print("DIFFICULTY LOCALIZATION: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
