#!/usr/bin/env python3
"""
Нарезка мастера скелета на части ПОД НАСТОЯЩУЮ ХОДЬБУ (Э3 миграции на Godot).

Чем отличается от старой марионетки (`assets/puppet/skeleton_parts.json`): там нога была
ОДНИМ куском, а цельной ногой можно только вращать целиком — это и давало «кукольность»,
которую владелец отверг. Здесь каждая нога режется на ДВА куска: ножка и ботинок. Отдельный
ботинок позволяет отрыв пятки (heel-off) и постановку на носок — это главный визуальный
признак того, что персонаж ИДЁТ, а не скользит.

Почему не «бедро + голень»: персонаж чиби (голова огромная, ноги короткие), колена у него
на спрайте нет вовсе — классический двухкостный IK там нечего показывать. Ощущение веса на
такой пропорции дают футпланинг, отрыв пятки, колебание таза и наклон корпуса.

Границы разреза найдены по пикселям (доля оранжевого «ботиночного» цвета по строкам),
а не на глаз: leg_near — строка 33, leg_far — строка 28 от верха куска.

Запуск:  python tools/slice_walk_parts.py
Выход:   godot/assets/parts/*.png + godot/assets/parts/skeleton_walk_rig.json
"""
import json
import pathlib

from PIL import Image

SRC = pathlib.Path("assets/img/skeleton.png")
OUT_DIR = pathlib.Path("godot/assets/parts")
OLD_RIG = pathlib.Path("assets/puppet/skeleton_parts.json")

# Разрез ноги: сколько строк от верха куска приходится на ножку (найдено пиксельным анализом).
# OVERLAP — перекрытие кусков: без него при повороте стопы в стыке появляется щель.
LEG_SPLIT = {"leg_near": 33, "leg_far": 28}
OVERLAP = 5   # перекрытие ТОЛЬКО у ножки: она лежит ПОД ботинком и закрывает щель



def alpha_centre(im, sx: int, sw: int, y: int) -> float:
    """Центр непрозрачной части строки — истинная ось сустава.

    Зачем: пивоты старой марионетки (px из skeleton_parts.json) указывали точку крепления
    ЦЕЛЬНОЙ ноги и лежали у её края. Для цельного куска это было неважно, но как ось
    вращения ботинка такой пивот даёт грубый брак: замер показал смещение −52.5 px (near)
    и +47 px (far) при ширине ноги ~102 px, то есть ботинок крутился вокруг точки ВНЕ ноги
    и уезжал вбок. Поэтому ось считаем по картинке, а не наследуем.
    """
    cols = [c for c in range(sw) if im.getpixel((sx + c, y))[3] > 100]
    return (cols[0] + cols[-1]) / 2.0 if cols else sw / 2.0


def main() -> None:
    im = Image.open(SRC).convert("RGBA")
    old = {p["name"]: p for p in json.loads(OLD_RIG.read_text(encoding="utf-8"))["parts"]}
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    rig = {"source": str(SRC).replace("\\", "/"), "parts": {}}

    def save(name: str, box: tuple[int, int, int, int], pivot: tuple[float, float]) -> None:
        """box = (x, y, w, h) в координатах мастера; pivot — в пикселях ВНУТРИ вырезанного куска."""
        crop = im.crop((box[0], box[1], box[0] + box[2], box[1] + box[3]))
        crop.save(OUT_DIR / f"{name}.png")
        rig["parts"][name] = {
            "file": f"res://assets/parts/{name}.png",
            "w": box[2], "h": box[3],
            # Godot центрирует Sprite2D, поэтому отдаём смещение пивота от ЦЕНТРА куска —
            # так в GDScript не придётся ничего пересчитывать руками.
            "offset_from_center": [box[2] / 2.0 - pivot[0], box[3] / 2.0 - pivot[1]],
            "pivot_in_crop": [pivot[0], pivot[1]],
            "pivot_in_master": [box[0] + pivot[0], box[1] + pivot[1]],
        }

    # --- корпус и голова: берём как в старой нарезке, пивоты те же (они уже выверены) ---
    b = old["body"]
    save("body", (b["sx"], b["sy"], b["sw"], b["sh"]), (b["px"], b["py"]))
    h = old["head"]
    save("head", (h["sx"], h["sy"], h["sw"], h["sh"]), (h["px"], h["py"]))
    t = old["tool"]
    save("tool", (t["sx"], t["sy"], t["sw"], t["sh"]), (t["px"], t["py"]))

    # --- ноги: каждая на два куска ---
    for leg in ("leg_near", "leg_far"):
        p = old[leg]
        split = LEG_SPLIT[leg]

        # ножка: от верха куска до линии разреза (+перекрытие вниз).
        # Ось крепления к тазу — центр ноги на верхней строке куска.
        # Перекрытие даём НОЖКЕ (она рисуется под ботинком и прячет щель на стыке).
        # Ботинку перекрытие давать НЕЛЬЗЯ: он утащит наверх кусок белой кости, и при
        # повороте ботинка этот кусок вылезает сбоку белым обрезком (поймано приёмкой кадрами).
        up_h = split + OVERLAP
        hip_x = alpha_centre(im, p["sx"], p["sw"], p["sy"])
        save(f"{leg}_upper", (p["sx"], p["sy"], p["sw"], up_h), (hip_x, 2.0))

        # ботинок: от линии разреза (−перекрытие вверх) до низа куска.
        # Ось ботинка — центр ноги НА ЛИНИИ СТЫКА: вокруг неё он поворачивается при
        # отрыве пятки, и только в этой точке поворот не уводит ботинок вбок.
        foot_y = p["sy"] + split
        foot_h = p["sh"] - split
        knee_x = alpha_centre(im, p["sx"], p["sw"], p["sy"] + split)
        save(f"{leg}_foot", (p["sx"], foot_y, p["sw"], foot_h), (knee_x, 0.0))

    (OUT_DIR / "skeleton_walk_rig.json").write_text(
        json.dumps(rig, ensure_ascii=False, indent=2), encoding="utf-8")

    for name, meta in rig["parts"].items():
        print(f"  {name:<18} {meta['w']:>4}x{meta['h']:<4} пивот от центра {meta['offset_from_center']}")
    print(f"\nвсего частей: {len(rig['parts'])} → {OUT_DIR}")


if __name__ == "__main__":
    main()
