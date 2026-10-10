extends Node
##
## Режиссёр записи промо: настоящий бой по сценарию — для роликов и кадров Steam движком, без
## генерации картинок. Аудит записи 08.10.2026 (docs/dev/audit-1008/recording.md, REC-04/05/06).
##
##   --dev director=C:/путь/сценарий.json
## (только отладочная сборка; обычно запускает tools/promo/record.py)
##
## Мир, симуляция и ввод — игровые: линии, фигуры, рогатка и способности идут НАСТОЯЩИМИ событиями
## мыши и клавиатуры (Input.parse_input_event, как corr_play.gd и тесты *_shots), бойцы и враги
## живут по правилам боя. Постановка — только в расстановке: сколько бойцов и врагов и где они
## стоят на старте, сколько душ и маны, какая волна идёт (читы ниже). Настоящие мышь и клавиатура
## на время прогона глушатся. Время сценария — кадры с его начала (t = кадр / 60), поэтому запуск
## обязателен с --fixed-fps 60: тогда прогон с тем же сидом повторяется кадр в кадр.
##
## Сценарий (JSON):
##   {"map": "wasteland", "seed": 7,            — проверка: карта и сид задаются аргументами запуска
##    "hud": "full" | "clean" | "off",          — clean: без тостов/превью волны/подсказок;
##                                                 off: без HUD вовсе (кадры Steam без текста)
##    "cursor": true,                           — свой курсор (курсор ОС в запись не попадает)
##    "setup": {ЧИТЫ},  "steps": [{"t": сек, "do": ДЕЙСТВИЕ, ...}, ...]}
## ЧИТЫ (в setup и как шаг "do": "cheat"; souls/mana/mana_regen/army/boss/wave/hold_waves/cd/hints —
## ещё и --dev director_<ключ>=N поверх сценария, например director_army=60 director_boss=1):
##   souls=N, mana=N (и потолок маны), mana_regen=K (множитель), army=N (подрядчики у Котла) или
##   [{kind, n, at, r, side?}] (side 1 — соперник «Схватки»), foes=[{road, from, to, types, n,
##   jitter, wave?}] (доли длины дороги 0..1; wave — сила врага волны N по сложности),
##   boss=1 или {road, at, wave?}, wave=N (волна N карты — её настоящие группы), hold_waves=true
##   (часы волн стоят), build=[{plot, kind, level}], cd=true (откаты Ку/Дубль-вэ/Е), hints=false.
## ДЕЙСТВИЯ: kind {kind: 1|2|3}; draw {pts, toward?, kind?, hand?}; ring {center, r, kind?,
##   squeeze?}; poly {pts (замкнутая), kind?}; eight {center, r, kind?}; sling {from, to, hold?};
##   aim {from, to}; key {key: Q|W|E|R|F|..., at, hold?}; tap/rtap {at}; move {to, frames?};
##   camera {zoom, at | follow: fight|foes, time?, cut?} (крупный план, см. _update_camera);
##   foes с width — толпа рядами по ширине дороги, а не цепочка;
##   cheat {ЧИТЫ}; hud {mode}; cursor {show}; shot {name} (PNG без потерь в папку
##   --dev director_out=…); mark {name} (печать EDIT_MARK для монтажа); end.
## Дубль без HUD и курсора — --dev director_hud=off --dev director_cursor=0 (бой тот же).
## В записи (Movie Maker) шина Master опускается на headroom_db (6 dB) — против клиппинга микса.
## Координаты — мировые (одиночка 1280×720 — те же, что экран 1280×720; «Схватка» — 1600×900).
##

## Сценарий доигран (тест гейта ждёт его; запись выходит сама, если "quit" не false).
signal finished

const DEVICE := 9
const FPS := 60
## Шаг протяжки за кадр (px): быстрая, но человеческая рука — 600 px/с.
const STEP_PX := 10.0
const KEYS := {"Q": KEY_Q, "W": KEY_W, "E": KEY_E, "R": KEY_R, "F": KEY_F, "N": KEY_N,
	"D": KEY_D, "TAB": KEY_TAB, "SPACE": KEY_SPACE, "1": KEY_1, "2": KEY_2, "3": KEY_3}
## Камера: «в стычке» — враг ближе этого к бойцу (px); пересчёт центра раз в столько кадров.
const CAM_CONTACT := 140.0
const CAM_RETARGET := 6
## Мгновенные шаги — своя дорожка, не ждут штрихов руки.
const TIMELINE_STEPS := ["camera", "shot", "mark", "cheat", "hud", "cursor"]
## Шаг рядов толпы врагов вдоль дороги и места в ряду поперёк (px).
const FOE_ROW := 17.0
## Шаг указателя без нажатия (px за кадр): рука между действиями переносится быстрее.
const MOVE_PX := 26.0
const CHEAT_KEYS := ["souls", "mana", "mana_regen", "army", "boss", "wave", "hold_waves", "cd",
	"hints"]

var world: LegionWorld = null
var path := ""
var scenario: Dictionary = {}
## Кадры с начала сценария (часы шагов).
var frame := 0
var _last_screen := Vector2.ZERO
var _cursor: DirectorCursor = null
var _cursor_layer: CanvasLayer = null
var _rng := RandomNumberGenerator.new()
var _hud_mode := "full"
var _cursor_world := Vector2.INF
## Дорожка «пульта» — мгновенные шаги по своим кадрам (см. _run).
var _timeline: Array = []
var _timeline_i := 0
var _timeline_on := false
var _cam_on := false
var _cam_zoom := 1.0
var _cam_target_zoom := 1.0
var _cam_at := Vector2.ZERO
var _cam_target_at := Vector2.ZERO
var _cam_tau := 0.9
var _cam_follow := ""
var _ended := false
var _evidence_on := false
var _max_bend := 0.0


## Свой курсор: стрелка-перо тёмным с белым кантом; нажатая кнопка — точка «чернил» у острия.
class DirectorCursor:
	extends Node2D

	var pressed := false

	func _draw() -> void:
		var pts := PackedVector2Array([Vector2(0, 0), Vector2(3.5, 21), Vector2(8.5, 15.5),
			Vector2(15, 24), Vector2(19, 21), Vector2(12.5, 12.5), Vector2(20, 11)])
		var shadow := PackedVector2Array()
		for p in pts:
			shadow.append(p + Vector2(1.5, 2.0))
		draw_colored_polygon(shadow, Color(0, 0, 0, 0.35))
		draw_colored_polygon(pts, Color(0.10, 0.07, 0.16, 0.97))
		var ring := pts.duplicate()
		ring.append(pts[0])
		draw_polyline(ring, Color(0.96, 0.93, 1.0), 1.6, true)
		if pressed:
			draw_circle(Vector2.ZERO, 3.2, Color(0.75, 0.55, 1.0, 0.9))


func setup(w: LegionWorld, scenario_path: String) -> void:
	world = w
	path = scenario_path


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# эффекты и звуковые лимиты — по кадрам и в прогоне без записи (--preview совпадает с записью)
	FxClock.use_frames()
	_run()


func _process(_delta: float) -> void:
	frame += 1
	if world == null:
		return
	# старт карты и итог возвращают HUD — держим выбранный режим каждый кадр
	if _hud_mode == "off" and world.hud != null and world.hud.visible:
		world.hud.visible = false
	while _timeline_on and _timeline_i < _timeline.size() \
			and frame >= roundi(float(_timeline[_timeline_i].get("t", 0.0)) * FPS):
		var s: Dictionary = _timeline[_timeline_i]
		_timeline_i += 1
		if String(s.get("do", "")) == "end":
			_ended = true
		else:
			_do_step(s)   # shot — корутина: снимет кадр этого же кадра, не задерживая дорожку
	_update_camera()
	if _evidence_on and frame % 15 == 0:
		for c: Contract in world.contracts.contracts:
			for seg in c.seg_count():
				var bend := c.bend_frac(seg)
				if bend > _max_bend + 0.08:
					_max_bend = bend
					print("PROMO_BEND t=%.3f bend=%.3f" % [frame / 60.0, bend])
	if _cursor != null and _cursor_world != Vector2.INF:
		_cursor.position = get_viewport().get_canvas_transform() * _cursor_world


# ── Камера-режиссёр ─────────────────────────────────────────────────────────
## Шаг {"do": "camera", "zoom": 1.5, "at": [x, y] | "follow": "fight" | "foes", "time": 0.9,
## "cut": false}: крупность поверх вида поля и центр кадра; переход плавный (экспонента с
## постоянной time секунд, по кадрам — повторяется кадр в кадр), cut — сразу. follow — центр
## стычки (враги в CAM_CONTACT от бойцов) или всех врагов, пересчёт раз в CAM_RETARGET кадров.
## Ввод режиссёра от камеры не зависит: игра переводит мышь видом поля (screen_to_world), без
## камеры, — события идут туда же, где их ждёт игра; курсор рисуется над точкой на кадре.
## Кадр не выходит за поле: центр зажат так, чтобы край карты не попадал в кадр.
func _update_camera() -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null or world == null or world.map.is_empty():
		return
	if not _cam_on:
		return
	if _cam_follow != "" and frame % CAM_RETARGET == 0:
		var c := _fight_center(_cam_follow)
		if c != Vector2.INF:
			_cam_target_at = c
	var k := 1.0 if _cam_tau <= 0.0 else 1.0 - exp(-1.0 / (float(FPS) * _cam_tau))
	_cam_zoom = lerpf(_cam_zoom, _cam_target_zoom, k)
	_cam_at = _cam_at.lerp(_cam_target_at, k)
	var z := world.view_scale() * _cam_zoom
	var half := Vector2(640.0, 360.0) / z
	var ws := world.world_size
	var at := Vector2(clampf(_cam_at.x, half.x, maxf(half.x, ws.x - half.x)),
		clampf(_cam_at.y, half.y, maxf(half.y, ws.y - half.y)))
	cam.zoom = Vector2(z, z)
	cam.position = at


func _camera_step(s: Dictionary) -> void:
	var cam := get_viewport().get_camera_2d()
	if cam != null and not _cam_on:
		_cam_on = true
		world.hud_follows_camera = true   # подписи HUD у мировых точек — за камерой (REC-07)
		_cam_zoom = 1.0
		_cam_at = world.world_size * 0.5
		_cam_target_at = _cam_at
	_cam_target_zoom = clampf(float(s.get("zoom", 1.0)), 1.0, 2.5)
	_cam_tau = float(s.get("time", 0.9))
	_cam_follow = String(s.get("follow", ""))
	if s.has("at"):
		_cam_target_at = _pt(s["at"])
	elif _cam_follow != "":
		var c := _fight_center(_cam_follow)
		if c != Vector2.INF:
			_cam_target_at = c
	elif _cam_target_zoom <= 1.0:
		_cam_target_at = world.world_size * 0.5
	if bool(s.get("cut", false)):
		_cam_zoom = _cam_target_zoom
		_cam_at = _cam_target_at


## Центр стычки: враги ближе CAM_CONTACT к живому бойцу (mode "fight") или все враги ("foes").
func _fight_center(mode: String) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for f in world.foes:
		if not f.alive:
			continue
		var take := mode == "foes"
		if not take:
			for u in world.units:
				if u.alive and u.position.distance_squared_to(f.position) < CAM_CONTACT * CAM_CONTACT:
					take = true
					break
		if take:
			sum += f.position
			n += 1
	return sum / n if n > 0 else Vector2.INF


## Настоящие мышь и клавиатура владельца на время записи не доходят до игры.
func _input(event: InputEvent) -> void:
	if (event is InputEventMouse or event is InputEventKey) and event.device != DEVICE:
		get_viewport().set_input_as_handled()


func _run() -> void:
	await _frames(1)
	# Земля карты грузится в фоне (LegionWorld._begin_ground_loading): пока грузится, мир стоит,
	# а ввод боя отбрасывается. Длительность — настенная (поток), поэтому часы сценария
	# запускаются только после неё — иначе под нагрузкой первый штрих терялся и бой расходился
	# (запись «Прораба» 08.10: 4 договора вместо 5).
	while world.is_ground_loading():
		await _frames(1)
	await _frames(1)
	frame = 0
	scenario = _load(path)
	if scenario.is_empty():
		_quit(1)
		return
	var want_map := String(scenario.get("map", world.map_id))
	if want_map != world.map_id:
		push_warning("director: сценарий для карты '%s', запущена '%s' (--map)"
			% [want_map, world.map_id])
	_rng.seed = int(scenario.get("seed", 1)) * 7919 + 17
	_seed_view_rngs(int(scenario.get("seed", 1)))
	var setup_cheats: Dictionary = scenario.get("setup", {})
	for k in CHEAT_KEYS:
		if world.dev.has("director_" + k):
			setup_cheats[k] = world.dev["director_" + k]
	_cheat(setup_cheats)
	if bool(scenario.get("evidence", false)):
		_evidence_on = true
		world.charge_impact.connect(func(at: Vector2, perfect: bool) -> void:
			print("PROMO_IMPACT t=%.3f perfect=%s at=%s" % [frame / 60.0, perfect, at]))
		world.spring_released.connect(func(_c: Contract, _s: int, bend: float) -> void:
			print("PROMO_SPRING t=%.3f bend=%.3f" % [frame / 60.0, bend]))
		world.hero_cast.connect(func(slot: int, at: Vector2) -> void:
			print("PROMO_CAST t=%.3f slot=%d at=%s" % [frame / 60.0, slot, at]))
		world.segment_released.connect(func(c: Contract, seg: int, n: int) -> void:
			print("PROMO_RELEASE t=%.3f units=%d cause=%s" % [
				frame / 60.0, n, c.release_causes[seg]]))
	# дубль того же боя без HUD и курсора (кадры Steam без текста): --dev director_hud=off
	# --dev director_cursor=0 — сценарий тот же, бой кадр в кадр тот же (сид и шаги)
	_set_hud(String(world.dev.get("director_hud", scenario.get("hud", "full"))))
	if int(world.dev.get("director_cursor", 1 if bool(scenario.get("cursor", true)) else 0)) != 0:
		_make_cursor()
	if OS.has_feature("movie"):
		# запас на шине Master: в залпах микс игры упирается в 0 dBFS и срезается (проба 08.10:
		# 266 сэмплов на 0 dB, flat factor 13) — в файл пишем тише, громкость выравнивает
		# record.py (loudnorm). В игре шина не меняется — только в записи Movie Maker.
		var hr := float(scenario.get("headroom_db", 6.0))
		AudioServer.set_bus_volume_db(0, AudioServer.get_bus_volume_db(0) - hr)
	print("DIRECTOR_START map=%s seed=%s units=%d foes=%d" % [world.map_id,
		world.args.get("seed", "-"), world.army_alive(), world.active_foes()])
	# Две дорожки: «рука» (штрихи, фигуры, рогатка, клавиши — по очереди, каждое занимает кадры)
	# и «пульт» (камера, кадр, метка, читы, HUD, курсор — мгновенные, в свой кадр из _process,
	# не ждут руки). Прежде кадры и переезды камеры опаздывали за долгим штрихом (verifier 08.10:
	# «late camera by 34», «late shot by 26») и сдвигали монтажные точки.
	var acts: Array = []
	for step: Dictionary in scenario.get("steps", []):
		if String(step.get("do", "")) in TIMELINE_STEPS:
			_timeline.append(step)
		else:
			acts.append(step)
	_timeline.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	_timeline_on = true
	for step: Dictionary in acts:
		var due := roundi(float(step.get("t", 0.0)) * FPS)
		while frame < due:
			await _frames(1)
		if frame > due + 2:
			print("DIRECTOR late %s t=%.2f by %d frames" % [String(step.get("do", "?")),
				float(step.get("t", 0.0)), frame - due])
		await _do(step)
		if _ended:
			break
	while _timeline_i < _timeline.size() and not _ended:
		await _frames(1)
	print("DIRECTOR_END frame=%d units=%d foes=%d kills=%d lines=%d charges=%d pos=%s" % [frame,
		world.army_alive(), world.active_foes(), int(world.stats.get("kills", 0)),
		int(world.stats.get("lines", 0)), int(world.stats.get("charges", 0)), _pos_hash()])
	finished.emit()
	if bool(scenario.get("quit", true)):
		_quit(0)


## Вид-генераторы (только вид: слои scripts/legion/fx, ветвление молнии героя, глобальный randf
## для тряски Juicee и вариантов звука) — от сида сценария, чтобы дубли с HUD и без совпадали и
## по искрам. Генераторы симуляции (world.rng, предметы) не трогаются.
func _seed_view_rngs(s: int) -> void:
	seed(s * 7 + 3)
	for n in world.find_children("*", "", true, false):
		var sc: Script = n.get_script()
		if sc == null or not sc.resource_path.begins_with("res://scripts/legion/fx/"):
			continue
		var r: Variant = n.get("rng")
		if r is RandomNumberGenerator:
			(r as RandomNumberGenerator).seed = s * 131 + 7
	var hero := world.my_hero()
	if hero != null and hero.get("_vis_rng") is RandomNumberGenerator:
		(hero.get("_vis_rng") as RandomNumberGenerator).seed = s * 977 + 11


## Отпечаток мира для проверки детерминизма: позиции живых бойцов и врагов (до 0,1 px) и HP.
func _pos_hash() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	var buf := PackedFloat32Array()
	for u in world.units:
		if u.alive:
			buf.append_array([snappedf(u.position.x, 0.1), snappedf(u.position.y, 0.1)])
	for f in world.foes:
		if f.alive:
			buf.append_array([snappedf(f.position.x, 0.1), snappedf(f.position.y, 0.1),
				snappedf(f.hp, 0.1)])
	ctx.update(buf.to_byte_array())
	return ctx.finish().hex_encode().left(12)


func _load(p: String) -> Dictionary:
	if not FileAccess.file_exists(p):
		push_error("director: нет сценария %s" % p)
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not data is Dictionary:
		push_error("director: сценарий %s — не JSON-объект" % p)
		return {}
	return data as Dictionary


func _quit(code: int) -> void:
	_ended = true
	get_tree().quit(code)


# ── Шаги ────────────────────────────────────────────────────────────────────

func _do(s: Dictionary) -> void:
	var what := String(s.get("do", ""))
	var lines0 := int(world.stats.get("lines", 0))
	await _do_step(s)
	if what in ["draw", "ring", "poly", "eight"]:
		# штрих в камень или поперёк стены договором не становится — видно в логе при подборе
		var made := int(world.stats.get("lines", 0)) > lines0
		print("DIRECTOR %s t=%.2f %s" % [what, frame / float(FPS), "ok" if made else "НЕ ЛЁГ"])


func _do_step(s: Dictionary) -> void:
	var kind_key := int(s.get("kind", 0))
	match String(s.get("do", "")):
		"kind":
			await _key(KEYS[str(kind_key)])
		"draw":
			if kind_key > 0:
				await _key(KEYS[str(kind_key)])
			var toward: Variant = _pt(s["toward"]) if s.has("toward") else null
			await _draw(_hand(_pts(s["pts"]), float(s.get("hand", 0.0))), toward)
		"ring":
			if kind_key > 0:
				await _key(KEYS[str(kind_key)])
			await _ring(_pt(s["center"]), float(s.get("r", 80.0)), float(s.get("from", 0.0)),
				bool(s.get("squeeze", false)))
		"poly":
			if kind_key > 0:
				await _key(KEYS[str(kind_key)])
			await _draw(_hand(_pts(s["pts"]), float(s.get("hand", 0.0))), null)
		"eight":
			if kind_key > 0:
				await _key(KEYS[str(kind_key)])
			await _draw(_eight(_pt(s["center"]), float(s.get("r", 60.0))), null)
		"sling":
			await _drag(_pt(s["from"]), _pt(s["to"]), MOUSE_BUTTON_RIGHT, int(s.get("hold", 8)))
		"release_when":
			await _release_when(s)
		"aim":
			await _move(_pt(s["from"]))
			await _key_state(KEY_SPACE, true)
			await _glide(_pt(s["from"]), _pt(s["to"]), 0)
			await _key_state(KEY_SPACE, false)
		"key":
			var code: Key = KEYS[String(s.get("key", "Q")).to_upper()]
			if s.has("at"):
				await _glide(_screen_to_world_last(), _pt(s["at"]), 0)
			await _key_state(code, true)
			await _frames(int(s.get("hold", 2)))
			await _key_state(code, false)
		"tap":
			await _click(_pt(s["at"]), MOUSE_BUTTON_LEFT)
		"rtap":
			await _click(_pt(s["at"]), MOUSE_BUTTON_RIGHT)
		"move":
			await _glide(_screen_to_world_last(), _pt(s["to"]), 0, int(s.get("frames", 0)))
		"cheat":
			_cheat(s)
		"hud":
			_set_hud(String(s.get("mode", "full")))
		"mark":
			print("EDIT_MARK %s frame=%d t=%.2f" % [String(s.get("name", "")), frame, frame / float(FPS)])
		"camera":
			_camera_step(s)
		"shot":
			await _shot(String(s.get("name", "shot_%d" % frame)))
		"cursor":
			if _cursor != null:
				_cursor.visible = bool(s.get("show", true))
		"end":
			_ended = true
		_:
			push_warning("director: неизвестный шаг %s" % JSON.stringify(s))


## Ждём настоящего состояния боя, затем щёлкаем мышью. Симуляция и условия золота не меняются.
## Нужен для пересъёмки после изменения набора: не выдаём пустой/промахнувшийся клик за запуск.
func _release_when(s: Dictionary) -> void:
	var until := frame + roundi(float(s.get("timeout", 6.0)) * FPS)
	var mode := String(s.get("mode", "gold"))
	while frame < until:
		world.contracts.pack_live_lures()
		for c: Contract in world.contracts.contracts:
			if c.kind != StringName(String(s.get("kind_name", "laborer"))):
				continue
			for seg in c.seg_count():
				if not c.seg_alive(seg) or c.seg_manned(seg) == 0:
					continue
				var ready := c.bend_frac(seg) >= float(s.get("bend", 0.5)) if mode == "spring" \
					else world.contracts.seg_gold(c, seg)
				if not ready:
					continue
				var at := c.seg_center(seg)
				await _glide(_screen_to_world_last(), at, 0)
				if not c.seg_alive(seg):
					continue
				print("PROMO_TRIGGER t=%.3f mode=%s gold=%s bend=%.3f" % [frame / 60.0,
					mode, world.contracts.seg_gold(c, seg), c.bend_frac(seg)])
				await _button(at, MOUSE_BUTTON_RIGHT, true)
				await _frames(3)
				await _button(at, MOUSE_BUTTON_RIGHT, false)
				return
		await _frames(1)
	print("PROMO_MISSING mode=%s t=%.3f" % [mode, frame / 60.0])


## Кольцо: замкнутый круг (12+ точек, длина от 220 px — «Оцепление»); squeeze — рогатка изнутри
## участка к центру: кольцо сжимается.
func _ring(c: Vector2, r: float, from_deg: float, squeeze: bool) -> void:
	var pts := PackedVector2Array()
	var n := maxi(24, ceili(TAU * r / STEP_PX))
	var a0 := deg_to_rad(from_deg)
	for i in n + 1:
		var a := a0 + TAU * float(i) / n
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	await _draw(pts, null)
	if squeeze:
		await _frames(20)
		var edge := c + Vector2(cos(a0), sin(a0)) * (r - 4.0)
		await _drag(edge, c.lerp(edge, 0.15), MOUSE_BUTTON_RIGHT, 6)


## Восьмёрка: лемниската Бернулли, две петли по горизонтали.
func _eight(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(48, ceili(6.0 * r / STEP_PX))
	for i in n + 1:
		var t := TAU * float(i) / n + PI * 0.5
		var d := 1.0 + sin(t) * sin(t)
		pts.append(c + Vector2(r * 1.4 * cos(t) / d, r * 1.4 * sin(t) * cos(t) / d))
	return pts


## Живая рука: ломаная чуть гуляет поперёк хода (амплитуда hand px, плавно), концы на месте.
func _hand(pts: PackedVector2Array, amp: float) -> PackedVector2Array:
	if amp <= 0.0 or pts.size() < 2:
		return pts
	var dense := _dense(pts)
	var out := PackedVector2Array()
	var phase := _rng.randf() * TAU
	var freq := _rng.randf_range(0.035, 0.06)
	var s := 0.0
	for i in dense.size():
		if i > 0:
			s += dense[i].distance_to(dense[i - 1])
		var a := dense[maxi(0, i - 1)]
		var b := dense[mini(dense.size() - 1, i + 1)]
		var across := (b - a).normalized().orthogonal()
		var fade := minf(1.0, minf(float(i), float(dense.size() - 1 - i)) / 4.0)
		out.append(dense[i] + across * amp * fade * sin(phase + s * freq))
	return out


func _dense(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size()):
		var n := maxi(1, ceili(pts[i - 1].distance_to(pts[i]) / STEP_PX))
		for k in range(1, n + 1):
			out.append(pts[i - 1].lerp(pts[i], float(k) / n))
	return out


# ── Читы расстановки ────────────────────────────────────────────────────────

func _cheat(c: Dictionary) -> void:
	if c.has("hints"):
		Settings.hints_override = "on" if bool(c["hints"]) else "off"
	if c.has("mana"):
		var m := float(c["mana"])
		world.contracts.mana_max = maxf(world.contracts.mana_max, m)
		world.contracts.mana = m
	if c.has("mana_regen"):
		world.contracts.mana_regen *= float(c["mana_regen"])
	if c.has("souls"):
		world.staff.add_souls(int(c["souls"]) - world.souls)
	for b: Dictionary in c.get("build", []):
		_build(String(b.get("plot", "")), StringName(String(b.get("kind", "laborer"))),
			int(b.get("level", 1)))
	if c.has("army"):
		# число (--dev director_army=N) — подрядчики толпой у Котла; список — толпы по видам
		var groups: Array = c["army"] if c["army"] is Array \
			else [{"kind": "laborer", "n": int(c["army"]), "at": [world.cauldron_pos.x + 110.0,
				world.cauldron_pos.y], "r": 80.0}]
		for a: Dictionary in groups:
			_army(StringName(String(a.get("kind", "laborer"))), int(a.get("n", 10)),
				_pt(a.get("at", [400, 360])), float(a.get("r", 50.0)), int(a.get("side", 0)))
	for f: Dictionary in c.get("foes", []):
		_foes(f)
	if c.has("boss"):
		# словарь {road, at}; иначе (--dev director_boss=1) — первая дорога карты, треть пути
		var roads: Array = world.map.get("roads", [])
		var bd: Dictionary = c["boss"] if c["boss"] is Dictionary \
			else {"road": String((roads[0] as Dictionary).get("id", "")) if not roads.is_empty() else "",
				"at": 0.35}
		_foes({"road": bd.get("road", ""), "from": bd.get("at", 0.3), "to": bd.get("at", 0.3),
			"types": ["boss"], "n": 1, "jitter": 0, "wave": bd.get("wave", 0)})
	if c.has("hold_waves") and world.wave_runner != null:
		world.wave_runner.held = bool(c["hold_waves"])
	if c.has("wave") and world.wave_runner != null:
		world.wave_runner.start_wave(int(c["wave"]) - 1)
	if bool(c.get("cd", false)):
		var hero := world.my_hero()
		if hero != null:
			for slot in 3:
				hero.reset_cd(slot)
	if c.has("souls") or c.has("build"):
		_settle_souls_plate()


## Чит душ — не доход боя: плашка HUD «+N» под «Души» после него гасится (режиссёр, не игра).
## Поля плашки приватные — правка только здесь, обычная игра её не видит.
func _settle_souls_plate() -> void:
	var plate: Object = world.hud.get("_plate") if world.hud != null else null
	if plate == null:
		return
	plate.set("_gain", 0)
	plate.set("_gain_t", 0.0)
	plate.set("_last_souls", world.souls)
	(plate as CanvasItem).queue_redraw()


## Постройка на площадке: души ровно на цену кладутся тихо (сеттер мира, без souls_changed) и тут
## же тратятся штатной стройкой — баланс душ не меняется, а плашка HUD не видит «прихода» (прежний
## чит на 100 000 душ рисовал под «Души» «+400406», verifier 08.10).
func _build(plot_id: String, kind: StringName, level: int) -> void:
	for plot in world.staff.plots:
		if String(plot.get("id", "")) != plot_id:
			continue
		var keep := world.souls
		world.souls = keep + LegionStaff.build_price(kind)
		var b := world.staff.build(plot, kind)
		for i in maxi(0, level - 1):
			if b == null:
				break
			var price := LegionStaff.upgrade_price(b)
			if price < 0:
				break
			world.souls = world.souls + price
			world.staff.upgrade(b)
		world.souls = keep
		return
	push_warning("director: площадки %s нет на карте" % plot_id)


## Толпа бойцов вида kind в круге r вокруг at — вразброс, не строем; камни обходятся.
## side — сторона «Схватки» (1 — соперник), в одиночке 0.
func _army(kind: StringName, n: int, at: Vector2, r: float, side := 0) -> void:
	if side >= world.sides.size():
		side = 0
	for i in n:
		var a := _rng.randf() * TAU
		var d := sqrt(_rng.randf()) * r
		world.spawn_unit(kind, world.terrain.nearest_open(at + Vector2(cos(a), sin(a)) * d), null, side)


## Враги на дороге от доли from до to её длины, вперемешку по types, с разбросом поперёк;
## каждый идёт дальше по своей дороге к Котлу, как враг волны.
func _foes(f: Dictionary) -> void:
	var road := String(f.get("road", ""))
	var full := world.road_path(road)
	if full.size() < 2:
		push_warning("director: дороги %s нет" % road)
		return
	var length := 0.0
	for i in range(1, full.size()):
		length += full[i - 1].distance_to(full[i])
	var types: Array = f.get("types", ["zombie"])
	var n := int(f.get("n", 10))
	var jitter := float(f.get("jitter", 12.0))
	var d0 := float(f.get("from", 0.2)) * length
	var d1 := float(f.get("to", 0.5)) * length
	# wave=N — враги как из волны N: сила по уровню сложности (LegionChallenge.toughen), элитные
	var origin := {"wave": int(f["wave"]), "road": road} if int(f.get("wave", 0)) > 0 else {}
	# width — толпа, а не цепочка (B-452): ряды поперёк дороги шириной width, шаг ряда
	# FOE_ROW px, первый ряд у доли to, дальше к воротам; иначе — по одному от from до to
	var width := float(f.get("width", 0.0))
	var per_row := maxi(1, roundi(width / FOE_ROW)) if width > 0.0 else 1
	for k in n:
		var d := lerpf(d0, d1, float(k) / maxf(1.0, float(n - 1))) + _rng.randf_range(-6.0, 6.0)
		var lateral := 0.0
		if width > 0.0:
			d = d1 - float(k / per_row) * FOE_ROW + _rng.randf_range(-5.0, 5.0)
			var slot := float(k % per_row) / maxf(1.0, float(per_row - 1)) - 0.5
			lateral = slot * width + _rng.randf_range(-4.0, 4.0)
		var rest := world.road_remainder(road, d)
		if rest.is_empty():
			continue
		var along := (rest[1] - rest[0]).normalized() if rest.size() > 1 else Vector2.RIGHT
		var off := Vector2(_rng.randf_range(-jitter, jitter), _rng.randf_range(-jitter, jitter))
		var at := rest[0] + along.orthogonal() * lateral + off
		if width > 0.0:
			at = world.terrain.nearest_open(at)
		world.spawn_foe_on_path(String(types[k % types.size()]), rest, at, false, origin)


# ── HUD и курсор ────────────────────────────────────────────────────────────

func _set_hud(mode: String) -> void:
	_hud_mode = mode
	var clean := mode != "full"
	if world.hud != null:
		world.hud.set_cinematic(clean)
		world.hud.visible = mode != "off"
		# вложенные CanvasLayer (слоты способностей AbilityBar) видимость HUD не наследуют
		for layer in world.hud.find_children("*", "CanvasLayer", true, false):
			(layer as CanvasLayer).visible = mode != "off"
		if clean:
			world.hud.drop_toasts()
	if world.obstacle_hint != null:
		world.obstacle_hint.visible = not clean
	if world.intuit != null:
		world.intuit.visible = not clean
	if clean:
		Settings.hints_override = "off"


## Кадр без потерь (PNG окна: при записи 1920×1080 — честные 1080p) в --dev director_out=папка.
func _shot(shot_name: String) -> void:
	var dir := String(world.dev.get("director_out", ""))
	if dir == "":
		print("DIRECTOR shot %s пропущен: нет --dev director_out" % shot_name)
		return
	DirAccess.make_dir_recursive_absolute(dir)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var p := dir.path_join(shot_name + ".png")
	var err := img.save_png(p)
	print("DIRECTOR_SHOT %s %dx%d frame=%d err=%d"
		% [p, img.get_width(), img.get_height(), frame, err])


func _make_cursor() -> void:
	_cursor_layer = CanvasLayer.new()
	_cursor_layer.layer = 120
	add_child(_cursor_layer)
	_cursor = DirectorCursor.new()
	_cursor.position = Vector2(-100, -100)
	_cursor_layer.add_child(_cursor)


## Курсор стоит над мировой точкой руки там, где её показывает камера (крупный план — тоже);
## события ввода при этом идут в координатах вида поля, как у игрока без камеры (REC-07).
func _sync_cursor(world_pos: Vector2, mask: int) -> void:
	_cursor_world = world_pos
	if _cursor == null:
		return
	_cursor.position = get_viewport().get_canvas_transform() * world_pos
	var down := mask != 0
	if down != _cursor.pressed:
		_cursor.pressed = down
		_cursor.queue_redraw()


# ── Ввод (как corr_play.gd: устройство DEVICE, мировые точки → экран) ─────────

func _screen(p: Vector2) -> Vector2:
	return get_viewport().get_final_transform() * world.world_to_screen(p)


func _screen_to_world_last() -> Vector2:
	if _last_screen == Vector2.ZERO:
		return Vector2(640, 360)
	return world.screen_to_world(get_viewport().get_final_transform().affine_inverse() * _last_screen)


func _pt(v: Variant) -> Vector2:
	var arr := v as Array
	return Vector2(float(arr[0]), float(arr[1]))


func _pts(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in (v as Array):
		out.append(_pt(p))
	return out


func _draw(pts: PackedVector2Array, toward: Variant) -> void:
	if pts.size() < 2:
		return
	await _glide(_screen_to_world_last(), pts[0], 0)
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for i in range(1, pts.size()):
		await _glide(pts[i - 1], pts[i], MOUSE_BUTTON_MASK_LEFT)
	var end := pts[pts.size() - 1]
	if toward != null:
		# стрелка черновика: Пробел держим, указатель к цели, Пробел отпускаем (как corr_play)
		await _key_state(KEY_SPACE, true)
		await _glide(end, toward as Vector2, MOUSE_BUTTON_MASK_LEFT)
		await _key_state(KEY_SPACE, false)
		end = toward as Vector2
	await _button(end, MOUSE_BUTTON_LEFT, false)


## Рогатка/протяжка кнопкой: нажать в a, оттянуть к b, подержать hold кадров (прицел виден),
## отпустить.
func _drag(a: Vector2, b: Vector2, button: MouseButton, hold: int) -> void:
	var mask := MOUSE_BUTTON_MASK_RIGHT if button == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT
	await _glide(_screen_to_world_last(), a, 0)
	await _button(a, button, true)
	await _glide(a, b, mask)
	await _frames(hold)
	await _button(b, button, false)


## Указатель от a к b шагами STEP_PX (или ровно за frames кадров) — рука видна на записи.
func _glide(a: Vector2, b: Vector2, mask: int, frames := 0) -> void:
	var step := STEP_PX if mask != 0 else MOVE_PX
	var n := frames if frames > 0 else maxi(1, ceili(a.distance_to(b) / step))
	for k in range(1, n + 1):
		await _move(a.lerp(b, float(k) / n), mask)


func _move(p: Vector2, mask: int = 0) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.relative = sp - _last_screen
	ev.button_mask = mask
	_last_screen = sp
	Input.parse_input_event(ev)
	_sync_cursor(p, mask)
	await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	var sp := _screen(p)
	ev.position = sp
	ev.global_position = sp
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	_last_screen = sp
	Input.parse_input_event(ev)
	_sync_cursor(p, ev.button_mask)
	await _frames(1)


func _click(p: Vector2, button: MouseButton) -> void:
	await _glide(_screen_to_world_last(), p, 0)
	await _button(p, button, true)
	await _frames(2)
	await _button(p, button, false)


func _key_state(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.device = DEVICE
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(1)


func _key(code: Key) -> void:
	await _key_state(code, true)
	await _frames(1)
	await _key_state(code, false)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
