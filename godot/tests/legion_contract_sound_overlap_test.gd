extends SceneTree
## B1008-S1: two real contract-field SFX requests retain independent playback.

const MAX_VOICES := 8

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	AudioServer.set_bus_mute(0, true)
	var field := ContractField.new()
	root.add_child(field)
	await process_frame
	field._on_charge_impact(Vector2(400, 300), true) # skel_hit, pitch 0.8
	var first_stream := SfxGen.get_stream("skel_hit")
	var first := _find(field, first_stream)
	_check(first != null and first.playing, "удар натиска начал skel_hit")
	field._sound("mine_boom", 1.35) # тот же путь, что spring_released
	var second := _find(field, SfxGen.get_stream("mine_boom"))
	_check(first != null and second != null and first != second,
		"близкий взрыв пружины получил отдельный голос")
	_check(first != null and first.playing and first.stream == first_stream,
		"первый звук не прерван вторым")
	_check(second != null and second.playing and is_equal_approx(second.pitch_scale, 1.35),
		"второй звук играет с исходной высотой")
	_check(first != null and first.bus == &"SFX" and is_equal_approx(first.pitch_scale, 0.8),
		"шина и высота первого звука сохранены")
	for i in 12:
		field._sound("mine_boom", 0.9)
		await process_frame
	_check(_voices(field).size() <= MAX_VOICES,
		"12 дополнительных вызовов не создают больше %d голосов" % MAX_VOICES)
	for voice in _voices(field):
		voice.stop()
		voice.stream = null
	field.queue_free()
	await process_frame
	for i in 60:
		await process_frame
	_check(not is_instance_valid(field), "плееры освобождаются вместе с полем")
	print("CONTRACT SOUND OVERLAP: %d/%d OK" % [_checks - _fails, _checks])
	quit(0 if _fails == 0 else 1)


func _voices(field: ContractField) -> Array[AudioStreamPlayer]:
	var out: Array[AudioStreamPlayer] = []
	for child in field.get_children():
		if child is AudioStreamPlayer:
			out.append(child)
	return out


func _find(field: ContractField, stream: AudioStream) -> AudioStreamPlayer:
	for player in _voices(field):
		if player.stream == stream:
			return player
	return null


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL ", label)
