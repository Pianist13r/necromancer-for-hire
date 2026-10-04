class_name SfxGen
extends RefCounted
##
## Процедурные боевые SFX: генерируем AudioStreamWAV математикой в рантайме,
## без внешних файлов. Тёмное фэнтези с офисной сатирой — звуки короткие
## и сухие. Каждый поток строится один раз и кэшируется в статическом
## словаре, чтобы в кадре боя не было аллокаций и повторного синтеза.
##

const MIX_RATE := 22050
## Пик держим ниже максимума int16 — запас против округления при микшировании
## нескольких голосов одновременно.
const PEAK_LIMIT := 0.7
const INT16_MAX := 32767.0
## Мгновенная атака — но не мгновеннее пары сэмплов, иначе щелчок на старте.
const ATTACK_SEC := 0.003

static var _cache: Dictionary = {}

## Список поддерживаемых id — контракт со звуковым слоем игры (audio.gd).
static func ids() -> PackedStringArray:
	return [
		"skel_hit",
		"enemy_die",
		"cauldron_hit",
		"rune_draw",
		"rune_fail",
		"cast_q",
		"cast_w",
		"cast_e",
		"wave_start",
		"wave_clear",
		"mine_place",
		"mine_boom",
		"totem_place",
		"ult_ready",
		"ult_cast",
		"ult_blast",
		"item_get",
	]


## Вернуть готовый поток по id. Первый вызов на id генерирует и кэширует,
## дальнейшие — отдают кэш.
## Кэш живёт в статике класса, а движок проверяет утечки ДО выгрузки скриптов — из-за этого
## на выходе он честно ругался «AudioStreamWAV leaked / resources still in use». Освобождаем
## сами, когда звуковой слой уходит из дерева.
static func clear_cache() -> void:
	_cache.clear()


static func get_stream(id: String) -> AudioStreamWAV:
	if _cache.has(id):
		return _cache[id]
	var samples := _synthesize(id)
	var stream := _to_stream(samples)
	_cache[id] = stream
	return stream


# ── Синтез по id ─────────────────────────────────────────────────────────────

## Построить массив сэмплов float в диапазоне [-1, 1] для данного id.
## Каждый id использует свой RandomNumberGenerator с фиксированным seed —
## звук должен быть одинаковым между запусками игры.
static func _synthesize(id: String) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(id)
	match id:
		"skel_hit":
			return _skel_hit(rng)
		"enemy_die":
			return _enemy_die(rng)
		"cauldron_hit":
			return _cauldron_hit(rng)
		"rune_draw":
			return _rune_draw()
		"rune_fail":
			return _rune_fail()
		"cast_q":
			return _cast_q(rng)
		"cast_w":
			return _cast_w()
		"cast_e":
			return _cast_e(rng)
		"wave_start":
			return _wave_start()
		"wave_clear":
			return _wave_clear()
		"mine_place":
			return _mine_place()
		"mine_boom":
			return _mine_boom(rng)
		"totem_place":
			return _totem_place(rng)
		"ult_ready":
			return _ult_ready()
		"ult_cast":
			return _ult_cast(rng)
		"ult_blast":
			return _ult_blast(rng)
		"item_get":
			return _item_get()
		_:
			push_error("SfxGen: неизвестный id '%s'" % id)
			return PackedFloat32Array()


## Удар костью по телу: шум с очень быстрым спадом + низкий призвук ~140 Гц,
## имитирующий глухой стук кости о доспех.
static func _skel_hit(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.12
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 42.0)
		var noise := rng.randf_range(-1.0, 1.0)
		var thud := sin(TAU * 140.0 * t)
		out[i] = (noise * 0.65 + thud * 0.35) * env
	return out


## «Упокоение»: нисходящий свип 400→90 Гц с шумовым хвостом — враг рассыпается.
static func _enemy_die(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.28
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var freq := lerpf(400.0, 90.0, frac)
		phase += freq / MIX_RATE
		var env := exp(-t * 7.0)
		var tone := sin(TAU * phase)
		var noise := rng.randf_range(-1.0, 1.0)
		out[i] = (tone * 0.6 + noise * 0.4 * frac) * env
	return out


## Тяжёлый удар по котлу: низкий бум 70–90 Гц + металлический призвук
## из трёх негармоничных частот (даёт «звон металла», а не чистый тон).
static func _cauldron_hit(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.35
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var boom_freq := 78.0
	var partials := [730.0, 1150.0, 1680.0]
	for i in range(n):
		var t := float(i) / MIX_RATE
		var boom_env := exp(-t * 9.0)
		var metal_env := exp(-t * 14.0)
		var boom := sin(TAU * boom_freq * t) * boom_env
		var metal := 0.0
		for p in partials:
			metal += sin(TAU * p * t)
		metal = metal / partials.size() * metal_env
		var noise := rng.randf_range(-1.0, 1.0) * exp(-t * 60.0)
		out[i] = boom * 0.7 + metal * 0.25 + noise * 0.2
	return out


## Начало черчения руны: тихий восходящий тон 300→600 Гц с мягкой атакой —
## сигнал «линия пошла», не должен резать ухо.
static func _rune_draw() -> PackedFloat32Array:
	var dur := 0.15
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var freq := lerpf(300.0, 600.0, frac)
		phase += freq / MIX_RATE
		# мягкая атака и мягкий спад — синус-огибающая на весь звук
		var env := sin(PI * frac) * 0.6
		out[i] = sin(TAU * phase) * env
	return out


## Отказ черчения: короткий низкий «пшик» 200→120 Гц — руна не сложилась.
static func _rune_fail() -> PackedFloat32Array:
	var dur := 0.12
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var freq := lerpf(200.0, 120.0, frac)
		phase += freq / MIX_RATE
		var env := exp(-t * 20.0)
		out[i] = sin(TAU * phase) * env
	return out


## Электрический разряд (Q): белый шум, промодулированный дребезгом 40–90 Гц —
## амплитудная модуляция даёт ощущение потрескивающей молнии.
static func _cast_q(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.35
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var mod_phase := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var mod_freq := lerpf(90.0, 40.0, frac)
		mod_phase += mod_freq / MIX_RATE
		# модуляция в диапазоне [0.2, 1.0] — не гасим шум полностью в провалах
		var buzz := 0.6 + 0.4 * sin(TAU * mod_phase)
		var noise := rng.randf_range(-1.0, 1.0)
		var env := exp(-t * 6.0)
		out[i] = noise * buzz * env
	return out


## Воскрешение (W): восходящий тон 180→520 Гц с лёгким вибрато — тёплое,
## «оживляющее» заклинание.
static func _cast_w() -> PackedFloat32Array:
	var dur := 0.5
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var base_freq := lerpf(180.0, 520.0, frac)
		var vibrato := sin(TAU * 6.0 * t) * 4.0
		phase += (base_freq + vibrato) / MIX_RATE
		var env := sin(PI * frac)
		out[i] = sin(TAU * phase) * env
	return out


## Аврал (E): гулкий свип 120→300 Гц + шумовой ветер — призыв всех к оружию.
static func _cast_e(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.45
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	# лёгкая фильтрация шума простым скользящим средним — из белого шума
	# получается более «ветреный», приглушённый оттенок
	var prev_noise := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var freq := lerpf(120.0, 300.0, frac)
		phase += freq / MIX_RATE
		var env := sin(PI * frac)
		var tone := sin(TAU * phase) * env
		var raw_noise := rng.randf_range(-1.0, 1.0)
		var wind := (raw_noise + prev_noise) * 0.5
		prev_noise = raw_noise
		out[i] = tone * 0.65 + wind * env * 0.35
	return out


## Гонг начала волны: низкий тон 110 Гц + обертоны 1.7x и 2.4x (негармоничные —
## настоящий гонг, не чистая квинта/октава), долгое затухание.
static func _wave_start() -> PackedFloat32Array:
	var dur := 0.9
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var base_freq := 110.0
	var ratios := [1.0, 1.7, 2.4]
	var weights := [0.55, 0.28, 0.17]
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 4.2)
		var s := 0.0
		for k in range(ratios.size()):
			s += sin(TAU * base_freq * ratios[k] * t) * weights[k]
		out[i] = s * env
	return out


## Облегчение при зачистке волны: два тона подряд, до-мажорная терция вверх
## (392 → 587 Гц), каждый по 0.18 c с мягкими краями.
static func _wave_clear() -> PackedFloat32Array:
	var tone_dur := 0.18
	var tone_n := int(MIX_RATE * tone_dur)
	var out := PackedFloat32Array()
	out.resize(tone_n * 2)
	var freqs := [392.0, 587.0]
	for k in range(2):
		var phase := 0.0
		for i in range(tone_n):
			var t := float(i) / MIX_RATE
			var frac := t / tone_dur
			phase += freqs[k] / MIX_RATE
			var env := sin(PI * frac) * 0.7
			out[k * tone_n + i] = sin(TAU * phase) * env
	return out


## Взвод мины: сухой механический щелчок (очень короткий шум) и через 60 мс — тонкий
## «пик» 1.4 кГц, как у детонатора. Короткий: ставят её в бою, звук не должен мешать.
static func _mine_place() -> PackedFloat32Array:
	var dur := 0.22
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in range(n):
		var t := float(i) / MIX_RATE
		var click := rng.randf_range(-1.0, 1.0) * exp(-t * 180.0)
		var tick := sin(TAU * 520.0 * t) * exp(-t * 90.0) * 0.5
		var beep := 0.0
		if t >= 0.06:
			var bt := t - 0.06
			beep = sin(TAU * 1400.0 * bt) * sin(PI * clampf(bt / 0.14, 0.0, 1.0)) * 0.45
		out[i] = click * 0.6 + tick + beep
	return out


## Взрыв мины: низкий удар с падением 120→40 Гц под шумовым выбросом с приглушённым
## (скользящее среднее) хвостом — «земля подбросила», а не хлопок хлопушки.
static func _mine_boom(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.7
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var freq := lerpf(120.0, 40.0, clampf(t / 0.35, 0.0, 1.0))
		phase += freq / MIX_RATE
		var thump := sin(TAU * phase) * exp(-t * 6.5)
		var raw := rng.randf_range(-1.0, 1.0)
		# однополюсный ФНЧ: коэффициент растёт со временем — хвост темнеет, как пыль оседает
		var k := lerpf(0.6, 0.08, clampf(t / dur, 0.0, 1.0))
		lp += (raw - lp) * k
		var debris := lp * exp(-t * 5.0)
		var crack := raw * exp(-t * 70.0)
		out[i] = thump * 0.75 + debris * 0.55 + crack * 0.35
	return out


## Тотем воткнули: глухой костяной стук (как skel_hit, но ниже) и следом поднимающийся гул
## квинтой 110+165 Гц с вибрато — аура «включилась».
static func _totem_place(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.75
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph1 := 0.0
	var ph2 := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var knock := (rng.randf_range(-1.0, 1.0) * 0.5 + sin(TAU * 95.0 * t)) * exp(-t * 30.0)
		var vib := sin(TAU * 5.0 * t) * 2.0
		ph1 += (110.0 + vib) / MIX_RATE
		ph2 += (165.0 + vib * 1.5) / MIX_RATE
		var frac := clampf((t - 0.05) / (dur - 0.05), 0.0, 1.0)
		var hum_env := sin(PI * frac) * 0.55
		var hum := (sin(TAU * ph1) + sin(TAU * ph2) * 0.6) * hum_env
		out[i] = knock * 0.7 + hum * 0.5
	return out


## Ульта готова: восходящее арпеджио ля-минора (440→523→659→880 Гц) колокольчиком —
## «премия начислена». Слышно поверх боя, но мягко, без резкой атаки.
static func _ult_ready() -> PackedFloat32Array:
	var note := 0.11
	var freqs := [440.0, 523.25, 659.25, 880.0]
	var tail := 0.35
	var n := int(MIX_RATE * (note * freqs.size() + tail))
	var out := PackedFloat32Array()
	out.resize(n)
	for k in range(freqs.size()):
		var start := int(MIX_RATE * note * k)
		var f: float = freqs[k]
		for i in range(start, n):
			var t := float(i - start) / MIX_RATE
			var env := exp(-t * 7.0) * 0.35
			out[i] += (sin(TAU * f * t) + sin(TAU * f * 2.01 * t) * 0.3) * env
	return out


## Находка артефакта: быстрое восходящее арпеджио ре-мажора с «колокольным» обертоном и
## мерцающим хвостом — отличимо от ult_ready (та ниже и медленнее), слышно поверх боя.
static func _item_get() -> PackedFloat32Array:
	var note := 0.07
	var freqs := [587.33, 739.99, 880.0, 1174.66, 1479.98]
	var tail := 0.55
	var n := int(MIX_RATE * (note * freqs.size() + tail))
	var out := PackedFloat32Array()
	out.resize(n)
	for k in range(freqs.size()):
		var start := int(MIX_RATE * note * k)
		var f: float = freqs[k]
		for i in range(start, n):
			var t := float(i - start) / MIX_RATE
			var env := exp(-t * 5.5) * 0.3
			var shimmer := 1.0 + 0.25 * sin(TAU * 9.0 * t)
			out[i] += (sin(TAU * f * t) + sin(TAU * f * 2.76 * t) * 0.25) * env * shimmer
	return out


## Замах ульты (0.6 с каста + 0.4 с пелены): нарастающий гул 60→180 Гц с шумовым «вдохом»
## и тремоло, которое ускоряется, — напряжение перед ударом.
static func _ult_cast(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 1.0
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var trem_phase := 0.0
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var freq := lerpf(60.0, 180.0, frac * frac)
		phase += freq / MIX_RATE
		trem_phase += lerpf(4.0, 22.0, frac) / MIX_RATE
		var trem := 0.7 + 0.3 * sin(TAU * trem_phase)
		var tone := (sin(TAU * phase) + sin(TAU * phase * 2.0) * 0.35) * trem
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.12
		var env := pow(frac, 1.6) * (1.0 - pow(frac, 12.0))
		out[i] = (tone * 0.7 + lp * 0.6) * env
	return out


## Удар ульты: суб-бум 55 Гц, яркий аккорд (ре-минор с октавой) поверх и шумовая волна —
## самый громкий и длинный звук набора, событие раз за матч.
static func _ult_blast(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 1.3
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var chord := [293.66, 349.23, 440.0, 587.33]
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var sub := sin(TAU * lerpf(70.0, 45.0, clampf(t / 0.5, 0.0, 1.0)) * t) * exp(-t * 3.2)
		var ch := 0.0
		for f in chord:
			ch += sin(TAU * float(f) * t + sin(TAU * 3.0 * t) * 0.4)
		ch = ch / chord.size() * exp(-t * 2.6) * (1.0 - exp(-t * 60.0))
		lp += (rng.randf_range(-1.0, 1.0) - lp) * lerpf(0.5, 0.05, clampf(t / dur, 0.0, 1.0))
		var wave := lp * exp(-t * 4.0)
		out[i] = sub * 0.8 + ch * 0.45 + wave * 0.5
	return out


# ── Обвязка: огибающая на краях, нормализация, упаковка в WAV ────────────────

## Наложить мгновенную (но не резкую) атаку на первые ATTACK_SEC и убедиться,
## что последний сэмпл близок к нулю — иначе на стыке буфера щёлкает.
static func _apply_edges(samples: PackedFloat32Array) -> void:
	var n := samples.size()
	if n == 0:
		return
	var attack_n := maxi(1, int(MIX_RATE * ATTACK_SEC))
	attack_n = min(attack_n, n)
	for i in range(attack_n):
		samples[i] *= float(i) / attack_n
	# короткий линейный фейд-аут на последних сэмплах — подчищает хвост
	# после экспоненциального спада, который к концу буфера уже почти нулевой,
	# но не гарантированно ровно ноль.
	var release_n := mini(attack_n, n)
	for i in range(release_n):
		var idx := n - 1 - i
		samples[idx] *= float(i) / release_n


## Найти пиковую амплитуду и отмасштабировать буфер под PEAK_LIMIT.
static func _normalize(samples: PackedFloat32Array) -> void:
	var peak := 0.0
	for s in samples:
		peak = max(peak, abs(s))
	if peak <= 0.00001:
		return
	var scale := PEAK_LIMIT / peak
	for i in range(samples.size()):
		samples[i] *= scale


## Собрать AudioStreamWAV из float-сэмплов: огибающая на краях, нормализация,
## упаковка в 16-бит PCM little-endian.
static func _to_stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	_apply_edges(samples)
	_normalize(samples)
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in range(samples.size()):
		var v := int(clamp(samples[i], -1.0, 1.0) * INT16_MAX)
		bytes.encode_s16(i * 2, v)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	stream.data = bytes
	return stream


# ── Самопроверка (используется временным скриптом-гейтом, не игрой) ─────────

## Замеры по потоку: длительность, число сэмплов, пиковая амплитуда, RMS,
## первый/последний сэмпл (в диапазоне [-1, 1]). Нужно только для проверки
## качества синтеза — игровой код это не вызывает.
static func measure(id: String) -> Dictionary:
	var stream := get_stream(id)
	@warning_ignore("integer_division")
	var n := stream.data.size() / 2   # 16 бит на сэмпл: делится нацело всегда
	var peak := 0.0
	var sum_sq := 0.0
	var first := 0.0
	var last := 0.0
	for i in range(n):
		var v := stream.data.decode_s16(i * 2) / INT16_MAX
		peak = max(peak, abs(v))
		sum_sq += v * v
		if i == 0:
			first = v
		if i == n - 1:
			last = v
	var rms := sqrt(sum_sq / maxi(n, 1))
	return {
		"duration_sec": float(n) / stream.mix_rate,
		"samples": n,
		"peak": peak,
		"rms": rms,
		"first": first,
		"last": last,
	}
