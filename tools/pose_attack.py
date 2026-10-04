#!/usr/bin/env python3
"""pose_attack.py — авторские OpenPose-позы для удара киркой (одноразовый резкий жест).

Почему не Civitai: там только ходьба/бег, замаха киркой нет. Хореография задаётся
параметрически: наклон корпуса, присед, угол рук (обе руки на рукояти кирки).
Стиль отрисовки — как draw_pose_openpose в pose_frames.py (COCO-цвета, тонкие
линии, белые суставы) — InstantX Union обучен на таких картах.

Фазы (8 кадров): ready -> anticipation -> windup -> swing -> CONTACT -> follow -> recover -> ready
Кадр контакта — индекс 4 (задублировано в anim_config.json: animations.attack.contact_frame).

Запуск: python tools/pose_attack.py ПАПКА [--sheet ЛИСТ.png]
"""
import argparse
import math
import pathlib
import sys

from PIL import Image, ImageDraw

# холст и геометрия — те же, что в pose_frames.py (координаты мастера skeleton_v2)
CANVAS = 832
PELVIS = (423.8, 584.5)
GROUND_Y = 769.0
HIP_NEAR_X = 372.0
HIP_FAR_X = 475.5
NECK_Y = 415.0
HEAD_R = 150.0
THIGH_LEN = 105.0
BOOT_LEN = 79.0

OP = {
    "neck_head": (255, 0, 0), "r_arm": (255, 85, 0), "l_arm": (85, 255, 0),
    "shoulders": (255, 0, 170), "spine": (170, 0, 255), "pelvis": (85, 0, 255),
    "r_leg": (0, 0, 255), "l_leg": (0, 170, 255), "joint": (255, 255, 255),
}

# хореография: (наклон корпуса°, присед px, угол рук° от вертикали-вверх по часовой, размах рук 0..1)
# 0° = руки вверх над головой, 180° = руки вниз-вперёд (контакт с землёй)
FRAMES = [
    ("ready",        4,   0, 140, 0.60),
    ("anticipation", -6, 12, 165, 0.50),
    ("windup",      -14,  4, -25, 1.00),
    ("swing",        8,  4,  40, 0.90),
    ("contact",     32,  18, 150, 1.00),   # КАДР КОНТАКТА (индекс 4)
    ("follow",      36,  22, 172, 0.95),
    ("recover",     14,  8, 105, 0.70),
    ("ready2",       4,  0, 140, 0.60),
]
CONTACT_INDEX = 4


def leg_joints(hip_x: float, crouch: float, bend: float) -> tuple[tuple, tuple, tuple]:
    """Стоячая нога с лёгким сгибом; присед опускает таз и сгибает колено вперёд."""
    hip = (hip_x, PELVIS[1] + crouch)
    foot = (hip_x, GROUND_Y)
    to_x, to_y = foot[0] - hip[0], foot[1] - hip[1]
    dist = min(math.hypot(to_x, to_y), THIGH_LEN + BOOT_LEN - 0.5)
    base_ang = math.atan2(to_y, to_x)
    cos_k = (THIGH_LEN ** 2 + dist ** 2 - BOOT_LEN ** 2) / (2.0 * THIGH_LEN * dist)
    knee_off = math.acos(max(-1.0, min(1.0, cos_k)))
    thigh_ang = base_ang - knee_off * bend
    knee = (hip[0] + math.cos(thigh_ang) * THIGH_LEN, hip[1] + math.sin(thigh_ang) * THIGH_LEN)
    return hip, knee, foot


def draw_frame(lean_deg: float, crouch: float, arm_deg: float, reach: float) -> Image.Image:
    im = Image.new("RGB", (CANVAS, CANVAS), (0, 0, 0))
    d = ImageDraw.Draw(im)
    w = max(3, CANVAS // 110)
    jr = w * 1.6

    lean = math.radians(lean_deg)
    pelvis = (PELVIS[0], PELVIS[1] + crouch)
    spine_len = PELVIS[1] - NECK_Y
    neck = (pelvis[0] + math.sin(lean) * spine_len, pelvis[1] - math.cos(lean) * spine_len)

    def limb(joints, col):
        d.line(list(joints), fill=col, width=w, joint="curve")
        for p in joints:
            d.ellipse([p[0] - jr, p[1] - jr, p[0] + jr, p[1] + jr], fill=OP["joint"])

    limb(leg_joints(HIP_FAR_X, crouch, 1.0), OP["l_leg"])
    limb(leg_joints(HIP_NEAR_X, crouch, 1.0), OP["r_leg"])
    d.line([(HIP_FAR_X, pelvis[1]), (HIP_NEAR_X, pelvis[1])], fill=OP["pelvis"], width=w)
    d.line([pelvis, neck], fill=OP["spine"], width=w)

    sh_y = neck[1] + HEAD_R * 0.55
    shoulder_r = (neck[0] + 46.0, sh_y)
    shoulder_l = (neck[0] - 46.0, sh_y)
    d.line([shoulder_l, shoulder_r], fill=OP["shoulders"], width=w)

    # обе руки держат рукоять: от плеч сходятся к точке хвата
    arm_ang = math.radians(arm_deg)          # 0 = вертикально вверх, по часовой
    grip = (neck[0] + math.sin(lean) * HEAD_R * 0.4 + math.sin(arm_ang) * ARM_REACH * reach,
            neck[1] - math.cos(arm_ang) * ARM_REACH * reach)
    for shoulder, col in ((shoulder_r, OP["r_arm"]), (shoulder_l, OP["l_arm"])):
        mid = ((shoulder[0] + grip[0]) / 2, (shoulder[1] + grip[1]) / 2 + 14)
        limb((shoulder, mid, grip), col)

    head_dir = (math.sin(lean), -math.cos(lean))
    nose = (neck[0] + head_dir[0] * HEAD_R * 0.9, neck[1] + head_dir[1] * HEAD_R * 0.9)
    d.line([neck, nose], fill=OP["neck_head"], width=w)
    d.ellipse([nose[0] - jr, nose[1] - jr, nose[0] + jr, nose[1] + jr], fill=OP["joint"])
    perp = (-head_dir[1], head_dir[0])
    for s in (1.0, -1.0):
        eye = (nose[0] + perp[0] * HEAD_R * 0.25 * s + head_dir[0] * HEAD_R * 0.12,
               nose[1] + perp[1] * HEAD_R * 0.25 * s + head_dir[1] * HEAD_R * 0.12)
        d.ellipse([eye[0] - jr * 0.8, eye[1] - jr * 0.8, eye[0] + jr * 0.8, eye[1] + jr * 0.8], fill=OP["joint"])
    return im


ARM_REACH = 260.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--sheet", default="")
    args = ap.parse_args()
    out = pathlib.Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    ims = []
    for i, (label, lean, crouch, arm, reach) in enumerate(FRAMES):
        im = draw_frame(lean, crouch, arm, reach)
        im.save(out / f"attack_{i:02d}_{label}.png")
        ims.append(im)
        mark = " <== КОНТАКТ" if i == CONTACT_INDEX else ""
        print(f"{i}: {label}{mark}")
    if args.sheet:
        cols = len(ims)
        sheet = Image.new("RGB", (CANVAS * cols, CANVAS), (0, 0, 0))
        for i, im in enumerate(ims):
            sheet.paste(im, (i * CANVAS, 0))
        sheet.save(args.sheet)
        print(f"лист: {args.sheet}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
