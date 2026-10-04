class_name PvpTopPlate
extends Control
##
## Плашка «Схватки» справа сверху (P5c, B-302): Котёл соперника и часы матча. Свой Котёл, ману,
## армию, души и отсчёт до волны показывает обычная плашка LegionTopPlate (в PvP её Котёл
## подписан «Ваш Котёл»); панель превью волны в PvP спрятана — она закрывала правый верхний угол
## поля, где стороне 1 выходят дороги. Плашка узкая (одна строка блоков, как у левой) и стоит на
## тех же 40 px высоты: закрывает край поля, а не его середину.
##
## Рисуется одним `_draw`, как LegionTopPlate; числа сглажены LegionUi.Meter.
##

const PAD := 6.0
const SEP := 10.0
const ICON := 34.0
const CAPTION_FONT := 15
const NUM_FONT := 19
const SMALL_FONT := 15
const BAR_H := 9.0
## Ширины блоков: Котёл соперника, часы.
const BLOCK_W: Array[float] = [196.0, 118.0]
## За столько секунд до предела матча часы желтеют: скоро решит процент HP Котла.
const CLOCK_WARN := 60.0

var world: LegionWorld = null

var _hp := LegionUi.Meter.new(1.0, false)
var _icon: Texture2D = null


func setup(w: LegionWorld) -> PvpTopPlate:
	world = w
	name = "PvpTopPlate"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var total := PAD * 2.0 + SEP * float(BLOCK_W.size() - 1)
	for bw in BLOCK_W:
		total += bw
	size = Vector2(total, LegionCfg.HUD_PLATE_H)
	position = Vector2(LegionCfg.WORLD_SIZE.x - LegionCfg.HUD_PLATE_POS.x - total,
		LegionCfg.HUD_PLATE_POS.y)
	_icon = LegionIcons.tex("hud_cauldron")
	return self


## Экранный прямоугольник плашки (телеграф угрозы не ставит маркер под неё); пустой — не видна.
func panel_rect() -> Rect2:
	return get_global_rect() if visible else Rect2()


## Строка-сводка плашек одной строкой: не рисуется, нужна тестам и трассировке —
## «Ваш Котёл 538 · Котёл соперника 600 · Осталось 10:19».
func summary() -> String:
	var r := rival()
	if world == null or r == null:
		return ""
	var limit := world.pvp_match.limit if world.pvp_match != null else PvpRules.MATCH_LIMIT
	return "Ваш Котёл %d · Котёл соперника %d · Осталось %s" % [ceili(world.my_side().cauldron_hp),
		ceili(r.cauldron_hp), PvpView.clock(maxf(0.0, limit - world.now))]


## Сторона-соперник для подписи и цвета: первая не своя (двойка; 3–4 стороны — L3/L4). Своя —
## сторона человека за этим экраном (сеть: local_side; вне сети 0).
func rival() -> PvpSide:
	if world == null:
		return null
	for s in world.sides:
		if s.index != world.local_side:
			return s
	return null


func _process(dt: float) -> void:
	var r := rival() if world != null else null
	visible = r != null and world.pvp and world.phase == LegionWorld.Phase.BATTLE
	if not visible:
		return
	var before := _hp.shown
	_hp.update(r.cauldron_hp, dt)
	if r.cauldron_hp < before - 0.5:
		_hp.flash = 1.0
	queue_redraw()


func _draw() -> void:
	var r := rival()
	if r == null:
		return
	LegionUi.draw_blank(self, Rect2(Vector2.ZERO, size))
	var x := PAD
	_block_rival(Rect2(x, 0.0, BLOCK_W[0], size.y), r)
	x += BLOCK_W[0] + SEP
	_block_clock(Rect2(x, 0.0, BLOCK_W[1], size.y))
	# разделитель — пунктир чернилами, как графы бланка
	var sx := PAD + BLOCK_W[0] + SEP * 0.5
	draw_dashed_line(Vector2(sx, 7.0), Vector2(sx, size.y - 7.0), LegionUi.INK_FAINT, 1.0, 3.0)


func _block_rival(r: Rect2, side: PvpSide) -> void:
	var cmax := maxf(1.0, side.cauldron_max)
	var frac := _hp.shown / cmax
	if _hp.flash > 0.0:
		draw_rect(r.grow_individual(2.0, -3.0, 2.0, -3.0), Color(LegionUi.BAD, 0.35 * _hp.flash),
			true)
	if _icon != null:
		draw_texture_rect(_icon, Rect2(r.position + Vector2(-2.0, (r.size.y - ICON) * 0.5),
			Vector2(ICON, ICON)), false, Color(PvpRules.marker_color(side.index).lerp(
				Color.WHITE, 0.55)))
	var tx := r.position.x + ICON + 2.0
	LegionUi.draw_text(self, Vector2(tx, r.position.y + 18.0), "Котёл соперника", CAPTION_FONT,
		PvpRules.marker_color(side.index), LegionUi.FONT_TITLE)
	var col := LegionUi.BAD if frac < 0.3 else LegionUi.TEXT
	LegionUi.draw_number(self, Vector2(r.end.x - 2.0, r.position.y + 20.0),
		"%d" % ceili(side.cauldron_hp), NUM_FONT, col, _hp.bump, true)
	var bar := Rect2(tx, r.position.y + 25.0, r.end.x - tx - 2.0, BAR_H)
	var bar_col := Color(0.42, 0.9, 0.4).lerp(Color(1.0, 0.8, 0.3),
		clampf((0.7 - frac) / 0.4, 0.0, 1.0))
	if frac < 0.3:
		bar_col = LegionUi.BAD
	LegionUi.draw_bar(self, bar, frac, bar_col, _hp.ghost / cmax, _hp.flash)


func _block_clock(r: Rect2) -> void:
	var limit := world.pvp_match.limit if world.pvp_match != null else PvpRules.MATCH_LIMIT
	var left := maxf(0.0, limit - world.now)
	var warn := left <= CLOCK_WARN
	LegionUi.draw_text(self, Vector2(r.position.x, r.position.y + 18.0), "Осталось",
		CAPTION_FONT, LegionUi.TEXT_DIM, LegionUi.FONT_TITLE)
	LegionUi.draw_number(self, Vector2(r.end.x - 2.0, r.position.y + 20.0), PvpView.clock(left),
		NUM_FONT, LegionUi.GOLD if warn else LegionUi.TEXT, 0.0, true)
	LegionUi.draw_text(self, Vector2(r.position.x, r.end.y - 8.0),
		"решит HP Котла" if warn else "из %s" % PvpView.clock(limit), SMALL_FONT,
		LegionUi.GOLD if warn else LegionUi.TEXT_DIM)
