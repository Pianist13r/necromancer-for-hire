class_name SnapWorld
extends RefCounted
##
## К1 снимка (NetSnap): скаляры мира, стороны (PvpSide), итог матча (PvpMatch), RNG мира — и
## подготовка мира к приёму снимка.
##
## Интерфейс куска (одинаков у всех snap_*.gd; зовёт только NetSnap, в порядке NetSnap.CHUNKS):
##   const READY := true|false                    — false: заглушка, тест печатает «не готов»
##   static func save(w, reg) -> Dictionary       — только простые Variant; ссылки — reg.ref_of
##                                                   или reg.enc; общие словари — reg.share
##   static func build(w, data, reg) -> void      — создать/перезаписать свои объекты и данные;
##                                                   ссылки не разрешать; RNG мира не тратить
##   static func link(w, data, reg) -> void       — разрешить ссылки (reg.resolve / reg.dec)
##   static func finish(w, data, reg) -> void     — восстановить то, что build/link сдвинули
##                                                   побочно (RNG, души, счётчики)
## data — свой кусок снимка ({} если его нет). Кусок пишет только свои поля и свои объекты.
##
## Подготовка: мир, совместимый со снимком (та же карта, сид, ключи --dev, число сторон и
## ботов, бой идёт), принимает снимок на месте — так клиент поправляется без перестройки поля.
## Иначе — start_map той же карты с тем же сидом и конфигом, затем перезапись: структура боя
## (рельеф, стороны, поля, штабы, участки, склепы, боты) создаётся тем же кодом, что у
## сервера, а куски перезаписывают изменчивое.
##

const READY := true
## Фаза снимка «матч „Схватки“ решён» (итог — в PvpMatch.result; см. saved_phase).
const PHASE_DECIDED := -1

## Ключи --dev, которые меняют только вид (у сервера noview=1, у клиента — нет): в сверку
## совместимости не входят и при подготовке у мира остаются свои.
## intuit и save — из LegionWorld.NET_DEV_KEEP («только вид»: подсказки и путь сохранения).
const VIEW_DEV_KEYS: Array[String] = ["noview", "gfx", "fx", "corr", "intuit", "save"]
## Ключи args, влияющие на бой: кто из сторон бот.
const SIM_ARGS: Array[String] = ["pvp_bots", "bot"]

## Поля LegionWorld (тест полноты): в этом куске, в других кусках, пропущенные с причиной.
const WORLD_SAVED: Array[String] = [
	"phase", "now", "rng", "stats", "combo", "tab_perfect_releases", "net_tick", "kassa",
	"_pvp_item_stage", "_pvp_carrier_serial", "_pvp_flip", "_assign_t", "_pace",
	"_dev_hero_cast_done", "_combo_hit_t", "_combo_soul_frac", "_hitstop_left", "_hitstop_gap",
	"sides", "pvp_match",
]
const WORLD_CONFIG: Array[String] = [
	# конфиг боя (config(): сверка и start_map тем же кодом, что у сервера)
	"mods", "difficulty", "in_campaign", "map", "map_id", "world_size", "args", "dev",
	"dev_invuln", "_base_seed",
	# структура, которую строит start_map из конфига
	"pvp", "terrain", "entities",
	"grid",   # индексы сетки: NetSnap.load зовёт grid.rebuild() последним
]
const WORLD_OTHER_CHUNKS: Array[String] = [
	"contracts", "figures",                              # К2 (contracts = поле стороны 0)
	"units", "foes", "_corpses", "projectiles", "_damage_hp",   # К3
	"crypts", "buildings", "staff", "hero",              # К4 (staff, hero — стороны 0)
	"wave_runner",                                       # К5
	"items",                                             # К6 (артефакты стороны 0)
]
const WORLD_SKIP: Array[String] = [
	"harmony",   # вид: кэш цветов итоговой подложки, пересоздаётся через _build_ground
	# сторона 0 (_s0 = sides[0]) и прокси к ней (К1)
	"_s0", "cauldron_hp", "cauldron_max", "cauldron_pos", "cauldron_view_pos", "souls", "rally_cd",
	"ability_mana_reserve",
	# решает хозяин мира, а не бой: встроен ли, есть ли касса, переносить ли артефакты (в
	# «Схватке» кассы и переноса нет); сеть — кто этот клиент и куда шлёт команды (сам факт
	# сетевого матча — в config(), "net"; prepare сохраняет сторону и net_out клиента)
	"embedded", "kassa_allowed", "carry_items", "net_mode", "local_side", "net_out",
	# пауза экрана и «думает над ходом» (переписка) — этого клиента
	"paused", "hold",
	# только одиночный бой: обучение и бот одиночки (в «Схватке» null; save предупреждает)
	"tutorial", "bot", "_lessons_force", "_pending_ground_lessons",
	"_pending_ground_lessons_force", "_pending_ground_lessons_generation",
	# буферы и флаги одного вызова: пусты/сброшены на границе шага
	"_pvp_hits", "_pvp_carrier_hits", "_resolving_carrier", "net_applying", "_net_starting",
	# пересчёт в шаге до чтения (_scan_home_threats — до хода бойцов)
	"_home_threat",
	# вид, звук, интерфейс, ввод мыши
	"view_xf", "no_view", "hud", "pvp_menu", "plot_menu", "audio", "injected_audio",
	"rally_aiming", "ability_aim", "obstacle_hint", "intuit", "_ground", "_ground_loading",
	"_ground_loading_layer", "_depth_decor", "_depth_generation", "_plot_view", "_fx",
	"_shadows_node", "_gfx_fx", "_cauldron", "_necro", "_breach_marks", "_impacts",
	"_impact_r", "_tears", "_rallies", "_mouse_pos", "_mouse_seen",
	# замеры, кадры, трасса (--trace печатает, бой не читает)
	"_trace_t", "_frames", "_bench_s", "_bench_el", "_bench_n", "_bench_tick_us",
	"_bench_ticks", "_bench_wall0", "_shot_path", "_shot_frame",
]
const SIDE_SAVED: Array[String] = [
	"cauldron_pos", "cauldron_hp", "cauldron_max", "cauldron_view_pos", "souls", "rally_cd",
	"ability_mana_reserve", "surrendered", "leaked_waves", "cauldron_dmg",
]
const SIDE_SKIP: Array[String] = [
	"index", "items", "contracts", "staff", "hero", "bot",   # структура (start_map); свои куски
	"view_xf", "cauldron_sprite", "necro",                    # вид
]


## Сверка полей классов (тест): [скрипт, учтённые имена].
static func coverage() -> Array:
	return [
		[LegionWorld, WORLD_SAVED + WORLD_CONFIG + WORLD_OTHER_CHUNKS + WORLD_SKIP],
		[PvpSide, SIDE_SAVED + SIDE_SKIP],
		[PvpMatch, ["limit", "result"]],
		[LegionKassa, ["souls", "premium", "deposits"]],
	]


static func save(w: LegionWorld, _reg: NetSnap.Reg) -> Dictionary:
	if not w._pvp_hits.is_empty() or not w._pvp_carrier_hits.is_empty():
		push_warning("SnapWorld: снимок не на границе шага — буферы ударов шага не пусты")
	if w.tutorial != null or w.bot != null:
		push_warning("SnapWorld: обучение и бот одиночки в снимок не входят")
	var sides := []
	for s in w.sides:
		sides.append({
			"cauldron_pos": s.cauldron_pos, "cauldron_view_pos": s.cauldron_view_pos,
			"cauldron_hp": s.cauldron_hp, "cauldron_max": s.cauldron_max,
			"souls": s.souls, "rally_cd": s.rally_cd,
			"ability_mana_reserve": s.ability_mana_reserve, "surrendered": s.surrendered,
			"leaked_waves": s.leaked_waves.duplicate(true),
			"cauldron_dmg": s.cauldron_dmg.duplicate(true),
		})
	var match_d := {}
	if w.pvp_match != null:
		match_d = {"limit": w.pvp_match.limit, "result": w.pvp_match.result.duplicate(true)}
	return {
		"cfg": config(w),
		"now": w.now, "phase": saved_phase(w),
		"pvp_flip": w._pvp_flip, "item_stage": w._pvp_item_stage,
		"carrier_serial": w._pvp_carrier_serial, "assign_t": w._assign_t,
		"combo": w.combo, "combo_hit_t": w._combo_hit_t, "combo_soul_frac": w._combo_soul_frac,
		"tab_perfect": w.tab_perfect_releases,
		"hitstop_left": w._hitstop_left, "hitstop_gap": w._hitstop_gap,
		"stats": w.stats.duplicate(true), "pace": w._pace.duplicate(true),
		"rng": NetSnap.save_rng(w.rng), "net_tick": w.net_tick,
		"dev_cast_done": w._dev_hero_cast_done,
		"kassa": [w.kassa.souls, w.kassa.premium, w.kassa.deposits],
		"sides": sides, "match": match_d,
	}


static func build(w: LegionWorld, data: Dictionary, reg: NetSnap.Reg) -> void:
	var cfg: Dictionary = data.get("cfg", {})
	if cfg.is_empty():
		reg.errors.append("world: в снимке нет cfg")
		return
	if mismatch(w, cfg) != "":
		prepare(w, cfg)
	var why := mismatch(w, cfg)
	if why != "":
		reg.errors.append("world: мир не совпал со снимком после start_map — " + why)
	_apply(w, data)


static func link(_w: LegionWorld, _data: Dictionary, _reg: NetSnap.Reg) -> void:
	pass   # у К1 ссылок нет


## Повтор build-присвоений последним: build других кусков мог тронуть души, RNG, счётчики.
## Итог матча — здесь же: снимок уже решённого матча закрывает бой тем же _end, что и шаг.
static func finish(w: LegionWorld, data: Dictionary, _reg: NetSnap.Reg) -> void:
	if data.get("cfg", {}).is_empty():
		return
	_apply(w, data)
	var phase := int(data.get("phase", LegionWorld.Phase.BATTLE))
	if phase == LegionWorld.Phase.BATTLE or w.phase != LegionWorld.Phase.BATTLE:
		return
	if phase == PHASE_DECIDED and w.pvp_match != null:
		# итог «Схватки» — от лица ЭТОГО мира, как в _check_pvp_end (ничья — winner -1)
		w._end(int(w.pvp_match.result.get("winner", -1)) == w.local_side)
	else:
		w._end(phase == LegionWorld.Phase.VICTORY)


## Фаза в снимке. VICTORY/DEFEAT «Схватки» — от лица local_side снимающего (судья — сторона 0),
## у клиента другой стороны они перевернулись бы: решённый матч хранится как PHASE_DECIDED, а
## победитель — в итоге матча (PvpMatch.result), и каждый мир решает свою фазу сам.
static func saved_phase(w: LegionWorld) -> int:
	var decided := w.pvp_match != null and not w.pvp_match.result.is_empty()
	if decided and w.phase != LegionWorld.Phase.BATTLE:
		return PHASE_DECIDED
	return int(w.phase)


## Конфиг боя: всё, что start_map превращает в структуру боя. Должен совпасть у мира и снимка.
static func config(w: LegionWorld) -> Dictionary:
	# сетевой матч ботов не ставит (_setup_pvp_bots): ключи ботов в args на бой не влияют
	var args := {}
	for k in SIM_ARGS:
		if w.args.has(k) and not w.net_mode:
			args[k] = w.args[k]
	var bots := []
	for s in w.sides:
		bots.append(s.bot != null)
	return {
		"map_id": w.map_id, "seed": w._base_seed, "dev": sim_dev(w.dev), "args": args,
		"invuln": w.dev_invuln, "mods": w.mods.duplicate(true), "in_campaign": w.in_campaign,
		"map_hash": hash(w.map), "difficulty": String(w.difficulty), "world_size": w.world_size,
		"sides": w.sides.size(), "bots": bots, "net": w.net_mode,
	}


## Ключи --dev без чисто видовых.
static func sim_dev(dev: Dictionary) -> Dictionary:
	var out := dev.duplicate(true)
	for k in VIEW_DEV_KEYS:
		out.erase(k)
	return out


## Чем мир не совпадает со снимком ("" — совместим и бой идёт).
static func mismatch(w: LegionWorld, cfg: Dictionary) -> String:
	if w.phase != LegionWorld.Phase.BATTLE:
		return "бой не идёт (phase %d)" % w.phase
	var mine := config(w)
	for k: String in cfg:
		if var_to_bytes(mine.get(k)) != var_to_bytes(cfg[k]):
			return "%s: %s ≠ %s" % [k, str(mine.get(k)), str(cfg[k])]
	return ""


## Свежий бой той же карты с конфигом снимка; видовые ключи --dev мира остаются его.
##
## Снимок сетевого матча (судья — start_net_match) готовится тем же start_net_match: обычный
## start_map вне _net_starting выводит мир из сети (net_mode, local_side, сид из --seed, боты).
## Клиент сохраняет своё: сторону, net_out; мир не из сети — сторона 0.
static func prepare(w: LegionWorld, cfg: Dictionary) -> void:
	if bool(cfg.get("net", false)):
		# net_out (куда клиент шлёт ходы) start_net_match не трогает — он остаётся клиентским
		w.start_net_match(String(cfg["map_id"]), int(cfg["seed"]),
			w.local_side if w.net_mode else 0)
		return
	# снимок не сетевой: мир выходит из сети сам, ДО start_map — иначе тот, видя net_mode,
	# взял бы сид из --seed вместо сида снимка
	w.net_mode = false
	w.local_side = 0
	w._base_seed = int(cfg["seed"])
	var dev: Dictionary = (cfg["dev"] as Dictionary).duplicate(true)
	for k in VIEW_DEV_KEYS:
		if w.dev.has(k):
			dev[k] = w.dev[k]
	w.dev = dev
	w.dev_invuln = bool(cfg["invuln"])
	for k in SIM_ARGS:
		w.args.erase(k)
	var args: Dictionary = cfg["args"]
	for k: String in args:
		w.args[k] = args[k]
	w.mods = (cfg["mods"] as Dictionary).duplicate(true)
	w.in_campaign = bool(cfg["in_campaign"])
	w.start_map(String(cfg["map_id"]))


static func _apply(w: LegionWorld, data: Dictionary) -> void:
	w.now = float(data["now"])
	w._pvp_flip = bool(data["pvp_flip"])
	w._pvp_item_stage = int(data["item_stage"])
	w._pvp_carrier_serial = int(data["carrier_serial"])
	w._assign_t = float(data["assign_t"])
	w.combo = int(data["combo"])
	w._combo_hit_t = float(data["combo_hit_t"])
	w._combo_soul_frac = float(data["combo_soul_frac"])
	w.tab_perfect_releases = int(data["tab_perfect"])
	w._hitstop_left = float(data["hitstop_left"])
	w._hitstop_gap = float(data["hitstop_gap"])
	w.stats = (data["stats"] as Dictionary).duplicate(true)
	w._pace = (data["pace"] as Dictionary).duplicate(true)
	NetSnap.load_rng(w.rng, data["rng"])
	w.net_tick = int(data["net_tick"])
	w._dev_hero_cast_done = bool(data["dev_cast_done"])
	var kassa: Array = data["kassa"]
	w.kassa.souls = int(kassa[0])
	w.kassa.premium = float(kassa[1])
	w.kassa.deposits = int(kassa[2])
	var sides: Array = data["sides"]
	for i in mini(sides.size(), w.sides.size()):
		var s := w.sides[i]
		var d: Dictionary = sides[i]
		s.cauldron_pos = d["cauldron_pos"]
		s.cauldron_view_pos = d["cauldron_view_pos"]
		s.cauldron_hp = float(d["cauldron_hp"])
		s.cauldron_max = float(d["cauldron_max"])
		s.souls = int(d["souls"])
		s.rally_cd = float(d["rally_cd"])
		s.ability_mana_reserve = float(d["ability_mana_reserve"])
		s.surrendered = bool(d["surrendered"])
		s.leaked_waves = (d["leaked_waves"] as Dictionary).duplicate(true)
		s.cauldron_dmg = (d["cauldron_dmg"] as Dictionary).duplicate(true)
	var match_d: Dictionary = data["match"]
	if w.pvp_match != null and not match_d.is_empty():
		w.pvp_match.limit = float(match_d["limit"])
		w.pvp_match.result = (match_d["result"] as Dictionary).duplicate(true)
