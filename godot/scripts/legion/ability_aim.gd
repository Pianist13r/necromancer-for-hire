class_name LegionAbilityAim
extends RefCounted
##
## Прицел способностей Ку/Дубль-вэ/Е и подписи «что произошло» (медленная сессия clarity,
## 26.09.2026). Игорь: «надо ещё сделать, чтобы понятнее было, что обилки делают в целом».
##
## Раньше Q/W/E кастовали мгновенно по нажатию — игрок не видел заранее, кого ударит, поднимет
## или ускорит, и не видел, что навык сделал. Теперь так же, как «Сбор» на R: клавиша зажата —
## у курсора круг, отметки под целями и подпись; отпустил — каст в точку отпускания. Быстрое
## нажатие-отпускание кастует, как раньше. Цели прицела берутся ТЕМИ ЖЕ функциями героя, что и
## каст (q_targets, w_corpses, e_targets), — превью не может соврать.
##
## Числа — из LegionCfg и героя (ранг, перки): другая ветка может поменять баланс, подписи не
## устаревают. Свои константы вида — здесь, а не в LegionCfg: там упёрлись в потолок gdlint
## 1000 строк (так же сделано в legion_bot.gd).
##
## Боевых чисел модуль не трогает: каст идёт через hero.cast(), подписи только читают.
##

const NONE := -1
## Имя константы LegionCfg «во сколько раз строй под Авралом держит напор давки» — её добавит
## slow/action; при слиянии поправить имя здесь, если там оно другое.
const E_PRESS_KEY := &"E_PRESS_HOLD_MULT"
## Имена навыков — канон игры (кириллица клавиш).
const NAMES: Array[String] = ["Ку", "Дубль-вэ", "Е"]

# ── вид прицела ─────────────────────────────────────────────────────────────────
## Заливка круга — как у «Сбора» (LegionCfg.RALLY_AIM_FILL), чтобы все прицелы читались одинаково.
const FILL_A := 0.07
const EDGE_A := 0.75
const EDGE_W := 2.0
## Серый — откат или навык закрыт: круг виден, но «не сейчас».
const IDLE_COLOR := Color(0.6, 0.58, 0.66)
## Кольцо под целью и номер цепи Ку.
const MARK_R := 11.0
const MARK_W := 2.5
const MARK_OFFSET := Vector2(0, 2)
## Номер цепи — над головой врага (фигура ~46 px вверх от ступней): на груди его терял спрайт.
const NUM_FONT := 17
const NUM_OFFSET := Vector2(0, -50)
## Пунктир цепи Ку: тоньше молнии настоящего удара, но виден на траве (кадр 26.09: 1,5 px терялся).
const CHAIN_W := 2.0
const CHAIN_A := 0.85
const CHAIN_DASH := 7.0
## Труп Дубль-вэ: пятно и кольцо крупнее обычной отметки — лежачая фигура шире стоячей.
const CORPSE_R := 20.0
const CORPSE_FILL_A := 0.3
## Подписи прицела — под курсором по центру, у нижней кромки круга (не дальше LABEL_DROP_MAX):
## справа-сверху, как у «Сбора», строки ложились прямо на цели цепи у курсора (кадр 26.09 —
## номер «2» под текстом). Для большого круга Е — ближе к курсору, чтобы взгляд не уходил далеко.
const LABEL_DROP_MAX := 100.0
const LABEL_GAP := 20.0
## Строка «что делает» (AbilityBar) — под строкой превью.
const HINT_STEP := 22.0
const LABEL_FONT := 17

# ── подписи каста ─────────────────────────────────────────────────────────────────
## Сколько живёт подпись «что произошло» и на сколько всплывает (реальные секунды).
const NOTE_TIME := 1.1
const NOTE_RISE := 26.0
const NOTE_FONT := 18
## Подпись над целью, а не на ней: иначе её закрывает сам враг.
const NOTE_LIFT := Vector2(0, -34)
const FAIL_COLOR := Color(1.0, 0.45, 0.4)
## B-347: ближе этого по x (центры; «−34» ≈ 34 px) подписи считаются стоящими друг на друге и
## разносятся по вертикали; NOTE_MAX — предел одновременно живых подписей.
const NOTE_SPACE_X := 38.0
const NOTE_MAX := 14

var world: LegionWorld = null
## Какая способность сейчас в прицеле (LegionHero.SLOT_*), NONE — прицела нет.
var slot := NONE
## Подписи «что произошло»: {pos, text, color, t}.
var notes: Array[Dictionary] = []


func setup(w: LegionWorld) -> void:
	world = w
	if not world.hero_cast.is_connected(_on_hero_cast):
		world.hero_cast.connect(_on_hero_cast)


func is_aiming() -> bool:
	return slot != NONE


## Нажата клавиша способности: прицел на неё. Другая клавиша посреди прицела переключает его,
## ничего не кастуя, — отпустить надо уже её.
func start(s: int) -> void:
	slot = s


## Пауза, потеря фокуса, Esc, «Сбор», конец боя: прицел гаснет без каста. Иначе отпускание,
## ушедшее мимо игры, оставило бы круг «залипшим».
func cancel() -> void:
	slot = NONE


## Отпущена клавиша способности s. Каст — только если в прицеле она же (после переключения
## отпускание прежней клавиши ничего не делает). true — каст состоялся.
func release(s: int, at: Vector2) -> bool:
	if slot != s:
		return false
	slot = NONE
	return cast_at(s, at)


## Каст с отзывом: удалось — подписи у целей придут из hero_cast; нет — короткое слово у курсора.
func cast_at(s: int, at: Vector2) -> bool:
	var hero := world.my_hero()
	if hero == null:
		return false
	var cd := hero.cd_left(s)
	var unlocked := hero.is_unlocked(s)
	var paid := world.can_pay_ability(s, world.local_side)
	if world.net_mode:
		# сеть: каст — командой CAST (исполнит мир у обоих клиентов); отказ, видный уже сейчас
		# (закрыто, откат, мана), — подписью сразу, «нет цели» — миганием слота по возвращении
		if unlocked and cd <= 0.0 and paid:
			world.local_cmd(PvpCmd.cast(s, at))
			return true
	elif hero.cast(s, at):
		return true
	var word := ""
	if not unlocked:
		word = "ещё закрыто"
	elif cd > 0.0:
		word = "откат %d с" % ceili(cd)
	elif not paid:
		word = mana_word(s)
	else:
		word = ["нет цели", "нет трупа", "некого"][s]
	_note(at, word, FAIL_COLOR)
	return false


func clear() -> void:
	slot = NONE
	notes.clear()


func tick(dt: float) -> void:
	for i in range(notes.size() - 1, -1, -1):
		notes[i]["t"] = float(notes[i]["t"]) + dt
		if float(notes[i]["t"]) >= NOTE_TIME:
			notes.remove_at(i)


# ── тексты ──────────────────────────────────────────────────────────────────────

## Одна строка «что делает навык» — для подписи у курсора во время прицела (AbilityBar).
func describe(s: int) -> String:
	var hero := world.my_hero()
	if hero == null:
		return ""
	match s:
		LegionHero.SLOT_Q:
			return "Ку — молния по цепи до %d врагов" % hero.q_chain_len()
		LegionHero.SLOT_W:
			var k := hero.w_raise_max()
			if k > 1:
				return "Дубль-вэ — до %d свежих трупов врагов бьются за вас %s с" % [
					k, num(hero.w_duration())]
			return "Дубль-вэ — свежий труп врага бьётся за вас %s с" % num(hero.w_duration())
		_:
			return "Е — Аврал: свои быстрее ×%s и сильнее ×%s%s" % [
				num(LegionCfg.E_SPEED_MULT), num(LegionCfg.E_DMG_MULT), _e_press_tail()]


## D-0927-140: способности не хватает маны — сколько нужно и сколько есть.
func mana_word(s: int) -> String:
	return "мало маны: %d из %d" % [int(world.my_field().mana), roundi(world.ability_mana(s))]


## Подпись прицела в точке at: сколько заденет, либо почему не выйдет.
func preview_text(s: int, at: Vector2) -> String:
	var hero := world.my_hero()
	if not hero.is_unlocked(s):
		return "ещё закрыто"
	if hero.cd_left(s) > 0.0:
		return "откат %d с" % ceili(hero.cd_left(s))
	if not world.can_pay_ability(s, world.local_side):
		return mana_word(s)
	match s:
		LegionHero.SLOT_Q:
			return _preview_q(hero.q_targets(at))
		LegionHero.SLOT_W:
			return _preview_w(hero.w_corpses(at))
		_:
			var n := hero.e_targets(at).size()
			return "ускорит %d на %s с%s" % [n, num(hero.e_duration()), _e_press_tail()] \
				if n > 0 else "некого ускорять"


## Оглушение — по первой цели цепи: босса Ку оглушает только на долю (Q_STUN_BOSS_MULT), и подпись
## не должна обещать ему полное (verifier 26.09: «оглушит на 0,9 с» при 0,27 у Прораба).
func _preview_q(chain: Array[Foe]) -> String:
	var n := chain.size()
	if n == 0:
		return "нет цели рядом"
	var stun := world.my_hero().q_stun()
	if chain[0].type_id == "boss":
		stun *= LegionCfg.Q_STUN_BOSS_MULT
	return "молния: %d %s, оглушит на %s с" % [n, plural(n, "цель", "цели", "целей"), num(stun)]


## Один труп — по имени вида (видно, кого именно), несколько — числом.
func _preview_w(cs: Array[Foe]) -> String:
	var t := num(world.my_hero().w_duration())
	if cs.is_empty():
		return "нет свежего трупа"
	if cs.size() == 1:
		return "поднимет: %s на %s с" % [foe_name(cs[0].type_id), t]
	return "поднимет %d на %s с" % [cs.size(), t]


## Хвост подписи Е про давку: «строй держит вдвое». Множитель добавляет ветка slow/action
## (координатор 26.09); имя константы — E_PRESS_KEY, в одном месте. Нет константы — хвоста
## нет: на ветке без этой механики подпись не обещает того, чего нет.
func _e_press_tail() -> String:
	var m := float(LegionHero.cfg_or(E_PRESS_KEY, 0.0))
	if m <= 1.0:
		return ""
	return ", строй держит вдвое" if is_equal_approx(m, 2.0) else ", строй держит ×%s" % num(m)


## Имя вида врага без значка (подписи волн: «● Зомби» → «Зомби»).
static func foe_name(type: String) -> String:
	var cap := LegionWorld.foe_caption(type)
	var sp := cap.find(" ")
	return cap.substr(sp + 1) if sp >= 0 and sp <= 2 else cap


## Число по-русски: целое — без дробной части, дробное — через запятую (1,5; 1,25).
static func num(x: float) -> String:
	if is_equal_approx(x, roundf(x)):
		return "%d" % roundi(x)
	return str(snappedf(x, 0.01)).replace(".", ",")


static func plural(n: int, one: String, few: String, many: String) -> String:
	var m100 := n % 100
	var m10 := n % 10
	if m100 >= 11 and m100 <= 14:
		return many
	if m10 == 1:
		return one
	if m10 >= 2 and m10 <= 4:
		return few
	return many


# ── отзыв каста ─────────────────────────────────────────────────────────────────

func _on_hero_cast(s: int, _at: Vector2) -> void:
	var hero := world.my_hero()
	if hero == null or int(hero.last_cast.get("slot", NONE)) != s:
		return
	var lc := hero.last_cast
	match s:
		LegionHero.SLOT_Q:
			for h: Dictionary in lc["hits"]:
				_note(h["pos"], "−%d" % roundi(float(h["dmg"])), LegionCfg.Q_COLOR)
		LegionHero.SLOT_W:
			for r: Dictionary in lc["raised"]:
				_note(r["pos"], "в штат!", LegionCfg.W_COLOR)
		_:
			_note(lc["at"], "Аврал ×%s" % num(LegionCfg.E_SPEED_MULT), LegionCfg.E_COLOR)


## B-347 (D-0930-51): подписи цепи Ку по слипшейся куче стояли друг на друге («−944»). Новая
## подпись сдвигается вверх на строку, пока на её месте (на экране) есть живая: разброс по вертикали
## сохраняет каждое число читаемым и каждой цели даёт своё; лишние сверх NOTE_MAX не показываются.
func _note(at: Vector2, text: String, col: Color) -> void:
	if notes.size() >= NOTE_MAX:
		return
	var pos := at + NOTE_LIFT
	var k := 1.0 / (world.view_scale() if world != null and world.pvp else 1.0)
	var step := float(NOTE_FONT + 2) * k       # строка подписи в мире (на экране — прежняя)
	var space_x := NOTE_SPACE_X * k
	for _i in NOTE_MAX:
		var busy := false
		for n in notes:
			var shown: Vector2 = n["pos"] - Vector2(0.0, NOTE_RISE * float(n["t"]) / NOTE_TIME)
			if absf(shown.x - pos.x) < space_x and absf(shown.y - pos.y) < step:
				busy = true
				break
		if not busy:
			break
		pos.y -= step
	notes.append({"pos": pos, "text": text, "color": col, "t": 0.0})


# ── отрисовка (слой Fx мира) ──────────────────────────────────────────────────────

func draw(ci: CanvasItem, at: Vector2) -> void:
	if slot != NONE and world.my_hero() != null and world.phase == LegionWorld.Phase.BATTLE:
		_draw_aim(ci, slot, at)
	for n in notes:
		var k := float(n["t"]) / NOTE_TIME
		var pos: Vector2 = n["pos"] - Vector2(0, NOTE_RISE * k)
		var a := 1.0 - k * k
		_label(ci, pos, String(n["text"]), NOTE_FONT, Color(n["color"], a), true, a)


func _draw_aim(ci: CanvasItem, s: int, at: Vector2) -> void:
	var hero := world.my_hero()
	var ready := hero.is_unlocked(s) and hero.cd_left(s) <= 0.0
	var base: Color = [LegionCfg.Q_COLOR, LegionCfg.W_COLOR, LegionCfg.E_COLOR][s]
	var col := base if ready else IDLE_COLOR
	var radius: float = [LegionCfg.Q_RADIUS, LegionCfg.W_RAISE_RADIUS, world.my_hero().e_radius()][s]
	ci.draw_circle(at, radius, Color(col, FILL_A))
	ci.draw_arc(at, radius, 0.0, TAU, 64, Color(col, EDGE_A), EDGE_W, true)
	if ready:
		match s:
			LegionHero.SLOT_Q:
				_draw_chain(ci, hero.q_targets(at), col)
			LegionHero.SLOT_W:
				for c in hero.w_corpses(at):
					ci.draw_circle(c.position + MARK_OFFSET, CORPSE_R, Color(col, CORPSE_FILL_A))
					ci.draw_arc(c.position + MARK_OFFSET, CORPSE_R, 0.0, TAU, 28, Color(col, 0.95),
						MARK_W, true)
			_:
				for u in hero.e_targets(at):
					_mark(ci, u.position, col)
	_label(ci, label_anchor(s, at), preview_text(s, at), LABEL_FONT, col, true, 1.0)


## Где подпись превью прицела (центр строки). Строка «что делает» — на HINT_STEP ниже. У нижнего
## края экрана обе строки поднимаются над курсором.
func label_anchor(s: int, at: Vector2) -> Vector2:
	var radius: float = [LegionCfg.Q_RADIUS, LegionCfg.W_RAISE_RADIUS, world.my_hero().e_radius()][s]
	var y := at.y + minf(radius, LABEL_DROP_MAX) + LABEL_GAP
	if y + HINT_STEP > world.view_rect().end.y - 8.0:   # видимый мир («Схватка» — 1600×900)
		y = at.y - minf(radius, LABEL_DROP_MAX) - HINT_STEP
	return Vector2(at.x, y)


## Кольца-номера в порядке удара и тонкий пунктир между ними (путь молнии от первой цели).
func _draw_chain(ci: CanvasItem, chain: Array[Foe], col: Color) -> void:
	for i in range(1, chain.size()):
		ci.draw_dashed_line(chain[i - 1].position, chain[i].position, Color(col, CHAIN_A), CHAIN_W,
			CHAIN_DASH, true, true)
	for i in chain.size():
		var p := chain[i].position
		_mark(ci, p, col)
		_label(ci, p + NUM_OFFSET, "%d" % (i + 1), NUM_FONT, col, true, 1.0)


func _mark(ci: CanvasItem, p: Vector2, col: Color) -> void:
	ci.draw_arc(p + MARK_OFFSET, MARK_R, 0.0, TAU, 20, Color(col, 0.95), MARK_W, true)


## Подпись с тёмной обводкой (B-028: без неё текст теряется среди дерущихся), как подпись превью
## договора. centered — по центру точки (подписи у целей), иначе от точки вправо.
func _label(ci: CanvasItem, pos: Vector2, text: String, size: int, col: Color, centered: bool,
		alpha: float) -> void:
	var font: Font = ThemeDB.fallback_font
	size = PvpView.fs(world, size)   # B-303: на экране прежний размер
	var p := pos
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if centered:
		p.x -= w * 0.5
	# у края экрана подпись не обрезать — сдвигаем внутрь
	var view := world.view_rect()   # видимый мир: в «Схватке» 1600×900 (P5a)
	p.x = clampf(p.x, view.position.x + 6.0, view.end.x - w - 6.0)
	var outline := LegionCfg.CORE_LABEL_OUTLINE_COLOR
	outline.a *= alpha
	ci.draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
		LegionCfg.CORE_LABEL_OUTLINE_W, outline)
	ci.draw_string(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
