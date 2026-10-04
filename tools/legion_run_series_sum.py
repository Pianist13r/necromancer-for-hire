"""Сводка серии забегов цепочкой (tools/legion_run_series.sh, B-358).

python tools/legion_run_series_sum.py <N объектов> <лог> [<лог> …]
Лог — вывод godot/tests/legion_run_chain_runner.gd: строки «RUN_OBJECT {json}» и «RUN_END {json}»,
последней строкой — «exit=<код>» от серийного скрипта.
Печатает строку на забег и таблицу по номеру объекта: сколько забегов дошло до k, побед на k,
Котёл медиана/минимум, потери медиана, сколько забегов кончилось на k. Медиана — честная
(statistics.median: при чётном числе — среднее двух средних).
"""
import json
import os
import statistics
import sys


def fmt(v: float) -> str:
    return str(int(v)) if float(v).is_integer() else f"{v:.1f}".replace(".", ",")


def parse(path: str) -> dict:
    rows, end, errs, code = [], None, 0, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "SCRIPT ERROR" in line:
                errs += 1
            if line.startswith("RUN_OBJECT "):
                rows.append(json.loads(line[len("RUN_OBJECT "):]))
            elif line.startswith("RUN_END "):
                end = json.loads(line[len("RUN_END "):])
            elif line.startswith("exit="):
                code = line.strip()[len("exit="):]
    return {"rows": rows, "end": end, "errs": errs, "code": code}


def main() -> int:
    n = int(sys.argv[1])
    logs = sys.argv[2:]
    runs = []
    total_errs = 0
    for path in logs:
        r = parse(path)
        total_errs += r["errs"]
        name = os.path.basename(path)
        end = r["end"]
        if end is None:
            reason = "НЕТ ИТОГА (завис или упал; exit=%s)" % r["code"]
            won = sum(1 for x in r["rows"] if x.get("result") == "victory")
        else:
            reason = end.get("reason", "?")
            won = int(end.get("objects_won", 0))
        last = r["rows"][-1] if r["rows"] else {}
        print(f"{name}: сдано {won}/{n}, конец — {reason}, ошибок скрипта {r['errs']}, "
              f"поправок {len(last.get('upgrades', []))}, артефактов {len(last.get('items', []))}, "
              f"покупок {sum(last.get('shop', {}).values()) if isinstance(last.get('shop'), dict) else 0}")
        runs.append({"rows": r["rows"], "reason": reason, "complete": end is not None})

    print()
    print(f"забегов {len(runs)}, объектов до {n}, SCRIPT ERROR всего {total_errs}")
    print("| объект | дошло | побед | Котёл медиана / мин | потери, медиана | кончилось на k |")
    print("|---|---|---|---|---|---|")
    for k in range(1, n + 1):
        at_k = [x for run in runs for x in run["rows"] if int(x.get("k", 0)) == k]
        if not at_k:
            continue
        wins = sum(1 for x in at_k if x.get("result") == "victory")
        hps = [float(x.get("hp", 0.0)) for x in at_k]
        lost = [float(x.get("lost", 0)) for x in at_k if "lost" in x]
        ended = sum(1 for run in runs if run["rows"] and int(run["rows"][-1].get("k", 0)) == k
                    and run["reason"] != "objects")
        lost_med = fmt(statistics.median(lost)) if lost else "-"
        print(f"| {k} | {len(at_k)} | {wins} | {fmt(statistics.median(hps))} / {fmt(min(hps))} "
              f"| {lost_med} | {ended} |")
    full = sum(1 for run in runs if run["reason"] == "objects")
    print(f"дошли до конца (все {n}): {full}/{len(runs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
