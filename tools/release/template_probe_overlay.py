"""Stage a reversible main-scene probe for a *distinct* diagnostic PCK.

This tool never starts Godot. The release template ignores external --script,
so the diagnostic PCK needs an in-pack main scene. Only use a clean, dedicated
ordinary worktree; the production PCK and its result remain immutable.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


REPO = Path(__file__).resolve().parents[2]
ORIGIN = Path("C:/Projects/Necromancer")
PROJECT = Path("godot/project.godot")
BUS = Path("godot/default_bus_layout.tres")
PIPE = Path("godot/scripts/legion/net/net_link_pipe.gd")
PRESET = Path("godot/export_presets.cfg")
SCRIPT = Path("godot/scripts/dev/template_semantics_probe.gd")
SCENE = Path("godot/scenes/template_semantics_probe.tscn")
GENERATED_UIDS = (Path(str(SCRIPT) + ".uid"), Path(str(SCENE) + ".uid"))
SCRIPT_SOURCE = Path(__file__).with_name("template_semantics_probe.gd")
OLD_MAIN = b'run/main_scene="res://scenes/legion.tscn"'
NEW_MAIN = b'run/main_scene="res://scenes/template_semantics_probe.tscn"'
SCENE_BYTES = (b'[gd_scene load_steps=2 format=3]\n\n'
               b'[ext_resource type="Script" path="res://scripts/dev/template_semantics_probe.gd" id="1"]\n\n'
               b'[node name="TemplateSemanticsProbe" type="Node"]\n'
               b'script = ExtResource("1")\n')


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def file_sha(path):
    return digest(path.read_bytes())


def require(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=REPO, text=True).rstrip("\r\n")


def paths(qa):
    tree = REPO.resolve()
    origin = ORIGIN.resolve()
    require(tree != origin and tree.is_relative_to(origin / "local/worktrees"),
            "run only inside a dedicated local/worktrees checkout")
    qa = qa.resolve()
    require(qa.is_relative_to(origin / "local/qa"), "QA result must be under local/qa")
    return tree, qa


def inventory():
    return {str(p).replace("\\", "/"): file_sha(REPO / p)
            for p in (PROJECT, BUS, PIPE, PRESET)}


def key(path):
    return str(path).replace("\\", "/")


def build_plan(head):
    require(re.fullmatch(r"[a-fA-F0-9]{40}", head) is not None, "explicit source HEAD required")
    require(git("rev-parse", "HEAD").lower() == head.lower(), "source HEAD changed")
    require(not git("status", "--porcelain=v1", "--untracked-files=all"),
            "worktree must be clean before staging")
    require(not any((REPO / p).exists() for p in (SCRIPT, SCENE, *GENERATED_UIDS)),
            "diagnostic targets already exist")
    original = (REPO / PROJECT).read_bytes()
    require(original.count(OLD_MAIN) == 1 and NEW_MAIN not in original,
            "unexpected project main scene")
    preset = (REPO / PRESET).read_text(encoding="utf-8")
    require('name="Windows Desktop"' in preset and
            'export_filter="all_resources"' in preset and
            'custom_features="ship"' in preset,
            "Windows export preset changed")
    return {"schema": "necro-template-overlay-v1", "source_head": head.lower(),
            "source_clean_before": True, "source_files": inventory(),
            "probe_source_sha256": file_sha(SCRIPT_SOURCE),
            "probe_scene_sha256": digest(SCENE_BYTES),
            "project_staged_sha256": digest(original.replace(OLD_MAIN, NEW_MAIN)),
            "diagnostic_main_scene": "res://scenes/template_semantics_probe.tscn",
            "scope": "new diagnostic PCK; never the accepted production PCK"}


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def prepare(qa, head):
    plan = build_plan(head)
    require(not qa.exists(), "QA directory already exists; choose a fresh run")
    qa.mkdir(parents=True)
    (qa / "scratch").mkdir()
    (qa / "accepted").mkdir()
    original = (REPO / PROJECT).read_bytes()
    (qa / "project.godot.original").write_bytes(original)
    save(qa / "overlay.json", plan)
    (REPO / SCRIPT).write_bytes(SCRIPT_SOURCE.read_bytes())
    (REPO / SCENE).write_bytes(SCENE_BYTES)
    (REPO / PROJECT).write_bytes(original.replace(OLD_MAIN, NEW_MAIN))
    require(file_sha(REPO / PROJECT) == plan["project_staged_sha256"] and
            file_sha(REPO / SCRIPT) == plan["probe_source_sha256"] and
            file_sha(REPO / SCENE) == plan["probe_scene_sha256"],
            "staging verification failed; preserve files for manual review")
    return plan


def restore(qa, head):
    manifest = json.loads((qa / "overlay.json").read_text(encoding="utf-8"))
    require(manifest["schema"] == "necro-template-overlay-v1" and
            manifest["source_head"] == head.lower() and
            git("rev-parse", "HEAD").lower() == head.lower(), "overlay HEAD mismatch")
    original = (qa / "project.godot.original").read_bytes()
    require(digest(original) == manifest["source_files"][key(PROJECT)] and
            file_sha(REPO / PROJECT) == manifest["project_staged_sha256"] and
            file_sha(REPO / SCRIPT) == manifest["probe_source_sha256"] and
            file_sha(REPO / SCENE) == manifest["probe_scene_sha256"],
            "overlay drift; preserve and inspect before restore")
    for p in (BUS, PIPE, PRESET):
        require(file_sha(REPO / p) == manifest["source_files"][key(p)],
                f"source drift: {p}")
    uid_hashes = {}
    for uid_path in GENERATED_UIDS:
        generated = REPO / uid_path
        if generated.exists():
            data = generated.read_bytes()
            require(re.fullmatch(rb"uid://[a-z0-9]+\s*", data) is not None,
                    f"unexpected generated UID content: {uid_path}")
            backup = qa / "generated-uids" / uid_path.name
            backup.parent.mkdir(exist_ok=True)
            backup.write_bytes(data)
            require(backup.read_bytes() == data, "generated UID backup mismatch")
            uid_hashes[str(uid_path).replace("\\", "/")] = digest(data)
    (REPO / PROJECT).write_bytes(original)
    (REPO / SCRIPT).unlink()
    (REPO / SCENE).unlink()
    for uid_path in GENERATED_UIDS:
        generated = REPO / uid_path
        if generated.exists():
            require(file_sha(generated) == uid_hashes[str(uid_path).replace("\\", "/")],
                    "generated UID changed during restore")
            generated.unlink()
    restored = {"source_head": head.lower(), "source_files": inventory(),
                "generated_uid_sha256": uid_hashes,
                "source_status": git("status", "--porcelain=v1", "--untracked-files=all")}
    save(qa / "restore.json", restored)
    return restored


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("plan", "prepare", "restore"))
    parser.add_argument("--source-head", required=True)
    parser.add_argument("--qa-dir", type=Path, required=True)
    args = parser.parse_args()
    _, qa = paths(args.qa_dir)
    if args.mode == "plan":
        result = build_plan(args.source_head)
    elif args.mode == "prepare":
        result = prepare(qa, args.source_head)
    else:
        result = restore(qa, args.source_head)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
