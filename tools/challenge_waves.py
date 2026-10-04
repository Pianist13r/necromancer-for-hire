"""Добавки «работы видов» и кульминации в волны карт (медленная сессия slow/challenge, 26.09.2026).

Зачем: волны карт — данные, а формат JSON карт ручной (json.dump его не повторяет). Скрипт берёт
карту из git HEAD~ (--base КОММИТ), вставляет группы с полем "tier" и флаг "climax" текстом, не
трогая остальное. Группы tier 1 появляются с «Штатного», tier 2 — только в «Аду»
(LegionChallenge.apply_map); «Стажёр» их не видит — там прежние волны бит в бит.

Использование (из корня worktree):  python tools/challenge_waves.py --base 419f6ae
"""
import argparse
import json
import subprocess

MAPS = "godot/assets/legion/maps/"

# (дорога, вид, число, интервал, задержка, tier)
S = "shield_inspector"
G = "ghost"
Z = "zombie"
ADD = {
    # «Развилка» — открылся вахтёр: колонны щитоносцев впереди зомби ломают подряд, держит охрана/Е
    "fork": {
        "climax": 4,
        2: [("north", S, 2, 0.9, 0.0, 1), ("south", S, 2, 0.9, 1.5, 1)],
        3: [("north", S, 2, 0.9, 0.0, 1), ("south", S, 2, 0.9, 11.0, 1)],
        4: [("north", S, 4, 0.8, 9.0, 1), ("south", S, 4, 0.8, 0.5, 1),
            ("north", Z, 6, 0.43, 14.0, 2), ("south", Z, 6, 0.43, 5.5, 2),
            ("north", S, 2, 0.8, 13.0, 2), ("south", S, 2, 0.8, 4.5, 2)],
        5: [("north", S, 2, 0.9, 0.0, 1), ("south", S, 2, 0.9, 12.5, 1)],
    },
    # «Мост» — открылся счетовод: волны призраков, которых строй подряда и охраны не бьёт
    "bridge": {
        "climax": 4,
        2: [("north", G, 4, 1.0, 6.0, 1), ("south", G, 4, 1.0, 6.5, 1)],
        3: [("north", G, 5, 1.0, 9.0, 1), ("south", G, 5, 1.0, 17.0, 1)],
        4: [("north", G, 8, 0.9, 12.0, 1), ("south", G, 8, 0.9, 6.0, 1),
            ("north", S, 3, 0.9, 7.0, 1), ("south", S, 3, 0.9, 0.0, 1),
            ("north", G, 3, 0.9, 15.0, 2), ("south", G, 3, 0.9, 9.0, 2)],
        5: [("north", G, 5, 1.0, 9.0, 1), ("south", G, 5, 1.0, 17.0, 1),
            ("north", S, 2, 0.9, 0.0, 1), ("south", S, 2, 0.9, 8.0, 1)],
    },
    # «Лабиринт» — смешение угроз: щиты и призраки с разных ворот, пик — пятая волна
    "maze": {
        "climax": 5,
        3: [("north", G, 3, 1.0, 9.0, 1), ("south", G, 3, 1.0, 9.0, 1)],
        5: [("north", S, 2, 1.2, 1.0, 1), ("east", S, 2, 1.2, 1.0, 1), ("south", S, 2, 1.2, 1.0, 1),
            ("north", G, 4, 1.0, 8.0, 1), ("south", G, 4, 1.0, 8.0, 1),
            ("west", G, 3, 1.0, 9.0, 2)],
    },
    # «Болото» — призраков уже много; щиты в пик
    "swamp": {
        "climax": 5,
        2: [("north", S, 2, 1.2, 1.0, 1), ("south", S, 2, 1.2, 1.0, 1)],
        5: [("north", S, 3, 1.2, 0.5, 1), ("south", S, 3, 1.2, 0.5, 1),
            ("north", Z, 8, 0.36, 9.0, 1), ("south", Z, 8, 0.39, 10.5, 1),
            ("west", S, 2, 1.2, 2.0, 2)],
    },
    # «Прораб» — пик перед выходом Прораба
    "boss": {
        "climax": 4,
        2: [("north", S, 2, 1.2, 0.5, 1), ("south", S, 2, 1.2, 0.5, 1)],
        3: [("north", G, 2, 1.2, 12.0, 1), ("south", G, 2, 1.2, 12.0, 1)],
        4: [("north", S, 3, 1.2, 1.0, 1), ("south", S, 3, 1.2, 1.0, 1),
            ("north", G, 4, 1.0, 10.0, 1), ("south", G, 4, 1.0, 10.0, 1),
            ("north", Z, 8, 0.36, 12.0, 2), ("south", Z, 8, 0.36, 13.5, 2)],
    },
    # «Пустырь» — обучение: только отметка кульминации, добавок нет
    "wasteland": {"climax": 4},
}


def group_text(g):
    road, kind, count, interval, delay, tier = g
    return ("        {\n"
            f'          "road": "{road}",\n'
            f'          "type": "{kind}",\n'
            f'          "count": {count},\n'
            f'          "interval": {interval},\n'
            f'          "delay": {delay},\n'
            f'          "tier": {tier}\n'
            "        }")


def patch(map_id, text):
    spec = ADD[map_id]
    lines = text.split("\n")
    start = next(i for i, ln in enumerate(lines) if ln == '  "waves": [')
    out = lines[:start]
    wave = 0
    i = start
    while i < len(lines):
        ln = lines[i]
        if ln == "    {" and i > start:
            wave += 1
        if ln.startswith('      "pause":') and wave == spec.get("climax"):
            out.append(ln)
            out.append('      "climax": true,')
            i += 1
            continue
        if ln == "      ]" and wave in spec:
            # последний элемент массива групп получает запятую, дальше — добавки
            out[-1] = out[-1] + ","
            out.append(",\n".join(group_text(g) for g in spec[wave]))
        if ln == "  ]":
            out.extend(lines[i:])
            break
        out.append(ln)
        i += 1
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    base = ap.parse_args().base
    for map_id in ADD:
        path = MAPS + map_id + ".json"
        text = subprocess.run(["git", "show", f"{base}:{path}"], capture_output=True, check=True,
                              encoding="utf-8").stdout
        new = patch(map_id, text)
        old = json.loads(text)
        cur = json.loads(new)
        # проверка: без групп tier и флага climax карта совпадает с исходной
        for w in cur["waves"]:
            w.pop("climax", None)
            w["groups"] = [g for g in w["groups"] if "tier" not in g]
        assert cur == old, map_id
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
        print(map_id, "ok", sum(len(v) for k, v in ADD[map_id].items() if k != "climax"), "групп")


if __name__ == "__main__":
    main()
