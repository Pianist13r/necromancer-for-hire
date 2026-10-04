class_name PgArtHarmony
extends RefCounted
## Постройки, склепы, Котёл и бойцы собранной карты «встают в землю» (D-CX-08, harmony-1003).
## Только картинка и только карты PgArt (TerrainView.wants_pgart); кампания с нарисованным bg
## не затронута. Два слоя:
##  1. запечённый — build_contact(): мягкое затемнение земли под склепами и Котлами
##     (эллипс, цвет — земля рядом, затемнённая, не чёрный), узлом Contact в стопке PgArt;
##  2. рабочий — экземпляр класса по ИТОГОВОЙ картинке карты: tone(p) — тонировка спрайтов
##     построек/склепов/Котла под свет и температуру биома (только оттенок, светлота цела —
##     читаемость), shadow_tint(p) — цвет тени под бойцами (CharShadows). Цвета сторон PvP и
##     видов врагов не трогаются: бойцам тонируется только тень.

## Оттенок биома (макс. компонента 1 — тонировка не поднимает светлоту): пустырь — тёплый
## фиолет, кладбище — холодный зелёный, болото — бирюза, контора — тёплый янтарь, стройка —
## охра.
const BIOME_TONE := {
	"ash": Color(1.0, 0.84, 0.98),
	"grave": Color(0.84, 1.0, 0.9),
	"swamp": Color(0.78, 1.0, 0.95),
	"office": Color(1.0, 0.86, 0.6),
	"site": Color(1.0, 0.82, 0.54),
}
## Сила тонировки спрайта (0 — как нарисован) и доля «земли рядом» в целевом оттенке.
const TONE_STRENGTH := 0.55
const TONE_LOCAL := 0.5
## Тень под бойцом: земля рядом × эта светлота (тёмная, но с оттенком земли).
const SHADOW_DARK := 0.22
## Крупность пробы: 1 пиксель пробы = столько px мира.
const PROBE_STEP := 16.0
## Контактная тень: полуоси эллипса (px мира), смещение от точки (свет сверху-слева, как у
## теней скал), альфа в центре и множитель светлоты земли.
const CONTACT := {
	"crypt": {"rx": 92.0, "ry": 34.0, "off": Vector2(9, 12), "a": 0.72},
	"cauldron": {"rx": 70.0, "ry": 28.0, "off": Vector2(5, 5), "a": 0.8},
}
const CONTACT_DARK := 0.13
const GRAD_SIZE := 64

static var _grad: Texture2D = null
## Малые «карты цвета» исходных подложек по пути ресурса (карта мира → пиксель пробы).
static var _raw_probes: Dictionary = {}

var _img: Image = null
## Цвет тени под бойцом, заранее по сетке в 2 пикселя пробы (бойцов сотни за кадр: одна выборка).
var _shade: Image = null
var _world := LegionCfg.WORLD_SIZE
var _biome := "grave"


## Точки контактных теней карты: [{pos: Vector2, k: "crypt"|"cauldron"}].
static func contact_points(map: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# участки не запекаем: в «Схватке» пустые участки противника не видны, а тёмное пятно на
	# пустом месте выдавало бы их; тень под построенным зданием — рабочий слой (set_ground_shadow)
	for crypt: Dictionary in map.get("crypts", []):
		out.append({"pos": _v(crypt.get("pos", [0, 0])), "k": "crypt"})
	var art: Array = map.get("cauldron_art", [0, 0])
	var shift := Vector2(float(art[0]), float(art[1])) if art.size() >= 2 else Vector2.ZERO
	var cps := PgArtScatter.cauldrons(map)
	for i in cps.size():
		# cauldron_art сдвигает картинку Котла стороны 0 (одиночка), не поля PvP
		out.append({"pos": cps[i] + (shift if cps.size() == 1 else Vector2.ZERO),
			"k": "cauldron"})
	return out


static func _v(a: Variant) -> Vector2:
	return Vector2(float((a as Array)[0]), float((a as Array)[1]))


static func _biome_of(map: Dictionary) -> String:
	return String(map.get("biome", map.get("theme", "grave")))


## Эллипсы затемнения земли под склепами и Котлами — узлы Sprite2D под parent
## (не draw_*: текстуры в draw_* во вложенном SubViewport дают белый кадр). Цвет — земля рядом
## по малой карте цвета подложки. Возвращает число узлов.
static func build_contact(parent: Node2D, map: Dictionary, ground_tex: Texture2D) -> int:
	# Пустой массив — явный выключатель harmony_off, а не просьба восстановить точки.
	var points: Array = map["contact"] if map.has("contact") else contact_points(map)
	if points.is_empty():
		return 0
	var probe := _raw_probe(ground_tex, map)
	var world := LegionTerrain.map_size(map)
	var n := 0
	for pt: Dictionary in points:
		var spec: Dictionary = CONTACT[pt["k"]]
		var pos: Vector2 = pt["pos"]
		var ground := Color(0.2, 0.2, 0.22) if probe == null \
			else sample(probe, world, pos, 2)
		var sp := Sprite2D.new()
		sp.name = "Contact%d" % n
		sp.texture = _gradient()
		sp.position = pos + (spec["off"] as Vector2)
		sp.scale = Vector2(float(spec["rx"]) * 2.0, float(spec["ry"]) * 2.0) / float(GRAD_SIZE)
		var dark := shadow_of(ground, CONTACT_DARK)
		sp.modulate = Color(dark.r, dark.g, dark.b, float(spec["a"]))
		parent.add_child(sp)
		n += 1
	return n


## Земля рядом, затемнённая с сохранением оттенка (чуть насыщеннее — тень цветная, не серая).
static func shadow_of(ground: Color, dark: float) -> Color:
	var lum := maxf(ground.get_luminance(), 0.001)
	var sat := Color(lum, lum, lum).lerp(ground, 1.25)
	return Color(clampf(sat.r * dark, 0.0, 1.0), clampf(sat.g * dark, 0.0, 1.0),
		clampf(sat.b * dark, 0.0, 1.0))


## Средний цвет пробы около точки мира (окно (2r+1)² пикселей пробы).
static func sample(probe: Image, world: Vector2, p: Vector2, r: int) -> Color:
	var w := probe.get_width()
	var h := probe.get_height()
	var cx := clampi(int(p.x / world.x * w), 0, w - 1)
	var cy := clampi(int(p.y / world.y * h), 0, h - 1)
	var sum := Color(0, 0, 0, 0)
	var k := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := probe.get_pixel(clampi(cx + dx, 0, w - 1), clampi(cy + dy, 0, h - 1))
			sum += c
			k += 1
	return Color(sum.r / k, sum.g / k, sum.b / k, 1.0)


## Малая карта цвета исходной подложки в координатах МИРА карты (поле PvP: вырезка и зеркало
## считаются здесь же, как PgArt._mirrored_ground). Кэш по пути ресурса — подложек немного.
static func _raw_probe(tex: Texture2D, map: Dictionary) -> Image:
	if tex == null:
		return null
	var world := LegionTerrain.map_size(map)
	var mw := LegionTerrain.mirror_width(map)
	var key := "%s|%d" % [tex.resource_path, int(mw)]
	if not tex.resource_path.is_empty() and _raw_probes.has(key):
		return _raw_probes[key]
	var src := tex.get_image()
	if src == null or src.is_empty():
		return null
	if src.is_compressed():
		src = src.duplicate()
		src.decompress()
	var small := src.duplicate() as Image
	small.resize(160, 90, Image.INTERPOLATE_BILINEAR)
	var pw := maxi(1, int(world.x / PROBE_STEP))
	var ph := maxi(1, int(world.y / PROBE_STEP))
	var out := Image.create(pw, ph, false, Image.FORMAT_RGB8)
	var half := Vector2(world.x * 0.5, world.y)
	var crop_w := minf(small.get_width(), small.get_height() * half.x / half.y)
	var crop_h := crop_w * half.y / half.x
	var y0 := (small.get_height() - crop_h) * 0.5
	for y in ph:
		for x in pw:
			var u := (float(x) + 0.5) / pw
			var v := (float(y) + 0.5) / ph
			if mw > 0.0:
				var hu := u * 2.0 if u < 0.5 else (1.0 - u) * 2.0
				u = hu * crop_w / small.get_width()
				v = (y0 + v * crop_h) / small.get_height()
			out.set_pixel(x, y, small.get_pixel(
				clampi(int(u * small.get_width()), 0, small.get_width() - 1),
				clampi(int(v * small.get_height()), 0, small.get_height() - 1)))
	if not tex.resource_path.is_empty():
		_raw_probes[key] = out
	return out


static func _gradient() -> Texture2D:
	if _grad != null:
		return _grad
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.55, Color(1, 1, 1, 0.85))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = GRAD_SIZE
	t.height = GRAD_SIZE
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	_grad = t
	return t


## Рабочий слой: проба итоговой картинки карты (то, что видит игрок).
func setup(texture: Texture2D, map: Dictionary) -> bool:
	_biome = _biome_of(map)
	_world = LegionTerrain.map_size(map)
	var src := texture.get_image() if texture != null else null
	if src == null or src.is_empty():
		return false
	if src.is_compressed():
		src = src.duplicate()
		src.decompress()
	_img = src.duplicate() as Image
	_img.resize(maxi(1, int(_world.x / PROBE_STEP)), maxi(1, int(_world.y / PROBE_STEP)),
		Image.INTERPOLATE_BILINEAR)
	_shade = _img.duplicate() as Image
	_shade.resize(maxi(1, _img.get_width() / 2), maxi(1, _img.get_height() / 2),
		Image.INTERPOLATE_TRILINEAR)
	for y in _shade.get_height():
		for x in _shade.get_width():
			_shade.set_pixel(x, y, shadow_of(_shade.get_pixel(x, y), SHADOW_DARK))
	return true


func ready() -> bool:
	return _img != null


## Земля вокруг точки мира: окно ±3 пикселя пробы (≈ ±50 px).
func ground_at(p: Vector2) -> Color:
	return sample(_img, _world, p, 3)


## Множитель цвета спрайта в точке: оттенок биома пополам с цветом земли рядом, нормирован
## по максимальной компоненте, смешан с белым на TONE_STRENGTH. Светлота почти не меняется
## (компонент не больше 1): контраст постройки к земле держится.
func tone(p: Vector2) -> Color:
	var biome_c: Color = BIOME_TONE.get(_biome, Color.WHITE)
	var g := ground_at(p)
	var top := maxf(maxf(g.r, g.g), maxf(g.b, 0.001))
	var local := Color(g.r / top, g.g / top, g.b / top)
	var target := biome_c.lerp(local, TONE_LOCAL)
	var mx := maxf(maxf(target.r, target.g), target.b)
	target = Color(target.r / mx, target.g / mx, target.b / mx)
	return Color.WHITE.lerp(target, TONE_STRENGTH)


## Цвет тени под бойцом в точке (альфа — у вызывающего).
func shadow_tint(p: Vector2) -> Color:
	return _shade.get_pixel(
		clampi(int(p.x / _world.x * _shade.get_width()), 0, _shade.get_width() - 1),
		clampi(int(p.y / _world.y * _shade.get_height()), 0, _shade.get_height() - 1))


## Цвет контактной тени под зданием в точке (то же правило, что у запечённой тени склепа).
func contact_tint(p: Vector2) -> Color:
	return shadow_of(ground_at(p), CONTACT_DARK)
