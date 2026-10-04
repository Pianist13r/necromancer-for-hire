#!/usr/bin/env python3
"""
Нарезка ЦЕЛЬНЫХ (не разрезанных на ножку+ботинок) ног обеих сторон — материал для
меш-рига Э1 (см. NEXT_SESSION_PROMPT.md). `slice_walk_parts.py` режет ногу на два жёстких
куска ради марионетки; здесь та же геометрия мастера, но нога остаётся ОДНОЙ картинкой —
её потом гнёт Polygon2D+Skeleton2D (доказано на `leg_near_whole.png` в mesh_vs_cut.gd),
а не второй жёсткий шов.

Координаты box те же, что в `slice_walk_parts.py` (assets/puppet/skeleton_parts.json),
пивоты (hip/knee) — тем же методом alpha_centre, чтобы риг совпал с уже принятой геометрией
ходьбы. sole_row ищем как последнюю непрозрачную строку снизу — это низ подошвы.

Запуск (из корня репо):  python tools/slice_walk_whole.py
Выход: godot/assets/parts/leg_{near,far}_whole.png + leg_whole_meta.json (обе ноги)
"""
import json
import pathlib

from PIL import Image

SRC = pathlib.Path("assets/img/skeleton.png")
OUT_DIR = pathlib.Path("godot/assets/parts")
OLD_RIG = pathlib.Path("assets/puppet/skeleton_parts.json")

LEG_SPLIT = {"leg_near": 33, "leg_far": 28}   # тот же разрез, что в slice_walk_parts.py


def alpha_centre(im: Image.Image, sx: int, sw: int, y: int) -> float:
    cols = [c for c in range(sw) if im.getpixel((sx + c, y))[3] > 100]
    return (cols[0] + cols[-1]) / 2.0 if cols else sw / 2.0


def bottom_opaque_row(im: Image.Image, sx: int, sy: int, sw: int, sh: int) -> int:
    for y in range(sh - 1, -1, -1):
        row_alpha = max(im.getpixel((sx + x, sy + y))[3] for x in range(sw))
        if row_alpha > 100:
            return y
    return sh - 1


def main() -> None:
    im = Image.open(SRC).convert("RGBA")
    old = {p["name"]: p for p in json.loads(OLD_RIG.read_text(encoding="utf-8"))["parts"]}
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    meta = {}
    for leg in ("leg_near", "leg_far"):
        p = old[leg]
        sx, sy, sw, sh = p["sx"], p["sy"], p["sw"], p["sh"]
        split = LEG_SPLIT[leg]

        crop = im.crop((sx, sy, sx + sw, sy + sh))
        out_name = f"{leg}_whole"
        crop.save(OUT_DIR / f"{out_name}.png")

        hip_x = alpha_centre(im, sx, sw, sy)
        knee_x = alpha_centre(im, sx, sw, sy + split)
        sole_row = bottom_opaque_row(im, sx, sy, sw, sh)

        meta[leg] = {
            "file": f"res://assets/parts/{out_name}.png",
            "w": sw, "h": sh,
            "split_row": split,
            # box_origin переводит crop-координаты в координаты МАСТЕРА (832x832) — той же
            # системы, что использует skeleton_walk_rig.json для тела/головы/инструмента.
            # Без этого риг ноги и риг тела считались бы в двух разных системах координат.
            "box_origin": [sx, sy],
            "hip_in_crop": [hip_x, 2.0],
            "knee_in_crop": [knee_x, float(split)],
            "sole_row": sole_row,
        }
        print(f"  {leg:<10} {sw}x{sh}  hip_x={hip_x:.1f} knee_x={knee_x:.1f} sole_row={sole_row}")

    (OUT_DIR / "leg_whole_meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nмета обеих ног → {OUT_DIR / 'leg_whole_meta.json'}")


if __name__ == "__main__":
    main()
