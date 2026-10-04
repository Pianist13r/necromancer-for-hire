extends SceneTree
# gdlint: disable=class-definitions-order
## Изолированная серия: профиль задаёт camp_stat, сохранение кампании не меняется.

class CampaignCandidateWorld extends LegionWorld:
	var profile: Dictionary = {}
	var candidate_audit: Dictionary = {}
	var candidate_side := "candidate"
	var damage_seconds := 0
	var _damage_bucket := -1
	# ── Экономика (линия economy, 27.09): мана и души за бой в итоговой строке ──────────
	# Почему здесь, а не в мире: это замер серии, игре он не нужен; одинаковый файл кладётся
	# в worktree «до» и «после», чтобы мерить одно и то же.
	var eco_frames := 0
	var eco_mana_min := INF
	var eco_mana_cap_frames := 0
	var eco_mana_half_frames := 0
	var eco_mana_zero_n := 0
	var _eco_mana_low := false
	var eco_souls_spent := 0
	var eco_souls_max := 0
	var eco_all_maxed_t := -1.0
	var eco_souls_at_maxed := -1
	var _eco_souls_prev := -1

	func _track_damage(before: Dictionary, dt: float) -> void:
		super._track_damage(before, dt)
		if float(stats["no_dmg_s"]) == 0.0 and _damage_bucket != int(now):
			_damage_bucket = int(now)
			damage_seconds += 1

	func print_trace() -> void:
		# Счётчик урона по игровым секундам исключает потерю ударов между снимками.
		print(JSON.stringify({"t": now, "mana": contracts.mana, "foes": active_foes(),
			"kills": stats["kills"], "hp": cauldron_hp, "wave": wave_runner.wave_no(),
			"lost": stats["lost"], "first_contact_t": stats.get("first_contact_t", -1.0),
			"no_dmg_s": stats.get("no_dmg_s", 0.0),
			"damage_seconds": damage_seconds,
			"line_restores": stats.get("line_restores", 0)}))

	func camp_stat(key: StringName) -> float:
		return float(profile[key]) if profile.has(key) else super.camp_stat(key)

	func _bonus(key: StringName) -> float:
		return camp_stat(key)

	func _process(delta: float) -> void:
		# Пакет из восьми обычных шагов 1/60 с между обновлениями только визуальных узлов.
		# steps=1 — контроль идентичности с обычной сценой; логика и dt не меняются.
		for i in int(dev.get("steps", "8")):
			if now >= 1800.0 and phase == Phase.BATTLE:
				print("BALANCE TIMEOUT: ", map_id, " seed=", _base_seed)
				get_tree().quit(2)
				return
			super._process(delta)
			if phase == Phase.BATTLE:
				_sample_economy()
			if phase != Phase.BATTLE:
				break

	func on_souls_changed(v: int) -> void:
		if _eco_souls_prev >= 0 and v < _eco_souls_prev:
			eco_souls_spent += _eco_souls_prev - v
		_eco_souls_prev = v
		eco_souls_max = maxi(eco_souls_max, v)

	func _sample_economy() -> void:
		eco_frames += 1
		var m := contracts.mana
		eco_mana_min = minf(eco_mana_min, m)
		if m >= contracts.mana_max - 0.5:
			eco_mana_cap_frames += 1
		if m < contracts.mana_max * 0.5:
			eco_mana_half_frames += 1
		# «упёрся в ноль» — провал ниже 5 после подъёма выше 15 (гистерезис: одно событие,
		# а не каждый кадр у дна)
		if not _eco_mana_low and m < 5.0:
			_eco_mana_low = true
			eco_mana_zero_n += 1
		elif _eco_mana_low and m > 15.0:
			_eco_mana_low = false
		if eco_all_maxed_t < 0.0 and not staff.plots.is_empty():
			var maxed := true
			for p: Dictionary in staff.plots:
				var b: LegionBuilding = p["building"]
				if b == null or b.level < LegionCfg.BUILDING_MAX_LEVEL:
					maxed = false
					break
			if maxed:
				eco_all_maxed_t = now
				eco_souls_at_maxed = souls

	func final_stats(victory: bool) -> Dictionary:
		var out := super.final_stats(victory)
		out.merge(candidate_audit, true)
		out["actual_map"] = String(map.get("id", ""))
		out["side"] = candidate_side
		var invested := 0
		for p: Dictionary in staff.plots:
			var b: LegionBuilding = p["building"]
			if b != null:
				invested += b.invested
		var n := maxf(1.0, float(eco_frames))
		out["eco"] = {
			"souls_end": souls, "souls_spent": eco_souls_spent, "souls_max": eco_souls_max,
			"souls_buildings": invested, "all_maxed_t": snappedf(eco_all_maxed_t, 0.1),
			"souls_at_maxed": eco_souls_at_maxed,
			"souls_rush": int(stats.get("rush_souls", 0)), "rush_units": int(stats.get("rush_units", 0)),
			"mana_min": snappedf(eco_mana_min, 0.1), "mana_zero_n": eco_mana_zero_n,
			"mana_cap_share": snappedf(eco_mana_cap_frames / n, 0.001),
			"mana_below_half_share": snappedf(eco_mana_half_frames / n, 0.001),
		}
		return out

	func _add_foe(type: String, path: PackedVector2Array, opts: Dictionary) -> Foe:
		var f := super._add_foe(type, path, opts)
		if type == "ghost" and dev.has("ghost_speed"):
			f.speed = float(dev["ghost_speed"])
		if type == "boss" and dev.has("boss_hp"):
			f.hp = float(dev["boss_hp"])
			f.max_hp = f.hp
			f.def = f.def.duplicate()
			f.def["ram_cd"] = float(dev.get("ram_cd", f.def["ram_cd"]))
			f.def["dmg"] = float(dev.get("boss_dmg", f.def["dmg"]))
			f.def["ram_dmg"] = float(dev.get("ram_dmg", f.def["ram_dmg"]))
		return f


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := LegionWorld.parse_args()
	var dev: Dictionary = args["dev"]
	var candidate_dir := _arg("--candidate-dir")
	var side := _arg("--side")
	if side not in ["canonical", "candidate"]:
		push_error("--side must be canonical or candidate")
		quit(2)
		return
	var profile_name := String(dev.get("profile", "base"))
	if profile_name not in ["base", "novice", "mid"]:
		push_error("Unsupported strict-series profile: " + profile_name)
		quit(2)
		return
	var map_id := String(args.get("map", "wasteland"))
	var entry: Dictionary = {}
	var candidate: Dictionary = {}
	if side == "candidate":
		entry = _manifest_entry(candidate_dir, map_id)
		candidate = _load_candidate(candidate_dir, map_id, entry)
		if candidate.is_empty():
			push_error("Candidate strict-series validation failed for " + map_id)
			quit(2)
			return
	var w := CampaignCandidateWorld.new()
	w.candidate_side = side
	w.embedded = true
	w.souls_changed.connect(w.on_souls_changed)
	# embedded = true обходит переключение мира на user://legion_standalone_test.cfg
	# (legion_world._ready), и подсказки карт (hint_unit_guard/clerk) серии писались в настоящее
	# сохранение владельца (25.09 12:41, серия Astra на Стиксе). Свой временный путь — до старта.
	Campaign.set_save_path("user://legion_balance_test.cfg")
	Campaign.reset()
	if dev.get("profile", "base") == "novice":
		# новичок первой карты: виды бойцов закрыты, способности открыты все три (Campaign
		# открывает Ку, Дубль-вэ и Е сразу — обучение первой миссии их учит, решение 26.09)
		w.profile = {&"kind_unlocked_guard": 0.0, &"kind_unlocked_clerk": 0.0}
	# 170 премии: души I, штат вахтёров I, возрождение вахтёров I, дальность I.
	# Три очка героя: откат, цепь, быстрый найм; достижимо к четвёртой карте.
	if dev.get("profile", "base") == "mid":
		w.profile = {&"start_souls": 30.0, &"cap_mult_guard": 1.2,
			&"respawn_mult_guard": 0.7, &"respawn_mult_laborer": 0.85,
			&"respawn_mult_clerk": 0.85, &"recruit_r_guard": 40.0,
			&"perk_short_cd": 1.0, &"perk_chain_reaction": 1.0,
			&"perk_fast_hire": 1.0}
	if dev.get("no_q", "0") == "1":
		w.profile[&"ability_unlocked_q"] = 0.0
	# --dev stat_<ключ>=число — поверх профиля любой ключ camp_stat (например
	# stat_mana_regen_bonus=-5): «что было бы» без правки игры (линия economy, 27.09)
	for key: String in dev:
		if key.begins_with("stat_"):
			w.profile[StringName(key.trim_prefix("stat_"))] = float(dev[key])
	w.candidate_audit = {
		"candidate_status": String(entry.get("status", "")) if side == "candidate" else "canonical",
		"candidate_digest": String(entry.get("digest", "")) if side == "candidate" else "",
		"candidate_profile": profile_name,
		"candidate_seed": int(args.get("seed", 1)),
		"candidate_manifest_seed": int(entry.get("seed", -1)) if side == "candidate" else -1,
		"candidate_manifest_k": int(entry.get("k", -1)) if side == "candidate" else -1,
		"candidate_manifest_file": candidate_dir.path_join("manifest.json") \
			if side == "candidate" else "",
	}
	root.add_child(w)
	if side == "candidate":
		w.start_map(map_id, candidate)
	else:
		w.start_map(map_id)
	if w.map.is_empty() or String(w.map.get("id", "")) != map_id:
		push_error("Candidate did not start with requested map id: " + map_id)
		quit(3)
		return
	if dev.has("cauldron_respawn"):
		w.staff.cauldron.respawn_t = float(dev["cauldron_respawn"]) \
			* w.camp_stat(&"respawn_mult_laborer")


func _arg(key: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""


func _manifest_entry(candidate_dir: String, id: String) -> Dictionary:
	if candidate_dir.is_empty() or not candidate_dir.is_absolute_path():
		return {}
	var path := candidate_dir.path_join("manifest.json")
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not value is Array:
		return {}
	var found: Dictionary = {}
	for item: Variant in value:
		if item is Dictionary and String(item.get("id", "")) == id:
			if not found.is_empty():
				return {}
			if not item.get("blocking_errors", []).is_empty():
				return {}
			found = item
	return found


func _load_candidate(candidate_dir: String, id: String, entry: Dictionary) -> Dictionary:
	if entry.is_empty() or String(entry.get("status", "")) != \
			"candidate_requires_visual_and_gameplay_review":
		return {}
	var path := candidate_dir.path_join(id + ".json")
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not value is Dictionary or String(value.get("id", "")) != id \
			or ProcGen.digest(value) != String(entry.get("digest", "")):
		return {}
	return value
