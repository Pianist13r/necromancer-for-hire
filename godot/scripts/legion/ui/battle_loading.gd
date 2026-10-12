extends Control
## Cold animation textures are loaded by ResourceLoader workers. Only completed
## requests are retrieved on the main thread; frames are then built from the cache.
## https://docs.godotengine.org/en/4.7/tutorials/io/background_loading.html

const MAX_PENDING := 64
var timings: Dictionary = {}
var _label: Label
var _bar: ProgressBar


func _ready() -> void:
	name = "BattleLoading"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var background := ColorRect.new()
	background.color = Color(0.045, 0.05, 0.07)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	_label = Label.new()
	_label.position = Vector2(240, 300)
	_label.size = Vector2(800, 70)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_font_override("font", UiStyle.FONT_TEXT)
	_label.text = I18n.t("Подготовка боя…")
	add_child(_label)
	_bar = ProgressBar.new()
	_bar.position = Vector2(390, 390)
	_bar.size = Vector2(500, 18)
	_bar.show_percentage = false
	add_child(_bar)


func prepare() -> bool:
	var started := Time.get_ticks_usec()
	# Two turns let the loading screen draw before even the filesystem scan.
	await get_tree().process_frame
	await get_tree().process_frame
	var paths: Dictionary = {}
	for id: String in CfgAnim.CHARS:
		if CharView._cache.has(id):
			continue
		var definition := CfgAnim.char_def(id)
		var clips: Dictionary = definition.get("clips", {})
		for clip: Dictionary in clips.values():
			_add_directory(paths, String(clip.get("dir", "")))
			for direction: Dictionary in (clip.get("directions", {}) as Dictionary).values():
				_add_directory(paths, String(direction.get("dir", "")))
		var fallback: Dictionary = definition.get("fallback", {})
		for state: Dictionary in fallback.values():
			var path := String(state.get("tex", ""))
			if path.begins_with("res://") and ResourceLoader.exists(path):
				paths[path] = true
		await get_tree().process_frame
	timings["scan_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	var pending: Array[String] = []
	var queue: Array = paths.keys()
	# Keep strong references until CharView owns the textures. The resource cache
	# is weak; discarding each result here would cause a second synchronous load.
	var retained: Array[Resource] = []
	var next := 0
	var failed := false
	# The dummy renderer cannot initialize textures concurrently (RID races).
	# Real-window acceptance still exercises the concurrent Vulkan path.
	var max_pending := 1 if DisplayServer.get_name() == "headless" else MAX_PENDING
	while next < queue.size() or not pending.is_empty():
		while next < queue.size() and pending.size() < max_pending:
			var path := String(queue[next])
			next += 1
			if ResourceLoader.load_threaded_request(path) != OK:
				push_error("BattleLoading: unable to request " + path)
				failed = true
				next = queue.size()
				break
			pending.append(path)
		for index in range(pending.size() - 1, -1, -1):
			var path := pending[index]
			var status := ResourceLoader.load_threaded_get_status(path)
			if status == ResourceLoader.THREAD_LOAD_LOADED:
				retained.append(ResourceLoader.load_threaded_get(path))
				pending.remove_at(index)
			elif status == ResourceLoader.THREAD_LOAD_FAILED \
					or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				# Completed failed requests still own a user token. Consume it so
				# a later retry can issue a fresh load instead of reusing failure.
				if status == ResourceLoader.THREAD_LOAD_FAILED:
					ResourceLoader.load_threaded_get(path)
				push_error("BattleLoading: unable to load " + path)
				failed = true
				next = queue.size()
				pending.remove_at(index)
		_bar.value = 90.0 * retained.size() / maxi(queue.size(), 1)
		await get_tree().process_frame
	# Let every request we started finish before allowing a retry.
	if failed:
		return false
	timings["textures_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	var count := 0
	for id: String in CfgAnim.CHARS:
		CharView.warm([id])
		count += 1
		_bar.value = 90.0 + 10.0 * count / CfgAnim.CHARS.size()
		await get_tree().process_frame
	timings["total_ms"] = (Time.get_ticks_usec() - started) / 1000.0
	timings["textures"] = retained.size()
	print("BATTLE LOADING: ", JSON.stringify(timings))
	return true


func _add_directory(paths: Dictionary, directory: String) -> void:
	if not directory.begins_with("res://"):
		return
	var index := 0
	while true:
		var path := directory.path_join("spr_%02d.png" % index)
		if not ResourceLoader.exists(path):
			break
		paths[path] = true
		index += 1
