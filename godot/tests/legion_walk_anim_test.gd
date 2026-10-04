extends SceneTree
## Ходьба не скользит (Игорь 29.09.2026: «зелёные чуваки в котелках практически не ходят, а просто
## дрыгаются»). У каждого, кто ходит ногами в бою (враги FOES и бойцы UNIT_KINDS), опорная ступня
## клипа walk должна идти назад по земле со скоростью, близкой к скорости персонажа в бою:
## опора = скорость ступни / скорость хода, коридор [MIN_SUPPORT, MAX_SUPPORT]. У прежних клипов
## anim_v4 (одна поза с дрожанием) опора 0 — нотариус, мимик, юрист, босс, счетовод; у зомби 0,32,
## у жука 0,12 (tools/walk_audit.py, та же метрика).
##
## Метрика — как в tools/walk_audit.py: профиль альфы самых нижних рядов (≈1,8 % роста: в них
## обычно остаётся опорная ступня). Неподвижную часть профиля вычитаем по минимуму за цикл:
## низ висящего портфеля может попасть туда же, но не является опорой. Сдвиг между соседними
## кадрами — лучший по корреляции, скорость =
## сдвиг × масштаб холста в мир / длительность кадра; медиана по циклу. Скорость и рост — из
## LegionCfg, темп и холст — из CfgAnim, поэтому тест ловит и «поменяли скорость врага, а клип нет».
## Парящие (motion.float > 0 — призрак) пропускаются: у них шага нет.
##
## Проверка на старых кадрах (должна падать):
##   ... --script res://tests/legion_walk_anim_test.gd -- --mute --anim-root <папка с <char>/walk>
##       --cfg-anim <старый cfg_anim.gd>
## (--cfg-anim — откуда брать fps walk; без него — живой CfgAnim.)

const MIN_SUPPORT := 0.5
const MAX_SUPPORT := 1.6
const ALPHA_MIN := 16.0 / 255.0
const CONTACT_BAND := 0.018

var _checks := 0
var _fails := 0
var _anim_root := ""
var _cfg_src := ""
var _cache := {}


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--anim-root" and i + 1 < args.size():
			_anim_root = args[i + 1]
		elif args[i] == "--cfg-anim" and i + 1 < args.size():
			_cfg_src = FileAccess.get_file_as_string(args[i + 1])


func _walk_dir(char_id: String) -> String:
	if _anim_root != "":
		return _anim_root.path_join(char_id).path_join("walk")
	var clips: Dictionary = CfgAnim.CHARS[char_id]["clips"]
	return ProjectSettings.globalize_path(String(clips["walk"]["dir"]))


func _walk_fps(char_id: String) -> float:
	if _cfg_src != "":
		var re := RegEx.new()
		re.compile('"res://assets/anim/%s/walk",\\s*"fps":\\s*([0-9.]+)' % char_id)
		var m := re.search(_cfg_src)
		return float(m.get_string(1)) if m != null else 12.0
	var clips: Dictionary = CfgAnim.CHARS[char_id]["clips"]
	return float(clips["walk"]["fps"])


## Кадры клипа: {imgs, durs}. Кэш — один персонаж служит нескольким видам врагов.
func _clip(char_id: String) -> Dictionary:
	if _cache.has(char_id):
		return _cache[char_id]
	var dir := _walk_dir(char_id)
	var imgs: Array[Image] = []
	var i := 0
	while FileAccess.file_exists(dir.path_join("spr_%02d.png" % i)):
		imgs.append(Image.load_from_file(dir.path_join("spr_%02d.png" % i)))
		i += 1
	var durs: Array = []
	var figure_fill := 0.0
	var meta_path := dir.path_join("clip.json")
	if FileAccess.file_exists(meta_path):
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if meta is Dictionary:
			durs = (meta as Dictionary).get("durations", [])
			figure_fill = float((meta as Dictionary).get("figure_fill", 0.0))
	var res := {"imgs": imgs, "durs": durs, "figure_fill": figure_fill}
	_cache[char_id] = res
	return res


## Верх и низ силуэта кадра (альфа > 16) — строки, где есть хоть один плотный пиксель.
func _rows(img: Image) -> Vector2i:
	var r := img.get_used_rect()
	var top := -1
	var bot := -1
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if img.get_pixel(x, y).a > ALPHA_MIN:
				top = y
				break
		if top >= 0:
			break
	for y in range(r.end.y - 1, r.position.y - 1, -1):
		for x in range(r.position.x, r.end.x):
			if img.get_pixel(x, y).a > ALPHA_MIN:
				bot = y
				break
		if bot >= 0:
			break
	return Vector2i(top, bot)


func _median(v: Array) -> float:
	var s := v.duplicate()
	s.sort()
	var n := s.size()
	if n == 0:
		return 0.0
	return float(s[n / 2]) if n % 2 == 1 else (float(s[n / 2 - 1]) + float(s[n / 2])) * 0.5


## Сдвиг d профиля p0 → p1 (p1(x) ≈ p0(x − d)): наибольшее перекрытие, при равенстве — меньший |d|.
func _shift(p0: PackedFloat32Array, p1: PackedFloat32Array, max_d: int) -> int:
	var best := -1.0
	var best_d := 0
	var n := p0.size()
	var order: Array[int] = [0]
	for k in range(1, max_d + 1):
		order.append(-k)   # порядок как у sorted(key=abs) в walk_audit.py: −k раньше +k
		order.append(k)
	for d in order:
		var s := 0.0
		for x in range(maxi(0, d), mini(n, n + d)):
			s += minf(p0[x - d], p1[x])
		if s > best + 1e-6:
			best = s
			best_d = d
	return best_d


func _without_static(profiles: Array[PackedFloat32Array]) -> Array[PackedFloat32Array]:
	var baseline := profiles[0].duplicate()
	for profile: PackedFloat32Array in profiles:
		for x in baseline.size():
			baseline[x]=minf(baseline[x],profile[x])
	var result: Array[PackedFloat32Array]=[]
	for profile: PackedFloat32Array in profiles:
		var moving := profile.duplicate()
		for x in moving.size():
			moving[x]-=baseline[x]
		result.append(moving)
	return result


## Опора клипа walk персонажа при скорости speed и росте body_h (px мира).
func _support(char_id: String, body_h: float, speed: float) -> float:
	var clip := _clip(char_id)
	var imgs: Array[Image] = clip["imgs"]
	if imgs.size() < 2:
		return 0.0
	var tops: Array = []
	var bots: Array = []
	var heights: Array = []
	for img in imgs:
		var tb := _rows(img)
		tops.append(tb.x)
		bots.append(tb.y)
		heights.append(tb.y - tb.x)
	var h := _median(heights)
	var ground := int(_median(bots))
	var y0 := int(ground - CONTACT_BAND * h)
	var w := imgs[0].get_width()
	var profiles: Array[PackedFloat32Array] = []
	for img in imgs:
		var p := PackedFloat32Array()
		p.resize(w)
		for x in w:
			var c := 0.0
			for y in range(y0, ground + 1):
				if img.get_pixel(x, y).a > ALPHA_MIN:
					c += 1.0
			p[x] = c
		profiles.append(p)
	profiles = _without_static(profiles)
	var def: Dictionary = CfgAnim.CHARS[char_id]
	var fill := float(clip["figure_fill"])
	if fill <= 0.0:
		fill = float(def.get("figure_fill", 0.85))
	var scale := body_h / (float(w) * fill)
	var fps := _walk_fps(char_id)
	var durs: Array = clip["durs"]
	var speeds: Array = []
	var n := imgs.size()
	for i in n:
		var d := _shift(profiles[i], profiles[(i + 1) % n], int(0.25 * h))
		var dur := float(durs[i]) if i < durs.size() else 1.0
		speeds.append(-float(d) * scale / (dur / fps))
	return _median(speeds) / speed


func _legged(char_id: String) -> bool:
	return float(CfgAnim.motion_for(char_id).get("float", 0.0)) <= 0.0


func _run() -> void:
	_parse_args()
	# Independent example: a broad stationary accessory obscures a narrow
	# planted foot in correlation, despite an exact -2px displacement.
	var examples: Array[PackedFloat32Array]=[]
	for offset in [0,2,4]:
		var profile := PackedFloat32Array()
		profile.resize(100)
		for x in range(10,50):
			profile[x]=3
		for x in range(80-offset,85-offset):
			profile[x]=3
		examples.append(profile)
	var cleaned := _without_static(examples)
	_check(_shift(examples[0],examples[1],6)==0 and _shift(cleaned[0],cleaned[1],6)==-2,
		"неподвижный аксессуар не маскирует движение ступни")
	var seen := {}
	for type: String in LegionCfg.FOES:
		var def: Dictionary = LegionCfg.FOES[type]
		var char_id := String(def["char"])
		if not CfgAnim.CHARS.has(char_id) or not _legged(char_id):
			continue
		if not DirAccess.dir_exists_absolute(_walk_dir(char_id)):
			continue
		var r := _support(char_id, float(def["body"]), float(def["speed"]))
		_check(r >= MIN_SUPPORT and r <= MAX_SUPPORT,
			"враг %s (%s): опора %.2f в [%.1f, %.1f]" % [type, char_id, r, MIN_SUPPORT, MAX_SUPPORT])
		seen[char_id] = true
	for kind: StringName in LegionCfg.UNIT_KINDS:
		var spec: Dictionary = LegionCfg.UNIT_KINDS[kind]
		# тот же выбор вида, что в unit.gd setup()
		var char_id := "skeleton" if kind == LegionCfg.KIND_LABORER else String(kind)
		if not CfgAnim.CHARS.has(char_id) or not DirAccess.dir_exists_absolute(_walk_dir(char_id)):
			continue
		var r := _support(char_id, float(spec["body_h"]), float(spec["speed"]))
		_check(r >= MIN_SUPPORT and r <= MAX_SUPPORT,
			"боец %s (%s): опора %.2f в [%.1f, %.1f]" % [kind, char_id, r, MIN_SUPPORT, MAX_SUPPORT])
		seen[char_id] = true
	_check(seen.has("signer"), "нотариус проверен")
	print("LEGION WALK ANIM: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
