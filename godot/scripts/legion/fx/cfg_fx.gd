class_name CfgFx
extends RefCounted
##
## Все числа слоя эффектов (LegionFx). Координаты и размеры — в пикселях мира 1280×720, время —
## реальные секунды (эффекты — чистый вид, симуляцию не трогают и её часов не слушают).
##
## Вкус (Игорь 26.09.2026: «красивых и со вкусом»): коротко, мягко, читаемо. Эффект не должен
## закрывать бойцов и руны — поэтому прозрачность умеренная, размеры маленькие, жизнь короткая.
## Текстуры Kenney — 512×512: слой один раз уменьшает их до TEX_SMALL/TEX_BIG (без мип-карт
## крупная текстура в 15 px рябит, и телефону легче читать маленькую).
##

## ── Один цвет — один смысл (slow/vfx-clarity 29.09) ─────────────────────────
## Игорь 29.09: «такая же красная печать у нас вроде бы как дамага не получает, получается
## несогласованность в интерфейсе» и «каша из эффектов… непонятно, что как нажать». Метки боя
## делятся по смыслу; у смысла — свой цвет, и чужой смысл этот цвет не берёт (тест
## legion_vfx_clarity_test сверяет таблицу и живые константы меток).
##   угроза  — сюда ударит враг / твой участок рвут: печать нотариуса, таран Прораба, Юрист,
##             давка, «стена»;
##   шанс    — щёлкни ПКМ сейчас: золотой участок, «Точно!», зона рогатки; золото же у элитных
##             (выгода: души ×4) и у «Золотого пера» (оно про «Точно!»);
##   оглушён — враг не бьёт: орбита над головой, круги оглушения артефактов;
##   простой — свой боец без дела: пузырь «Zz» / «…» (подсказка, а не тревога — тихий цвет).
## Артефакты рисуют свои метки цветом артефакта (item_db look), но не цветом угрозы и не
## четырёхлучевой искрой шанса.
const C_DANGER := Color(1.0, 0.3, 0.22)
const C_CHANCE := Color(1.0, 0.84, 0.3)
const C_STUN := Color(0.62, 0.86, 1.0)
const C_IDLE := Color(0.78, 0.74, 0.66)
## PvP: чей — овал стороны 0 и ромб стороны 1 под бойцом и постройкой (PvpRules.draw_marker).
## Форма различает и без цвета; цвет — не голубой оглушения и не бежевый простоя (B-250).
const C_SIDE_0 := Color(0.3, 0.95, 0.72)
const C_SIDE_1 := Color(1.0, 0.45, 0.85)
## «Сбор» (R) — приказ некроманта своим: сиреневый, цвет некроманта. Был голубым, ΔE 0,020 до
## оглушения — круг «Сбора» на земле не отличить от кругов оглушения артефактов (B-272, D-0930-10).
## Тон дальше 25° от соседей (маджента стороны 1 — ближайшая, ~37°).
const C_RALLY := Color(0.66, 0.46, 0.92)
const MEANING_COLOR := {
	&"danger": C_DANGER, &"chance": C_CHANCE, &"stun": C_STUN, &"idle": C_IDLE,
	&"side_0": C_SIDE_0, &"side_1": C_SIDE_1, &"rally": C_RALLY,
}
## Ближе этого (ΔE в OKLab, как legion_lines_test) цвета разных смыслов глаз путает на карте.
const MEANING_MIN_DE := 0.12

## Общий потолок живых частиц событий; при переполнении новые отбрасываются (старые не рвём —
## оборванная на середине частица заметнее, чем не родившаяся).
const CAP := 500
## Отдельный потолок фоновой жизни карт: фон не должен съесть место у событий боя.
const AMBIENT_CAP := 160
const TEX_SMALL := 64
const TEX_BIG := 128
## Порог альфы, по которому текстура обрезается до видимого пятна (LegionFx._crop_visible).
const TEX_CROP_ALPHA := 0.06

## Палитра игры: фиолетово-бирюзовая некромантия, тёплые свечи, зелёное зелье Котла.
## Пыль — цвет земли под ногами (фон карты), но контрастнее: на светлой дороге и плитах —
## темнее, на тёмной траве — светлее к кремовому. Одного цвета на всё нет: кремовая тонет на
## дороге, землистая — в траве (кадры приёмки r6–r7). Без фона карты — C_DUST.
const C_DUST := Color(0.8, 0.74, 0.64)
const DUST_LIGHT := Color(0.97, 0.94, 0.87)
const DUST_LUM_SPLIT := 0.5
const DUST_DARKEN := 0.42
const DUST_LIGHTEN := 0.6
const GROUND_SAMPLE := Vector2i(160, 90)    ## фон карты ужимается до этого для выборки цвета
const C_SOUL := Color(0.56, 0.46, 1.0)
const C_SOUL_CORE := Color(0.82, 0.92, 1.0)
const C_BONE := Color(0.96, 0.94, 0.86)
const C_SPAWN := Color(0.4, 0.95, 0.5)
const C_HIT := Color(1.0, 0.8, 0.3)
const C_POTION := Color(0.5, 0.95, 0.3)
const C_GATE := Color(1.0, 0.24, 0.14)
const C_BREACH := Color(1.0, 0.45, 0.2)
const C_PAPER := Color(0.95, 0.9, 0.78)
const C_SMOKE_DARK := Color(0.1, 0.07, 0.12)

# ── пыль (общая для смертей, рождения, натиска, прорыва) ─────────────────────
const DUST_ALPHA := 0.5
const DUST_SIZE := Vector2(12.0, 30.0)      ## от → до
const DUST_ASPECT := 0.62                   ## пыль стелется: эллипс ниже, чем шире
const DUST_LIFE := Vector2(0.45, 0.65)
const DUST_SPEED := 30.0
const DUST_RISE := 7.0
const DUST_DRAG := 3.0

# ── смерть врага: пыль у ступней + душа ──────────────────────────────────────
const FOE_DUST_N := 4
const SOUL_LIFT := 0.4                      ## доля роста тела — откуда душа выходит
const SOUL_SIZE := Vector2(24.0, 15.0)
const SOUL_CORE := Vector2(8.0, 4.5)
const SOUL_ALPHA := 0.7
const SOUL_CORE_ALPHA := 0.9
const SOUL_RISE := 36.0
const SOUL_LIFE := 1.0
const SOUL_SWAY := 5.0                      ## амплитуда покачивания, px
const SOUL_SWAY_F := 5.0                    ## рад/с
const BOSS_SCALE := 2.2
const BOSS_DUST_N := 7

# ── смерть бойца-скелета: косточки + пыль ────────────────────────────────────
const BONES_N := Vector2i(4, 6)
const BONE_LEN := Vector2(9.0, 12.0)
const BONE_ASPECT := 0.42
const BONE_VX := Vector2(35.0, 85.0)
const BONE_VY := Vector2(90.0, 150.0)
const BONE_GRAV := 430.0
const BONE_SPIN := 9.0
const BONE_LIFE := 0.8
const BONE_BOUNCE := 0.35                   ## доля скорости после отскока
const BONE_FRICTION := 0.55
const BONE_GROUND_JITTER := Vector2(-4.0, 6.0)
const UNIT_DUST_N := 2

# ── рождение бойца: зелёное кольцо у ног + пыль ─────────────────────────────
const SPAWN_RING := Vector2(16.0, 48.0)
const SPAWN_RING_ASPECT := 0.45             ## кольцо лежит на земле
const SPAWN_RING_ALPHA := 1.0
const SPAWN_LIFE := 0.4
const SPAWN_DUST_N := 2

# ── удар по персонажу: искра-вспышка ────────────────────────────────────────
const HIT_SIZE := Vector2(20.0, 26.0)
const HIT_LIFE := Vector2(0.12, 0.18)
const HIT_ALPHA := 0.95
const HIT_LIFT := Vector2(0.4, 0.65)        ## высота на теле, доля роста
const HIT_SPREAD := 0.18                    ## разброс вбок, доля роста
const HIT_PER_FRAME := 4                    ## в большой драке — не мельтешение
const HIT_VIEW_CD := 0.1                    ## не чаще раза в N с на один вид
const HIT_FORGET := 2.0                     ## чистка журнала ударов, с

# ── натиск: клубы пыли у ног бегущих ────────────────────────────────────────
const CHARGE_SCAN := 0.1                    ## опрос бойцов раз в N с, не каждый кадр
const CHARGE_RATE := 2.2                    ## клубов в секунду на бойца
const CHARGE_DUST_SCALE := 0.8

# ── Котёл: брызги при ударе, тихое бульканье ────────────────────────────────
const CAULDRON_MOUTH := Vector2(0.0, -57.0) ## от точки Котла до поверхности зелья
const CAULDRON_MOUTH_W := 14.0
const CAULDRON_HIT_CD := 0.12
const DROPS_N := Vector2i(7, 10)
const DROP_SIZE := Vector2(6.0, 9.0)
const DROP_VX := 75.0
const DROP_VY := Vector2(110.0, 170.0)
const DROP_GRAV := 380.0
const DROP_LIFE := Vector2(0.55, 0.8)
const DROP_ALPHA := 0.85
const DROP_GROUND := Vector2(-6.0, 10.0)    ## уровень земли у Котла для капель
const SPLASH_SIZE := Vector2(20.0, 44.0)
const SPLASH_ALPHA := 0.45
const SPLASH_LIFE := 0.3
const BUBBLE_RATE := 1.3
const BUBBLE_SIZE := Vector2(3.0, 5.5)
const BUBBLE_RISE := Vector2(10.0, 18.0)
const BUBBLE_LIFE := Vector2(0.9, 1.4)
const BUBBLE_ALPHA := 0.35

# ── начало волны: красный отсвет у ворот ────────────────────────────────────
const GATE_INSET := 34.0                    ## не ближе к краю экрана, px
const GATE_MARGIN := 18.0                   ## не ближе к краю экрана
const GATE_MAX_INSET := 420.0               ## дальше по дороге от начала не уходим
const GATE_STEP := 12.0
const GATE_SIZE := 120.0
const GATE_CORE := 54.0
const GATE_ALPHA := 0.42
const GATE_CORE_ALPHA := 0.35
const GATE_LIFE := 1.3

# ── прорыв: пыль кольцом + оранжевая вспышка ────────────────────────────────
const BREACH_DUST_N := 8
const BREACH_DUST_SPEED := 46.0
const BREACH_FLASH := Vector2(26.0, 70.0)
const BREACH_FLASH_ALPHA := 0.5
const BREACH_LIFE := 0.55

# ── конец боя ───────────────────────────────────────────────────────────────
const PAPER_TIME := 2.6                     ## сколько секунд сыплются листки
const PAPER_RATE := 13.0
const PAPER_SIZE := Vector2(8.0, 11.0)
const PAPER_ASPECT := 1.3
const PAPER_FALL := Vector2(38.0, 64.0)
const PAPER_SWAY := Vector2(12.0, 22.0)
const PAPER_SWAY_F := Vector2(1.8, 3.0)
const PAPER_SPIN := 2.4
const PAPER_LIFE := Vector2(3.0, 4.2)
const PAPER_ALPHA := 0.9
const SMOKE_TIME := 2.6
const SMOKE_RATE := 9.0
const SMOKE_SIZE := Vector2(28.0, 90.0)
const SMOKE_RISE := Vector2(16.0, 30.0)
const SMOKE_LIFE := Vector2(2.2, 3.0)
const SMOKE_ALPHA := 0.5

# ── фоновая жизнь карт (assets/legion/ambient/<map>.json) ───────────────────
## Своя папка, не папка карт: Campaign.maps() берёт в кампанию любой *.json из MAPS_DIR,
## и файл фона стал бы «картой» без имени (падал legion_cutscene_flow_test).
const AMBIENT_DIR := "res://assets/legion/ambient/"
const GLOW_ALPHA := 0.4
const GLOW_FREQ := Vector2(2.3, 5.9)        ## две синусоиды мерцания, рад/с
const GLOW_SIZE_WOBBLE := 0.06
const EMBER_SIZE := Vector2(6.0, 2.5)
const EMBER_RISE := Vector2(14.0, 26.0)
const EMBER_LIFE := Vector2(1.4, 2.6)
const EMBER_SWAY := 3.0
const EMBER_ALPHA := 0.95
const FOG_LIFE := Vector2(10.0, 16.0)
const FOG_SIZE := Vector2(0.8, 1.25)        ## доля меньшей стороны прямоугольника
const FOG_SIZE_MAX := 260.0
const FOG_GROW := 1.15
const WISP_SIZE := 15.0
const WISP_CORE := 3.5
const WISP_ALPHA := 0.7
const WISP_LIFE := Vector2(6.0, 9.0)
const WISP_SWAY := Vector2(14.0, 34.0)
const WISP_SWAY_F := Vector2(0.45, 0.9)
const WISP_DRIFT := 4.0
const WATER_SIZE := Vector2(7.0, 12.0)
const WATER_LIFE := Vector2(0.35, 0.7)
const WATER_ALPHA := 0.7
const WATER_TRIES := 8                      ## попыток найти точку внутри многоугольника

# ══ Импакт способностей и натиска (LegionImpactFx, slow/impact 26.09) ══════════
## Игорь 26.09: «у скиллов, особенно у молнии, нужны сильно более интересные анимации, чтобы
## от них импакт чувствовался». Всё — чистый вид: урон и эффекты боя прежние и мгновенные,
## задержки здесь — только у картинки.
const IMPACT_CAP := 320                     ## свой потолок частиц: импакт не ест место у фона/боя
const IMPACT_DECALS_CAP := 24               ## пятна и рунные круги на земле
const IMPACT_BOLTS_CAP := 24                ## каналы молний, включая микродуги «под током»

# ── Ку: канал молнии ────────────────────────────────────────────────────────
const BOLT_HOP_DELAY := 0.06                ## картинка разряда идёт по цепи с задержкой на прыжок
const BOLT_LIVE := 0.2                      ## сколько канал мерцает, пересобираясь
const BOLT_RESHAPE := 0.04                  ## раз в столько секунд форма новая
const BOLT_FADE := 0.16                     ## затухание после мерцания
const BOLT_FLICKER := 0.62                  ## яркость «тёмной» фазы мерцания (не ноль: не строб)
const BOLT_DEPTH := Vector2i(4, 6)          ## уровней деления средней точкой (от длины прыжка)
const BOLT_SEG_PX := 14.0                   ## делим, пока звено длиннее этого
const BOLT_JAG := 0.2                       ## смещение первого уровня, доля длины
const BOLT_JAG_MAX := 55.0                  ## и не больше, px (длинный прыжок от руки — не прямой)
const BOLT_BRANCHES := Vector2i(2, 3)
const BOLT_BRANCH_LEN := Vector2(0.22, 0.42) ## доля длины прыжка
const BOLT_BRANCH_MAX := 64.0
const BOLT_BRANCH_ANGLE := Vector2(0.35, 0.8) ## отклонение от канала, рад
const BOLT_BRANCH_DEPTH := 2
## Слои канала. Игра светлая: аддитив на светлой дороге выгорает в белую «трубу» (кадры v1),
## поэтому цвет молнии держит обычное смешение — синий ореол и кант, белая сердцевина, — а
## аддитивное свечение узкое и слабое, для искры на тёмной траве.
const BOLT_W_HALO := 18.0
const C_BOLT_HALO := Color(0.3, 0.5, 1.0, 0.22)
const BOLT_W_MID := 5.0                     ## синий кант — держит молнию на светлой дороге
const C_BOLT_MID := Color(0.32, 0.52, 1.0, 0.95)
const BOLT_W_CORE := 2.2                    ## белая сердцевина
const BOLT_W_GLOW := 9.0                    ## аддитивное свечение цвета Ку
const BOLT_A_GLOW := 0.3
const BOLT_BRANCH_W := 0.5                  ## ответвления тоньше
const BOLT_HAND := Vector2(10.0, 0.9)       ## x — к цели от центра, px; y — доля роста некроманта
const BOLT_CHEST := 0.48                    ## куда бьёт: доля роста цели от ступней
const BOLT_FLARE := 30.0                    ## вспышка на кончике у руки и на груди цели
const BOLT_FLARE_A := 0.85

# ── Ку: удар по цели ────────────────────────────────────────────────────────
const ZAP_FLASH := 0.12                     ## белая вспышка фигуры, с
const ZAP_SPARKS := 9
const ZAP_SPARK_SPEED := Vector2(120.0, 270.0)
const ZAP_SPARK_GRAV := 520.0
const ZAP_SPARK_LIFE := Vector2(0.16, 0.3)
const ZAP_SPARK_W := 5.0
const ZAP_SPARK_ASPECT := 3.4               ## искра — чёрточка вдоль полёта
const ZAP_RING := Vector2(10.0, 58.0)
const ZAP_RING_ASPECT := 0.45
const ZAP_RING_LIFE := 0.24
const C_ZAP_RING := Color(0.45, 0.65, 1.0)
const ZAP_GLOW := 78.0                      ## отсвет земли
const ZAP_GLOW_A := 0.55
const ZAP_GLOW_LIFE := 0.32
const SCORCH_SIZE := Vector2(42.0, 50.0)
const SCORCH_ASPECT := 0.42
const SCORCH_LIFE := Vector2(3.0, 4.0)
const SCORCH_A := 0.85
const C_SCORCH := Color(0.09, 0.06, 0.12)
const ZAP_ELECTRIFY := 0.4                  ## «под током» после удара Ку, с
const BOLT_SHAKE := 4.0                     ## тряска: база + за каждую цель
const BOLT_SHAKE_PER_HOP := 1.6
const BOLT_SHAKE_DUR := 0.22
const BOLT_SCREEN_A := 0.1                  ## цветная вспышка экрана (≤0,12 — не ослепляет)
const BOLT_SCREEN_LIFE := 0.09
const BOLT_HITSTOP := 0.045                 ## стоп-кадр мира, реальные секунды

# ── «Под током» (electrify) ────────────────────────────────────────────────
const ELEC_DOT_RATE := 30.0                 ## искорок в секунду на фигуру
const ELEC_DOT_SIZE := Vector2(4.0, 8.0)
const ELEC_DOT_LIFE := Vector2(0.07, 0.14)
const ELEC_ARC_EVERY := 0.09                ## микродуга по телу
const ELEC_ARC_LIFE := 0.07
const ELEC_ARC_LEN := Vector2(0.25, 0.45)   ## доля роста
const ELEC_FLICK := 0.1                     ## мигание фигуры
const C_ELEC_FLASH := Color(1.5, 1.8, 2.6)

# ── Дубль-вэ: подъём ────────────────────────────────────────────────────────
const RAISE_RUNE := Vector2(30.0, 92.0)
const RAISE_RUNE_ASPECT := 0.42
const RAISE_RUNE_LIFE := 0.95
const RAISE_RUNE_SPIN := 2.2
const RAISE_COLUMN := Vector2(40.0, 48.0)   ## ширина столба
const RAISE_COLUMN_ASPECT := 2.6            ## высота = ширина × это
const RAISE_COLUMN_LIFE := 0.6
const RAISE_COLUMN_A := 0.8
const RAISE_CORE_RISE := 70.0
const RAISE_MOTES := 16
const RAISE_MOTE_RISE := Vector2(90.0, 170.0)
const RAISE_MOTE_LIFE := Vector2(0.55, 0.9)
const RAISE_MOTE_SIZE := Vector2(5.0, 9.0)
const RAISE_GLOW := 96.0
const RAISE_GLOW_A := 0.6
const RAISE_SQUASH := Vector2(1.35, 0.55)   ## рывок: сплющен → вытянут → норма
const RAISE_STRETCH := Vector2(0.85, 1.22)
const RAISE_SQUASH_T := 0.08
const RAISE_SETTLE_T := 0.32

# ── Е: Аврал ────────────────────────────────────────────────────────────────
const RUSH_WAVE_LIFE := 0.42
const RUSH_WAVE_A := 0.9
const RUSH_WAVE2_LIFE := 0.6                ## вторая, мягкая и медленнее
const RUSH_WAVE2_A := 0.45
const RUSH_WAVE_W := 10.0                   ## толщина фронта волны Е (дуга с кантом, B-066)
const RUSH_FLASH := 110.0                   ## вспышка-удар в точке каста
const RUSH_FLASH_A := 0.6
const RUSH_FLASH_LIFE := 0.2
const RUSH_DUST_RIM := 28                   ## пыль поднимается там, где прошла волна
const RUSH_DUST_MID := 12
const RUSH_DUST_SCALE := 1.35
const RUSH_DUST_A := 0.72
const RUSH_DUST_OUT := 36.0
const RUSH_GLOW := 130.0
const RUSH_GLOW_A := 0.5
const HASTE_SCAN := 0.08                    ## опрос ускоренных (Аврал накрывает десятки бойцов)
const HASTE_MIN_MOVE := 1.2                 ## px за опрос — иначе боец стоит, шлейфа нет
const HASTE_STREAK_W := 9.0
const HASTE_STREAK_ASPECT := 4.5
const HASTE_STREAK_LIFE := 0.26
const HASTE_STREAK_A := 0.85
const HASTE_STREAK_BACK := 0.45             ## позади бойца на долю роста
const HASTE_MODULATE := Color(1.18, 1.03, 0.8) ## тёплый отлив ускоренного

# ── натиск и «Точно!» ───────────────────────────────────────────────────────
const CHARGE_FX_CD := 0.05                  ## чаще — только кольцо (в свалке не каша)
## Ударные кольца дугами (_shock): тёмный кант под цветом — светлая дорога его не съедает.
const SHOCK_CAP := 24
const SHOCK_POINTS := 48
const SHOCK_KANT_W := 5.0                   ## кант шире цвета на столько px
const SHOCK_KANT_A := 0.55
const C_SHOCK_KANT := Color(0.16, 0.08, 0.04)
const CHARGE_RING := Vector2(12.0, 58.0)    ## диаметр от → до
const CHARGE_RING_W := 4.0
const PERFECT_RING_W := 6.5
const CHARGE_FLASH := 46.0                  ## вспышка-удар на первом касании залпа
const CHARGE_FLASH_A := 0.55
const CHARGE_FLASH_LIFE := 0.12
const CHARGE_RING_LIFE := 0.26
const CHARGE_SPARKS := 4
const CHARGE_DUST := 3
const C_CHARGE := Color(1.0, 0.7, 0.38)      ## тёплый: светлый кремовый тонул в дороге (кадры v1)
const CHARGE_HIT_DUST_SCALE := 1.3
const PERFECT_RING := Vector2(14.0, 76.0)
const PERFECT_SPARKS := 9
const PERFECT_DUST := 6
const PERFECT_FLASH := 74.0
const PERFECT_FLASH_A := 0.6
const PERFECT_FLASH_LIFE := 0.18
const PERFECT_EXTRA_SHAKE := 3.0
const PERFECT_EXTRA_SHAKE_T := 0.1
