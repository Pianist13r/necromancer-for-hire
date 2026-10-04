#!/usr/bin/env python3
"""
puppet_slice_check.py — генерация и проверка манифеста нарезки марионетки скелета (W2c).

Что делает:
  1. Пишет assets/puppet/skeleton_parts.json (регионы + пивоты + z-порядок).
  2. Проверяет НЕЙТРАЛЬНУЮ СБОРКУ: рисует части в z-порядке на их же исходных
     координатах (все углы = 0) и сравнивает силуэт с исходным skeleton.png.
     Метрика — доля пикселей, где альфа-маска (>16) отличается. Порог приёмки 3%.
  3. Проверяет покрытие: непрозрачные пиксели исходника, не попавшие ни в один регион.

Запуск: python tools/puppet_slice_check.py [--write]
"""
import argparse
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "img", "skeleton.png")
OUT = os.path.join(ROOT, "assets", "puppet", "skeleton_parts.json")

# W2d: перенарезка под НОВЫЙ мастер skeleton.png (832x832, контент bbox x 242..589,
# y 125..706). Замеры по альфа- и цвето-профилю (оранжевый ботинок отделён от серого
# полотна лопаты по цвету — иначе рез по лопате цеплял носок):
#   y 125..430  — каска + череп; шея — самая узкая строка y≈415 (ширина 111 px), центр x≈438.
#   y 398..622  — торс, ОБЕ руки, черенок лопаты и шорты: лопату держат обе руки, резать
#                 её на куски нельзя → корпус+руки+инструмент = один жёсткий кусок.
#   y 614..654  — «tool»: нижний угол полотна лопаты (x 238..336) свисает НИЖЕ линии реза
#                 бёдер. Отдельный кусок с ТЕМ ЖЕ пивотом, что у корпуса (drawPuppet
#                 крутит всё не-leg/не-head вокруг своего пивота), поэтому лопата остаётся
#                 жёстко связанной с торсом, а линия реза ног может подняться до y=606
#                 и дать ногам 90 px видимого маха вместо 30.
#   y 606..712  — ноги; промежность расходится с y≈612, вертикальный рез по x=441
#                 с перекрытием 436..446. Пивоты бёдер разведены от промежности (как в
#                 прежней нарезке: ~8 % ширины фигуры).
# Перекрытия по вертикали: голова/корпус 398..430, корпус/ноги 606..622 — корпус рисуется
# ПОСЛЕ ног и перекрывает их верх, поэтому смаз у бедра не виден.
PARTS = [
    # name,       sx,  sy,  sw,  sh,  pivot_abs_x, pivot_abs_y, z
    ("leg_far",  310, 606, 136, 106, 413, 610, 10),
    ("leg_near", 436, 606, 154, 106, 469, 610, 20),
    ("tool",     238, 614,  98,  40, 444, 612, 25),
    ("body",     238, 398, 356, 224, 444, 612, 30),
    ("head",     265, 118, 332, 312, 438, 418, 40),
]


def build_manifest(w, h):
    return {
        "sprite": "assets/img/skeleton.png",
        "width": w,
        "height": h,
        "parts": [
            {
                "name": name,
                "sx": sx, "sy": sy, "sw": sw, "sh": sh,
                "px": pvx - sx, "py": pvy - sy,
                "z": z,
            }
            for (name, sx, sy, sw, sh, pvx, pvy, z) in PARTS
        ],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="записать JSON-манифест")
    args = ap.parse_args()

    src = Image.open(SRC).convert("RGBA")
    w, h = src.size
    manifest = build_manifest(w, h)

    # --- нейтральная сборка ---
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for p in sorted(manifest["parts"], key=lambda p: p["z"]):
        region = src.crop((p["sx"], p["sy"], p["sx"] + p["sw"], p["sy"] + p["sh"]))
        canvas.alpha_composite(region, (p["sx"], p["sy"]))

    a_src = src.split()[3].point(lambda v: 255 if v > 16 else 0)
    a_new = canvas.split()[3].point(lambda v: 255 if v > 16 else 0)
    total = w * h
    diff = sum(1 for a, b in zip(a_src.getdata(), a_new.getdata()) if a != b)
    src_px = sum(1 for a in a_src.getdata() if a)
    print("нейтральная сборка: отличается %d px из %d (%.4f%% кадра, %.4f%% силуэта)"
          % (diff, total, 100.0 * diff / total, 100.0 * diff / max(1, src_px)))

    # --- покрытие: непрозрачные пиксели вне всех регионов ---
    covered = Image.new("L", (w, h), 0)
    for p in manifest["parts"]:
        covered.paste(255, (p["sx"], p["sy"], p["sx"] + p["sw"], p["sy"] + p["sh"]))
    miss = sum(1 for a, c in zip(a_src.getdata(), covered.getdata()) if a and not c)
    print("не покрыто регионами: %d непрозрачных px из %d (%.4f%%)"
          % (miss, src_px, 100.0 * miss / max(1, src_px)))

    ok = (100.0 * diff / max(1, src_px)) <= 3.0 and miss == 0
    if args.write:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
        print("записан", OUT)
    print("ИТОГ:", "OK" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
