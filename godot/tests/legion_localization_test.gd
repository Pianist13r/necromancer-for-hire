extends SceneTree
## Привязки в английском тексте должны подставляться один раз, включая обмен Q/W.

const TutorialVoice = preload("res://scripts/legion/legion_tutorial_voice.gd")

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
	Settings.path = "user://locale_fresh_%d.cfg" % Time.get_ticks_usec()
	Settings._cfg = null
	I18n.initialize("en")
	_check(I18n.language == "en", "Fresh English system profile")
	Settings.set_value("test", "unrelated", true)
	Settings._cfg = null
	I18n.initialize("en")
	_check(I18n.language == "en", "English survives unrelated settings write and restart")
	Settings.path = "user://locale_legacy_%d.cfg" % Time.get_ticks_usec()
	Settings._cfg = null
	Settings.set_value("audio", "muted", true)
	I18n.initialize("en")
	_check(I18n.language == "ru", "Legacy Russian profile preserved")
	Settings.path = "user://localization_test.cfg"
	Settings._cfg = null
	I18n.language = "en"
	_check(Controls.label(&"cast_q", true) == "Q", "English spoken key label")
	_check(Controls.text("Press {key:cast_q}.") == "Press Q.", "English binding token")
	_check(MouseBind.label(&"draw") == "LMB", "English mouse label")
	Settings.lefty_override = "on"
	_check(MouseBind.label(&"draw") == "RMB", "Left-handed mouse label")
	Settings.lefty_override = "off"
	for id: StringName in LessonsCfg.VOICE_MOUSE:
		_check(TutorialVoice.sequence(id) == [StringName(String(id) + "_righty")],
			"English right-handed speech: " + String(id))
		Settings.lefty_override = "on"
		_check(TutorialVoice.sequence(id) == [StringName(String(id) + "_lefty")]
			and TutorialVoice.has_replacement(id), "English left-handed speech: " + String(id))
		Settings.lefty_override = "off"
	_check(Controls.text("Grade E; press {key:cast_q}.") == "Grade E; press Q.",
		"English prose is not a legacy binding reference")
	_check(I18n.voice_path(&"lg_intro_1").ends_with("/en/lg_intro_1.ogg"), "English voice path")
	var audio := LegionAudio.new()
	root.add_child(audio)
	audio.setup_standalone(true, false)
	audio.speech.voice(&"lg_tut_1", 10, LegionAudio.VoiceClass.STORY)
	_check(audio.speech._voice_parts == [&"lg_tut_1_righty"], "Right-handed speech starts")
	Settings.lefty_override = "on"
	audio.speech.refresh_tutorial_voice(&"lg_tut_1")
	_check(audio.speech._voice_parts == [&"lg_tut_1_lefty"], "Mouse speech refreshes after handedness change")
	audio.speech.stop_voice()
	audio.free()
	Settings.lefty_override = "off"
	_check(I18n.map_text("Пустырь") == "Wasteland", "Campaign JSON title")
	var generated := I18n.map_text("Архив погоста")
	_check(generated != "Архив погоста" and not generated.contains("погоста"),
		"Generated name reconstructed at display")
	_check(I18n.map_text("Архив погоста особой важности").ends_with("of Special Importance"),
		"Generated boss title")
	_check(I18n.map_text("Карта собрана новой версией генератора (v1 → v2). Пустырь")
		== "Map rebuilt with a newer generator (v1 → v2). Wasteland", "Version migration hint")
	var hint := "Одна дорога молчит до 7-й волны — её ворота видны заранее."
	_check(I18n.map_text(hint).contains("7") and not I18n.map_text(hint).contains("дорога"),
		"Generated delayed-road hint")
	I18n.language = "ru"
	_check(Controls.label(&"cast_q", true) == "Ку", "Russian key label unchanged")
	_check(MouseBind.label(&"draw") == "ЛКМ", "Russian mouse label unchanged")
	_check(I18n.voice_path(&"lg_intro_1").ends_with("/voice/lg_intro_1.ogg"), "Russian voice path")
	print("LOCALIZATION: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
