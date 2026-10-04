class_name ComboMeter
extends Control
##
## v17 CTL (DESIGN_V17 §2.4): счётчик комбо натисков — «Комбо ×3», под ним множитель урона и душ
## и полоска окна COMBO_WINDOW (сколько осталось до сброса). Всплеск масштабом при росте, гаснет
## при сбросе. Слушает LegionWorld.combo_changed, окно читает world.combo_left() каждый кадр.
##
## Висит на CanvasLayer боевого HUD (мир добавляет, legion_hud.gd не трогаем) слева под верхней
## плашкой (тосты заняты серединой). Оформление — бланк LegionUi. Мышь не перехватывает.
##

const SIZE := Vector2(230.0, 70.0)
const FADE_TIME := 0.6

var world: LegionWorld = null
var _combo := 0
var _mult := 1.0
var _alpha := 0.0
var _tween: Tween = null


func setup(w: LegionWorld) -> void:
	world = w
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = SIZE
	position = LegionCfg.COMBO_METER_POS - SIZE * 0.5
	pivot_offset = SIZE * 0.5
	world.combo_changed.connect(_on_combo_changed)


func _on_combo_changed(combo: int, mult: float) -> void:
	var grew := combo > _combo
	_combo = combo
	if combo >= 2:
		_mult = mult
		_alpha = 1.0
		if grew:
			# «поп»: мгновенный перелёт масштаба и упругий возврат (TRANS_BACK)
			if _tween != null:
				_tween.kill()
			scale = Vector2(1.45, 1.45)
			_tween = create_tween()
			_tween.tween_property(self, "scale", Vector2.ONE, 0.22) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	queue_redraw()


func _process(delta: float) -> void:
	if _combo < 2 and _alpha > 0.0:
		_alpha = maxf(0.0, _alpha - delta / FADE_TIME)
	if _alpha > 0.0:
		queue_redraw()


## Число комбо, которое сейчас показано (0 — ничего не показано). Для тестов и кадров.
func shown_combo() -> int:
	return _combo if _combo >= 2 else 0


func _draw() -> void:
	if _alpha <= 0.0:
		return
	var a := _alpha
	LegionUi.draw_blank(self, Rect2(Vector2.ZERO, SIZE), Color(LegionUi.GOLD, 0.9 * a),
		Color(LegionUi.PAPER, LegionUi.PAPER.a * a))
	var font: Font = UiStyle.FONT_TITLE
	var text := "Комбо ×%d" % _combo if _combo >= 2 else "Комбо"
	var fs := 30
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var at := Vector2((SIZE.x - tw) * 0.5, 34.0)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color(0, 0, 0, 0.8 * a))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(UiStyle.GOLD, a))
	# десятичная запятая: точка у Neucha почти не видна — «×1.2» читалось как «×12»
	var sub := ("урон и души ×%.1f" % _mult).replace(".", ",")
	var small: Font = UiStyle.FONT_TEXT
	var sw := small.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	draw_string(small, Vector2((SIZE.x - sw) * 0.5, 52.0), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
		Color(UiStyle.TEXT_DIM, a))
	# окно комбо: полоска тает к сбросу
	var left := world.combo_left() / LegionCfg.COMBO_WINDOW if _combo >= 2 else 0.0
	var bar := Rect2(14.0, SIZE.y - 11.0, SIZE.x - 28.0, 5.0)
	draw_rect(bar, Color(1, 1, 1, 0.12 * a))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * left, bar.size.y)),
		Color(UiStyle.WARN if left < 0.3 else UiStyle.GOLD, a))
