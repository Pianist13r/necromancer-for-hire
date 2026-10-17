"""The worker boundary rejects unsupported input before any engine launch."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local_worker


class LocalWorkerTests(unittest.TestCase):
    def setUp(self):
        self.identity = {"code": "a" * 64, "engine": "b" * 64}
        self.replay = {"schema": 1, "identity": {"code_sha256": "a" * 64,
                       "engine_sha256": "b" * 64},
                       "config": {"map": "_plots", "seed": 4242, "difficulty": "normal",
                                  "progression": "neutral", "tick_hz": 60, "side": 0},
                       "ticks": 1200,
                       "score": {"hp": 200.0, "t": 20.0, "wave": 1, "kills": 0,
                                 "lost": 0, "souls": 20, "phase": 1}}

    def native_success(self):
        report = {"checks": 2, "effects": {"draw": 1, "release": 20, "cast": 1, "build": 2},
                  "error": "", "failures": [], "mode": "replay", "tick": 1200,
                  "score": copy.deepcopy(self.replay["score"])}
        return {"exit_code": 0, "stop": None, "diagnostics": [], "owned_job_final": [], "report": report}

    def inputs(self, kind="neutral_checkpoint"):
        data = json.dumps(self.replay).encode()
        manifest = {"schema": 1, "kind": kind,
                    "identity": {"code_sha256": self.identity["code"],
                                 "engine_sha256": self.identity["engine"]},
                    "replay_sha256": hashlib.sha256(data).hexdigest()}
        return json.dumps(manifest).encode(), data

    def test_pinned_neutral_checkpoint(self):
        manifest, replay = self.inputs()
        self.assertEqual(local_worker.preflight(manifest, replay, self.identity), hashlib.sha256(replay).hexdigest())

    def test_unsupported_and_tampered_inputs(self):
        for key, change, expected in [
            ("kind", lambda m, r: m.update(kind="daily"), "unsupported manifest"),
            ("progression", lambda m, r: r["config"].update(progression="endless"), "unsupported replay progression"),
            ("generated-map", lambda m, r: r["config"].update(map="generated-123"), "unsupported replay map"),
            ("identity", lambda m, r: m["identity"].update(code_sha256="0" * 64), "runtime identity mismatch"),
            ("digest", lambda m, r: r.update(digests=["0" * 64]), "replay hash mismatch"),
        ]:
            with self.subTest(key=key):
                manifest, replay = self.inputs()
                m, r = json.loads(manifest), json.loads(replay)
                change(m, r)
                if key != "digest":
                    m["replay_sha256"] = hashlib.sha256(json.dumps(r).encode()).hexdigest()
                with self.assertRaisesRegex(ValueError, expected):
                    local_worker.preflight(json.dumps(m).encode(), json.dumps(r).encode(), self.identity)

    def test_oversized_is_bounded(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "input"
            path.write_bytes(b"x" * (local_worker.MAX_MANIFEST + 1))
            with self.assertRaisesRegex(ValueError, "oversized"):
                local_worker.read_bounded(path, local_worker.MAX_MANIFEST)

    def test_refusal_never_launches_or_verifies(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest, replay = self.inputs(kind="daily")
            (root / "manifest.json").write_bytes(manifest)
            (root / "replay.json").write_bytes(replay)
            out = root / "out"
            with patch.object(local_worker.runner, "launch", side_effect=AssertionError("engine launched")):
                code = local_worker.main(["--engine", sys.executable, "--manifest", str(root / "manifest.json"),
                                          "--replay", str(root / "replay.json"), "--out", str(out)])
            receipt = json.loads((out / "receipt.json").read_text())
            self.assertEqual(code, 1)
            self.assertEqual(receipt["status"], "refused")
            self.assertFalse(receipt["verified"])
            self.assertFalse(receipt["score_eligible"])

    def test_native_success_contract(self):
        replay = json.dumps(self.replay).encode()
        self.assertEqual(local_worker.native_result(self.native_success(), replay),
                         ("matched", "neutral checkpoint reproduced", 1200))
        for name, change in [
            ("missing-tick", lambda r: r["report"].pop("tick")),
            ("wrong-tick", lambda r: r["report"].update(tick=1199)),
            ("wrong-mode", lambda r: r["report"].update(mode="record")),
            ("missing-score", lambda r: r["report"].pop("score")),
            ("wrong-score", lambda r: r["report"]["score"].update(hp=199)),
            ("missing-checks", lambda r: r["report"].pop("checks")),
            ("zero-checks", lambda r: r["report"].update(checks=0)),
            ("missing-effects", lambda r: r["report"].pop("effects")),
            ("native-warning", lambda r: r.update(diagnostics=["WARNING: bogus"])),
            ("owned-child", lambda r: r.update(owned_job_final=[123])),
        ]:
            with self.subTest(name=name):
                result = self.native_success()
                change(result)
                self.assertEqual(local_worker.native_result(result, replay)[0], "worker_failure")

    def test_mocked_malformed_native_cannot_issue_match(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest, replay = self.inputs()
            (root / "manifest.json").write_bytes(manifest)
            (root / "replay.json").write_bytes(replay)
            result = self.native_success()
            result["report"] = {"error": "", "failures": []}
            out = root / "out"
            with patch.object(local_worker.runner, "source", return_value=({}, "a" * 64)), \
                 patch.object(local_worker.runner, "owner", return_value={}), \
                 patch.object(local_worker.runner, "sha", return_value="b" * 64), \
                 patch.object(local_worker.runner, "launch", return_value=result):
                code = local_worker.main(["--engine", sys.executable, "--manifest", str(root / "manifest.json"),
                                          "--replay", str(root / "replay.json"), "--out", str(out)])
            receipt = json.loads((out / "receipt.json").read_text())
            self.assertEqual(code, 1)
            self.assertEqual(receipt["status"], "worker_failure")
            self.assertFalse(receipt["verified"])


if __name__ == "__main__":
    unittest.main()
