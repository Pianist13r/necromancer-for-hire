# gdlint: disable=max-public-methods
class_name CharView
extends Node2D
##
## Вид персонажа — ЕДИНСТВЕННЫЙ вход геймплея в анимацию (контракт docs/PROTOTYPE_PLAN.md §2.5).
## Геймплей говорит «иду/стою/удар/смерть», CharView решает, как это показать:
##   есть клип в CfgAnim.CHARS[char_id].clips → покадровый CharAnim;
##   клипа нет → процедурная заглушка (stub) на плоской запасной текстуре (fallback).
## Поэтому геймплей не зависит от прихода клипов: трек анимации дописывает строку в CfgAnim,
## код игры не меняется.
##
## Правила контракта: тайминги геймплея главнее клипа (подъём 0.4, смерть 0.45 — клип
## подгоняется под них); базовые клипы — лицом ВПРАВО, directions — пять ракурсов;
## масштаб — через body_h, опора новых клипов — pivot_px из clip.json.
##
## Кадры строятся ОДИН раз на персонажа (статический кэш `_cache`) и прогреваются `warm()` при
## старте мира — ни одного чтения диска в кадре боя (правило проекта, fx.gd).
##
## Узлы: CharView (им управляет сущность: position/rotation/modulate — её) → _body (смещения и
## поворот заглушек) → CharAnim | Sprite2D; живость v19 — трансформация клипа вокруг ступней. Тинт и
## вспышка — на самом изображении, поэтому modulate сущности (прозрачность призрака, свечение
## «Аврала») с ними перемножается.
##
## Живость (v19, Игорь 26.09.2026: «анимации более плавные… более естественные»): рисованные
## клипы — это позы, а тело между ними стоит колом, и вся толпа шагает в ногу. Поверх клипа —
## чисто вид, геймплей его не видит и не ждёт:
##   - разнобой: у каждого своя фаза цикла и свой темп дыхания;
##   - ходьба: корпус опускается на касании (по нарисованному разносу ног из clip.json),
##     покачивается с ноги на ногу и чуть клонится вперёд;
##   - темп ходьбы следует за фактической скоростью сущности (CHARS.walk_speed, B-206) —
##     только пока играет walk, темп удара не трогается;
##   - покой: дыхание — сжатие к ступням и обратно;
##   - удар по персонажу: пружина сплющивания; разворот — через сжатие по ширине, не щелчком;
##   - появление с подскоком; труп перед уборкой оседает и тает, а не пропадает кадром.
## Всё вращается и сжимается вокруг ступней (опора _ground), поэтому ноги не скользят по земле.
## Опора — не узел, а одна запись трансформации клипа за обновление (дешевле на сотнях фигур).
## Числа — CfgAnim.MOTION (по умолчанию) и CHARS[id].motion (поправки на персонажа).
##

## кадр касания — ровно раз за проигрывание (клип: contact_frame; заглушка: сразу)
signal contact(state: StringName)
## одноразовый клип/заглушка доиграли
signal finished(state: StringName)

const BOB_RATE := 0.09           ## рад на px пути — цикл покачивания заглушки ходьбы (enemy.gd)
const RISE_DEPTH := 0.55         ## из-под земли: старт на body_h × 0.55 ниже
const FALL_DROP := 0.35          ## смерть: тело оседает на body_h × 0.35
const FALL_TILT := 0.9           ## и поворачивается на 0.9 рад в сторону взгляда
const FLASH_COLOR := Color(3.0, 3.0, 3.0)
## Сколько секунд сущность должна простоять, чтобы ходьба без клипа покоя замерла на кадре.
## Меньше шага физики нельзя — иначе клип мигает play/pause между тиками движения.
const STILL_FREEZE := 0.1
## Клип вздрагивания (react_hit) — не чаще раза в столько секунд: скелеты и пепел бьют часто,
## и без паузы ходьба врага целиком состояла бы из hit.
const HIT_REACT_CD := 0.9
## Подготовка только в конце уже действующего отката: первый удар остаётся мгновенным.
const ATTACK_PREP_TIME := 0.1

static var _cache: Dictionary = {}   ## char_id → {frames, defs, tex: {state: Texture2D}}
## Все живые виды на сцене — слой теней (CharShadows) рисует их одним проходом.
static var registry: Array[CharView] = []
## Крючок эффектов: вызывается при каждом ударе по персонажу (react_hit) с самим видом.
## Слой эффектов ставит его на время боя и снимает при выходе; геймплей его не видит.
static var hit_hook: Callable = Callable()
## «Графика: экономная» (Settings.set_economy_graphics) — без дыхания, раскачки, наклона,
## пружины удара и подскока появления; клипы играют как есть. Разворот (facing) и труп
## (оседание/таяние) остаются — разворот нужен фигуре, а не только для красоты (у CharAnim нет
## другого способа отзеркалить клип), труп — часть B-049 (часы мира). Статик-флаг проверяется
## каждый кадр вместо пересборки узлов — переключатель мгновенный и безопасный из паузы.
static var economy_motion := false
## Отсечка крючка ДО вызова (verifier 26.09: в драке 300 фигур сотни вызовов за кадр стоили
## ~1 мс): не больше CfgAnim.HIT_HOOK_PER_FRAME за кадр и не чаще раза в HIT_HOOK_VIEW_FRAMES
## кадров на вид — ровно то, что слой эффектов всё равно бы отбросил.
static var _hook_frame := -1
static var _hook_n := 0

var body_h := 0.0
var char_id := ""
## Враги не отправляют команды локомоции: их вид следует фактическому перемещению.
## Бойцы оставляют false, поскольку сами задают idle/walk в своём tick.
var locomotion_from_position := false
## тень, px мира — слой CharShadows читает поля напрямую
var shadow_w_px := 0.0
var shadow_h_px := 0.0
var shadow_a := 0.0

var _def: Dictionary = {}
var _body: Node2D
## клип в системе опоры у ступней (масштаб и смещение без живости)
var _anim_local := Transform2D.IDENTITY
var _legacy_anim_local := Transform2D.IDENTITY
var _layout_cached: StringName = &""
var _prepare_seen := false
var _prepare_target_id := 0
## таяние трупа 0…1 (1 — целый)
var _corpse_a := 1.0
var _anim: CharAnim = null
var _sprite: Sprite2D = null
var _state: StringName = &""
var _loop_state: StringName = &""
var _facing := 1.0
var _legacy_facing := 1.0
var _direction_pos := Vector2.INF
var _walked := 0.0
var _tint := Color.WHITE
var _flash_color := FLASH_COLOR
var _flash_t := 0.0
var _flash_dur := 0.12
var _stub_kind := ""
var _stub_state: StringName = &""
var _stub_t := 0.0
var _stub_dur := 0.0
var _last_pos := Vector2.INF
var _still_t := 0.0
var _hit_cd := 0.0
var _stun_time := 0.0
var _stun_visible := false

# ── живость (v19) ──
var _motion: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _ground := 0.0              ## где ступни ниже position, px
var _face_cur := 1.0            ## видимый разворот −1…1 (ширина через сжатие)
var _face_set := false
var _spring := 0.0              ## сплющивание по высоте (−: сжат), пружина удара
var _spring_v := 0.0
var _breath_t := 0.0
var _breath_period := 2.5
var _pop_t := -1.0              ## появление: время с начала, <0 — не идёт
var _corpse_t := -1.0           ## труп: время с начала смерти, <0 — жив
## true — возраст трупа гонит вызывающий (foe.gd set_corpse_age, часы мира) до явного
## release_corpse_clock(); иначе — свой _process (часы вида, реальные секунды) — так живут
## трупы Legionnaire (unit.gd своя уборка) и трупы врагов после конца боя.
var _corpse_driven := false
var _corpse_hold := false
var _idle_jitter := 1.0
# числа живости — полями (словарь в кадре дорог): см. _tick_life
var _m_bob_px := 0.0
var _m_sway := 0.0
var _m_lean := 0.0
var _m_float_px := 0.0
var _m_breath := 0.0
var _m_hit_kick := 0.0
var _m_thud_kick := 0.0
var _m_k := 600.0
var _m_c := 22.0
var _m_flip_rate := 22.0
var _m_pop_time := 0.3
var _m_pop_from := 0.45
var _m_corpse_fade := 0.8
var _m_corpse_sink_px := 0.0
var _breath_w := 1.0
var _clip_cached: StringName = &""
var _stride := PackedFloat32Array()
var _contact_ph := 0.0
var _frame_n := 0
var _tick_n := 0
var _stagger := 0
var _settled := false
## идёт ли фигура: бойцам ставит set_locomotion, врагам — _tick_still_walk (без вызовов движка
## в каждом кадре — на сотнях фигур это заметная доля кадра)
var _walk_flag := false
var _hook_next := 0
var _ap_rot := 0.0
var _ap_y := INF
var _ap_sx := INF
var _ap_sy := INF
# ── темп ходьбы по факту скорости (B-206): чисто вид, скорость берём из движения самого узла ──
## расчётная скорость хода, px/с (CHARS.walk_speed; 0 — темп не трогаем)
var _walk_ref := 0.0
var _base_speed := 1.0          ## темп клипа без поправки: то, что попросили set_locomotion/скелет
var _tempo := 1.0               ## текущий множитель темпа walk (1 — расчётная скорость)
var _tempo_on := false          ## speed_scale клипа сейчас подправлен нами
var _tempo_pos := Vector2.INF
var _tempo_dist := 0.0          ## путь и время с затуханием: факт = путь / время
var _tempo_time := 0.0


## Прогреть кэш кадров для набора персонажей (мир зовёт в _ready для всех CHARS).
static func warm(char_ids: Array) -> void:
	for id in char_ids:
		_entry(String(id))


static func _entry(id: String) -> Dictionary:
	if _cache.has(id):
		return _cache[id]
	var def := CfgAnim.char_def(id)
	var built := CharAnim.load_clips(def.get("clips", {}))
	var tex := {}
	var fallback: Dictionary = def.get("fallback", {})
	for state in fallback.keys():
		var path := String((fallback[state] as Dictionary).get("tex", ""))
		if path != "" and ResourceLoader.exists(path):
			tex[state] = load(path)
	var entry := {"frames": built["frames"], "defs": built["defs"], "tex": tex}
	_cache[id] = entry
	return entry


func _enter_tree() -> void:
	registry.append(self)


func _exit_tree() -> void:
	registry.erase(self)


## Собрать вид. body_h — высота фигуры на экране, px (Cfg.ANCHOR_PX × visual).
func setup(new_char_id: String, new_body_h: float) -> void:
	char_id = new_char_id
	body_h = new_body_h
	if char_id == "boss":
		# Звёзды не теряются в затемнении края арены; дочерний спрайт освещается как прежде.
		var stars_material := CanvasItemMaterial.new()
		stars_material.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		material = stars_material
	_def = CfgAnim.char_def(char_id)
	_walk_ref = float(_def.get("walk_speed", 0.0))
	_motion = CfgAnim.motion_for(char_id)
	# свой генератор: разнобой — чистый вид, world.rng (симуляция) не трогаем
	_rng.seed = hash(get_instance_id())
	_breath_period = float(_motion["breath_period"]) * _rng.randf_range(0.85, 1.15)
	_breath_t = _rng.randf() * _breath_period
	_idle_jitter = _rng.randf_range(0.92, 1.08)
	_cache_motion()
	var entry := _entry(char_id)
	_body = Node2D.new()
	add_child(_body)
	_ground = float(_def.get("ground_off", 0.5)) * body_h

	var defs: Dictionary = entry["defs"]
	if not defs.is_empty():
		_anim = CharAnim.new()
		_anim.centered = true
		# кадры ужимаются на экране в 2–3 раза: без мипмапов контур зернит и мерцает при ходьбе
		_anim.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		var canvas := float(_def.get("canvas_px", 460.0))
		var fill := float(_def.get("figure_fill", 0.85))
		var sc := body_h / (canvas * fill)
		_anim.scale = Vector2(sc, sc)
		# холст клипа якорен НИЗОМ: низ холста ложится на «землю» персонажа (+1 % поля);
		# позиция — от опоры у ступней: живость крутит и сжимает клип вокруг неё
		_anim.position = Vector2(0.0, -canvas * sc / 2.0 + canvas * sc * 0.01)
		_anim_local = _anim.transform
		_legacy_anim_local = _anim_local
		_body.add_child(_anim)
		_anim.setup_frames(entry["frames"], defs, String(_def.get("default", "idle")))
		_anim.set_death_variant(_rng.randi_range(0, int(_def.get("death_variants", 1)) - 1))
		_anim.contact_frame.connect(_on_clip_contact)
		_anim.clip_finished.connect(_on_clip_finished)

	_sprite = Sprite2D.new()
	_body.add_child(_sprite)
	set_look_material(CharReadability.for_character(char_id))
	var start := StringName(String(_def.get("default", "idle")))
	_loop_state = start
	if _anim != null and _anim.has_state(String(start)):
		_sprite.visible = false
		_anim.play_state(String(start))
		_state = start
		_desync_loop()
	else:
		_show_fallback(start)
	_apply_modulate()
	# «Графика: экономная» — появление сразу закончено (не только пружина/дыхание, но и тень:
	# shadow_alpha ниже умножает на _pop_t, замороженный на 0 гасил бы её навсегда).
	if _m_pop_time > 0.0 and not economy_motion:
		_pop_t = 0.0
	_apply_pivot()


## Ходьба/покой: step_px — путь за этот тик (0 → idle, >0 → walk); speed_scale — темп клипа
## (скелет на «Аврале» перебирает ногами быстрее).
func set_locomotion(step_px: float, speed_scale: float = 1.0) -> void:
	var want: StringName = &"walk" if step_px > 0.0 else &"idle"
	_walk_flag = step_px > 0.0
	if _anim != null and _anim.has_state(String(want)):
		var before := _anim.current_state()
		_anim.play_state(String(want))
		# Отклонённая заявка локомоции не меняет скорость замаха или смерти.
		# Повторный walk сохраняет накопленные путь/время: бойцы зовут его каждый тик.
		if _anim.current_state() == String(want):
			if before != String(want):
				_tempo_reset()
			# Факт перемещения уже включает Аврал/замедление; второй множитель удвоил бы эффект.
			_base_speed = _idle_jitter if want == &"idle" else (1.0 if _walk_ref > 0.0 else speed_scale)
			_anim.speed_scale = _base_speed * _tempo
		_sync_facing()
		if _anim.current_state() != before:
			_desync_loop()
		if _stub_kind == "":
			_state = StringName(_anim.current_state())
		return
	# заглушка: покачивание по ПУТИ, а не по времени — остановился, перестал качаться
	if step_px > 0.0 and _stub_kind == "":
		_walked += step_px
		var bob := float(_def.get("bob", 0.0))
		if bob > 0.0:
			_body.position.y = sin(_walked * BOB_RATE) * bob


## Зацикленное состояние сверх ходьбы/покоя: sleep, stun, float…
func set_loop_state(state: StringName) -> void:
	_loop_state = state
	_tempo_reset()
	if _anim != null and _anim.has_state(String(state)):
		_sprite.visible = false
		_anim.visible = true
		_anim.play_state(String(state))
		_state = state
		_sync_facing()
		_desync_loop()
		return
	_show_fallback(state)


## Одноразовое состояние. true — пошёл клип; false — клипа нет, отработала заглушка.
func play_once(state: StringName) -> bool:
	if _anim != null and _anim.has_state(String(state)):
		# у удара свой кадр контакта: темп возвращаем ДО старта клипа, не на следующем кадре
		_tempo_reset()
		_anim.play_state(String(state))
		if _anim.current_state() == String(state):
			if _anim.is_hold(String(state)):
				_cancel_stub()
			_state = state
			_sync_facing()
			if _anim.is_hold(String(state)):
				_corpse_t = 0.0
				_corpse_driven = false
			return true
		return false
	_start_stub(state)
	return false


## Tick-хуки отмечают заявки уже выбранной цели; отдельного поиска целей у вида нет.
func begin_action_tick() -> void:
	_prepare_seen = false


func end_action_tick() -> void:
	if not _prepare_seen and _anim != null and _anim.is_preparing_attack():
		cancel_action()


func prepare_attack(remaining: float, target: Object = null) -> void:
	if remaining <= 0.0 or remaining > ATTACK_PREP_TIME:
		return
	_prepare_action(1.0 - remaining / ATTACK_PREP_TIME, target)


## Печать/зачитка быстро поднимает инструмент и ждёт действующего игрового события.
func prepare_special(remaining: float, total: float, target: Object = null) -> void:
	_prepare_action(clampf((total - remaining) / ATTACK_PREP_TIME, 0.0, 1.0), target)


func _prepare_action(progress: float, target: Object) -> void:
	if _anim == null or _corpse_t >= 0.0:
		return
	var target_id := target.get_instance_id() if is_instance_valid(target) else 0
	if _anim.is_preparing_attack() and target_id != _prepare_target_id:
		_anim.cancel_attack()
	_prepare_target_id = target_id
	_prepare_seen = true
	_tempo_reset()
	if _anim.prepare_attack(progress):
		_state = &"attack"
		_sync_facing()


func attack_impact() -> void:
	_prepare_seen = false
	if _anim == null or not _anim.has_state("attack"):
		play_once(&"attack")
		return
	_tempo_reset()
	if _anim.impact_attack():
		_state = &"attack"
		_sync_facing()


func cancel_action() -> void:
	_prepare_seen = false
	if _anim != null:
		_anim.cancel_attack()
		_state = StringName(_anim.current_state())
		_sync_facing()


## Вздрогнуть от урона: короткий одноразовый клип hit ПОВЕРХ ходьбы. Только из ходьбы —
## подъём, замах, сон, стан и смерть он не перебивает, а сам уступает замаху и смерти
## ("interruptible" в CfgAnim). Чисто вид: геймплей урона и таймеры его не ждут.
## Пружина сплющивания — на каждый удар, без отката: клип редкий, а удар должен ощущаться.
func react_hit() -> void:
	if _corpse_t < 0.0:
		_spring_v -= _m_hit_kick
		if hit_hook.is_valid():
			var f := Engine.get_process_frames()
			if f != _hook_frame:
				_hook_frame = f
				_hook_n = 0
			if _hook_n < CfgAnim.HIT_HOOK_PER_FRAME and f >= _hook_next:
				_hook_n += 1
				_hook_next = f + CfgAnim.HIT_HOOK_VIEW_FRAMES
				hit_hook.call(self)
	if _hit_cd > 0.0 or not has_clip(&"hit") or current_state() != &"walk":
		return
	if play_once(&"hit"):
		_hit_cd = HIT_REACT_CD


func has_clip(state: StringName) -> bool:
	return _anim != null and _anim.has_state(String(state))


func current_state() -> StringName:
	if _anim != null and _anim.visible and _stub_kind == "":
		return StringName(_anim.current_state())
	return _state


## Клипы и текстуры рисуются лицом ВПРАВО; dir < 0 — зеркалим. Клип разворачивается не
## щелчком, а сжатием по ширине за FLIP_TIME (первый вызов — сразу, без разворота на месте).
func set_facing(dir: float) -> void:
	set_direction(Vector2.LEFT if dir < 0.0 else Vector2.RIGHT)


## Полный вектор — только представление. Нулевой сохраняет последний взгляд.
func set_direction(direction: Vector2) -> void:
	if not direction.is_finite() or direction.is_zero_approx():
		return
	if absf(direction.x) > 0.0001:
		_legacy_facing = -1.0 if direction.x < 0.0 else 1.0
	if _anim != null:
		_anim.set_direction(direction)
	_sync_facing()


func _sync_facing() -> void:
	_facing = _legacy_facing
	if _anim != null and String(_anim.animation) != _anim.current_state():
		_facing = _anim.facing_sign()
	if not _face_set:
		_face_set = true
		_face_cur = _facing
		_apply_pivot()
	_sprite.flip_h = _legacy_facing < 0.0
	_refresh_clip_layout()


## Новый ракурс может иметь место под вертикальный шаг ниже ступней. Pivot — в пикселях PNG.
func _refresh_clip_layout() -> void:
	if _anim == null or _layout_cached == _anim.animation:
		return
	_layout_cached = _anim.animation
	_anim_local = _legacy_anim_local
	var def: Dictionary = _anim._clip_defs.get(String(_anim.animation), {})
	var pivot: Array = def.get("pivot_px", [])
	if pivot.size() == 2 and _anim.sprite_frames.get_frame_count(_anim.animation) > 0:
		var tex := _anim.sprite_frames.get_frame_texture(_anim.animation, 0)
		var fill := float(def.get("figure_fill", 0.0))
		if fill <= 0.0:
			fill = float(_def.get("figure_fill", 0.85))
		var sc := body_h / (float(tex.get_height()) * fill)
		var anchor := Vector2(float(pivot[0]), float(pivot[1]))
		var center := Vector2(tex.get_width(), tex.get_height()) * 0.5
		_anim_local = Transform2D(0.0, Vector2(sc, sc), 0.0, (center - anchor) * sc)
	_ap_sx = INF
	_apply_pivot()


func flash(color: Color = FLASH_COLOR, dur: float = 0.12) -> void:
	if not Settings.is_flashes_enabled():
		return
	_flash_color = color
	_flash_dur = maxf(dur, 0.001)
	_flash_t = _flash_dur
	_apply_modulate()


## Материал вида (PvP: цвет стороны, PvpSideLook) — на анимацию и на запасной спрайт.
func set_look_material(m: Material) -> void:
	if _anim != null:
		_anim.material = m
	_sprite.material = m


func look_material() -> Material:
	return _anim.material if _anim != null else _sprite.material


## Постоянный тинт: элитка (золото), фаза 2 босса (красный), союзник (зелёный).
func set_tint(c: Color) -> void:
	_tint = c
	_apply_modulate()


## Возраст трупа по часам мира (сущность знает точное время до уборки). Без вызова CharView
## считает сам по кадрам — при «Отсрочке» (мир медленнее) тогда тает чуть раньше уборки.
func set_corpse_age(t: float) -> void:
	if _corpse_t >= 0.0:
		_corpse_t = t
		_corpse_driven = true


## Конец боя (LegionWorld: итог или меню) — часы мира больше не идут, труп дотаивает по своим
## часам с того возраста, до которого его довёл мир. Пока бой идёт, в том числе в паузе и в
## hold (игра по переписке), труп стоит вместе с миром — verifier 26.09 (пункт C) поймал
## прежнюю эвристику «0,3 с без set_corpse_age — свои часы»: в hold дерево не на паузе, труп
## таял за 7 с раздумий и «оживал» первым же вызовом после снятия hold.
func release_corpse_clock() -> void:
	_corpse_driven = false


## Для слоя теней: множитель тени 0…1 (появление, таяние трупа, прозрачность вида).
func shadow_alpha() -> float:
	var a := modulate.a * _corpse_a
	if _pop_t >= 0.0:
		a *= clampf(_pop_t / maxf(_m_pop_time, 0.001) * 2.0, 0.0, 1.0)
	return a


func _cache_motion() -> void:
	_m_bob_px = float(_motion["bob"]) * body_h
	_m_sway = float(_motion["sway"])
	_m_lean = float(_motion["lean"])
	_m_float_px = float(_motion["float"]) * body_h
	_m_breath = float(_motion["breath"])
	_m_hit_kick = float(_motion["hit_kick"])
	_m_thud_kick = float(_motion["thud_kick"])
	_m_k = float(_motion["spring_k"])
	_m_c = float(_motion["spring_c"])
	_m_flip_rate = 2.0 / maxf(float(_motion["flip_time"]), 0.001)
	_m_pop_time = float(_motion["pop_time"])
	_m_pop_from = float(_motion["pop_from"])
	_m_corpse_fade = float(_motion["corpse_fade"])
	_m_corpse_sink_px = float(_motion["corpse_sink"]) * body_h
	_breath_w = TAU / maxf(_breath_period, 0.01)
	_stagger = _rng.randi_range(0, CfgAnim.BREATH_EVERY - 1)
	shadow_w_px = float(_motion["shadow_w"]) * body_h
	shadow_h_px = float(_motion["shadow_h"]) * body_h
	shadow_a = float(_motion["shadow_a"])


## Точка ступней в глобальных координатах (без поворота/оседания смерти — тень лежит на земле).
func ground_point() -> Vector2:
	var parent := get_parent() as Node2D
	var base := parent.global_position if parent != null else global_position
	return base + Vector2(0.0, _ground)


## Ограничивающий прямоугольник видимого тела в world space для редких проверок заслонения.
## Берём именно активный кадр и его фактические трансформации, а не только точку ступней.
func occlusion_world_rect() -> Rect2:
	var visual: Node2D = _anim if _anim != null and _anim.visible else _sprite
	if visual == null or not visual.visible:
		var h := maxf(1.0, body_h)
		return Rect2(global_position + Vector2(-h * 0.35, -h), Vector2(h * 0.7, h))
	var local_rect: Rect2
	if visual is AnimatedSprite2D:
		var animated := visual as AnimatedSprite2D
		var frames := animated.sprite_frames
		if frames == null or not frames.has_animation(animated.animation) \
				or frames.get_frame_count(animated.animation) <= animated.frame:
			var fallback_h := maxf(1.0, body_h)
			return Rect2(global_position + Vector2(-fallback_h * 0.35, -fallback_h),
				Vector2(fallback_h * 0.7, fallback_h))
		var frame_texture: Texture2D = frames.get_frame_texture(animated.animation, animated.frame)
		if frame_texture == null:
			return Rect2(global_position - Vector2(body_h * 0.35, body_h),
				Vector2(body_h * 0.7, body_h))
		var frame_size := frame_texture.get_size()
		var frame_origin := animated.offset
		if animated.centered:
			frame_origin -= frame_size * 0.5
		local_rect = Rect2(frame_origin, frame_size)
	else:
		local_rect = (_sprite as Sprite2D).get_rect()
	var points := [visual.to_global(local_rect.position),
		visual.to_global(Vector2(local_rect.end.x, local_rect.position.y)),
		visual.to_global(local_rect.end),
		visual.to_global(Vector2(local_rect.position.x, local_rect.end.y))]
	var first: Vector2 = points[0]
	var bounds := Rect2(first, Vector2.ZERO)
	for point: Vector2 in points:
		bounds = bounds.expand(point)
	return bounds


## Где ступни ниже position сущности, px (слой теней).
func ground_px() -> float:
	return _ground


func motion_value(key: String) -> float:
	return float(_motion.get(key, 0.0))


func _process(delta: float) -> void:
	_hit_cd = maxf(0.0, _hit_cd - delta)
	if _flash_t > 0.0:
		_flash_t = maxf(0.0, _flash_t - delta)
		_apply_modulate()
	if _stub_kind != "":
		_tick_stub(delta)
	_tick_still_walk(delta)
	_tick_direction()
	_sync_facing()
	_tick_walk_tempo(delta)
	_tick_stun_visual(delta)
	if _corpse_t >= 0.0 and _anim != null:
		_body.transform = _anim.death_pose(_ground, _facing)
	_tick_life(delta)


## Живость: пружина удара, разворот, появление, дыхание/шаг, таяние трупа.
## Цена кадра (verifier 26.09: +0,9 мс на 130 фигурах): числа живости — полями, а не словарём;
## кривая шага кэшируется при смене клипа; свойства опоры пишутся, только если изменились;
## фигура в покое пересчитывает дыхание раз в BREATH_EVERY кадров со сдвигом по экземплярам —
## период 2,6 с, амплитуда меньше пикселя, на глаз не отличить.
func _tick_life(delta: float) -> void:
	var busy := false
	# «Графика: экономная» (Settings): без пружины удара, подскока появления и дыхания —
	# самая частая работа (каждая идущая/стоящая фигура каждый кадр или через WALK/BREATH_EVERY).
	# Разворот и труп остаются: разворот — единственный способ отзеркалить клип, труп — B-049.
	if not economy_motion and (_spring != 0.0 or _spring_v != 0.0):
		# пружина — полуявный Эйлер с ограниченным шагом: устойчива и на долгом кадре
		var dt := minf(delta, 1.0 / 30.0)
		_spring_v += (-_m_k * _spring - _m_c * _spring_v) * dt
		_spring += _spring_v * dt
		if absf(_spring) < 1e-4 and absf(_spring_v) < 1e-3:
			_spring = 0.0
			_spring_v = 0.0
		busy = true
	if _face_cur != _facing:
		_face_cur = move_toward(_face_cur, _facing, delta * _m_flip_rate)
		busy = true
	if economy_motion:
		# верификатор 26.09: замороженный на 0,0 _pop_t гасил тень (shadow_alpha ниже) и,
		# вернувшись к полной графике, проигрывал подскок с опозданием — появление считаем
		# законченным сразу, а не копим его до включения полной.
		if _pop_t >= 0.0:
			_pop_t = -1.0
			busy = true
	elif _pop_t >= 0.0:
		_pop_t += delta
		if _pop_t >= _m_pop_time:
			_pop_t = -1.0
		busy = true
	if not economy_motion:
		_breath_t += delta
	if _corpse_t >= 0.0:
		# B-049: возраст трупа гонит foe.gd часами мира (set_corpse_age) — свои часы (реальный
		# delta) только пока никто не гонит их извне (труп Legionnaire — unit.gd своя уборка).
		# Мир стоит (пауза, hold, хит-стоп) — стоит и труп; конец боя отпускает его явно
		# (release_corpse_clock).
		if not _corpse_driven:
			_corpse_t += delta
		var left := CfgAnim.CORPSE_TTL - _corpse_t
		var a := clampf(left / _m_corpse_fade, 0.0, 1.0) if _m_corpse_fade > 0.0 else 1.0
		if a != _corpse_a:
			_corpse_a = a
			if _anim != null:
				_anim.modulate.a = a
			busy = true
	if economy_motion:
		if busy:
			_apply_pivot()
		return
	if not busy:
		_tick_n += 1
		if _walk_flag:
			# шаг: смещение 1–2 px на 30 Гц при движении самой фигуры на 60 Гц не видно
			if (_tick_n + _stagger) % CfgAnim.WALK_EVERY != 0:
				return
		else:
			if _m_breath == 0.0 and _m_float_px == 0.0 and _settled:
				return
			if (_tick_n + _stagger) % CfgAnim.BREATH_EVERY != 0:
				return
	_apply_pivot()


func _refresh_clip_cache() -> void:
	_clip_cached = _anim.animation
	_stride = _anim.stride_curve()
	_contact_ph = _anim.contact_phase()
	_frame_n = _anim.sprite_frames.get_frame_count(_clip_cached) if _anim.sprite_frames else 0


func _apply_pivot() -> void:
	if _anim == null:
		return
	var rot := 0.0
	var bob := 0.0
	var sx := 1.0
	var sy := 1.0
	# «Графика: экономная» — без дыхания/раскачки/наклона (тут) и без пружины удара/подскока
	# появления (ниже): клип играет как есть, живой остаётся только опора (низ) и разворот.
	if not economy_motion and _corpse_t < 0.0 and _anim != null and _anim.visible:
		if _anim.animation != _clip_cached:
			_refresh_clip_cache()
		var breath := sin(_breath_t * _breath_w)
		if _walk_flag and _stub_kind == "" and _anim.current_state() == "walk":
			if _frame_n > 0:
				var f := float(_anim.frame) + _anim.frame_progress
				var phase := f / float(_frame_n) - _contact_ph
				# корпус ниже всего на касании (ноги разнесены шире всего)
				if not _stride.is_empty():
					var n := _stride.size()
					var i := _anim.frame % n
					bob = _m_bob_px * lerpf(_stride[i], _stride[(i + 1) % n], _anim.frame_progress)
				rot = _m_sway * cos(TAU * phase) + _m_lean * _facing
			bob += _m_float_px * breath
		else:
			var st := StringName(_anim.current_state())
			if st == &"idle" or st == &"walk" or st == &"sleep":
				# покой (и замершая ходьба у врагов без клипа покоя) — дыхание
				sy += _m_breath * breath
				sx -= _m_breath * breath * 0.5
				bob += _m_float_px * breath
	if not economy_motion:
		# пружина удара: сплющился по высоте — раздался вширь
		sy += _spring
		sx -= _spring * 0.6
		if _pop_t >= 0.0:
			var s := lerpf(_m_pop_from, 1.0, _ease_out_back(_pop_t / _m_pop_time))
			sx *= s
			sy *= s
	var y := _ground + bob
	if _corpse_t >= 0.0:
		# перед уборкой тело оседает в землю вместе с таянием
		y += (1.0 - _corpse_a) * _m_corpse_sink_px
	sx *= _face_cur
	_settled = rot == 0.0 and bob == 0.0 and sx == _face_cur and sy == 1.0
	if rot == _ap_rot and y == _ap_y and sx == _ap_sx and sy == _ap_sy:
		return
	_ap_rot = rot
	_ap_y = y
	_ap_sx = sx
	_ap_sy = sy
	# одна запись вместо трёх свойств узла-опоры: опора(y, поворот, сжатие) · клип
	_anim.transform = Transform2D(rot, Vector2(sx, sy), 0.0, Vector2(0.0, y)) * _anim_local


static func _ease_out_back(x: float) -> float:
	var t := clampf(x, 0.0, 1.0) - 1.0
	const C1 := 1.70158
	return 1.0 + (C1 + 1.0) * t * t * t + C1 * t * t


## Толпа, шагающая в ногу, выглядит механически: зацикленный клип начинается со случайного
## кадра. Смещение — вид, на касание не влияет (у циклов его нет).
func _desync_loop() -> void:
	if _anim == null or _anim.sprite_frames == null:
		return
	var st := String(_anim.animation)
	if st == "" or not _anim.sprite_frames.has_animation(st):
		return
	if _anim.sprite_frames.get_animation_loop_mode(st) == SpriteFrames.LOOP_NONE:
		return
	var n := _anim.sprite_frames.get_frame_count(st)
	if n > 1:
		_anim.set_frame_and_progress(_rng.randi_range(0, n - 1), _rng.randf())


func _tick_stun_visual(delta: float) -> void:
	var stunned := char_id == "boss" and current_state() == &"stun"
	if not stunned and not _stun_visible:
		return
	_stun_visible = stunned
	_stun_time = _stun_time + delta if stunned else 0.0
	_body.rotation = sin(_stun_time * CfgAnim.STUN_ORBIT_RATE) * CfgAnim.STUN_SWAY
	queue_redraw()


func _draw() -> void:
	if not _stun_visible:
		return
	var center := Vector2(0.0, -body_h * 0.56)
	for i in CfgAnim.STUN_STAR_COUNT:
		var phase := _stun_time * CfgAnim.STUN_ORBIT_RATE + TAU * i / CfgAnim.STUN_STAR_COUNT
		var at := center + Vector2(cos(phase) * body_h * 0.25, sin(phase) * body_h * 0.055)
		var points := PackedVector2Array()
		for tip in 10:
			var angle := TAU * tip / 10.0 - PI / 2.0 + phase * 0.2
			var radius := body_h * (0.037 if tip % 2 == 0 else 0.016)
			points.append(at + Vector2.from_angle(angle) * radius)
		draw_colored_polygon(points, Color(1.0, 0.86, 0.3))
		points.append(points[0])
		draw_polyline(points, Color(0.17, 0.10, 0.22), 1.5, true)


## Враг выбирает walk/idle по фактическому пути, не меняя таймеров/позиции симуляции.
## Старый вид без idle вместо переключения просто замораживает walk на месте.
func _tick_still_walk(delta: float) -> void:
	if _anim == null or not _anim.visible:
		return
	var pos := global_position
	var moved := _last_pos != Vector2.INF and pos.distance_squared_to(_last_pos) > 0.0001
	_last_pos = pos
	if _anim.has_state("idle"):
		if not locomotion_from_position:
			return
		var state := _anim.current_state()
		# Сон/пробуждение/смерть принадлежат явному событию. Подготовку спецудара
		# также нельзя сбить движением (нотариус может шагать до остановки).
		if state not in ["idle", "walk", "attack"] or _anim.is_preparing_attack():
			_still_t = 0.0
			return
		if moved:
			_still_t = 0.0
			if state != "walk":
				set_locomotion(1.0)
			_walk_flag = _anim.current_state() == "walk"
		else:
			_still_t += delta
			if _still_t >= STILL_FREEZE and state == "walk":
				set_locomotion(0.0)
		return
	if _anim.current_state() != "walk":
		_still_t = 0.0
		_walk_flag = false
		return
	if moved:
		_still_t = 0.0
		_walk_flag = true
		if not _anim.is_playing():
			_anim.play()
		return
	_still_t += delta
	if _still_t >= STILL_FREEZE and _anim.is_playing():
		_anim.pause()
		_walk_flag = false


## Обход препятствия может заменить диагональ вертикальным шагом: берём фактический путь.
func _tick_direction() -> void:
	var pos := global_position
	var delta_pos := pos - _direction_pos
	var known := _direction_pos != Vector2.INF
	_direction_pos = pos
	if known and delta_pos.length_squared() > 0.0001 \
			and delta_pos.length() < CfgAnim.WALK_TEMPO_JUMP_PX \
			and current_state() == &"walk":
		set_direction(delta_pos)


## Темп клипа walk по фактической скорости узла (B-206): рельеф, замедление печатью, «Щитовой
## инспектор» меняют скорость сущности, а fps клипа посчитан под расчётную — на замедлении ноги
## обгоняли тело. Скорость видна из движения самого узла (как в _tick_still_walk), логику не
## читаем и не трогаем. ТОЛЬКО пока играет walk: у удара свой кадр контакта — его темп не наш
## (иначе сдвинулся бы урон), при смене клипа темп возвращается сразу (_tempo_reset).
func _tick_walk_tempo(delta: float) -> void:
	if _walk_ref <= 0.0 or _anim == null:
		return
	if not _anim.visible or _stub_kind != "" or _anim.current_state() != "walk" \
			or not _anim.is_playing():
		if _tempo_on or _tempo_time > 0.0:
			_tempo_reset()
		return
	var pos := global_position
	if _tempo_pos != Vector2.INF and delta > 0.0:
		var d := pos.distance_to(_tempo_pos)
		if d < CfgAnim.WALK_TEMPO_JUMP_PX:
			var k := exp(-delta / CfgAnim.WALK_TEMPO_TAU)
			_tempo_dist = _tempo_dist * k + d
			_tempo_time = _tempo_time * k + delta
	_tempo_pos = pos
	if _tempo_time < CfgAnim.WALK_TEMPO_WARMUP:
		return
	_tempo = clampf(_tempo_dist / _tempo_time / _walk_ref,
		CfgAnim.WALK_TEMPO_MIN, CfgAnim.WALK_TEMPO_MAX)
	if absf(_anim.speed_scale - _base_speed * _tempo) > 0.005:
		_anim.speed_scale = _base_speed * _tempo
	_tempo_on = true


## Вернуть клипу базовый темп и начать замер заново (смена клипа, остановка).
func _tempo_reset() -> void:
	if _anim != null:
		_anim.speed_scale = 1.0
	_tempo_on = false
	_tempo = 1.0
	_tempo_dist = 0.0
	_tempo_time = 0.0
	_tempo_pos = Vector2.INF


## Текущий множитель темпа ходьбы (1 — расчётная скорость; для тестов и отладки).
func walk_tempo() -> float:
	return _tempo


## Фактический темп проигрывания клипа (speed_scale) — для тестов.
func clip_speed_scale() -> float:
	return _anim.speed_scale if _anim != null else 1.0


func _apply_modulate() -> void:
	var k := _flash_t / _flash_dur if _flash_t > 0.0 else 0.0
	if not Settings.is_flashes_enabled():
		k = 0.0
	var c := _tint.lerp(Color(_flash_color, _tint.a), k)
	if _anim != null:
		_anim.self_modulate = c
	_sprite.self_modulate = c


func _show_fallback(state: StringName) -> void:
	var fallback: Dictionary = _def.get("fallback", {})
	var key := String(state)
	if not fallback.has(key):
		key = "idle" if fallback.has("idle") else ""
	var tex_map: Dictionary = _entry(char_id)["tex"]
	if key == "" or not tex_map.has(key):
		_sprite.visible = false
		return
	var tex: Texture2D = tex_map[key]
	var frac := float((fallback[key] as Dictionary).get("frac", 1.0))
	# рисуем весь квадратный холст мастера так, чтобы КОНТЕНТ был ровно body_h
	var s := body_h / frac / float(tex.get_width())
	_sprite.texture = tex
	_sprite.scale = Vector2(s, s)
	_sprite.visible = true
	if _anim != null:
		_anim.visible = false
	_state = state


func _start_stub(state: StringName) -> void:
	if _corpse_t >= 0.0:
		return
	var stubs: Dictionary = _def.get("stub", {})
	var stub: Dictionary = stubs.get(String(state), {})
	var kind := String(stub.get("kind", "none"))
	var dur := float(stub.get("dur", 0.0))
	# у заглушки нет кадра касания — урон по таймеру геймплея, контакт сообщаем сразу
	contact.emit(state)
	match kind:
		"flash":
			flash(FLASH_COLOR, dur)
			finished.emit(state)
			return
		"pose":
			_show_fallback(state)
	if dur <= 0.0:
		finished.emit(state)
		return
	_stub_kind = kind
	_stub_state = state
	_stub_t = 0.0
	_stub_dur = dur
	_tick_stub(0.0)


func _tick_stub(delta: float) -> void:
	_stub_t += delta
	var k := clampf(_stub_t / maxf(_stub_dur, 0.001), 0.0, 1.0)
	match _stub_kind:
		"rise":
			var eased := smoothstep(0.0, 1.0, k)
			_body.position.y = (1.0 - eased) * body_h * RISE_DEPTH
			_body.scale = Vector2(1.0 + 0.12 * (1.0 - eased), 0.55 + 0.45 * eased)
			_body.modulate.a = smoothstep(0.0, 0.4, k)
		"fall":
			_body.position.y = k * body_h * FALL_DROP
			_body.rotation = k * FALL_TILT * _facing
	if k < 1.0:
		return
	var done := _stub_state
	var kind := _stub_kind
	if kind != "fall":
		_cancel_stub()
	else:
		_stub_kind = ""
		_stub_state = &""
	# «fall» оставляет тело лежать; «pose» возвращает зацикленное состояние
	if kind == "pose":
		_show_fallback(_loop_state)
	finished.emit(done)


func _cancel_stub() -> void:
	_stub_kind = ""
	_stub_state = &""
	_body.transform = Transform2D.IDENTITY
	_body.modulate.a = 1.0


func _on_clip_contact(state_name: String) -> void:
	contact.emit(StringName(state_name))


func _on_clip_finished(state_name: String) -> void:
	_state = StringName(_anim.current_state())
	_sync_facing()
	if _anim.is_hold(state_name):
		# тело ударилось о землю — короткий шлепок пружиной
		_spring_v -= _m_thud_kick
	finished.emit(StringName(state_name))
