#!/usr/bin/env python3
"""Строгая последовательная парная серия на процедурных картах gen:<seed>:<k>.

Пример:
  python tools/procgen_pair.py C:/путь/before C:/путь/after \
    --out C:/AI/necro/batches/legion/series/procgen-pair-<sha> \
    --runner godot/tests/legion_balance_runner.gd

Матрица: gen seeds 5,6,7,8 × k 1,2,3,5,8,12,16,20 × bot seeds 1..5 × 2 стороны = 320
прогонов (по 160 на сторону), по одному процессу за раз. Профиль base,
бот selective, сложность normal передаются явно. Один замороженный runner-файл для обеих
веток: копия в OUT, SHA сверяется до/после каждого прогона; HEAD и чистота чекаутов — тоже.
Итог (results.json + summary) пишется только при полной уникальной матрице. Resume нет.
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
    "C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe")
RUNNER_DEFAULT = "godot/tests/legion_balance_runner.gd"
GEN_SEEDS = (5, 6, 7, 8)
KS = (1, 2, 3, 5, 8, 12, 16, 20)
BOT_SEEDS = (1, 2, 3, 4, 5)
BOT = "selective"
STEPS = 8
TIMEOUT = 1800


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def head(root: pathlib.Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()


def require_frozen(root: pathlib.Path, expected: str) -> None:
    if head(root) != expected:
        raise RuntimeError(f"checkout HEAD changed: {root}")
    dirty = subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"],
        text=True)
    if dirty:
        raise RuntimeError(f"tracked checkout changes during series: {root}")


def finite_nonnegative(value, label: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) \
            or not math.isfinite(value) or value < 0:
        raise RuntimeError(f"invalid numeric metric {label}: {value!r}")


def finite_json_number(token: str) -> float:
    value = float(token)
    if not math.isfinite(value):
        raise ValueError(f"non-finite JSON number: {token}")
    return value


def one_run(root: pathlib.Path, out: pathlib.Path, godot: pathlib.Path,
            side: str, gen_seed: int, k: int, bot_seed: int,
            runner: pathlib.Path) -> dict:
    map_id = f"gen:{gen_seed}:{k}"
    stem = f"{side}_{map_id.replace(':', '_')}_selective_base_s{bot_seed}"
    log_path = out / f"{stem}.log"
    appdata = out / "appdata" / stem
    appdata.mkdir(parents=True, exist_ok=True)
    cmd = [str(godot), "--headless", "--path", str(root / "godot"),
           "--fixed-fps", "60", "--quit-after", "90000", "--script", str(runner),
           "--", "--mute", "--trace", "--bot", BOT, "--seed", str(bot_seed),
           "--map", map_id, "--quit-on-end", "--dev", f"steps={STEPS}",
           "--dev", "profile=base", "--dev", "difficulty=normal"]
    env = os.environ.copy()
    env["APPDATA"] = str(appdata)
    with log_path.open("w", encoding="utf-8", newline="\n") as log:
        proc = subprocess.Popen(cmd, cwd=root, env=env, stdout=log,
                                stderr=subprocess.STDOUT,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            # Консольный Godot порождает GUI-бинарь: убираем только своё дерево.
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                               stdout=log, stderr=subprocess.STDOUT, check=False,
                               creationflags=subprocess.CREATE_NO_WINDOW)
            else:
                proc.kill()
            proc.wait()
            raise
    text = log_path.read_text(encoding="utf-8", errors="replace")
    result_rows = [
        json.loads(line, parse_float=finite_json_number, parse_constant=finite_json_number)
        for line in text.splitlines()
        if line.startswith("{") and '"result"' in line]
    cleanup = [line for line in text.splitlines()
               if line.startswith("ERROR:") and "resources still in use at exit" in line]
    errors = [line for line in text.splitlines()
              if "ERROR:" in line and line not in cleanup]
    if proc.returncode != 0 or len(result_rows) != 1 or "SCRIPT ERROR" in text or errors:
        raise RuntimeError(f"invalid run {stem}: exit={proc.returncode}, log={log_path}")
    row = result_rows[0]
    if not isinstance(row, dict) or row.get("result") not in ("victory", "defeat"):
        raise RuntimeError(f"invalid result in {log_path}")
    for field, expected in (("map", map_id), ("bot", BOT), ("seed", bot_seed)):
        if row.get(field) != expected:
            raise RuntimeError(
                f"wrong {field} in {log_path}: {row.get(field)!r} != {expected!r}")
    finite_nonnegative(row.get("hp"), "hp")
    eco = row.get("eco")
    if not isinstance(eco, dict) or "mana_min" not in eco:
        raise RuntimeError(f"missing economy metrics in {log_path}")
    finite_nonnegative(eco["mana_min"], "mana_min")
    # Итоговая строка не знает сторону/параметр k — дополняем фактическими значениями прогона.
    row.update({"side": side, "gen_seed": gen_seed, "k": k, "bot_seed": bot_seed,
                "profile": "base", "policy": BOT, "log": str(log_path)})
    row["mana_min"] = eco["mana_min"]
    row["cleanup_warnings"] = cleanup
    return row


def atomic_write(path: pathlib.Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Парная серия на картах gen:<seed>:<k> по двум замороженным чекаутам.")
    parser.add_argument("before", type=pathlib.Path, help="frozen checkout «до»")
    parser.add_argument("after", type=pathlib.Path, help="frozen checkout «после»")
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--runner", type=pathlib.Path, default=pathlib.Path(RUNNER_DEFAULT),
                        help="runner .gd относительно корня чекаута (общий для обеих сторон)")
    parser.add_argument("--godot", type=pathlib.Path, default=GODOT_DEFAULT)
    args = parser.parse_args()
    before, after, out, godot = (p.resolve() for p in
                                 (args.before, args.after, args.out, args.godot))
    runner_rel = args.runner.as_posix()
    for root in (before, after):
        if not (root / runner_rel).is_file() or not (root / "godot/project.godot").is_file():
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
    # Один замороженный runner на обе стороны: копия в OUT, дальше меряем только её SHA.
    runner = out / pathlib.Path(runner_rel).name
    runner.write_bytes((after / runner_rel).read_bytes())
    if sha256(runner) != sha256(before / runner_rel):
        parser.error(f"runner differs between checkouts: {runner_rel}")
    runner_hash = sha256(runner)
    expected_keys = {(side, g, k, s)
                     for side in ("before", "after")
                     for g in GEN_SEEDS for k in KS for s in BOT_SEEDS}
    manifest = {
        "before": str(before), "after": str(after), "godot": str(godot),
        "runner": runner_rel, "runner_sha256": runner_hash,
        "gen_seeds": GEN_SEEDS, "ks": KS, "bot_seeds": BOT_SEEDS,
        "map_format": "gen:<gen_seed>:<k>", "bot": BOT, "profile": "base",
        "difficulty": "normal", "steps": STEPS,
        "fixed_fps": 60, "quit_on_end": True, "timeout_s": TIMEOUT,
        "parallel": 1, "heads": heads, "expected_runs": len(expected_keys),
    }
    atomic_write(out / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    rows = []
    try:
        for side, root in (("before", before), ("after", after)):
            for gen_seed in GEN_SEEDS:
                for k in KS:
                    for bot_seed in BOT_SEEDS:
                        if sha256(runner) != runner_hash:
                            raise RuntimeError("frozen runner changed during series")
                        for checkout in (before, after):
                            require_frozen(checkout, heads[str(checkout)])
                        row = one_run(root, out, godot, side, gen_seed, k, bot_seed, runner)
                        for checkout in (before, after):
                            require_frozen(checkout, heads[str(checkout)])
                        if sha256(runner) != runner_hash:
                            raise RuntimeError("frozen runner changed during run")
                        rows.append(row)
                        atomic_write(out / "partial-results.json",
                                     json.dumps(rows, indent=2) + "\n")
                        print(f"{side} gen:{gen_seed}:{k} s{bot_seed}: "
                              f"{row['result']} hp={row['hp']} mana_min={row['mana_min']}",
                              flush=True)
    except (OSError, subprocess.SubprocessError, RuntimeError, KeyError, ValueError) as exc:
        atomic_write(out / "partial-results.json", json.dumps(rows, indent=2) + "\n")
        print(f"INVALID SERIES: {exc}", file=sys.stderr)
        return 1
    seen = {(r["side"], r["gen_seed"], r["k"], r["bot_seed"]) for r in rows}
    if len(rows) != len(expected_keys) or seen != expected_keys:
        print(f"INVALID SERIES: incomplete/duplicate matrix: {len(rows)} rows, "
              f"{len(seen)} unique", file=sys.stderr)
        return 1
    atomic_write(out / "results.json", json.dumps(rows, indent=2) + "\n")
    lines = ["|k|side|wins|HP median|mana_min median|", "|---|---|---|---:|---:|"]
    for k in KS:
        for side in ("before", "after"):
            group = [r for r in rows if r["k"] == k and r["side"] == side]
            wins = sum(r["result"] == "victory" for r in group)
            hp = statistics.median(r["hp"] for r in group)
            mana = statistics.median(r["mana_min"] for r in group)
            lines.append(f"|{k}|{side}|{wins}/{len(group)}|{hp:.1f}|{mana:.1f}|")
    atomic_write(out / "summary.md", "\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
