#!/usr/bin/env python3
"""
Нарезка НОВОГО мастера скелета (Э1, NEXT_SESSION_PROMPT.md v7): персонаж перегенерирован
на MostAI (nano-banana-pro) 3/4-ракурсом, обе ноги близкого размера, точка сгиба — по
серой полоске на щиколотке (НЕ вогнутая выемка, как была у старого ботинка — именно
вогнутость рвала меш, см. DEBT.md/cfg.gd RIG_BONE_SOFT_ZONE).

Боксы частей подобраны глазами по координатной сетке (см. сессию), пивоты — тем же
методом alpha_centre, что в slice_walk_parts.py/slice_walk_whole.py: ось сустава — центр
непрозрачной части СТРОКИ, а не координата с картинки на глаз.

Источник: assets/img/skeleton_v2.png (832x832, прозрачный фон).
Выход: godot/assets/parts/*_v2.png + skeleton_rig_v2.json + leg_meta_v2.json

Запуск (из корня репо):  python tools/slice_skeleton_v2.py
"""
import json
import pathlib

from PIL import Image

SRC = pathlib.Path("assets/img/skeleton_v2.png")
OUT_DIR = pathlib.Path("godot/assets/parts")

# Боксы (x, y, w, h) в координатах мастера 832x832 — подобраны по сетке глазами.
HEAD_BOX = (240, 62, 375, 356)   # чуть ниже подбородка (найдено профилем цвета: подбородок ~y=406)
BODY_BOX = (275, 380, 375, 220)
TOOL_BOX = (175, 455, 475, 255)
LEG_BOXES = {
	"near": (305, 585, 135, 190),   # леворасположенная на картинке нога
	"far": (430, 580, 135, 190),   # праворасположенная
}

# Полоска-сустав (серая манжета над ботинком) — доля высоты бокса ноги, где искать сустав.
LEG_JOINT_FRAC = {"near": (0.36, 0.56), "far": (0.34, 0.52)}


def alpha_centre(im: Image.Image, sx: int, sw: int, y: int) -> float:
    cols = [c for c in range(sw) if im.getpixel((sx + c, y))[3] > 100]
    return (cols[0] + cols[-1]) / 2.0 if cols else sw / 2.0


def row_has_alpha(im: Image.Image, sx: int, sw: int, y: int) -> bool:
    return any(im.getpixel((sx + c, y))[3] > 100 for c in range(sw))


def bottom_opaque_row(im: Image.Image, sx: int, sy: int, sw: int, sh: int) -> int:
    for y in range(sh - 1, -1, -1):
        if row_has_alpha(im, sx, sw, sy + y):
            return y
    return sh - 1


def find_joint_row(im: Image.Image, box: tuple[int, int, int, int], frac_range: tuple[float, float]) -> int:
    """Строка сустава внутри диапазона frac_range высоты бокса — минимум ШИРИНЫ силуэта
    (там, где манжета уже штанины и уже ботинка), а не сама манжета по цвету: так метод
    не зависит от точного оттенка серого."""
    sx, sy, sw, sh = box
    lo, hi = int(sh * frac_range[0]), int(sh * frac_range[1])
    best_row, best_width = lo, sw + 1
    for y in range(lo, hi):
        cols = [c for c in range(sw) if im.getpixel((sx + c, sy + y))[3] > 100]
        if not cols:
            continue
        width = cols[-1] - cols[0]
        if width < best_width:
            best_width = width
            best_row = y
    return best_row


def save_part(im: Image.Image, name: str, box: tuple[int, int, int, int], pivot: tuple[float, float]) -> dict:
    x, y, w, h = box
    crop = im.crop((x, y, x + w, y + h))
    crop.save(OUT_DIR / f"{name}.png")
    return {
        "file": f"res://assets/parts/{name}.png",
        "w": w, "h": h,
        "offset_from_center": [w / 2.0 - pivot[0], h / 2.0 - pivot[1]],
        "pivot_in_crop": [pivot[0], pivot[1]],
        "pivot_in_master": [x + pivot[0], y + pivot[1]],
    }


def main() -> None:
    im = Image.open(SRC).convert("RGBA")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rig = {"source": str(SRC).replace("\\", "/"), "parts": {}}

    # --- бёдра обеих ног: точка привязки к тазу = alpha_centre верхней строки бокса ---
    na, fa = LEG_BOXES["near"], LEG_BOXES["far"]
    hip_near = (na[0] + alpha_centre(im, na[0], na[2], na[1]), na[1] + 2.0)
    hip_far = (fa[0] + alpha_centre(im, fa[0], fa[2], fa[1]), fa[1] + 2.0)
    pelvis = ((hip_near[0] + hip_far[0]) / 2.0, (hip_near[1] + hip_far[1]) / 2.0)

    rig["parts"]["body"] = save_part(im, "body_v2", BODY_BOX, (pelvis[0] - BODY_BOX[0], pelvis[1] - BODY_BOX[1]))

    # --- голова: пивот — шея, центр непрозрачной части НИЖНЕЙ строки бокса головы ---
    hx, hy, hw, hh = HEAD_BOX
    neck_x = alpha_centre(im, hx, hw, hy + hh - 3)
    rig["parts"]["head"] = save_part(im, "head_v2", HEAD_BOX, (neck_x, float(hh - 3)))

    # --- инструмент: пивот — точка хвата (у кисти, верхний правый угол бокса) ---
    tx, ty, tw, th = TOOL_BOX
    grip_x = alpha_centre(im, tx, tw, ty + 15)
    rig["parts"]["tool"] = save_part(im, "tool_v2", TOOL_BOX, (grip_x, 15.0))

    # --- ноги: цельные (не режем на бедро+ботинок — гнутся мешем) ---
    leg_meta = {}
    for key, box in LEG_BOXES.items():
        sx, sy, sw, sh = box
        crop = im.crop((sx, sy, sx + sw, sy + sh))
        out_name = f"leg_{key}_whole_v2"
        crop.save(OUT_DIR / f"{out_name}.png")

        hip_x = alpha_centre(im, sx, sw, sy)
        joint_row = find_joint_row(im, box, LEG_JOINT_FRAC[key])
        knee_x = alpha_centre(im, sx, sw, sy + joint_row)
        sole_row = bottom_opaque_row(im, sx, sy, sw, sh)

        leg_meta[key] = {
            "file": f"res://assets/parts/{out_name}.png",
            "w": sw, "h": sh,
            "split_row": joint_row,
            "box_origin": [sx, sy],
            "hip_in_crop": [hip_x, 2.0],
            "knee_in_crop": [knee_x, float(joint_row)],
            "sole_row": sole_row,
        }
        print(f"  {key:<8} box={box} hip_x={hip_x:.1f} joint_row={joint_row} "
              f"knee_x={knee_x:.1f} sole_row={sole_row}")

    (OUT_DIR / "skeleton_rig_v2.json").write_text(
        json.dumps(rig, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT_DIR / "leg_meta_v2.json").write_text(
        json.dumps(leg_meta, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\nPELVIS_IN_MASTER = ({pelvis[0]:.1f}, {pelvis[1]:.1f})")
    for name, meta in rig["parts"].items():
        print(f"  {name:<6} {meta['w']}x{meta['h']} пивот_в_мастере={meta['pivot_in_master']}")
    print(f"\n→ {OUT_DIR}")


if __name__ == "__main__":
    main()
