"""Run the gate's Daily Board HTTP test against an owned loopback fixture.

The ordinary gate discovers every legion_*_test.gd. This one needs a real
service, so it must never silently run with an empty endpoint or shared DB.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

import psutil

from night_pilot.owned_process import ProcessOwner


STOP_REQUESTED = False


def request_stop(_signum: int, _frame: object) -> None:
    # Defer teardown until spawn has returned its owned process identity.
    global STOP_REQUESTED
    STOP_REQUESTED = True


def check_abort(deadline: float) -> None:
    if STOP_REQUESTED:
        raise RuntimeError("Daily Board interrupted by signal")
    if time.monotonic() >= deadline:
        raise RuntimeError("Daily Board whole fixture timed out")
    if psutil.virtual_memory().available < 3 * 1024 ** 3:
        raise RuntimeError("Daily Board fixture reached 3 GiB RAM floor")


def main() -> int:
    global STOP_REQUESTED
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--appdata", required=True, type=Path)
    parser.add_argument("--timeout", required=True, type=int)
    args = parser.parse_args()
    if os.name != "nt" and not sys.platform.startswith("linux"):
        print("Daily Board INCOMPLETE: unsupported user-data isolation on this platform", flush=True)
        return 77
    if args.timeout < 15:
        parser.error("--timeout must be at least 15 seconds (includes owned teardown)")
    STOP_REQUESTED = False
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    # One budget covers readiness and the engine; reserve two 5s stops plus I/O.
    whole_deadline = time.monotonic() + args.timeout - 12
    root = Path(__file__).resolve().parent.parent
    stage = Path(tempfile.mkdtemp(prefix="daily-board-", dir=args.out.resolve()))
    gib = 1024 ** 3
    available = psutil.virtual_memory().available
    (stage / "admission.json").write_text(json.dumps({"available": available,
        "admission": 4 * gib, "floor": 3 * gib}), encoding="utf-8")
    if available < 4 * gib:
        print("Daily Board gate fixture FAIL: RAM below 4 GiB admission", flush=True)
        return 1
    service_job = ProcessOwner()
    engine_job = ProcessOwner()
    service = None
    engine = None
    offline = socket.socket()
    offline.bind(("127.0.0.1", 0))
    env = dict(os.environ)
    profile = args.appdata.resolve()
    env.update(APPDATA=str(profile), XDG_DATA_HOME=str(profile),
               XDG_CONFIG_HOME=str(profile / "config"),
               XDG_CACHE_HOME=str(profile / "cache"), NECRO_NO_METRICS="1",
               NECRO_NO_DEV_BRIDGE="1",
               NECRO_BOARD_OFFLINE_URL=f"http://127.0.0.1:{offline.getsockname()[1]}")
    env.pop("NECRO_DEV_BRIDGE", None)
    for directory in (profile, profile / "config", profile / "cache"):
        directory.mkdir(parents=True, exist_ok=True)
    result = {"stage": str(stage), "service": None, "engine": None,
              "profile_env": {key: env[key] for key in
                              ("APPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME")},
              "endpoint": None, "service_remaining": None, "engine_remaining": None}
    try:
        check_abort(whole_deadline)
        with (stage / "service.log").open("w", encoding="utf-8") as service_log:
            service, service_identity = service_job.spawn(
                [sys.executable, "-u", str(root / "tools/server/daily_board_service.py"),
                 "--db", str(stage / "board.sqlite3"), "--port", "0"],
                cwd=str(root), env=env, stdout=service_log, stderr=subprocess.STDOUT)
            result["service"] = service_identity
            deadline = time.monotonic() + min(10, args.timeout / 4)
            port = None
            while time.monotonic() < deadline and service.poll() is None:
                check_abort(whole_deadline)
                lines = (stage / "service.log").read_text(encoding="utf-8").splitlines()
                if lines:
                    port = json.loads(lines[0])["port"]
                    break
                time.sleep(.1)
            check_abort(whole_deadline)
            if port is None or service.poll() is not None:
                raise RuntimeError("Daily Board loopback service failed readiness")
            env["NECRO_DAILY_BOARD_URL"] = f"http://127.0.0.1:{port}"
            result["endpoint"] = env["NECRO_DAILY_BOARD_URL"]
            command = [args.godot, "--headless", "--path", str(root / "godot"),
                       "--fixed-fps", "60", "--script",
                       "res://tests/legion_daily_board_test.gd", "--", "--mute"]
            with (stage / "engine.log").open("w", encoding="utf-8") as engine_log:
                engine, engine_identity = engine_job.spawn(
                    command, cwd=str(root), env=env, stdout=engine_log,
                    stderr=subprocess.STDOUT)
                result["engine"] = engine_identity
                while engine.poll() is None:
                    check_abort(whole_deadline)
                    time.sleep(.1)
                engine.wait(timeout=5)
                check_abort(whole_deadline)
            raw = (stage / "engine.log").read_text(encoding="utf-8", errors="replace")
            print(raw, end="" if raw.endswith("\n") else "\n", flush=True)
            result["exit"] = engine.returncode
            result["diagnostics"] = [line for line in raw.splitlines()
                                     if any(x in line for x in ("ERROR:", "WARNING:",
                                                                "SCRIPT ERROR:"))]
            return int(engine.returncode != 0 or bool(result["diagnostics"])
                       or "DAILY BOARD:" not in raw)
    except Exception as error:
        print(f"Daily Board gate fixture FAIL: {error}", flush=True)
        if (stage / "service.log").exists():
            print((stage / "service.log").read_text(encoding="utf-8", errors="replace"), flush=True)
        if (stage / "engine.log").exists():
            print((stage / "engine.log").read_text(encoding="utf-8", errors="replace"), flush=True)
        result["error"] = str(error)
        return 1
    finally:
        result["engine_stop"] = engine_job.stop()
        result["service_stop"] = service_job.stop()
        result["engine_remaining"] = engine_job.remaining()
        result["service_remaining"] = service_job.remaining()
        engine_job.close()
        service_job.close()
        offline.close()
        (stage / "result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False),
                                           encoding="utf-8")
        if result["engine_remaining"] or result["service_remaining"]:
            raise RuntimeError("Daily Board owned process remained after teardown")


if __name__ == "__main__":
    raise SystemExit(main())
