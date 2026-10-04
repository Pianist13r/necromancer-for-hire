extends SceneTree
##
## B-358: бот проходит объекты 1..N ОДНОГО забега «Бесконечного подряда» подряд через настоящий
## поток LegionMain, с переносом поправок, артефактов, «Конторы», стажа и душ (ядро —
## legion_run_chain.gd, политики — там же в докстринге). НЕ *_test.gd: гейт его не гоняет, забег
## долгий (минуты). Серии — tools/legion_run_series.sh.
##
##   APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1 "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_run_chain_runner.gd -- --mute
##       --dev run_seed=3341246352 --dev bot_seed=91 [--dev run_objects=10] [--dev bot=selective]
##       [--dev difficulty=intern|normal|hell] [--dev run_upgrade=first] [--dev run_shop=off]
##       [--dev battle_cap_s=1800]
##
## Не передавать --bot/--map/--autostart/--seed/--quit-on-end: LegionMain ушёл бы в compat-путь
## одного боя. Вывод: строка «RUN_OBJECT {json}» на объект, в конце «RUN_END {json}» (reason:
## defeat | objects | timeout). Код выхода: 0 — забег отыгран (в т.ч. поражением или
## таймаутом боя), 1 — сбой раннера (поток пошёл не туда). Сохранение — своё
## user://legion_run_chain_<забег>_<бот>.cfg, каждый прогон с чистого профиля.
##

const Chain := preload("res://tests/legion_run_chain.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := LegionWorld.parse_args()
	var dev: Dictionary = args["dev"]
	for bad in ["bot", "map", "autostart", "seed", "quit_on_end"]:
		if args.has(bad):
			print("RUN_CHAIN ERROR: --%s не передавать — задайте через --dev (см. докстринг)" % bad)
			quit(1)
			return
	# --dev save=… в командной строке видит и LegionMain._ready: он сбрасывает сохранение уже
	# после prepare_profile — забег молча шёл бы без профиля «ветеран» (verifier B-358, 30.09)
	if dev.has("save"):
		print("RUN_CHAIN ERROR: --dev save не передавать — сохранение раннера всегда своё " +
			"user://legion_run_chain_<забег>_<бот>.cfg")
		quit(1)
		return
	if not dev.has("run_seed") or not dev.has("bot_seed"):
		print("RUN_CHAIN ERROR: нужны --dev run_seed=N и --dev bot_seed=N")
		quit(1)
		return
	var chain := Chain.new()
	chain.setup(self, dev)
	var t0 := Time.get_ticks_msec()
	var info: Dictionary = await chain.run()
	print("RUN_CHAIN wall_s=%.1f" % ((Time.get_ticks_msec() - t0) / 1000.0))
	chain.cleanup()
	await process_frame
	quit(1 if String(info.get("reason", "")) == "error" else 0)
