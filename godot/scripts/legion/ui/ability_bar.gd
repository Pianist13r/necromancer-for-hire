class_name AbilityBar
extends CanvasLayer
##
## Три слота способностей некроманта (DESIGN_V17 §1 п.5) в стиле LegionUi: бланк, иконка art1,
## штамп клавиши латиницей (Q/W/E — как на клавиатуре), имя кириллицей один раз мелко под
## слотом («Ку», «Дубль-вэ», «Е» — канон игры), радиальная заливка отката с секундами, пульс
## «готово» в момент, когда откат кончился, красное мигание отказа, серый вид закрытого слота.
## Отдельный узел, чтобы владение способностями не размазывало чужой файл.
##

const SLOT_SIZE := Vector2(64.0, 64.0)
const GAP := 14.0
const LABELS := ["Ку", "Дубль-вэ", "Е"]
const KEYS := ["Q", "W", "E"]
const BLINK_DUR := 0.35
const ICONS := ["ability_q", "ability_w", "ability_e"]
## Низ по центру занят карточками видов (LegionKindBar) — слоты у правого края.
const MARGIN_RIGHT := 16.0
## Слот над нижним краем: под ним строка имени.
const MARGIN_BOTTOM := 22.0
const NAME_FONT := 14
## v18: слот «Сбор» (R) — слева от Ку; не способность героя, откат — у мира (world.rally_left).
const SLOT_RALLY := 3
## clarity: строка «что делает навык» у курсора во время прицела — под подписью прицела мира
## (место — LegionAbilityAim.label_anchor), чтобы две строки не наезжали.
const AIM_HINT_FONT := 18
const AIM_FRAME_W := 3.0
## D-0927-140: цена в мане на слоте — отступ от угла, радиус капли, кегль числа.
const PRICE_INSET := 5.0
const PRICE_DROP_R := 4.0
const PRICE_FONT := 15

## Рамка общая для слотов; меняется только её цвет при рисовании.
static var _slot_frame: StyleBoxTexture = null

var world: LegionWorld = null

var _root: Control
var _blink: Array[float] = [0.0, 0.0, 0.0]
var _pulse: Array[float] = [0.0, 0.0, 0.0]
var _was_cd: Array[bool] = [false, false, false]
var _icons: Array[Texture2D] = []
var _rally_blink := 0.0
var _hero: LegionHero = null

static func _slot_style() -> StyleBoxTexture:
	if _slot_frame == null:
		_slot_frame = UiStyle.button_style(false, 8.0, 6.0)
	return _slot_frame


## Фон слота: рамка из кэша с тонировкой под состояние (готов — золото, откат — тусклые
## чернила, закрыт — сумрак). Пока SVG не в импорте — прежний векторный бланк.
func _draw_slot_box(rect: Rect2, ink: Color, dark: bool = false) -> void:
	var st := _slot_style()
	if st.texture == null:
		LegionUi.draw_blank(_root, rect, ink,
			Color(0.05, 0.05, 0.05, 0.6) if dark else LegionUi.PAPER, false)
		return
	var tint := Color.WHITE.lerp(Color(ink.r, ink.g, ink.b, 1.0), 0.55)
	tint.a = clampf(ink.a * 1.7, 0.0, 1.0)
	if dark:
		tint = Color(0.5, 0.46, 0.52, 0.8)
	st.modulate_color = tint
	st.draw(_root.get_canvas_item(), rect)


func setup(w: LegionWorld) -> void:
	world = w
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	UiStyle.fill_rect(_root)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_root.draw.connect(_draw_bar)
	for icon_name: String in ICONS:
		_icons.append(LegionIcons.tex(icon_name))
	world.mana_short.connect(_on_mana_short)


## Герой пересоздаётся на каждом start_map (LegionWorld), а панель — один раз: подписка на отказ
## в setup() попадала в «никуда» (героя ещё нет) — красное мигание отказа не показывалось вовсе
## (кадр abilities_denied, линия economy-mana 27.09). Подписываемся на текущего героя.
func _watch_hero() -> void:
	if world == null or world.my_hero() == _hero:
		return
	_hero = world.my_hero()
	if _hero != null:
		_hero.cast_failed.connect(_on_cast_failed)


func _on_cast_failed(slot: int, _reason: StringName) -> void:
	if slot >= 0 and slot < _blink.size():
		_blink[slot] = BLINK_DUR


## D-0927-140: «Сбору» не хватило маны — мигает и его слот (Q/W/E мигают через cast_failed).
func _on_mana_short(slot: int) -> void:
	if slot == SLOT_RALLY:
		_rally_blink = BLINK_DUR


func _process(delta: float) -> void:
	_watch_hero()
	_rally_blink = maxf(0.0, _rally_blink - delta)
	for i in _blink.size():
		_blink[i] = maxf(0.0, _blink[i] - delta)
		_pulse[i] = maxf(0.0, _pulse[i] - delta)
		if world != null and world.my_hero() != null:
			var on_cd := world.my_hero().cd_left(i) > 0.0
			if _was_cd[i] and not on_cd and world.my_hero().is_unlocked(i):
				_pulse[i] = LegionCfg.HUD_READY_PULSE
			_was_cd[i] = on_cd
	_root.queue_redraw()


## v18 «Сбор»: бланк, значок «все сюда» (кольцо и четыре стрелки внутрь), откат, штамп R.
func _draw_rally_slot() -> void:
	var rect := slot_rect(SLOT_RALLY)
	var locked := rally_locked()
	var left := 0.0 if locked else world.rally_left()
	var frac := clampf(left / world.rally_cd_total(world.local_side), 0.0, 1.0)
	var ready := frac <= 0.0 and not locked \
		and world.can_pay_ability(LegionCfg.RALLY_SLOT, world.local_side)
	# закрытый «Сбор» (кампания до «Проходной») — как закрытые Q/W/E: тёмный бланк, серый значок;
	# раньше слот горел золотом «готово», а R молчал (кампания новичка, сессия 180f1168)
	var ink := LegionUi.GOLD if ready else LegionUi.INK_FAINT
	if locked:
		ink = Color(LegionUi.TEXT_DIM, 0.2)
	_draw_slot_box(rect, ink, locked)
	var c := rect.get_center()
	var col := LegionCfg.RALLY_COLOR if ready else Color(0.6, 0.58, 0.66)
	if locked:
		col = Color(0.35, 0.35, 0.35, 0.6)
	_root.draw_arc(c, 20.0, 0.0, TAU, 32, col, 3.0, true)
	for q in 4:
		var d := Vector2.from_angle(PI * 0.5 * float(q) + PI * 0.25)
		var tip := c + d * 7.0
		var side := d.orthogonal() * 5.0
		_root.draw_colored_polygon(PackedVector2Array([tip, tip + d * 9.0 + side,
			tip + d * 9.0 - side]), col)
	_root.draw_circle(c, 3.0, col)
	if frac > 0.0:
		var inner := rect.grow(-4.0)
		LegionUi.draw_pie(_root, inner.get_center(), inner.size.x * 0.5, frac,
			Color(0.02, 0.01, 0.03, 0.62))
		var secs := "%d" % ceili(left)
		var sw := LegionUi.num_font().get_string_size(secs, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		LegionUi.draw_number(_root, inner.get_center() + Vector2(-sw * 0.5, 8.0), secs, 22,
			LegionUi.TEXT)
	if _rally_blink > 0.0:
		_root.draw_rect(rect, Color(1.0, 0.2, 0.2, 0.45 * (_rally_blink / BLINK_DUR)), true)
	_draw_price(rect, LegionCfg.RALLY_SLOT, locked)
	LegionUi.draw_stamp(_root, rect.position + Vector2(rect.size.x - 6.0, 4.0),
		Controls.label(&"rally"),
		Color(LegionUi.TEXT_DIM, 0.4) if locked else LegionUi.STAMP, 14, 0.12, 20.0)
	var nw := LegionUi.FONT_TEXT.get_string_size("Сбор", HORIZONTAL_ALIGNMENT_LEFT, -1,
		NAME_FONT).x
	LegionUi.draw_text(_root, Vector2(c.x - nw * 0.5, rect.end.y + 15.0), "Сбор", NAME_FONT,
		Color(LegionUi.TEXT_DIM, 0.35) if locked else LegionUi.TEXT_DIM)


## «Сбор» закрыт (кампания, карта до открытия R) — слот рисуется закрытым, как Q/W/E.
func rally_locked() -> bool:
	return world != null and not world.rally_unlocked()


## Прямоугольник слота i (экранный) — для тестов и кадров. SLOT_RALLY — слева от Ку.
func slot_rect(i: int) -> Rect2:
	var total_w := SLOT_SIZE.x * 3.0 + GAP * 2.0
	var x0 := LegionCfg.WORLD_SIZE.x - total_w - MARGIN_RIGHT
	var y0 := LegionCfg.WORLD_SIZE.y - SLOT_SIZE.y - MARGIN_BOTTOM
	var col := -1 if i == SLOT_RALLY else i
	return Rect2(Vector2(x0 + col * (SLOT_SIZE.x + GAP), y0), SLOT_SIZE)


func _draw_bar() -> void:
	if world == null or world.my_hero() == null or world.phase != LegionWorld.Phase.BATTLE:
		return
	_draw_rally_slot()
	var hero := world.my_hero()
	for i in 3:
		var rect := slot_rect(i)
		var unlocked := hero.is_unlocked(i)
		var total := hero.cd_total(i)
		var left := hero.cd_left(i) if unlocked else 0.0
		var frac := clampf(left / total, 0.0, 1.0) if total > 0.0 else 0.0
		var ready := unlocked and frac <= 0.0 and world.can_pay_ability(i, world.local_side)
		var ink := LegionUi.GOLD if ready else LegionUi.INK_FAINT
		if not unlocked:
			ink = Color(LegionUi.TEXT_DIM, 0.2)
		_draw_slot_box(rect, ink, not unlocked)
		if _icons[i] != null:
			var tint := Color.WHITE if unlocked else Color(0.35, 0.35, 0.35, 0.6)
			if unlocked and not ready:
				tint = Color(0.6, 0.58, 0.66)
			_root.draw_circle(rect.get_center() + Vector2(0.0, 1.5), 23.0,
				Color(0.025, 0.02, 0.04, 0.55))
			_root.draw_arc(rect.get_center(), 23.0, 0.0, TAU, 48,
				Color(ink, ink.a * 0.24), 1.0, true)
			_root.draw_texture_rect(_icons[i], rect.grow(-8.0), false, tint)
		if unlocked and frac > 0.0:
			var inner := rect.grow(-4.0)
			LegionUi.draw_pie(_root, inner.get_center(), inner.size.x * 0.5, frac,
				Color(0.02, 0.01, 0.03, 0.62))
			var secs := "%d" % ceili(left)
			var sw := LegionUi.num_font().get_string_size(secs, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
			LegionUi.draw_number(_root, inner.get_center() + Vector2(-sw * 0.5, 8.0), secs, 22,
				LegionUi.TEXT)
		if _pulse[i] > 0.0:
			# «готово»: вспышка слота и кольцо, расходящееся наружу
			var k := _pulse[i] / LegionCfg.HUD_READY_PULSE
			_root.draw_rect(rect, Color(1.0, 0.9, 0.6, 0.35 * k), true)
			_root.draw_rect(rect.grow(10.0 * (1.0 - k)), Color(LegionUi.GOLD, k), false, 3.0)
		if _blink[i] > 0.0:
			_root.draw_rect(rect, Color(1.0, 0.2, 0.2, 0.45 * (_blink[i] / BLINK_DUR)), true)
		_draw_price(rect, i, not unlocked)
		_draw_useful(i, rect)
		# штамп клавиши — в правом верхнем углу, наполовину за рамкой
		var aimed := world.ability_aim != null and world.ability_aim.slot == i
		if aimed:
			# clarity: слот в прицеле — золотая рамка, чтобы было видно, какой навык зажат
			_root.draw_rect(rect.grow(3.0), LegionUi.GOLD, false, AIM_FRAME_W)
		LegionUi.draw_stamp(_root, rect.position + Vector2(rect.size.x - 6.0, 4.0),
			Controls.label([&"cast_q", &"cast_w", &"cast_e"][i]),
			LegionUi.STAMP if unlocked else Color(LegionUi.TEXT_DIM, 0.4), 14, 0.12, 20.0)
		var name_col := LegionUi.TEXT_DIM if unlocked else Color(LegionUi.TEXT_DIM, 0.35)
		if aimed:
			name_col = LegionUi.GOLD
		var nw := LegionUi.FONT_TEXT.get_string_size(LABELS[i], HORIZONTAL_ALIGNMENT_LEFT, -1,
			NAME_FONT).x
		LegionUi.draw_text(_root, Vector2(rect.get_center().x - nw * 0.5, rect.end.y + 15.0),
			LABELS[i], NAME_FONT, name_col)
	_draw_aim_hint()


## D-0927-140: цена в мане — в левом нижнем углу слота: капля цвета маны и число. Не хватает —
## то и другое красное (и слот не горит золотом «готово»): видно до нажатия, а не после отказа.
func _draw_price(rect: Rect2, slot: int, locked: bool) -> void:
	if locked:
		return
	var col := LegionUi.MANA if world.can_pay_ability(slot, world.local_side) else LegionUi.BAD
	var base := rect.position + Vector2(PRICE_INSET, rect.size.y - PRICE_INSET)
	_root.draw_circle(base + Vector2(PRICE_DROP_R, -PRICE_DROP_R - 2.0), PRICE_DROP_R + 1.5,
		LegionUi.OUTLINE)
	_root.draw_circle(base + Vector2(PRICE_DROP_R, -PRICE_DROP_R - 2.0), PRICE_DROP_R, col)
	LegionUi.draw_number(_root, base + Vector2(PRICE_DROP_R * 2.0 + 3.0, 0.0),
		"%d" % roundi(world.ability_mana(slot)), PRICE_FONT, col)


## slow/intuit: навык готов и сейчас полезен (LegionIntuit.slot_glow) — слот зовёт: рамка
## цветом навыка пульсирует, пока висит подпись на поле — ярко и с расходящимся кольцом.
func _draw_useful(i: int, rect: Rect2) -> void:
	if world.intuit == null:
		return
	var glow := world.intuit.slot_glow(i)
	if glow <= 0.0:
		return
	var cols: Array[Color] = [LegionCfg.Q_COLOR, LegionCfg.W_COLOR, LegionCfg.E_COLOR]
	var t := float(Time.get_ticks_msec()) * 0.001
	var pulse := 0.5 + 0.5 * sin(t * IntuitCfg.SLOT_PULSE_RATE)
	var col := Color(cols[i], glow * (0.55 + 0.45 * pulse))
	_root.draw_rect(rect.grow(4.0 + 3.0 * pulse * glow), col, false, 3.0 + 2.0 * glow)
	if glow >= 1.0:
		_root.draw_rect(rect, Color(cols[i], 0.18 * pulse), true)


## clarity (26.09): пока Q/W/E зажата — у курсора, под подписью прицела, строка «что делает
## навык» (текст и числа — LegionAbilityAim.describe, место — label_anchor). Рисуется слоем HUD:
## _root не ловит мышь (MOUSE_FILTER_IGNORE), черчение договоров не рвётся.
func _draw_aim_hint() -> void:
	var aim := world.ability_aim
	if aim == null or not aim.is_aiming():
		return
	var text := Controls.text(aim.describe(aim.slot))
	var font: Font = LegionUi.FONT_TEXT
	var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, AIM_HINT_FONT)
	# якорь — точка мира (подпись прицела рисуется в мире), строка — на слое HUD: в экран (P5a)
	var at := world.world_to_screen(aim.label_anchor(aim.slot, world.aim_pos())) \
		+ Vector2(-size.x * 0.5, LegionAbilityAim.HINT_STEP)
	# у краёв экрана строку не обрезать — сдвигаем внутрь
	at.x = clampf(at.x, 6.0, LegionCfg.WORLD_SIZE.x - size.x - 6.0)
	_root.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, AIM_HINT_FONT,
		LegionCfg.CORE_LABEL_OUTLINE_W, LegionCfg.CORE_LABEL_OUTLINE_COLOR)
	# светлым, а не золотом: золото терялось на жёлтой траве (кадр aim_e 26.09)
	_root.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, AIM_HINT_FONT, LegionUi.TEXT)
