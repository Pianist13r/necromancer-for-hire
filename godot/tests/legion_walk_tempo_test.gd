extends SceneTree
## B-206: темп клипа walk следует за ФАКТИЧЕСКОЙ скоростью сущности (рельеф, замедление печатью),
## а удар свой темп не меняет — иначе сдвинулся бы кадр контакта и урон.
##   при расчётной скорости множитель 1,0; при ×0,5 — примерно 0,5; на сильном замедлении —
##   пол WALK_TEMPO_MIN, на ускорении — потолок WALK_TEMPO_MAX; клип атаки идёт с базовым темпом
##   и кадр контакта наступает на том же кадре, что без замедления; у персонажа без walk_speed
##   темп постоянный.
## Запуск: ... --fixed-fps 60 --script res://tests/legion_walk_tempo_test.gd -- --mute

const DT := 1.0 / 60.0

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _make(char_id: String) -> Array:
	var holder := Node2D.new()
	root.add_child(holder)
	var view := CharView.new()
	holder.add_child(view)
	view.setup(char_id, 42.0)
	view.set_locomotion(1.0)
	return [holder, view]


## Шагает holder со скоростью v px/с frames кадров (позиция — как у сущности: шаг за кадр).
func _walk(holder: Node2D, v: float, frames: int) -> void:
	for i in frames:
		holder.position.x += v * DT
		await process_frame


## Кадров от старта атаки до контакта после ходьбы на скорости v.
func _frames_to_contact(char_id: String, v: float) -> Array:
	var made := _make(char_id)
	var holder: Node2D = made[0]
	var view: CharView = made[1]
	var got := [0]
	view.contact.connect(func(_s: StringName) -> void: got[0] = 1)
	await _walk(holder, v, 60)
	var tempo_before := view.walk_tempo()
	view.play_once(&"attack")
	var scale_at_start := view.clip_speed_scale()
	var n := 0
	while got[0] == 0 and n < 120:
		await process_frame
		n += 1
	var scale_end := view.clip_speed_scale()
	holder.queue_free()
	return [n, tempo_before, scale_at_start, scale_end]


func _run() -> void:
	var ref := float(CfgAnim.CHARS["clerk"]["walk_speed"])
	var made := _make("clerk")
	var holder: Node2D = made[0]
	var view: CharView = made[1]
	await _walk(holder, ref, 90)
	_check(absf(view.walk_tempo() - 1.0) < 0.03, "расчётная скорость: темп %.3f ≈ 1" % view.walk_tempo())
	_check(absf(view.clip_speed_scale() - 1.0) < 0.03, "клип идёт с темпом %.3f" % view.clip_speed_scale())
	await _walk(holder, ref * 0.5, 90)
	_check(absf(view.walk_tempo() - 0.5) < 0.03, "замедление ×0,5: темп %.3f ≈ 0,5" % view.walk_tempo())
	_check(absf(view.clip_speed_scale() - 0.5) < 0.03, "клип идёт с темпом %.3f" % view.clip_speed_scale())
	await _walk(holder, ref * 0.15, 90)
	_check(is_equal_approx(view.walk_tempo(), CfgAnim.WALK_TEMPO_MIN),
		"сильное замедление: темп %.3f = пол %.2f" % [view.walk_tempo(), CfgAnim.WALK_TEMPO_MIN])
	await _walk(holder, ref * 3.0, 90)
	_check(is_equal_approx(view.walk_tempo(), CfgAnim.WALK_TEMPO_MAX),
		"ускорение: темп %.3f = потолок %.2f" % [view.walk_tempo(), CfgAnim.WALK_TEMPO_MAX])
	# остановка: темп сброшен, покой с базовым темпом
	view.set_locomotion(0.0)
	_check(view.walk_tempo() == 1.0, "остановка сбрасывает темп")
	holder.queue_free()

	var full: Array = await _frames_to_contact("clerk", ref)
	var slow: Array = await _frames_to_contact("clerk", ref * 0.5)
	_check(float(slow[1]) < 0.6, "перед ударом при ×0,5 walk шёл с темпом %.2f" % float(slow[1]))
	_check(is_equal_approx(float(slow[2]), 1.0) and is_equal_approx(float(slow[3]), 1.0),
		"темп клипа attack не тронут: %.2f → %.2f" % [float(slow[2]), float(slow[3])])
	_check(int(slow[0]) == int(full[0]) and int(full[0]) > 0,
		"кадр контакта на том же кадре: %d при ×0,5 против %d при ×1" % [int(slow[0]), int(full[0])])

	# без walk_speed (скелет) темп постоянный
	var sk := _make("skeleton")
	await _walk(sk[0], 35.0, 90)
	var sk_view: CharView = sk[1]
	_check(sk_view.walk_tempo() == 1.0 and is_equal_approx(sk_view.clip_speed_scale(), 1.0),
		"персонаж без walk_speed: темп постоянный")
	(sk[0] as Node2D).queue_free()

	# walk_speed рядом с расчётом из боевого конфига (не разошлись ли числа)
	for kind: StringName in LegionCfg.UNIT_KINDS:
		if kind == &"clerk":
			_check(is_equal_approx(float(LegionCfg.UNIT_KINDS[kind]["speed"]), ref),
				"walk_speed счетовода = скорость в бою (%.0f)" % ref)
	print("LEGION WALK TEMPO: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
