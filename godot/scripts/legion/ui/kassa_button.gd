class_name LegionKassaButton
extends Control
##
## Кнопка «Касса» в HUD одиночного боя (D-1001-01): между плашкой статов и превью волны — то же
## место, где в «Схватке» была кнопка «Донос» (убрана, D-1002-09). На кнопке —
## подпись и курс («20:1»), премия кассы за бой «+N/потолок», штамп клавиши «D» (Дэ). Щелчок и
## клавиша — одна команда LegionWorld.request_kassa.
##
## Мышь ловит только свой прямоугольник (MOUSE_FILTER_STOP): арену не перекрывает. Спрятана вне
## боя, в «Схватке», в переигровке из коллекции и пока обучение держит волны.
##

const CAPTION_FONT := 17
const NUM_FONT := 17
const SMALL_FONT := 13
const BLINK := 0.35

var world: LegionWorld = null
var _left: Control = null
var _blink := 0.0
var _premium: Texture2D = null


func setup(w: LegionWorld, left: Control) -> LegionKassaButton:
	world = w
	_left = left
	name = "LegionKassaButton"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false   # покажет _process, когда идёт одиночный бой
	size = Vector2(LegionCfg.KASSA_BUTTON_W, LegionCfg.HUD_PLATE_H)
	tooltip_text = ("Касса (Дэ): заложить %d душ в премию «Конторы». Заложенное в бою не " \
		+ "вернуть; курс к концу боя хуже; при поражении касса сгорает") % LegionCfg.KASSA_PORTION
	_premium = LegionIcons.tex("premium")
	return self


## Можно ли заложить прямо сейчас (для цвета «готово»).
func ready_now() -> bool:
	return world != null and world.kassa.refusal(world) == ""


## Подпись для тестов и трассировки: «Касса 10:1 · +5/25».
func summary() -> String:
	if world == null:
		return ""
	return "Касса %d:1 · +%d/%d" % [world.kassa.rate(world), world.kassa.earned(),
		LegionCfg.KASSA_CAP]


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		if not bool(world.request_kassa().get("ok", false)):
			_blink = BLINK
		accept_event()


func _process(dt: float) -> void:
	visible = world != null and not world.pvp and world.kassa_allowed \
		and world.phase == LegionWorld.Phase.BATTLE \
		and not (world.tutorial != null and world.tutorial.holding())
	if not visible:
		return
	_blink = maxf(0.0, _blink - dt)
	# посередине между плашкой статов и превью волны
	var x0 := _left.get_global_rect().end.x if _left != null else 812.0
	var x1 := LegionCfg.WAVE_PREVIEW_POS.x
	position = Vector2(roundf((x0 + x1 - size.x) * 0.5), LegionCfg.HUD_PLATE_POS.y)
	queue_redraw()


func _draw() -> void:
	var ok := ready_now()
	var full := world.kassa.earned() >= LegionCfg.KASSA_CAP
	var rect := Rect2(Vector2.ZERO, size)
	LegionUi.draw_blank(self, rect, LegionUi.GOLD if ok else LegionUi.INK_FAINT)
	if _blink > 0.0:
		draw_rect(rect, Color(1.0, 0.2, 0.2, 0.45 * (_blink / BLINK)), true)
	LegionUi.draw_text(self, Vector2(8.0, 18.0), "Касса", CAPTION_FONT,
		LegionUi.GOLD if ok else LegionUi.TEXT_DIM, LegionUi.FONT_TITLE)
	if not full:
		LegionUi.draw_text(self, Vector2(rect.end.x - 6.0, 35.0),
			"%d:1" % world.kassa.rate(world), SMALL_FONT, LegionUi.TEXT, LegionUi.FONT_TEXT, true)
	if _premium != null:
		draw_texture_rect(_premium, Rect2(Vector2(6.0, 21.0), Vector2(16.0, 16.0)), false)
	var col := LegionUi.GOOD if full else LegionUi.GOLD.lightened(0.3)
	LegionUi.draw_number(self, Vector2(24.0, 35.0),
		"+%d/%d" % [world.kassa.earned(), LegionCfg.KASSA_CAP], NUM_FONT, col)
	LegionUi.draw_stamp(self, Vector2(rect.end.x - 8.0, 6.0), "D", LegionUi.STAMP, 13, 0.12,
		18.0)
