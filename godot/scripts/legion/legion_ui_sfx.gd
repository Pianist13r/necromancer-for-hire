class_name LegionUiSfx
extends Node
##
## Звуки интерфейса централизованно (аудит 08.10, SND-02): экраны меню, паузы, настроек,
## брифинга, досье и прокачки были немы, а правка каждого `ui/*.gd` — чужие потоки. Узел живёт
## ребёнком LegionAudio, слушает `SceneTree.node_added` и каждой кнопке (`BaseButton`: Button,
## CheckBox, OptionButton, TextureButton…) вешает наведение мышью и нажатие. Наведение — только
## мышью: фокус с клавиатуры/геймпада прыгает часто, и тик на каждый шаг утомляет (риск из аудита).
## Звучит только узел текущего LegionAudio (`LegionAudio.current()`): в тестах и гейте их бывает
## несколько, а кнопка одна — без проверки нажатие звучало бы дважды.
##

## Метка на кнопке: чей узел её уже озвучил (id экземпляра) — второй раз не подписываемся.
const META := &"_legion_ui_sfx"

var _audio: LegionAudio


func setup(audio: LegionAudio) -> void:
	_audio = audio


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_hook_all(get_tree().root)


func _hook_all(n: Node) -> void:
	_on_node_added(n)
	for c in n.get_children():
		_hook_all(c)


func _on_node_added(n: Node) -> void:
	var b := n as BaseButton
	if b == null or int(b.get_meta(META, 0)) == get_instance_id():
		return
	b.set_meta(META, get_instance_id())
	b.mouse_entered.connect(_on_hover.bind(b))
	b.pressed.connect(_on_pressed.bind(b))


func _on_hover(b: BaseButton) -> void:
	if b.disabled or LegionAudio.current() != _audio:
		return
	_audio.ui_sfx(&"ui_hover")


func _on_pressed(b: BaseButton) -> void:
	if LegionAudio.current() != _audio:
		return
	# переключатели (галочки) — тот же щелчок чуть выше: «вкл/выкл», а не «перейти»
	_audio.ui_sfx(&"ui_press", LegionCfg.AUDIO_UI_TOGGLE_PITCH if b.toggle_mode else 1.0)
