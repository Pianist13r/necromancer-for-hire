extends SceneTree
## A1 (item 5): подключение AmendmentRuntime к настоящему LegionWorld. Правило «Копия верна»
## (carbon_copy → эхо) срабатывает через мир._step(dt), а не прямой tick helper'а: за задержку
## 0.6 с Ку наносит второй разряд в пол-урона. Тот же сид без поправки его не даёт; PvP-мир с той
## же сохранённой поправкой ведёт себя как без неё (helper сам отсеивает PvP).

const LAB := Vector2(760, 120)
const DT := 1.0 / 60.0
const ECHO_FRAMES := 42   # 0,7 с: эхо срабатывает на 0,6 с — второй разряд уже нанесён
const FOE_HP := 900.0
const SAVE := "user://legion_amendment_world_test.cfg"

var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL: ", label)


## Свежий мир на сцену; _build() в _ready ставит amendment_runtime как узел-помощник (wiring),
## подписки на сигналы ставит start_map() вызовом amendment_runtime.setup().
func _world() -> LegionWorld:
	var wd := LegionWorld.new()
	root.add_child(wd)
	await process_frame
	return wd


## Покорная цель — та же, что в legion_amendment_runtime_test: неподвижна, чтобы замер эха не
## путался с её собственным движением или атакой.
func _foe(wd: LegionWorld, at: Vector2) -> Foe:
	var f := wd.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = FOE_HP
	wd.grid.rebuild()
	return f


## Один прогон эхо-сценария: каст Ку по цели и ECHO_FRAMES шагов мира. Возвращает замеры после
## каста и после шагов; единственное, что меняет HP между ними — второй разряд эха. campaign —
## миру читать doctrine забега; иначе строим «Схватку», где поправки забега не действуют (mods
## пусты, in_campaign=false), даже если сохранение их держит.
func _echo_run(campaign: bool, ids: Array[StringName]) -> Dictionary:
	var wd := await _world()
	Campaign.set_save_path(SAVE)
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()
	for id in ids:
		Campaign.add_upgrade(id)
	if campaign:
		wd.in_campaign = true
		wd.mods = Campaign.active_mods()
		wd.battle_preparation = {}
		wd.dev = {"no_waves": "1", "spawn_units": "0"}
		wd.start_map("_gray")
	else:
		wd.in_campaign = false
		wd.mods = {}   # «Схватка» не читает поправки забега ни из mods, ни через rules
		wd.battle_preparation = {}
		wd.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
		wd.start_map("pvp:duel")
	wd.set_process(false)
	wd.set_physics_process(false)
	var f := _foe(wd, LAB)
	var cast_ok := wd.hero.cast(LegionHero.SLOT_Q, LAB)
	var after_cast := f.hp
	var hits: Array = wd.hero.last_cast.get("hits", [])
	var first_dmg := float(hits[0].get("dmg", 0.0)) if not hits.is_empty() else 0.0
	for _i in ECHO_FRAMES:
		wd._step(DT)
	var res := {
		"cast": cast_ok, "after_cast": after_cast, "after_steps": f.hp,
		"first_dmg": first_dmg, "echoes": int(wd.stats.get("amendment_echoes", 0)),
		"damage": float(wd.stats.get("amendment_damage", 0.0)),
		"rules": wd.amendment_runtime.rules.size(),
	}
	wd.queue_free()
	await process_frame
	return res


func _run() -> void:
	# 1) Кампания без поправки — база: Ку бьёт один раз, второго разряда нет.
	var base := await _echo_run(true, [])
	_check(base["cast"], "база: Ку кастуется")
	_check(is_equal_approx(FOE_HP - base["after_cast"], base["first_dmg"]),
		"база: первый разряд реально уменьшил HP")
	_check(base["rules"] == 0, "база: правил в мире нет")
	_check(is_equal_approx(base["after_steps"], base["after_cast"]),
		"база: за 0,7 с тиков нового урона нет")
	_check(base["echoes"] == 0, "база: эхо не учтено")

	# 2) Кампания с поправкой-правилом — тот же сид, эхо приходит через мир._step().
	var amended := await _echo_run(true, [&"carbon_copy"])
	_check(amended["cast"], "поправка: Ку кастуется (мана дороже, но хватает)")
	_check(amended["rules"] == 1, "поправка: правило эха подписано на мир")
	_check(amended["echoes"] == 1, "поправка: мир выдал один второй разряд")
	_check(is_equal_approx(amended["after_cast"] - amended["after_steps"],
		amended["first_dmg"] * 0.5), "поправка: второй разряд — половина первого удара")
	_check(is_equal_approx(amended["damage"], amended["first_dmg"] * 0.5),
		"поправка: учтён фактический урон эха")
	_check(base["after_steps"] > amended["after_steps"],
		"бой с поправкой измеримо отличается от боя без неё (тот же сид)")

	# 3) PvP с той же сохранённой поправкой — поведение как без поправки.
	var pvp := await _echo_run(false, [&"carbon_copy"])
	_check(pvp["rules"] == 0, "PvP: doctrine забега в мир не подписана")
	_check(is_equal_approx(pvp["after_steps"], pvp["after_cast"]),
		"PvP: второго разряда нет — как без поправки")
	_check(pvp["echoes"] == 0, "PvP: эхо не учтено")

	print("AMENDMENT WORLD: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)