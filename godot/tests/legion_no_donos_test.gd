extends SceneTree
##
## «Донос» из «Схватки» убран целиком (D-1002-09, Игорь 02.10.2026; причина — B-385: после B-379
## матч короче, механика почти без дела). Регресс-тест: на коде с доносом падает.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_no_donos_test.gd -- --mute
##
## 1) классов PvpDonos / PvpDonosButton в проекте нет, у мира и стороны нет полей доноса;
## 2) в HUD «Схватки» нет кнопки «Донос», на экране выбора поля — подсказки про Дэ;
## 3) клавиша Дэ в бою «Схватки» ничего не тратит и никого не шлёт; команда "donos" — отказ
##    «type», сетевой кодек такого типа не знает;
## 4) бот с запасом душ после первой волны не доносит, в его счётчиках ключа donos нет;
## 5) итог матча (pvp_stats) — без ключей donos / donos_souls и без источника урона donos.
## Итог «LEGION NO DONOS: N/M OK»; выход 1 при провале. Код с доносом трогается только
## динамически (get / has_node), чтобы тест разбирался и на старом коде.
##

const SAVE := "user://legion_no_donos_test.cfg"

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
	_test_classes()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	await _test_hud()
	_test_key()
	_test_command()
	_test_bot()
	_test_stats()
	await _test_field_select()
	Campaign.reset()
	print("LEGION NO DONOS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _start(id: String) -> void:
	w.dev = {"spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 3
	w.start_map(id)


func _has_prop(o: Object, prop: String) -> bool:
	for p: Dictionary in o.get_property_list():
		if String(p["name"]) == prop:
			return true
	return false


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	return ev


## Доносы стороны: поле donos_sent, если оно ещё есть (на новом коде его нет — 0).
func _sent(s: PvpSide) -> int:
	return int(s.get("donos_sent")) if _has_prop(s, "donos_sent") else 0


func _test_classes() -> void:
	print("— классы и поля")
	var names: Array[String] = []
	for c: Dictionary in ProjectSettings.get_global_class_list():
		names.append(String(c["class"]))
	_check(not names.has("PvpDonos") and not names.has("PvpDonosButton"),
		"классов PvpDonos / PvpDonosButton нет")
	_check(names.has("PvpBot") and names.has("NetCodec"),
		"контроль: список классов не пуст (PvpBot, NetCodec есть)")


func _test_hud() -> void:
	print("— HUD «Схватки»")
	_start("pvp:duel")
	_check(w.pvp, "контроль: «Дуэль» — это «Схватка»")
	_check(not _has_prop(w, "donos"), "у мира нет поля donos")
	var s0: PvpSide = w.sides[0]
	_check(not _has_prop(s0, "donos_sent") and not _has_prop(s0, "donos_souls")
		and not _has_prop(s0, "donos_ready_at"), "у стороны нет полей donos_*")
	_check(not (s0.cauldron_dmg as Dictionary).has("donos"),
		"урон Котлу без источника donos: %s" % [s0.cauldron_dmg])
	w.phase = LegionWorld.Phase.BATTLE
	await process_frame
	await process_frame
	_check(not _has_prop(w.hud, "pvp_donos"), "у HUD нет поля pvp_donos")
	_check(w.hud.find_child("PvpDonosButton", true, false) == null, "кнопки «Донос» в HUD нет")


func _test_key() -> void:
	print("— клавиша Дэ в бою «Схватки»")
	_start("pvp:duel")
	w.phase = LegionWorld.Phase.BATTLE
	var s0: PvpSide = w.sides[0]
	w.now = 70.0   # после первой волны: прежде здесь донос уже принимался
	s0.souls = 1000
	var foes0 := w.foes.size()
	w._unhandled_input(_key(KEY_D))
	_check(s0.souls == 1000 and _sent(s0) == 0, "Дэ души не тратит (души %d)" % s0.souls)
	for i in 120:
		w.now += 0.5
		if _has_prop(w, "donos") and w.get("donos") != null:
			w.get("donos").call("tick")
	var donos_foes := 0
	for f in w.foes:
		if f.origin.has("donos"):
			donos_foes += 1
	_check(donos_foes == 0 and w.foes.size() == foes0, "проверяющих из доноса нет")


func _test_command() -> void:
	print("— команда и сеть")
	_start("pvp:duel")
	var s0: PvpSide = w.sides[0]
	w.now = 70.0
	s0.souls = 1000
	var r := w.command(0, {"type": "donos"})
	_check(not bool(r.get("ok", true)) and r.get("reason") == "type",
		"команда donos — отказ «type» (%s)" % [r])
	_check(s0.souls == 1000, "души целы")
	_check(not NetCodec.TYPES.has("donos"), "сетевой кодек не знает donos: %s" % [NetCodec.TYPES])


func _test_bot() -> void:
	print("— бот")
	_start("pvp:duel")
	var b := PvpBot.new()
	b.setup(w, 1)
	_check(not b.counts.has("donos"), "в счётчиках бота нет donos: %s" % [b.counts])
	var s1: PvpSide = w.sides[1]
	w.now = 70.0
	s1.souls = 5000
	b.stage = PvpBot.Stage.MARCH
	for i in 40:
		if b.has_method("_donos_step"):
			b.call("_donos_step")
		w.now += 30.0
	_check(_sent(s1) == 0, "бот с 5000 душ не доносит (доносов %d)" % _sent(s1))


func _test_stats() -> void:
	print("— итог матча")
	_start("pvp:duel")
	var st := w.pvp_stats()
	var bad: Array[String] = []
	for row: Dictionary in st["sides"]:
		for k in ["donos", "donos_souls"]:
			if row.has(k):
				bad.append(k)
		if (row.get("dmg", {}) as Dictionary).has("donos"):
			bad.append("dmg.donos")
	_check(bad.is_empty(), "в итоге «Схватки» нет ключей доноса: %s" % [bad])
	_check(JSON.stringify(st).findn("donos") < 0, "строка итога без «donos»")


func _test_field_select() -> void:
	print("— выбор поля")
	var fs := PvpFieldSelect.new()
	root.add_child(fs)
	await process_frame
	_check(fs.find_child("PvpDonosHint", true, false) == null, "подсказки «Дэ — донос» нет")
	var texts: Array[String] = []
	for n in fs.find_children("*", "Label", true, false):
		texts.append((n as Label).text)
	_check(" ".join(texts).findn("донос") < 0, "в надписях экрана нет «донос»")
	fs.queue_free()
