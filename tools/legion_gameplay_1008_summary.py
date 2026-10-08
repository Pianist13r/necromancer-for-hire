"""Read complete paired bot logs; do not count a crash/timeout as a defeat."""
import argparse
import json
import statistics
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("before", type=Path)
p.add_argument("after", type=Path)
p.add_argument("--pvp-before", type=Path)
p.add_argument("--pvp-after", type=Path)
args = p.parse_args()
if bool(args.pvp_before) != bool(args.pvp_after):
    p.error("Provide both --pvp-before and --pvp-after.")


def read(folder, name):
    path = folder / name
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    if "SCRIPT ERROR" in text:
        raise ValueError(f"SCRIPT ERROR: {path}")
    rows = [json.loads(line) for line in text.splitlines()
            if line.startswith("{") and '"result"' in line]
    if len(rows) != 1:
        return None
    return rows[0]


def med(rows, key):
    return round(statistics.median(row[key] for row in rows), 2)


print("|Карта|До: победы / HP / потери / с / простой %|После: победы / HP / потери / с / простой %|Пар|")
print("|---|---|---|---|")
all_rows = {}
for map_id in ["boss", "maze", "fork"]:
    groups = [[], []]
    for seed in range(91, 101):
        name = f"{map_id}_selective_s{seed}.log"
        pair = [read(folder, name) for folder in [args.before, args.after]]
        if any(row is None for row in pair):
            continue
        for rows, row in zip(groups, pair):
            assert row["seed"] == seed and row["map"] == map_id
            assert row["bot"] == "selective" and row["difficulty"] == "normal"
            row["idle_share"] = 100 * row.get("idle_unit_seconds", 0) / max(
                1, row.get("avg_army", 0) * row["t"])
            rows.append(row)
    if not groups[0]:
        print(f"|{map_id}|pending|pending|0/10|")
        continue
    cells = []
    for rows in groups:
        wins = sum(row["result"] == "victory" for row in rows)
        cells.append(f"{wins}/{len(rows)} / " + " / ".join(str(med(rows, key))
                     for key in ["hp", "lost", "t", "idle_share"]))
    print(f"|{map_id}|{cells[0]}|{cells[1]}|{len(groups[0])}/10|")
    all_rows[map_id] = groups
    for label, key in [("Автомарши", "auto_marches"), ("Фланговые срывы", "bot_flanks")]:
        print(f"<!-- {map_id} {label}: " + " → ".join(str(sum(r.get(key, 0) for r in rows))
              for rows in groups) + " -->")
complete = True
for folder in [args.before, args.after]:
    available = sum(read(folder, f"{m}_selective_s{s}.log") is not None
                    for m in ["boss", "maze", "fork"] for s in range(91, 101))
    print(f"<!-- {folder}: {available}/30 complete -->")
    complete = complete and available == 30
if not complete:
    raise SystemExit("Incomplete series: paired conclusions require all 30 + 30 outcomes.")

if args.pvp_before:
    print("\n|PvP|Победы 0 / 1 / ничья|Время медиана / макс, с|Разрушений Котла|Урон бойцов / волн|Доля волн, %|")
    print("|---|---|---|---|---|---|")
    for label, folder in [("До", args.pvp_before), ("После", args.pvp_after)]:
        rows = [read(folder, f"s{s}.log") for s in range(91, 101)]
        if any(row is None for row in rows):
            raise SystemExit(f"Incomplete PvP series: {folder}")
        for seed, row in zip(range(91, 101), rows):
            assert row["seed"] == seed and row["map"] == "pvp:duel"
            assert row["difficulty"] == "intern"  # Fixed by PvpRules, not a user setting.
            assert all("bot" in side for side in row["pvp"]["sides"])
        matches = [r["pvp"] for r in rows]
        wins = [sum(m["winner"] == s for m in matches) for s in [0, 1, -1]]
        times = [m["t"] for m in matches]
        units = sum(s["dmg"]["units"] for m in matches for s in m["sides"])
        waves = sum(s["dmg"]["waves"] for m in matches for s in m["sides"])
        destroyed = sum(m["reason"] == "cauldron" for m in matches)
        share = 100 * waves / max(1, units + waves)
        print(f"|{label}|{' / '.join(map(str, wins))}|{statistics.median(times):.2f} / {max(times):.1f}"
              f"|{destroyed}/10|{units:.1f} / {waves:.1f}|{share:.2f}|")
