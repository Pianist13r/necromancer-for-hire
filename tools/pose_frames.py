#!/usr/bin/env python3
"""
Рендер ПОЗ цикла ходьбы палочным скелетом — вход для ControlNet/pose-подсказки (Э1-c, 2026-08-23).

Идея: генеративная модель не умеет сама разложить движение по равномерным фазам (замер листа
16 кадров: разброс движения между соседними кадрами 1.4-12.4 % вместо ровных 6.25 %). Зато она
хорошо рисует персонажа в ЗАДАННОЙ позе. Значит фазы надо задавать снаружи — этим и занят
этот скрипт.

Откуда берётся правильность: формулы здесь — построчный перенос походки из
`godot/scripts/game/walk_rig.gd` (а туда — из принятого владельцем `walk_proto.gd`). Там
футпланинг доказан замером 0.00 px/кадр, то есть опорная стопа действительно стоит на земле.
От рига берутся ТОЛЬКО КООРДИНАТЫ СУСТАВОВ — как выглядит его «шкура» (меш, текстуры), для
позы совершенно неважно.

Пропорции — наши, чиби (огромная голова, короткие ноги). Это важнее, чем взять готовый
walk-cycle с человеческими пропорциями: подсказка должна соответствовать персонажу.

Запуск (из корня репо):
    python tools/pose_frames.py ПАПКА --frames 16
    ... --style stick   палочный скелет цветными линиями (по мотивам OpenPose)
    ... --style silhouette   заливной силуэт (иногда работает лучше как canny/depth-вход)
    ... --sheet ЛИСТ.png   собрать все позы в один лист
"""
import argparse
import math
import pathlib
import sys

from PIL import Image, ImageDraw

# --- числа походки: ДОСЛОВНО из godot/scripts/game/cfg.gd (WALK_*) ---
STRIDE = 132.0
DUTY = 0.62
FOOT_LIFT = 30.0
PELVIS_BOB = 8.0
IMPACT_DROP = 4.5
BODY_LEAN_DEG = 4.0
BODY_SWAY_DEG = 1.8

# --- геометрия персонажа в координатах мастера (skeleton_rig_v2.json, slice_skeleton_v2.py) ---
PELVIS = (423.8, 584.5)      # точка покоя таза
GROUND_Y = 769.0             # уровень пола
HIP_NEAR_X = 372.0           # бедро ближней ноги (box_origin.x + hip_in_crop.x)
HIP_FAR_X = 475.5            # бедро дальней ноги
NECK_Y = 415.0               # пивот головы (шея)
HEAD_TOP_Y = 62.0            # макушка каски
HEAD_R = 150.0               # радиус головы с каской
THIGH_LEN = 105.0            # длина бедра (hip -> сустав)
BOOT_LEN = 79.0              # длина голени с ботинком (сустав -> подошва)
SHOULDER_Y = 470.0           # линия плеч
ARM_LEN = 105.0

CANVAS = 832


def smoothstep(a: float, b: float, x: float) -> float:
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


def foot_state(phase: float) -> tuple[float, float]:
    """Смещение стопы от нейтрали (x, y) для фазы цикла [0,1) — как в walk_rig.gd."""
    half = STRIDE * DUTY * 0.5
    if phase < DUTY:
        u = phase / DUTY
        return (half + (-half - half) * u, 0.0)
    v = (phase - DUTY) / (1.0 - DUTY)
    eased = smoothstep(0.0, 1.0, v)
    return (-half + (half + half) * eased, -FOOT_LIFT * math.sin(math.pi * v))


def pelvis_offset(t: float) -> float:
    lift = -PELVIS_BOB * (math.sin(2.0 * math.pi * t) ** 2)
    since = (t * 2.0) % 1.0
    return lift + IMPACT_DROP * math.exp(-((since * 7.0) ** 2))


def leg_joints(hip_x: float, phase: float, bob: float) -> tuple[tuple, tuple, tuple]:
    """(бедро, сустав, подошва) в координатах мастера. IK по закону косинусов — как в риге."""
    dx, dy = foot_state(phase)
    hip = (hip_x, PELVIS[1] + bob)
    target = (hip_x + dx, GROUND_Y + dy)

    to_x, to_y = target[0] - hip[0], target[1] - hip[1]
    dist = math.hypot(to_x, to_y)
    dist = max(abs(THIGH_LEN - BOOT_LEN) + 0.5, min(dist, THIGH_LEN + BOOT_LEN - 0.5))
    base_ang = math.atan2(to_y, to_x)
    cos_k = (THIGH_LEN ** 2 + dist ** 2 - BOOT_LEN ** 2) / (2.0 * THIGH_LEN * dist)
    knee_off = math.acos(max(-1.0, min(1.0, cos_k)))
    thigh_ang = base_ang - knee_off        # колено вперёд по ходу движения
    knee = (hip[0] + math.cos(thigh_ang) * THIGH_LEN, hip[1] + math.sin(thigh_ang) * THIGH_LEN)
    return hip, knee, target


# --- цвета конечностей как в OpenPose COCO (по ним обучены pose-ControlNet'ы) ---
OP = {
    "neck_head": (255, 0, 0),   # шея -> нос
    "r_arm": (255, 85, 0),      # правая (ближняя) рука
    "l_arm": (85, 255, 0),      # левая (дальняя) рука
    "shoulders": (255, 0, 170), # линия плеч
    "spine": (170, 0, 255),     # шея -> таз
    "pelvis": (85, 0, 255),     # линия таза
    "r_leg": (0, 0, 255),       # правая (ближняя) нога
    "l_leg": (0, 170, 255),     # левая (дальняя) нога
    "joint": (255, 255, 255),
}


def draw_pose_openpose(t: float) -> Image.Image:
    """Поза в стиле DWPose/OpenPose COCO: тонкие цветные линии, точки суставов,
    без заливного круга головы (она вне обучающего распределения pose-моделей).
    Профиль, лицом вправо; ближняя сторона = правая (R)."""
    im = Image.new("RGB", (CANVAS, CANVAS), (0, 0, 0))
    d = ImageDraw.Draw(im)
    w = max(3, CANVAS // 110)          # толщина линии ~7 px при 832
    jr = w * 1.6                        # радиус точки сустава
    bob = pelvis_offset(t)

    lean = math.radians(BODY_LEAN_DEG + BODY_SWAY_DEG * math.sin(2.0 * math.pi * t))
    pelvis = (PELVIS[0], PELVIS[1] + bob)
    spine_len = PELVIS[1] - NECK_Y
    neck = (pelvis[0] + math.sin(lean) * spine_len, pelvis[1] - math.cos(lean) * spine_len)

    near = leg_joints(HIP_NEAR_X, t % 1.0, bob)
    far = leg_joints(HIP_FAR_X, (t + 0.5) % 1.0, bob)

    def limb(joints, col):
        d.line(list(joints), fill=col, width=w, joint="curve")
        for p in joints:
            d.ellipse([p[0] - jr, p[1] - jr, p[0] + jr, p[1] + jr], fill=OP["joint"])

    limb(far, OP["l_leg"])
    limb(near, OP["r_leg"])

    # таз и позвоночник
    d.line([(HIP_FAR_X, pelvis[1]), (HIP_NEAR_X, pelvis[1])], fill=OP["pelvis"], width=w)
    d.line([pelvis, neck], fill=OP["spine"], width=w)

    # плечи: чуть ниже шеи; у чиби голова большая — плечи опускаем под подбородок
    sh_y = neck[1] + HEAD_R * 0.55
    sh_half = 46.0
    shoulder_r = (neck[0] + sh_half, sh_y)
    shoulder_l = (neck[0] - sh_half, sh_y)
    d.line([shoulder_l, shoulder_r], fill=OP["shoulders"], width=w)

    # руки в противофазе ногам, два звена (плечо -> локоть -> кисть)
    swing = math.sin(2.0 * math.pi * t) * 0.5
    for shoulder, col, sign in ((shoulder_r, OP["r_arm"], 1.0), (shoulder_l, OP["l_arm"], -1.0)):
        ang = math.pi / 2.0 + sign * swing * 0.9
        elbow = (shoulder[0] + math.cos(ang) * ARM_LEN * 0.5, shoulder[1] + math.sin(ang) * ARM_LEN * 0.5)
        ang2 = ang + sign * 0.25
        wrist = (elbow[0] + math.cos(ang2) * ARM_LEN * 0.55, elbow[1] + math.sin(ang2) * ARM_LEN * 0.55)
        limb((shoulder, elbow, wrist), col)

    # голова: НЕ круг, а в стиле OpenPose — линия шея->макушка и две точки глаз
    head_dir = (math.sin(lean), -math.cos(lean))
    nose = (neck[0] + head_dir[0] * HEAD_R * 0.9, neck[1] + head_dir[1] * HEAD_R * 0.9)
    d.line([neck, nose], fill=OP["neck_head"], width=w)
    d.ellipse([nose[0] - jr, nose[1] - jr, nose[0] + jr, nose[1] + jr], fill=OP["joint"])
    # глаза перпендикулярно взгляду (профиль: оба рядом с «носом»)
    perp = (-head_dir[1], head_dir[0])
    for s in (1.0, -1.0):
        eye = (nose[0] + perp[0] * HEAD_R * 0.25 * s + head_dir[0] * HEAD_R * 0.12,
               nose[1] + perp[1] * HEAD_R * 0.25 * s + head_dir[1] * HEAD_R * 0.12)
        d.ellipse([eye[0] - jr * 0.8, eye[1] - jr * 0.8, eye[0] + jr * 0.8, eye[1] + jr * 0.8], fill=OP["joint"])
    return im


def draw_pose(t: float, style: str) -> Image.Image:
    if style == "openpose":
        return draw_pose_openpose(t)
    im = Image.new("RGB", (CANVAS, CANVAS), (0, 0, 0))
    d = ImageDraw.Draw(im)
    bob = pelvis_offset(t)

    # цвета по мотивам OpenPose: разные конечности — разные цвета, так модель точнее читает позу
    col_body = (0, 255, 0)
    col_near = (255, 60, 60)
    col_far = (60, 120, 255)
    col_arm = (255, 200, 0)
    w = 18 if style == "stick" else 46

    near = leg_joints(HIP_NEAR_X, t % 1.0, bob)
    far = leg_joints(HIP_FAR_X, (t + 0.5) % 1.0, bob)

    # дальняя нога рисуется первой — она позади
    for joints, col in ((far, col_far), (near, col_near)):
        hip, knee, foot = joints
        d.line([hip, knee], fill=col, width=w)
        d.line([knee, foot], fill=col, width=w)
        d.ellipse([knee[0] - w * 0.6, knee[1] - w * 0.6, knee[0] + w * 0.6, knee[1] + w * 0.6], fill=col)
        d.ellipse([foot[0] - w * 0.7, foot[1] - w * 0.7, foot[0] + w * 0.7, foot[1] + w * 0.7], fill=col)

    # корпус: сначала СЧИТАЕМ наклон и шею (нужны и голове, и торсу, и рукам)
    lean = math.radians(BODY_LEAN_DEG + BODY_SWAY_DEG * math.sin(2.0 * math.pi * t))
    pelvis_pt = (PELVIS[0], PELVIS[1] + bob)
    spine_len = PELVIS[1] - NECK_Y
    neck = (pelvis_pt[0] + math.sin(lean) * spine_len, pelvis_pt[1] - math.cos(lean) * spine_len)

    # голова — большой круг (чиби-пропорция); рисуется ПЕРЕД торсом и руками,
    # иначе шея/плечи/руки тонут в заливке головы и ControlNet не видит конечности
    head_c = (neck[0] + math.sin(lean) * HEAD_R * 0.7, neck[1] - HEAD_R * 0.55)
    d.ellipse(
        [head_c[0] - HEAD_R, head_c[1] - HEAD_R, head_c[0] + HEAD_R, head_c[1] + HEAD_R],
        outline=col_body,
        width=w,
    )

    # торс: таз -> шея, поверх головы — шея читается линией
    d.line([pelvis_pt, neck], fill=col_body, width=w)
    d.line([(pelvis_pt[0] - 40, pelvis_pt[1]), (pelvis_pt[0] + 40, pelvis_pt[1])], fill=col_body, width=w)

    # руки махают в противофазе ногам; плечо опущено ПОД голову (у чиби голова
    # перекрывает настоящую линию плеч — руки должны читаться снаружи круга головы)
    swing = math.sin(2.0 * math.pi * t) * 0.5
    shoulder = (neck[0], neck[1] + HEAD_R * 0.85)
    for sign, col in ((1.0, col_arm), (-1.0, col_arm)):
        ang = math.pi / 2.0 + sign * swing
        hand = (shoulder[0] + math.cos(ang) * ARM_LEN * sign, shoulder[1] + math.sin(ang) * ARM_LEN)
        d.line([shoulder, hand], fill=col, width=int(w * 0.8))
        d.ellipse([hand[0] - w * 0.5, hand[1] - w * 0.5, hand[0] + w * 0.5, hand[1] + w * 0.5], fill=col)
    return im


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--frames", type=int, default=16)
    ap.add_argument("--style", choices=["stick", "silhouette", "openpose"], default="stick")
    ap.add_argument("--sheet", default="")
    args = ap.parse_args()

    out = pathlib.Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    ims = []
    for i in range(args.frames):
        t = i / args.frames
        im = draw_pose(t, args.style)
        im.save(out / f"pose_{i:02d}.png")
        ims.append(im)
    print(f"поз сохранено: {len(ims)} → {out}")

    if args.sheet:
        cols = min(8, len(ims))
        rows = (len(ims) + cols - 1) // cols
        sheet = Image.new("RGB", (CANVAS * cols, CANVAS * rows), (0, 0, 0))
        for i, im in enumerate(ims):
            sheet.paste(im, ((i % cols) * CANVAS, (i // cols) * CANVAS))
        sheet.save(args.sheet)
        print(f"лист поз: {args.sheet}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
