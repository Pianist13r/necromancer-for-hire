extends SceneTree
##
## Регресс слоя эффектов LegionFx (26.09.2026):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_fx_test.gd -- --mute
##
## а) бой бота на фиксированном сиде 60 с со слоем и без него (как --dev fx=0) даёт одинаковые
##    итоги мира — эффекты чисто вид и не трогают ни числа боя, ни world.rng;
## б) после массового вызова всех эффектов живых частиц не больше потолка CfgFx.CAP;
## в) файл фона карты разбирается, фон рождается и держится под своим потолком;
## г) без ошибок скрипта (проверяет гейт по логу: SCRIPT ERROR).
## Итог «LEGION FX: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_fx_test.cfg"
const AMB := "user://legion_fx_test_ambient.json"
const DT := 1.0 / 60.0
const BATTLE_S := 60.0

var w: LegionWorld
var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	var fx := w.get_node_or_null("LegionFx") as LegionFx
	_check(fx != null, "слой эффектов создан миром по умолчанию")
	if fx == null:
		_finish()
		return
	fx.set_process(false)
	_test_events(fx)
	_test_cap(fx)
	_test_ambient(fx)
	await _test_same_battle(fx)
	_finish()


func _finish() -> void:
	Campaign.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(AMB))
	print("LEGION FX: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Настоящие события мира доходят до слоя: рождение, смерть бойца и врага, удар, Котёл.
func _test_events(fx: LegionFx) -> void:
	print("— события мира рождают частицы")
	w.dev["no_waves"] = "1"
	w.start_map("fork")
	fx.tick(DT)
	# стартовая армия (десятки бойцов) родилась внутри start_map — колец за неё нет, живо
	# разве что пузырёк Котла
	_check(fx.live_count() <= 2, "старт карты: стартовая армия колец не даёт (%d)"
		% fx.live_count())
	var n0 := fx.live_count()
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(500, 600))
	fx.tick(DT)
	_check(fx.live_count() > n0, "рождение бойца: %d → %d" % [n0, fx.live_count()])
	n0 = fx.live_count()
	u.take_damage(1000.0, u.position + Vector2(10, 0))
	_check(fx.live_count() > n0, "смерть бойца: косточки и пыль (%d)" % fx.live_count())
	var p := Vector2(600, 470)
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([p, p + Vector2(-2, 0)]), p)
	n0 = fx.live_count()
	f.take_damage(1000.0, p + Vector2(10, 0))
	_check(fx.live_count() > n0, "смерть врага: пыль и душа (%d)" % fx.live_count())
	n0 = fx.live_count()
	w.damage_cauldron(0.0)
	_check(fx.live_count() > n0, "удар по Котлу: брызги (%d)" % fx.live_count())
	var v: CharView = w.units[0].view if not w.units.is_empty() else null
	n0 = fx.live_count()
	if v != null:
		v.react_hit()
		v.react_hit()
	_check(fx.live_count() == n0 + 1, "удар по виду: одна искра, повтор в кулдауне")
	# натиск: бегущий боец поднимает пыль (опрос раз в CHARGE_SCAN)
	fx.clear_all()
	var runner := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(400, 600))
	fx.tick(DT)
	fx.clear_all()
	runner.start_charge(Vector2.RIGHT)
	var charging := runner.state == Legionnaire.State.CHARGE
	# мир не шагает — боец так и стоит в натиске; за 3 с клубов ~CHARGE_RATE×3, а не каждый кадр
	var dust: LegionFxPool = fx.get("_dust")
	var puffs := 0
	for k in roundi(3.0 / DT):
		var before := dust.n
		fx.tick(DT)
		puffs += maxi(0, dust.n - before)
	_check(charging and puffs >= 2 and puffs <= 16, "натиск: клубы пыли у ног, редко (%d за 3 с)"
		% puffs)
	# победа — листопад идёт потоком, не разом
	fx.clear_all()
	w.force_end(true)
	for k in 30:
		fx.tick(DT)
	_check(fx.live_count() > 0, "победа: листки летят (%d)" % fx.live_count())


func _test_cap(fx: LegionFx) -> void:
	print("— пауза и потолок частиц")
	w.dev["no_waves"] = "1"
	w.start_map("fork")
	w.set_paused(true)
	_check(not fx.can_process(), "на паузе слой стоит вместе с персонажами")
	w.set_paused(false)
	_check(fx.can_process(), "после паузы слой идёт")
	var pos := Vector2(640, 360)
	for k in 300:
		fx.emit_foe_death(pos, 40.0, k % 10 == 0)
		fx.emit_bones(pos, 36.0)
		fx.emit_spawn(pos)
		fx.emit_cauldron_splash()
		fx.emit_gate(pos)
		fx.emit_breach(pos)
		fx.emit_paper()
		fx.emit_dark_smoke()
		fx.emit_bubble()
		fx.emit_dust(pos, 3)
	_check(fx.live_count() == CfgFx.CAP, "живых %d = потолку %d" % [fx.live_count(), CfgFx.CAP])
	for k in 20:
		fx.tick(DT)
		fx.emit_foe_death(pos, 40.0, false)
	_check(fx.live_count() <= CfgFx.CAP, "под нагрузкой не выше потолка: %d" % fx.live_count())
	for k in roundi(6.0 / DT):
		fx.tick(DT)
	_check(fx.live_count() < 20, "через 6 с всё отгорело: %d" % fx.live_count())


func _test_ambient(fx: LegionFx) -> void:
	print("— фон карты")
	_check(not fx.load_ambient("user://нет_такого_файла.json"), "нет файла — нет фона")
	var data := {
		"glows": [{"pos": [606, 222], "r": 22, "color": "ffb060", "flicker": 0.3}],
		"embers": [{"rect": [880, 380, 60, 20], "rate": 30.0, "color": "ff7a30"}],
		"fog": [{"rect": [0, 120, 200, 520], "count": 4, "color": "c8d2e8", "alpha": 0.12,
			"drift": [6, 0]}],
		"wisps": [{"rect": [80, 560, 220, 120], "count": 3, "color": "7fffd8"}],
		"water": [{"poly": [[380, 330], [470, 330], [470, 380], [380, 380]], "rate": 200,
			"color": "e0f6ff"}],
	}
	var fa := FileAccess.open(AMB, FileAccess.WRITE)
	fa.store_string(JSON.stringify(data))
	fa.close()
	_check(fx.load_ambient(AMB), "файл фона разобран")
	_check(fx.glow_count() == 1, "ореол свечи: %d" % fx.glow_count())
	# 4 клочка тумана + 3 огонька по два (ореол и ядро)
	_check(fx.ambient_count() == 10, "туман и огоньки сразу на месте: %d" % fx.ambient_count())
	for k in roundi(3.0 / DT):
		fx.tick(DT)
	_check(fx.ambient_count() > 10 and fx.ambient_count() <= CfgFx.AMBIENT_CAP,
		"угли и блики идут, под потолком %d: %d" % [CfgFx.AMBIENT_CAP, fx.ambient_count()])
	fx.load_ambient("user://нет_такого_файла.json")
	_check(fx.ambient_count() == 0 and fx.glow_count() == 0, "смена карты снимает фон")


## Итог боя бота со слоем и без него совпадает до числа.
func _test_same_battle(fx: LegionFx) -> void:
	print("— эффекты не влияют на бой")
	var with_fx := _battle(fx)
	fx.get_parent().remove_child(fx)
	fx.free()
	await process_frame
	_check(w.get_node_or_null("FxGround") == null, "слой земли ушёл вместе со слоем")
	_check(not CharView.hit_hook.is_valid(), "крючок удара снят")
	var without := _battle(null)
	print("    со слоем: ", with_fx)
	print("    без слоя: ", without)
	_check(int(with_fx["kills"]) > 0, "в бою были убитые (%d)" % int(with_fx["kills"]))
	_check(with_fx == without, "итоги мира совпадают")


func _battle(fx: LegionFx) -> Dictionary:
	w.dev.erase("no_waves")
	w.args["bot"] = "selective"
	seed(7)
	w.start_map("fork")
	for k in roundi(BATTLE_S / DT):
		w._step(DT)
		if fx != null:
			fx.tick(DT)
		if w.phase != LegionWorld.Phase.BATTLE:
			break
	return {"t": snappedf(w.now, 0.001), "kills": int(w.stats["kills"]),
		"lost": int(w.stats["lost"]), "hp": snappedf(w.cauldron_hp, 0.001),
		"units": w.army_alive(), "foes": w.foes.size(), "souls": w.souls,
		"mana": snappedf(w.contracts.mana, 0.001), "rng": w.rng.state}
