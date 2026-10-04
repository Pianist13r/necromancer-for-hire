extends SceneTree
## Shipped clips must keep all facings, contact timing and a held corpse after loading.

var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL ", label)


func _seconds(frames: SpriteFrames, key: String, count: int) -> float:
	var weight := 0.0
	for i in count:
		weight += frames.get_frame_duration(key, i)
	return weight / frames.get_animation_speed(key)


func _run() -> void:
	for kind: String in ["skeleton", "guard", "clerk", "zombie", "ghost", "beetle",
		"signer", "lawyer", "mimic", "boss"]:
		var loaded := CharAnim.load_clips(CfgAnim.char_def(kind)["clips"])
		var frames: SpriteFrames = loaded["frames"]
		var defs: Dictionary = loaded["defs"]
		for state: String in ["attack", "death"]:
			_check(defs.has(state), "%s has %s" % [kind, state])
			if not defs.has(state):
				continue
			for direction: String in ["e", "se", "s", "ne", "n"]:
				var key := state + "_" + direction
				_check(defs[state]["directions"].get(direction, "") == key,
					"%s %s survives loader timing validation" % [kind, key])
				if not defs.has(key):
					continue
				var duration := _seconds(frames, key, frames.get_frame_count(key))
				var expected := .5 if state == "attack" else (1.0 if kind == "boss" else .4)
				_check(absf(duration - expected) < .0001, "%s %s duration" % [kind, key])
				_check(not defs[key]["loop"], "%s %s is one-shot" % [kind, key])
				if state == "attack":
					var contact := int(defs[key]["contact_frame"])
					_check(contact > 0 and contact < frames.get_frame_count(key),
						"%s %s has contact" % [kind, key])
					if contact > 0:
						_check(absf(_seconds(frames, key, contact) - .1) < .0001,
							"%s %s contact stays at 100ms" % [kind, key])
				else:
					_check(defs[key]["hold"], "%s %s holds corpse" % [kind, key])
				var pivot: Array = defs[key]["pivot_px"]
				var texture := frames.get_frame_texture(key, 0)
				_check(pivot.size() == 2 and float(defs[key]["figure_fill"]) > 0.0,
					"%s %s has standing geometry" % [kind, key])
				if pivot.size() == 2:
					_check(float(pivot[0]) >= 0.0 and float(pivot[0]) <= texture.get_width()
						and float(pivot[1]) >= 0.0 and float(pivot[1]) <= texture.get_height(),
						"%s %s pivot inside canvas" % [kind, key])
	print("DIRECTIONAL ACTION ASSETS: %d/%d OK" % [checks - failures, checks])
	quit(0 if failures == 0 else 1)
