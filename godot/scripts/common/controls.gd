class_name Controls
extends RefCounted
## Physical keyboard positions; mouse gestures and simulation commands are unchanged.
## Esc remains an unconditional way to cancel or open the menu.

const SECTION := "bindings"
const ACTIONS: Array[StringName] = [&"cast_q", &"cast_w", &"cast_e", &"rally",
	&"call_wave", &"kassa", &"aim_contract", &"erase_piece", &"rune_normal",
	&"rune_frost", &"rune_ash", &"pause", &"mute"]
const DEFAULTS := {&"cast_q": KEY_Q, &"cast_w": KEY_W, &"cast_e": KEY_E,
	&"rally": KEY_R, &"call_wave": KEY_F, &"kassa": KEY_D, &"aim_contract": KEY_SPACE,
	&"erase_piece": KEY_TAB, &"rune_normal": KEY_1, &"rune_frost": KEY_2,
	&"rune_ash": KEY_3, &"pause": KEY_P, &"mute": KEY_M}
const TITLES := {&"cast_q": "Молния", &"cast_w": "Оформление в штат", &"cast_e": "Аврал",
	&"rally": "Сбор", &"call_wave": "Вызвать волну", &"kassa": "Касса",
	&"aim_contract": "Поворот стрелки (держать)", &"erase_piece": "Стереть кусок линии",
	&"rune_normal": "Подряд", &"rune_frost": "Охрана",
	&"rune_ash": "Аудит", &"pause": "Пауза / меню", &"mute": "Без звука"}
## Отказ записи settings.cfg (J8): раскладка в этой сессии уже новая, но на диск не легла.
const SAVE_FAILED := "Не удалось записать настройки: клавиша действует до закрытия игры."
static var _text_regex: RegEx = null

static func key(action: StringName) -> int:
	return int(_bindings().get(action, 0))

## Read the whole set to reject corrupt/duplicate saved values as one transaction.
static func _bindings() -> Dictionary:
	var result := DEFAULTS.duplicate()
	var saved: Variant = Settings.get_value(SECTION, "keyboard", {})
	if not saved is Dictionary:
		return result
	var candidate := DEFAULTS.duplicate()
	for action: StringName in ACTIONS:
		var value: Variant = saved.get(String(action), DEFAULTS[action])
		if not value is int or not valid_key(value):
			return result
		candidate[action] = value
	var used: Array[int] = []
	for action: StringName in ACTIONS:
		if int(candidate[action]) in used:
			return result
		used.append(int(candidate[action]))
	# Скрытая Эн волны живёт только на свободной клавише: словарь «волна на Эф и чужое на Эн»
	# негоден целиком — иначе apply() повесил бы Эн двум действиям (J7).
	if int(candidate[&"call_wave"]) == KEY_F and alias_key(&"call_wave", candidate) == 0:
		return result
	return candidate

static func valid_key(code: int) -> bool:
	return code > 0 and code < KEY_SPECIAL + 256 and code != KEY_ESCAPE \
		and not OS.get_keycode_string(code).is_empty()

## Скрытая клавиша действия: у «Вызвать волну» на штатной Эф живёт ещё и Эн — но только пока Эн
## не занята другим действием. Занятость алиаса проверяет и conflict(), и _bindings(): иначе
## словарь «волна на Эф + Ку на Эн» проходил бы, и apply() вешал Эн двум действиям разом (J7).
static func alias_key(action: StringName, bindings: Dictionary) -> int:
	if action != &"call_wave" or int(bindings.get(&"call_wave", 0)) != KEY_F:
		return 0
	for other: StringName in ACTIONS:
		if other != &"call_wave" and int(bindings[other]) == KEY_N:
			return 0
	return KEY_N


static func conflict(action: StringName, code: int) -> StringName:
	var bindings := _bindings()
	for other: StringName in ACTIONS:
		if other == action:
			continue
		if int(bindings[other]) == code or alias_key(other, bindings) == code:
			return other
	# Обратный переход (J7): возврат волны на Эф включает скрытую Эн — она не должна быть занята.
	if action == &"call_wave" and code == KEY_F:
		for other: StringName in ACTIONS:
			if other != &"call_wave" and int(bindings[other]) == KEY_N:
				return other
	return &""

## Error string for the UI; a rejected candidate leaves both InputMap and disk unchanged.
static func rebind(action: StringName, code: int) -> String:
	if action not in ACTIONS or not valid_key(code):
		return "Эскейп оставлен для отмены. Выберите другую клавишу."
	var other := conflict(action, code)
	if other != &"":
		return "Клавиша занята: %s. Сначала измените это действие." % TITLES[other]
	var bindings := _bindings()
	bindings[action] = code
	var saved := {}
	for name: StringName in ACTIONS:
		saved[String(name)] = bindings[name]
	# J8: отказ записи — тоже ошибка этого вызова, хотя InputMap уже живёт по новой клавише:
	# экран не должен писать «Клавиша сохранена», когда на диск ничего не легло.
	var err := Settings.set_value(SECTION, "keyboard", saved)
	apply()
	return "" if err == OK else SAVE_FAILED

## Возврат к штатной раскладке — той же проверкой записи, что и rebind (J8).
static func reset() -> String:
	var err := Settings.set_value(SECTION, "keyboard", {})
	apply()
	return "" if err == OK else SAVE_FAILED

static func apply() -> void:
	var bindings := _bindings()
	for action: StringName in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		# Preserve any non-keyboard device bindings.
		for old: InputEvent in InputMap.action_get_events(action):
			if old is InputEventKey:
				InputMap.action_erase_event(action, old)
		_add_key(action, int(bindings[action]))
		if action == &"pause":
			_add_key(action, KEY_ESCAPE)
		elif alias_key(action, bindings) != 0:
			# Existing N shortcut survives on the default layout — пока Эн свободна (J7).
			_add_key(action, KEY_N)

static func _add_key(action: StringName, code: int) -> void:
	var event := InputEventKey.new()
	event.device = -1
	event.physical_keycode = code
	InputMap.action_add_event(action, event)

static func label(action: StringName, spoken := false) -> String:
	var code := key(action)
	if spoken:
		var names := {KEY_Q: "Ку", KEY_W: "Дубль-вэ", KEY_E: "Е", KEY_R: "Эр",
			KEY_F: "Эф", KEY_D: "Дэ", KEY_P: "Пэ", KEY_SPACE: "Пробел", KEY_TAB: "Таб",
			KEY_SHIFT: "Шифт"}
		if names.has(code):
			return names[code]
	return OS.get_keycode_string(code)

## Historical map/tutorial prose names the default keyboard positions. Substitute complete
## words only, once, so assigning e.g. Q to W does not recursively replace the new label.
static func text(source: String) -> String:
	var words := {"Ку": &"cast_q", "Дубль-вэ": &"cast_w", "Е": &"cast_e", "Эр": &"rally",
		"Пробел": &"aim_contract", "Таб": &"erase_piece", "Дэ": &"kassa", "Эф": &"call_wave",
		"Q": &"cast_q", "W": &"cast_w", "E": &"cast_e", "R": &"rally", "F": &"call_wave",
		"N": &"call_wave", "П": &"pause", "1": &"rune_normal", "2": &"rune_frost", "3": &"rune_ash"}
	if _text_regex == null:
		_text_regex = RegEx.new()
		_text_regex.compile("(?<![\\p{L}\\p{N}])(?:F \\(или N\\)|1/2/3|Дубль-вэ|Пробел|Таб|Ку|Эр|Дэ|Эф"
			+ "|[QWERFПЕ])(?![\\p{L}\\p{N}])")
	var matches := _text_regex.search_all(source)
	var out := source
	for i in range(matches.size() - 1, -1, -1):
		var hit: RegExMatch = matches[i]
		var word := hit.get_string()
		var replacement := word
		if word == "1/2/3":
			replacement = "/".join([label(&"rune_normal"), label(&"rune_frost"), label(&"rune_ash")])
		elif word == "F (или N)":
			replacement = "F (или N)" if key(&"call_wave") == KEY_F else label(&"call_wave")
		elif words.has(word):
			replacement = label(words[word], word != word.to_upper() or word == "Е")
		out = out.substr(0, hit.get_start()) + replacement + out.substr(hit.get_end())
	return out
