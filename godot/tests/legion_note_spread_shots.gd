extends SceneTree
##
## Кадр приёмки подписей урона Ку по слипшейся куче (B-347, slow/pvp-read; не тест гейта).
## Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720
##       --script res://tests/legion_note_spread_shots.gd -- --mute --out C:/AI/necro/batches/legion/pvp-0930/read
##

const SAVE := "user://legion_note_spread_shots.cfg"
const P := Vector2(640, 300)

var w: LegionWorld
var out := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://"
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.unlock_all()
	Input.use_accumulated_input = false
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.in_campaign = true
	root.add_child(w)
	await process_frame
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	for f in 30:
		await process_frame
	# слипшаяся куча из 8: цепь Ку бьёт по всем, подписи встают почти в одну точку
	for off: Vector2 in [Vector2(0, 0), Vector2(14, 6), Vector2(-12, 8), Vector2(24, -4),
			Vector2(-22, -6), Vector2(8, 16), Vector2(34, 10), Vector2(-30, 14)]:
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([P + off]), P + off)
		f.speed = 0.0
	w.hero.cast(LegionHero.SLOT_Q, P)
	for f in 14:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := out.path_join(argv[argv.find("--name") + 1] if argv.has("--name") else "q_pile.png")
	print(JSON.stringify({"shot": path, "notes": w.ability_aim.notes.size(),
		"error": root.get_texture().get_image().save_png(path)}))
	Campaign.reset()
	quit(0)
