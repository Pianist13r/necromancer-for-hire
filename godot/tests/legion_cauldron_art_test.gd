extends SceneTree
## B-199 (Игорь 29.09): подложка Котла впечатана в фон карты; на «Архиве» и «Проходной» она
## легла мимо игровой точки. Сдвигаем только картинку (map["cauldron_art"]): игровая точка, к
## которой ведут дороги и трассы, стоит на месте — иначе падает legion_maps_test.

var w: LegionWorld
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _sprite() -> Sprite2D:
	return w.get("_cauldron") as Sprite2D


func _run() -> void:
	w = LegionWorld.new()
	root.add_child(w)
	w.set_process(false)
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.args["bot"] = "off"
	for spec: Array in [["archive", Vector2(170, 360), Vector2(179, 360)],
			["gatehouse", Vector2(188, 360), Vector2(185, 360)],
			["wasteland", Vector2(200, 400), Vector2(200, 400)]]:
		var id: String = spec[0]
		w.start_map(id)
		_check(w.cauldron_pos == spec[1], "%s: игровая точка Котла на месте %s" % [id, spec[1]])
		_check(w.cauldron_view_pos == spec[2], "%s: картинка Котла в %s" % [id, spec[2]])
		_check(_sprite() != null and _sprite().position == spec[2],
			"%s: спрайт Котла стоит в точке картинки" % id)
	print("LEGION CAULDRON ART: %d/%d OK" % [_checks - _fails, _checks])
	w.queue_free()
	await process_frame
	quit(1 if _fails else 0)
