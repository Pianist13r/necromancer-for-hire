class_name LegionInputReplay
extends RefCounted
## Opt-in local evidence, NOT a signed score or an anti-cheat verifier.
## Commands use NetCodec and the existing net_apply/net_step path. No production hook.
## v1: fresh standalone solo, neutral progression, no bots/tutorial/campaign/carry.

const VERSION := 1
const MAX_TICKS := 3600
const MAX_EVENTS := 4096
const MAX_FILE := 8 * 1024 * 1024
const MAX_SNAPSHOT := 4 * 1024 * 1024
const TYPES := ["stroke", "aim", "sling", "click", "erase", "plot", "cast", "rally"]
const KEYS := ["schema", "identity", "config", "initial", "ticks", "events", "digests", "score"]

var world: LegionWorld
var envelope: Dictionary = {}
var pending: Array[Dictionary] = []
var error := ""
var cursor := 0


static func identity(code: String, engine: String) -> Dictionary:
	return {"code_sha256": code, "engine_sha256": engine,
		"engine_version": Engine.get_version_info()["string"],
		"generator": ProcGen.VERSION, "snapshot": NetSnap.VERSION, "codec": "NetCodec/Q8"}


## Caller creates an embedded world in an isolated profile, then awaits net_can_step().
static func prepare(w: LegionWorld, config: Dictionary) -> void:
	w.set_process(false)
	w.mods = {}
	w.in_campaign = false
	w.carry_items = false
	w.battle_preparation = {}
	w.dev_invuln = false
	w.dev = {"difficulty": config["difficulty"]}
	w.args = {"mute": true}
	w._base_seed = int(config["seed"])
	w.net_mode = true
	w.local_side = 0
	w.net_tick = 0
	w._net_starting = true
	w.start_map(config["map"])
	w._net_starting = false
	w.set_process(false)


func begin(w: LegionWorld, source: Dictionary) -> bool:
	world = w
	if not w.net_can_step() or w.net_tick != 0 or w.now != 0.0 or w.pvp \
			or w.bot != null or w.tutorial != null or w.in_campaign or w.carry_items \
			or not w.mods.is_empty() or not w.battle_preparation.is_empty():
		error = "unsupported initial state"
		return false
	var bytes := state_bytes(w)
	envelope = {"schema": VERSION, "identity": source,
		"config": {"map": w.map_id, "seed": w._base_seed, "difficulty": w.difficulty,
			"progression": "neutral", "tick_hz": 60, "side": 0},
		"initial": Marshalls.raw_to_base64(bytes), "ticks": 0,
		"events": [], "digests": [digest(w)], "score": score(w)}
	w.net_out = capture
	return true


## Attach explicitly to net_out; never records raw device input or calls a bot.
func capture(cmd: Dictionary) -> void:
	var encoded := NetCodec.encode(cmd)
	if not valid_command(encoded) or pending.size() + envelope["events"].size() >= MAX_EVENTS:
		error = "unsupported command or event limit"
		return
	pending.append(encoded)


func record_tick() -> bool:
	if error != "" or world.net_tick >= MAX_TICKS or not world.net_can_step():
		error = error if error != "" else "tick limit or ended battle"
		return false
	for cmd in pending:
		var outcome := world.net_apply(0, NetCodec.decode(cmd))
		envelope["events"].append({"tick": world.net_tick, "seq": envelope["events"].size(),
			"side": 0, "command": cmd, "outcome": outcome})
	pending.clear()
	world.net_step()
	envelope["ticks"] = world.net_tick
	envelope["digests"].append(digest(world))
	envelope["score"] = score(world)
	return true


## Preflight must succeed before calling restore. A saved start is loaded ONLY after its
## binary representation equals the fresh neutral start, so arbitrary Variant data is never
## deserialized. Full-width RNG integers survive the binary snapshot inside the JSON envelope.
func restore(w: LegionWorld, data: Dictionary, expected: Dictionary) -> bool:
	error = validate(data, expected)
	if error != "":
		return false
	world = w
	var bytes := Marshalls.base64_to_raw(data["initial"])
	if bytes != state_bytes(w):
		error = "initial state mismatch"
		return false
	var reg := w.load_snapshot(bytes_to_var(bytes))
	if not reg.errors.is_empty() or not reg.misses.is_empty() or digest(w) != data["digests"][0]:
		error = "snapshot restore mismatch"
		return false
	envelope = data
	cursor = 0
	return true


func replay_tick() -> bool:
	var tick := world.net_tick
	if error != "" or tick >= int(envelope["ticks"]) or not world.net_can_step():
		error = "unexpected end at tick %d" % tick
		return false
	while cursor < envelope["events"].size() and int(envelope["events"][cursor]["tick"]) == tick:
		var event: Dictionary = envelope["events"][cursor]
		var outcome := world.net_apply(0, NetCodec.decode(event["command"]))
		if json_text(outcome) != json_text(event["outcome"]):
			error = "command outcome mismatch at tick %d" % tick
			return false
		cursor += 1
	world.net_step()
	if digest(world) != envelope["digests"][world.net_tick]:
		error = "state mismatch at tick %d" % world.net_tick
		return false
	if world.net_tick == int(envelope["ticks"]) \
			and json_text(score(world)) != json_text(envelope["score"]):
		error = "score mismatch"
		return false
	return true


static func validate(data: Variant, expected: Dictionary) -> String:
	if not data is Dictionary or not exact_keys(data, KEYS):
		return "envelope keys"
	if not integer(data["schema"], VERSION, VERSION):
		return "schema identity"
	if not data["identity"] is Dictionary or json_text(data["identity"]) != json_text(expected) \
			or not hex64(expected.get("code_sha256")) or not hex64(expected.get("engine_sha256")):
		return "runtime identity"
	var cfg: Variant = data["config"]
	if not cfg is Dictionary or not exact_keys(cfg, ["map", "seed", "difficulty", "progression", "tick_hz", "side"]):
		return "config keys"
	if not cfg["map"] is String or cfg["map"].length() < 1 or cfg["map"].length() > 80 \
			or "/" in cfg["map"] or "\\" in cfg["map"] or ".." in cfg["map"] \
			or not integer(cfg["seed"], 0, 2147483647) or not cfg["difficulty"] is String \
			or not cfg["difficulty"] in LegionChallenge.ORDER or not cfg["progression"] is String \
			or cfg["progression"] != "neutral" or not integer(cfg["tick_hz"], 60, 60) \
			or not integer(cfg["side"], 0, 0):
		return "unsupported config"
	if not FileAccess.file_exists("res://assets/legion/maps/%s.json" % cfg["map"]):
		return "unsupported map"
	if not data["initial"] is String or data["initial"].length() < 4 or data["initial"].length() > MAX_SNAPSHOT:
		return "snapshot size"
	if not base64_text(data["initial"]):
		return "snapshot encoding"
	if not integer(data["ticks"], 1, MAX_TICKS) or not data["events"] is Array \
			or data["events"].size() > MAX_EVENTS or not data["digests"] is Array \
			or data["digests"].size() != int(data["ticks"]) + 1:
		return "timeline bounds"
	for value: Variant in data["digests"]:
		if not hex64(value):
			return "digest encoding"
	var previous := -1
	for i in data["events"].size():
		var event: Variant = data["events"][i]
		if not event is Dictionary or not exact_keys(event, ["tick", "seq", "side", "command", "outcome"]):
			return "event keys"
		if not integer(event["tick"], maxi(0, previous), int(data["ticks"]) - 1) \
				or not integer(event["seq"], i, i) or not integer(event["side"], 0, 0):
			return "event order"
		if not valid_command(event["command"]) or not event["outcome"] is Dictionary \
				or not event["outcome"].get("ok") is bool or not event["outcome"].get("reason") is String \
				or JSON.stringify(event["outcome"]).length() > 1024:
			return "command encoding"
		previous = int(event["tick"])
	if not data["score"] is Dictionary or not exact_keys(data["score"], ["hp", "t", "wave", "kills", "lost", "souls", "phase"]):
		return "score encoding"
	for value: Variant in data["score"].values():
		if not (value is int or value is float) or not is_finite(float(value)):
			return "score value"
	return ""


static func valid_command(data: Variant) -> bool:
	if not data is Dictionary or not data.get("type") is String or not data["type"] in TYPES:
		return false
	# Bound before decode (including arbitrary nested/unknown fields).
	if JSON.stringify(data).length() > 12000:
		return false
	var decoded := NetCodec.decode(data)
	return not decoded.is_empty() and json_text(data) == json_text(NetCodec.encode(decoded))


## Godot JSON parses every number as float. Compare semantic JSON numbers, while the
## separate integer()/NetCodec validators still reject fractional ticks/coordinates/ids.
static func json_text(value: Variant) -> String:
	return JSON.stringify(json_numbers(value))


static func json_numbers(value: Variant) -> Variant:
	if value is float and is_finite(value) and absf(value) <= 9007199254740991.0 and value == floor(value):
		return int(value)
	if value is Dictionary:
		var out := {}
		for key: Variant in value:
			out[key] = json_numbers(value[key])
		return out
	if value is Array:
		var out: Array = []
		for item: Variant in value:
			out.append(json_numbers(item))
		return out
	return value


static func exact_keys(data: Dictionary, names: Array) -> bool:
	return data.size() == names.size() and names.all(func(key: String) -> bool: return data.has(key))


static func integer(value: Variant, lo: int, hi: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) == floor(float(value)) and float(value) >= lo and float(value) <= hi


static func hex64(value: Variant) -> bool:
	if not value is String or value.length() != 64:
		return false
	for c in value:
		if not c in "0123456789abcdef":
			return false
	return true


static func base64_text(value: String) -> bool:
	if value.length() % 4 != 0:
		return false
	var padding := false
	for i in value.length():
		var c := value[i]
		if c == "=" and i >= value.length() - 2:
			padding = true
		elif padding or not c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/":
			return false
	return true


static func score(w: LegionWorld) -> Dictionary:
	# A bounded checkpoint, not an invented victory or an endless-run leaderboard score.
	var result := w.final_stats(false)
	return {"hp": result["hp"], "t": result["t"], "wave": result["wave"],
		"kills": result["kills"], "lost": result["lost"], "souls": w.souls, "phase": int(w.phase)}


static func canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var out := {}
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			out[key] = canonical(value[key])
		return out
	if value is Array:
		var out: Array = []
		for item: Variant in value:
			out.append(canonical(item))
		return out
	return value


static func state_bytes(w: LegionWorld) -> PackedByteArray:
	return var_to_bytes(canonical(w.snapshot()))


static func digest(w: LegionWorld) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(state_bytes(w))
	return hash.finish().hex_encode()
