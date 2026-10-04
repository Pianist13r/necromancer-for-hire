class_name CharAnim
extends AnimatedSprite2D
##
## Слой покадровой анимации персонажей — общий для ЛЮБОГО персонажа игры, не только
## скелета-подрядчика. Тот же подход, что в `scripts/anim_lab.gd` (там он проверен на
## экран: загрузка клипов из папок на диске в SpriteFrames, хит-стоп на кадре контакта),
## перенесён сюда как переиспользуемый класс, а не переизобретён заново.
##
## Состояния делятся на два рода:
## - зациклены (покой, ходьба) — переключаются свободно в любой момент;
## - одноразовые (удар, получение урона, возникновение) — БЛОКИРУЮТ переключение до
##   конца клипа (`animation_finished`), после чего сами возвращают персонажа в
##   состояние по умолчанию.
##
## Кадр контакта (нужен, чтобы урон наносился в момент касания оружием, а не по
## таймеру) даёт сигнал `contact_frame` РОВНО ОДИН РАЗ за проигрывание клипа.
##
## Если папка клипа не найдена или пуста — `push_warning` и персонаж остаётся в
## прежнем состоянии; падать нельзя, потому что реальные клипы могут появиться позже.
##

signal contact_frame(state_name: String)
## одноразовый клип доиграл (перед возвратом в default_state)
signal clip_finished(state_name: String)

const DIRECTIONS := ["e", "se", "s", "sw", "w", "nw", "n", "ne"]
const CANONICAL := ["e", "se", "s", "se", "e", "ne", "n", "ne"]
const SOURCE_DIRECTIONS := ["e", "se", "s", "ne", "n"]

var default_state := "idle"

## имя состояния -> {loop: bool, contact_frame: int}. Заполняется только для
## РЕАЛЬНО загруженных клипов — ненайденные состояния сюда не попадают.
var _clip_defs: Dictionary = {}
var _current_state := ""
var _contact_fired := false
var _locked := false          ## true, пока идёт одноразовый (незацикленный) клип
var _direction := Vector2.RIGHT
var _shown_sector := 0
var _prepared := false
var _prepare_return := ""
var _impact_ready := false


## `clips`: имя состояния -> {"dir": String, "fps": float, "loop": bool, "contact_frame": int
## (-1 — клип без кадра касания)}. `dir` — либо `res://...` (импортированные текстуры: так
## грузит бой, это работает и в экспорте), либо путь от корня проекта ВЫШЕ res:// (лаборатория
## анимации: кадры перегенерируются без импорта Godot).
##
## Боевой код зовёт не это, а CharView: он строит кадры ОДИН раз на персонажа (кэш), а не на
## каждый экземпляр — чтение диска в кадре боя запрещено правилом проекта.
func setup(clips: Dictionary, default_state_name: String = "idle") -> void:
	var built := load_clips(clips)
	setup_frames(built["frames"], built["defs"], default_state_name)


## Подключить готовые кадры (общий SpriteFrames на всех персонажей одного вида — у каждого
## узла своё проигрывание, а ресурс кадров один).
func setup_frames(
	frames: SpriteFrames, defs: Dictionary, default_state_name: String = "idle"
) -> void:
	default_state = default_state_name
	_clip_defs = defs.duplicate(true)
	sprite_frames = frames
	if not frame_changed.is_connected(_on_frame_changed):
		frame_changed.connect(_on_frame_changed)
	if not animation_finished.is_connected(_on_animation_finished):
		animation_finished.connect(_on_animation_finished)


## Собрать SpriteFrames из описаний клипов. Возвращает {"frames": SpriteFrames, "defs":
## {state: {loop, contact_frame}}}; в defs попадают только РЕАЛЬНО найденные клипы.
static func load_clips(clips: Dictionary) -> Dictionary:
	# Внутренние имена кадров не становятся состояниями боя: walk остаётся walk.
	var expanded := clips.duplicate(true)
	for state: String in clips:
		var base: Dictionary = clips[state]
		var directions: Dictionary = base.get("directions", {})
		for direction: String in directions:
			if direction not in CANONICAL:
				continue
			var variant := base.duplicate(true)
			var orientation: Dictionary = directions[direction]
			variant["dir"] = orientation.get("dir", "")
			# Темп одноразового клипа — часть боевого контакта; ракурс его не меняет.
			if bool(base.get("loop", false)):
				variant["fps"] = orientation.get("fps", base.get("fps", 8.0))
			variant["directions"] = {}
			expanded[state + "_" + direction] = variant
	var frames := SpriteFrames.new()
	var defs := {}
	var project := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var root := project.get_base_dir()
	for state_name in expanded.keys():
		var def: Dictionary = expanded[state_name]
		var dir := String(def.get("dir", ""))
		var textures := _load_textures(dir, root)
		if textures.is_empty():
			push_warning("CharAnim: клип '%s' не найден или пуст (%s)" % [state_name, dir])
			continue
		frames.add_animation(state_name)
		frames.set_animation_speed(state_name, float(def.get("fps", 8.0)))
		var loop := bool(def.get("loop", false))
		frames.set_animation_loop_mode(
			state_name, SpriteFrames.LOOP_LINEAR if loop else SpriteFrames.LOOP_NONE
		)
		# clip.json кладёт tools/anim_inbetween.py: промежуточные кадры идут с долей исходного
		# шага, поэтому fps в CfgAnim остаётся исходным, а длина клипа — прежней.
		var meta := _clip_meta(dir, root)
		var durations: Array = meta.get("durations", [])
		for i in textures.size():
			var dur := float(durations[i]) if i < durations.size() else 1.0
			frames.add_frame(state_name, textures[i], dur)
		defs[state_name] = {
			"loop": loop,
			# Новые клипы указывают контакт индексом финального PNG; старые сохраняют remap.
			"contact_frame": clampi(int(meta.get("contact_frame",
				_remap_frame(int(def.get("contact_frame", -1)), meta))), -1, textures.size() - 1),
			"hold": bool(def.get("hold", false)),
			"interruptible": bool(def.get("interruptible", false)),
			# разнос ног по кадрам цикла (0…1) — CharView качает корпус в такт шагам
			"stride": PackedFloat32Array(meta.get("stride", [])),
			"contact_phase": float(meta.get("contact_phase", 0.0)),
			"pivot_px": meta.get("pivot_px", []),
			"figure_fill": float(meta.get("figure_fill", 0.0)),
		}
	for state: String in clips:
		if not defs.has(state):
			continue
		var available := {}
		for direction: String in SOURCE_DIRECTIONS:
			var key := state + "_" + direction
			if defs.has(key):
				if bool(defs[state]["loop"]) or _same_timing(frames, defs, state, key):
					available[direction] = key
				else:
					push_warning("CharAnim: ракурс '%s' меняет длительность или контакт — пропущен" % key)
		defs[state]["directions"] = available
	return {"frames": frames, "defs": defs}


static func _same_timing(frames: SpriteFrames, defs: Dictionary, base: String, key: String) -> bool:
	var duration := _clip_time(frames, base, frames.get_frame_count(base))
	var other := _clip_time(frames, key, frames.get_frame_count(key))
	if not is_equal_approx(duration, other):
		return false
	var contact := int(defs[base]["contact_frame"])
	if contact < 0:
		return true
	return is_equal_approx(_clip_time(frames, base, contact),
		_clip_time(frames, key, int(defs[key]["contact_frame"])))


static func _clip_time(frames: SpriteFrames, state: String, count: int) -> float:
	var duration := 0.0
	for i in mini(count, frames.get_frame_count(state)):
		duration += frames.get_frame_duration(state, i)
	return duration / frames.get_animation_speed(state)


## Описание клипа рядом с кадрами (clip.json) или пустое — у рисованных клипов его нет.
static func _clip_meta(dir: String, root: String) -> Dictionary:
	var path := dir.path_join("clip.json") if dir.is_absolute_path() \
		else root.path_join(dir).path_join("clip.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## contact_frame в CfgAnim — номер ИСХОДНОГО кадра; после вставки промежуточных он сдвигается
## (src_index: новый номер каждого исходного кадра), а момент касания остаётся тем же.
static func _remap_frame(src_frame: int, meta: Dictionary) -> int:
	var index: Array = meta.get("src_index", [])
	if src_frame < 0 or src_frame >= index.size():
		return src_frame
	return int(index[src_frame])


static func _load_textures(dir: String, root: String) -> Array[Texture2D]:
	var textures: Array[Texture2D] = []
	var i := 0
	if dir.begins_with("res://"):
		while ResourceLoader.exists(dir.path_join("spr_%02d.png" % i)):
			var tex := load(dir.path_join("spr_%02d.png" % i)) as Texture2D
			if tex == null:
				break
			textures.append(tex)
			i += 1
		return textures
	var abs_dir := dir if dir.is_absolute_path() else root.path_join(dir)
	while FileAccess.file_exists(abs_dir.path_join("spr_%02d.png" % i)):
		var img := Image.load_from_file(abs_dir.path_join("spr_%02d.png" % i))
		if img == null:
			break
		textures.append(ImageTexture.create_from_image(img))
		i += 1
	return textures


## Загружен ли клип этого состояния. Нужно вызывающему коду, чтобы решать
## по факту, а не по вере: клипа может не быть на диске, и тогда логика,
## завязанная на кадр контакта, должна честно откатиться на прежнее поведение.
func current_state() -> String:
	return _current_state


func has_state(state_name: String) -> bool:
	return _clip_defs.has(state_name)


## Клип-«труп»: последний кадр остаётся лежать (hold).
func is_hold(state_name: String) -> bool:
	return _clip_defs.has(state_name) and bool(_clip_defs[state_name].get("hold", false))


## Разнос ног 0…1 по кадрам текущего клипа (из clip.json; пусто — кривой нет). CharView
## кэширует её при смене клипа и качает корпус в такт нарисованным шагам.
func stride_curve() -> PackedFloat32Array:
	var st := String(animation)
	if not _clip_defs.has(st):
		return PackedFloat32Array()
	return _clip_defs[st].get("stride", PackedFloat32Array())


func contact_phase() -> float:
	var st := String(animation)
	if not _clip_defs.has(st):
		return 0.0
	return float(_clip_defs[st].get("contact_phase", 0.0))


## Переключить состояние. Зацикленные — свободно; во время одноразового клипа
## (удар, получение урона) заявка игнорируется, пока клип не доиграет сам.
func play_state(state_name: String) -> void:
	if not _clip_defs.has(state_name):
		push_warning(
			"CharAnim: состояние '%s' не загружено — остаюсь в '%s'" % [state_name, _current_state]
		)
		return
	if _prepared:
		_prepared = false
		_locked = false
	# Старт локомоции не блокирует бой: атака/урон могут прервать перенос веса.
	# Повторный запрос walk от игрового цикла не должен перезапускать intro.
	if _current_state == "walk_start" and state_name == "walk":
		return
	if _current_state == "idle" and state_name == "walk" and has_state("walk_start"):
		play_state("walk_start")
		return
	var one_shot := not bool(_clip_defs[state_name]["loop"])
	if _locked and state_name != _current_state:
		# Одноразовый клип блокирует всё, кроме случая «interruptible»: такой клип (появление
		# призывника) уступает другому ОДНОРАЗОВОМУ — замах обязан пойти сразу, иначе кадр
		# контакта сдвинется и анимация изменит бой. Зацикленные его не перебивают.
		# Смерть («hold») перебивает любой одноразовый клип: враг, убитый посреди замаха или
		# вздрагивания, иначе доигрывал его и вставал обратно в ходьбу вместо трупа.
		var preempt := bool(_clip_defs[state_name].get("hold", false))
		var yields := bool(_clip_defs[_current_state].get("interruptible", false))
		# Закончившее касание не держит шагающую сущность в длинном recovery.
		var resume_walk := state_name == "walk" and _impact_ready and _contact_fired
		if not preempt and not resume_walk and not (one_shot and yields):
			return
	_impact_ready = false
	if _current_state == state_name and is_playing():
		if not one_shot:
			return
		# Повторная заявка на ОДНОРАЗОВЫЙ клип (второй удар подряд) — не игнорируем,
		# а начинаем его заново. Иначе кадр контакта за этот замах уже отыграл, новый
		# не наступит, и удар молча пропадёт: замер показал падение демо-бота с 6/6
		# побед до 1/6 именно из-за потерянных ударов.
		_contact_fired = false
		frame = 0
		_shown_sector = direction_sector(_direction)
		play(_animation_for(state_name))
		return
	_current_state = state_name
	_contact_fired = false
	_locked = one_shot and state_name != "walk_start"
	_shown_sector = direction_sector(_direction)
	play(_animation_for(state_name))


## Подготовка — поза по часам симуляции, без замка и без сигнала контакта.
func prepare_attack(progress: float) -> bool:
	if not has_state("attack") or (_locked and _current_state != "attack"):
		return false
	if _locked and not _prepared:
		return false
	if not _prepared:
		_prepare_return = _current_state if has_state(_current_state) else default_state
	_prepared = true
	_impact_ready = false
	_current_state = "attack"
	_locked = false
	_contact_fired = false
	_shown_sector = direction_sector(_direction)
	var key := _animation_for("attack")
	var cf := int(_clip_defs[key]["contact_frame"])
	if cf <= 0:
		cancel_attack()
		return false
	if String(animation) != key:
		play(key)
	pause()
	var remaining := clampf(progress, 0.0, 0.999999) * _clip_time(sprite_frames, key, cf)
	_seek_seconds(remaining)
	return true


## Реальный удар уже совершён: контактная поза сейчас, recovery после неё.
## Этот метод не вызывает игровой урон; первый удар и повтор не ждут замаха.
func impact_attack() -> bool:
	if not has_state("attack") or is_hold(_current_state):
		return false
	_prepared = false
	_current_state = "attack"
	_impact_ready = true
	_locked = true
	# play() может вернуть кадр 0: сигнал должен относиться к выбранной impact-позе.
	_contact_fired = true
	_shown_sector = direction_sector(_direction)
	var key := _animation_for("attack")
	play(key)
	var cf := int(_clip_defs[key]["contact_frame"])
	set_frame_and_progress(maxi(0, cf), 0.0)
	contact_frame.emit("attack")
	return true


func is_preparing_attack() -> bool:
	return _prepared


## Отмена подготовки/остатка удара не поднимает труп и не меняет таймеров боя.
func cancel_attack() -> void:
	if _current_state != "attack":
		return
	var next := _prepare_return if _prepared else default_state
	_prepared = false
	_locked = false
	_current_state = ""
	play_state(next if has_state(next) else default_state)


func _seek_seconds(seconds: float) -> void:
	var remaining := maxf(0.0, seconds) * sprite_frames.get_animation_speed(animation)
	for i in sprite_frames.get_frame_count(animation):
		var duration := sprite_frames.get_frame_duration(animation, i)
		if remaining < duration:
			set_frame_and_progress(i, remaining / duration)
			return
		remaining -= duration


## Нулевой вектор не разворачивает остановившуюся фигуру. Удар остаётся прежним клипом.
func set_direction(direction: Vector2) -> void:
	if not direction.is_finite() or direction.is_zero_approx():
		return
	_direction = direction.normalized()
	if _current_state not in ["idle", "walk"]:
		return
	_shown_sector = direction_sector(_direction)
	var target := _animation_for(_current_state)
	if target == String(animation):
		return
	var phase := cycle_phase()
	var was_playing := is_playing()
	play(target)
	_seek_phase(phase)
	if not was_playing:
		pause()


static func direction_sector(direction: Vector2) -> int:
	return posmod(int(floor(direction.angle() / (PI / 4.0) + 0.5)), 8)


func _animation_for(state: String) -> String:
	var variants: Dictionary = _clip_defs.get(state, {}).get("directions", {})
	return String(variants.get(CANONICAL[direction_sector(_direction)], state))


## CharView зеркалит вокруг ступней своей трансформацией; здесь только выбор зеркала.
func facing_sign() -> float:
	if String(animation) != _current_state:
		return -1.0 if _shown_sector in [3, 4, 5] else 1.0
	return -1.0 if _direction.x < 0.0 else 1.0


## Фаза измеряется длительностями кадров: клипы с разным числом inbetween не сбивают шаг.
func cycle_phase() -> float:
	if sprite_frames == null or not sprite_frames.has_animation(animation):
		return 0.0
	var total := 0.0
	var elapsed := 0.0
	for i in sprite_frames.get_frame_count(animation):
		var duration := sprite_frames.get_frame_duration(animation, i)
		total += duration
		if i < frame:
			elapsed += duration
		elif i == frame:
			elapsed += duration * frame_progress
	return elapsed / total if total > 0.0 else 0.0


func _seek_phase(phase: float) -> void:
	var total := 0.0
	for i in sprite_frames.get_frame_count(animation):
		total += sprite_frames.get_frame_duration(animation, i)
	var remaining := clampf(phase, 0.0, 0.999999) * total
	for i in sprite_frames.get_frame_count(animation):
		var duration := sprite_frames.get_frame_duration(animation, i)
		if remaining < duration:
			set_frame_and_progress(i, remaining / duration)
			return
		remaining -= duration


## Разворот персонажа по горизонтали.
func set_facing(dir: float) -> void:
	flip_h = dir < 0.0


func _on_frame_changed() -> void:
	if _prepared or not _clip_defs.has(_current_state):
		return
	var def: Dictionary = _clip_defs.get(String(animation), _clip_defs[_current_state])
	var cf := int(def["contact_frame"])
	if cf >= 0 and frame == cf and not _contact_fired:
		_contact_fired = true
		contact_frame.emit(_current_state)


func _on_animation_finished() -> void:
	if _current_state == "walk_start":
		_current_state = ""
		_locked = false
		play_state("walk")
		return
	if _clip_defs.has(_current_state) and not bool(_clip_defs[_current_state]["loop"]):
		if bool(_clip_defs[_current_state].get("hold", false)):
			# «hold» (смерть): последний кадр — труп, он остаётся и держит замок, чтобы
			# ходьба/покой тело не подняли. Выход из него — только новый вид.
			clip_finished.emit(_current_state)
			return
		_locked = false
		var done := _current_state
		play_state(default_state)
		clip_finished.emit(done)
