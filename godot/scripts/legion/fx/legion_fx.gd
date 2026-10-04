class_name LegionFx
extends Node2D
##
## Слой эффектов режима «По истечении договора» (26.09.2026, Игорь: «эффектов ещё добавь.
## Только красивых и со вкусом и хорошо работающих»). Чистый вид: слушает сигналы мира и крючок
## удара CharView, ни одного числа боя не меняет и world.rng не трогает — у слоя свой ГСЧ.
## `--dev fx=0` — мира без слоя (A/B и замеры кадра).
##
## Почему не GPUParticles2D: эффектов много видов, а вспышек каждого — единицы. Узел частиц на
## каждую вспышку — это узлы, материалы и вызовы отрисовки; на телефоне дороже, чем массивы
## в самом слое. Здесь, как у CharShadows: частицы — упакованные массивы (LegionFxPool), рисуются
## draw_texture_rect подряд по одной текстуре, и соседние прямоугольники одной текстуры движок
## сливает в один вызов. Слоёв четыре: земля (под персонажами, над рунами: кольца рождения,
## отсветы ворот и прорыва, туман, блики воды, ореолы свечей) и воздух (над персонажами: пыль,
## души, косточки, искры, капли, листки, дым, угли, огоньки), в каждом обычное и аддитивное
## смешение.
##
## Числа — CfgFx. Время — реальный delta (эффект не должен тянуться в «Отсрочке»), на паузе
## слой стоит вместе с персонажами (PROCESS_MODE_PAUSABLE, как Entities мира).
##

const TEX_DIR := "res://assets/vfx/"

## Кэш уменьшенных текстур на весь сеанс: перезапуск карты не пересобирает их.
static var _tex_cache: Dictionary = {}

var world: LegionWorld = null
var rng := RandomNumberGenerator.new()
## Импакт способностей и натиска (молния Ку, подъём Дубль-вэ, волна Е, удар натиска).
var impact: LegionImpactFx = null
## Эффекты логики уровня процедурной карты (ambient.quirk_fx, BOOK §8.5 п.2) и тихий фон биома.
var quirk: LegionQuirkFx = null

var _ground: Node2D = null
var _layers: Array[Node2D] = []
## Пулы по слоям (индекс слоя → Array[LegionFxPool]); порядок в массиве — порядок отрисовки.
var _layer_pools: Array = []
var _drawn := PackedByteArray()          ## слой рисовал что-то в прошлом кадре
var _pools: Array[LegionFxPool] = []

var _dust: LegionFxPool
var _fog: LegionFxPool
var _ring: LegionFxPool
var _glow_g: LegionFxPool
var _water: LegionFxPool
var _bone: LegionFxPool
var _paper: LegionFxPool
var _smoke: LegionFxPool
var _soft: LegionFxPool
var _halo: LegionFxPool
var _spark: LegionFxPool
var _ember: LegionFxPool
var _wisp: LegionFxPool
var _glow_tex: Texture2D = null
var _ground_img: Image = null

var _clock := 0.0
var _hits_frame := 0
var _hit_seen: Dictionary = {}      ## instance_id вида → время последней искры
var _hit_forget_t := 0.0
var _cauldron_hit_t := -INF
var _charge_t := 0.0
var _bubble_acc := 0.0
## Рождения бойцов откладываются на кадр: стартовая армия рождается внутри start_map до
## match_started — её кольца (десятки разом у Котла) сбрасываются там же, ещё не нарисованными.
var _pending_spawns := PackedVector2Array()
var _streams: Array[Dictionary] = []       ## {kind, left, rate, acc}
var _amb_emit: Array[Dictionary] = []      ## фоновые излучатели карты
var _amb_glows: Array[Dictionary] = []     ## мерцающие ореолы карты


func setup(w: LegionWorld) -> void:
	world = w
	name = "LegionFx"
	rng.randomize()
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_glow_tex = _vfx("circle_05", CfgFx.TEX_SMALL)
	# пыль — мягкий диск, не дым Kenney: у smoke_04 рваная полупрозрачная текстура, и в 20–30 px
	# клуб почти не виден (кадр _probe.png, 26.09)
	_dust = LegionFxPool.new(_glow_tex, false, false)
	_fog = _pool("smoke_08", CfgFx.TEX_BIG, true, true)
	_ring = _pool("light_03", CfgFx.TEX_SMALL, false, false)
	_glow_g = LegionFxPool.new(_glow_tex, false, false)
	_water = _pool("star_08", CfgFx.TEX_SMALL, false, true)
	_bone = LegionFxPool.new(_proc_tex(&"bone"), true, false)
	_paper = LegionFxPool.new(_proc_tex(&"paper"), true, false)
	_smoke = _pool("smoke_01", CfgFx.TEX_BIG, true, false)
	_soft = LegionFxPool.new(_glow_tex, false, false)
	_halo = LegionFxPool.new(_glow_tex, false, false)
	_spark = _pool("magic_05", CfgFx.TEX_SMALL, false, false)
	_ember = LegionFxPool.new(_glow_tex, false, true)
	_wisp = LegionFxPool.new(_glow_tex, false, true)
	_pools = [_dust, _fog, _ring, _glow_g, _water, _bone, _paper, _smoke, _soft, _halo, _spark,
		_ember, _wisp]
	# земля: под Entities мира, над рунами (Contracts) — пыль и кольца у ног, отсветы
	_ground = Node2D.new()
	_ground.name = "FxGround"
	_ground.process_mode = Node.PROCESS_MODE_PAUSABLE
	w.add_child(_ground)
	w.move_child(_ground, w.entities.get_index())
	_add_layer(_ground, false, [_fog, _ring])
	_add_layer(_ground, true, [_glow_g, _water])
	# воздух: этот узел, мир ставит его над персонажами
	# Игра светлая и мультяшная: аддитив на светлой дороге и белом скелете выгорает в белое
	# и не читается. Поэтому всё, что должно читаться цветом (искра, ореол души, капли зелья),
	# — обычное смешение, а аддитив — только свечение поверх (ядро души, огоньки, угли).
	# пыль — поверх фигур: под ними её закрывает само тело (кадры приёмки r4), а мягкий клуб
	# у ступней поверх ног читается как поднятая пыль
	_add_layer(self, false, [_dust, _smoke, _halo, _bone, _paper, _spark])
	_add_layer(self, true, [_soft, _ember, _wisp])
	# импакт — поверх обычных частиц (своими слоями земли и воздуха, после наших)
	impact = LegionImpactFx.new()
	add_child(impact)
	impact.setup(self, w, _ground)
	quirk = LegionQuirkFx.new()
	add_child(quirk)
	quirk.setup(self, w, _ground, _glow_tex)
	w.foe_killed.connect(_on_foe_killed)
	w.unit_died.connect(_on_unit_died)
	w.unit_spawned.connect(_on_unit_spawned)
	w.cauldron_hit.connect(_on_cauldron_hit)
	w.wave_started.connect(_on_wave_started)
	w.breach_opened.connect(_on_breach_opened)
	w.match_started.connect(_on_match_started)
	w.match_ended.connect(_on_match_ended)
	w.menu_entered.connect(clear_all.bind(true))
	CharView.hit_hook = _on_hit


func _exit_tree() -> void:
	if CharView.hit_hook.is_valid() and CharView.hit_hook.get_object() == self:
		CharView.hit_hook = Callable()
	if is_instance_valid(_ground):
		_ground.queue_free()


func _add_layer(parent: Node2D, additive: bool, pools: Array) -> void:
	var node := Node2D.new()
	node.name = "Add" if additive else "Mix"
	if additive:
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		node.material = mat
	parent.add_child(node)
	var idx := _layers.size()
	_layers.append(node)
	_drawn.append(0)
	_layer_pools.append(pools)
	node.draw.connect(_draw_layer.bind(idx))


func _pool(tex_name: String, size: int, rotating: bool, ambient: bool) -> LegionFxPool:
	return LegionFxPool.new(_vfx(tex_name, size), rotating, ambient)


# ── Текстуры ────────────────────────────────────────────────────────────────

## Kenney 512×512 → size×size один раз: без мип-карт уменьшенная на лету крупная текстура
## рябит, а телефону маленькая дешевле по памяти и выборке. Без картинки (безголовый прогон,
## где текстуры не читаются обратно) — исходная текстура как есть.
static func _vfx(tex_name: String, size: int) -> Texture2D:
	var key := "%s@%d" % [tex_name, size]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var src := load(TEX_DIR + tex_name + ".png") as Texture2D
	var out: Texture2D = src
	var img := src.get_image() if src != null else null
	if img != null and not img.is_empty():
		img = img.duplicate() as Image
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		img.resize(size * 2, size * 2, Image.INTERPOLATE_LANCZOS)
		img = _crop_visible(img)
		img.resize(size, size, Image.INTERPOLATE_LANCZOS)
		out = ImageTexture.create_from_image(img)
	_tex_cache[key] = out
	return out


## У Kenney рисунок занимает середину кадра (у circle_05 — меньше половины), и размер в
## CfgFx переставал значить «видимый размер». Обрезаем по заметной альфе квадратом вокруг
## центра: тогда 20 px в конфиге — это 20 px пятна на экране мира.
static func _crop_visible(img: Image) -> Image:
	var n := img.get_width()
	var c := n / 2
	var half := 1
	for y in n:
		for x in n:
			if img.get_pixel(x, y).a > CfgFx.TEX_CROP_ALPHA:
				half = maxi(half, maxi(absi(x - c), absi(y - c)) + 1)
	half = mini(half + 1, c)
	return img.get_region(Rect2i(c - half, c - half, half * 2, half * 2))


## Процедурные косточка и листок: в наборе Kenney таких нет, а качать новые нельзя.
static func _proc_tex(kind: StringName) -> Texture2D:
	var key := String(kind)
	if _tex_cache.has(key):
		return _tex_cache[key]
	var img: Image
	if kind == &"bone":
		img = _bone_image()
	else:
		img = _paper_image()
	var out := ImageTexture.create_from_image(img)
	_tex_cache[key] = out
	return out


## Косточка 32×12: стержень и по два мыщелка на концах, тёмный контур — читается и на светлой
## дороге, и на тёмной траве.
static func _bone_image() -> Image:
	var img := Image.create(32, 12, false, Image.FORMAT_RGBA8)
	var knobs := [Vector2(5.5, 3.8), Vector2(5.5, 8.2), Vector2(26.5, 3.8), Vector2(26.5, 8.2)]
	for y in 12:
		for x in 32:
			var p := Vector2(x + 0.5, y + 0.5)
			var d := absf(p.y - 6.0) - 2.2
			if p.x < 6.0 or p.x > 26.0:
				d = maxf(d, minf(absf(p.x - 16.0) - 10.0, 99.0))
			for k: Vector2 in knobs:
				d = minf(d, p.distance_to(k) - 3.0)
			var c := Color(0, 0, 0, 0)
			if d < -1.0:
				c = Color(1, 1, 1, 1)
			elif d < 0.6:
				c = Color(0.45, 0.42, 0.4, clampf(0.6 - d, 0.0, 1.0))
			img.set_pixel(x, y, c)
	return img


## Листок 12×16: бумага с тремя строками и красной печатью в углу — «бюрократия преисподней».
static func _paper_image() -> Image:
	var img := Image.create(12, 16, false, Image.FORMAT_RGBA8)
	var paper := Color(1, 1, 1, 1)
	var edge := Color(0.62, 0.58, 0.52, 1)
	var ink := Color(0.55, 0.55, 0.6, 1)
	for y in 16:
		for x in 12:
			var c := paper
			if x == 0 or y == 0 or x == 11 or y == 15:
				c = edge
			elif (y == 4 or y == 7 or y == 10) and x >= 2 and x <= 9:
				c = ink
			img.set_pixel(x, y, c)
	for p: Vector2i in [Vector2i(8, 12), Vector2i(9, 12), Vector2i(8, 13), Vector2i(9, 13)]:
		img.set_pixel(p.x, p.y, Color(0.85, 0.15, 0.12, 1))
	return img


# ── Кадр ────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if world != null and world.hold:
		return
	tick(delta)


## Шаг слоя (публичный — тест гоняет его вместе с шагом мира без кадров движка).
func tick(dt: float) -> void:
	_clock += dt
	_hits_frame = 0
	for i in _pending_spawns.size():
		emit_spawn(_pending_spawns[i])
	_pending_spawns.clear()
	for p in _pools:
		p.step(dt)
	_tick_streams(dt)
	_tick_ambient(dt)
	_tick_charge(dt)
	_tick_bubbles(dt)
	impact.tick(dt)
	quirk.tick(dt)
	_hit_forget_t -= dt
	if _hit_forget_t <= 0.0:
		_hit_forget_t = CfgFx.HIT_FORGET
		for id: int in _hit_seen.keys():
			if _clock - float(_hit_seen[id]) > CfgFx.HIT_FORGET:
				_hit_seen.erase(id)
	for i in _layers.size():
		var busy := i == 1 and not _amb_glows.is_empty()
		if not busy:
			for p: LegionFxPool in _layer_pools[i]:
				if p.n > 0:
					busy = true
					break
		if busy or _drawn[i] != 0:
			_layers[i].queue_redraw()
			# ещё один кадр после опустения — стереть последний нарисованный
			_drawn[i] = 1 if busy else 0


func _draw_layer(idx: int) -> void:
	var node := _layers[idx]
	for p: LegionFxPool in _layer_pools[idx]:
		p.draw(node)
	if idx == 1:
		_draw_glows(node)


## Сколько частиц событий живо (фоновые — отдельно, ambient_count).
func live_count() -> int:
	var n := 0
	for p in _pools:
		if not p.ambient:
			n += p.n
	return n


func ambient_count() -> int:
	var n := 0
	for p in _pools:
		if p.ambient:
			n += p.n
	return n


func glow_count() -> int:
	return _amb_glows.size()


## Новая частица, если есть место под потолком; -1 — отброшена.
func _add(p: LegionFxPool, at: Vector2, life: float, size_a: float, size_b: float, alpha: float,
		c: Color) -> int:
	if p.ambient:
		if ambient_count() >= CfgFx.AMBIENT_CAP:
			return -1
	elif live_count() >= CfgFx.CAP:
		return -1
	return p.add(at.x, at.y, life, size_a, size_b, alpha, c)


func clear_all(with_ambient := false) -> void:
	for p in _pools:
		if with_ambient or not p.ambient:
			p.clear()
	_streams.clear()
	_pending_spawns.clear()
	_hit_seen.clear()
	impact.clear()
	if with_ambient:
		_amb_emit.clear()
		_amb_glows.clear()
		quirk.clear()


func _local(v: CharView) -> Vector2:
	return world.to_local(v.ground_point())


func _rr(r: Vector2) -> float:
	return rng.randf_range(r.x, r.y)


# ── Эффекты событий ─────────────────────────────────────────────────────────

func _dust_color(at: Vector2) -> Color:
	if _ground_img == null:
		return CfgFx.C_DUST
	var sz := _ground_img.get_size()
	# картинка земли покрывает весь мир карты (поле «Схватки» 1600×900 — P5b, B-304)
	var ws := world.world_size if world != null else LegionCfg.WORLD_SIZE
	var x := clampi(int(at.x / ws.x * sz.x), 0, sz.x - 1)
	var y := clampi(int(at.y / ws.y * sz.y), 0, sz.y - 1)
	var g := _ground_img.get_pixel(x, y)
	if g.get_luminance() > CfgFx.DUST_LUM_SPLIT:
		return g.darkened(CfgFx.DUST_DARKEN)
	return g.lerp(CfgFx.DUST_LIGHT, CfgFx.DUST_LIGHTEN)


## Уменьшенная копия фона карты — только для цвета пыли. Нет фона (или безголовый прогон
## без чтения текстур) — null, пыль берёт C_DUST. У процедурной карты (B-107) фон — не файл,
## а собранная PgArt текстура, которая может быть ещё не готова (SubViewport рендерит минимум
## кадр) — тогда досэмплируем её, как только TerrainView получит сигнал background_ready.
func _load_ground(map: Dictionary) -> void:
	_ground_img = null
	var tex := _ground_texture(map)
	if tex != null:
		_apply_ground_texture(tex)
	else:
		_await_ground_texture()


func _ground_texture(map: Dictionary) -> Texture2D:
	var bg := String(map.get("bg", ""))
	if not bg.is_empty() and ResourceLoader.exists(bg, "Texture2D"):
		return load(bg) as Texture2D
	var tv: TerrainView = world.ground_view() if world != null else null
	return tv.background_texture() if tv != null else null


func _await_ground_texture() -> void:
	var tv: TerrainView = world.ground_view() if world != null else null
	if tv != null and not tv.background_ready.is_connected(_apply_ground_texture):
		tv.background_ready.connect(_apply_ground_texture, CONNECT_ONE_SHOT)


func _apply_ground_texture(tex: Texture2D) -> void:
	var img := tex.get_image() if tex != null else null
	if img == null or img.is_empty():
		return
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	img.resize(CfgFx.GROUND_SAMPLE.x, CfgFx.GROUND_SAMPLE.y, Image.INTERPOLATE_BILINEAR)
	_ground_img = img


func emit_dust(at: Vector2, count: int, scale := 1.0) -> void:
	var col := _dust_color(at)
	for k in count:
		var i := _add(_dust, at + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-2.0, 2.0)),
			_rr(CfgFx.DUST_LIFE), CfgFx.DUST_SIZE.x * scale, CfgFx.DUST_SIZE.y * scale,
			CfgFx.DUST_ALPHA, col)
		if i < 0:
			return
		var ang := rng.randf() * TAU
		_dust.vx[i] = cos(ang) * CfgFx.DUST_SPEED * scale
		_dust.vy[i] = sin(ang) * CfgFx.DUST_SPEED * 0.4 * scale - CfgFx.DUST_RISE
		_dust.drag[i] = CfgFx.DUST_DRAG
		_dust.asp[i] = CfgFx.DUST_ASPECT
		_dust.rot[i] = rng.randf() * TAU
		_dust.spin[i] = rng.randf_range(-0.8, 0.8)
		_dust.fin[i] = 0.15
		_dust.fout[i] = 0.6


func emit_foe_death(at: Vector2, body_h: float, boss: bool) -> void:
	var sc := CfgFx.BOSS_SCALE if boss else 1.0
	emit_dust(at, CfgFx.BOSS_DUST_N if boss else CfgFx.FOE_DUST_N, 1.4 if boss else 1.0)
	var from := at - Vector2(0.0, body_h * CfgFx.SOUL_LIFT)
	var ph := rng.randf() * TAU
	var drift := rng.randf_range(-4.0, 4.0)
	for layer in 2:
		var core := layer == 1
		var sz := CfgFx.SOUL_CORE if core else CfgFx.SOUL_SIZE
		var pool := _soft if core else _halo
		var i := _add(pool, from, CfgFx.SOUL_LIFE * (1.2 if boss else 1.0), sz.x * sc, sz.y * sc,
			CfgFx.SOUL_CORE_ALPHA if core else CfgFx.SOUL_ALPHA,
			CfgFx.C_SOUL_CORE if core else CfgFx.C_SOUL)
		if i < 0:
			return
		pool.vx[i] = drift
		pool.vy[i] = -CfgFx.SOUL_RISE * (1.0 + 0.2 * (sc - 1.0))
		pool.wax[i] = CfgFx.SOUL_SWAY * sc
		pool.wf[i] = CfgFx.SOUL_SWAY_F
		pool.wph[i] = ph
		pool.fin[i] = 0.12
		pool.fout[i] = 0.55


func emit_bones(at: Vector2, body_h: float) -> void:
	emit_dust(at, CfgFx.UNIT_DUST_N)
	var from := at - Vector2(0.0, body_h * 0.4)
	for k in rng.randi_range(CfgFx.BONES_N.x, CfgFx.BONES_N.y):
		var ln := _rr(CfgFx.BONE_LEN)
		var i := _add(_bone, from, CfgFx.BONE_LIFE * rng.randf_range(0.85, 1.15), ln, ln, 1.0,
			CfgFx.C_BONE)
		if i < 0:
			return
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		_bone.vx[i] = side * _rr(CfgFx.BONE_VX)
		_bone.vy[i] = -_rr(CfgFx.BONE_VY)
		_bone.grav[i] = CfgFx.BONE_GRAV
		_bone.gy[i] = at.y + _rr(CfgFx.BONE_GROUND_JITTER)
		_bone.bn[i] = 1
		_bone.asp[i] = CfgFx.BONE_ASPECT
		_bone.rot[i] = rng.randf() * TAU
		_bone.spin[i] = rng.randf_range(-CfgFx.BONE_SPIN, CfgFx.BONE_SPIN)
		_bone.fin[i] = 0.02
		_bone.fout[i] = 0.35


func emit_spawn(at: Vector2) -> void:
	var i := _add(_ring, at, CfgFx.SPAWN_LIFE, CfgFx.SPAWN_RING.x, CfgFx.SPAWN_RING.y,
		CfgFx.SPAWN_RING_ALPHA, CfgFx.C_SPAWN)
	if i >= 0:
		_ring.asp[i] = CfgFx.SPAWN_RING_ASPECT
		_ring.fin[i] = 0.1
		_ring.fout[i] = 0.6
	emit_dust(at, CfgFx.SPAWN_DUST_N, 0.8)


func emit_hit(v: CharView) -> void:
	if _hits_frame >= CfgFx.HIT_PER_FRAME or not v.is_inside_tree():
		return
	var id := v.get_instance_id()
	if _clock - float(_hit_seen.get(id, -INF)) < CfgFx.HIT_VIEW_CD:
		return
	_hit_seen[id] = _clock
	_hits_frame += 1
	var at := _local(v) + Vector2(rng.randf_range(-1.0, 1.0) * v.body_h * CfgFx.HIT_SPREAD,
		-v.body_h * _rr(CfgFx.HIT_LIFT))
	var sz := _rr(CfgFx.HIT_SIZE)
	var i := _add(_spark, at, _rr(CfgFx.HIT_LIFE), sz, sz * 0.55, CfgFx.HIT_ALPHA, CfgFx.C_HIT)
	if i >= 0:
		_spark.fin[i] = 0.0
		_spark.fout[i] = 0.7


func emit_cauldron_splash() -> void:
	if _clock - _cauldron_hit_t < CfgFx.CAULDRON_HIT_CD:
		return
	_cauldron_hit_t = _clock
	var mouth := world.cauldron_view_pos + CfgFx.CAULDRON_MOUTH
	var i := _add(_soft, mouth, CfgFx.SPLASH_LIFE, CfgFx.SPLASH_SIZE.x, CfgFx.SPLASH_SIZE.y,
		CfgFx.SPLASH_ALPHA, CfgFx.C_POTION)
	if i >= 0:
		_soft.asp[i] = 0.6
		_soft.fin[i] = 0.05
	for k in rng.randi_range(CfgFx.DROPS_N.x, CfgFx.DROPS_N.y):
		var sz := _rr(CfgFx.DROP_SIZE)
		var at := mouth + Vector2(rng.randf_range(-1.0, 1.0) * CfgFx.CAULDRON_MOUTH_W, 0.0)
		i = _add(_halo, at, _rr(CfgFx.DROP_LIFE), sz, sz * 0.7, CfgFx.DROP_ALPHA, CfgFx.C_POTION)
		if i < 0:
			return
		_halo.vx[i] = rng.randf_range(-1.0, 1.0) * CfgFx.DROP_VX
		_halo.vy[i] = -_rr(CfgFx.DROP_VY)
		_halo.grav[i] = CfgFx.DROP_GRAV
		_halo.gy[i] = world.cauldron_view_pos.y + _rr(CfgFx.DROP_GROUND)
		_halo.fin[i] = 0.0
		_halo.fout[i] = 0.4


func emit_gate(at: Vector2) -> void:
	for layer in 2:
		var core := layer == 1
		var sz := CfgFx.GATE_CORE if core else CfgFx.GATE_SIZE
		var i := _add(_glow_g, at, CfgFx.GATE_LIFE, sz * 0.8, sz,
			CfgFx.GATE_CORE_ALPHA if core else CfgFx.GATE_ALPHA, CfgFx.C_GATE)
		if i >= 0:
			_glow_g.fin[i] = 0.25
			_glow_g.fout[i] = 0.6


func emit_breach(at: Vector2) -> void:
	var i := _add(_glow_g, at, CfgFx.BREACH_LIFE, CfgFx.BREACH_FLASH.x, CfgFx.BREACH_FLASH.y,
		CfgFx.BREACH_FLASH_ALPHA, CfgFx.C_BREACH)
	if i >= 0:
		_glow_g.asp[i] = 0.7
		_glow_g.fin[i] = 0.05
	var col := _dust_color(at)
	for k in CfgFx.BREACH_DUST_N:
		var ang := TAU * float(k) / float(CfgFx.BREACH_DUST_N) + rng.randf_range(-0.3, 0.3)
		i = _add(_dust, at, _rr(CfgFx.DUST_LIFE) * 1.4, CfgFx.DUST_SIZE.x, CfgFx.DUST_SIZE.y * 1.3,
			CfgFx.DUST_ALPHA, col)
		if i < 0:
			return
		_dust.vx[i] = cos(ang) * CfgFx.BREACH_DUST_SPEED
		_dust.vy[i] = sin(ang) * CfgFx.BREACH_DUST_SPEED * 0.5
		_dust.drag[i] = CfgFx.DUST_DRAG
		_dust.asp[i] = CfgFx.DUST_ASPECT
		_dust.rot[i] = rng.randf() * TAU
		_dust.fin[i] = 0.1
		_dust.fout[i] = 0.6


func emit_paper() -> void:
	# листы падают по видимому миру (B-304; одиночка — кадр 1280×720)
	var vr := _view()
	var at := Vector2(rng.randf_range(vr.position.x, vr.end.x),
		rng.randf_range(vr.position.y - 20.0, vr.end.y - 120.0))
	var sz := _rr(CfgFx.PAPER_SIZE)
	var i := _add(_paper, at, _rr(CfgFx.PAPER_LIFE), sz, sz, CfgFx.PAPER_ALPHA, CfgFx.C_PAPER)
	if i < 0:
		return
	_paper.vy[i] = _rr(CfgFx.PAPER_FALL)
	_paper.wax[i] = _rr(CfgFx.PAPER_SWAY)
	_paper.wf[i] = _rr(CfgFx.PAPER_SWAY_F)
	_paper.wph[i] = rng.randf() * TAU
	_paper.asp[i] = CfgFx.PAPER_ASPECT
	_paper.rot[i] = rng.randf() * TAU
	_paper.spin[i] = rng.randf_range(-CfgFx.PAPER_SPIN, CfgFx.PAPER_SPIN)
	_paper.fin[i] = 0.2
	_paper.fout[i] = 0.35


func emit_dark_smoke() -> void:
	var at := world.cauldron_view_pos + CfgFx.CAULDRON_MOUTH \
		+ Vector2(rng.randf_range(-1.0, 1.0) * CfgFx.CAULDRON_MOUTH_W, 0.0)
	var i := _add(_smoke, at, _rr(CfgFx.SMOKE_LIFE), CfgFx.SMOKE_SIZE.x, CfgFx.SMOKE_SIZE.y,
		CfgFx.SMOKE_ALPHA, CfgFx.C_SMOKE_DARK)
	if i < 0:
		return
	_smoke.vx[i] = rng.randf_range(-8.0, 8.0)
	_smoke.vy[i] = -_rr(CfgFx.SMOKE_RISE)
	_smoke.rot[i] = rng.randf() * TAU
	_smoke.spin[i] = rng.randf_range(-0.4, 0.4)
	_smoke.fin[i] = 0.2
	_smoke.fout[i] = 0.6


func emit_bubble() -> void:
	var at := world.cauldron_view_pos + CfgFx.CAULDRON_MOUTH \
		+ Vector2(rng.randf_range(-1.0, 1.0) * CfgFx.CAULDRON_MOUTH_W, 0.0)
	var sz := _rr(CfgFx.BUBBLE_SIZE)
	var i := _add(_soft, at, _rr(CfgFx.BUBBLE_LIFE), sz, sz * 1.2, CfgFx.BUBBLE_ALPHA,
		CfgFx.C_POTION)
	if i < 0:
		return
	_soft.vy[i] = -_rr(CfgFx.BUBBLE_RISE)
	_soft.wax[i] = 2.0
	_soft.wf[i] = 4.0
	_soft.wph[i] = rng.randf() * TAU
	_soft.fin[i] = 0.2
	_soft.fout[i] = 0.5


# ── Сигналы мира ────────────────────────────────────────────────────────────

func _on_foe_killed(foe: Foe, pos: Vector2) -> void:
	var h := foe.view.body_h if foe.view != null else 40.0
	emit_foe_death(pos, h, foe.type_id == "boss")


func _on_unit_died(u: Legionnaire) -> void:
	var at := _local(u.view) if u.view != null else u.position
	emit_bones(at, u.view.body_h if u.view != null else 36.0)


func _on_unit_spawned(u: Legionnaire) -> void:
	_pending_spawns.append(u.position)


func _on_hit(v: CharView) -> void:
	emit_hit(v)


func _on_cauldron_hit(_amount: float) -> void:
	emit_cauldron_splash()


func _on_wave_started(i: int, _total: int) -> void:
	for at in gate_points(i):
		emit_gate(at)


func _on_breach_opened(id: String) -> void:
	emit_breach(world.breach_pos(id))


func _on_match_started(map_id: String) -> void:
	clear_all(true)
	_load_ground(world.map)
	# Процедурная карта (STAGE2 §3) несёт фоновую жизнь словарём map.ambient — той же схемы,
	# что файл кампании; кампанийная карта — по-прежнему из assets/legion/ambient/<id>.json.
	if world.map.has("ambient"):
		load_ambient_dict(world.map.get("ambient", {}) as Dictionary)
		quirk.load_map(world.map)
	else:
		load_ambient(CfgFx.AMBIENT_DIR + map_id + ".json")


func _on_match_ended(victory: bool, _stats: Dictionary) -> void:
	if victory:
		_streams.append({"kind": &"paper", "left": CfgFx.PAPER_TIME, "rate": CfgFx.PAPER_RATE,
			"acc": 0.0})
	else:
		_streams.append({"kind": &"smoke", "left": CfgFx.SMOKE_TIME, "rate": CfgFx.SMOKE_RATE,
			"acc": 0.0})


## Ворота, откуда идёт волна i: начало дороги каждой группы без прорыва, чуть внутрь карты.
func gate_points(i: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if world.wave_runner == null or i < 0 or i >= world.wave_runner.waves.size():
		return out
	var seen := {}
	for g: Dictionary in (world.wave_runner.waves[i] as Dictionary).get("groups", []):
		var road := String(g.get("road", ""))
		if String(g.get("breach", "")) != "" or road == "" or seen.has(road):
			continue
		seen[road] = true
		var path := world.road_path(road)
		if path.size() < 2:
			continue
		# ворота часто под панелями HUD (превью волны, способности) — отсвет под панелью не
		# виден; идём по дороге внутрь, пока ядро отсвета не выйдет из-под них (как маркер
		# угрозы LegionThreatEdge)
		var rects: Array[Rect2] = world.hud.panel_rects() if world.hud != null else []
		# панели HUD — в координатах экрана, точка дороги — мира: сравниваем на экране (B-304)
		var d := 0.0
		var p := _along(path, d)
		while d < CfgFx.GATE_MAX_INSET and _hidden(world.world_to_screen(p), rects):
			d += CfgFx.GATE_STEP
			p = _along(path, d)
		var m := Vector2.ONE * CfgFx.GATE_MARGIN
		var vr := _view()
		out.append(p.clamp(vr.position + m, vr.end - m))
	return out


## Видимая часть мира (LegionWorld.view_rect): одиночка — кадр 1280×720, «Схватка» — всё поле.
func _view() -> Rect2:
	return world.view_rect() if world != null else Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE)


static func _along(path: PackedVector2Array, dist: float) -> Vector2:
	var left := dist
	for k in path.size() - 1:
		var seg := path[k + 1] - path[k]
		var ln := seg.length()
		if left <= ln and ln > 0.0:
			return path[k] + seg * (left / ln)
		left -= ln
	return path[path.size() - 1]


## Экранная точка за краем экрана (дороги начинаются за картой) или под панелью HUD.
static func _hidden(p: Vector2, rects: Array[Rect2]) -> bool:
	if not Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).grow(-CfgFx.GATE_INSET).has_point(p):
		return true
	for r in rects:
		if r.grow(CfgFx.GATE_CORE * 0.5).has_point(p):
			return true
	return false


# ── Потоки и фоновые тики ───────────────────────────────────────────────────

func _tick_streams(dt: float) -> void:
	for k in range(_streams.size() - 1, -1, -1):
		var s := _streams[k]
		s["left"] = float(s["left"]) - dt
		var acc := float(s["acc"]) + float(s["rate"]) * dt
		while acc >= 1.0:
			acc -= 1.0
			if s["kind"] == &"paper":
				emit_paper()
			else:
				emit_dark_smoke()
		s["acc"] = acc
		if float(s["left"]) <= 0.0:
			_streams.remove_at(k)


func _tick_charge(dt: float) -> void:
	_charge_t += dt
	if _charge_t < CfgFx.CHARGE_SCAN or world == null:
		return
	var chance := CfgFx.CHARGE_RATE * _charge_t
	_charge_t = 0.0
	for u in world.units:
		if u.alive and u.state == Legionnaire.State.CHARGE and rng.randf() < chance:
			emit_dust(u.position, 1, CfgFx.CHARGE_DUST_SCALE)


func _tick_bubbles(dt: float) -> void:
	if world == null or world.map.is_empty():
		return
	_bubble_acc += CfgFx.BUBBLE_RATE * dt * rng.randf_range(0.5, 1.5)
	while _bubble_acc >= 1.0:
		_bubble_acc -= 1.0
		emit_bubble()


# ── Фоновая жизнь карты ─────────────────────────────────────────────────────

## Данные карты: assets/legion/ambient/<map>.json (схема — в докстринге ниже).
## Нет файла — фона нет, false.
## {"glows":[{"pos":[x,y],"r":24,"color":"ffb060","flicker":0.25}],
##  "embers":[{"rect":[x,y,w,h],"rate":1.5,"color":"ff7a30"}],
##  "fog":[{"rect":[x,y,w,h],"count":3,"color":"c8d2e8","alpha":0.10,"drift":[6,0]}],
##  "wisps":[{"rect":[x,y,w,h],"count":3,"color":"7fffd8"}],
##  "water":[{"poly":[[x,y],...],"rate":3,"color":"e0f6ff"}]}
func load_ambient(path: String) -> bool:
	if not FileAccess.file_exists(path):
		_clear_ambient()
		return false
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_warning("LegionFx: не разобрать %s" % path)
		_clear_ambient()
		return false
	return load_ambient_dict(data as Dictionary)


func _clear_ambient() -> void:
	_amb_emit.clear()
	_amb_glows.clear()
	for p in _pools:
		if p.ambient:
			p.clear()


## Общая схема разбора фоновой жизни карты (докстринг load_ambient выше) — что для файла
## кампании (load_ambient), что для словаря процедурной карты map.ambient (B-107, STAGE2 §3):
## один код чтения, чтобы генератор не собирал свой отдельный формат.
func load_ambient_dict(d: Dictionary) -> bool:
	_clear_ambient()
	for g: Dictionary in d.get("glows", []):
		_amb_glows.append({"pos": _vec(g.get("pos", [0, 0])), "r": float(g.get("r", 24.0)),
			"color": _col(g.get("color", "ffb060")), "flicker": float(g.get("flicker", 0.25)),
			"p1": rng.randf() * TAU, "p2": rng.randf() * TAU})
	for e: Dictionary in d.get("embers", []):
		_amb_emit.append({"kind": &"ember", "rect": _rect(e.get("rect", [])),
			"rate": float(e.get("rate", 1.5)), "color": _col(e.get("color", "ff7a30")), "acc": 0.0})
	for f: Dictionary in d.get("fog", []):
		var cnt := int(f.get("count", 3))
		_amb_emit.append({"kind": &"fog", "rect": _rect(f.get("rect", [])),
			"rate": float(cnt) / ((CfgFx.FOG_LIFE.x + CfgFx.FOG_LIFE.y) * 0.5), "count": cnt,
			"color": _col(f.get("color", "c8d2e8")), "alpha": float(f.get("alpha", 0.1)),
			"drift": _vec(f.get("drift", [6, 0])), "acc": 0.0})
	for wsp: Dictionary in d.get("wisps", []):
		var cnt := int(wsp.get("count", 3))
		_amb_emit.append({"kind": &"wisp", "rect": _rect(wsp.get("rect", [])),
			"rate": float(cnt) / ((CfgFx.WISP_LIFE.x + CfgFx.WISP_LIFE.y) * 0.5), "count": cnt,
			"color": _col(wsp.get("color", "7fffd8")), "acc": 0.0})
	for wt: Dictionary in d.get("water", []):
		var poly := PackedVector2Array()
		for pt: Variant in wt.get("poly", []):
			poly.append(_vec(pt))
		if poly.size() >= 3:
			var box := Rect2(poly[0], Vector2.ZERO)
			for pt in poly:
				box = box.expand(pt)
			_amb_emit.append({"kind": &"water", "poly": poly, "rect": box,
				"rate": float(wt.get("rate", 3.0)), "color": _col(wt.get("color", "e0f6ff")),
				"acc": 0.0})
	# туман и огоньки сразу на месте, в разном возрасте — а не проявляются всем разом
	for em in _amb_emit:
		if em.has("count"):
			for k in int(em["count"]):
				_emit_ambient(em, rng.randf_range(0.1, 0.8))
	return true


static func _vec(v: Variant) -> Vector2:
	var a := v as Array
	if a == null or a.size() < 2:
		return Vector2.ZERO
	return Vector2(float(a[0]), float(a[1]))


static func _rect(v: Variant) -> Rect2:
	var a := v as Array
	if a == null or a.size() < 4:
		return Rect2()
	return Rect2(float(a[0]), float(a[1]), float(a[2]), float(a[3]))


static func _col(v: Variant) -> Color:
	var s := String(v)
	return Color.html(s) if Color.html_is_valid(s) else Color.WHITE


func _tick_ambient(dt: float) -> void:
	for em in _amb_emit:
		var acc := float(em["acc"]) + float(em["rate"]) * dt
		while acc >= 1.0:
			acc -= 1.0
			_emit_ambient(em)
		em["acc"] = acc


func _rand_in(r: Rect2) -> Vector2:
	return r.position + Vector2(rng.randf() * r.size.x, rng.randf() * r.size.y)


## age_frac > 0 — частица рождается уже прожившей эту долю жизни (прогрев фона при загрузке).
func _emit_ambient(em: Dictionary, age_frac := 0.0) -> int:
	var r: Rect2 = em["rect"]
	var c: Color = em["color"]
	var i := -1
	match em["kind"]:
		&"ember":
			i = _add(_ember, _rand_in(r), _rr(CfgFx.EMBER_LIFE), CfgFx.EMBER_SIZE.x,
				CfgFx.EMBER_SIZE.y, CfgFx.EMBER_ALPHA, c)
			if i >= 0:
				_ember.vx[i] = rng.randf_range(-4.0, 4.0)
				_ember.vy[i] = -_rr(CfgFx.EMBER_RISE)
				_ember.wax[i] = CfgFx.EMBER_SWAY
				_ember.wf[i] = rng.randf_range(2.0, 3.2)
				_ember.wph[i] = rng.randf() * TAU
				_ember.fin[i] = 0.1
				_ember.fout[i] = 0.5
		&"fog":
			var base := minf(minf(r.size.x, r.size.y), CfgFx.FOG_SIZE_MAX / CfgFx.FOG_GROW)
			var sz := base * _rr(CfgFx.FOG_SIZE)
			i = _add(_fog, _rand_in(r), _rr(CfgFx.FOG_LIFE), sz, sz * CfgFx.FOG_GROW,
				float(em["alpha"]), c)
			if i >= 0:
				var drift: Vector2 = em["drift"]
				_fog.vx[i] = drift.x * rng.randf_range(0.7, 1.3)
				_fog.vy[i] = drift.y * rng.randf_range(0.7, 1.3)
				_fog.asp[i] = 0.6
				_fog.rot[i] = rng.randf() * TAU
				_fog.spin[i] = rng.randf_range(-0.05, 0.05)
				_fog.fin[i] = 0.3
				_fog.fout[i] = 0.35
				_fog.age[i] = _fog.life[i] * age_frac
		&"wisp":
			i = _add(_wisp, _rand_in(r), _rr(CfgFx.WISP_LIFE), CfgFx.WISP_SIZE,
				CfgFx.WISP_SIZE * 0.8, CfgFx.WISP_ALPHA, c)
			if i >= 0:
				var ang := rng.randf() * TAU
				_wisp.vx[i] = cos(ang) * CfgFx.WISP_DRIFT
				_wisp.vy[i] = sin(ang) * CfgFx.WISP_DRIFT
				_wisp.wax[i] = _rr(CfgFx.WISP_SWAY)
				_wisp.way[i] = _rr(CfgFx.WISP_SWAY) * 0.6
				_wisp.wf[i] = _rr(CfgFx.WISP_SWAY_F)
				_wisp.wph[i] = rng.randf() * TAU
				_wisp.fin[i] = 0.25
				_wisp.fout[i] = 0.3
				_wisp.age[i] = _wisp.life[i] * age_frac
				# светлое ядро идёт тем же путём — огонёк, а не пятно
				var j := _add(_wisp, Vector2(_wisp.px[i], _wisp.py[i]), _wisp.life[i],
					CfgFx.WISP_CORE, CfgFx.WISP_CORE * 0.8, 1.0, c.lerp(Color.WHITE, 0.6))
				if j >= 0:
					_wisp.copy_motion(i, j)
		&"water":
			var poly: PackedVector2Array = em["poly"]
			for t in CfgFx.WATER_TRIES:
				var p := _rand_in(r)
				if Geometry2D.is_point_in_polygon(p, poly):
					var sz := _rr(CfgFx.WATER_SIZE)
					i = _add(_water, p, _rr(CfgFx.WATER_LIFE), sz * 0.6, sz, CfgFx.WATER_ALPHA, c)
					if i >= 0:
						_water.asp[i] = 0.7
						_water.fin[i] = 0.4
						_water.fout[i] = 0.6
					break
	return i


## Ореолы свечей: мерцание — сумма двух синусоид со своей фазой (живой огонь, а не шум кадра).
func _draw_glows(ci: CanvasItem) -> void:
	for g in _amb_glows:
		var n := 0.5 + 0.5 * (0.6 * sin(_clock * CfgFx.GLOW_FREQ.x + float(g["p1"]))
			+ 0.4 * sin(_clock * CfgFx.GLOW_FREQ.y + float(g["p2"])))
		var fl := float(g["flicker"])
		var c: Color = g["color"]
		c.a = CfgFx.GLOW_ALPHA * (1.0 - fl * n)
		var s := float(g["r"]) * 2.0 * (1.0 + CfgFx.GLOW_SIZE_WOBBLE * (n - 0.5))
		var pos: Vector2 = g["pos"]
		ci.draw_texture_rect(_glow_tex, Rect2(pos - Vector2(s, s) * 0.5, Vector2(s, s)), false, c)
