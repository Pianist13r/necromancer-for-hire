"""Mandatory exclusive gate fixtures; no engine on import or policy queries.

The gate drains ordinary work before this dispatcher. A registered test cannot
fall back to an ordinary shell launch or inherit a dev-save override.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

import psutil

from night_pilot.owned_process import ProcessOwner

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "tools/legion_gate_resources.json"
NAME = "legion_solo_input_capture_test"
GIB = 1024 ** 3
STOP_REQUESTED = False
EXPECTED_POLICY = {"execution": "exclusive", "resource_class": "daily_solo_capture_unmeasured",
                   "admission_gib": 8, "floor_gib": 6, "native_timeout_s": 120,
                   "cleanup_reserve_s": 12, "measured_peak_bytes": None, "measurement_evidence": None}
SOURCE_PATHS = ("godot/project.godot", "godot/tests/legion_solo_input_capture_test.gd",
                "godot/scripts/dev/solo_input_capture.gd", "godot/scripts/dev/daily_solo_capture_probe.gd",
                "godot/scripts/legion/legion_world.gd", "godot/scripts/legion/contract_field.gd",
                "godot/scripts/legion/snap/snap_world.gd", "tools/legion_gate_owned_test.py",
                "tools/legion_gate.sh", "tools/legion_gate_resources.json", "tools/night_pilot/owned_process.py",
                "tools/night_pilot/owned_job.py")
DIAGNOSTIC = re.compile(r"ERROR:|WARNING:|SCRIPT ERROR|Parse Error|leaked|still in use|PagedAllocator", re.I)


def require(ok: bool, reason: str) -> None:
    if not ok:
        raise RuntimeError(reason)


def policy() -> dict:
    data = json.loads(POLICY.read_text(encoding="utf-8"))
    require(data.get("schema") == "legion-gate-resource-policy-v1"
            and data.get("tests") == {NAME: EXPECTED_POLICY}, "mandatory resource policy drift")
    require((ROOT / f"godot/tests/{NAME}.gd").is_file(), "mandatory fixture missing")
    return data["tests"]


def plain(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        if os.path.lexists(part):
            info = part.lstat()
            require(not stat.S_ISLNK(info.st_mode)
                    and not (getattr(info, "st_file_attributes", 0) & 0x400), "reparse path refused: " + str(part))
    require(path.resolve() == path, "lexical/actual path mismatch")
    return path


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save(path: Path, data: object) -> None:
    with path.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def source_snapshot() -> dict:
    # The surrounding full gate owns the broader frozen source inventory. These
    # exact capture seams and dispatch dependencies are checked in every entry path.
    files = {name: sha(ROOT / name) for name in SOURCE_PATHS}
    return {"files": files,
            "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "status": subprocess.check_output(["git", "status", "--porcelain=v1",
                                                "--untracked-files=all"], cwd=ROOT, text=True)}


def owner_folder(appdata: str, xdg_data: str) -> Path:
    if os.name == "nt":
        require(bool(appdata), "original owner APPDATA required before gate rewrite")
        return Path(appdata) / "Godot/app_userdata/Некромант на аутсорсе"
    base = Path(xdg_data) if xdg_data else Path.home() / ".local/share"
    return base / "godot/app_userdata/Некромант на аутсорсе"


def owner_snapshot(folder: Path) -> dict:
    return {path.relative_to(folder).as_posix(): [sha(path), path.stat().st_mtime_ns]
            for path in folder.rglob("*") if path.is_file() and ".cfg" in path.name} if folder.exists() else {}


def other_engines() -> list[dict]:
    found = []
    for process in psutil.process_iter(["pid", "name", "exe", "create_time"], ad_value=None):
        info = process.info
        names = (str(info.get("name") or ""), Path(str(info.get("exe") or "")).name)
        if any(name.lower().startswith(("godot", "necromancer")) for name in names):
            found.append({key: info.get(key) for key in ("pid", "name", "exe", "create_time")})
    return found


def environment(stage: Path) -> dict:
    for name in ("appdata", "localappdata", "temp"):
        plain(stage / name).mkdir()
    profile, temporary = stage / "appdata", stage / "temp"
    env = dict(os.environ)
    for key in list(env):
        if key.upper().startswith(("QA_", "NECRO_QA_")) or key.upper() == "NECRO_DEV_BRIDGE":
            env.pop(key)
    env.update(APPDATA=str(profile), LOCALAPPDATA=str(stage / "localappdata"),
               XDG_DATA_HOME=str(profile), XDG_CONFIG_HOME=str(profile / "config"),
               XDG_CACHE_HOME=str(profile / "cache"), TEMP=str(temporary), TMP=str(temporary),
               TMPDIR=str(temporary), NECRO_NO_METRICS="1", NECRO_NO_DEV_BRIDGE="1",
               NECRO_DAILY_BOARD_URL="")
    return env


def command(engine: Path, name: str) -> list[str]:
    require(name == NAME, "unregistered exclusive test")
    return [str(engine), "--headless", "--path", str(ROOT / "godot"), "--fixed-fps", "60",
            "--script", f"res://tests/{name}.gd", "--", "--mute"]


def request_stop(_signum: int, _frame: object) -> None:
    global STOP_REQUESTED
    STOP_REQUESTED = True


def check_work(deadline: float) -> int:
    require(not STOP_REQUESTED, "exclusive fixture interrupted")
    require(time.monotonic() < deadline, "120s native work deadline")
    available = psutil.virtual_memory().available
    require(available >= 6 * GIB, "6 GiB RAM floor")
    return available


def run_test(name: str, engine: Path, out: Path, owner_appdata: str, owner_xdg: str) -> dict:
    limits = policy().get(name)
    require(limits is not None, "unregistered exclusive test")
    require(os.name == "nt" or sys.platform.startswith("linux"), "unsupported isolated userdata platform")
    out = plain(out)
    owner = owner_folder(owner_appdata, owner_xdg)
    require(not out.is_relative_to(owner.resolve()), "QA output inside owner userdata refused")
    out.mkdir(parents=True, exist_ok=True)
    stage = plain(Path(tempfile.mkdtemp(prefix=name + "-", dir=out)))
    result = {"schema": "legion-exclusive-test-v1", "test": name, "pass": False,
              "stage": str(stage), "policy": dict(limits), "failure": None,
              "cleanup_errors": [], "final_guard_errors": [], "native_exit": None,
              "resource_peak_class": "unmeasured"}
    job = proc = None
    source_before = owner_before = engine_sha = None
    began = time.monotonic()
    try:
        source_before, owner_before = source_snapshot(), owner_snapshot(owner)
        engine_sha = sha(engine)
        result["source_before"] = source_before
        result["owner_before"] = owner_before
        available = psutil.virtual_memory().available
        save(stage / "admission.json", {"available_bytes": available, "admission_bytes": 8 * GIB,
                                        "floor_bytes": 6 * GIB, "native_timeout_s": 120,
                                        "cleanup_reserve_s": 12})
        require(available >= 8 * GIB, "8 GiB RAM admission")
        require(not other_engines(), "exclusive fixture: another engine active")
        env = environment(stage)
        cmd = command(engine, name)
        save(stage / "launch.json", {"command": cmd, "engine_sha256": engine_sha,
             "owner_userdata": str(owner), "profile_env": {key: env[key] for key in
             ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
              "TEMP", "TMP", "TMPDIR", "NECRO_NO_METRICS", "NECRO_NO_DEV_BRIDGE")}})
        deadline = time.monotonic() + limits["native_timeout_s"]
        job = ProcessOwner()
        with (stage / "engine.log").open("x", encoding="utf-8") as stream:
            require(not other_engines(), "exclusive fixture: another engine at spawn")
            require(psutil.virtual_memory().available >= 8 * GIB, "8 GiB RAM admission at spawn")
            check_work(deadline)
            proc, identity = job.spawn(cmd, cwd=str(ROOT), env=env, stdout=stream, stderr=subprocess.STDOUT)
            save(stage / "identity.json", identity)
            while proc.poll() is None:
                check_work(deadline)
                job.remaining()
                time.sleep(.1)
            check_work(deadline)
            result["native_exit"] = proc.returncode
            require(proc.returncode == 0 and job.remaining() == [], "native exit/owned children")
        require(sha(engine) == engine_sha, "engine executable drift")
    except BaseException as error:
        result["failure"] = repr(error)
    finally:
        if job is not None:
            try:
                result["cleanup"] = job.stop(timeout=5)
                result["remaining"] = job.remaining()
            except BaseException as error:
                result["cleanup_errors"].append(repr(error))
            finally:
                try:
                    job.close()
                except BaseException as error:
                    result["cleanup_errors"].append(repr(error))
        if proc is not None:
            try:
                proc.wait(timeout=5)
                result["native_exit"] = proc.returncode
            except BaseException as error:
                result["cleanup_errors"].append(repr(error))
        try:
            raw = (stage / "engine.log").read_text(encoding="utf-8", errors="replace") \
                if (stage / "engine.log").is_file() else ""
            result["diagnostics"] = [line for line in raw.splitlines() if DIAGNOSTIC.search(line)]
            matches = re.findall(r"^Solo input capture native: (\d+)/(\d+)\s*$", raw, re.M)
            result["summary_valid"] = (len(matches) == 1 and matches[0][0] == matches[0][1]
                                       and int(matches[0][0]) > 0)
            result["logs"] = {}
            for path in stage.rglob("*.log*"):
                if path.is_file():
                    result["logs"][path.relative_to(stage).as_posix()] = sha(path)
                    if path != stage / "engine.log":
                        result["diagnostics"].extend(line for line in path.read_text(
                            encoding="utf-8", errors="replace").splitlines() if DIAGNOSTIC.search(line))
            result["owner_unchanged"] = owner_before is not None and owner_snapshot(owner) == owner_before
            result["source_unchanged"] = source_before is not None and source_snapshot() == source_before
            result["engine_unchanged"] = engine_sha is not None and sha(engine) == engine_sha
        except BaseException as error:
            result["final_guard_errors"].append(repr(error))
        result["seconds"] = time.monotonic() - began
        if result["failure"] is None:
            for ok, reason in ((not result.get("diagnostics"), "native/runtime diagnostics"),
                               (result.get("summary_valid") is True, "native summary missing/incomplete"),
                               (result.get("owner_unchanged") is True, "owner CFG drift"),
                               (result.get("source_unchanged") is True, "capture source/dispatch drift"),
                               (result.get("engine_unchanged") is True, "engine executable drift")):
                if not ok:
                    result["failure"] = reason
                    break
        result["pass"] = (result["failure"] is None and not result["cleanup_errors"]
                          and not result["final_guard_errors"] and result["native_exit"] == 0
                          and result.get("remaining") == [] and result.get("summary_valid") is True
                          and not result.get("diagnostics") and result.get("owner_unchanged") is True
                          and result.get("source_unchanged") is True
                          and result.get("engine_unchanged") is True
                          and result.get("cleanup", {}).get("owned_processes_dead") is True)
        save(stage / "result.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exclusive-list", action="store_true")
    parser.add_argument("--wrapper-timeout")
    parser.add_argument("--test")
    parser.add_argument("--godot")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--owner-appdata", default="")
    parser.add_argument("--owner-xdg-data", default="")
    args = parser.parse_args()
    limits = policy()
    if args.exclusive_list:
        print(" ".join(limits))
        return 0
    if args.wrapper_timeout is not None:
        require(args.wrapper_timeout in limits, "unregistered exclusive test")
        row = limits[args.wrapper_timeout]
        print(row["native_timeout_s"] + row["cleanup_reserve_s"])
        return 0
    require(args.test in limits and args.godot is not None and args.out is not None, "exclusive fixture arguments")
    resolved = shutil.which(args.godot)
    require(resolved is not None, "engine executable missing")
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, request_stop)
    result = run_test(args.test, plain(Path(resolved)), args.out, args.owner_appdata, args.owner_xdg_data)
    log = Path(result["stage"]) / "engine.log"
    if log.is_file():
        print(log.read_text(encoding="utf-8", errors="replace"), end="", flush=True)
    print("EXCLUSIVE FIXTURE " + json.dumps({"pass": result["pass"], "stage": result["stage"],
                                            "failure": result["failure"]}), flush=True)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
