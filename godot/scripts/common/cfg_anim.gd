class_name CfgAnim
extends RefCounted

## Стан: только представление CharView, без изменения таймера или позиции врага.
const STUN_STAR_COUNT := 3
const STUN_ORBIT_RATE := 4.5
const STUN_SWAY := 0.045
## Темп клипа walk по фактической скорости (CHARS[id].walk_speed, B-206): множитель темпа =
## факт / расчёт, зажатый в [MIN, MAX]; факт — сумма пути и времени с затуханием TAU секунд
## (шаг движения сущности 60 Гц против кадров вида — без сглаживания темп дёргался бы).
## Первые WARMUP секунд ходьбы темп 1,0; скачок позиции больше JUMP_PX (телепорт, спавн) не в счёт.
const WALK_TEMPO_MIN := 0.4
const WALK_TEMPO_MAX := 1.5
const WALK_TEMPO_TAU := 0.25
const WALK_TEMPO_WARMUP := 0.1
const WALK_TEMPO_JUMP_PX := 60.0
##
## Как выглядят персонажи: покадровые клипы, запасные текстуры и процедурные заглушки.
## Владелец — трек анимации (docs/PROTOTYPE_PLAN.md §2.5, §7). Геймплейные пакеты этот файл
## НЕ правят: они зовут только API CharView (setup/play_once/set_locomotion/...).
##
## Клип появился → трек кладёт кадры в `res://assets/anim/<char_id>/<state>/spr_NN.png`
## (импортированные текстуры, работают в экспорте) и дописывает строку в CHARS — код игры не
## меняется. Нет клипа → CharView отыгрывает заглушку из "stub" на запасной текстуре.
##
## Поля CHARS[char_id]:
##   clips        — state → {dir, fps, loop, contact_frame} (-1 — без кадра касания);
##                  необязательные: hold (одноразовый клип замирает на последнем кадре —
##                  смерть/труп; перебивает любой одноразовый клип), interruptible (одноразовый
##                  клип уступает другому одноразовому: spawn скелета, hit врагов)
##   default      — зацикленное состояние, куда возвращаемся после одноразового клипа
##   canvas_px    — сторона холста клипа, px; figure_fill — доля высоты холста под фигурой
##   ground_off   — где «земля» ниже position сущности, в долях body_h (клипы якорены низом:
##                  низ холста = земля + 1 % холста)
##   fallback     — state → {tex, frac}: плоская текстура, центр = position сущности; frac —
##                  доля высоты КОНТЕНТА в холсте (js/data/visualScale.js). Нет state →
##                  берётся "idle"
##   stub         — state → {kind, dur}: процедурная заглушка, если клипа нет. kind:
##                  rise (из-под земли), fall (падение с поворотом, остаётся лежать),
##                  flash (вспышка), pose (сменить fallback-текстуру на dur), none
##   bob          — амплитуда покачивания заглушки ходьбы, px (0 — без покачивания)
##   walk_speed   — необязательное: расчётная скорость хода, px мира/с — та, из которой посчитан
##                  fps клипа walk (tools/walk_legs_rig.py, BATTLE в tools/walk_audit.py). CharView
##                  по факту скорости сущности (рельеф, замедление печатью) ускоряет/замедляет
##                  ТОЛЬКО пока играет walk — ноги не обгоняют тело и не отстают (B-206). Нет
##                  поля — темп клипа постоянный
##
## Пределы и сглаживание темпа ходьбы — WALK_TEMPO_* ниже.

# ── Вид скелета: меш-риг vs покадровая анимация (Э2, 2026-08-26) ─────────────
## "rig" — WalkRig (меш-риг с разрезанным туловищем — владелец его ОТВЕРГ, 2026-08-26).
## "sprites" — CharView/CharAnim (покадровые клипы) — ДЕФОЛТ и основной вид с 2026-08-26. "rig"
## оставлен только чтобы не падать и не проваливаться сквозь землю — вылизывать его не надо.
const SKELETON_VIEW := "sprites"

# ── Меш-риг v5: нога на трёх костях (ветка анимации 2026-09-23, перенос в F0) ──
## Числа чисто визуальные (риг снимает клипы и живёт в walk_proto/"rig"), поэтому лежат в
## файле трека, а не в cfg.gd рядом со старыми RIG_*: cfg.gd правит балансовый проход.
## Третья кость (совет Codex Astra): прежний сустав на манжете носка стал ЩИКОЛОТКОЙ —
## ботинок держит собственный угол (перекат пятка→носок), а IK решает бедро→колено→щиколотка.
## Колено — на этой доле пути бедро→щиколотка, внутри трубки-штанины под шортами: сгиб там
## прячет подол. Мягкая зона колена шире — её всё равно не видно.
const RIG_KNEE_FRAC := 0.45
const RIG_KNEE_SOFT_ZONE := 30.0
## Насколько бедро может вытянуться сверх своей длины, чтобы щиколотка достала цель
## (растяжение ножки вместо колена, правило 4 харнесса). Остальное добирает присед.
## v6: 30 → 8 — покадровое растяжение давало «резиновую» голень; длину добирает постоянная
## прибавка RIG_THIGH_EXTENSION.
const RIG_LEG_STRETCH_MAX := 8.0
## v6: постоянная длина под шортами вместо покадрового удлинения бедра на 30 px.
const RIG_THIGH_EXTENSION := 22.0
## v6: одна базовая высота таза для покоя, старта, ходьбы и замаха.
const RIG_BASE_CROUCH := 30.0
## Доля схождения бёдер к общей дорожке стоп в шаге (см. WalkRig._hip_mount).
const RIG_HIP_TRACK_PULL := 0.7
## Доля схождения стоп к дорожке в ПОКОЕ (WalkRig._idle_x): покой в геометрии ходьбы.
const RIG_IDLE_TRACK_PULL := 0.15
## Присед на дефицит досягаемости считается только по опорной ноге: вклад ноги гаснет,
## когда её цель поднимается над землёй на эту высоту (px рига).
const RIG_CROUCH_LIFT_FADE := 12.0

## Холст покадровых клипов anim-lab (см. `scripts/anim_lab.gd` SPRITE_PX/FIGURE_FILL) —
## те же числа, чтобы масштаб персонажа в бою совпал с кадрами приёмки в лаборатории.
## v19: кадры уменьшены 460 → 224 (Ланцош по предумноженной альфе) и импортируются с мипмапами:
## фигура на экране 45–70 px мира (×1,5 окна), а в холсте 460 было 390 px — ужатие в 4–6 раз
## без мипмапов давало зернистый, мерцающий при ходьбе контур. 224 — запас ≈1,3× до 4K.
const SKELETON_ANIM_CANVAS_PX := 224.0
const SKELETON_ANIM_FIGURE_FILL := 0.85
## Земля скелета — та же точка опоры, что у меш-рига (WalkRig.ground_offset): стопа мастера
## RIG_GROUND_IN_MASTER ниже центра холста мастера, в долях высоты контента (frac 0.8498).
const SKELETON_GROUND_OFF := (
	(Cfg.RIG_GROUND_IN_MASTER - Cfg.MASTER_PX * 0.5) / (0.8498 * Cfg.MASTER_PX)
)

## Направленные мастера и IK-походка: пять исходных ракурсов, ещё три зеркалятся.
## Появление и реакция на урон используют текущий рисунок и процедурное движение,
## чтобы не подменять новый ракурс прежними односторонними hit/spawn.
const SKELETON_ANIM_CLIPS := {
	"idle": {
		# Канонический standing master; дыхание остаётся в CharView.
		"dir": "res://assets/anim/skeleton/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/skeleton/idle_e"}, "se": {"dir": "res://assets/anim/skeleton/idle_se"},
			"s": {"dir": "res://assets/anim/skeleton/idle_s"}, "ne": {"dir": "res://assets/anim/skeleton/idle_ne"}, "n": {"dir": "res://assets/anim/skeleton/idle_n"}},
	},
	"walk": {
		# Направленный IK-цикл .44s при Legion speed70; master256 -> runtime128.
		"dir": "res://assets/anim/skeleton/walk_e", "fps": 36.363636, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/skeleton/walk_e"}, "se": {"dir": "res://assets/anim/skeleton/walk_se"},
			"s": {"dir": "res://assets/anim/skeleton/walk_s"}, "ne": {"dir": "res://assets/anim/skeleton/walk_ne"}, "n": {"dir": "res://assets/anim/skeleton/walk_n"}},
	},
	"attack": {"dir": "res://assets/anim/skeleton/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/skeleton/attack_e"}, "se": {"dir": "res://assets/anim/skeleton/attack_se"}, "s": {"dir": "res://assets/anim/skeleton/attack_s"}, "ne": {"dir": "res://assets/anim/skeleton/attack_ne"}, "n": {"dir": "res://assets/anim/skeleton/attack_n"}}},

	"death": {"dir": "res://assets/anim/skeleton/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/skeleton/death_e"}, "se": {"dir": "res://assets/anim/skeleton/death_se"}, "s": {"dir": "res://assets/anim/skeleton/death_s"}, "ne": {"dir": "res://assets/anim/skeleton/death_ne"}, "n": {"dir": "res://assets/anim/skeleton/death_n"}}},
}

## Заглушки врагов — ровно поведение enemy.gd до F0: подъём из-под земли за SPAWN_RISE,
## падение с поворотом за DEATH_ANIM, белая вспышка 0.12 с на попадании. Работают, только
## если клипа состояния нет.
const ENEMY_STUBS := {
	"rise": {"kind": "rise", "dur": CfgEnemies.SPAWN_RISE},
	"death": {"kind": "fall", "dur": CfgEnemies.DEATH_ANIM},
	"hit": {"kind": "flash", "dur": 0.12},
	"attack": {"kind": "none", "dur": 0.0},
	"wake": {"kind": "none", "dur": 0.5},
	"roar": {"kind": "flash", "dur": 0.3},
	"summon": {"kind": "none", "dur": 0.0},
}
const ENEMY_BOB := 2.4

# ── Клипы персонажей anim_v4 (2026-09-23) ────────────────────────────────────
## Источник — `C:/AI/necro/assets/anim_v4/<char>/manifest.json` (лучшие кадры; у ghost —
## клипы *_v2, у mimic — стиль v2). Второй проход 23.09: жук walk_v2, зомби walk_v3, у всех
## death_v3/hit_v3, ghost attack_v3, некромант cast_v3/ult_v3 (flinch = hit_v3).
## Все нарисованы лицом ВПРАВО, стопы на нижней кромке
## холста с полем 1 %. Холст уменьшен 460 → 320 (кроме босса), v19 — до 224 с мипмапами
## (рост врагов 30–46 px мира, окно ×1,5): контур гладкий, память кадров втрое меньше.
## figure_fill — замер: высота фигуры клипа по умолчанию / холст (альфа > 16), поэтому
## body_h = настоящая высота фигуры на экране. ground_off 0.48 — там же, где тень врага
## (enemy.gd _make_shadow): ноги стоят в тени.
## Тайминги подогнаны под геймплей (PROTOTYPE_PLAN §2.5): rise 0.4 с, death ≤ 0.45 с (босс
## ≤ 1.2 с), контакт замаха ≤ 0.1 с, wake 0.4 с. Смерть — "hold": последний кадр остаётся
## трупом (CharAnim не возвращает его в ходьбу).
const ENEMY_GROUND_OFF := 0.48
## v19: 320 → 224 + мипмапы (враги ростом 30–46 px мира; см. SKELETON_ANIM_CANVAS_PX)
const V4_CANVAS_PX := 224.0

## Ходьба (walk) семи персонажей с 29.09.2026 — ноги-вырезки из одного кадра, шагают по земле
## (tools/walk_legs_rig.py, разметка tools/walk_rig_masters/rig.json). Прежние клипы anim_v4 были
## одной позой с дрожанием: ступни ехали по земле «на коньках», а корпус качался — Игорь: «не
## ходят, а просто дрыгаются». fps здесь — не вкус, а футпланинг: опорная ступня идёт назад со
## скоростью support × скорость в бою (legion_cfg.gd); число печатает walk_legs_rig.py, приёмка —
## tools/walk_audit.py и tests/legion_walk_anim_test.gd. Сменилась скорость или рост в бою —
## перегенерировать кадры, а не подкручивать fps руками.
const ZOMBIE_CLIPS := {
	"idle": {
		"dir": "res://assets/anim/zombie/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {
			"e": {"dir": "res://assets/anim/zombie/idle_e"},
			"se": {"dir": "res://assets/anim/zombie/idle_se"},
			"s": {"dir": "res://assets/anim/zombie/idle_s"},
			"ne": {"dir": "res://assets/anim/zombie/idle_ne"},
			"n": {"dir": "res://assets/anim/zombie/idle_n"},
		},
	},
	"walk": {
		"dir": "res://assets/anim/zombie/walk_e", "fps": 22.222222, "loop": true, "contact_frame": -1,
		"directions": {
			"e": {"dir": "res://assets/anim/zombie/walk_e"},
			"se": {"dir": "res://assets/anim/zombie/walk_se"},
			"s": {"dir": "res://assets/anim/zombie/walk_s"},
			"ne": {"dir": "res://assets/anim/zombie/walk_ne"},
			"n": {"dir": "res://assets/anim/zombie/walk_n"},
		},
	},
	"attack": {
		"dir": "res://assets/anim/zombie/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {
			"e": {"dir": "res://assets/anim/zombie/attack_e"},
			"se": {"dir": "res://assets/anim/zombie/attack_se"},
			"s": {"dir": "res://assets/anim/zombie/attack_s"},
			"ne": {"dir": "res://assets/anim/zombie/attack_ne"},
			"n": {"dir": "res://assets/anim/zombie/attack_n"},
		},
	},
	"death": {
		"dir": "res://assets/anim/zombie/death_e", "fps": 15.0, "loop": false, "contact_frame": -1,
		"hold": true,
		"directions": {
			"e": {"dir": "res://assets/anim/zombie/death_e"},
			"se": {"dir": "res://assets/anim/zombie/death_se"},
			"s": {"dir": "res://assets/anim/zombie/death_s"},
			"ne": {"dir": "res://assets/anim/zombie/death_ne"},
			"n": {"dir": "res://assets/anim/zombie/death_n"},
		},
	},
	# Урон — пружина/вспышка текущего ракурса; появление — общий rise без смены рисунка.
}
const GHOST_CLIPS := {
	"idle": {"dir": "res://assets/anim/ghost/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/ghost/idle_e"}, "se": {"dir": "res://assets/anim/ghost/idle_se"},
			"s": {"dir": "res://assets/anim/ghost/idle_s"}, "ne": {"dir": "res://assets/anim/ghost/idle_ne"}, "n": {"dir": "res://assets/anim/ghost/idle_n"}}},
	"walk": {"dir": "res://assets/anim/ghost/walk_e", "fps": 0.666667, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/ghost/walk_e"}, "se": {"dir": "res://assets/anim/ghost/walk_se"},
			"s": {"dir": "res://assets/anim/ghost/walk_s"}, "ne": {"dir": "res://assets/anim/ghost/walk_ne"}, "n": {"dir": "res://assets/anim/ghost/walk_n"}}},
	"attack": {"dir": "res://assets/anim/ghost/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/ghost/attack_e"}, "se": {"dir": "res://assets/anim/ghost/attack_se"}, "s": {"dir": "res://assets/anim/ghost/attack_s"}, "ne": {"dir": "res://assets/anim/ghost/attack_ne"}, "n": {"dir": "res://assets/anim/ghost/attack_n"}}},
	"death": {"dir": "res://assets/anim/ghost/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/ghost/death_e"}, "se": {"dir": "res://assets/anim/ghost/death_se"}, "s": {"dir": "res://assets/anim/ghost/death_s"}, "ne": {"dir": "res://assets/anim/ghost/death_ne"}, "n": {"dir": "res://assets/anim/ghost/death_n"}}},
}
const BEETLE_CLIPS := {
	"idle": {"dir": "res://assets/anim/beetle/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/beetle/idle_e"}, "se": {"dir": "res://assets/anim/beetle/idle_se"},
			"s": {"dir": "res://assets/anim/beetle/idle_s"}, "ne": {"dir": "res://assets/anim/beetle/idle_ne"}, "n": {"dir": "res://assets/anim/beetle/idle_n"}}},
	"walk": {
		"dir": "res://assets/anim/beetle/walk_e", "fps": 47.058824, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/beetle/walk_e"}, "se": {"dir": "res://assets/anim/beetle/walk_se"},
			"s": {"dir": "res://assets/anim/beetle/walk_s"}, "ne": {"dir": "res://assets/anim/beetle/walk_ne"}, "n": {"dir": "res://assets/anim/beetle/walk_n"}},
	},
	"attack": {"dir": "res://assets/anim/beetle/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/beetle/attack_e"}, "se": {"dir": "res://assets/anim/beetle/attack_se"}, "s": {"dir": "res://assets/anim/beetle/attack_s"}, "ne": {"dir": "res://assets/anim/beetle/attack_ne"}, "n": {"dir": "res://assets/anim/beetle/attack_n"}}},
	"death": {"dir": "res://assets/anim/beetle/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/beetle/death_e"}, "se": {"dir": "res://assets/anim/beetle/death_se"}, "s": {"dir": "res://assets/anim/beetle/death_s"}, "ne": {"dir": "res://assets/anim/beetle/death_ne"}, "n": {"dir": "res://assets/anim/beetle/death_n"}}},
}
const SIGNER_CLIPS := {
	"idle": {"dir": "res://assets/anim/signer/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/signer/idle_e"}, "se": {"dir": "res://assets/anim/signer/idle_se"},
			"s": {"dir": "res://assets/anim/signer/idle_s"}, "ne": {"dir": "res://assets/anim/signer/idle_ne"}, "n": {"dir": "res://assets/anim/signer/idle_n"}}},
	"walk": {
		"dir": "res://assets/anim/signer/walk_e", "fps": 22.222222, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/signer/walk_e"}, "se": {"dir": "res://assets/anim/signer/walk_se"},
			"s": {"dir": "res://assets/anim/signer/walk_s"}, "ne": {"dir": "res://assets/anim/signer/walk_ne"}, "n": {"dir": "res://assets/anim/signer/walk_n"}},
	},
	"attack": {"dir": "res://assets/anim/signer/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/signer/attack_e"}, "se": {"dir": "res://assets/anim/signer/attack_se"}, "s": {"dir": "res://assets/anim/signer/attack_s"}, "ne": {"dir": "res://assets/anim/signer/attack_ne"}, "n": {"dir": "res://assets/anim/signer/attack_n"}}},
	"death": {"dir": "res://assets/anim/signer/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/signer/death_e"}, "se": {"dir": "res://assets/anim/signer/death_se"}, "s": {"dir": "res://assets/anim/signer/death_s"}, "ne": {"dir": "res://assets/anim/signer/death_ne"}, "n": {"dir": "res://assets/anim/signer/death_n"}}},
}
## Юрист (v19, 26.09.2026, B-014): до этого — нотариус, перекрашенный в золото. Свой вид —
## бледный юрист-вампир с портфелем (листы 4×4 nano-banana-pro, позы нотариуса: удар свитком,
## урон, падение с бумагами; tools/sheet_redraw.py). Тайминги 1:1 с нотариусом.
const LAWYER_CLIPS := {
	"idle": {"dir": "res://assets/anim/lawyer/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/lawyer/idle_e"}, "se": {"dir": "res://assets/anim/lawyer/idle_se"},
			"s": {"dir": "res://assets/anim/lawyer/idle_s"}, "ne": {"dir": "res://assets/anim/lawyer/idle_ne"}, "n": {"dir": "res://assets/anim/lawyer/idle_n"}}},
	"walk": {
		"dir": "res://assets/anim/lawyer/walk_e", "fps": 23.529412, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/lawyer/walk_e"}, "se": {"dir": "res://assets/anim/lawyer/walk_se"},
			"s": {"dir": "res://assets/anim/lawyer/walk_s"}, "ne": {"dir": "res://assets/anim/lawyer/walk_ne"}, "n": {"dir": "res://assets/anim/lawyer/walk_n"}},
	},
	"attack": {"dir": "res://assets/anim/lawyer/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/lawyer/attack_e"}, "se": {"dir": "res://assets/anim/lawyer/attack_se"}, "s": {"dir": "res://assets/anim/lawyer/attack_s"}, "ne": {"dir": "res://assets/anim/lawyer/attack_ne"}, "n": {"dir": "res://assets/anim/lawyer/attack_n"}}},
	"death": {"dir": "res://assets/anim/lawyer/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/lawyer/death_e"}, "se": {"dir": "res://assets/anim/lawyer/death_se"}, "s": {"dir": "res://assets/anim/lawyer/death_s"}, "ne": {"dir": "res://assets/anim/lawyer/death_ne"}, "n": {"dir": "res://assets/anim/lawyer/death_n"}}},
}
## Некромант: контакт cast = вылет заклинания (урон его не ждёт), ult ≈ 0.6 с.
const NECRO_CLIPS := {
	"idle": {
		"dir": "res://assets/anim/necromancer/idle", "fps": 10.0, "loop": true,
		"contact_frame": -1
	},
	"cast": {
		"dir": "res://assets/anim/necromancer/cast", "fps": 16.0, "loop": false,
		"contact_frame": 3
	},
	"ult": {
		"dir": "res://assets/anim/necromancer/ult", "fps": 13.0, "loop": false, "contact_frame": 5
	},
	"flinch": {
		"dir": "res://assets/anim/necromancer/flinch", "fps": 12.0, "loop": false,
		"contact_frame": -1
	},
}
## Мимик сохраняет маскировку sleep; пробуждение показывает новый ракурс за прежние 0.4 с.
const MIMIC_CLIPS := {
	"idle": {"dir": "res://assets/anim/mimic/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/mimic/idle_e"}, "se": {"dir": "res://assets/anim/mimic/idle_se"},
			"s": {"dir": "res://assets/anim/mimic/idle_s"}, "ne": {"dir": "res://assets/anim/mimic/idle_ne"}, "n": {"dir": "res://assets/anim/mimic/idle_n"}}},
	"sleep": {
		"dir": "res://assets/anim/mimic/sleep", "fps": 8.0, "loop": true, "contact_frame": -1
	},
	"wake": {"dir": "res://assets/anim/mimic/idle_e", "fps": 2.5, "loop": false, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/mimic/idle_e"}, "se": {"dir": "res://assets/anim/mimic/idle_se"},
			"s": {"dir": "res://assets/anim/mimic/idle_s"}, "ne": {"dir": "res://assets/anim/mimic/idle_ne"}, "n": {"dir": "res://assets/anim/mimic/idle_n"}}},
	"walk": {"dir": "res://assets/anim/mimic/walk_e", "fps": 27.586207, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/mimic/walk_e"}, "se": {"dir": "res://assets/anim/mimic/walk_se"},
			"s": {"dir": "res://assets/anim/mimic/walk_s"}, "ne": {"dir": "res://assets/anim/mimic/walk_ne"}, "n": {"dir": "res://assets/anim/mimic/walk_n"}}},
	"attack": {"dir": "res://assets/anim/mimic/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/mimic/attack_e"}, "se": {"dir": "res://assets/anim/mimic/attack_se"}, "s": {"dir": "res://assets/anim/mimic/attack_s"}, "ne": {"dir": "res://assets/anim/mimic/attack_ne"}, "n": {"dir": "res://assets/anim/mimic/attack_n"}}},
	"death": {"dir": "res://assets/anim/mimic/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/mimic/death_e"}, "se": {"dir": "res://assets/anim/mimic/death_se"}, "s": {"dir": "res://assets/anim/mimic/death_s"}, "ne": {"dir": "res://assets/anim/mimic/death_ne"}, "n": {"dir": "res://assets/anim/mimic/death_n"}}},
}
## Стан босса использует текущий ракурс покоя и процедурные звёзды/качание.
## Холст 320 (v19, было 460): босс ростом 46 × 2,3 ≈ 106 px мира — 159 px на экране 1080p,
## фигура в холсте 250 px; ниже 320 он мылился бы уже на 1440p.
const BOSS_CLIPS := {
	"idle": {"dir": "res://assets/anim/boss/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/boss/idle_e"}, "se": {"dir": "res://assets/anim/boss/idle_se"},
			"s": {"dir": "res://assets/anim/boss/idle_s"}, "ne": {"dir": "res://assets/anim/boss/idle_ne"}, "n": {"dir": "res://assets/anim/boss/idle_n"}}},
	"walk": {"dir": "res://assets/anim/boss/walk_e", "fps": 19.047619, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/boss/walk_e"}, "se": {"dir": "res://assets/anim/boss/walk_se"},
			"s": {"dir": "res://assets/anim/boss/walk_s"}, "ne": {"dir": "res://assets/anim/boss/walk_ne"}, "n": {"dir": "res://assets/anim/boss/walk_n"}}},
	"stun": {"dir": "res://assets/anim/boss/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/boss/idle_e"}, "se": {"dir": "res://assets/anim/boss/idle_se"},
			"s": {"dir": "res://assets/anim/boss/idle_s"}, "ne": {"dir": "res://assets/anim/boss/idle_ne"}, "n": {"dir": "res://assets/anim/boss/idle_n"}}},
	"attack": {"dir": "res://assets/anim/boss/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/boss/attack_e"}, "se": {"dir": "res://assets/anim/boss/attack_se"}, "s": {"dir": "res://assets/anim/boss/attack_s"}, "ne": {"dir": "res://assets/anim/boss/attack_ne"}, "n": {"dir": "res://assets/anim/boss/attack_n"}}},
	"death": {"dir": "res://assets/anim/boss/death_e", "fps": 24.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/boss/death_e"}, "se": {"dir": "res://assets/anim/boss/death_se"}, "s": {"dir": "res://assets/anim/boss/death_s"}, "ne": {"dir": "res://assets/anim/boss/death_ne"}, "n": {"dir": "res://assets/anim/boss/death_n"}}},
}

## Стражник и счетовод: свои направленные мастера, общий контракт CharView.
const GUARD_CLIPS := {
	"idle": {"dir": "res://assets/anim/guard/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/guard/idle_e"}, "se": {"dir": "res://assets/anim/guard/idle_se"},
			"s": {"dir": "res://assets/anim/guard/idle_s"}, "ne": {"dir": "res://assets/anim/guard/idle_ne"}, "n": {"dir": "res://assets/anim/guard/idle_n"}}},
	"walk": {"dir": "res://assets/anim/guard/walk_e", "fps": 30.769231, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/guard/walk_e"}, "se": {"dir": "res://assets/anim/guard/walk_se"},
			"s": {"dir": "res://assets/anim/guard/walk_s"}, "ne": {"dir": "res://assets/anim/guard/walk_ne"}, "n": {"dir": "res://assets/anim/guard/walk_n"}}},
	"attack": {"dir": "res://assets/anim/guard/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/guard/attack_e"}, "se": {"dir": "res://assets/anim/guard/attack_se"}, "s": {"dir": "res://assets/anim/guard/attack_s"}, "ne": {"dir": "res://assets/anim/guard/attack_ne"}, "n": {"dir": "res://assets/anim/guard/attack_n"}}},

	"death": {"dir": "res://assets/anim/guard/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/guard/death_e"}, "se": {"dir": "res://assets/anim/guard/death_se"}, "s": {"dir": "res://assets/anim/guard/death_s"}, "ne": {"dir": "res://assets/anim/guard/death_ne"}, "n": {"dir": "res://assets/anim/guard/death_n"}}},
}
const CLERK_CLIPS := {
	"idle": {"dir": "res://assets/anim/clerk/idle_e", "fps": 1.0, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/clerk/idle_e"}, "se": {"dir": "res://assets/anim/clerk/idle_se"},
			"s": {"dir": "res://assets/anim/clerk/idle_s"}, "ne": {"dir": "res://assets/anim/clerk/idle_ne"}, "n": {"dir": "res://assets/anim/clerk/idle_n"}}},
	"walk": {"dir": "res://assets/anim/clerk/walk_e", "fps": 36.363636, "loop": true, "contact_frame": -1,
		"directions": {"e": {"dir": "res://assets/anim/clerk/walk_e"}, "se": {"dir": "res://assets/anim/clerk/walk_se"},
			"s": {"dir": "res://assets/anim/clerk/walk_s"}, "ne": {"dir": "res://assets/anim/clerk/walk_ne"}, "n": {"dir": "res://assets/anim/clerk/walk_n"}}},
	"attack": {"dir": "res://assets/anim/clerk/attack_e", "fps": 20.0, "loop": false, "contact_frame": 5,
		"directions": {"e": {"dir": "res://assets/anim/clerk/attack_e"}, "se": {"dir": "res://assets/anim/clerk/attack_se"}, "s": {"dir": "res://assets/anim/clerk/attack_s"}, "ne": {"dir": "res://assets/anim/clerk/attack_ne"}, "n": {"dir": "res://assets/anim/clerk/attack_n"}}},
	# Старый hit рисует одну слитную ногу и блокирует замах. Реакция остаётся
	# процедурной (пружина CharView + искры): целая поза и непрерывный шаг.

	"death": {"dir": "res://assets/anim/clerk/death_e", "fps": 15.0, "loop": false, "contact_frame": -1, "hold": true,
		"directions": {"e": {"dir": "res://assets/anim/clerk/death_e"}, "se": {"dir": "res://assets/anim/clerk/death_se"}, "s": {"dir": "res://assets/anim/clerk/death_s"}, "ne": {"dir": "res://assets/anim/clerk/death_ne"}, "n": {"dir": "res://assets/anim/clerk/death_n"}}},
}
const GUARD_CLERK_CANVAS_PX := 224.0  ## v19: как у скелета, 460 → 224 + мипмапы
const GUARD_CLERK_FIGURE_FILL := 0.85
## Все бойцы стоят в одном пространстве договоров. Старые 0.9913 сдвигали
## охрану и аудит вниз примерно на полроста относительно подрядчика.
const GUARD_CLERK_GROUND_OFF := SKELETON_GROUND_OFF

const CHARS := {
	"skeleton": {
		"walk_speed": 70.0,
		"motion": {"bob": 0.0},
		"clips": SKELETON_ANIM_CLIPS,
		"default": "idle",
		"canvas_px": SKELETON_ANIM_CANVAS_PX,
		"figure_fill": SKELETON_ANIM_FIGURE_FILL,
		"ground_off": SKELETON_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/skeleton/idle_e/spr_00.png", "frac": 0.75}},
		"stub": {"spawn": {"kind": "rise", "dur": 0.4}},
		"bob": 0.0,
	},
	## Реестр минимальный: код боя (unit.gd) сейчас зовёт view.setup("skeleton", ...) жёстко —
	## переключение на вид по LegionCfg.UNIT_KINDS остаётся пакету, который вводит guard/clerk
	## в бой (см. отчёт art1). Здесь только данные CharView, чтобы они были готовы заранее.
	"guard": {
		"walk_speed": 55.0,
		"motion": {"bob": 0.0},
		"clips": GUARD_CLIPS,
		"default": "idle",
		"canvas_px": GUARD_CLERK_CANVAS_PX,
		"figure_fill": GUARD_CLERK_FIGURE_FILL,
		"ground_off": GUARD_CLERK_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/guard/idle_e/spr_00.png", "frac": 0.75}},
		"stub": {"spawn": {"kind": "rise", "dur": 0.4}},
		"bob": 0.0,
	},
	"clerk": {
		"walk_speed": 65.0,
		"clips": CLERK_CLIPS,
		"default": "idle",
		"motion": {"bob": 0.0},
		"canvas_px": GUARD_CLERK_CANVAS_PX,
		"figure_fill": GUARD_CLERK_FIGURE_FILL,
		"ground_off": GUARD_CLERK_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/clerk/idle_e/spr_00.png", "frac": 0.75}},
		"stub": {"spawn": {"kind": "rise", "dur": 0.4}},
		"bob": 0.0,
	},
	"necromancer": {
		"clips": NECRO_CLIPS,
		"default": "idle",
		"motion": {"breath": 0.006},
		"canvas_px": V4_CANVAS_PX, "figure_fill": 0.75, "ground_off": ENEMY_GROUND_OFF,
		"fallback": {
			"idle": {"tex": "res://assets/img/necromancer.png", "frac": 0.6767},
			"cast": {"tex": "res://assets/img/necromancer_cast.png", "frac": 0.6262},
			"ult": {"tex": "res://assets/img/necromancer_ult.png", "frac": 0.6995},
		},
		# cast 0.5 с — ровно прежний откат текстуры некроманта (world.gd до F0)
		"stub": {
			"cast": {"kind": "pose", "dur": 0.5},
			"ult": {"kind": "pose", "dur": 0.6},
			"flinch": {"kind": "flash", "dur": 0.2},
		},
		"bob": 0.0,
	},
	"zombie": {
		"walk_speed": 34.0,
		"clips": ZOMBIE_CLIPS, "default": "idle",
		# шарканье: раскачка с ноги на ногу и наклон вперёд. bob 0 у всех персонажей с ногами
		# walk_legs_rig: опускание корпуса на касании уже в кадрах (геометрия опорной ноги), а
		# наложенное сверху удваивало провал — фигура «подпрыгивала» (аудит 29.09)
		"motion": {"bob": 0.0, "sway": 0.04, "lean": 0.035},
		"canvas_px": V4_CANVAS_PX, "figure_fill": 0.75, "ground_off": ENEMY_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/zombie/idle_e/spr_00.png", "frac": 0.75}},
		"stub": ENEMY_STUBS, "bob": ENEMY_BOB,
	},
	"ghost": {
		"clips": GHOST_CLIPS, "default": "idle",
		# парит: шага нет, тень меньше и бледнее
		"motion": {"bob": 0.0, "float": 0.035, "breath": 0.0, "shadow_w": 0.45,
			"shadow_h": 0.14, "shadow_a": 0.22},
		"canvas_px": V4_CANVAS_PX, "figure_fill": 0.77, "ground_off": ENEMY_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/ghost/idle_e/spr_00.png", "frac": 0.75}},
		"stub": ENEMY_STUBS, "bob": ENEMY_BOB,
	},
	"beetle": {
		"walk_speed": 70.0,
		"clips": BEETLE_CLIPS, "default": "idle",
		"motion": {"bob": 0.0, "breath": 0.01, "shadow_w": 0.75},
		"canvas_px": V4_CANVAS_PX, "figure_fill": 0.75, "ground_off": ENEMY_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/beetle/idle_e/spr_00.png", "frac": 0.75}},
		"stub": ENEMY_STUBS, "bob": ENEMY_BOB,
	},
	"signer": {
		"walk_speed": 34.0,
		"clips": SIGNER_CLIPS, "default": "idle",
		# раскачка слабее прежней 0,025: при шаге 2 цикла/с сильная раскачка читалась тряской
		"motion": {"bob": 0.0, "sway": 0.015},
		"canvas_px": V4_CANVAS_PX, "figure_fill": 0.78, "ground_off": ENEMY_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/signer/idle_e/spr_00.png", "frac": 0.75}},
		"stub": ENEMY_STUBS, "bob": ENEMY_BOB,
	},
	"lawyer": {
		"walk_speed": 42.0,
		"clips": LAWYER_CLIPS, "default": "idle",
		"canvas_px": V4_CANVAS_PX, "figure_fill": 0.78, "ground_off": ENEMY_GROUND_OFF,
		"fallback": {"idle": {"tex": "res://assets/anim/lawyer/idle_e/spr_00.png", "frac": 0.75}},
		"stub": ENEMY_STUBS, "bob": ENEMY_BOB,
		"motion": {"bob": 0.0, "sway": 0.012, "lean": 0.03},
	},
	"mimic": {
		"walk_speed": 40.0,
		"clips": MIMIC_CLIPS, "default": "idle",
		"motion": {"bob": 0.0},
		"canvas_px": V4_CANVAS_PX, "figure_fill": 0.75, "ground_off": ENEMY_GROUND_OFF,
		"fallback": {
			"idle": {"tex": "res://assets/anim/mimic/idle_e/spr_00.png", "frac": 0.75},
			"sleep": {"tex": "res://assets/img/mimic.png", "frac": 0.6178},
			"walk": {"tex": "res://assets/img/mimic_awake.png", "frac": 0.6995},
			"wake": {"tex": "res://assets/img/mimic_awake.png", "frac": 0.6995},
		},
		"stub": ENEMY_STUBS, "bob": ENEMY_BOB,
	},
	"boss": {
		"walk_speed": 22.0,
		"clips": BOSS_CLIPS, "default": "idle",
		# тяжёлый шаг: глубже на касании, медленная раскачка
		"motion": {"bob": 0.0, "sway": 0.03, "breath": 0.012, "shadow_w": 0.7,
			"hit_kick": 1.2},
		"canvas_px": 320.0, "figure_fill": 0.78, "ground_off": ENEMY_GROUND_OFF,  # v19: 460 → 320
		# мастер 960 px (не 832) — CharView берёт ширину самой текстуры
		"fallback": {"idle": {"tex": "res://assets/anim/boss/idle_e/spr_00.png", "frac": 0.75}},
		"stub": ENEMY_STUBS, "bob": ENEMY_BOB,
	},
}


# ── Живость и тени (v19, 26.09.2026) ─────────────────────────────────────────
## Чисто вид (CharView._apply_pivot, CharShadows): геймплей эти числа не читает. Доли — от
## body_h. Поправки персонажа — CHARS[id].motion поверх MOTION.
##   bob — опускание корпуса на касании шага (по нарисованному разносу ног, clip.json stride);
##   sway — покачивание с ноги на ногу, рад; lean — наклон вперёд при ходьбе, рад;
##   float — парение (призрак): амплитуда в долях body_h; breath — дыхание в покое, доля высоты;
##   hit_kick — толчок пружины при ударе, 1/с; thud_kick — шлепок тела о землю;
##   spring_k / spring_c — жёсткость и вязкость пружины (≈3,9 Гц, затухание 0,45);
##   flip_time — разворот через сжатие по ширине, с; pop_* — появление с подскоком;
##   corpse_fade / corpse_sink — таяние и оседание трупа в последние секунды перед уборкой;
##   shadow_* — пятно тени под ступнями: ширина, высота (доли body_h), непрозрачность.
const MOTION := {
	"bob": 0.018, "sway": 0.0, "lean": 0.0, "float": 0.0,
	"breath": 0.018, "breath_period": 2.6,
	"hit_kick": 2.2, "thud_kick": 1.6, "spring_k": 600.0, "spring_c": 22.0,
	"flip_time": 0.09, "pop_time": 0.3, "pop_from": 0.45,
	"corpse_fade": 0.8, "corpse_sink": 0.12,
	"shadow_w": 0.62, "shadow_h": 0.2, "shadow_a": 0.42,
}
## Фигура в покое пересчитывает дыхание раз в столько кадров (со сдвигом по экземплярам):
## период 2,6 с и амплитуда меньше пикселя — на глаз не отличить, а кадр дешевле.
const BREATH_EVERY := 3
## Шагающая фигура пересчитывает раскачку раз в столько кадров: смещение опоры 1–2 px на 30 Гц
## при движении самой фигуры на 60 Гц не видно.
const WALK_EVERY := 2
## Крючок удара для слоя эффектов (CharView.react_hit): не больше столько за кадр и не чаще
## раза в столько кадров на вид (= CfgFx.HIT_PER_FRAME и HIT_VIEW_CD 0,1 с при 60 кадр/с).
const HIT_HOOK_PER_FRAME := 4
const HIT_HOOK_VIEW_FRAMES := 6
## Труп врага лежит, пока Дубль-вэ может его поднять, затем уборка (foe.gd is_corpse_done).
const CORPSE_TTL := LegionCfg.HERO_CORPSE_TTL


## Числа живости персонажа: MOTION с поправками CHARS[id].motion.
static func motion_for(char_id: String) -> Dictionary:
	var m := MOTION.duplicate()
	var own: Dictionary = char_def(char_id).get("motion", {}) if CHARS.has(char_id) else {}
	for key in own.keys():
		m[key] = own[key]
	return m


## Описание персонажа; неизвестный — пустое (CharView покажет пустоту и предупредит).
static func char_def(char_id: String) -> Dictionary:
	if CHARS.has(char_id):
		return CHARS[char_id]
	push_warning("CfgAnim: персонаж '%s' не описан в CHARS" % char_id)
	return {}
