"""Сводка серии «Схватки» (tools/pvp_series.sh): строка на сид и итог.

python tools/pvp_series_sum.py <папка> <сид> [<сид> …]
Итог боя — последняя JSON-строка лога с полем "pvp" (печатает --quit-on-end).
"""
import json
import os
import statistics
import sys


def main() -> int:
    out, seeds = sys.argv[1], sys.argv[2:]
    wins = {0: 0, 1: 0, -1: 0}
    times, reasons, errors = [], {}, 0
    for s in seeds:
        path = os.path.join(out, f"s{s}.log")
        final = None
        errs = 0
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "SCRIPT ERROR" in line:
                    errs += 1
                if line.startswith("{") and '"pvp"' in line and '"result"' in line:
                    final = json.loads(line)
        errors += errs
        if final is None:
            print(f"s{s}: НЕТ ИТОГА (ошибок скрипта {errs})")
            continue
        p = final["pvp"]
        w = int(p["winner"])
        wins[w] = wins.get(w, 0) + 1
        times.append(float(p["t"]))
        reasons[p["reason"]] = reasons.get(p["reason"], 0) + 1
        sides = " | ".join(
            f"hp {sd['hp']:.0f} армия {sd['army']} души {sd['souls']} "
            f"перебежек {sd.get('bot', {}).get('leaps', '-')} осад {sd.get('bot', {}).get('sieges', '-')}"
            for sd in p["sides"])
        print(f"s{s}: победа {w if w >= 0 else 'ничья'} ({p['reason']}) за {p['t']:.0f} с · {sides}"
              f"{' · ОШИБОК ' + str(errs) if errs else ''}")
    n = len(times)
    if n:
        print(f"ИТОГ: боёв {n}/{len(seeds)} · побед стороны 0: {wins[0]}, стороны 1: {wins[1]}, "
              f"ничьих: {wins[-1]} · причины {reasons} · время медиана {statistics.median(times):.0f} с, "
              f"макс {max(times):.0f} с, < 720 с: {sum(1 for t in times if t < 720)} · "
              f"ошибок скрипта {errors}")
    return 0 if n == len(seeds) and n > 0 and errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
