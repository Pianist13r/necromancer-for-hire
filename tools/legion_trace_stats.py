# -*- coding: utf-8 -*-
"""Мера скуки боя по трассе бота (--trace, строка JSON раз в секунду).

Зачем: «скучно» надо доказывать числом, а не вкусом (INTEREST_V16 §1, §5 п.10). Для каждой
секунды боя: «драка» — за секунду был хоть один kill; «ходьба» — враги на карте, убийств нет;
«пусто» — врагов нет. Дополнительно, если движок пишет их в трассу (пакет T): first_contact_t —
время первого нанесённого урона, no_dmg_s — секунды без нанесённого урона.

Использование:
  python -X utf8 tools/legion_trace_stats.py <лог1> [<лог2> ...]
  python -X utf8 tools/legion_trace_stats.py --json <лог>      # одна строка JSON на лог
Лог — stdout прогона с `--trace` (и обычно `--quit-on-end`); итоговая строка с "result" тоже читается.
"""
import json
import sys


def parse(path):
    rows, final = [], None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if "result" in obj:
                final = obj
            elif "mana" in obj and "foes" in obj:
                rows.append(obj)
    return rows, final


def stats(rows, final):
    fight = walk = idle = 0
    waves = {}
    prev = None
    first_kill_t = None
    for r in rows:
        w = int(r.get("wave", 0))
        entry = waves.setdefault(w, {"fight": 0, "walk": 0, "idle": 0, "t0": r["t"], "t1": r["t"]})
        entry["t1"] = r["t"]
        if prev is not None:
            if r["kills"] > prev["kills"]:
                fight += 1
                entry["fight"] += 1
                if first_kill_t is None:
                    first_kill_t = r["t"]
            elif r["foes"] > 0:
                walk += 1
                entry["walk"] += 1
            else:
                idle += 1
                entry["idle"] += 1
        prev = r
    total = max(1, fight + walk + idle)
    out = {
        "seconds": rows[-1]["t"] if rows else 0.0,
        "fight_s": fight, "walk_s": walk, "idle_s": idle,
        "fight_share": round(fight / total, 3), "walk_share": round(walk / total, 3),
        "idle_share": round(idle / total, 3),
        "first_kill_t": first_kill_t,
        "hp_min": min((r["hp"] for r in rows), default=None),
        "mana_min": min((r["mana"] for r in rows), default=None),
        "waves": {w: v for w, v in waves.items()},
    }
    if final is not None:
        for key in ("result", "map", "seed", "bot", "hp", "t", "kills", "lost",
                    "first_contact_t", "no_dmg_s", "waves_called", "call_bonus", "breach_leaks"):
            if key in final:
                out[key] = final[key]
    return out


def main(argv):
    as_json = "--json" in argv
    paths = [a for a in argv if a != "--json"]
    if not paths:
        print(__doc__)
        return 2
    for path in paths:
        rows, final = parse(path)
        s = stats(rows, final)
        if as_json:
            print(json.dumps({"log": path, **s}, ensure_ascii=False))
            continue
        print("== %s: %s %s seed=%s bot=%s" % (path, s.get("map", "?"), s.get("result", "?"),
                                                 s.get("seed", "?"), s.get("bot", "?")))
        print("  бой %.0f с · драка %d с (%.0f%%) · ходьба %d с (%.0f%%) · пусто %d с (%.0f%%)" % (
            s["seconds"], s["fight_s"], s["fight_share"] * 100, s["walk_s"], s["walk_share"] * 100,
            s["idle_s"], s["idle_share"] * 100))
        extras = []
        if s.get("first_kill_t") is not None:
            extras.append("первое убийство %.0f с" % s["first_kill_t"])
        if s.get("first_contact_t") is not None:
            extras.append("первый контакт %.1f с" % float(s["first_contact_t"]))
        if s.get("no_dmg_s") is not None:
            extras.append("без урона %.0f с" % float(s["no_dmg_s"]))
        extras.append("HP min %s · мана min %s" % (s["hp_min"], s["mana_min"]))
        print("  " + " · ".join(extras))
        for w, v in sorted(s["waves"].items()):
            print("  волна %d: %.0f–%.0f с · драка %d · ходьба %d · пусто %d" % (
                w, v["t0"], v["t1"], v["fight"], v["walk"], v["idle"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
