"""Offline neutral-checkpoint replay receipt. Never issues a verified score.

python tools/replay/local_worker.py --engine PATH --manifest FILE --replay FILE --out NEW_DIR
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import sys
import time

import run_input_replay as runner

MAX_MANIFEST = 4096
MAX_REPLAY = 8 * 1024 * 1024
HEX = frozenset("0123456789abcdef")


def hex64(value):
    return isinstance(value, str) and len(value) == 64 and set(value) <= HEX


def finite_number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(float(value))
    except OverflowError:
        return False


def read_bounded(path, limit):
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if not data or len(data) > limit:
        raise ValueError("empty or oversized input")
    return data


def preflight(manifest_data, replay_data, identities):
    try:
        manifest = json.loads(manifest_data)
        replay = json.loads(replay_data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid JSON") from exc
    if not isinstance(manifest, dict) or set(manifest) != {"schema", "kind", "identity", "replay_sha256"}:
        raise ValueError("manifest keys")
    if type(manifest["schema"]) is not int or manifest["schema"] != 1 or manifest["kind"] != "neutral_checkpoint":
        raise ValueError("unsupported manifest kind/schema")
    pinned = manifest["identity"]
    if not isinstance(pinned, dict) or set(pinned) != {"code_sha256", "engine_sha256"} or not all(map(hex64, pinned.values())):
        raise ValueError("manifest identity")
    if pinned != {"code_sha256": identities["code"], "engine_sha256": identities["engine"]}:
        raise ValueError("runtime identity mismatch")
    replay_hash = hashlib.sha256(replay_data).hexdigest()
    if not hex64(manifest["replay_sha256"]) or manifest["replay_sha256"] != replay_hash:
        raise ValueError("replay hash mismatch")
    if not isinstance(replay, dict) or type(replay.get("schema")) is not int or replay["schema"] != 1:
        raise ValueError("unsupported replay schema")
    cfg = replay.get("config")
    if not isinstance(cfg, dict) or set(cfg) != {"map", "seed", "difficulty", "progression", "tick_hz", "side"}:
        raise ValueError("unsupported replay config")
    if cfg["progression"] != "neutral" or type(cfg["side"]) is not int or cfg["side"] != 0 or type(cfg["tick_hz"]) is not int or cfg["tick_hz"] != 60:
        raise ValueError("unsupported replay progression")
    map_name = cfg["map"]
    if not isinstance(map_name, str) or not 1 <= len(map_name) <= 80 or any(piece in map_name for piece in ("/", "\\", "..")) or not (runner.TREE / "godot/assets/legion/maps" / f"{map_name}.json").is_file():
        raise ValueError("unsupported replay map")
    if type(cfg["seed"]) is not int or not 0 <= cfg["seed"] <= 2147483647 or cfg["difficulty"] not in ("intern", "normal", "hell"):
        raise ValueError("unsupported replay setup")
    envelope_identity = replay.get("identity")
    if not isinstance(envelope_identity, dict) or envelope_identity.get("code_sha256") != identities["code"] or envelope_identity.get("engine_sha256") != identities["engine"]:
        raise ValueError("replay runtime identity mismatch")
    return replay_hash


def native_result(result, replay_data):
    """Classify a completed guarded child; malformed native evidence fails closed."""
    if not isinstance(result, dict) or not {"exit_code", "stop", "diagnostics", "report", "owned_job_final"} <= result.keys():
        return "worker_failure", "missing runner result", None
    if result["stop"] is not None or result["diagnostics"] != [] or result["owned_job_final"] != []:
        return "worker_failure", "native diagnostics or containment failure", None
    report = result["report"]
    if not isinstance(report, dict) or not {"checks", "error", "failures", "mode", "tick"} <= report.keys():
        return "worker_failure", "malformed native report", None
    tick = report["tick"]
    if report["mode"] != "replay" or type(tick) is not int or type(report["checks"]) is not int or report["checks"] < 0 or report["failures"] != [] or not isinstance(report["error"], str):
        return "worker_failure", "malformed native report", None
    try:
        replay = json.loads(replay_data)
        total = replay["ticks"]
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError):
        return "worker_failure", "malformed copied replay", None
    if not finite_number(total) or not 1 <= total <= 3600 or total != int(total):
        return "worker_failure", "malformed replay tick count", None
    if result["exit_code"] == 0:
        if set(report) != {"checks", "effects", "error", "failures", "mode", "score", "tick"} or report["error"] != "" or tick != total or report["checks"] != 2:
            return "worker_failure", "malformed native success report", tick
        effects = report["effects"]
        if not isinstance(effects, dict) or set(effects) != {"draw", "release", "cast", "build"} or any(type(n) is not int or n < 0 for n in effects.values()):
            return "worker_failure", "malformed native effects", tick
        score = report["score"]
        expected = replay.get("score")
        keys = {"hp", "t", "wave", "kills", "lost", "souls", "phase"}
        if not isinstance(score, dict) or not isinstance(expected, dict) or set(score) != keys or set(expected) != keys:
            return "worker_failure", "malformed native score", tick
        if any(not finite_number(value) for value in (*score.values(), *expected.values())) or score != expected:
            return "worker_failure", "native score differs from replay", tick
        return "matched", "neutral checkpoint reproduced", tick
    if result["exit_code"] == 1 and report["error"] and -1 <= tick <= total:
        error = report["error"]
        divergence = (error.startswith("state mismatch at tick ") or
                      error.startswith("command outcome mismatch at tick ") or
                      error in ("score mismatch",) or error.startswith("unexpected end at tick "))
        return "diverged" if divergence else "refused", error, tick
    return "worker_failure", "native failure or malformed engine result", tick


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args(argv)
    if args.timeout < 10:
        parser.error("--timeout must be at least 10 seconds")
    if os.name != "nt" and not sys.platform.startswith("linux"):
        print(f"LOCAL REPLAY UNSUPPORTED: isolated profile on {sys.platform}; no engine launched", flush=True)
        return 77
    engine_name = shutil.which(args.engine)
    if engine_name is None:
        parser.error("engine executable not found")
    engine = Path(engine_name).resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    receipt = {"schema": 1, "kind": "neutral_checkpoint_receipt", "status": "worker_failure",
               "reason": "worker did not complete", "tick": None, "verified": False,
               "score_eligible": False, "replay_sha256": None}
    runner.STOP_REQUESTED = False
    runner.TOTAL_DEADLINE = time.monotonic() + args.timeout - 5
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, runner.request_stop)
    before = None
    owner_before = None
    worker_before = runner.sha(Path(__file__))
    runner_before = runner.sha(Path(runner.__file__))
    try:
        before, code = runner.source()
        owner_before = runner.owner()
        identities = {"code": code, "engine": runner.sha(engine)}
        runner.write(out / "before.json", {"source": before, "identity": identities, "owner": owner_before,
                     "worker": worker_before, "runner": runner_before})
        try:
            manifest_data = read_bounded(args.manifest, MAX_MANIFEST)
            replay_data = read_bounded(args.replay, MAX_REPLAY)
            receipt["replay_sha256"] = preflight(manifest_data, replay_data, identities)
        except (OSError, ValueError) as exc:
            receipt.update(status="refused", reason=str(exc))
        else:
            # Run the exact bytes that passed preflight, even if the caller changes its file.
            copied = out / "input.json"
            copied.write_bytes(replay_data)
            result = runner.launch(engine, out, "replay", "replay", copied, identities)
            status, reason, tick = native_result(result, replay_data)
            receipt.update(status=status, reason=reason, tick=tick)
    except (Exception, KeyboardInterrupt) as exc:
        receipt.update(status="worker_failure", reason=f"{type(exc).__name__}: {exc}")
    finally:
        try:
            after, code_after = runner.source()
            owner_after = runner.owner()
            guards = {"source_unchanged": before == after if before is not None else False,
                      "owner_unchanged": owner_before == owner_after if owner_before is not None else False,
                      "worker_unchanged": worker_before == runner.sha(Path(__file__)),
                      "runner_unchanged": runner_before == runner.sha(Path(runner.__file__)),
                      "worker_not_interrupted": not runner.STOP_REQUESTED,
                      "deadline_ok": time.monotonic() < runner.TOTAL_DEADLINE}
            runner.write(out / "after.json", {"source": after, "code": code_after, "owner": owner_after, "guards": guards})
            if not all(guards.values()):
                failed = ", ".join(name for name, ok in guards.items() if not ok)
                prior = receipt["reason"] if receipt["reason"] != "worker did not complete" else ""
                receipt.update(status="worker_failure", reason=f"{prior}; post-run guard failed: {failed}".lstrip("; "))
        except Exception as exc:
            receipt.update(status="worker_failure", reason=f"post-run guard: {type(exc).__name__}: {exc}")
        runner.write(out / "receipt.json", receipt)
    print(json.dumps(receipt, ensure_ascii=False), flush=True)
    return 0 if receipt["status"] == "matched" else 1


if __name__ == "__main__":
    raise SystemExit(main())
