"""Future GO-only, bounded import/export for a distinct template diagnostic PCK.

Requires template_probe_overlay.py prepare first. Never edits production dist.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import psutil

import template_probe_overlay as overlay
from run_template_semantics import DIAGNOSTIC, GIB, cfg_snapshot, module_at, package_files, save, sha


ALLOWED_STATUS = {
    " M godot/project.godot",
    "?? godot/scripts/dev/template_semantics_probe.gd",
    "?? godot/scenes/template_semantics_probe.tscn",
    "?? godot/scripts/dev/template_semantics_probe.gd.uid",
    "?? godot/scenes/template_semantics_probe.tscn.uid",
}


def require(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def import_deadline(value):
    if not re.fullmatch(r"[1-9][0-9]{0,2}", value) or int(value) > 900:
        raise argparse.ArgumentTypeError("import deadline must be an integer from 1 to 900 seconds")
    return int(value)


def observe_job(job, observations):
    """Capture live Job members, without reading or recording their environment."""
    for identity in job.remaining():
        pid = identity["pid"]
        old = observations.get(pid)
        if old and old.get("exe") and old.get("cmdline"):
            continue
        row = dict(identity, exe=None, cmdline=None, name=None)
        try:
            process = psutil.Process(pid)
            require(abs(process.create_time() - identity["create_time"]) < .001,
                    "owned PID identity changed during observation")
            row.update(name=process.name(), exe=process.exe(), cmdline=process.cmdline())
        except (psutil.Error, OSError, RuntimeError, TypeError) as error:
            row["capture_error"] = repr(error)
        observations[pid] = row


def observations_complete(identities, observations):
    return all((row := observations.get(item["pid"])) is not None and
               row.get("create_time") == item["create_time"] and
               bool(row.get("exe")) and bool(row.get("cmdline"))
               for item in identities)


def source_state(manifest):
    tree = overlay.REPO
    require(overlay.git("rev-parse", "HEAD").lower() == manifest["source_head"],
            "source HEAD changed")
    status = overlay.git("status", "--porcelain=v1", "--untracked-files=all").splitlines()
    require(set(status).issubset(ALLOWED_STATUS), "unexpected source status: " + repr(status))
    hashes = {relative: sha(tree / relative) for relative in manifest["source_files"]}
    expected = dict(manifest["source_files"])
    expected[overlay.key(overlay.PROJECT)] = manifest["project_staged_sha256"]
    require(hashes == expected, "frozen source content changed")
    require(sha(tree / overlay.PROJECT) == manifest["project_staged_sha256"] and
            sha(tree / overlay.SCRIPT) == manifest["probe_source_sha256"] and
            sha(tree / overlay.SCENE) == manifest["probe_scene_sha256"],
            "diagnostic overlay content changed")
    return {"status": status, "source_files": hashes,
            "project_staged_sha256": manifest["project_staged_sha256"],
            "probe_source_sha256": manifest["probe_source_sha256"],
            "probe_scene_sha256": manifest["probe_scene_sha256"]}


def run_stage(name, command, deadline, qa, module, editor_sha, owner, *, cold_cache=None):
    stage = qa / "scratch" / name
    stage.mkdir(exist_ok=False)
    for child in ("appdata", "localappdata", "temp"):
        (stage / child).mkdir()
    available = psutil.virtual_memory().available
    save(stage / "admission.json", {"available": available, "admit": 8 * GIB,
                                   "floor": 6 * GIB, "deadline_s": deadline})
    result = {"stage": name, "pass": False, "cleanup_errors": [],
              "deadline_s": deadline, "cold_cache_requested": cold_cache is not None}
    job = None
    proc = None
    observations = {}
    started = time.monotonic()
    try:
        result["owner_before"] = cfg_snapshot(owner)
        require(available >= 8 * GIB, "8 GiB RAM admission")
        if cold_cache is not None:
            require(not os.path.lexists(cold_cache), "cold import requires absent .godot cache")
            result["cold_cache_absent_before_spawn"] = True
        require(sha(Path(command[0])) == editor_sha, "editor executable changed")
        env = dict(os.environ, APPDATA=str(stage / "appdata"),
                   LOCALAPPDATA=str(stage / "localappdata"),
                   TEMP=str(stage / "temp"), TMP=str(stage / "temp"),
                   TMPDIR=str(stage / "temp"), NECRO_NO_METRICS="1",
                   NECRO_NO_DEV_BRIDGE="1", NECRO_DAILY_BOARD_URL="")
        for key in list(env):
            if key.upper().startswith("NECRO_QA_") or key.upper() == "NECRO_DEV_BRIDGE":
                env.pop(key)
        save(stage / "launch.json", {"command": command, "cwd": str(overlay.REPO / "godot"),
                                     "appdata": env["APPDATA"],
                                     "localappdata": env["LOCALAPPDATA"],
                                     "temp": env["TEMP"]})
        job = module.OwnedJob()
        with (stage / "console.log").open("w", encoding="utf-8") as stream:
            proc, identity = job.spawn(command, cwd=str(overlay.REPO / "godot"), env=env,
                                       stdout=stream, stderr=subprocess.STDOUT)
            save(stage / "identity.json", identity)
            observe_job(job, observations)
            while proc.poll() is None:
                require(time.monotonic() - started < deadline,
                        f"{deadline}s {name} work deadline (12s cleanup reserved)")
                require(psutil.virtual_memory().available >= 6 * GIB, "6 GiB RAM floor")
                observe_job(job, observations)
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
        result["aggregation_errors"] = []
        try:
            result["owned_process_observations"] = sorted(observations.values(),
                                                           key=lambda row: row["pid"])
            identities = result.get("cleanup", {}).get("identities", [])
            result["observation_complete"] = bool(identities) and observations_complete(
                identities, observations)
        except BaseException as error:
            result["owned_process_observations"] = []
            result["observation_complete"] = False
            result["aggregation_errors"].append("owned process observation: " + repr(error))
        if proc is not None:
            try:
                proc.wait(timeout=5)
                result["exit_code"] = proc.returncode
            except BaseException as error:
                result["cleanup_errors"].append(repr(error))
        result["logs"] = {}
        result["diagnostics"] = []
        try:
            logs = [p for p in stage.rglob("*.log*") if p.is_file()]
        except BaseException as error:
            logs = []
            result["aggregation_errors"].append("log inventory: " + repr(error))
        for log in logs:
            try:
                content = log.read_text(encoding="utf-8", errors="replace")
                result["logs"][log.relative_to(stage).as_posix()] = sha(log)
                result["diagnostics"].extend(line for line in content.splitlines()
                                             if DIAGNOSTIC.search(line))
            except BaseException as error:
                result["aggregation_errors"].append("log " + log.name + ": " + repr(error))
        try:
            result["owner_guard"] = cfg_snapshot(owner) == result["owner_before"]
        except BaseException as error:
            result["owner_guard"] = False
            result["aggregation_errors"].append("owner guard: " + repr(error))
        result["seconds"] = time.monotonic() - started
        result["pass"] = (not result.get("failure") and result.get("exit_code") == 0 and
                          result.get("remaining") == [] and not result["cleanup_errors"] and
                          not result["aggregation_errors"] and not result["diagnostics"] and
                          result["owner_guard"] and result["observation_complete"])
        save(stage / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--qa-dir", type=Path, required=True)
    parser.add_argument("--source-head", required=True)
    parser.add_argument("--overlay-sha256", required=True)
    parser.add_argument("--godot-editor", type=Path, required=True)
    parser.add_argument("--editor-sha256", required=True)
    parser.add_argument("--owned-job-sha256", required=True)
    parser.add_argument("--template-exe", type=Path, required=True)
    parser.add_argument("--template-sha256", required=True)
    parser.add_argument("--import-deadline-s", type=import_deadline, default=90)
    parser.add_argument("--cold-import", action="store_true")
    args = parser.parse_args()
    require(args.execute and os.name == "nt", "explicit Windows engine GO required")
    _, qa = overlay.paths(args.qa_dir)
    manifest_path = qa / "overlay.json"
    require(sha(manifest_path) == args.overlay_sha256.upper(), "overlay binding SHA")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    require(manifest["schema"] == "necro-template-overlay-v1" and
            manifest["source_head"] == args.source_head.lower(), "overlay/head binding")
    require(args.godot_editor.is_absolute() and sha(args.godot_editor) == args.editor_sha256.upper(),
            "reviewed editor SHA")
    require(args.template_exe.is_absolute() and sha(args.template_exe) ==
            args.template_sha256.upper(), "reviewed official template SHA")
    helper = overlay.REPO / "tools/night_pilot/owned_job.py"
    require(sha(helper) == args.owned_job_sha256.upper(), "reviewed OwnedJob SHA")
    module = module_at(helper)
    source_before = source_state(manifest)
    package = qa / "scratch" / "package"
    require(not package.exists() and not (qa / "scratch" / "import").exists() and
            not (qa / "scratch" / "export").exists(), "fresh QA stages required")
    package.mkdir()
    owner = Path(os.environ["APPDATA"]) / "Godot/app_userdata/Некромант на аутсорсе"
    owner_before = cfg_snapshot(owner)
    result = {"schema": "necro-template-pack-build-v1", "pass": False,
              "source_head": args.source_head.lower(), "overlay_sha256": args.overlay_sha256.upper(),
              "source_before": source_before, "stages": {}, "owner_before": owner_before,
              "failure": None, "import_deadline_s": args.import_deadline_s,
              "cold_import_requested": args.cold_import}
    try:
        editor = str(args.godot_editor.resolve())
        project = str(overlay.REPO / "godot")
        common = [editor, "--headless", "--path", project]
        import_cmd = common + ["--fixed-fps", "60", "--import", "--", "--mute"]
        cache = overlay.REPO / "godot/.godot" if args.cold_import else None
        stage = run_stage("import", import_cmd, args.import_deadline_s, qa, module,
                          args.editor_sha256.upper(), owner, cold_cache=cache)
        result["stages"]["import"] = stage
        require(stage["pass"], "import stage failed")
        result["source_after_import"] = source_state(manifest)
        export_cmd = common + ["--log-file", str(qa / "scratch/export/engine.log"),
                               "--export-pack", "Windows Desktop",
                               str(package / "Necromancer.pck"), "--", "--mute"]
        stage = run_stage("export", export_cmd, 180, qa, module, args.editor_sha256.upper(), owner)
        result["stages"]["export"] = stage
        require(stage["pass"], "export stage failed")
        result["source_after_export"] = source_state(manifest)
        pck = package / "Necromancer.pck"
        require(pck.is_file() and pck.stat().st_size > 0, "diagnostic PCK missing")
        require(package_files(package) == {"Necromancer.pck": sha(pck)},
                "export package has unexpected files")
        shutil.copyfile(args.template_exe, package / "Necromancer.exe")
        require(sha(package / "Necromancer.exe") == args.template_sha256.upper(),
                "copied template SHA mismatch")
        restored = overlay.restore(qa, args.source_head)
        result["restore"] = restored
        require(restored["source_status"] == "", "source not clean after restore")
        result["package_files"] = package_files(package)
        require(set(result["package_files"]) == {"Necromancer.exe", "Necromancer.pck"},
                "diagnostic package inventory")
        require(cfg_snapshot(owner) == owner_before, "owner CFG changed")
        result["pass"] = True
        result["failure"] = None
    except BaseException as error:
        result["failure"] = repr(error)
    try:
        result["package_files_observed"] = package_files(package)
    except BaseException as error:
        result["pass"] = False
        result.setdefault("aggregation_errors", []).append("package inventory: " + repr(error))
    try:
        result["source_status_observed"] = overlay.git("status", "--porcelain=v1", "--untracked-files=all")
    except BaseException as error:
        result["pass"] = False
        result.setdefault("aggregation_errors", []).append("source status: " + repr(error))
    save(qa / "build-result.json", result)
    print(json.dumps({"pass": result["pass"], "result": str(qa / "build-result.json")}))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
