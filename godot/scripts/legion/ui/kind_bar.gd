class_name LegionKindBar
extends HBoxContainer
##
## Карточки видов договора внизу по центру (DESIGN_V17 §1 п.4): бланк, штамп клавиши 1/2/3,
## иконка art1, название рукописным и цена «12 маны за аршин» (аршин = HUD_ARSHIN_PX линии;
## пиксели игроку не показываем). Выбранная карточка — рамка цветом вида и светлее бумага;
## закрытая — тусклая. Карточки перехватывают только собственный прямоугольник, корень — IGNORE.
## Карточки используют кэш карты: сохранение не читается при обновлении HUD.
##

const BADGE_W := 24.0
const ICON := 36.0
const NAME_FONT := 19
const PRICE_FONT := 15

var world: LegionWorld
var buttons: Array[Button] = []
var _refresh_t := 0.0
var _styles: Array[Dictionary] = []
var _state: Array[int] = []
var _keys: Array[int] = [0, 0, 0]


static func attach(hud: LegionHud, w: LegionWorld) -> LegionKindBar:
	var bar := LegionKindBar.new()
	bar.world = w
	hud.add_child(bar)
	return bar


func _ready() -> void:
	position = LegionCfg.KIND_BAR_POS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 10)
	for i in LegionCfg.KIND_ORDER.size():
		var kind: StringName = LegionCfg.KIND_ORDER[i]
		var core: Color = LegionCfg.UNIT_KINDS[kind]["color"]
		var button := Button.new()
		button.custom_minimum_size = LegionCfg.KIND_CARD_SIZE
		button.focus_mode = Control.FOCUS_NONE
		LegionUi.style_button(button)
		# рамка карточек — общая художественная девятисрезка UiStyle; выбранная — золотая
		# версия, модулированная цветом вида. Держим стили готовыми, чтобы не создавать
		# StyleBox в _process; невыбранная — обычная латунь, без отдельно затемнённого бланка
		# (тусклость закрытых даёт modulate самой кнопки)
		var frame: StyleBoxTexture = UiStyle.button_style(false)
		var sel: StyleBoxTexture = UiStyle.button_style(true)
		sel.modulate_color = Color(core.lightened(0.35), 1.0)
		var dim: StyleBox = frame if frame.texture != null \
			else LegionUi.blank_style(LegionUi.INK_FAINT, LegionUi.PAPER)
		var sel_st: StyleBox = sel if sel.texture != null \
			else LegionUi.blank_style(Color(core.lightened(0.35), 1.0), LegionUi.PAPER_HI)
		_styles.append({
			"normal": dim,
			"hover": button.get_theme_stylebox("hover"),
			"sel": sel_st,
		})
		button.add_theme_stylebox_override("normal", dim)
		_state.append(-1)
		var row := HBoxContainer.new()
		UiStyle.fill_rect(row)
		row.offset_left = 4.0
		row.offset_right = -8.0
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 4)
		button.add_child(row)
		var badge := Control.new()
		badge.custom_minimum_size = Vector2(BADGE_W, 0.0)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(badge)
		var icon := LegionIcons.rect("contract_%s" % String(kind), ICON)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon)
		var col := VBoxContainer.new()
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.add_theme_constant_override("separation", -2)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(col)
		col.add_child(LegionUi.label(LegionCfg.KIND_CARD_NAMES[i], NAME_FONT, LegionUi.FONT_TITLE,
			LegionUi.TEXT))
		var price := LegionUi.label(_price_text(kind), PRICE_FONT, LegionUi.FONT_TEXT,
			LegionUi.TEXT_DIM)
		price.name = "Price"
		col.add_child(price)
		badge.draw.connect(func() -> void:
			LegionUi.draw_stamp(badge, badge.size * 0.5 + Vector2(2.0, 0.0),
				Controls.label([&"rune_normal", &"rune_frost", &"rune_ash"][i]),
				LegionUi.STAMP if not button.disabled else Color(LegionUi.TEXT_DIM, 0.5), 16, -0.14,
				20.0))
		button.draw.connect(func() -> void:
			if _state[i] == 2:
				var r := Rect2(Vector2(6.0, button.size.y - 7.0), Vector2(button.size.x - 12.0, 4.0))
				button.draw_rect(r, core.lightened(0.35), true)
				var tip := Vector2(button.size.x * 0.5, -3.0)
				button.draw_colored_polygon(PackedVector2Array([tip + Vector2(-8.0, -7.0),
					tip + Vector2(8.0, -7.0), tip]), core.lightened(0.35)))
		button.pressed.connect(func() -> void: world.my_field().set_kind(kind))
		add_child(button)
		buttons.append(button)


## «12 маны за аршин»: цена вида с перком «Мелкий шрифт», округлённая до целого.
func _price_text(kind: StringName) -> String:
	var mult := world.my_field().mana_cost_mult if world != null and world.my_field() != null else 1.0
	var per := Contract.base_price(kind) * mult * LegionCfg.HUD_ARSHIN_PX
	return "%d маны за аршин" % roundi(per)


func _process(dt: float) -> void:
	_refresh_t -= dt
	if _refresh_t > 0.0:
		return
	_refresh_t = LegionCfg.ASSIGN_INTERVAL
	visible = world.phase == LegionWorld.Phase.BATTLE
	for i in buttons.size():
		var kind: StringName = LegionCfg.KIND_ORDER[i]
		var button := buttons[i]
		button.disabled = not bool(world.my_field().unlocked.get(kind, true)) or world.paused
		var selected := not button.disabled and world.my_field().current_kind == kind
		var state := 2 if selected else (0 if button.disabled else 1)
		var key := Controls.key([&"rune_normal", &"rune_frost", &"rune_ash"][i])
		if state == _state[i] and key == _keys[i]:
			continue
		_keys[i] = key
		_state[i] = state
		var st: Dictionary = _styles[i]
		button.add_theme_stylebox_override("normal", st["sel"] if selected else st["normal"])
		button.add_theme_stylebox_override("hover", st["sel"] if selected else st["hover"])
		button.modulate = Color(1.0, 1.0, 1.0, 0.55) if button.disabled else Color.WHITE
		(button.find_child("Price", true, false) as Label).text = _price_text(kind)
		button.queue_redraw()
		for c in button.find_children("*", "Control", true, false):
			(c as Control).queue_redraw()
