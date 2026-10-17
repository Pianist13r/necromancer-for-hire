extends Node
## Diagnostic main scene for a private release-template PCK. Never shipped.

const BASE_UID := "uid://bvgjm8g4e0e8k"
const NAMES := ["Master", "Music", "SFX", "Voice"]
const EFFECT_COUNTS := [1, 2, 1, 0]

var pipe_failures: Array[String] = []
var pipe_checks := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	pipe_checks += 1
	if not ok:
		pipe_failures.append(label)


func _audio() -> Dictionary:
	var failures: Array[String] = []
	var raw_path: String = str(ProjectSettings.get_setting("audio/buses/default_bus_layout", ""))
	var editor_path: String = str(ProjectSettings.get_setting(
		"audio/buses/default_bus_layout.editor", ""))
	var effective_path: String = str(ProjectSettings.get_setting_with_override(
		"audio/buses/default_bus_layout"))
	if raw_path != BASE_UID:
		failures.append("raw base UID changed")
	if effective_path != BASE_UID:
		failures.append("release template did not select base UID")
	var layout: Resource = ResourceLoader.load(effective_path)
	if not layout is AudioBusLayout:
		failures.append("effective UID did not load as AudioBusLayout")
	var facts := {"raw_setting": raw_path, "editor_override": editor_path,
		"effective_setting": effective_path, "resource_loaded": layout is AudioBusLayout,
		"count": AudioServer.get_bus_count(), "buses": []}
	if AudioServer.get_bus_count() != 4:
		failures.append("startup AudioServer bus count is not four")
	else:
		for i in 4:
			var name := AudioServer.get_bus_name(i)
			var effect_count := AudioServer.get_bus_effect_count(i)
			var send := str(AudioServer.get_bus_send(i))
			(facts["buses"] as Array).append({"name": name, "effects": effect_count, "send": send})
			if name != NAMES[i] or effect_count != EFFECT_COUNTS[i]:
				failures.append("wrong bus name/count at index %d" % i)
			if i > 0 and send != "Master":
				failures.append("wrong send at index %d" % i)
			for j in effect_count:
				if not AudioServer.is_bus_effect_enabled(i, j):
					failures.append("disabled effect at %d/%d" % [i, j])
		if AudioServer.get_bus_effect_count(0) == 1:
			var master_fx := AudioServer.get_bus_effect(0, 0)
			if not master_fx is AudioEffectHardLimiter \
					or absf((master_fx as AudioEffectHardLimiter).ceiling_db + 1.0) > 0.001:
				failures.append("Master hard limiter/ceiling mismatch")
		if AudioServer.get_bus_effect_count(1) == 2:
			var music_low := AudioServer.get_bus_effect(1, 0)
			var music_amp := AudioServer.get_bus_effect(1, 1)
			if not music_low is AudioEffectLowPassFilter \
					or absf((music_low as AudioEffectLowPassFilter).cutoff_hz - 20000.0) > 0.01:
				failures.append("Music low-pass/cutoff mismatch")
			if not music_amp is AudioEffectAmplify:
				failures.append("Music amplifier missing")
		if AudioServer.get_bus_effect_count(2) == 1:
			var sfx_fx := AudioServer.get_bus_effect(2, 0)
			if not sfx_fx is AudioEffectCompressor \
					or absf((sfx_fx as AudioEffectCompressor).threshold + 14.0) > 0.001 \
					or absf((sfx_fx as AudioEffectCompressor).ratio - 3.0) > 0.001:
				failures.append("SFX compressor/parameters mismatch")
	facts["failures"] = failures
	return facts


func _pipe() -> Dictionary:
	_check(OS.has_feature("ship") and OS.has_feature("template")
		and not OS.has_feature("editor") and not OS.is_debug_build(), "ship runtime flags")
	var script: Variant = load("res://scripts/legion/net/net_link_pipe.gd")
	if script == null or not script.has_method("pair"):
		_check(false, "embedded script load/pair")
		return {"checks": pipe_checks, "failures": pipe_failures}
	var pair: Variant = script.pair()
	if not pair is Array or pair.size() != 2:
		_check(false, "exactly two endpoints")
		return {"checks": pipe_checks, "failures": pipe_failures}
	_check(true, "exactly two endpoints")
	var a: Variant = pair[0]
	var b: Variant = pair[1]
	_check(a != b and a.state() == 1 and b.state() == 1, "distinct OPEN endpoints")
	_check(a.kind() == "pipe" and b.kind() == "pipe", "pipe kind")
	_check(a.available() == 0 and b.available() == 0, "initial empty")
	var forward: Array[String] = ["Привет 🦴", "second:2", "", "last:4"]
	var reverse: Array[String] = ["ответ 🧪", "sequence:2"]
	for message: String in forward:
		_check(a.send_text(message) == OK, "forward send")
	for message: String in reverse:
		_check(b.send_text(message) == OK, "reverse send")
	_check(b.available() == forward.size() and a.available() == reverse.size(), "queue counts")
	for i in forward.size():
		_check(b.take_text() == forward[i], "forward order/text")
		_check(b.last_size() == forward[i].to_utf8_buffer().size(), "forward UTF8 size")
		_check(b.available() == forward.size() - i - 1, "forward remaining")
	for i in reverse.size():
		_check(a.take_text() == reverse[i], "reverse order/text")
		_check(a.last_size() == reverse[i].to_utf8_buffer().size(), "reverse UTF8 size")
		_check(a.available() == reverse.size() - i - 1, "reverse remaining")
	_check(a.take_text() == "" and b.take_text() == "", "empty take")
	_check(a.send_text("queued before close") == OK, "pre-close send")
	a.close(4321, "QA close")
	_check(a.state() == 2 and b.state() == 2, "close propagates")
	_check(a.close_code() == 4321 and b.close_code() == 4321, "close code")
	_check(a.close_reason() == "QA close" and b.close_reason() == "QA close", "close reason")
	_check(a.send_text("no") == ERR_UNAVAILABLE, "closed A refuses")
	_check(b.send_text("no") == ERR_UNAVAILABLE, "closed B refuses")
	_check(b.available() == 1 and b.take_text() == "queued before close", "queued survives close")
	b.close(9999, "again")
	_check(b.close_code() == 4321, "idempotent close")
	var weak_a: WeakRef = weakref(a)
	var weak_b: WeakRef = weakref(b)
	pair.clear()
	a = null
	b = null
	script = null
	_check(weak_a.get_ref() == null and weak_b.get_ref() == null, "endpoints released")
	return {"checks": pipe_checks, "failures": pipe_failures}


func _run() -> void:
	var audio := _audio()
	var pipe := _pipe()
	await get_tree().process_frame
	await get_tree().process_frame
	var flags := {"ship": OS.has_feature("ship"), "editor": OS.has_feature("editor"),
		"template": OS.has_feature("template"), "debug": OS.is_debug_build()}
	var passed: bool = (flags["ship"] and not flags["editor"] and flags["template"]
		and not flags["debug"] and audio["failures"].is_empty()
		and pipe["checks"] == 40 and pipe["failures"].is_empty())
	print("TEMPLATE_SEMANTICS_PROBE " + JSON.stringify({"pass": passed,
		"flags": flags, "audio": audio, "pipe": pipe}))
	get_tree().quit(0 if passed else 1)
