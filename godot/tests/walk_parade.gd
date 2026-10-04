extends SceneTree
## Ролик приёмки ходьбы (не тест, в гейт не входит): настоящий бой (legion.tscn, карта из --map),
## без волн и бойцов, по северной дороге идёт колонна нотариусов, по южной — остальные ходячие
## враги. Движение — обычный foe.gd, вид — CharView, как в игре. Запуск (APPDATA — песочница!):
##   GODOT --path godot --write-movie OUT/clip.png --fixed-fps 30 --quit-after 150 \
##     --script res://tests/walk_parade.gd -- --mute --map fork --dev no_waves=1 \
##     --dev spawn_units=0 --dev no_hero=1
## --dev parade_north=<тип> (по умолчанию signer) — кто идёт колонной по северной дороге.

const NORTH := ["signer", "signer", "signer", "signer", "signer", "signer"]
const SOUTH := ["zombie", "lawyer", "mimic", "beetle", "signer", "boss"]
const GAP := 46.0

var _main: Node = null
var _frames := 0


func _initialize() -> void:
	_main = (load("res://scenes/legion.tscn") as PackedScene).instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		_spawn()
	return false


func _spawn() -> void:
	var world: LegionWorld = _main.get("world")
	if world == null:
		push_error("walk_parade: мир не поднялся (нужен --map)")
		return
	var north_type := String(world.dev.get("parade_north", "signer"))
	_column(world, "north", NORTH.map(func(_t: String) -> String: return north_type))
	_column(world, "south", SOUTH)


## Колонна на втором отрезке дороги (у fork он горизонтальный — видно шаг сбоку): первый ближе
## к Котлу, остальные сзади через GAP px.
func _column(world: LegionWorld, road: String, types: Array) -> void:
	var path := world.road_path(road)
	if path.size() < 3:
		return
	var b := path[2]
	var back := (path[1] - path[2]).normalized()
	var rest := path.slice(2)
	for i in types.size():
		var at := b + back * (GAP * (types.size() - i) + 40.0)
		var f := world.spawn_foe_on_path(String(types[i]), rest, at)
		if f != null:
			f.hp = 1.0e6   # ролик про ходьбу: ничто в пути не должно их уронить
