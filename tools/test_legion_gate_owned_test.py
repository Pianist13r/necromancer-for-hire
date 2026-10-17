"""Pure owned-lifecycle and Bash scheduling fixtures. Never starts a Godot engine."""
from __future__ import annotations

import copy
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

TOOLS = Path(__file__).resolve().parent
QA = Path(os.environ.get("NECRO_TEST_QA", str(TOOLS.parent / "local/qa/capture-gate-lifecycle-pure")))
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("exclusive_gate", TOOLS / "legion_gate_owned_test.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class FakeProcess:
    def __init__(self, *, hold=False, fast=False):
        self.returncode = None
        self.polls = 0
        self.hold, self.fast = hold, fast

    def poll(self):
        self.polls += 1
        if not self.hold and (self.fast or self.polls > 1):
            self.returncode = 0
        return self.returncode

    def wait(self, timeout):
        return self.returncode


class FakeOwner:
    def __init__(self, process, raw="Solo input capture native: 2/2\n", callback=None):
        self.process, self.raw, self.callback = process, raw, callback
        self.spawn = Mock(side_effect=self._spawn)
        self.close = Mock()
        self.stop = Mock(side_effect=self._stop)
        self.identity = {"pid": 4444, "create_time": 123.0}

    def _spawn(self, command, **kwargs):
        kwargs["stdout"].write(self.raw)
        kwargs["stdout"].flush()
        if self.callback:
            self.callback(command, kwargs)
        return self.process, self.identity

    def remaining(self):
        return [self.identity] if self.process.returncode is None else []

    def _stop(self, timeout):
        if self.process.returncode is None:
            self.process.returncode = 1
        return {"owned_processes_dead": True, "remaining": [], "identities": [self.identity]}


class OwnedFixtureTests(unittest.TestCase):
    def setUp(self):
        QA.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="gate-pure-", dir=QA)
        self.root = Path(self.temporary.name)
        self.owner = self.root / "owner-userdata"
        self.owner.mkdir()
        self.engine = self.root / "fixture-engine-file"
        self.engine.write_bytes(b"not executable; mock only")
        gate.STOP_REQUESTED = False

    def tearDown(self):
        self.temporary.cleanup()

    def run_fixture(self, *, memory=None, engines=None, raw=None, callback=None,
                    hold=False, fast=False, source=None, times=None, cleanup_error=False):
        process = FakeProcess(hold=hold, fast=fast)
        job = FakeOwner(process, raw if raw is not None else "Solo input capture native: 2/2\n", callback)
        if cleanup_error:
            job.stop.side_effect = RuntimeError("owned cleanup failed")
        memory = memory or [16 * gate.GIB] * 30
        engines = engines if engines is not None else []
        with ExitStack() as stack:
            stack.enter_context(patch.object(gate, "policy", return_value={gate.NAME: dict(gate.EXPECTED_POLICY)}))
            stack.enter_context(patch.object(gate, "owner_folder", return_value=self.owner))
            stack.enter_context(patch.object(gate, "source_snapshot", side_effect=source or [{"code": "same"}] * 2))
            stack.enter_context(patch.object(gate, "other_engines", return_value=engines))
            factory = stack.enter_context(patch.object(gate, "ProcessOwner", return_value=job))
            stack.enter_context(patch.object(gate.psutil, "virtual_memory", side_effect=[
                types.SimpleNamespace(available=value) for value in memory]))
            stack.enter_context(patch.object(gate.time, "sleep"))
            if times is not None:
                stack.enter_context(patch.object(gate.time, "monotonic", side_effect=times))
            result = gate.run_test(gate.NAME, self.engine, self.root / "out", "original-appdata", "original-xdg")
        return result, job, factory

    def test_exact_policy_is_unmeasured_and_cannot_be_weakened(self):
        data = {"schema": "legion-gate-resource-policy-v1", "tests": {gate.NAME: copy.deepcopy(gate.EXPECTED_POLICY)}}
        file = self.root / "policy.json"
        with patch.object(gate, "POLICY", file):
            file.write_text(json.dumps(data), encoding="utf-8")
            self.assertIsNone(gate.policy()[gate.NAME]["measured_peak_bytes"])
            data["tests"][gate.NAME]["floor_gib"] = 4
            file.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "policy drift"):
                gate.policy()

    def test_success_uses_private_profile_real_owner_and_only_mute_args(self):
        def inspect(command, kwargs):
            env = kwargs["env"]
            self.assertNotEqual(Path(env["APPDATA"]), self.owner)
            self.assertEqual(command[command.index("--") + 1:], ["--mute"])
            self.assertNotIn("--dev", command)
            self.assertEqual(env["NECRO_NO_METRICS"], "1")
            self.assertEqual(env["NECRO_NO_DEV_BRIDGE"], "1")
            self.assertNotIn("NECRO_DEV_BRIDGE", env)
            self.assertTrue(Path(env["TEMP"]).is_dir())
            self.assertEqual(env["TEMP"], env["TMPDIR"])
        with patch.dict(os.environ, {"NECRO_DEV_BRIDGE": "1", "QA_BAD": "1"}):
            result, job, _ = self.run_fixture(callback=inspect)
        self.assertTrue(result["pass"])
        self.assertTrue(result["owner_unchanged"])
        self.assertEqual(result["resource_peak_class"], "unmeasured")
        job.stop.assert_called_once_with(timeout=5)
        job.close.assert_called_once()

    def test_low_admission_refuses_before_owner_job_or_engine_spawn(self):
        result, job, factory = self.run_fixture(memory=[7 * gate.GIB])
        self.assertFalse(result["pass"])
        self.assertIn("8 GiB", result["failure"])
        factory.assert_not_called()
        job.spawn.assert_not_called()

    def test_other_engine_refuses_without_stopping_it(self):
        result, job, factory = self.run_fixture(engines=[{"pid": 999, "create_time": 456.0}])
        self.assertFalse(result["pass"])
        factory.assert_not_called()
        job.stop.assert_not_called()

    def test_floor_failure_only_stops_owned_job(self):
        result, job, _ = self.run_fixture(memory=[8 * gate.GIB, 8 * gate.GIB, 6 * gate.GIB, 5 * gate.GIB], hold=True)
        self.assertFalse(result["pass"])
        self.assertIn("6 GiB", result["failure"])
        job.stop.assert_called_once_with(timeout=5)
        self.assertEqual(result["cleanup"]["identities"], [{"pid": 4444, "create_time": 123.0}])

    def test_fast_exit_after_native_deadline_is_failure(self):
        result, job, _ = self.run_fixture(fast=True, times=[0, 0, 0, 121, 121])
        self.assertFalse(result["pass"])
        self.assertIn("120s", result["failure"])
        job.close.assert_called_once()

    def test_owner_drift_refuses_even_after_exit_zero(self):
        def mutate_owner(_command, _kwargs):
            (self.owner / "legion.cfg").write_text("owner changed", encoding="utf-8")
        result, _, _ = self.run_fixture(callback=mutate_owner)
        self.assertFalse(result["pass"])
        self.assertFalse(result["owner_unchanged"])
        self.assertEqual(result["native_exit"], 0)

    def test_source_drift_refuses(self):
        result, _, _ = self.run_fixture(source=[{"code": "before"}, {"code": "after"}])
        self.assertFalse(result["pass"])
        self.assertFalse(result["source_unchanged"])

    def test_dispatcher_content_drift_detected_with_same_head_and_dirty_status(self):
        self.assertIn("tools/legion_gate.sh", gate.SOURCE_PATHS)
        shell = self.root / "tools/legion_gate.sh"
        shell.parent.mkdir()
        shell.write_text("before", encoding="utf-8")
        with patch.object(gate, "ROOT", self.root), \
                patch.object(gate, "SOURCE_PATHS", ("tools/legion_gate.sh",)), \
                patch.object(gate.subprocess, "check_output", side_effect=["head", " M tools/legion_gate.sh"] * 2):
            before = gate.source_snapshot()
            shell.write_text("after", encoding="utf-8")
            after = gate.source_snapshot()
        self.assertEqual(before["head"], after["head"])
        self.assertEqual(before["status"], after["status"])
        self.assertNotEqual(before["files"], after["files"])

    def test_signal_during_spawn_defers_to_owned_cleanup(self):
        def interrupt(_command, _kwargs):
            gate.request_stop(None, None)
        result, job, _ = self.run_fixture(callback=interrupt, hold=True)
        self.assertFalse(result["pass"])
        self.assertIn("interrupted", result["failure"])
        job.stop.assert_called_once_with(timeout=5)
        job.close.assert_called_once()

    def test_zero_exit_diagnostic_and_missing_summary_refuse(self):
        for raw in ("Solo input capture native: 2/2\nWARNING: fixture diagnostic\n", "no completion\n"):
            with self.subTest(raw=raw):
                result, _, _ = self.run_fixture(raw=raw)
                self.assertFalse(result["pass"])

    def test_cleanup_error_never_promotes_and_always_closes(self):
        result, job, _ = self.run_fixture(cleanup_error=True)
        self.assertFalse(result["pass"])
        self.assertTrue(result["cleanup_errors"])
        job.close.assert_called_once()

    def test_output_inside_owner_userdata_refused_before_spawn(self):
        with patch.object(gate, "owner_folder", return_value=self.owner), \
                patch.object(gate, "ProcessOwner") as factory:
            with self.assertRaisesRegex(RuntimeError, "inside owner"):
                gate.run_test(gate.NAME, self.engine, self.owner / "bad", "owner", "owner")
            factory.assert_not_called()


class ShellSchedulingTests(unittest.TestCase):
    def test_exclusive_drain_and_owner_baseline_survive_parallel_and_serial_overrides(self):
        bash = Path("C:/Program Files/Git/bin/bash.exe")
        if not bash.is_file():
            candidate = shutil.which("bash")
            if not candidate:
                self.skipTest("Bash unavailable")
            bash = Path(candidate)
        QA.mkdir(parents=True, exist_ok=True)
        for par, selected in (("2", gate.NAME), ("1", "godot/tests/" + gate.NAME + ".gd"),
                              ("1", gate.NAME + ".gd"), ("2", "godot/tests/" + gate.NAME.upper() + ".gd"),
                              ("2", "godot/tests/" + gate.NAME + ".GD"),
                              ("2", "godot\\tests\\..\\tests\\" + gate.NAME.upper() + ".GD")):
            with self.subTest(par=par, selected=selected), tempfile.TemporaryDirectory(prefix="gate-shell-pure-", dir=QA) as temporary:
                root = Path(temporary)
                (root / "tools").mkdir()
                shutil.copy2(TOOLS / "legion_gate.sh", root / "tools/legion_gate.sh")
                trace, owner_args = root / "trace.txt", root / "owner.json"
                stub = root / "stub_godot"
                stub.write_text('#!/bin/bash\necho "normal-start:$*" >> "$TRACE_FILE"\n'
                                'sleep 0.1\necho "normal-end:$*" >> "$TRACE_FILE"\necho "pure mock 1/1"\n',
                                encoding="utf-8")
                stub.chmod(0o755)
                (root / "tools/legion_gate_owned_test.py").write_text(
                    'import json,os,pathlib,sys\n'
                    'args=sys.argv[1:]\n'
                    'if "--exclusive-list" in args: print("legion_solo_input_capture_test")\n'
                    'elif "--wrapper-timeout" in args: print(132)\n'
                    'else:\n'
                    ' pathlib.Path(os.environ["OWNER_ARGS"]).write_text(json.dumps({"owner":args[args.index("--owner-appdata")+1]}))\n'
                    ' with pathlib.Path(os.environ["TRACE_FILE"]).open("a") as stream: stream.write("exclusive-start\\n")\n'
                    ' print("pure exclusive mock 1/1")\n', encoding="utf-8")
                original_owner = str(root / "original-owner")
                env = dict(os.environ, GODOT=str(stub).replace("\\", "/"),
                           PYTHON=sys.executable.replace("\\", "/"), OUT=str(root / "out").replace("\\", "/"),
                           APPDATA=original_owner, XDG_DATA_HOME=original_owner,
                           GATE_PAR=par, GATE_SERIAL_LIST="", GATE_TEST_TIMEOUT_S="9000",
                           GATE_ONLY_TEST="normal_a " + selected + " normal_b", SKIP_IMPORT="1",
                           TRACE_FILE=str(trace).replace("\\", "/"), OWNER_ARGS=str(owner_args))
                result = subprocess.run([str(bash), "--noprofile", "--norc", "tools/legion_gate.sh"],
                                        cwd=root, env=env, text=True, capture_output=True, timeout=25)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                rows = trace.read_text(encoding="utf-8").splitlines()
                ends = [i for i, line in enumerate(rows) if line.startswith("normal-end:")]
                self.assertEqual(len(ends), 2)
                self.assertGreater(rows.index("exclusive-start"), max(ends))
                self.assertEqual(json.loads(owner_args.read_text())["owner"], original_owner)
                self.assertEqual((root / "out/.res" / gate.NAME).read_text().split()[3], "132")
                self.assertIn("GATE OK", result.stdout)

    def test_full_selector_glob_still_discovers_capture_once(self):
        shell = (TOOLS / "legion_gate.sh").read_text(encoding="utf-8")
        self.assertIn('tests_list="$(ls godot/tests/legion_*_test.gd ', shell)
        names = [path.stem for path in (TOOLS.parent / "godot/tests").glob("legion_*_test.gd")]
        self.assertEqual(names.count(gate.NAME), 1)
        self.assertIn("for name in $exclusive_part; do run_test", shell)


if __name__ == "__main__":
    unittest.main(verbosity=2)
