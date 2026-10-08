class_name SteamLobby
extends Control
##
## Лобби онлайн-«Схватки» через Steam (вместо NetLobby с адресом сервера): имя — из Steam, список
## открытых игр — лобби Steam с данными нашей сборки, «Открыть» — своя игра (SteamNet.host),
## «Играть» — чужая (SteamNet.join), «Пригласить друга» — оверлей Steam. После матча оба
## возвращаются сюда с живым соединением: хозяин снова открывает комнату, гость видит её в
## «комнатах» и жмёт «Играть» — реванш без повторного поиска.
##
## Экран без ссылок на LegionMain: сессия и SteamNet живут у PvpFlow и переживают экран.
##

signal back

const CARD_W := 640.0
const MAP_TITLES := NetLobby.MAP_TITLES

var session: NetSession
var steam: SteamNet
## Лобби, в которое войти сразу (приглашение, +connect_lobby); 0 — просто показать список.
var join_on_start := 0

var _status: Label
var _games_box: VBoxContainer
var _rooms_box: VBoxContainer
var _create_row: HBoxContainer
var _mine_row: HBoxContainer
var _mine_label: Label
var _guest_row: HBoxContainer
var _refresh_btn: Button


func setup(s: NetSession, st: SteamNet, join_lobby := 0) -> SteamLobby:
	session = s
	steam = st
	join_on_start = join_lobby
	return self


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.92)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	var box := UiStyle.card_box(self, CARD_W, 10)
	var title := UiStyle.label("Схватка через Steam", 40, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var who := UiStyle.label("Вы — «%s»" % steam.my_name, 18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(who)
	_status = UiStyle.label("", 18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	# своя игра
	_create_row = HBoxContainer.new()
	_create_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_create_row.add_theme_constant_override("separation", 12)
	box.add_child(_create_row)
	for map: String in ["pvp:duel", "gen:"]:
		var b := _btn("Открыть: %s" % MAP_TITLES[map], 280.0)
		b.pressed.connect(func() -> void: steam.host(session, map, steam.my_name))
		_create_row.add_child(b)
	_mine_row = HBoxContainer.new()
	_mine_row.add_theme_constant_override("separation", 12)
	box.add_child(_mine_row)
	_mine_label = UiStyle.label("", 20, UiStyle.FONT_TEXT, UiStyle.TEXT)
	_mine_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mine_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mine_row.add_child(_mine_label)
	var invite := _btn("Пригласить друга", 200.0)
	invite.pressed.connect(steam.invite)
	_mine_row.add_child(invite)
	var close_mine := _btn("Закрыть", 120.0)
	close_mine.pressed.connect(_disconnect)
	_mine_row.add_child(close_mine)
	# в гостях
	_guest_row = HBoxContainer.new()
	_guest_row.add_theme_constant_override("separation", 12)
	box.add_child(_guest_row)
	var guest_label := UiStyle.label("Вы в чужой игре", 20, UiStyle.FONT_TEXT, UiStyle.TEXT)
	guest_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_guest_row.add_child(guest_label)
	var leave_btn := _btn("Отключиться", 160.0)
	leave_btn.pressed.connect(_disconnect)
	_guest_row.add_child(leave_btn)
	_rooms_box = VBoxContainer.new()
	_rooms_box.add_theme_constant_override("separation", 6)
	box.add_child(_rooms_box)
	# чужие игры
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	box.add_child(head)
	var games_title := UiStyle.label("Открытые игры:", 20, UiStyle.FONT_TEXT, UiStyle.TEXT)
	games_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(games_title)
	_refresh_btn = _btn("Обновить", 140.0)
	_refresh_btn.pressed.connect(steam.refresh)
	head.add_child(_refresh_btn)
	_games_box = VBoxContainer.new()
	_games_box.add_theme_constant_override("separation", 6)
	box.add_child(_games_box)
	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit())
	steam.lobbies.connect(_on_lobbies)
	steam.status.connect(_on_status)
	steam.failed.connect(_on_failed)
	steam.changed.connect(_refresh_mode)
	session.status.connect(_on_status)
	session.failed.connect(_on_failed)
	session.lobby.connect(_on_rooms)
	steam.auto_refresh = true
	_on_lobbies([])
	_refresh_mode()
	if session.last_error != "":
		_on_failed(session.last_error)
		session.last_error = ""
	# отложенное приглашение забирается всегда: иначе оно сработало бы при следующем открытии
	# экрана и порвало живое соединение (verifier 08.10, п. 3b)
	var taken := steam.take_pending_join()
	var pending := join_on_start if join_on_start != 0 else taken
	if pending != 0:
		steam.join(session, pending, steam.my_name)
	else:
		steam.refresh()


func _exit_tree() -> void:
	if steam != null:
		steam.auto_refresh = false
		for pair: Array in [[steam.lobbies, _on_lobbies], [steam.status, _on_status],
				[steam.failed, _on_failed], [steam.changed, _refresh_mode]]:
			_off(pair[0], pair[1])
	if session != null:
		for pair: Array in [[session.status, _on_status], [session.failed, _on_failed],
				[session.lobby, _on_rooms]]:
			_off(pair[0], pair[1])


static func _off(sig: Signal, handler: Callable) -> void:
	if sig.is_connected(handler):
		sig.disconnect(handler)


## Esc — «Назад» (см. NetLobby._input: ui_cancel, не «pause»; echo гасим; потребляем).
func _input(event: InputEvent) -> void:
	if visible and not event.is_echo() and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		back.emit()


## Закрыть свою игру или уйти из чужой: сначала сессия (её канал), потом Steam-сторона.
func _disconnect() -> void:
	session.close()
	steam.leave()
	_status.text = ""
	_on_rooms([], [], 0)
	_refresh_mode()


func _on_status(text: String) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	_refresh_mode()


func _on_failed(text: String) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", UiStyle.BAD)
	_refresh_mode()


func _on_lobbies(rows: Array) -> void:
	for c in _games_box.get_children():
		c.queue_free()
	for r: Variant in rows:
		if not (r is Dictionary):
			continue
		var row: Dictionary = r
		var lid := int(row.get("id", 0))
		var map := String(row.get("map", ""))
		var hb := _row(_games_box, "«%s» · %s" % [String(row.get("name", "?")), _map_title(map)],
			"Играть")
		(hb.get_child(1) as Button).pressed.connect(func() -> void:
			steam.join(session, lid, steam.my_name))
	if rows.is_empty():
		var empty := UiStyle.label("Открытых игр нет — откройте свою или пригласите друга", 16,
			UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_games_box.add_child(empty)


## Комнаты ретранслятора хозяина (после матча — реванш): гостю «Играть», хозяину — своя строка.
func _on_rooms(rooms: Array, _players: Array, _in_game: int) -> void:
	for c in _rooms_box.get_children():
		c.queue_free()
	for r: Variant in rooms:
		if not (r is Dictionary):
			continue
		var room: Dictionary = r
		if bool(room.get("mine", false)) or steam.mode != "guest":
			continue
		var code := String(room.get("code", ""))
		var hb := _row(_rooms_box, "«%s» · %s" % [String(room.get("host", "?")),
			_map_title(String(room.get("map", "")))], "Играть")
		(hb.get_child(1) as Button).pressed.connect(func() -> void: session.join_room(code))
	_refresh_mode()


static func _map_title(map: String) -> String:
	if MAP_TITLES.has(map):
		return MAP_TITLES[map]
	return MAP_TITLES["gen:"] if map.begins_with("gen:") else map


func _refresh_mode() -> void:
	if _create_row == null:
		return
	var host := steam.mode == "host"
	var guest := steam.mode == "guest"
	_create_row.visible = steam.mode == ""
	_mine_row.visible = host
	_guest_row.visible = guest
	_rooms_box.visible = guest
	if host:
		var waiting := session.room_code != "" and session.stage == NetSession.Stage.LOBBY
		_mine_label.text = "Ваша игра · %s — %s" % [_map_title(steam.map_id),
			"ждём соперника" if waiting else "открываем…"]


func _row(parent: VBoxContainer, text: String, action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UiStyle.label(text, 20, UiStyle.FONT_TEXT, UiStyle.TEXT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	row.add_child(_btn(action, 150.0))
	parent.add_child(row)
	return row


func _btn(text: String, w: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, 44.0)
	b.add_theme_font_override("font", UiStyle.FONT_TITLE)
	b.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(b)
	return b
