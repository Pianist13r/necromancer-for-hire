class_name RunProgression
extends RefCounted
## Миграция и услуги держатся отдельно от каталога карт Campaign.
##
## «Переподписать» (другое предложение) живёт ТОЛЬКО на экране выбора поправок и всегда стоит
## премию напрямую (AmendmentDb.REROLL_COST) — банка жетонов больше нет, из «Конторы» переброска
## убрана (замысел 06.10.2026). «Контора» — короткая подготовка: до двух пакетов на объект
## (второй слот — с разряда 4, AmendmentDb.PREP_SLOT2_LEVEL).

const VERSION := 4
const SECTION := "progression"
## Только конверсия v1: цены оплаченных улучшений для возврата премии.
const LEGACY_OFFICE_SHOP := {
	"range": {"per_kind": true, "costs": [40, 70, 110]},
	"staff": {"per_kind": true, "costs": [50, 80, 120]},
	"respawn": {"per_kind": true, "costs": [40, 70, 110]},
	"mana": {"costs": [60, 90, 130]},
	"souls": {"costs": [40, 70, 110]},
	"settlement": {"costs": [60, 100]},
}
## Ключ одиночной подготовки (до второго слота) — читается как совместимость; новый ключ —
## массив "preparations". Старые сохранения с одним пакетом открываются без миграции.
const PREP_KEY := "preparation"
const PREPS_KEY := "preparations"
## Что игрок брал в прошлый раз (D-1007-P5): брифинг берёт это само (auto_prepare), снятое
## щелчком отсюда уходит. Старт боя ключ не трогает — запомненное переживает списание.
const PREP_LAST_KEY := "prep_last"
## Имя способности/приёма по ключу `needs` карточки — для пометки B-426.
const NEEDS_NAMES := {
	"ability_unlocked_q": "Молния Ку", "ability_unlocked_w": "Дубль-вэ",
	"ability_unlocked_e": "Аврал", "control_unlocked_rally": "«Сбор»",
}
static var _replacement: Dictionary = {}


## Миграция по ступеням версии: применяются только недостающие шаги. v1 → v2 архивирует старые
## покупки «Конторы» и переводит старые id поправок; v2 → v3 возвращает премию за оплаченные
## жетоны переброски (банк жетонов убран из игры, D-1006-13) — иначе два жетона живого игрока
## пропали бы молча при открытии сохранения новой сборкой.
static func migrate(cfg: ConfigFile, path: String) -> bool:
	var version := int(cfg.get_value(SECTION, "version", 0))
	if version >= VERSION:
		return version == VERSION
	var before := cfg.encode_to_text()
	if version < 2:
		_migrate_v1_to_v2(cfg)
	if version < 3:
		_migrate_v2_to_v3(cfg)
	if version < 4:
		_migrate_v3_to_v4(cfg)
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


## v1 → v2 (переработка 05.10): старые покупки «Конторы» архивируются и возвращаются премией,
## старые id поправок переводятся в колоду, сбрасываются транзиентные ключи.
static func _migrate_v1_to_v2(cfg: ConfigFile) -> void:
	for sec: String in ["meta", Campaign.ENDLESS_SECTION, Campaign.DAILY_SECTION,
			Campaign.REPLAY_SECTION]:
		var archived := {}
		var refund := 0
		for id: String in LEGACY_OFFICE_SHOP:
			var data: Dictionary = LEGACY_OFFICE_SHOP[id]
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
		cfg.set_value(sec, PREP_KEY, "")
		cfg.set_value(sec, PREPS_KEY, [])


## v2 → v3 (переработка 06.10): «Переподписать» убрана из «Конторы», банк жетонов (reroll_tokens)
## удалён. Оплаченные жетоны в каждом разделе возвращаются премией по цене покупки
## (AmendmentDb.REROLL_COST за штуку) и обнуляются — оплаченное не отбираем молча.
static func _migrate_v2_to_v3(cfg: ConfigFile) -> void:
	for sec: String in ["meta", Campaign.ENDLESS_SECTION, Campaign.DAILY_SECTION,
			Campaign.REPLAY_SECTION]:
		var tokens := maxi(0, int(cfg.get_value(sec, "reroll_tokens", 0)))
		if tokens <= 0:
			continue
		cfg.set_value(sec, "bounty",
			int(cfg.get_value(sec, "bounty", 0)) + tokens * AmendmentDb.REROLL_COST)
		cfg.set_value(sec, "reroll_tokens", 0)


static func clear_stage() -> void:
	_replacement.clear()


## v3 → v4: удаляем неработающие ключи, сохраняя ненулевую историю в архиве.
## Премию здесь не возвращаем: это уже сделала v1 → v2. Выбор награды не трогаем.
static func _migrate_v3_to_v4(cfg: ConfigFile) -> void:
	for sec: String in ["meta", Campaign.ENDLESS_SECTION, Campaign.DAILY_SECTION,
			Campaign.REPLAY_SECTION]:
		if not cfg.has_section(sec):
			continue
		var archive: Dictionary = cfg.get_value(sec, "legacy_purchases", {}).duplicate()
		for key: String in cfg.get_section_keys(sec):
			if not key.begins_with("shop_"):
				continue
			var value := int(cfg.get_value(sec, key, 0))
			if value > 0 and not archive.has(key):
				archive[key] = value
			cfg.erase_section_key(sec, key)
		if not archive.is_empty():
			cfg.set_value(sec, "legacy_purchases", archive)


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


## B-426: карточка про способность, которую игрок в кампании ещё не видел (её открывает карта,
## открытая, но не пройденная), — «Аврал появится на «Два отдела»». Иначе "". Предложение не
## сужаем: поправка сработает уже на той карте, игроку нужно лишь знать, откуда способность.
static func unseen_note(id: StringName) -> String:
	if Campaign.is_endless_scope():
		return ""
	var needs := String(AmendmentDb.card(id).get("needs", ""))
	if needs == "" or not NEEDS_NAMES.has(needs):
		return ""
	for m in Campaign.maps():
		var unlocks: Variant = m.get("unlocks", [])
		if not (unlocks is Array or unlocks is Dictionary) or not needs in unlocks:
			continue
		var mid := String(m.get("id", ""))
		if Campaign.stars(mid) > 0:
			return ""
		return "%s появится на «%s»" % [NEEDS_NAMES[needs], String(m.get("title", mid))]
	return ""


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


## Другое предложение: только на экране выбора поправок, всегда за премию напрямую (банк жетонов
## убран). Не списывается, если предложения нет или награда уже забрана.
static func reroll(rng: RandomNumberGenerator) -> Array[StringName]:
	if Campaign.pending_reward() == "" or Campaign.reward_claimed():
		return []
	if Campaign.bounty() < AmendmentDb.REROLL_COST:
		return []
	var cfg := Campaign.raw_file()
	var sec := Campaign._meta_section()
	Campaign.begin_update()
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
	return Campaign.bounty() >= AmendmentDb.REROLL_COST


# ── «Контора»: разовая подготовка следующего боя (AmendmentDb.PREPARATIONS) ─────────────────────

## Сколько пакетов подготовки влезает на один объект: один сразу, второй — с разряда 4.
static func preparations_max() -> int:
	return 2 if Campaign.hero_level() >= AmendmentDb.PREP_SLOT2_LEVEL else 1


## Выбранные пакеты подготовки (по порядку), с отсечкой мусора и потолком слотов. Старое
## сохранение с одиночным ключом PREP_KEY читается так же — миграция не нужна.
static func preparations() -> Array[String]:
	var raw: Array = Campaign.raw_file().get_value(Campaign._meta_section(), PREPS_KEY, [])
	var out: Array[String] = []
	for id in raw:
		var sid := String(id)
		if AmendmentDb.PREPARATIONS.has(sid) and not out.has(sid) \
				and out.size() < preparations_max():
			out.append(sid)
	if out.is_empty():
		var legacy := String(Campaign.raw_file().get_value(
			Campaign._meta_section(), PREP_KEY, ""))
		if AmendmentDb.PREPARATIONS.has(legacy):
			out.append(legacy)
	return out


## Первый пакет подготовки (совместимость со старыми вызовами) или "".
static func preparation() -> String:
	var list := preparations()
	return list[0] if not list.is_empty() else ""


## Свод модов всех выбранных пакетов по правилу MetaMods (пакеты сейчас двигают разные ключи —
## стартовые души и потолок маны, — но свод общий, чтобы второй источник не погасил первый).
static func preparation_mods() -> Dictionary:
	var parts := {}
	for id in preparations():
		var card_mods: Dictionary = AmendmentDb.PREPARATIONS[id].get("mods", {})
		for k: String in card_mods:
			if not parts.has(k):
				parts[k] = []
			(parts[k] as Array).append(float(card_mods[k]))
	var out := {}
	for k: String in parts:
		out[k] = MetaMods.combine(StringName(k), parts[k])
	return out


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
	if preparations().is_empty():
		return true
	Campaign.begin_update()
	var cfg := Campaign.raw_file()
	var sec := Campaign._meta_section()
	cfg.set_value(sec, PREPS_KEY, [])
	cfg.set_value(sec, PREP_KEY, "")
	Campaign.save_raw()
	return Campaign.end_update(true)


## Покупка пакета подготовки за премию. false — пакет неизвестен, уже взят, слот занят или премии
## не хватает. (Переброски здесь больше нет: она на экране выбора поправок.)
static func buy_service(id: String) -> bool:
	var data: Dictionary = AmendmentDb.PREPARATIONS.get(id, {})
	var cost := int(data.get("cost", -1))
	if cost < 0 or Campaign.bounty() < cost:
		return false
	if preparations().has(id) or preparations().size() >= preparations_max():
		return false
	Campaign.begin_update()
	Campaign.add_bounty(-cost)
	var picked := preparations()
	picked.append(id)
	Campaign.raw_file().set_value(Campaign._meta_section(), PREPS_KEY, picked)
	var last := prep_last()
	if not last.has(id):
		last.append(id)
	Campaign.raw_file().set_value(Campaign._meta_section(), PREP_LAST_KEY, last)
	Campaign.save_raw()
	return Campaign.end_update(true)


## Снять взятый пакет с ПОЛНЫМ возвратом премии (брифинг: повторный щелчок по взятой строке) и
## забыть его для auto_prepare. false — пакет не взят или запись не удалась (тогда end_update
## откатывает файл целиком: ни премии, ни пакета не меняется).
static func cancel_service(id: String) -> bool:
	var picked := preparations()
	if not picked.has(id):
		return false
	Campaign.begin_update()
	Campaign.add_bounty(int(AmendmentDb.PREPARATIONS[id]["cost"]))
	picked.erase(id)
	var cfg := Campaign.raw_file()
	var sec := Campaign._meta_section()
	cfg.set_value(sec, PREPS_KEY, picked)
	cfg.set_value(sec, PREP_KEY, "")
	var last := prep_last()
	last.erase(id)
	cfg.set_value(sec, PREP_LAST_KEY, last)
	Campaign.save_raw()
	return Campaign.end_update(true)


## Запомненные пакеты прошлой подготовки (D-1007-P5), без мусора.
static func prep_last() -> Array[String]:
	var out: Array[String] = []
	for id in Campaign.raw_file().get_value(Campaign._meta_section(), PREP_LAST_KEY, []):
		var sid := String(id)
		if AmendmentDb.PREPARATIONS.has(sid) and not out.has(sid):
			out.append(sid)
	return out


## Брифинг: докупить то, что игрок брал в прошлый раз, по обычным правилам buy_service (премия,
## места, транзакция). Возвращает, что взято автоматически сейчас; уже взятое не трогает.
static func auto_prepare() -> Array[String]:
	var got: Array[String] = []
	for id in prep_last():
		if not preparations().has(id) and buy_service(id):
			got.append(id)
	return got


static func reset_run(sec: String) -> void:
	var cfg := Campaign.raw_file()
	for key: String in ["draft_options", "legacy_upgrades"]:
		cfg.set_value(sec, key, [])
	cfg.set_value(sec, PREP_KEY, "")
	cfg.set_value(sec, PREPS_KEY, [])
	cfg.set_value(sec, PREP_LAST_KEY, [])
	cfg.set_value(sec, "reward_claimed", false)
	clear_stage()
