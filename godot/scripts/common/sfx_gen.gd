class_name SfxGen
extends RefCounted
##
## Процедурные боевые SFX: генерируем AudioStreamWAV математикой в рантайме,
## без внешних файлов. Тёмное фэнтези с офисной сатирой — звуки короткие
## и сухие. Каждый поток строится один раз и кэшируется в статическом
## словаре, чтобы в кадре боя не было аллокаций и повторного синтеза.
##
## Звук к Steam (аудит 08.10, SND-01/03/11/12): 44,1 кГц вместо 22,05 (верх «треска» и «хруста»
## больше не срезан), громкость выравнивается по RMS, а не по пику (тихий синус и шумовой треск
## звучат ровно), у шумовых эффектов несколько дублей с разным зерном (повтор не «пулемёт»),
## а прогрев всего набора идёт в фоне (`synth()` — чистая функция, её зовёт поток Audio).
##

const MIX_RATE := 44100
## Частота, под которую подбирались коэффициенты однополюсных ФНЧ первых 17 звуков: при смене
## MIX_RATE их срез иначе съехал бы вдвое вниз и «пыль» взрыва стала бы глуше (см. _k()).
const DESIGN_RATE := 22050.0
## Потолок пика: −1 dBFS — запас против межсэмплового пика и наложения нескольких звуков.
const PEAK_LIMIT := 0.89
## Цель громкости по RMS звучащей части (≈ −17 dBFS): эффекты разной природы звучат ровно, а
## тембр, который упирается в PEAK_LIMIT раньше, просто остаётся чуть тише.
const TARGET_RMS := 0.14
const INT16_MAX := 32767.0
## Мгновенная атака — но не мгновеннее пары сэмплов, иначе щелчок на старте.
const ATTACK_SEC := 0.003
## Дублей у эффекта с шумом (зерно влияет на звук); тональным хватает разброса высоты в Audio.
const VARIANTS := 3
## Эффекты без случайности в синтезе (или с фиксированным зерном): дубли у них одинаковы.
const _TONAL := [
	"rune_draw", "rune_fail", "cast_w", "wave_start", "wave_clear", "mine_place", "ult_ready",
	"item_get", "combo", "rally", "spring", "breach_warn", "wave_call", "ui_hover", "rank_up",
]

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
		# 08.10 (SND-01/02): действия боя и интерфейс
		"charge",
		"charge_hit",
		"charge_perfect",
		"combo",
		"rally",
		"crush",
		"spring",
		"erase",
		"sling",
		"tear",
		"breach_warn",
		"breach_open",
		"wave_call",
		"build",
		"boss_roar",
		"spawn",
		"ui_hover",
		"ui_press",
		"ui_buy",
		"rank_up",
		"amend_sign",
	]


## Эффекты, чей звук зависит от зерна (шум, случайные щелчки): у них VARIANTS дублей.
static func variant_count(id: String) -> int:
	return 1 if _TONAL.has(id) else VARIANTS



## Вернуть готовый поток по id. Первый вызов на id генерирует и кэширует,
## дальнейшие — отдают кэш.
## Кэш живёт в статике класса, а движок проверяет утечки ДО выгрузки скриптов — из-за этого
## на выходе он честно ругался «AudioStreamWAV leaked / resources still in use». Освобождаем
## сами, когда звуковой слой уходит из дерева.
static func clear_cache() -> void:
	_cache.clear()


static func get_stream(id: String, variant := 0) -> AudioStreamWAV:
	var key := _key(id, variant)
	if _cache.has(key):
		return _cache[key]
	var stream := synth(id, variant)
	_cache[key] = stream
	return stream


## Уже в кэше (прогрев Audio не синтезирует второй раз то, что успел запросить бой).
static func has_cached(id: String, variant := 0) -> bool:
	return _cache.has(_key(id, variant))


## Положить готовый поток (из фонового прогрева) — только из основного потока.
static func store(id: String, variant: int, stream: AudioStreamWAV) -> void:
	var key := _key(id, variant)
	if not _cache.has(key):
		_cache[key] = stream


## Синтез без кэша: чистая функция (свои RNG и буферы), безопасна для фонового потока.
static func synth(id: String, variant := 0) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	# дубль 0 — прежнее зерно (тот же звук, что до вариаций); остальные — своё зерно
	rng.seed = hash(id) if variant == 0 else hash("%s#%d" % [id, variant])
	var stream := _to_stream(_synthesize(id, rng))
	stream.set_meta(&"sfx_id", id)
	return stream


static func _key(id: String, variant: int) -> String:
	return id if variant == 0 else "%s#%d" % [id, variant]


## Коэффициент однополюсного ФНЧ, подобранный на DESIGN_RATE, — тот же срез на MIX_RATE.
static func _k(k_design: float) -> float:
	return 1.0 - pow(1.0 - k_design, DESIGN_RATE / MIX_RATE)


# ── Синтез по id ─────────────────────────────────────────────────────────────

## Построить массив сэмплов float в диапазоне [-1, 1] для данного id.
## Каждый дубль id использует свой RandomNumberGenerator с фиксированным seed —
## звук должен быть одинаковым между запусками игры.
static func _synthesize(id: String, rng: RandomNumberGenerator) -> PackedFloat32Array:
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
			return _synthesize_v2(id, rng)


static func _synthesize_v2(id: String, rng: RandomNumberGenerator) -> PackedFloat32Array:
	match id:
		"charge":
			return _charge(rng)
		"charge_hit":
			return _charge_hit(rng)
		"charge_perfect":
			return _charge_perfect(rng)
		"combo":
			return _combo()
		"rally":
			return _rally()
		"crush":
			return _crush(rng)
		"spring":
			return _spring()
		"erase":
			return _erase(rng)
		"sling":
			return _sling(rng)
		"tear":
			return _tear(rng)
		"breach_warn":
			return _breach_warn()
		"breach_open":
			return _breach_open(rng)
		"wave_call":
			return _wave_call()
		"build":
			return _build(rng)
		"boss_roar":
			return _boss_roar(rng)
		"spawn":
			return _spawn(rng)
		"ui_hover":
			return _ui_hover()
		"ui_press":
			return _ui_press(rng)
		"ui_buy":
			return _ui_buy(rng)
		"rank_up":
			return _rank_up()
		"amend_sign":
			return _amend_sign(rng)
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
		var k := _k(lerpf(0.6, 0.08, clampf(t / dur, 0.0, 1.0)))
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
	var k_hum := _k(0.12)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var freq := lerpf(60.0, 180.0, frac * frac)
		phase += freq / MIX_RATE
		trem_phase += lerpf(4.0, 22.0, frac) / MIX_RATE
		var trem := 0.7 + 0.3 * sin(TAU * trem_phase)
		var tone := (sin(TAU * phase) + sin(TAU * phase * 2.0) * 0.35) * trem
		lp += (rng.randf_range(-1.0, 1.0) - lp) * k_hum
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
		lp += (rng.randf_range(-1.0, 1.0) - lp) * _k(lerpf(0.5, 0.05, clampf(t / dur, 0.0, 1.0)))
		var wave := lp * exp(-t * 4.0)
		out[i] = sub * 0.8 + ch * 0.45 + wave * 0.5
	return out


# ── 08.10: действия боя и интерфейс (SND-01/02) ─────────────────────────────
## Тембры подобраны так, чтобы события различались на слух и в каше боя: натиск — шорох и
## костяной стук, удар — низ + треск, точный срыв — ещё и звон, «Сбор» — медный зов, давка —
## хруст, бумажные события (Таб, Юрист, подпись) — шорох бумаги. Слои «низ / середина / верх»
## — рецепт game-juice «Layer impacts».

static func _buf(dur: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(MIX_RATE * dur))
	return out


## Тон с гармониками 1/k (мягкая «медь»/«пила» без алиасинга: гармоник немного).
static func _brass(phase: float, harmonics: int) -> float:
	var v := 0.0
	for h in range(1, harmonics + 1):
		v += sin(TAU * phase * h) / float(h)
	return v * 0.6


## Натиск (участок растаял, бойцы пошли): шорох-рывок воздуха + костяной перестук + толчок.
static func _charge(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.42
	var out := _buf(dur)
	var n := out.size()
	var clicks: Array[float] = []
	for c in 6:
		clicks.append(rng.randf_range(0.02, 0.3))
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var k := _k(lerpf(0.05, 0.45, sin(PI * minf(frac * 1.4, 1.0))))
		lp += (rng.randf_range(-1.0, 1.0) - lp) * k
		var whoosh := lp * pow(sin(PI * frac), 0.7) * 0.8
		var clatter := 0.0
		for c0 in clicks:
			var dt := t - c0
			if dt >= 0.0 and dt < 0.03:
				clatter += sin(TAU * (1100.0 + c0 * 2400.0) * dt) * exp(-dt * 110.0) * 0.5
		var thump := sin(TAU * 90.0 * t) * exp(-t * 25.0) * 0.6
		out[i] = whoosh + clatter + thump
	return out


## Удар залпа о врага: низкий удар (низ) + сухой треск (середина) + два костяных «пика» (верх).
## Поле договоров (contract_field.gd, его не правим) кладёт сверху свой skel_hit — этот звук
## нарочно без шума в середине, чтобы два слоя не спорили.
static func _charge_hit(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.26
	var out := _buf(dur)
	var phase := 0.0
	var lp := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		phase += lerpf(75.0, 42.0, clampf(t / 0.2, 0.0, 1.0)) / MIX_RATE
		var thump := sin(TAU * phase) * exp(-t * 16.0)
		var raw := rng.randf_range(-1.0, 1.0)
		lp += (raw - lp) * _k(0.35)
		var crack := (raw - lp) * exp(-t * 85.0)
		var ping := (sin(TAU * 1850.0 * t) + sin(TAU * 2630.0 * t) * 0.7) * exp(-t * 55.0)
		out[i] = thump * 0.85 + crack * 0.45 + ping * 0.12
	return out


## Точный срыв: тот же удар + яркий колокольный аккорд с мерцанием — «попал в такт».
static func _charge_perfect(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var hit := _charge_hit(rng)
	var dur := 0.65
	var out := _buf(dur)
	var chord := [880.0, 1318.5, 1760.0]
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var bell := 0.0
		for f: float in chord:
			bell += sin(TAU * f * t) + sin(TAU * f * 2.76 * t) * 0.25
		bell = bell / chord.size() * exp(-t * 5.5) * (1.0 + 0.2 * sin(TAU * 11.0 * t))
		var h: float = hit[i] if i < hit.size() else 0.0
		out[i] = h * 0.8 + bell * 0.45
	return out


## Шаг комбо: короткий щипок — высоту поднимает лестница (Audio.sfx pitch), как монетки Марио.
static func _combo() -> PackedFloat32Array:
	var dur := 0.14
	var out := _buf(dur)
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var f := 660.0
		var tone := sin(TAU * f * t) + sin(TAU * f * 2.0 * t) * 0.35 + sin(TAU * f * 3.0 * t) * 0.15
		out[i] = tone * exp(-t * 28.0)
	return out


## «Сбор» (R): медный зов квартой вверх — горн десятника собирает свободных.
static func _rally() -> PackedFloat32Array:
	var notes := [[392.0, 0.0, 0.2], [523.25, 0.17, 0.4]]
	var dur := 0.6
	var out := _buf(dur)
	for nt: Array in notes:
		var f: float = nt[0]
		var start: float = nt[1]
		var len_s: float = nt[2]
		var phase := 0.0
		for i in range(int(start * MIX_RATE), out.size()):
			var t := float(i) / MIX_RATE - start
			if t > len_s:
				break
			phase += (f + sin(TAU * 5.5 * t) * 3.0) / MIX_RATE
			var env := minf(t / 0.025, 1.0) * clampf((len_s - t) / 0.08, 0.0, 1.0)
			out[i] += _brass(phase, 6) * env
	return out


## Давка: толпа проломила участок — низкий гул, хруст костей густо вначале и нисходящий стон.
static func _crush(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.48
	var out := _buf(dur)
	var lp := 0.0
	var phase := 0.0
	var crack_env := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var raw := rng.randf_range(-1.0, 1.0)
		lp += (raw - lp) * _k(0.06)
		var rumble := lp * exp(-t * 5.0) * 2.0
		if rng.randf() < 0.0012 * (1.0 - frac):
			crack_env = 1.0
		crack_env *= 0.996
		var crunch := raw * crack_env * 0.7
		phase += lerpf(210.0, 60.0, frac) / MIX_RATE
		var groan := sin(TAU * phase) * exp(-t * 6.0) * 0.4
		out[i] = rumble + crunch + groan
	return out


## Пружина: «бойнг» — тон, качающийся с затухающей частотой, и лёгкий щелчок старта.
static func _spring() -> PackedFloat32Array:
	var dur := 0.38
	var out := _buf(dur)
	var phase := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var f := 230.0 + 170.0 * sin(TAU * 13.0 * t) * exp(-t * 7.0) + t * 120.0
		phase += f / MIX_RATE
		var tone := sin(TAU * phase) + sin(TAU * phase * 2.0) * 0.25
		out[i] = tone * exp(-t * 7.5)
	return out


## Таб стёр линию: резкий шорох ластика по бумаге — полосовой шум с быстрой «скребущей» модуляцией.
static func _erase(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.24
	var out := _buf(dur)
	var lp1 := 0.0
	var lp2 := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var raw := rng.randf_range(-1.0, 1.0)
		lp1 += (raw - lp1) * _k(0.5)
		lp2 += (raw - lp2) * _k(0.08)
		var band := lp1 - lp2
		var scratch := 0.6 + 0.4 * sin(TAU * 32.0 * t)
		out[i] = band * scratch * sin(PI * frac)
	return out


## Рогатка: упругий «шлёп» резинки и свист улетающей группы (шум, светлеющий к концу).
static func _sling(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.32
	var out := _buf(dur)
	var lp := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		lp += (rng.randf_range(-1.0, 1.0) - lp) * _k(lerpf(0.04, 0.5, frac))
		var whistle := lp * pow(frac, 1.3) * clampf((1.0 - frac) / 0.15, 0.0, 1.0) * 1.6
		var snap := sin(TAU * 170.0 * t) * exp(-t * 45.0)
		out[i] = whistle + snap * 0.6
	return out


## Юрист расторг участок: рвущаяся бумага — рваные пачки светлого шума.
static func _tear(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.42
	var out := _buf(dur)
	var gate := 1.0
	var gate_left := 0
	var lp := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		if gate_left <= 0:
			gate = rng.randf_range(0.15, 1.0)
			gate_left = int(rng.randf_range(0.004, 0.012) * MIX_RATE)
		gate_left -= 1
		var raw := rng.randf_range(-1.0, 1.0)
		lp += (raw - lp) * _k(0.3)
		var hi := raw - lp
		var env := minf(t / 0.02, 1.0) * exp(-t * 4.5)
		out[i] = hi * gate * env
	return out


## Предупреждение прорыва: двухтоновая тревога (880/660 Гц) три раза — «сейчас прорвутся».
static func _breach_warn() -> PackedFloat32Array:
	var step := 0.12
	var dur := step * 6.0
	var out := _buf(dur)
	var phase := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var k := int(t / step)
		var f := 880.0 if k % 2 == 0 else 660.0
		phase += f / MIX_RATE
		var local := fmod(t, step) / step
		var env := minf(local / 0.08, 1.0) * minf((1.0 - local) / 0.12, 1.0)
		out[i] = (sin(TAU * phase) + sin(TAU * phase * 3.0) * 0.2) * env
	return out


## Прорыв открыт: низкий тёмный гонг с рокотом — враги пошли новым путём.
static func _breach_open(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 1.05
	var out := _buf(dur)
	var ratios := [1.0, 1.47, 2.09, 2.76]
	var weights := [0.55, 0.3, 0.18, 0.1]
	var lp := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var s := 0.0
		for k in range(ratios.size()):
			s += sin(TAU * 62.0 * float(ratios[k]) * t) * float(weights[k])
		lp += (rng.randf_range(-1.0, 1.0) - lp) * _k(0.05)
		out[i] = s * exp(-t * 3.2) + lp * exp(-t * 4.0) * 1.4
	return out


## Досрочный вызов волны: быстрый колокольчик тремя нотами вверх — «премия за смелость».
static func _wave_call() -> PackedFloat32Array:
	var note := 0.06
	var freqs := [523.25, 659.25, 783.99]
	var dur := note * freqs.size() + 0.35
	var out := _buf(dur)
	for k in range(freqs.size()):
		var start := int(MIX_RATE * note * k)
		var f: float = freqs[k]
		for i in range(start, out.size()):
			var t := float(i - start) / MIX_RATE
			out[i] += (sin(TAU * f * t) + sin(TAU * f * 2.0 * t) * 0.4) * exp(-t * 9.0) * 0.4
	return out


## Постройка: три удара молотка по дереву.
static func _build(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var hits := [0.0, 0.13, 0.26]
	var dur := 0.45
	var out := _buf(dur)
	for h: float in hits:
		var pitch := rng.randf_range(0.93, 1.07)
		for i in range(int(h * MIX_RATE), out.size()):
			var t := float(i) / MIX_RATE - h
			if t > 0.12:
				break
			var wood := sin(TAU * 185.0 * pitch * t) * 0.7 + sin(TAU * 430.0 * pitch * t) * 0.4
			var knock := rng.randf_range(-1.0, 1.0) * exp(-t * 160.0) * 0.6
			out[i] += wood * exp(-t * 38.0) + knock
	return out


## Рёв босса: рычание — низкая «пила» с неровным дрожанием и шумом дыхания, нарастает и
## обрывается. Раньше на рёв играл замах ульты (ult_cast) — SND-09.
static func _boss_roar(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 1.1
	var out := _buf(dur)
	var phase := 0.0
	var lp := 0.0
	var rough := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var frac := t / dur
		rough += (rng.randf_range(-1.0, 1.0) - rough) * _k(0.004)
		var f := 58.0 + 14.0 * sin(PI * frac) + rough * 25.0
		phase += f / MIX_RATE
		var growl := _brass(phase, 9) * (0.75 + 0.25 * sin(TAU * 27.0 * t))
		lp += (rng.randf_range(-1.0, 1.0) - lp) * _k(0.15)
		var env := minf(t / 0.15, 1.0) * clampf((dur - t) / 0.3, 0.0, 1.0)
		out[i] = (growl + lp * 0.5) * env
	return out


## Боец встал в строй: тихий костяной перестук (часто — поэтому короткий и тихий).
static func _spawn(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.16
	var out := _buf(dur)
	for c in 3:
		var at := rng.randf_range(0.0, 0.09)
		var f := rng.randf_range(1300.0, 2100.0)
		for i in range(int(at * MIX_RATE), out.size()):
			var t := float(i) / MIX_RATE - at
			out[i] += sin(TAU * f * t) * exp(-t * 90.0) * 0.4
	return out


## Наведение на кнопку: едва слышный тик (громкость задаёт LegionCfg — около −12 дБ).
static func _ui_hover() -> PackedFloat32Array:
	var dur := 0.05
	var out := _buf(dur)
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		out[i] = sin(TAU * 1760.0 * t) * exp(-t * 110.0)
	return out


## Нажатие кнопки: щелчок «канцелярской кнопки» — короткий шум и падающий тон.
static func _ui_press(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.09
	var out := _buf(dur)
	var phase := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		phase += lerpf(1000.0, 650.0, t / dur) / MIX_RATE
		var click := rng.randf_range(-1.0, 1.0) * exp(-t * 260.0) * 0.5
		out[i] = click + sin(TAU * phase) * exp(-t * 45.0) * 0.7
	return out


## Покупка: монеты в ящик кассы — три металлических звона.
static func _ui_buy(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.5
	var out := _buf(dur)
	var base := [2093.0, 2637.0, 3136.0]
	for k in 3:
		var at := 0.07 * k + rng.randf_range(0.0, 0.015)
		var f: float = base[k] * rng.randf_range(0.97, 1.03)
		for i in range(int(at * MIX_RATE), out.size()):
			var t := float(i) / MIX_RATE - at
			var ring := sin(TAU * f * t) + sin(TAU * f * 2.41 * t) * 0.35
			out[i] += ring * exp(-t * 14.0) * 0.4
	return out


## Новый разряд: медная фанфара — до-ми-соль-до и держащийся аккорд.
static func _rank_up() -> PackedFloat32Array:
	var note := 0.11
	var freqs := [261.63, 329.63, 392.0, 523.25]
	var hold := 0.6
	var dur := note * freqs.size() + hold
	var out := _buf(dur)
	for k in range(freqs.size()):
		var f: float = freqs[k]
		var start := note * k
		var phase := 0.0
		for i in range(int(start * MIX_RATE), out.size()):
			var t := float(i) / MIX_RATE - start
			phase += (f + sin(TAU * 5.0 * t) * 1.5) / MIX_RATE
			var env := minf(t / 0.02, 1.0) * clampf((dur - start - t) / 0.25, 0.0, 1.0)
			out[i] += _brass(phase, 5) * env * 0.35
	return out


## Подпись поправки: росчерк пера (быстрый шорох с «петлями») и удар печати.
static func _amend_sign(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 0.55
	var stamp_at := 0.32
	var out := _buf(dur)
	var lp1 := 0.0
	var lp2 := 0.0
	for i in range(out.size()):
		var t := float(i) / MIX_RATE
		var raw := rng.randf_range(-1.0, 1.0)
		lp1 += (raw - lp1) * _k(0.6)
		lp2 += (raw - lp2) * _k(0.15)
		var pen := 0.0
		if t < 0.27:
			var loops := 0.5 + 0.5 * sin(TAU * 9.0 * t + sin(TAU * 3.0 * t))
			pen = (lp1 - lp2) * loops * sin(PI * t / 0.27) * 0.9
		var stamp := 0.0
		if t >= stamp_at:
			var st := t - stamp_at
			stamp = sin(TAU * 105.0 * st) * exp(-st * 22.0) + raw * exp(-st * 150.0) * 0.6
		out[i] = pen + stamp
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


## Выровнять громкость: RMS звучащей части (сэмплы громче 1 % пика — без тишины хвоста) к
## TARGET_RMS, но пик не выше PEAK_LIMIT. Раньше было «пик к 0,7»: тихий синус и шумовой треск
## тогда звучали с разной воспринимаемой громкостью (SND-11).
static func _normalize(samples: PackedFloat32Array) -> void:
	var peak := 0.0
	for s in samples:
		peak = maxf(peak, absf(s))
	if peak <= 0.00001:
		return
	var floor_v := peak * 0.01
	var sum_sq := 0.0
	var cnt := 0
	for s in samples:
		if absf(s) >= floor_v:
			sum_sq += s * s
			cnt += 1
	var rms := sqrt(sum_sq / maxi(cnt, 1))
	var scale := minf(TARGET_RMS / maxf(rms, 0.00001), PEAK_LIMIT / peak)
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
static func measure(id: String, variant := 0) -> Dictionary:
	var stream := get_stream(id, variant)
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
