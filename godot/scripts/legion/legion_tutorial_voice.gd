extends RefCounted
## Фраза и имя клавиши записаны одним голосом. Неизвестная клавиша — только полная
## инструкция без имени: текущая привязка всё равно видна на плашке.

const SPECIAL := {KEY_SPACE: "space", KEY_SHIFT: "shift", KEY_TAB: "tab",
	KEY_CTRL: "ctrl", KEY_ALT: "alt", KEY_ENTER: "enter", KEY_BACKSPACE: "backspace",
	KEY_DELETE: "delete", KEY_UP: "up", KEY_DOWN: "down", KEY_LEFT: "left", KEY_RIGHT: "right"}
const GAP_MSEC := 120
const REPLACEMENTS := {&"lg_tut_stun": &"lg_tut_stun_safe", &"lg_tut_item": &"lg_tut_item_safe",
	&"lg_tut_clerk": &"lg_tut_clerk_safe"}


static func key_id(action: StringName) -> StringName:
	var code := Controls.display_code(Controls.key(action))
	if (code >= KEY_A and code <= KEY_Z) or (code >= KEY_0 and code <= KEY_9):
		return StringName("key_" + String.chr(code).to_lower())
	if SPECIAL.has(code):
		return StringName("key_" + String(SPECIAL[code]))
	if code >= KEY_F1 and code <= KEY_F12:
		return StringName("key_f%d" % (code - KEY_F1 + 1))
	return &""


static func sequence(id: StringName) -> Array[StringName]:
	if REPLACEMENTS.has(id):
		return [REPLACEMENTS[id]]
	var actions: Array = LessonsCfg.VOICE_KEYS.get(id, [])
	if actions.is_empty():
		return [id]
	var result: Array[StringName] = [StringName(String(id) + "_prompt")]
	var key := key_id(actions[0])
	if key != &"":
		result.append(key)
	return result


static func has_replacement(id: StringName) -> bool:
	return LessonsCfg.VOICE_KEYS.has(id) or REPLACEMENTS.has(id)
