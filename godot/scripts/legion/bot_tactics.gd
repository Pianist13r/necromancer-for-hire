extends RefCounted
## Видимая колонна проходит вдоль фланга: бот пользуется тем же золотым окном, что игрок.


## Сигнал открытия ворот — не единственный источник угрозы: колонна могла обойти фронт.
static func rear_ready(slot: Dictionary, seen: Dictionary) -> bool:
	if slot.get("role", "") != "rear" or slot.get("rear_active", false):
		return true
	var template: Contract = slot["template"]
	for at: Vector2 in seen.values():
		if template.live_distance(at) <= LegionCfg.BOT_THREAT_R:
			slot["rear_active"] = true
			return true
	return false


static func release_flank(w: LegionWorld, slot: Dictionary,
		seen: Dictionary, velocity: Dictionary) -> bool:
	if slot.get("role", "") not in ["flank", "back"]:
		return false
	for c: Contract in slot["contracts"]:
		if c.kind == LegionCfg.KIND_CLERK:
			continue
		for s in c.seg_count():
			if not c.seg_alive(s) or c.seg_manned(s) < LegionCfg.BOT_MIN_SQUAD:
				continue
			if w.contracts.in_package(c, s) or not w.contracts.seg_gold(c, s):
				continue
			var hit := w.contracts.seg_strike(c, s, LegionCfg.BOT_FLANK_POWER)
			var zone := w.contracts.zone_foes(c.seg_center(s), hit["dir"],
				w.contracts.seg_half_len(c, s), hit["depth"])
			for f in zone:
				var id := f.get_instance_id()
				var motion: Vector2 = velocity.get(id, Vector2.ZERO)
				if not seen.has(id) or motion.length() < LegionCfg.BOT_MELT_MIN_SPEED:
					continue
				if absf(motion.normalized().dot(c.seg_dir(s))) > LegionCfg.BOT_FLANK_DOT:
					continue
				w.contracts.release_aimed(c, s, c.seg_dir(s), LegionCfg.BOT_FLANK_POWER, true)
				slot["last_release"] = w.now
				w.stats["bot_flanks"] = int(w.stats.get("bot_flanks", 0)) + 1
				return true
	return false
