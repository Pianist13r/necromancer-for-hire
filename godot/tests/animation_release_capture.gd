extends SceneTree
## Изолированная витрина настоящих CharView; не подмена геймплея.
## -- --mute --out <worktree>/batches/anim-1008/render

const IDS := ["skeleton", "guard", "clerk", "zombie", "ghost", "necromancer",
	"beetle", "signer", "lawyer", "mimic", "boss"]
const STAGES := ["idle", "walk_e", "walk_n", "attack", "hit", "death_a", "death_b", "rise", "cast"]
var _views: Array[CharView] = []
var _out := ""
var _label: Label


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[args.find("--out") + 1]
	DirAccess.make_dir_recursive_absolute(_out)
	root.size = Vector2i(1280, 720)
	var bg := ColorRect.new()
	bg.color = Color("282535")
	bg.size = Vector2(1280, 720)
	root.add_child(bg)
	_label = Label.new()
	_label.position = Vector2(18, 12)
	_label.add_theme_font_size_override("font_size", 24)
	root.add_child(_label)
	for stage: String in STAGES:
		for view: CharView in _views:
			view.free()
		_views.clear()
		_label.text = "CharView · " + stage + " · 60 Hz / mobile renderer"
		for i in IDS.size():
			var view := CharView.new()
			root.add_child(view)
			view.position = Vector2(105 + (i % 6) * 212, 205 + (i / 6) * 310)
			view.setup(IDS[i], 86.0)
			view._pop_t = -1.0
			view._rng.seed = i
			view._anim.set_death_variant(0)
			_views.append(view)
			var label := Label.new()
			label.text = IDS[i]
			label.position = Vector2(-50, 90)
			view.add_child(label)
			match stage:
				"walk_e", "walk_n":
					view.set_direction(Vector2.UP if stage == "walk_n" else Vector2.RIGHT)
					if view.has_clip(&"walk"):
						view.set_locomotion(1.0)
						# Сцена стоит на месте: показать расчётный темп, не замер неподвижного узла.
						view._walk_ref = 0.0
				"attack":
					view.play_once(&"cast" if IDS[i] == "necromancer" else &"attack")
				"death_a", "death_b":
					if view.has_clip(&"death"):
						view._anim.set_death_variant(1 if stage == "death_b" else 0)
						view.play_once(&"death")
				"rise":
					if IDS[i] != "necromancer":
						view.play_once(&"spawn" if IDS[i] in ["skeleton", "guard", "clerk"] else &"rise")
				"cast":
					if IDS[i] == "necromancer":
						view.set_direction(Vector2.LEFT)
						view.play_once(&"cast")
		for frame in 96:
			if stage == "hit" and frame == 12:
				for view: CharView in _views:
					view.react_hit()
					view.flash()
			await process_frame
			await RenderingServer.frame_post_draw
			if frame % 4 == 0:
				root.get_texture().get_image().save_png(_out.path_join("%s_%03d.png" % [stage, frame]))
	print("ANIMATION CAPTURE: 9 stages / 216 frames OK")
	quit()
