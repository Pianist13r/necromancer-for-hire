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
## Канон игры — кириллические имена штатных клавиш («Ку», «Дубль-вэ»…); прочие — латиницей.
const SPOKEN := {KEY_Q: "Ку", KEY_W: "Дубль-вэ", KEY_E: "Е", KEY_R: "Эр",
	KEY_F: "Эф", KEY_D: "Дэ", KEY_P: "Пэ", KEY_SPACE: "Пробел", KEY_TAB: "Таб",
	KEY_SHIFT: "Шифт"}
## Группы токена {keys:…}: «1/2/3» — три вида договора.
const KEY_GROUPS := {"runes": [&"rune_normal", &"rune_frost", &"rune_ash"]}
## Слова старой прозы → действие (мост для текстов, ещё не переведённых на токены).
const PROSE := {"Ку": &"cast_q", "Дубль-вэ": &"cast_w", "Е": &"cast_e", "Эр": &"rally",
	"Пробел": &"aim_contract", "Пробелом": &"aim_contract", "Таб": &"erase_piece",
	"Табом": &"erase_piece", "Дэ": &"kassa", "Эф": &"call_wave",
	"Q": &"cast_q", "W": &"cast_w", "E": &"cast_e", "R": &"rally", "F": &"call_wave",
	"D": &"kassa", "П": &"pause", "1": &"rune_normal", "2": &"rune_frost", "3": &"rune_ash"}
## Одна регулярка на все случаи — один проход по тексту: при обмене Q↔W «Ку» станет «Дубль-вэ»
## и не превратится обратно. Порядок: токен; пара «Ку (Q)» (слово и буква одного действия —
## одна клавиша, KB-05); «F (или N)»; «1/2/3»; склонённые «Пробелом»/«Табом» (KB-10); имена;
## цифра вида ТОЛЬКО после «нажмите», «линия —», «клавиша(-ей)» (KB-04: «3 души» — не клавиша).
const _TEXT_PATTERN := ("\\{(?<tok>key\\+?|keys|cap):(?<act>[a-z_]+)\\}"
	+ "|(?<![\\p{L}\\p{N}])(?:(?<pw>Дубль-вэ|Ку|Е|Эр|Эф|Дэ) \\((?<pl>[QWERFDЕ])\\)"
	+ "|F \\(или N\\)|1/2/3|Пробелом|Табом|Дубль-вэ|Пробел|Таб|Ку|Эр|Дэ|Эф|[QWERFПЕ]"
	+ "|(?<=[Нн]ажмите |линия — |[Кк]лавиша |[Кк]лавишей )[123])(?![\\p{L}\\p{N}])")
static var _text_regex: RegEx = null
## Растёт на каждом apply(): открытый текст (плашка урока) сверяет её и пересчитывается, если
## клавишу переназначили посреди боя из паузы (KB-06).
static var revision := 0
## Подмена меток раскладки ОС (физическая → подпись) — только для тестов; пусто — спросить ОС.
static var _layout_labels: Dictionary = {}

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
	return candidate if _valid(candidate) else result

## Набор клавиш целиком: без повторов, и скрытая Эн волны живёт только на свободной клавише:
## словарь «волна на Эф и чужое на Эн» негоден целиком — иначе apply() повесил бы Эн двум
## действиям (J7).
static func _valid(candidate: Dictionary) -> bool:
	var used: Array[int] = []
	for action: StringName in ACTIONS:
		if int(candidate[action]) in used:
			return false
		used.append(int(candidate[action]))
	return not (int(candidate[&"call_wave"]) == KEY_F and alias_key(&"call_wave", candidate) == 0)

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
	return _store(bindings)

## Обмен клавишами (KB-11): клавиша занята другим действием — оно получает прежнюю клавишу
## этого, одним сохранением. Только прямой конфликт: скрытую Эн волны (J7) обмен не трогает —
## там остаётся отказ rebind(). Без конфликта — обычный rebind().
static func swap(action: StringName, code: int) -> String:
	var other := conflict(action, code)
	if action not in ACTIONS or not valid_key(code) or other == &"":
		return rebind(action, code)
	var bindings := _bindings()
	if int(bindings[other]) != code:
		return rebind(action, code)
	bindings[other] = bindings[action]
	bindings[action] = code
	if not _valid(bindings):
		return rebind(action, code)
	return _store(bindings)

## Записать набор и применить. J8: отказ записи — тоже ошибка этого вызова, хотя InputMap уже
## живёт по новой клавише: экран не должен писать «Клавиша сохранена», когда на диск ничего не
## легло.
static func _store(bindings: Dictionary) -> String:
	var saved := {}
	for name: StringName in ACTIONS:
		saved[String(name)] = bindings[name]
	var err := Settings.set_value(SECTION, "keyboard", saved)
	apply()
	return "" if err == OK else SAVE_FAILED

## Возврат к штатной раскладке — той же проверкой записи, что и rebind (J8).
static func reset() -> String:
	var err := Settings.set_value(SECTION, "keyboard", {})
	apply()
	return "" if err == OK else SAVE_FAILED

static func apply() -> void:
	revision += 1
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

## Что напечатано на физической клавише в раскладке ОС (KB-09): на AZERTY физическая Q — «A».
## Берём только латинскую букву или цифру: русская раскладка ОС дала бы «Й», а игра называет
## клавиши латиницей и своими именами — тогда остаётся имя физической клавиши (US QWERTY).
static func display_code(code: int) -> int:
	var shown := code
	if not _layout_labels.is_empty():
		shown = int(_layout_labels.get(code, code))
	elif DisplayServer.get_name() != "headless":
		shown = int(DisplayServer.keyboard_get_label_from_physical(code))
	if (shown >= KEY_A and shown <= KEY_Z) or (shown >= KEY_0 and shown <= KEY_9):
		return shown
	return code

## Тестам: подменить метки раскладки ОС словарём {физическая: подпись}; {} — снова спрашивать ОС.
static func set_layout_labels(labels: Dictionary) -> void:
	_layout_labels = labels.duplicate()
	revision += 1

## Клавиша действия выглядит не так, как штатная (переназначена или раскладка ОС другая).
static func renamed(action: StringName) -> bool:
	return display_code(key(action)) != int(DEFAULTS.get(action, 0))

static func label(action: StringName, spoken := false) -> String:
	var code := display_code(key(action))
	if spoken and SPOKEN.has(code):
		return SPOKEN[code]
	return OS.get_keycode_string(code)

## «Ку (Q)»: имя и буква на клавише; совпали (Z) — одно имя.
static func full_label(action: StringName) -> String:
	var spoken := label(action, true)
	var plain := label(action)
	return plain if spoken == plain else "%s (%s)" % [spoken, plain]

## Текст игрока с клавишами. Токены: {key:действие} — имя клавиши в прозе («Ку», после
## переназначения — новая), {key+:действие} — «Ку (Q)», {cap:действие} — буква на клавише
## («R» в «Сбор (R)»), {keys:runes} — «1/2/3». Старая проза
## со штатными словами («Ку», «Пробел», «(R)») — мост: на штатной раскладке остаётся как
## написана, после переназначения слово заменяется. Звать ОДИН раз на путь вывода (сток):
## повторный проход при обмене клавиш вернул бы прежнее слово.
static func text(source: String) -> String:
	if _text_regex == null:
		_text_regex = RegEx.create_from_string(_TEXT_PATTERN)
	var matches := _text_regex.search_all(source)
	var out := source
	for i in range(matches.size() - 1, -1, -1):
		var hit: RegExMatch = matches[i]
		out = out.substr(0, hit.get_start()) + _render(hit) + out.substr(hit.get_end())
	return out

static func _render(hit: RegExMatch) -> String:
	var word := hit.get_string()
	var tok := hit.get_string("tok")
	if tok == "keys":
		var group: Array = KEY_GROUPS.get(hit.get_string("act"), [])
		return word if group.is_empty() else _group(group)
	if tok != "":
		var action := StringName(hit.get_string("act"))
		if action not in ACTIONS:
			return word
		match tok:
			"key+":
				return full_label(action)
			"cap":
				return label(action)
		return label(action, true)
	var pw := hit.get_string("pw")
	if pw != "":
		var pl := hit.get_string("pl")
		if PROSE[pw] != PROSE[pl]:
			return _prose(pw) + " (" + _prose(pl) + ")"
		return word if not renamed(PROSE[pw]) else full_label(PROSE[pw])
	if word == "1/2/3":
		var runes: Array = KEY_GROUPS["runes"]
		for action: StringName in runes:
			if renamed(action):
				return _group(runes)
		return word
	if word == "F (или N)":
		var alias := alias_key(&"call_wave", _bindings()) == KEY_N
		return word if alias and not renamed(&"call_wave") else label(&"call_wave")
	return _prose(word)

static func _group(actions: Array) -> String:
	var names := PackedStringArray()
	for action: StringName in actions:
		names.append(label(action))
	return "/".join(names)

## Слово старой прозы: штатная клавиша — как написано; иначе имя новой (кириллическое слово —
## «произносимым» именем, латинская буква — буквой; «Пробелом» — «клавишей Z»).
static func _prose(word: String) -> String:
	var action: StringName = PROSE.get(word, &"")
	if action == &"" or not renamed(action):
		return word
	var shown := label(action, word.unicode_at(0) >= 0x400)
	return "клавишей " + shown if word.ends_with("ом") else shown
