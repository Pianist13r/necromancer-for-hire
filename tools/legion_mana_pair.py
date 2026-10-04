#!/usr/bin/env python3
"""Run a sequential, matched economy-mana balance series on two local checkouts.

Example (after A is merged into both trees):
  python tools/legion_mana_pair.py C:/Projects/Necromancer C:/Projects/necro-economy-mana \
    --out C:/AI/necro/batches/legion/series/mana-pair-a6ebfc2

One frozen copy of legion_balance_runner.gd is used for both trees. Processes run one at a
time, each with its own APPDATA sandbox. Engine binaries and the user's save directory are untouched.
"""

import argparse
import hashlib
import json
import math
import os
import pathlib
import statistics
import subprocess
import sys


GODOT_DEFAULT = pathlib.Path(
    "C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe"
)
MAPS = ("wasteland", "gatehouse", "fork", "archive", "maze")
PROFILES = ("novice", "mid")
SEEDS = tuple(range(91, 101))
RUNNER = pathlib.Path("godot/tests/legion_balance_runner.gd")


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def head(root: pathlib.Path) -> str:
    return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()


def require_frozen(root: pathlib.Path, expected: str) -> None:
    if head(root) != expected:
        raise RuntimeError(f"checkout HEAD changed: {root}")
    dirty = subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"], text=True)
    if dirty:
        raise RuntimeError(f"tracked checkout changes during series: {root}")


def finite_nonnegative(value, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise RuntimeError(f"invalid numeric metric {label}: {value!r}")


def finite_json_number(token: str) -> float:
    value = float(token)
    if not math.isfinite(value):
        raise ValueError(f"non-finite JSON number: {token}")
    return value


def one_run(root: pathlib.Path, out: pathlib.Path, godot: pathlib.Path,
            side: str, map_id: str, profile: str, seed: int, runner: pathlib.Path) -> dict:
    stem = f"{side}_{map_id}_selective_{profile}_{seed}"
    log_path = out / f"{stem}.log"
    appdata = out / "appdata" / stem
    appdata.mkdir(parents=True, exist_ok=True)
    cmd = [str(godot), "--headless", "--path", str(root / "godot"), "--fixed-fps", "60",
           "--quit-after", "90000", "--script", str(runner),
           "--", "--mute", "--trace", "--bot", "selective", "--seed", str(seed),
           "--map", map_id, "--quit-on-end", "--dev", f"profile={profile}",
           "--dev", "steps=8"]
    env = os.environ.copy()
    env["APPDATA"] = str(appdata)
    with log_path.open("w", encoding="utf-8", newline="\n") as log:
        proc = subprocess.run(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
                              timeout=1800, check=False,
                              creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    text = log_path.read_text(encoding="utf-8", errors="replace")
    result_rows = [json.loads(line, parse_float=finite_json_number, parse_constant=finite_json_number)
                  for line in text.splitlines()
                   if line.startswith("{") and '"result"' in line]
    cleanup = [line for line in text.splitlines()
               if line.startswith("ERROR:") and "resources still in use at exit" in line]
    errors = [line for line in text.splitlines() if "ERROR:" in line and line not in cleanup]
    if proc.returncode != 0 or len(result_rows) != 1 or "SCRIPT ERROR" in text or errors:
        raise RuntimeError(f"invalid run {stem}: exit={proc.returncode}, log={log_path}")
    row = result_rows[0]
    if not isinstance(row, dict) or row.get("result") not in ("victory", "defeat"):
        raise RuntimeError(f"invalid result in {log_path}")
    for field, expected in (("map", map_id), ("bot", "selective"), ("seed", seed)):
        if row.get(field) != expected:
            raise RuntimeError(f"wrong {field} in {log_path}: {row.get(field)!r} != {expected!r}")
    finite_nonnegative(row.get("hp"), "hp")
    eco = row.get("eco")
    if not isinstance(eco, dict) or "mana_min" not in eco:
        raise RuntimeError(f"missing economy metrics in {log_path}")
    finite_nonnegative(eco["mana_min"], "mana_min")
    # Profile is a command parameter; this runner does not emit its name in the final JSON.
    # Preserve the actual map/bot/seed above instead of overwriting mismatches with expectations.
    row.update({"side": side, "policy": "selective", "profile": profile, "log": str(log_path)})
    row["mana_min"] = eco["mana_min"]
    row["cleanup_warnings"] = cleanup
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=pathlib.Path, help="master checkout after A")
    parser.add_argument("after", type=pathlib.Path, help="economy-mana checkout after A merge")
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--godot", type=pathlib.Path, default=GODOT_DEFAULT)
    parser.add_argument("--pilot", action="store_true", help="one matched pair before the full 200 runs")
    args = parser.parse_args()
    before, after, out, godot = (p.resolve() for p in
                                 (args.before, args.after, args.out, args.godot))
    for root in (before, after):
        if not (root / RUNNER).is_file() or not (root / "godot/project.godot").is_file():
            parser.error(f"not a complete project checkout: {root}")
    if not godot.is_file():
        parser.error(f"Godot executable not found: {godot}")
    if before == after:
        parser.error("before and after must be different frozen checkouts")
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error(f"output must be new or empty: {out}")
    heads = {str(root): head(root) for root in (before, after)}
    for root in (before, after):
        require_frozen(root, heads[str(root)])
    out.mkdir(parents=True, exist_ok=True)
    runner = out / "legion_balance_runner.gd"
    runner.write_bytes((after / RUNNER).read_bytes())
    runner_hash = sha256(runner)
    maps, profiles, seeds = (MAPS[:1], PROFILES[:1], SEEDS[:1]) if args.pilot else (MAPS, PROFILES, SEEDS)
    manifest = {"before": str(before), "after": str(after), "godot": str(godot),
                "runner": str(runner), "runner_sha256": runner_hash,
                "maps": maps, "profiles": profiles, "seeds": seeds,
                "policy": "selective", "steps": 8, "fixed_fps": 60,
                "quit_on_end": True, "parallel": 1,
                "heads": heads, "expected_runs": len(maps) * len(profiles) * len(seeds) * 2}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    rows = []
    try:
        for side, root in (("before", before), ("after", after)):
            for map_id in maps:
                for profile in profiles:
                    for seed in seeds:
                        if sha256(runner) != runner_hash:
                            raise RuntimeError("frozen runner changed during series")
                        require_frozen(root, heads[str(root)])
                        row = one_run(root, out, godot, side, map_id, profile, seed, runner)
                        require_frozen(root, heads[str(root)])
                        if sha256(runner) != runner_hash:
                            raise RuntimeError("frozen runner changed during run")
                        rows.append(row)
                        checkpoint = out / "partial-results.tmp"
                        checkpoint.write_text(json.dumps(rows, indent=2), encoding="utf-8")
                        checkpoint.replace(out / "partial-results.json")
                        print(f"{side} {map_id} {profile} {seed}: {row['result']} hp={row['hp']}",
                              flush=True)
    except (OSError, subprocess.SubprocessError, RuntimeError, KeyError, ValueError) as exc:
        (out / "partial-results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
        print(f"INVALID SERIES: {exc}", file=sys.stderr)
        return 1
    (out / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    lines = ["|side|map|profile|wins|HP median|min mana median|", "|---|---|---|---:|---:|---:|"]
    for side in ("before", "after"):
        for map_id in maps:
            for profile in profiles:
                group = [r for r in rows if (r["side"], r["map"], r["profile"])
                         == (side, map_id, profile)]
                wins = sum(r["result"] == "victory" for r in group)
                hp = statistics.median(r["hp"] for r in group)
                mana = statistics.median(r["mana_min"] for r in group)
                lines.append(f"|{side}|{map_id}|{profile}|{wins}/{len(group)}|{hp:.1f}|{mana:.1f}|")
    (out / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
