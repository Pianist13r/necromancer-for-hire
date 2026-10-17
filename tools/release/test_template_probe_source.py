"""Small source-only guards for the prospective template diagnostic."""

import argparse
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from build_template_semantics_pack import (import_deadline, observe_job,
                                           observations_complete, run_stage, source_state)
from run_template_semantics import MARKER, aggregate_result, save, validate_payload
from template_probe_overlay import BUS, NEW_MAIN, OLD_MAIN, PRESET, PROJECT, PIPE, SCENE, SCENE_BYTES, SCRIPT
from run_template_semantics import sha


def sample():
    return {"pass": True,
            "flags": {"ship": True, "editor": False, "template": True, "debug": False},
            "audio": {"raw_setting": "uid://bvgjm8g4e0e8k",
                      "effective_setting": "uid://bvgjm8g4e0e8k",
                      "editor_override": "", "resource_loaded": True,
                      "count": 4, "failures": [],
                      "buses": [{"name": "Master", "effects": 1, "send": ""},
                                {"name": "Music", "effects": 2, "send": "Master"},
                                {"name": "SFX", "effects": 1, "send": "Master"},
                                {"name": "Voice", "effects": 0, "send": "Master"}]},
            "pipe": {"checks": 40, "failures": []}}


class TemplateProbeSourceTest(unittest.TestCase):
    def test_cold_import_deadline_is_explicit_and_bounded(self):
        self.assertEqual(import_deadline("300"), 300)
        for value in ("0", "901", "1.5", "NaN", "-1", " 300", "300s"):
            with self.assertRaises(argparse.ArgumentTypeError):
                import_deadline(value)

    def test_live_owned_child_observation_needs_exe_and_command(self):
        identity = {"pid": 4217, "create_time": 17.5}
        job = type("Job", (), {"remaining": lambda self: [identity]})()
        process = type("Process", (), {"create_time": lambda self: 17.5,
                                        "name": lambda self: "Godot.exe",
                                        "exe": lambda self: "C:/Godot.exe",
                                        "cmdline": lambda self: ["C:/Godot.exe", "--import"]})()
        observations = {}
        with patch("build_template_semantics_pack.psutil.Process", return_value=process):
            observe_job(job, observations)
        self.assertTrue(observations_complete([identity], observations))
        self.assertEqual(observations[4217]["cmdline"], ["C:/Godot.exe", "--import"])
        observations[4217]["cmdline"] = None
        self.assertFalse(observations_complete([identity], observations))

    def test_cold_stage_refuses_existing_cache_before_spawn(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scratch").mkdir()
            cache = root / ".godot"
            cache.mkdir()
            memory = type("Memory", (), {"available": 10 * 1024 ** 3})()
            with patch("build_template_semantics_pack.psutil.virtual_memory",
                       return_value=memory), \
                 patch("build_template_semantics_pack.cfg_snapshot", return_value={}):
                result = run_stage("import", [str(root / "never-run.exe")], 300,
                                   root, None, "unused", root, cold_cache=cache)
            self.assertFalse(result["pass"])
            self.assertIn("cold import requires absent", result["failure"])
            self.assertEqual(result["deadline_s"], 300)
            self.assertEqual(result["owned_process_observations"], [])

    def test_strict_semantic_payload(self):
        validate_payload(sample())
        for mutate in (
            lambda v: v["flags"].update(editor=True),
            lambda v: v["audio"].update(resource_loaded=False),
            lambda v: v["audio"].update(effective_setting="res://default_bus_layout.tres"),
            lambda v: v["pipe"].update(checks=39),
            lambda v: v["pipe"]["failures"].append("close failed"),
        ):
            value = copy.deepcopy(sample())
            mutate(value)
            with self.assertRaises(RuntimeError):
                validate_payload(value)

    def test_scene_overlay_is_explicit(self):
        self.assertNotEqual(OLD_MAIN, NEW_MAIN)
        self.assertIn(b"template_semantics_probe.gd", SCENE_BYTES)
        self.assertIn(b'type="Node"', SCENE_BYTES)

    def test_log_hash_failure_is_saved_as_structured_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "console.log").write_text(MARKER + json.dumps(sample()) + "\n",
                                              encoding="utf-8")
            result = {"pass": False, "exit_code": 0, "remaining": [], "cleanup_errors": []}
            with patch("run_template_semantics.sha", side_effect=OSError("hash read")), \
                 patch("run_template_semantics.git", side_effect=["head", ""]), \
                 patch("run_template_semantics.package_files", return_value={}), \
                 patch("run_template_semantics.cfg_snapshot", return_value={}):
                aggregate_result(result, root, root, root, root, {"source_head": "head"},
                                 {}, {}, {}, {})
            save(root / "result.json", result)
            recorded = json.loads((root / "result.json").read_text(encoding="utf-8"))
            self.assertFalse(recorded["pass"])
            self.assertTrue(any("log console.log" in e for e in recorded["aggregation_errors"]))

    def test_guard_exception_is_saved_as_structured_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "console.log").write_text(MARKER + json.dumps(sample()) + "\n",
                                              encoding="utf-8")
            result = {"pass": False, "exit_code": 0, "remaining": [], "cleanup_errors": []}
            with patch("run_template_semantics.git", side_effect=["head", ""]), \
                 patch("run_template_semantics.package_files", side_effect=OSError("package read")), \
                 patch("run_template_semantics.cfg_snapshot", return_value={}):
                aggregate_result(result, root, root, root, root, {"source_head": "head"},
                                 {}, {}, {}, {})
            save(root / "result.json", result)
            recorded = json.loads((root / "result.json").read_text(encoding="utf-8"))
            self.assertFalse(recorded["pass"])
            self.assertFalse(recorded["guards"]["package"])
            self.assertTrue(any("guard package" in e for e in recorded["aggregation_errors"]))

    def test_import_freeze_uses_bytes_and_rejects_content_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            files = {PROJECT: b"staged project", BUS: b"bus", PIPE: b"pipe",
                     PRESET: b"preset", SCRIPT: b"probe", SCENE: b"scene"}
            for relative, content in files.items():
                path = tree / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            source = {str(p).replace("\\", "/"): sha(tree / p)
                      for p in (PROJECT, BUS, PIPE, PRESET)}
            source[str(PROJECT).replace("\\", "/")] = "ORIGINAL_PROJECT_SHA"
            manifest = {"source_head": "head", "source_files": source,
                        "project_staged_sha256": sha(tree / PROJECT),
                        "probe_source_sha256": sha(tree / SCRIPT),
                        "probe_scene_sha256": sha(tree / SCENE)}
            status = " M godot/project.godot\n?? godot/scripts/dev/template_semantics_probe.gd\n?? godot/scenes/template_semantics_probe.tscn"
            def fake_check_output(command, cwd, text):
                self.assertEqual(cwd, tree)
                self.assertTrue(text)
                self.assertEqual(command[0], "git")
                return "head\n" if command[1] == "rev-parse" else status + "\n"
            with patch("build_template_semantics_pack.overlay.REPO", tree), \
                 patch("template_probe_overlay.subprocess.check_output",
                       side_effect=fake_check_output):
                self.assertEqual(source_state(manifest)["source_files"][str(BUS).replace("\\", "/")],
                                 sha(tree / BUS))
                os.utime(tree / PROJECT, None)
                source_state(manifest)
                (tree / BUS).write_bytes(b"changed bus")
                with self.assertRaises(RuntimeError):
                    source_state(manifest)


if __name__ == "__main__":
    unittest.main()
