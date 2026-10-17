"""Bounded local replay runner. No score submission or production capture.

python tools/replay/run_input_replay.py --engine PATH --out NEW_DIRECTORY [--import]
python tools/replay/run_input_replay.py --engine PATH --out NEW_DIRECTORY --replay FILE

Default: native semantic fixture recording, separate-process playback, then negatives.
Every engine uses an isolated profile, owned process containment and RAM admission.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

import psutil

TREE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(TREE / "tools"))
from night_pilot.owned_process import ProcessOwner

GIB = 1024**3
STOP_REQUESTED = False
TOTAL_DEADLINE = float("inf")


def request_stop(_signum, _frame):
    # Defer teardown to the normal finally block, including a signal during spawn.
    global STOP_REQUESTED
    STOP_REQUESTED = True


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def source():
    # Source identity covers the actual working bytes, including uncommitted helper/tests.
    # Art/audio are not part of this headless simulation identity; see README limitations.
    files = [p for p in (TREE / "godot").rglob("*") if p.is_file()
             and ".godot" not in p.parts and
             (p.suffix in (".gd", ".json", ".tscn", ".tres") or p.name == "project.godot")]
    manifest = {p.relative_to(TREE).as_posix(): sha(p) for p in sorted(files)}
    return manifest, hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()


def owner():
    if os.name == "nt":
        base = Path(os.environ["APPDATA"]) / "Godot/app_userdata/Некромант на аутсорсе"
    elif sys.platform == "darwin":
        base = Path.home() / "Library/Application Support/Godot/app_userdata/Некромант на аутсорсе"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "godot/app_userdata/Некромант на аутсорсе"
    return {str(p): [sha(p), p.stat().st_mtime_ns] for p in base.rglob("*") if p.is_file()} if base.exists() else {}


def launch(engine, out, name, mode, replay_file, identities, importing=False):
    if STOP_REQUESTED or time.monotonic() >= TOTAL_DEADLINE:
        raise InterruptedError("replay runner interrupted or total deadline reached")
    folder = out / name
    folder.mkdir()
    available = psutil.virtual_memory().available
    write(folder / "admission.json", {"available": available, "admission": 4 * GIB, "floor": 3 * GIB})
    if available < 4 * GIB:
        raise RuntimeError("RAM below 4 GiB admission")
    appdata = folder / "appdata"
    appdata.mkdir()
    env = dict(os.environ, APPDATA=str(appdata), XDG_DATA_HOME=str(appdata),
               XDG_CONFIG_HOME=str(appdata / "config"), XDG_CACHE_HOME=str(appdata / "cache"),
               NECRO_NO_METRICS="1", NECRO_NO_DEV_BRIDGE="1",
               REPLAY_MODE=mode, REPLAY_FILE=str(replay_file), REPLAY_RESULT=str(folder / "engine-result.json"),
               REPLAY_CODE_SHA256=identities["code"], REPLAY_ENGINE_SHA256=identities["engine"])
    env.pop("NECRO_DEV_BRIDGE", None)
    cmd = [str(engine), "--headless", "--path", str(TREE / "godot")]
    cmd += ["--editor", "--import", "--quit"] if importing else [
        "--fixed-fps", "60", "--script", "res://tests/legion_input_replay_driver.gd"]
    cmd += ["--", "--mute"]
    job = ProcessOwner()
    deadline = 900 if importing else 240
    result = {"command": cmd, "timeout": deadline, "stop": None}
    started = time.monotonic()
    try:
        with (folder / "engine.log").open("w", encoding="utf-8") as log:
            proc, ident = job.spawn(cmd, cwd=str(TREE), env=env, stdout=log, stderr=subprocess.STDOUT)
            write(folder / "launch.json", {"identity": ident, "command": cmd, "appdata": str(appdata)})
            while proc.poll() is None:
                if (STOP_REQUESTED or time.monotonic() >= TOTAL_DEADLINE
                        or time.monotonic() - started > deadline or psutil.virtual_memory().available < 3 * GIB):
                    result["stop"] = "signal, timeout or RAM floor"
                    job.stop()
                    break
                job.remaining()
                time.sleep(0.2)
            proc.wait(timeout=10)
        result["exit_code"] = proc.returncode
        raw = (folder / "engine.log").read_text(encoding="utf-8", errors="replace")
        result["diagnostics"] = [s for s in raw.splitlines() if any(x in s for x in ("ERROR:", "WARNING:", "SCRIPT ERROR:"))]
        report = folder / "engine-result.json"
        result["report"] = json.loads(report.read_text(encoding="utf-8")) if report.exists() else None
    finally:
        if job.remaining():
            job.stop()
        result["owned_job_final"] = job.remaining()
        job.close()
        result["elapsed"] = time.monotonic() - started
        write(folder / "result.json", result)
    if result["stop"] or result["owned_job_final"] or result["diagnostics"]:
        raise RuntimeError(f"{name}: engine diagnostics/containment failure; see {folder}")
    if importing:
        if result["exit_code"] != 0:
            raise RuntimeError("import failed")
    elif result["report"] is None:
        raise RuntimeError(f"{name}: no engine result")
    return result


def main():
    global TOTAL_DEADLINE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--import", dest="do_import", action="store_true")
    parser.add_argument("--replay", type=Path)
    parser.add_argument("--record-only", action="store_true", help="record one compatible neutral fixture for offline worker")
    parser.add_argument("--timeout", type=int, default=900, help="whole lifecycle seconds, including teardown")
    args = parser.parse_args()
    if os.name != "nt" and not sys.platform.startswith("linux"):
        # APPDATA/XDG_DATA_HOME do not isolate Godot's native macOS user://.
        # Do not launch against the owner's real profile or pretend this is a PASS.
        print(f"INPUT REPLAY UNSUPPORTED: isolated profile on {sys.platform}; no engine launched", flush=True)
        return 77
    if args.timeout < 10:
        parser.error("--timeout must be at least 10 seconds")
    if args.record_only and args.replay:
        parser.error("--record-only cannot be combined with --replay")
    TOTAL_DEADLINE = time.monotonic() + args.timeout - 5
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, request_stop)
    resolved_engine = shutil.which(args.engine)
    if resolved_engine is None:
        parser.error("engine executable not found")
    args.engine = Path(resolved_engine).resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    before, code = source()
    owner_before = owner()
    runner_before = sha(Path(__file__))
    identities = {"code": code, "engine": sha(args.engine)}
    write(out / "before.json", {"source": before, "identity": identities, "owner": owner_before, "runner": runner_before,
          "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=TREE, text=True).strip()})
    results = {"completed": False}
    try:
        if args.do_import:
            launch(args.engine, out, "import", "", out / "unused.json", identities, True)
        if args.replay:
            replay = launch(args.engine, out, "replay", "replay", args.replay.resolve(), identities)
            results["replay"] = replay["exit_code"] == 0 and replay["report"]["error"] == ""
        else:
            envelope = out / "recording.json"
            record = launch(args.engine, out, "record", "record", envelope, identities)
            results["record"] = record["exit_code"] == 0 and record["report"]["error"] == ""
            if not results["record"]:
                raise RuntimeError("fixture recording failed")
            if not args.record_only:
                replay = launch(args.engine, out, "replay", "replay", envelope, identities)
            else:
                replay = None
            if replay is not None:
                results["replay"] = replay["exit_code"] == 0 and replay["report"]["error"] == ""
                if not results["replay"]:
                    raise RuntimeError("separate-process playback failed")
                results["score_equal"] = record["report"]["score"] == replay["report"]["score"]
            if not args.record_only:
                base = json.loads(envelope.read_text(encoding="utf-8"))
                cases = []
                def case(name, mutate, expected, tick):
                    data = copy.deepcopy(base)
                    mutate(data)
                    cases.append((name, data, expected, tick))
                case("schema", lambda d: d.update(schema=2), "schema identity", -1)
                case("code", lambda d: d["identity"].update(code_sha256="0" * 64), "runtime identity", -1)
                case("generator", lambda d: d["identity"].update(generator=0), "runtime identity", -1)
                case("fractional-tick", lambda d: d["events"][0].update(tick=10.5), "event order", -1)
                case("late-event", lambda d: d["events"][-1].update(tick=d["ticks"]), "event order", -1)
                case("wrong-side", lambda d: d["events"][0].update(side=1), "event order", -1)
                case("unknown-input", lambda d: d["events"][0]["command"].update(type="call_wave"), "command encoding", -1)
                case("unknown-field", lambda d: d["events"][0]["command"].update(extra=True), "command encoding", -1)
                case("snapshot", lambda d: d.update(initial="AAAA"), "initial state mismatch", 0)
                case("snapshot-encoding", lambda d: d.update(initial="????"), "snapshot encoding", -1)
                case("progression", lambda d: d["config"].update(progression="campaign"), "unsupported config", -1)
                for field in ("difficulty", "progression"):
                    for suffix, value in (("object", {}), ("array", []), ("bool", True), ("fraction", 1.5), ("null", None)):
                        case(f"{field}-{suffix}", lambda d, f=field, v=value: d["config"].update({f: v}),
                             "unsupported config", -1)
                case("command-type-object", lambda d: d["events"][0]["command"].update(type={}), "command encoding", -1)
                case("tamper-stroke", lambda d: d["events"][0]["command"]["pts"].__setitem__(0, 3000), "state mismatch at tick 11", 11)
                case("tamper-score", lambda d: d["score"].update(kills=999), "score mismatch", base["ticks"])
                for name, data, expected, tick in cases:
                    path = out / f"negative-{name}.json"
                    write(path, data)
                    result = launch(args.engine, out, name, "replay", path, identities)
                    results[name] = result["exit_code"] == 1 and result["report"]["error"] == expected and result["report"]["tick"] == tick
                    print(name, results[name], result["report"]["error"], flush=True)
        results["completed"] = True
    finally:
        after, code_after = source()
        owner_after = owner()
        runner_after = sha(Path(__file__))
        write(out / "after.json", {"source": after, "code": code_after, "owner": owner_after, "runner": runner_after})
        results["source_unchanged"] = before == after
        results["owner_unchanged"] = owner_before == owner_after
        results["runner_unchanged"] = runner_before == runner_after
        results["not_interrupted"] = not STOP_REQUESTED
        write(out / "result.json", results)
    print(json.dumps(results), flush=True)
    return 0 if results and all(results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
