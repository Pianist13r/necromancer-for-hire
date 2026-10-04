extends SceneTree
## Real shipped PNG/JSON, direction selection, shared textures, and idle/walk layout.

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("%s %s" % ["OK" if ok else "FAIL", label])

func _run() -> void:
	CharView.economy_motion = true
	var clips := {"idle": CfgAnim.ZOMBIE_CLIPS["idle"], "walk": CfgAnim.ZOMBIE_CLIPS["walk"]}
	var loaded := CharAnim.load_clips(clips)
	var frames: SpriteFrames = loaded["frames"]
	var defs: Dictionary = loaded["defs"]
	var textures := {}
	for state: String in ["walk", "idle"]:
		for direction: String in ["e", "se", "s", "ne", "n"]:
			var key := state + "_" + direction
			_check(defs[state]["directions"].get(direction, "") == key, key + " available")
			_check(frames.get_frame_count(key) == (16 if state == "walk" else 1), key + " frame count")
			var pivot: Array = defs[key]["pivot_px"]
			_check(pivot.size() == 2 and float(pivot[0]) == 64 and float(pivot[1]) == 112
				and float(defs[key]["figure_fill"]) == .75, key + " normalized pivot and height")
			for i in frames.get_frame_count(key):
				var texture := frames.get_frame_texture(key, i)
				_check(texture.get_size() == Vector2(128, 128), key + " runtime128 frame%d" % i)
				textures[texture.get_rid().get_id()] = true
	_check(textures.size() == 85, "85 unique textures = 5.3125MiB RGBA8 base level")
	var holder := Node2D.new()
	root.add_child(holder)
	var view := CharView.new()
	holder.add_child(view)
	view.setup("zombie",44.0)
	view.set_process(false)
	for vector: Vector2 in [Vector2.RIGHT,Vector2(1,1),Vector2.DOWN,Vector2(-1,1),
		Vector2.LEFT,Vector2(-1,-1),Vector2.UP,Vector2(1,-1)]:
		view.set_locomotion(1.0)
		view.set_direction(vector)
		view._face_cur = view._facing
		view._apply_pivot()
		var walk_scale := view._anim_local.x.length()
		view.set_locomotion(0.0)
		view._apply_pivot()
		_check(view.current_state() == &"idle" and view._anim_local.x.length() == walk_scale
			and is_equal_approx(walk_scale,44.0/96.0), "stop retains body44 in direction%s" % vector)
		var ground := view._anim.transform * Vector2(0,48)
		_check(ground.distance_to(Vector2(0,view.ground_px())) < .001, "idle pivot lies on existing ground%s" % vector)
	holder.free()
	CharView.economy_motion = false
	print("ZOMBIE DIRECTIONAL ASSETS: %d/%d OK" % [checks-failures,checks])
	quit(0 if failures==0 else 1)
