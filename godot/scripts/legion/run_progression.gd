class_name RunProgression
extends RefCounted
## Миграция и услуги держатся отдельно от каталога карт Campaign.

const VERSION := 2
const SECTION := "progression"
static var _replacement: Dictionary = {}


static func migrate(cfg: ConfigFile, path: String) -> bool:
	var version := int(cfg.get_value(SECTION, "version", 0))
	if version >= VERSION:
		return version == VERSION
	var before := cfg.encode_to_text()
	for sec: String in ["meta", Campaign.ENDLESS_SECTION, Campaign.DAILY_SECTION,
			Campaign.REPLAY_SECTION]:
		var archived := {}
		var refund := 0
		for id: String in LegionMetaCfg.LEGACY_OFFICE_SHOP_ORDER:
			var data: Dictionary = LegionMetaCfg.LEGACY_OFFICE_SHOP[id]
			var kinds: Array[String] = [""]
			if bool(data.get("per_kind", false)):
				kinds = ["laborer", "guard", "clerk"]
			for kind in kinds:
				var key := "shop_%s" % id if kind == "" else "shop_%s_%s" % [id, kind]
				var level := maxi(0, int(cfg.get_value(sec, key, 0)))
				if level > 0:
					archived[key] = level
					var costs: Array = data["costs"]
					for i in mini(level, costs.size()):
						refund += int(costs[i])
		var old: Array = cfg.get_value(sec, "upgrades", [])
		var active: Array[String] = []
		for old_id in old:
			var mapped := String(AmendmentDb.LEGACY_MAP.get(String(old_id), ""))
			if mapped != "" and not active.has(mapped) and active.size() < AmendmentDb.MAX_ACTIVE:
				active.append(mapped)
		if not archived.is_empty() or not old.is_empty():
			cfg.set_value(sec, "legacy_purchases", archived)
			cfg.set_value(sec, "legacy_upgrades", old.duplicate())
			cfg.set_value(sec, "legacy_refund", refund)
			cfg.set_value(sec, "bounty", int(cfg.get_value(sec, "bounty", 0)) + refund)
		cfg.set_value(sec, "upgrades", active)
		cfg.set_value(sec, "draft_options", [])
		cfg.set_value(sec, "preparation", "")
		cfg.set_value(sec, "reroll_tokens", 0)
	var hero_legacy := {}
	for key: String in ["perks", "rank_q", "rank_w", "rank_e"]:
		if cfg.has_section_key("hero", key):
			hero_legacy[key] = cfg.get_value("hero", key)
	if not hero_legacy.is_empty():
		cfg.set_value("hero", "legacy_choices", hero_legacy)
	cfg.set_value(SECTION, "version", VERSION)
	# Не меняем конверт SafeConfig; .bak останется профилем до конверсии целиком.
	if SafeConfig.save_file(cfg, path) != OK:
		cfg.clear()
		cfg.parse(before)
		return false
	return true


static func clear_stage() -> void:
	_replacement.clear()


static func stage(slot: int) -> bool:
	var active := Campaign.upgrades()
	if slot < 0 or slot >= active.size():
		return false
	_replacement = {"scope": Campaign._scope, "slot": slot, "old": active[slot]}
	return true


static func replacement_slot() -> int:
	var slot := int(_replacement.get("slot", -1))
	var active := Campaign.upgrades()
	if _replacement.get("scope", "") != Campaign._scope or slot < 0 or slot >= active.size():
		return -1
	return slot if active[slot] == _replacement.get("old", &"") else -1


static func available(id: StringName) -> bool:
	var data := AmendmentDb.card(id)
	if data.is_empty():
		return false
	if Campaign.hero_level() < int(data.get("unlock_level", 1)):
		# Перенесённая карточка остаётся доступна, даже если старый XP ниже нового порога.
		if not Campaign.upgrades().has(id):
			return false
	var needs := StringName(data.get("needs", ""))
	return needs == &"" or Campaign.stat(needs) > 0.5


static func offer(rng: RandomNumberGenerator) -> Array[StringName]:
	var cfg := Campaign.raw_file()
	var sec := Campaign._meta_section()
	var saved: Array = cfg.get_value(sec, "draft_options", [])
	var out: Array[StringName] = []
	for id in saved:
		var sid := StringName(String(id))
		if available(sid) and not Campaign.upgrades().has(sid):
			out.append(sid)
	if not out.is_empty():
		return out
	var pool: Array[StringName] = []
	for id: String in AmendmentDb.ORDER:
		if available(StringName(id)) and not Campaign.upgrades().has(StringName(id)):
			pool.append(StringName(id))
	Campaign._shuffle(pool, rng)
	out = pool.slice(0, mini(3, pool.size()))
	Campaign.begin_update()
	cfg.set_value(sec, "draft_options", out.map(func(id: StringName) -> String: return String(id)))
	Campaign.save_raw()
	Campaign.end_update(true)
	return out


static func reroll(rng: RandomNumberGenerator) -> Array[StringName]:
	if Campaign.pending_reward() == "" or Campaign.reward_claimed():
		return []
	var cfg := Campaign.raw_file()
	var sec := Campaign._meta_section()
	var tokens := int(cfg.get_value(sec, "reroll_tokens", 0))
	if tokens <= 0 and Campaign.bounty() < AmendmentDb.REROLL_COST:
		return []
	Campaign.begin_update()
	if tokens > 0:
		cfg.set_value(sec, "reroll_tokens", tokens - 1)
	else:
		Campaign.add_bounty(-AmendmentDb.REROLL_COST)
	# Генерация предложения входит в ту же транзакцию со списанием.
	var previous: Array = cfg.get_value(sec, "draft_options", [])
	cfg.set_value(sec, "draft_options", [])
	Campaign.save_raw()
	var next := offer(rng)
	var has_new := false
	for candidate in next:
		if not previous.has(String(candidate)):
			has_new = true
	if not has_new:
		var fresh: Array[StringName] = []
		for candidate: String in AmendmentDb.ORDER:
			if available(StringName(candidate)) and not previous.has(candidate) \
					and not Campaign.upgrades().has(StringName(candidate)):
				fresh.append(StringName(candidate))
		if not fresh.is_empty() and not next.is_empty():
			next[0] = fresh[rng.randi_range(0, fresh.size() - 1)]
			cfg.set_value(sec, "draft_options", next)
			Campaign.save_raw()
	if not Campaign.end_update(true):
		return []
	clear_stage()
	return next


static func can_reroll() -> bool:
	return Campaign.bounty() >= AmendmentDb.REROLL_COST or reroll_tokens() > 0


static func reroll_tokens() -> int:
	return int(Campaign.raw_file().get_value(Campaign._meta_section(), "reroll_tokens", 0))


static func buy_service(id: String) -> bool:
	var cfg := Campaign.raw_file()
	var sec := Campaign._meta_section()
	var cost := AmendmentDb.REROLL_COST if id == "reroll" else \
		int(AmendmentDb.PREPARATIONS.get(id, {}).get("cost", -1))
	if cost < 0 or Campaign.bounty() < cost:
		return false
	if id != "reroll" and preparation() != "":
		return false
	if id == "reroll" and reroll_tokens() >= 2:
		return false
	Campaign.begin_update()
	Campaign.add_bounty(-cost)
	if id == "reroll":
		cfg.set_value(sec, "reroll_tokens", reroll_tokens() + 1)
	else:
		cfg.set_value(sec, "preparation", id)
	Campaign.save_raw()
	return Campaign.end_update(true)


static func preparation() -> String:
	return String(Campaign.raw_file().get_value(Campaign._meta_section(), "preparation", ""))


static func preparation_mods() -> Dictionary:
	return AmendmentDb.PREPARATIONS.get(preparation(), {}).get("mods", {}).duplicate()


## Подготовка для НАЧИНАЮЩЕГОСЯ боя: копия уходит в мир только вместе с успешным списанием
## (J3). Отказ записи иначе выдавал бы услугу бесплатно и оставлял её в сохранении — следующий
## старт применил бы тот же бонус второй раз. Мир копирует эти моды ДО start_map (мана, души),
## поэтому вызов идёт до него, а не после. Пустой словарь — подготовки нет либо списать не вышло.
static func consume_preparation_for_battle() -> Dictionary:
	var prep := preparation_mods()
	return prep if consume_preparation() else {}


## Мир копирует preparation_mods в свой бой ДО старта, а потребляет после успешного старта.
## Повторное получение предмета пересчитывает ману по копии мира, а не пустой Конторе.
static func consume_preparation() -> bool:
	if preparation() == "":
		return true
	Campaign.begin_update()
	Campaign.raw_file().set_value(Campaign._meta_section(), "preparation", "")
	Campaign.save_raw()
	return Campaign.end_update(true)


static func reset_run(sec: String) -> void:
	var cfg := Campaign.raw_file()
	for key: String in ["draft_options", "legacy_upgrades"]:
		cfg.set_value(sec, key, [])
	cfg.set_value(sec, "preparation", "")
	cfg.set_value(sec, "reroll_tokens", 0)
	cfg.set_value(sec, "reward_claimed", false)
	clear_stage()
