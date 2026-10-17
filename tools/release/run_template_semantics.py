"""Bounded private release-template diagnostic-PCK runtime; never a product gate."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import psutil


GIB = 1024 ** 3
MARKER = "TEMPLATE_SEMANTICS_PROBE "
DIAGNOSTIC = re.compile(r"ERROR:|WARNING:|SCRIPT ERROR|leaked|still in use|PagedAllocator", re.I)


def require(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest().upper()


def save(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def git(tree, *args):
    return subprocess.check_output(["git", *args], cwd=tree, text=True).strip()


def package_files(package):
    return {p.relative_to(package).as_posix(): sha(p)
            for p in package.rglob("*") if p.is_file()}


def cfg_snapshot(directory):
    if not directory.exists():
        return {}
    return {p.relative_to(directory).as_posix(): (sha(p), p.stat().st_mtime_ns)
            for p in directory.rglob("*") if p.is_file() and ".cfg" in p.name}


def module_at(path):
    spec = importlib.util.spec_from_file_location("template_semantics_owned_job", path)
    mod = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(mod)
    require(Path(mod.__file__).resolve() == path.resolve(), "OwnedJob import path")
    return mod


def validate_payload(facts):
    require(facts["pass"] is True, "probe reported fail")
    require(facts["flags"] == {"ship": True, "editor": False,
                                "template": True, "debug": False}, "runtime flags")
    audio = facts["audio"]
    require(audio["failures"] == [] and audio["raw_setting"] == "uid://bvgjm8g4e0e8k" and
            audio["effective_setting"] == "uid://bvgjm8g4e0e8k" and
            audio["resource_loaded"] is True and audio["count"] == 4, "UID/audio")
    require([b["name"] for b in audio["buses"]] == ["Master", "Music", "SFX", "Voice"] and
            [b["effects"] for b in audio["buses"]] == [1, 2, 1, 0] and
            [b["send"] for b in audio["buses"]][1:] == ["Master"] * 3,
            "audio bus graph")
    require(facts["pipe"] == {"checks": 40, "failures": []}, "NetPipe checks")


def validate_binding(binding, binding_path, expected_sha):
    require(binding_path.is_absolute() and sha(binding_path) == expected_sha.upper(),
            "binding SHA mismatch")
    require(binding["schema"] == "necro-template-semantics-v1" and
            binding["root_reviewed"] is True, "reviewed binding required")
    tree = Path(binding["source_tree"]).resolve()
    require(git(tree, "rev-parse", "HEAD") == binding["source_head"] and
            not git(tree, "status", "--porcelain=v1", "--untracked-files=all"),
            "source HEAD/clean")
    overlay_path = Path(binding["overlay_manifest"]["path"]).resolve()
    restore_path = Path(binding["restore_report"]["path"]).resolve()
    build_path = Path(binding["build_report"]["path"]).resolve()
    require(sha(overlay_path) == binding["overlay_manifest"]["sha256"] and
            sha(restore_path) == binding["restore_report"]["sha256"] and
            sha(build_path) == binding["build_report"]["sha256"], "overlay/build/restore SHA")
    overlay = json.loads(overlay_path.read_text(encoding="utf-8"))
    restore = json.loads(restore_path.read_text(encoding="utf-8"))
    build = json.loads(build_path.read_text(encoding="utf-8"))
    require(overlay["schema"] == "necro-template-overlay-v1" and
            overlay["source_head"] == binding["source_head"] and
            restore["source_head"] == binding["source_head"] and
            restore["source_status"] == "" and
            restore["source_files"] == overlay["source_files"], "source overlay provenance")
    require(build["schema"] == "necro-template-pack-build-v1" and build["pass"] is True and
            build["source_head"] == binding["source_head"] and
            build["overlay_sha256"] == binding["overlay_manifest"]["sha256"] and
            build["restore"] == restore and
            build["stages"]["import"]["pass"] is True and
            build["stages"]["export"]["pass"] is True and
            build["package_files"] == binding["diagnostic_package_files"],
            "accepted diagnostic export provenance")
    require(sha(tree / "tools/release/template_semantics_probe.gd") ==
            overlay["probe_source_sha256"], "probe source changed")
    for relative, expected in overlay["source_files"].items():
        require(sha(tree / relative) == expected, f"source changed: {relative}")
    helper = tree / "tools/night_pilot/owned_job.py"
    require(sha(helper) == binding["owned_job_sha256"], "OwnedJob SHA")
    package = Path(binding["diagnostic_package_dir"]).resolve()
    require(package_files(package) == binding["diagnostic_package_files"] and
            set(binding["diagnostic_package_files"]) == {"Necromancer.exe", "Necromancer.pck"},
            "exact diagnostic package")
    exe = package / "Necromancer.exe"
    pck = package / "Necromancer.pck"
    require(sha(exe) == binding["template_exe_sha256"] and
            sha(pck) == binding["diagnostic_pck_sha256"], "diagnostic EXE/PCK SHA")
    require(binding["diagnostic_pck_sha256"] != binding["production_pck_sha256"],
            "diagnostic PCK must have distinct identity")
    require(sha(Path(binding["production_pck_path"])) == binding["production_pck_sha256"],
            "production PCK binding")
    return tree, package, helper


def aggregate_result(result, run_dir, tree, package, owner, binding,
                     source_before, package_before, owner_before, pinned):
    """Best-effort evidence collection: any read error becomes a recorded FAIL."""
    errors = result.setdefault("aggregation_errors", [])
    texts = []
    result["logs"] = {}
    try:
        logs = [p for p in run_dir.rglob("*.log*") if p.is_file()]
    except BaseException as error:
        logs = []
        errors.append("log inventory: " + repr(error))
    for path in logs:
        label = path.relative_to(run_dir).as_posix()
        try:
            texts.append(path.read_text(encoding="utf-8", errors="replace"))
            result["logs"][label] = sha(path)
        except BaseException as error:
            errors.append("log " + label + ": " + repr(error))
    result["diagnostics"] = [line for content in texts for line in content.splitlines()
                             if DIAGNOSTIC.search(line)]
    markers = [line[len(MARKER):] for content in texts for line in content.splitlines()
               if line.startswith(MARKER)]
    try:
        unique = {json.dumps(json.loads(line), sort_keys=True, ensure_ascii=False)
                  for line in markers}
        require(len(unique) == 1 and markers, "missing/ambiguous probe marker")
        facts = json.loads(markers[0])
        validate_payload(facts)
        result["facts"] = facts
    except BaseException as error:
        result["semantic_failure"] = repr(error)
    guards = {
        "head": lambda: git(tree, "rev-parse", "HEAD") == binding["source_head"],
        "clean": lambda: not git(tree, "status", "--porcelain=v1", "--untracked-files=all"),
        "source": lambda: all(sha(tree / p) == v for p, v in source_before.items()),
        "package": lambda: package_files(package) == package_before,
        "owner": lambda: cfg_snapshot(owner) == owner_before,
        "inputs": lambda: all(sha(Path(p)) == v for p, v in pinned.items()),
    }
    result["guards"] = {}
    for name, check in guards.items():
        try:
            result["guards"][name] = bool(check())
        except BaseException as error:
            result["guards"][name] = False
            errors.append("guard " + name + ": " + repr(error))
    result["pass"] = (not result.get("failure") and not result.get("semantic_failure") and
                      not errors and result.get("exit_code") == 0 and
                      result.get("remaining") == [] and not result["cleanup_errors"] and
                      not result["diagnostics"] and all(result["guards"].values()))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--binding", type=Path, required=True)
    parser.add_argument("--binding-sha256", required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args()
    require(args.execute and os.name == "nt", "explicit Windows execution required")
    binding = json.loads(args.binding.read_text(encoding="utf-8"))
    tree, package, helper = validate_binding(binding, args.binding, args.binding_sha256)
    run_dir = args.run_dir.resolve()
    require(run_dir.is_relative_to(Path("C:/Projects/Necromancer/local/qa").resolve()) and
            not run_dir.exists(), "fresh QA run directory required")
    owner = Path(os.environ["APPDATA"]) / "Godot/app_userdata/Некромант на аутсорсе"
    owner_before = cfg_snapshot(owner)
    source_before = {relative: sha(tree / relative)
                     for relative in json.loads(Path(binding["overlay_manifest"]["path"])
                     .read_text(encoding="utf-8"))["source_files"]}
    package_before = package_files(package)
    pinned = {str(args.binding.resolve()): sha(args.binding), str(Path(__file__).resolve()): sha(Path(__file__)),
              str(helper.resolve()): sha(helper)}
    run_dir.mkdir(parents=True)
    appdata = run_dir / "appdata"
    localappdata = run_dir / "localappdata"
    temp = run_dir / "temp"
    for path in (appdata, localappdata, temp):
        path.mkdir()
    result = {"pass": False, "scope": "distinct_diagnostic_pck_release_template",
              "cleanup_errors": []}
    job = None
    proc = None
    started = time.monotonic()
    try:
        available = psutil.virtual_memory().available
        save(run_dir / "admission.json", {"available": available, "admit": 8 * GIB,
                                          "floor": 6 * GIB})
        require(available >= 8 * GIB, "8 GiB RAM admission")
        env = dict(os.environ, APPDATA=str(appdata), LOCALAPPDATA=str(localappdata),
                   TEMP=str(temp), TMP=str(temp), TMPDIR=str(temp),
                   NECRO_NO_METRICS="1", NECRO_NO_DEV_BRIDGE="1", NECRO_DAILY_BOARD_URL="")
        for key in list(env):
            if key.upper().startswith("NECRO_QA_") or key.upper() == "NECRO_DEV_BRIDGE":
                env.pop(key)
        command = [str(package / "Necromancer.exe"), "--headless", "--audio-driver", "Dummy",
                   "--log-file", str(run_dir / "engine.log"), "--", "--mute"]
        save(run_dir / "launch.json", {"command": command, "cwd": str(package),
                                       "appdata": str(appdata), "localappdata": str(localappdata),
                                       "temp": str(temp)})
        module = module_at(helper)
        job = module.OwnedJob()
        with (run_dir / "console.log").open("w", encoding="utf-8") as stream:
            proc, identity = job.spawn(command, cwd=str(package), env=env,
                                       stdout=stream, stderr=subprocess.STDOUT)
            save(run_dir / "identity.json", identity)
            while proc.poll() is None:
                require(time.monotonic() - started < 108, "108 s work deadline")
                require(psutil.virtual_memory().available >= 6 * GIB, "6 GiB RAM floor")
                job.remaining()
                time.sleep(.1)
            result["exit_code"] = proc.returncode
            require(proc.returncode == 0 and job.remaining() == [], "native exit/children")
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
                result["exit_code"] = proc.returncode
            except BaseException as error:
                result["cleanup_errors"].append(repr(error))
        try:
            aggregate_result(result, run_dir, tree, package, owner, binding,
                             source_before, package_before, owner_before, pinned)
        except BaseException as error:
            result.setdefault("aggregation_errors", []).append("unexpected: " + repr(error))
            result["pass"] = False
        result["seconds"] = time.monotonic() - started
        save(run_dir / "result.json", result)
    print(json.dumps({"pass": result["pass"], "result": str(run_dir / "result.json")}))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
