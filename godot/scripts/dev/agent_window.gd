extends Node
## Окно для агентных прогонов не должно всплывать у владельца.
##
## override.cfg открывает главное окно за пределами экрана и без фокуса. Этот автолоад
## решает, чей запуск: агентный (есть `--mute` в аргументах после `--` или файл
## res://.agent_mute) — окно остаётся спрятанным, но рендерит (кадры --shot/--write-movie
## снимаются как обычно); запуск владельца (play.bat, без --mute) — окно сразу
## возвращается в центр основного экрана и получает фокус.
## Появилось 2026-09-23 по просьбе владельца: параллельные агенты открывали окна Godot.


func _enter_tree() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# --offscreen (запись промо движком, REC-02): окно прячется так же, но звук не глушится —
	# Movie Maker пишет его в файл через драйвер Dummy; без записи --offscreen глушит сам
	# (LegionWorld.parse_args), так что на колонки владельца агентный звук не выходит.
	var user_args := OS.get_cmdline_user_args()
	var agent_run := user_args.has("--mute") or user_args.has("--offscreen") \
		or FileAccess.file_exists("res://.agent_mute")
	var win := get_window()
	if agent_run:
		# Окно стартует СВЁРНУТЫМ (override.cfg), поэтому не мелькает. Свёрнутым его оставлять
		# нельзя: window_can_draw() = false, и `await frame_post_draw` в --shot из меню виснет
		# навсегда (нашла соседняя сессия 2026-09-23). Поэтому сперва уводим окно за экран,
		# ПОТОМ разворачиваем — оно рисует, но на экране его нет.
		win.position = Vector2i(-32000, -32000)
		win.mode = Window.MODE_WINDOWED
		win.position = Vector2i(-32000, -32000)
		return
	win.mode = Window.MODE_WINDOWED
	win.set_flag(Window.FLAG_NO_FOCUS, false)
	var screen := DisplayServer.get_primary_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	win.current_screen = screen
	win.position = usable.position + (usable.size - win.size) / 2
	DisplayServer.window_move_to_foreground()
	win.grab_focus()
