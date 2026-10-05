extends SceneTree
## Ограниченная редакция, миграция, цена услуги и восстановление ожидающего выбора.

const SAVE := "user://progression_red_green.cfg"

var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL: ", message)


func _fresh() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()


func _run() -> void:
	_test_slots()
	_test_draft()
	_test_services()
	_test_migration()
	_test_run_boundaries()
	await _test_screens()
	print("PROGRESSION: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _test_slots() -> void:
	_fresh()
	for id: StringName in [&"living_queue", &"ghost_clause", &"carbon_copy", &"lean_staff"]:
		Campaign.add_upgrade(id)
	_check(Campaign.upgrades().size() == 3, "fourth direct grant cannot silently stack")
	Campaign.set_pending_reward("gatehouse")
	_check(not Campaign.claim_reward(&"lean_staff"), "full draft refuses unspecified replacement")
	_check(not RunProgression.stage(3), "invalid replacement slot refused")
	_check(RunProgression.stage(0), "replacement explicitly staged")
	Campaign.use_endless_scope()
	_check(RunProgression.replacement_slot() == -1, "stage cannot leak into another scope")
	Campaign.use_campaign_scope()
	_check(RunProgression.replacement_slot() == -1, "scope switch drops staged replacement")
	_check(RunProgression.stage(0), "replacement staged again after round-trip")
	_check(Campaign.claim_reward(&"lean_staff"), "valid replacement commits")
	_check(Campaign.upgrades().size() == 3 and not Campaign.upgrades().has(&"living_queue"),
		"replacement removed old rule and kept bounded slots")
	_check(not Campaign.active_rules().has("queue"), "removed special behavior no longer active")
	_check(Campaign.active_rules().has("ghost") and Campaign.active_rules().has("echo"),
		"remaining rules retained")
	_check(Campaign.reward_claimed() and Campaign.pending_reward() == "gatehouse",
		"office stage retained")
	Campaign.set_save_path(SAVE)
	_check(RunProgression.replacement_slot() == -1, "restart clears transient replacement")
	_check(Campaign.upgrades().size() == 3 and Campaign.reward_claimed(), "replacement persisted once")
	_check(not Campaign.claim_reward(&"living_queue"), "same victory cannot grant twice")
	var active := Campaign.upgrades()
	active.clear()
	_check(Campaign.upgrades().size() == 3, "public slots getter returns own array")
	_check(is_equal_approx(Campaign.stat(&"cap_mult_laborer"), 0.75), "tradeoff really reaches stats")
	Campaign.raw_file().set_value("hero", "rank_q", 2)
	Campaign.raw_file().set_value("hero", "perks", ["perk_chain_reaction", "perk_fast_hire"])
	Campaign.raw_file().set_value("meta", "shop_mana", 3)
	Campaign.save_raw()
	_check(Campaign.stat(&"ability_rank_q") == 0.0 and Campaign.stat(&"perk_chain_reaction") == 0.0,
		"legacy hero grants no hidden permanent power")
	_check(Campaign.stat(&"mana_max_bonus") == 0.0, "legacy office grants no hidden mana")


func _test_draft() -> void:
	_fresh()
	Campaign.set_pending_reward("next")
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	var first := Campaign.offer_upgrades(rng)
	_check(first.size() == 3, "full useful initial random offer")
	for id in first:
		_check(not AmendmentDb.card(id).is_empty() and RunProgression.available(id), "offered card valid")
	Campaign.set_save_path(SAVE)
	rng.seed = 999
	_check(Campaign.offer_upgrades(rng) == first, "restart preserves exact offer")
	_check(not RunProgression.available(&"moving_office"), "optional variant respects XP unlock")
	Campaign._add_hero_xp(250)
	_check(RunProgression.available(&"moving_office"), "XP opens optional variety")
	Campaign.add_bounty(90)
	var before := Campaign.bounty()
	var next := RunProgression.reroll(rng)
	_check(next.size() == 3 and Campaign.bounty() == before - AmendmentDb.REROLL_COST,
		"reroll costs once and yields three options")
	var changed := false
	for id in next:
		if not first.has(id):
			changed = true
	_check(changed, "paid reroll changes at least one available option")
	_check(Campaign.offer_upgrades(rng) == next, "rerolled draft persisted")
	for id: String in AmendmentDb.ORDER:
		var card := AmendmentDb.card(StringName(id))
		_check(card.has("text") and card.has("tradeoff") and card.has("hint"),
			"every rule explains play and price")


func _test_services() -> void:
	_fresh()
	Campaign.add_bounty(140)
	_check(RunProgression.buy_service("souls"), "one object preparation bought")
	var bounty := Campaign.bounty()
	_check(not RunProgression.buy_service("mana") and Campaign.bounty() == bounty,
		"second preparation cannot charge or overwrite first")
	_check(RunProgression.preparation_mods().get("start_souls", 0.0) == 45.0,
		"preparation has concrete next-object value")
	_check(not Campaign.active_mods().has("start_souls"),
		"preparation cannot stack into permanent draft")
	_check(RunProgression.consume_preparation() and RunProgression.preparation() == "", "consume once")
	_check(RunProgression.consume_preparation(), "consume twice neutral")
	_check(RunProgression.buy_service("reroll") and RunProgression.buy_service("reroll"),
		"two rerolls banked")
	_check(not RunProgression.buy_service("reroll"), "reroll bank cap")
	var before := Campaign.bounty()
	var blocked := ProjectSettings.globalize_path(SAVE + ".tmp")
	DirAccess.make_dir_recursive_absolute(blocked)
	_check(not RunProgression.buy_service("mana"), "failed disk write refuses purchase")
	_check(Campaign.bounty() == before and RunProgression.preparation() == "",
		"failed purchase rolled back")
	DirAccess.remove_absolute(blocked)


func _test_migration() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("hero", "xp", 450)
	cfg.set_value("hero", "rank_q", 2)
	cfg.set_value("hero", "perks", ["perk_fast_hire"])
	cfg.set_value("progress", "unlocked", ["wasteland", "gatehouse"])
	cfg.set_value("progress", "stars_wasteland", 3)
	for sec: String in ["meta", Campaign.ENDLESS_SECTION, Campaign.DAILY_SECTION]:
		cfg.set_value(sec, "shop_range_laborer", 2)
		cfg.set_value(sec, "shop_mana", 1)
		cfg.set_value(sec, "bounty", 17)
		cfg.set_value(sec, "upgrades",
			["overtime_clause", "brigade_quota", "hazard_pay", "union_contract"])
		cfg.set_value(sec, "items", ["clip_of_fate"])
		cfg.set_value(sec, "pending_reward", "next")
		cfg.set_value(sec, "reward_claimed", true)
		cfg.set_value(sec, "seed", 41)
		cfg.set_value(sec, "k", 5)
		cfg.set_value(sec, "tenure", 4)
	SafeConfig.save_file(cfg, SAVE, true)
	var before := FileAccess.get_file_as_string(SAVE)
	Campaign.set_save_path(SAVE)
	Campaign.use_campaign_scope()
	_check(Campaign.hero_xp() == 450, "migration preserved XP")
	_check(FileAccess.get_file_as_string(SAVE + ".bak") == before,
		"migration committed as one backup generation")
	for sec: String in ["meta", Campaign.ENDLESS_SECTION, Campaign.DAILY_SECTION]:
		var raw := Campaign.raw_file()
		_check(int(raw.get_value(sec, "bounty", 0)) == 187,
			"refund by exact spent prices in " + sec)
		_check(Array(raw.get_value(sec, "upgrades", [])).size() == 3, "migrated slots bounded in " + sec)
		_check(Array(raw.get_value(sec, "legacy_upgrades", [])).size() == 4,
			"all old choices archived in " + sec)
		_check(raw.get_value(sec, "pending_reward") == "next" and raw.get_value(sec, "reward_claimed"),
			"reward stage preserved in " + sec)
		_check(raw.get_value(sec, "seed") == 41 and raw.get_value(sec, "k") == 5
			and raw.get_value(sec, "tenure") == 4, "run identity preserved in " + sec)
	_check(Campaign.run_items() == [&"clip_of_fate"], "owned artifacts preserved")
	_check(Campaign.stat(&"ability_rank_q") == 0.0, "migrated rank not hidden extra power")
	Campaign.set_save_path(SAVE)
	_check(Campaign.bounty() == 187, "migration idempotent, no second refund")
	_check(Campaign.raw_file().has_section_key("hero", "legacy_choices"), "hero choices archived")


func _test_run_boundaries() -> void:
	_fresh()
	Campaign.add_upgrade(&"living_queue")
	Campaign.add_bounty(80)
	RunProgression.buy_service("mana")
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(7)
	_check(Campaign.upgrades().is_empty() and RunProgression.preparation() == "",
		"new run starts without campaign loadout")
	Campaign.add_upgrade(&"ghost_clause")
	Campaign.add_bounty(70)
	RunProgression.buy_service("souls")
	LegionRunStore.endless_start(8)
	_check(Campaign.upgrades().is_empty() and Campaign.bounty() == 0
		and RunProgression.preparation() == "", "new run resets draft and services")
	Campaign.use_campaign_scope()
	_check(Campaign.upgrades() == [&"living_queue"] and RunProgression.preparation() == "mana",
		"endless reset cannot erase campaign")


func _test_screens() -> void:
	_fresh()
	Campaign.add_upgrade(&"living_queue")
	Campaign.add_upgrade(&"ghost_clause")
	Campaign.add_upgrade(&"carbon_copy")
	Campaign.set_pending_reward("next")
	var picker := UpgradePicker.new()
	root.add_child(picker)
	await process_frame
	picker.offer([&"lean_staff", &"bulk_ink", &"paper_shield"])
	var chosen: Array[StringName] = []
	picker.picked.connect(func(id: StringName) -> void: chosen.append(id))
	picker.choose(&"bulk_ink")
	_check(chosen.is_empty(), "full UI choice waits for explicit replacement")
	_check(not picker._cards_box.visible, "replacement screen exposes old rules")
	picker.replace(1)
	_check(chosen == [&"bulk_ink"] and RunProgression.replacement_slot() == 1,
		"UI choice stages concrete old slot")
	picker._cancel_replacement()
	_check(RunProgression.replacement_slot() == -1 and picker._cards_box.visible,
		"cancel restores proposal without leak")
	picker.queue_free()
	await process_frame
	var office := OfficeShop.new()
	root.add_child(office)
	await process_frame
	_check(office._services.get_child_count() == 3, "office offers three concrete services")
	var hero := HeroScreen.new()
	root.add_child(hero)
	await process_frame
	_check(hero.find_children("*", "AmendmentCard", true, false).size() == 12,
		"dossier shows every possible rule")
	office.queue_free()
	hero.queue_free()
	await process_frame
