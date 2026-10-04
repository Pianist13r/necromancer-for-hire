extends SceneTree
## Real idle/walk resources for all ten kinds, including shared GPU textures.

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, text: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(text)

func _run() -> void:
	CharView.economy_motion = true
	for spec: Array in [["skeleton",46.0],["guard",50.0],["clerk",42.0],["signer",44.0],
		["zombie",44.0],["ghost",44.0],["beetle",30.0],["mimic",42.0],["lawyer",46.0],["boss",105.8]]:
		var id: String = spec[0]
		var canvas := 256.0 if id=="boss" else 128.0
		var standing := canvas*.75
		var walk_count := 1 if id=="ghost" else 16
		var allocation_count := 10 if id=="ghost" else 85
		var clips: Dictionary = CfgAnim.CHARS[id]["clips"]
		var loaded := CharAnim.load_clips({"idle": clips["idle"],"walk": clips["walk"]})
		var frames: SpriteFrames = loaded["frames"]
		var defs: Dictionary = loaded["defs"]
		var unique := {}
		for state: String in ["idle","walk"]:
			for direction: String in ["e","se","s","ne","n"]:
				var key := state+"_"+direction
				_check(defs[state]["directions"].get(direction,"") == key,id+" "+key)
				_check(frames.get_frame_count(key) == (1 if state=="idle" else walk_count),id+" count "+key)
				var pivot: Array = defs[key]["pivot_px"]
				_check(pivot.size()==2 and float(pivot[0])==canvas*.5 and float(pivot[1])==canvas*.875
					and float(defs[key]["figure_fill"])==.75,id+" geometry "+key)
				var sizes_ok := true
				for index in frames.get_frame_count(key):
					var texture := frames.get_frame_texture(key,index)
					sizes_ok = sizes_ok and texture.get_size()==Vector2(canvas,canvas)
					unique[texture.get_rid().get_id()]=true
				_check(sizes_ok,id+" resolution "+key)
		_check(unique.size()==allocation_count,id+" unique texture allocations")
		var holder := Node2D.new()
		root.add_child(holder)
		var view := CharView.new()
		holder.add_child(view)
		view.setup(id,float(spec[1]))
		view.set_process(false)
		for direction: Vector2 in [Vector2.RIGHT,Vector2(1,1),Vector2.DOWN,Vector2(-1,1),
			Vector2.LEFT,Vector2(-1,-1),Vector2.UP,Vector2(1,-1)]:
			view.set_direction(direction)
			view.set_locomotion(1)
			view._face_cur=view._facing
			view._apply_pivot()
			var walking := view._anim_local.x.length()
			view.set_locomotion(0)
			view._apply_pivot()
			_check(view.current_state()==&"idle" and is_equal_approx(walking,view._anim_local.x.length())
				and is_equal_approx(walking,float(spec[1])/standing),id+" stable stop layout")
			var ground := view._anim.transform*Vector2(0,canvas*.375)
			_check(ground.distance_to(Vector2(0,view.ground_px()))<.001,id+" stable ground")
		holder.free()
		print("Directional assets %s:%d unique textures,%dpx,all8 headings checked"%[id,unique.size(),int(canvas)])
	CharView.economy_motion=false
	print("DIRECTIONAL GAIT ASSETS: %d/%d OK"%[checks-failures,checks])
	quit(0 if failures==0 else 1)
