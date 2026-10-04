class_name CfgEnemies
extends RefCounted
##
## Враги: характеристики типов и движение. Владелец — пакет P1 (волны и враги).
## Перенесено из cfg.gd фундаментом F0 без изменения чисел; добавлен master_px (мастер босса —
## 960 px, а не 832: общий MASTER_PX дал бы неверный размер).
##
## Как выглядит враг (текстуры, доли контента, клипы) — в CfgAnim.CHARS[type_id]; здесь
## sprite/visual/frac оставлены как справочник и для enemy_scale().
##

# ── Враги (config.js ENEMY_TYPES) ────────────────────────────────────────────
## В срез входят ровно два типа: зомби идёт напролом, призрак быстрый и хлипкий.
## visual поднят тем же коэффициентом, что и VIS_SKELETON (Э2, 2026-08-26) — враги обязаны
## остаться соразмерны подросшему скелету, а не потеряться у него в ногах. radius (боевая
## коллизия/расталкивание) поднят пропорционально.
## visual пересчитан треком анимации (2026-09-23, ТОЛЬКО вид — radius/speed не тронуты): с
## клипами anim_v4 body_h = ANCHOR_PX × visual — настоящая высота фигуры, высоты по
## C:/AI/necro/assets/anim_v4/SCALES.md к скелету (~120 px на экране): зомби ×1.0,
## подписант ×0.98, юрист ×0.88, призрак ×1.14, надгробие ×0.73, босс ×1.9.
const ENEMIES := {
	"zombie": {
		"name": "стажёр",
		"hp": 20.0, "speed": 58.0, "damage": 4.0, "radius": 21.0,
		"sprite": "res://assets/img/zombie.png", "visual": 0.87, "frac": 0.5192,
		"master_px": 832.0, "translucent": false,
	},
	"ghost": {
		"name": "аудитор",
		"hp": 10.0, "speed": 118.0, "damage": 4.0, "radius": 18.0,
		"sprite": "res://assets/img/ghost.png", "visual": 0.99, "frac": 0.5288,
		"master_px": 832.0, "translucent": true,
	},
	## Числа ×1.29 (Э2) от CC §3.1 (hp70 speed30 dmg12 radius20) — тот же коэффициент, что у
	## zombie/ghost, чтобы юрист не потерялся рядом с подросшим скелетом. Умирая, распадается
	## на 2 signer (enemy_roster.gd, B1: спавн отложенный, как весь world.spawn_enemy).
	"beetle": {
		"name": "юрист",
		"hp": 70.0, "speed": 39.0, "damage": 12.0, "radius": 26.0,
		"sprite": "res://assets/img/beetle.png", "visual": 0.77, "frac": 0.5757,
		"master_px": 832.0, "translucent": false,
	},
	## CC §3.2 (hp8 speed100 dmg5 radius12) ×1.29. В генератор волн НЕ попадает — рождается
	## только из юриста (rise:=false).
	"signer": {
		"name": "подписант",
		"hp": 8.0, "speed": 129.0, "damage": 5.0, "radius": 15.0,
		"sprite": "res://assets/img/signer.png", "visual": 0.85, "frac": 0.5168,
		"master_px": 832.0, "translucent": false,
	},
	## CC §3.3: спит (speed 0) до пробуждения, скорость после — 70×1.29≈90 (CC speedAwake 70).
	## `speed` здесь = скорость ПРОСНУВШЕГОСЯ; спящего останавливает enemy_roster.gd/mimic.gd.
	"mimic": {
		"name": "надгробие",
		"hp": 15.0, "speed": 90.0, "damage": 8.0, "radius": 23.0,
		"sprite": "res://assets/img/mimic.png", "visual": 0.64, "frac": 0.6178,
		"master_px": 832.0, "translucent": false,
	},
	## CC §3.4 (hp600 speed25 dmg25 radius46) ×1.29. Мастер 960, а не общий MASTER_PX 832 —
	## иначе enemy_scale() даёт неверный размер (PROTOTYPE_PLAN.md, находка сверки §0.4).
	"boss": {
		"name": "прораб ада",
		# HP этой строки boss.gd НЕ читает — истина в CfgBoss (3000 после балансового прохода
		# 2026-09-23); здесь копия, чтобы справочная таблица не врала
		"hp": 3000.0, "speed": 32.0, "damage": 25.0, "radius": 59.0,
		"sprite": "res://assets/img/boss.png", "visual": 1.66, "frac": 0.8906,
		"master_px": 960.0, "translucent": false,
	},
}

const ENEMY_ATTACK_CD := 0.8        # как часто враг бьёт котёл, с
const CORPSE_TTL := 6.0             # с — труп доступен для W (config.js CORPSE_TTL)
const DEATH_ANIM := 0.45            # с — падение и растворение (config.js DEATH_ANIM_DURATION)
const SPAWN_RISE := 0.4             # с — подъём из-под земли (config.js SPAWN.riseDuration)
const SPAWN_JITTER := 40.0          # амплитуда бокового виляния на пути к котлу
const SPAWN_PATH_LOCK := 60.0       # первые px от ворот враг идёт строго к центру


## Множитель scale для плоского спрайта врага (мастер master_px, по умолчанию 832).
static func enemy_scale(type_id: String) -> Vector2:
	var e: Dictionary = ENEMIES[type_id]
	var master := float(e.get("master_px", Cfg.MASTER_PX))
	var s := Cfg.ANCHOR_PX * float(e["visual"]) / float(e["frac"]) / master
	return Vector2(s, s)


## Определение типа врага; неизвестный тип — зомби (с предупреждением), чтобы бой не падал.
static func def_of(type_id: String) -> Dictionary:
	if ENEMIES.has(type_id):
		return ENEMIES[type_id]
	push_warning("CfgEnemies: неизвестный тип '%s' — подставлен zombie" % type_id)
	return ENEMIES["zombie"]
