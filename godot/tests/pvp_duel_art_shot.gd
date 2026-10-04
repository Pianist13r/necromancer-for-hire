extends SceneTree
## Кадры карты «Дуэль» после сборки PgArt (B-381) — только в окне, не headless (нужен GPU):
##   APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1 "$GODOT" --path godot --fixed-fps 60
##       --resolution 1280x720 --script res://tests/pvp_duel_art_shot.gd
##       -- --mute --out C:/AI/necro/pvp/duel-art-shots [--seed 3]
## Ждёт background_build_finished земли (не больше 20 с), потом ~2 с боя ботов и пишет
## duel_art.png (вьюпорт). Итог сборки (текстура, depth_split) — в stdout.

var w: LegionWorld
var out := ""
var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, default: String) -> String:
	var argv := OS.get_cmdline_user_args()
	var pos := argv.find(name)
	return argv[pos + 1] if pos >= 0 and pos + 1 < argv.size() else default


func _run() -> void:
	out = _arg("--out", "user://duel-art-shots")
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://pvp_duel_art_shot.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.args["pvp_bots"] = true
	w._base_seed = int(_arg("--seed", "3"))
	w.start_map("pvp:duel")
	var tv := w._ground as TerrainView
	if tv == null:
		failed = true
		push_error("PVP_DUEL_ART no TerrainView")
	else:
		var waited := 0.0
		while tv.background_build_pending() and waited < 20.0:
			await process_frame
			waited += 1.0 / 60.0
		print("PVP_DUEL_ART build pending=%s waited=%.1fs texture=%s depth_split=%s" % [
			tv.background_build_pending(), waited, tv.background_texture() != null, tv._depth_split])
		if tv.background_texture() == null:
			failed = true
	var t0 := w.now
	while w.now - t0 < 2.0:
		await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if picture == null or picture.is_empty():
		failed = true
		push_error("PVP_DUEL_ART empty GPU frame")
	else:
		failed = picture.save_png(out.path_join("duel_art.png")) != OK or failed
		print("PVP_DUEL_ART shot saved")
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("PVP_DUEL_ART_SHOT exit%d" % (1 if failed else 0))
	quit(1 if failed else 0)
