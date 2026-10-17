extends SceneTree
## Срок жизни владельца артефактов: слабая обратная ссылка, без очистки общих кэшей.

var checks := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("OK " if ok else "FAIL ", message)


func _initialize() -> void:
	_isolated_cycle()
	_world_ownership()
	_inventory()
	print("ITEM LIFETIME: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)


func _isolated_cycle() -> void:
	var owner := LegionItems.new()
	owner.effects = LegionItemEffects.new()
	owner.effects.setup(null, owner)
	var owner_ref: WeakRef = weakref(owner)
	var effects_ref: WeakRef = weakref(owner.effects)
	var rng_ref: WeakRef = weakref(owner.rng)
	check(owner.effects.items == owner, "живой владелец доступен через effects.items")
	owner.counts[&"probe"] = 1
	owner.effects.used(&"probe", Vector2.ZERO)
	check(owner.activation_count(&"probe") == 1, "эффект обновляет счётчик живого владельца")
	# Старые тесты используют nullable setter для локальной очистки.
	owner.effects.items = null
	check(owner.effects.items == null, "items=null остаётся поддерживаемым присваиванием")
	owner.effects.items = owner
	check(owner.effects.items == owner, "setter восстанавливает доступ к живому владельцу")
	owner = null
	check(owner_ref.get_ref() == null, "без внешнего владельца LegionItems освобождён")
	check(effects_ref.get_ref() == null, "при освобождении владельца effects освобождён")
	check(rng_ref.get_ref() == null, "при освобождении владельца его RNG освобождён")


func _world_ownership() -> void:
	# Сигналы живого мира законно удерживают owner; сначала освобождаем сам мир.
	var world := LegionWorld.new()
	var owner := LegionItems.new().setup(world, 1)
	var owner_ref: WeakRef = weakref(owner)
	var rng_ref: WeakRef = weakref(owner.rng)
	var effects := owner.effects
	var effects_ref: WeakRef = weakref(effects)
	world.free()
	owner = null
	check(owner_ref.get_ref() == null, "после world.free нет скрытого владельца Items")
	check(rng_ref.get_ref() == null, "после world.free/drop owner RNG освобождён")
	check(effects.items == null, "удержанный отдельно effect не удерживает мёртвого владельца")
	effects = null
	check(effects_ref.get_ref() == null, "последний внешний effects освобождён")


func _inventory() -> void:
	for entry: Array in SnapItems.coverage():
		var script: Script = entry[0]
		var known: Array = entry[1]
		var fields := NetSnap.script_vars(script)
		var missing: Array[String] = []
		var stale: Array[String] = []
		for field in fields:
			if not known.has(field):
				missing.append(field)
		for field: String in known:
			if not fields.has(field):
				stale.append(field)
		check(missing.is_empty() and stale.is_empty(),
			"inventory %s missing=%s stale=%s" % [script.resource_path, missing, stale])
