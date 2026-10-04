class_name LegionTopPlate
extends Control
##
## Верхняя плашка-бланк боя (DESIGN_V17 §1 п.2): Котёл · Мана · Армия · Души · Волна.
## Каждый блок: иконка art1 слева; сверху — подпись рукописным и крупное число справа; снизу —
## шкала (Котёл, Мана) или мелкая расшифровка (Армия, Души, Волна). Читается одним взглядом:
## число большое и чистое, шкала даёт «сколько осталось» периферийным зрением.
##
## Рисуется одним `_draw` (без десятка Label): перерисовка каждый кадр — это ~60 примитивов.
## Числа сглажены LegionUi.Meter: полоса плывёт, у Котла при уроне — светлый «хвост» и красная
## вспышка блока, у душ — всплеск числа и «+N» под ним.
##

const ICON := 34.0
const PAD := 6.0
const SEP := 10.0
const CAPTION_FONT := 15
const NUM_FONT := 19
const SMALL_FONT := 15
const BAR_H := 9.0
const GAIN_TIME := 1.4

var world: LegionWorld = null
## Текст второй строки блока «Волна» — его же читает LegionHud._stats (тесты, трассировка).
var wave_hint := ""

var _icons: Dictionary = {}
var _hp := LegionUi.Meter.new(1.0, false)
var _mana := LegionUi.Meter.new(8.0, false)
var _army := LegionUi.Meter.new(1.0, true)
var _souls := LegionUi.Meter.new(1.0, true)
var _wave := LegionUi.Meter.new(1.0, true)
var _shake := 0.0
var _gain := 0
var _gain_t := 0.0
var _last_souls := -1
var _posted := 0
var _free := 0


func setup(w: LegionWorld) -> LegionTopPlate:
	world = w
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = LegionCfg.HUD_PLATE_POS
	var total := PAD * 2.0 + SEP * float(LegionCfg.HUD_BLOCK_W.size() - 1)
	for bw in LegionCfg.HUD_BLOCK_W:
		total += bw
	size = Vector2(total, LegionCfg.HUD_PLATE_H)
	for n in ["hud_cauldron", "hud_mana", "hud_army", "soul", "hud_wave"]:
		_icons[n] = LegionIcons.tex(n)
	world.cauldron_hit.connect(_on_cauldron_hit)
	world.souls_changed.connect(_on_souls)
	_last_souls = world.my_side().souls
	return self


func _on_cauldron_hit(_amount: float) -> void:
	_hp.flash = 1.0
	_shake = 0.3


func _on_souls(v: int) -> void:
	if _last_souls >= 0 and v > _last_souls:
		# убийства идут очередью — копим «+N», пока прежний не погас
		_gain = (_gain if _gain_t > 0.0 else 0) + (v - _last_souls)
		_gain_t = GAIN_TIME
	_last_souls = v


## Счётчики армии — HUD считает раз в REFRESH (LegionHud.tick), плашка только рисует.
func set_army(posted: int, free: int) -> void:
	_posted = posted
	_free = free


func _process(dt: float) -> void:
	if world == null:
		return
	visible = world.phase == LegionWorld.Phase.BATTLE
	_hp.update(world.my_side().cauldron_hp, dt)
	_mana.update(world.my_field().mana, dt)
	_army.update(float(world.army_alive(world.local_side)), dt)
	_souls.update(float(world.my_side().souls), dt)
	var wr := world.wave_runner
	_wave.update(float(wr.wave_no()) if wr != null else 0.0, dt)
	_shake = maxf(0.0, _shake - dt)
	_gain_t = maxf(0.0, _gain_t - dt)
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	LegionUi.draw_blank(self, Rect2(Vector2.ZERO, size))
	var x := PAD
	var widths := LegionCfg.HUD_BLOCK_W
	_block_cauldron(Rect2(x, 0.0, widths[0], size.y))
	x += widths[0] + SEP
	_block_mana(Rect2(x, 0.0, widths[1], size.y))
	x += widths[1] + SEP
	_block_army(Rect2(x, 0.0, widths[2], size.y))
	x += widths[2] + SEP
	_block_souls(Rect2(x, 0.0, widths[3], size.y))
	x += widths[3] + SEP
	_block_wave(Rect2(x, 0.0, widths[4], size.y))
	# разделители — пунктир чернилами, как графы бланка
	x = PAD
	for i in widths.size() - 1:
		x += widths[i] + SEP * 0.5
		draw_dashed_line(Vector2(x, 7.0), Vector2(x, size.y - 7.0), LegionUi.INK_FAINT, 1.0, 3.0)
		x += SEP * 0.5


## Иконка блока, подпись и число в первой строке; возвращает прямоугольник второй строки.
func _head(r: Rect2, icon: String, caption: String, value: String, col: Color, bump: float,
		icon_off: Vector2 = Vector2.ZERO, cap_col: Color = LegionUi.TEXT_DIM) -> Rect2:
	var tex: Texture2D = _icons.get(icon)
	var ir := Rect2(r.position + Vector2(-2.0, (r.size.y - ICON) * 0.5) + icon_off,
		Vector2(ICON, ICON))
	if tex != null:
		draw_texture_rect(tex, ir, false)
	var tx := r.position.x + ICON + 2.0
	LegionUi.draw_text(self, Vector2(tx, r.position.y + 18.0), caption, CAPTION_FONT,
		cap_col, LegionUi.FONT_TITLE)
	LegionUi.draw_number(self, Vector2(r.end.x - 2.0, r.position.y + 20.0), value, NUM_FONT, col,
		bump, true)
	return Rect2(tx, r.position.y + 25.0, r.end.x - tx - 2.0, BAR_H)


func _block_cauldron(r: Rect2) -> void:
	var cmax := maxf(1.0, world.my_side().cauldron_max)
	var frac := _hp.shown / cmax
	if _hp.flash > 0.0:
		draw_rect(r.grow_individual(2.0, -3.0, 2.0, -3.0), Color(LegionUi.BAD, 0.35 * _hp.flash), true)
	var shake := Vector2(sin(_shake * 90.0), 0.0) * 3.0 * (_shake / 0.3)
	var col := LegionUi.TEXT.lerp(LegionUi.BAD, _hp.flash)
	if frac < 0.3:
		col = LegionUi.BAD
	# «Схватка» (P5c): два Котла — свой подписан и окрашен цветом своей стороны, как маркеры
	var row := _head(r, "hud_cauldron", "Ваш Котёл" if world.pvp else "Котёл",
		"%d" % ceili(world.my_side().cauldron_hp), col, _hp.flash, shake,
		PvpRules.marker_color(world.local_side) if world.pvp else LegionUi.TEXT_DIM)
	var bar_col := Color(0.42, 0.9, 0.4).lerp(Color(1.0, 0.8, 0.3),
		clampf((0.7 - frac) / 0.4, 0.0, 1.0))
	if frac < 0.3:
		bar_col = LegionUi.BAD
	LegionUi.draw_bar(self, row, frac, bar_col, _hp.ghost / cmax, _hp.flash)


func _block_mana(r: Rect2) -> void:
	var mmax := maxf(1.0, world.my_field().mana_max)
	var row := _head(r, "hud_mana", "Мана", "%d" % int(world.my_field().mana), LegionUi.TEXT,
		_mana.bump)
	LegionUi.draw_bar(self, row, _mana.shown / mmax, LegionUi.MANA, _mana.ghost / mmax)


func _block_army(r: Rect2) -> void:
	var row := _head(r, "hud_army", "Армия", "%d" % world.army_alive(world.local_side),
		LegionUi.TEXT, _army.bump)
	LegionUi.draw_text(self, Vector2(row.position.x, row.end.y + 3.0),
		"в строю %d · свободно %d" % [_posted, _free], SMALL_FONT, LegionUi.TEXT_DIM)


func _block_souls(r: Rect2) -> void:
	var row := _head(r, "soul", "Души", "%d" % world.my_side().souls, UiStyle.SOUL.lightened(0.55),
		_souls.bump)
	if _gain_t > 0.0 and _gain > 0:
		var a := clampf(_gain_t / 0.4, 0.0, 1.0)
		LegionUi.draw_text(self, Vector2(row.end.x, row.end.y + 3.0), "+%d" % _gain, SMALL_FONT,
			Color(LegionUi.GOLD, a), LegionUi.FONT_TEXT, true)


func _block_wave(r: Rect2) -> void:
	var wr := world.wave_runner
	var value := "%d/%d" % [wr.wave_no(), wr.total()] if wr != null else "-"
	var row := _head(r, "hud_wave", "Волна", value, LegionUi.TEXT, _wave.bump)
	var col := LegionUi.TEXT_DIM
	if wr != null and not wr.held:
		var left := wr.next_start_in()
		if left >= 0.0 and is_finite(left) and left <= LegionCfg.HUD_THREAT_LEAD:
			col = LegionUi.GOLD
	LegionUi.draw_text(self, Vector2(row.position.x, row.end.y + 3.0), wave_hint, SMALL_FONT, col)
