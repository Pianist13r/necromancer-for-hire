extends SceneTree
## Оконная приёмка: настоящий CharView, равные якоря, игровой размер и увеличение.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	AudioServer.set_bus_mute(0, true)
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	var out := args[index + 1] if index >= 0 else "user://poses.png"
	var stage := Node2D.new()
	root.add_child(stage)
	var bg := ColorRect.new()
	bg.color = Color("514c53")
	bg.size = Vector2(1280, 720)
	stage.add_child(bg)
	var actors: Array[CharView] = []
	var chars: Array[String] = ["skeleton", "guard", "clerk", "zombie", "signer", "beetle"]
	for row in 2:
		for column in chars.size():
			var origin := Vector2(110 + column * 205, 190 + row * 340)
			var label := Label.new()
			label.text = chars[column]
			label.position = origin + Vector2(-40, -100)
			stage.add_child(label)
			var line := Line2D.new()
			line.points = PackedVector2Array([origin + Vector2(-80, 0), origin + Vector2(80, 0)])
			line.default_color = Color("aa9491")
			line.width = 1.0
			stage.add_child(line)
			var actor := CharView.new()
			stage.add_child(actor)
			actor.position = origin
			actor.setup(chars[column], 46.0 if row == 0 else 92.0)
			actor.set_locomotion(1.0)
			actors.append(actor)
	for frame in 40:
		await process_frame
	for actor: CharView in actors:
		actor.react_hit()
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(out)
	print("pose shot: %s (%s)" % [out, error_string(error)])
	stage.free()
	quit(0 if error == OK else 1)
