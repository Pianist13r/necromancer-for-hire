class_name PgArtGrade
extends RefCounted
## Цветовая обработка собранной карты по зонам (линия art3, D-0927-210; pg_post.gdshader):
## статистика цвета сборки по зонам карты PgArtMask, образец — статистика тех же зон на фонах
## кампании биома (tools/procgen_zone_lab.py → zones_lab.json), параметры — в шейдер.
##
## Статистика сборки считается здесь, на уменьшенном кадре (SAMPLE — 240×135: ≈ 32 тыс. точек,
## десятки миллисекунд), а не в шейдере: шейдеру нужны средние по всему кадру до прохода.
## Lab — та же формула, что в шейдере и скрипте образца (sRGB → линейный → XYZ D65 → Lab).
##
## Правило координатора 27.09 «земля не уходит от подложки больше чем на ±10 %» соблюдается
## ограничением сдвига светлоты L зоны земли (GROUND_L_SHIFT); оттенок и разброс переносятся.

const ZONES_JSON := "res://assets/legion/procgen/road/zones_lab.json"
const SAMPLE := Vector2i(240, 135)
const ZONES := ["ground", "road", "items"]
## Сила переноса по зонам: земля — основа «той же краски»; дорогу подтягиваем слабее (её светлоту
## уже держит PgArtRoad.brightness), предметы — средне (библиотека рисована в том же стиле).
const STRENGTH := Vector3(0.7, 0.4, 0.5)
## Разброс образца не больше/меньше разброса сборки в эти разы — иначе шум и цветные каймы
## (прототип npr: «не раздувать разброс больше чем вдвое»).
const SD_RATIO := Vector2(0.6, 1.6)
const GROUND_L_SHIFT := 0.08 ## доля L: ±8 % по Lab ≈ ±10 % по яркости на средних тонах
const ROAD_L_SHIFT := 0.03 ## дорога: L почти не трогаем (road-1003)
const ROAD_AB_SHARE := 0.5 ## дорога: половина сдвига оттенка к образцу биома
const MIN_PIXELS := 150

static var _ref_cache: Dictionary = {}


## Зона пикселя по маске (те же пороги, что в pg_post.gdshader, но жёстко): -1 — вода/смесь.
static func zone_of(m: Color) -> int:
	if m.g > 0.5:
		return 2
	if m.r > 0.9:
		return 1
	if m.r < 0.2 and m.b < 0.2:
		return 0
	return -1


static func srgb_to_lab(c: Color) -> Vector3:
	var l := Vector3(_lin(c.r), _lin(c.g), _lin(c.b))
	var x := (0.4124564 * l.x + 0.3575761 * l.y + 0.1804375 * l.z) / 0.95047
	var y := 0.2126729 * l.x + 0.7151522 * l.y + 0.0721750 * l.z
	var z := (0.0193339 * l.x + 0.1191920 * l.y + 0.9503041 * l.z) / 1.08883
	var fx := _f(x)
	var fy := _f(y)
	var fz := _f(z)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


static func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


static func _f(t: float) -> float:
	return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0


## Статистика Lab по зонам: {ground|road|items: {mu, sd, n}}. Картинки любого размера —
## уменьшаются до SAMPLE здесь.
static func zone_stats(art: Image, mask: Image) -> Dictionary:
	var a := _small(art)
	var m := _small(mask)
	var sum: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var sq: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var n: Array[int] = [0, 0, 0]
	for y in SAMPLE.y:
		for x in SAMPLE.x:
			var z := zone_of(m.get_pixel(x, y))
			if z < 0:
				continue
			var lab := srgb_to_lab(a.get_pixel(x, y))
			sum[z] += lab
			sq[z] += lab * lab
			n[z] += 1
	var out := {}
	for z in 3:
		if n[z] < MIN_PIXELS:
			continue
		var mu := sum[z] / float(n[z])
		var v := sq[z] / float(n[z]) - mu * mu
		out[ZONES[z]] = {"mu": mu, "n": n[z],
			"sd": Vector3(sqrt(maxf(v.x, 0.0)), sqrt(maxf(v.y, 0.0)), sqrt(maxf(v.z, 0.0)))}
	return out


## Средняя яркость (luma) картинки по зоне маски — для отчёта «земля до/после», «дорога ×».
static func zone_luma(img: Image, mask: Image, zone: int) -> float:
	var a := _small(img)
	var m := _small(mask)
	var s := 0.0
	var n := 0
	for y in SAMPLE.y:
		for x in SAMPLE.x:
			if zone_of(m.get_pixel(x, y)) == zone:
				s += a.get_pixel(x, y).get_luminance()
				n += 1
	return s / float(n) if n > 0 else -1.0


static func _small(img: Image) -> Image:
	var out := img.duplicate() as Image
	if out.is_compressed():
		out.decompress()
	out.convert(Image.FORMAT_RGBA8)
	if out.get_size() != SAMPLE:
		out.resize(SAMPLE.x, SAMPLE.y, Image.INTERPOLATE_BILINEAR)
	return out


## Образец биома из zones_lab.json: {ground|road|items: {mu: Vector3, sd: Vector3}}.
static func biome_ref(biome: String) -> Dictionary:
	if _ref_cache.is_empty():
		if not FileAccess.file_exists(ZONES_JSON):
			return {}
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(ZONES_JSON))
		if not data is Dictionary:
			return {}
		_ref_cache = data
	var src: Dictionary = _ref_cache.get(biome, _ref_cache.get("grave", {}))
	var out := {}
	for z: String in ZONES:
		if src.has(z):
			var e: Dictionary = src[z]
			out[z] = {"mu": _v3(e["mu"]), "sd": _v3(e["sd"])}
	return out


static func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## Параметры переноса в шейдер. Нет статистики зоны (мало точек или нет образца) — сила 0.
## Возвращает силы по зонам (для отчёта и теста).
static func apply(mat: ShaderMaterial, own: Dictionary, ref: Dictionary) -> Vector3:
	var src_mu: Array[Vector3] = []
	var src_sd: Array[Vector3] = []
	var ref_mu: Array[Vector3] = []
	var ref_sd: Array[Vector3] = []
	var strength := Vector3.ZERO
	for z in 3:
		var key: String = ZONES[z]
		if own.has(key) and ref.has(key):
			var mu_a: Vector3 = own[key]["mu"]
			var sd_a: Vector3 = own[key]["sd"]
			var mu_b: Vector3 = ref[key]["mu"]
			var sd_b: Vector3 = ref[key]["sd"]
			sd_b = sd_b.clamp(sd_a * SD_RATIO.x, sd_a * SD_RATIO.y)
			if z == 0:
				mu_b.x = clampf(mu_b.x, mu_a.x * (1.0 - GROUND_L_SHIFT),
					mu_a.x * (1.0 + GROUND_L_SHIFT))
			elif z == 1:
				# светлоту и оттенок дороги держит PgArtRoad от земли под ней (road-1003): перенос
				# к крему фонов кампании возвращал бы ленту, которую вписали в землю
				mu_b.x = clampf(mu_b.x, mu_a.x * (1.0 - ROAD_L_SHIFT), mu_a.x * (1.0 + ROAD_L_SHIFT))
				var ab := Vector2(mu_a.y, mu_a.z).lerp(Vector2(mu_b.y, mu_b.z), ROAD_AB_SHARE)
				mu_b.y = ab.x
				mu_b.z = ab.y
			src_mu.append(mu_a)
			src_sd.append(sd_a)
			ref_mu.append(mu_b)
			ref_sd.append(sd_b)
			strength[z] = STRENGTH[z]
		else:
			for arr: Array[Vector3] in [src_mu, ref_mu]:
				arr.append(Vector3.ZERO)
			for arr: Array[Vector3] in [src_sd, ref_sd]:
				arr.append(Vector3.ONE)
	mat.set_shader_parameter("src_mu", PackedVector3Array(src_mu))
	mat.set_shader_parameter("src_sd", PackedVector3Array(src_sd))
	mat.set_shader_parameter("ref_mu", PackedVector3Array(ref_mu))
	mat.set_shader_parameter("ref_sd", PackedVector3Array(ref_sd))
	mat.set_shader_parameter("zone_strength", strength)
	return strength
