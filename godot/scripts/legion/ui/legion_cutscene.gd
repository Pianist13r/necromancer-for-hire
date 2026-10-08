class_name LegionCutscene
extends Control
##
## Катсцена нового режима (docs/legion/DESIGN_V15.md §9): последовательность кадров —
## картинка 1920×1080 с медленным наездом (Ken Burns) либо короткое видео (.ogv), голос
## рассказчика через `LegionVoice.voice(id)` и титры внизу. Три места вызова — вступление
## кампании, выход Прораба, финал — собирает legion_main.gd, этот файл только проигрывает
## готовый список кадров и не знает про Campaign/карты.
##
## Пропуск кадра — ЛКМ или Пробел, пропуск всей катсцены — Esc (задание пакета cuts).
## Длительность кадра с видео задаёт само видео (сигнал `finished`); кадр-картинка стоит не
## меньше max(длина титров, длина голоса `VOICE_TAIL_MARGIN_SEC` в запасе) — реплика короче
## титров кадр раньше срока не обрежет, LegionAudio просто замолчит первой, а реплика длиннее
## титров (озвучка 26.09.2026) держит кадр сама.
##

signal finished

## Один кадр: картинка ИЛИ видео (video приоритетнее, если задано), голос, титры.
class Frame:
	var image: Texture2D
	var video: VideoStream
	var voice_id: StringName
	var caption: String

	func _init(p_caption: String, p_voice_id: StringName = &"", p_image: Texture2D = null,
			p_video: VideoStream = null) -> void:
		caption = p_caption
		voice_id = p_voice_id
		image = p_image
		video = p_video

## Почему: короткая реплика не должна мигать кадром меньше секунды — 3 с минимум даже
## для пустых титров, плюс своя секунда на кадр текста (докстрин ставки — подобрано на глаз
## по темпу реплик lines.tsv, не наука).
const FRAME_MIN_SEC := 3.0
const FRAME_SEC_PER_CHAR := 0.055
## Почему: озвучка 26.09.2026 (gemini-3.1-flash-tts) читает медленнее прежней Silero — реплика
## рассказчика теперь 7-12 с против ~4-5 с раньше, а кадр по титрам держался только ~4 с и голос
## обрывался следующим кадром. Кадр обязан стоять не короче длины голоса
## (`AudioStream.get_length()`) плюс этот запас — иначе последний слог срезает смена картинки.
const VOICE_TAIL_MARGIN_SEC := 0.5
## Почему: 1.08 — заметный, но не отвлекающий наезд за длительность кадра (5-10 с); больше
## отрывает картинку от рамки на широких планах вроде lg_intro_3.
const PAN_ZOOM_TARGET := 1.08
const FADE_SEC := 0.35

var _frames: Array[Frame] = []
var _index := -1
var _frame_token := 0
var _audio: LegionAudio = null
var _finished := false

var _pic: TextureRect
var _video_player: VideoStreamPlayer
var _caption_label: Label
var _fade: ColorRect


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.color = Color.BLACK
	UiStyle.fill_rect(bg)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_pic = TextureRect.new()
	_pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pic.stretch_mode = TextureRect.STRETCH_SCALE
	UiStyle.fill_rect(_pic)
	_pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pic)

	_video_player = VideoStreamPlayer.new()
	UiStyle.fill_rect(_video_player)
	_video_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_video_player.expand = true
	_video_player.visible = false
	_video_player.finished.connect(_on_video_finished)
	add_child(_video_player)

	var caption_bg := PanelContainer.new()
	caption_bg.anchor_left = 0.0
	caption_bg.anchor_right = 1.0
	caption_bg.anchor_top = 1.0
	caption_bg.anchor_bottom = 1.0
	caption_bg.offset_top = -140.0
	caption_bg.offset_bottom = 0.0
	caption_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption_bg.add_theme_stylebox_override(
		"panel", UiStyle.panel_style(Color(0.02, 0.01, 0.04, 0.82), 0))
	add_child(caption_bg)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 70)
	margin.add_theme_constant_override("margin_right", 70)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	caption_bg.add_child(margin)

	_caption_label = UiStyle.label("", 24, UiStyle.FONT_TEXT)
	_caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_caption_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	margin.add_child(_caption_label)

	var hint := UiStyle.label(
		"ЛКМ / Пробел — дальше · Esc — пропустить", 14, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	hint.anchor_left = 1.0
	hint.anchor_right = 1.0
	hint.offset_left = -440.0
	hint.offset_top = 14.0
	hint.offset_right = -14.0
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)

	_fade = ColorRect.new()
	_fade.color = Color(0.0, 0.0, 0.0, 0.0)
	UiStyle.fill_rect(_fade)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	var skip := ProgressionUi.button("Пропустить ▸▸", _skip_all)
	add_child(skip)
	skip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	skip.offset_left = -244
	skip.offset_right = -24
	skip.offset_top = 44
	skip.offset_bottom = 96


## Публичный вход: список кадров и, если у вызывающего уже есть боевой узел озвучки (боссовая
## катсцена перед картой — LegionWorld к этому моменту уже жив), передать его — иначе длина
## кадра считается по титрам, без голоса (вступление кампании звучит до первого мира).
func play(frames: Array[Frame], audio: LegionAudio = null) -> void:
	_frames = frames
	_audio = audio
	_index = -1
	_next_frame()


func _next_frame() -> void:
	_frame_token += 1
	var token := _frame_token
	_index += 1
	if _index >= _frames.size():
		_finish()
		return
	var f: Frame = _frames[_index]
	_caption_label.text = f.caption
	var dur := maxf(FRAME_MIN_SEC, f.caption.length() * FRAME_SEC_PER_CHAR)
	if f.voice_id != &"":
		var voice_stream := load(LegionAudio.VOICE_DIR + String(f.voice_id) + ".ogg") as AudioStream
		if voice_stream != null:
			dur = maxf(dur, voice_stream.get_length() + VOICE_TAIL_MARGIN_SEC)

	if f.video != null:
		_pic.visible = false
		_video_player.visible = true
		_video_player.stream = f.video
		_video_player.play()
	else:
		_video_player.visible = false
		_pic.visible = true
		_pic.texture = f.image
		_play_pan(dur)
		var timer := get_tree().create_timer(dur)
		timer.timeout.connect(func() -> void: _advance_if_current(token))

	if _audio != null and f.voice_id != &"":
		# Сцена: новый кадр обрывает прежнюю реплику и чистит очередь (verifier 26.09: при
		# одиночном слоте «важной» реплики клик по кадру оставлял звучать прошлый кадр).
		_audio.speech.voice(f.voice_id, LegionCfg.AUDIO_V15_PRIORITY_NARRATOR,
			LegionAudio.VoiceClass.SCENE)

	_fade_in()


func _advance_if_current(token: int) -> void:
	if not _finished and token == _frame_token:
		_next_frame()


func _on_video_finished() -> void:
	# stop() при ручном пропуске не эмитит finished (только естественный конец потока) —
	# так что сюда попадаем только для кадра, который реально доиграл сам.
	_advance_if_current(_frame_token)


func _play_pan(dur: float) -> void:
	_pic.pivot_offset = _pic.size * 0.5
	_pic.scale = Vector2.ONE
	var tw := create_tween()
	tw.tween_property(_pic, "scale", Vector2(PAN_ZOOM_TARGET, PAN_ZOOM_TARGET), dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _fade_in() -> void:
	_fade.color.a = 1.0
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 0.0, FADE_SEC)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_skip_frame()
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed or event.is_echo():
		return
	var k := event as InputEventKey
	if k.keycode == KEY_SPACE:
		_skip_frame()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_ESCAPE:
		_skip_all()
		get_viewport().set_input_as_handled()


func _skip_frame() -> void:
	if _video_player.visible:
		_video_player.stop()
	_next_frame()


func _skip_all() -> void:
	if _video_player.visible:
		_video_player.stop()
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	_frame_token += 1
	# Уход из катсцены любым путём (Esc, клик за последний кадр, конец) гасит голос кадра, если
	# он ещё звучит: иначе 10-секундная реплика звучала бы поверх брифинга/боя, а брифинг карты
	# ждал бы её в очереди. До finished — следующий экран уже может заговорить своим.
	if _audio != null:
		_audio.speech.end_scene_voice()
	finished.emit()
	queue_free()
