class_name LegionItemBar
extends Control
##
## Полоска артефактов забега (левый нижний угол HUD) + вид выпадения + карточка «Артефакт».
##
## Выпадение: артефакт вылетает дугой из носителя, лежит, светясь (успеваешь увидеть, что
## выпало), и сам летит в полоску; на посадке — иконка в полоске, карточка «Артефакт: название —
## эффект» над полоской на CARD_T секунд (без паузы), звук находки и вспышка того, на что он
## действует (items.start_pulse). Механика уже действует с момента выпадения (LegionItems.grant).
## Артефакты забега, загруженные в начале боя, садятся в полоску сразу, без карточек.
##
## Мышь НЕ перехватывается (MOUSE_FILTER_IGNORE — иначе ЛКМ по арене не чертит линию).
## Подсказка при наведении — ручной проверкой позиции курсора (world.mouse_screen():
## последняя позиция из события в экранных координатах, как у прицела способностей).
##
## Часы — реальные секунды, но стоят на паузе и в «игре по переписке» (hold). Вылет и
## подпрыгивание — свой ГСЧ.
##

var world: LegionWorld = null
var owner_side := 0
var inventory: LegionItems = null
## Порядок иконок в полоске (id в порядке посадки) и сколько копий уже «долетело».
var shown: Array[StringName] = []
var shown_counts: Dictionary = {}
var shown_synergies: Array[StringName] = []

var _drops: Array[Dictionary] = []
var _cards: Array[Dictionary] = []
var _card_t := 0.0
var _clock := 0.0
var _punch: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _icons: Dictionary = {}
## Карточки синергий ждут, пока долетит предмет, который набор собрал.
var _pending_syn: Array[Dictionary] = []


func setup(w: LegionWorld, side := 0) -> LegionItemBar:
	world = w
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_rng.randomize()
	bind_side(side)
	w.match_started.connect(func(_id: String) -> void: bind_side(owner_side))
	return self


## Полоска смотрит на инвентарь своей стороны (в одиночке — сторона 0 = world.items);
## вздрагивание значка (_on_fx, vfx-clarity) — тоже только от своих срабатываний.
func bind_side(side: int) -> void:
	if inventory != null:
		inventory.gained.disconnect(_on_gained)
		inventory.synergy_gained.disconnect(_on_synergy)
		inventory.cleared.disconnect(clear)
		inventory.fx_event.disconnect(_on_fx)
	owner_side = side
	inventory = world.items_of(side) if side >= 0 and side < world.sides.size() else null
	clear()
	if inventory == null:
		return
	inventory.gained.connect(_on_gained)
	inventory.synergy_gained.connect(_on_synergy)
	inventory.cleared.connect(clear)
	inventory.fx_event.connect(_on_fx)
	for id in inventory.owned():
		_on_gained(id, Vector2.INF)


func clear() -> void:
	shown.clear()
	shown_counts.clear()
	shown_synergies.clear()
	_pending_syn.clear()
	_drops.clear()
	_cards.clear()
	_card_t = 0.0
	_punch.clear()
	queue_redraw()


## Сколько копий предмета видно в полоске (долетевших).
func shown_count(id: StringName) -> int:
	return int(shown_counts.get(id, 0))


func in_flight() -> int:
	return _drops.size()


## Карточка, что показана сейчас ({} — нет): {title, text, kind}.
func current_card() -> Dictionary:
	return _cards[0] if not _cards.is_empty() else {}


func _icon(id: StringName) -> Texture2D:
	var key := LegionItemDb.icon_name(id)
	if not _icons.has(key):
		_icons[key] = LegionIcons.tex(key)
	return _icons[key]


func _on_gained(id: StringName, at: Vector2) -> void:
	if at == Vector2.INF:
		_land(id)   # выдан без выпадения (--dev items, тест) — сразу в полоску, без карточки
		return
	var eco := Settings.is_economy_graphics()
	var spot := at + Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.4, 0.6)) \
		* CfgItems.DROP_SCATTER
	_drops.append({"id": id, "from": at, "spot": spot, "t": 0.0, "eco": eco})


## Артефакт сработал на поле (item_effects.used) — его значок в полоске вздрагивает: след,
## взрыв или кольцо на поле связаны с иконкой, по которой видно имя и текст (vfx-clarity 29.09,
## Игорь: «остаётся фиолетовый след, ещё непонятный мне»).
func _on_fx(kind: StringName, d: Dictionary) -> void:
	if kind == &"used" and shown.has(StringName(d.get("id", &""))):
		_punch[StringName(d["id"])] = 1.0


func _on_synergy(id: StringName) -> void:
	# карточка синергии встаёт в очередь за карточкой предмета, который набор собрал
	var s := LegionItemDb.synergy(id)
	_pending_syn.append({"id": id, "title": "Синергия: " + String(s["title"]),
		"text": Controls.text(String(s["text"])), "kind": &"synergy"})



func _dur(eco: bool) -> Vector3:
	var k := CfgItems.DROP_ECONOMY_SCALE if eco else 1.0
	return Vector3(CfgItems.DROP_POP_T, CfgItems.DROP_REST_T, CfgItems.DROP_FLY_T) * k


func _process(delta: float) -> void:
	if world == null or world.paused or world.hold:
		return
	_clock += delta
	for i in range(_drops.size() - 1, -1, -1):
		var d := _drops[i]
		d["t"] = float(d["t"]) + delta
		var dur := _dur(bool(d["eco"]))
		if float(d["t"]) >= dur.x + dur.y + dur.z:
			_drops.remove_at(i)
			_land(d["id"], true)
	# синергия, чей последний предмет ещё в полёте, ждёт его посадки
	if not _pending_syn.is_empty() and _drops.is_empty():
		for c in _pending_syn:
			if not shown_synergies.has(c["id"]):
				shown_synergies.append(c["id"])
			_cards.append(c)
		_pending_syn.clear()
	if not _cards.is_empty():
		_card_t += delta
		if _card_t >= CfgItems.CARD_T:
			_cards.remove_at(0)
			_card_t = 0.0
	for k: StringName in _punch.keys():
		_punch[k] = maxf(0.0, float(_punch[k]) - delta * 3.0)
	queue_redraw()


func _land(id: StringName, card := false) -> void:
	if not shown.has(id):
		shown.append(id)
	shown_counts[id] = shown_count(id) + 1
	_punch[id] = 1.0
	if card:
		var e := LegionItemDb.item(id)
		_cards.append({"id": id, "title": "Артефакт: " + String(e["title"]),
			"text": Controls.text(String(e["text"])), "kind": &"item"})
		# импульс на посадке: то, на что артефакт действует, вспыхивает ~1,5 с, и звучит находка
		inventory.start_pulse(id)
		if world.audio != null:
			world.audio.play_item()
	# синергии предметов, выданных без выпадения, — сразу значком
	if _drops.is_empty() and not card:
		for sid in inventory.synergies:
			if not shown_synergies.has(sid):
				shown_synergies.append(sid)
		_pending_syn = _pending_syn.filter(func(c: Dictionary) -> bool:
			return not shown_synergies.has(c["id"]))
	queue_redraw()


# ── Раскладка ───────────────────────────────────────────────────────────────

func slot_count() -> int:
	return mini(shown.size() + shown_synergies.size(), CfgItems.BAR_PER_ROW * CfgItems.BAR_MAX_ROWS)


## B-072: сколько значков не влезло — их собирает последний слот «+N» (0 — всё видно). Раньше
## лишние (и синергии) молча не рисовались.
func overflow() -> int:
	var cap := CfgItems.BAR_PER_ROW * CfgItems.BAR_MAX_ROWS
	var total := shown.size() + shown_synergies.size()
	return total - (cap - 1) if total > cap else 0


func _is_more_slot(i: int) -> bool:
	return overflow() > 0 and i == CfgItems.BAR_PER_ROW * CfgItems.BAR_MAX_ROWS - 1


func slot_rect(i: int) -> Rect2:
	var row := i / CfgItems.BAR_PER_ROW
	var col := i % CfgItems.BAR_PER_ROW
	var at := CfgItems.BAR_ORIGIN + Vector2(col * CfgItems.BAR_STEP, -row * CfgItems.BAR_STEP)
	return Rect2(at, Vector2.ONE * CfgItems.BAR_ICON)


## Куда садится следующий предмет (для дуги полёта): новый id — в конец, известный — в свой слот.
func _target(id: StringName) -> Vector2:
	var i := shown.find(id)
	if i < 0:
		i = shown.size()
	return slot_rect(mini(i, CfgItems.BAR_PER_ROW * CfgItems.BAR_MAX_ROWS - 1)).get_center()


func _strip_top() -> float:
	var rows := maxi(1, ceili(float(maxi(1, slot_count())) / CfgItems.BAR_PER_ROW))
	return CfgItems.BAR_ORIGIN.y - float(rows - 1) * CfgItems.BAR_STEP


## Какой слот под курсором (-1 — ни один).
func hovered_slot() -> int:
	var m := world.mouse_screen()   # панель — на экране; aim_pos() — точка мира (P5a)
	for i in slot_count():
		if slot_rect(i).grow(2.0).has_point(m):
			return i
	return -1


## Текст подсказки слота: {title, text, color}.
func slot_info(i: int) -> Dictionary:
	if _is_more_slot(i):
		var names: Array[String] = []
		for k in range(i, shown.size() + shown_synergies.size()):
			if k < shown.size():
				names.append(String(LegionItemDb.item(shown[k])["title"]))
			else:
				var syn := LegionItemDb.synergy(shown_synergies[k - shown.size()])
				names.append("Синергия: " + String(syn["title"]))
		return {"title": "Ещё %d" % overflow(), "text": ", ".join(names), "sub": "",
			"color": LegionUi.GOLD}
	if i < shown.size():
		var id := shown[i]
		var e := LegionItemDb.item(id)
		var r := LegionItemDb.rarity(id)
		var n := shown_count(id)
		var status := "Постоянно" if bool(e.get("passive", false)) else "Срабатываний: %d" \
			% inventory.activation_count(id)
		return {"title": String(e["title"]) + (" ×%d" % n if n > 1 else ""),
			"text": Controls.text(String(e["text"])), "sub": String(CfgItems.RARITY_TITLE.get(r, ""))
				+ " · " + status,
			"color": CfgItems.RARITY_COLOR.get(r, Color.WHITE)}
	var sid := shown_synergies[i - shown.size()]
	var s := LegionItemDb.synergy(sid)
	var names: Array[String] = []
	for n: String in s["items"]:
		names.append(String(LegionItemDb.item(StringName(n))["title"]))
	return {"title": "Синергия: " + String(s["title"]), "text": Controls.text(String(s["text"])),
		"sub": " + ".join(names), "color": CfgItems.LINK_COLOR}


# ── Рисование ───────────────────────────────────────────────────────────────

func _draw() -> void:
	if world == null or world.phase == LegionWorld.Phase.MENU:
		return
	for i in slot_count():
		_draw_slot(i)
	for d in _drops:
		_draw_drop(d)
	if not _cards.is_empty():
		_draw_card(_cards[0])
	var h := hovered_slot()
	if h >= 0:
		_draw_tip(h)


func _draw_slot(i: int) -> void:
	var rect := slot_rect(i)
	if _is_more_slot(i):
		LegionUi.draw_blank(self, rect, LegionUi.GOLD, LegionUi.PAPER_HI, false, 2.0)
		var more := "+%d" % overflow()
		var w := LegionUi.num_font().get_string_size(more, HORIZONTAL_ALIGNMENT_LEFT, -1,
			CfgItems.BAR_MORE_FONT).x
		LegionUi.draw_number(self, rect.get_center() + Vector2(w * 0.5, CfgItems.BAR_MORE_FONT * 0.35),
			more, CfgItems.BAR_MORE_FONT, LegionUi.TEXT, 0.0, true)
		return
	if i < shown.size():
		var id := shown[i]
		var col: Color = CfgItems.RARITY_COLOR.get(LegionItemDb.rarity(id), Color.WHITE)
		var p := float(_punch.get(id, 0.0))
		var r := rect.grow(p * 4.0)
		LegionUi.draw_blank(self, r, col, LegionUi.PAPER, false, 2.0)
		var tex := _icon(id)
		if tex != null:
			draw_texture_rect(tex, r.grow(-3.0), false)
		if p > 0.0:
			draw_rect(r.grow(3.0), Color(Color.WHITE, p * 0.9), false, 2.0)
		if _in_synergy(id):
			draw_circle(r.position + Vector2(4.0, 4.0), 4.0, CfgItems.LINK_COLOR)
		var n := shown_count(id)
		if n > 1:
			LegionUi.draw_number(self, r.end + Vector2(-2.0, -2.0), "×%d" % n, 14, LegionUi.TEXT,
				0.0, true)
		return
	# значок-связка синергии: два сцепленных кольца на золотом бланке
	LegionUi.draw_blank(self, rect, CfgItems.LINK_COLOR, LegionUi.PAPER_HI, false, 2.0)
	var c := rect.get_center()
	draw_arc(c + Vector2(-5.0, 0.0), 8.0, 0.0, TAU, 20, CfgItems.LINK_COLOR, 3.0, true)
	draw_arc(c + Vector2(5.0, 0.0), 8.0, 0.0, TAU, 20, CfgItems.LINK_COLOR, 3.0, true)


func _in_synergy(id: StringName) -> bool:
	for sid in shown_synergies:
		if (LegionItemDb.synergy(sid)["items"] as Array).has(String(id)):
			return true
	return false


func _draw_drop(d: Dictionary) -> void:
	var id: StringName = d["id"]
	var dur := _dur(bool(d["eco"]))
	var t := float(d["t"])
	var from: Vector2 = d["from"]
	var spot: Vector2 = d["spot"]
	var pos := spot
	var size := CfgItems.DROP_ICON
	var glow := 1.0
	if t < dur.x:
		var k := t / dur.x
		pos = from.lerp(spot, k)
		pos.y -= sin(k * PI) * CfgItems.DROP_ARC_H
		size *= 0.5 + 0.5 * k
	elif t < dur.x + dur.y:
		pos.y -= 4.0 + 3.0 * sin((t - dur.x) * 7.0)
	else:
		var k := (t - dur.x - dur.y) / dur.z
		var e := k * k * k   # ease-in: срывается с места и ускоряется к полоске
		var target := _target(id)
		pos = spot.lerp(target, e)
		pos.y -= sin(k * PI) * 30.0
		size = lerpf(size, CfgItems.BAR_ICON, e)
		glow = 1.0 - k
	var col: Color = CfgItems.RARITY_COLOR.get(LegionItemDb.rarity(id), Color.WHITE)
	if not bool(d["eco"]):
		# кадр 26.09: бледное свечение терялось на светлой дороге — ярче ядро и толще лучи
		var pulse := 0.5 + 0.5 * sin(_clock * 9.0)
		var hot := col.lerp(Color.WHITE, 0.45)
		draw_circle(pos, size * (0.95 + 0.12 * pulse), Color(col, 0.3 * glow))
		draw_circle(pos, size * 0.72, Color(hot, 0.45 * glow))
		for r in 10:
			var ang := TAU * float(r) / 10.0 + _clock * 1.5
			var dir := Vector2(cos(ang), sin(ang))
			draw_line(pos + dir * size * 0.6, pos + dir * size * (1.05 + 0.25 * pulse),
				Color(hot, 0.8 * glow), 3.0, true)
		draw_arc(pos, size * (0.8 + 0.3 * pulse), 0.0, TAU, 32, Color(hot, 0.7 * glow * (1.0 - pulse)),
			2.0, true)
	else:
		draw_arc(pos, size * 0.62, 0.0, TAU, 24, Color(col, 0.9 * glow), 2.0, true)
	var tex := _icon(id)
	if tex != null:
		draw_texture_rect(tex, Rect2(pos - Vector2.ONE * size * 0.5, Vector2.ONE * size), false)


func _draw_card(c: Dictionary) -> void:
	var a := 1.0
	if _card_t < 0.2:
		a = _card_t / 0.2
	elif _card_t > CfgItems.CARD_T - CfgItems.CARD_FADE:
		a = maxf(0.0, (CfgItems.CARD_T - _card_t) / CfgItems.CARD_FADE)
	var sz := CfgItems.CARD_SIZE
	var slide := (1.0 - minf(1.0, _card_t / 0.2)) * 14.0
	var top := _strip_top() - CfgItems.CARD_GAP - sz.y + slide
	var rect := Rect2(Vector2(CfgItems.BAR_ORIGIN.x, top), sz)
	var syn: bool = c["kind"] == &"synergy"
	var col: Color = CfgItems.LINK_COLOR if syn \
		else CfgItems.RARITY_COLOR.get(LegionItemDb.rarity(c["id"]), Color.WHITE)
	LegionUi.draw_blank(self, rect, Color(col, a), Color(LegionUi.PAPER_HI, LegionUi.PAPER_HI.a * a),
		true, 2.5)
	var icon_r := Rect2(rect.position + Vector2(8.0, 9.0), Vector2(40.0, 40.0))
	if not syn:
		var tex := _icon(c["id"])
		if tex != null:
			draw_texture_rect(tex, icon_r, false, Color(1, 1, 1, a))
	else:
		var ic := icon_r.get_center()
		draw_arc(ic + Vector2(-7.0, 0.0), 11.0, 0.0, TAU, 24, Color(col, a), 3.5, true)
		draw_arc(ic + Vector2(7.0, 0.0), 11.0, 0.0, TAU, 24, Color(col, a), 3.5, true)
	var tx := icon_r.end.x + 8.0
	var room := rect.end.x - tx - 8.0
	_fit_text(Vector2(tx, rect.position.y + 24.0), String(c["title"]), 17, Color(col, a),
		LegionUi.FONT_TITLE, room)
	_fit_text(Vector2(tx, rect.position.y + 46.0), String(c["text"]), 16, Color(LegionUi.TEXT, a),
		LegionUi.FONT_TEXT, room)


## Строка в ширину room: не влезла — кегль меньше (до 12), текст не обрезаем.
func _fit_text(at: Vector2, text: String, size: int, color: Color, font: Font, room: float) -> void:
	var s := size
	while s > 12 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s).x > room:
		s -= 1
	LegionUi.draw_text(self, at, text, s, color, font)


func _draw_tip(i: int) -> void:
	var info := slot_info(i)
	var slot := slot_rect(i)
	var w := CfgItems.TIP_W
	var font := LegionUi.FONT_TEXT
	for key in ["title", "text", "sub"]:
		w = maxf(w, font.get_string_size(String(info[key]), HORIZONTAL_ALIGNMENT_LEFT, -1,
			CfgItems.TIP_FONT + 1).x + 20.0)
	var rect := Rect2(Vector2(slot.position.x, _strip_top() - 8.0 - 70.0), Vector2(w, 66.0))
	# ширина экрана — от вьюпорта: у Control под CanvasLayer size бывает нулевым
	rect.position.x = clampf(rect.position.x, 6.0, get_viewport_rect().size.x - rect.size.x - 6.0)
	var col: Color = info["color"]
	LegionUi.draw_blank(self, rect, col, LegionUi.PAPER_HI, true, 2.0)
	LegionUi.draw_text(self, rect.position + Vector2(10.0, 21.0), String(info["title"]),
		CfgItems.TIP_FONT + 2, col, LegionUi.FONT_TITLE)
	LegionUi.draw_text(self, rect.position + Vector2(10.0, 41.0), String(info["text"]),
		CfgItems.TIP_FONT, LegionUi.TEXT)
	LegionUi.draw_text(self, rect.position + Vector2(10.0, 59.0), String(info["sub"]),
		CfgItems.TIP_FONT - 2, LegionUi.TEXT_DIM)
