"""Synthetic packaging failures and destination races; no live builds/services.

Native promotion is exercised only on the execution host. Run with -O as well:
acceptance must not depend on Python assertions being enabled.
"""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import make_github_release as release
from release_test_fixtures import write_platform_inputs


class ReleaseStagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="necro-release-staging-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dist = self.root / "dist"
        self.parent = self.dist / "github-release"
        self.final = self.parent / "test-alpha"
        engine = b"MZ synthetic engine"
        pck = b"GDPC" + struct.pack("<5I", 4, 4, 7, 2, 2) + bytes(8)
        for name, data in {
            "dist/Necromancer/Necromancer.exe": engine,
            "dist/Necromancer/Necromancer.pck": pck,
            "dist/Necromancer/README.txt": b"readme",
            "dist/Necromancer-single/Necromancer.exe": engine + pck + struct.pack("<Q", len(pck)) + b"GDPC",
            "tools/release/README-macOS.txt": b"mac readme",
            "tools/release/README-Linux.txt": b"linux readme",
            "LICENSE.txt": b"synthetic license",
            "dist/github-release/prior-tag/sentinel": b"previous release",
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        write_platform_inputs(self.dist)
        self.licenses = [self.root / "LICENSE.txt"]
        self.before = self.snapshot()

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()
                and not path.is_relative_to(self.parent / "test-alpha")
                and not any(part.startswith(".test-alpha.staging-") for part in path.parts)}

    def invoke(self, version="test-alpha"):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(release, "REPO", self.root), patch.object(release, "DIST", self.dist), \
                patch.object(release, "LICENSES", self.licenses), \
                patch.object(release.metrics_preflight, "check") as metrics, \
                patch("sys.argv", ["make_github_release.py", version]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            failure = None
            try:
                release.main()
            except BaseException as error:
                failure = error
        return failure, output.getvalue(), errors.getvalue(), metrics.call_count

    def retained_failure(self, result):
        failure, output, errors, _metrics = result
        self.assertIsNotNone(failure)
        self.assertFalse(os.path.lexists(self.final), "failed release exposed final directory")
        stages = list(self.parent.glob(".test-alpha.staging-*"))
        self.assertEqual(len(stages), 1, errors)
        self.assertIn(str(stages[0]), errors)
        self.assertNotIn("готово:", output)
        self.assertEqual(self.snapshot(), self.before)
        self.assertTrue((stages[0] / "NecromancerForHire-Windows.exe").is_file())

    def test_late_archive_failure_retains_stage(self):
        with patch.object(release, "linux_tar", side_effect=OSError("synthetic archive failure")):
            self.retained_failure(self.invoke())

    def test_late_license_failure_retains_stage(self):
        self.licenses.append(self.root / "missing-license")
        self.retained_failure(self.invoke())

    def test_failed_zip_validation_retains_stage_even_optimized(self):
        with patch.object(zipfile.ZipFile, "testzip", return_value="bad-member"):
            self.retained_failure(self.invoke())

    def test_failed_tar_mode_retains_stage_even_optimized(self):
        import tarfile
        real = tarfile.TarFile.getmember

        def bad_mode(archive, name):
            member = real(archive, name)
            member.mode = 0o644
            return member

        with patch.object(tarfile.TarFile, "getmember", bad_mode):
            self.retained_failure(self.invoke())

    def test_keyboard_interrupt_retains_stage(self):
        with patch.object(release, "linux_tar", side_effect=KeyboardInterrupt):
            self.retained_failure(self.invoke())

    def test_existing_empty_destination_refused_before_metrics(self):
        self.final.mkdir()
        failure, _out, _err, metrics = self.invoke()
        self.assertIsNotNone(failure)
        self.assertEqual(metrics, 0)
        self.assertEqual(list(self.final.iterdir()), [])
        self.assertEqual(list(self.parent.glob(".test-alpha.staging-*")), [])
        self.assertEqual(self.snapshot(), self.before)

    def test_existing_nonempty_destination_preserved(self):
        self.final.mkdir()
        marker = self.final / "existing"
        marker.write_bytes(b"owned")
        failure, _out, _err, metrics = self.invoke()
        self.assertIsNotNone(failure)
        self.assertEqual(metrics, 0)
        self.assertEqual(list(self.final.iterdir()), [marker])
        self.assertEqual(marker.read_bytes(), b"owned")

    def test_existing_file_preserved(self):
        self.final.write_bytes(b"owned")
        failure, _out, _err, metrics = self.invoke()
        self.assertIsNotNone(failure)
        self.assertEqual(metrics, 0)
        self.assertEqual(self.final.read_bytes(), b"owned")

    def make_dangling_link(self):
        try:
            self.final.symlink_to(self.root / "absent-target", target_is_directory=True)
        except OSError as error:
            self.skipTest(f"host cannot create synthetic directory symlink: {error}")

    def test_dangling_destination_refused_before_metrics(self):
        self.make_dangling_link()
        failure, _out, _err, metrics = self.invoke()
        self.assertIsNotNone(failure)
        self.assertEqual(metrics, 0)
        self.assertTrue(self.final.is_symlink())
        self.assertFalse(self.final.exists())
        self.assertEqual(list(self.parent.glob(".test-alpha.staging-*")), [])

    def race_case(self, dangling=False):
        real = zipfile.ZipFile.testzip
        seen = []

        def race(archive):
            result = real(archive)
            seen.append(archive.filename)
            if len(seen) == 2:
                if dangling:
                    # Old main already exposed final: its existence itself proves RED.
                    if not os.path.lexists(self.final):
                        self.make_dangling_link()
                else:
                    self.final.mkdir(exist_ok=True)
            return result

        with patch.object(zipfile.ZipFile, "testzip", race):
            failure, output, errors, _metrics = self.invoke()
        self.assertIsNotNone(failure, "destination race overwrote/accepted occupied target")
        if dangling:
            self.assertTrue(self.final.is_symlink())
            self.assertFalse(self.final.exists())
        else:
            self.assertTrue(self.final.is_dir())
            self.assertEqual(list(self.final.iterdir()), [], "race-created directory overwritten")
        stages = list(self.parent.glob(".test-alpha.staging-*"))
        self.assertEqual(len(stages), 1)
        self.assertIn(str(stages[0]), errors)
        self.assertNotIn("готово:", output)
        self.assertEqual(self.snapshot(), self.before)

    def test_race_empty_directory_not_replaced(self):
        self.race_case()

    def test_race_dangling_link_not_replaced(self):
        self.race_case(dangling=True)

    def test_unsafe_version_component_refused_before_metrics(self):
        for version in ("../escape", "a/b", "a\\b", ".", "..", "CON", "trailing.", "x:y"):
            with self.subTest(version=version):
                failure, _out, _err, metrics = self.invoke(version)
                self.assertIsNotNone(failure)
                self.assertEqual(metrics, 0)
                self.assertEqual(self.snapshot(), self.before)

    def test_success_promotes_only_complete_inventory(self):
        failure, output, errors, metrics = self.invoke()
        self.assertIsNone(failure, str(failure) + errors)
        self.assertEqual(metrics, 1)
        self.assertEqual(list(self.parent.glob(".test-alpha.staging-*")), [])
        self.assertEqual({p.name for p in self.final.iterdir()}, {
            "NecromancerForHire-Windows.exe", "NecromancerForHire-Windows.zip",
            "NecromancerForHire-macOS.zip", "NecromancerForHire-Linux.tar.gz", "SHA256SUMS.txt"})
        for line in (self.final / "SHA256SUMS.txt").read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(hashlib.sha256((self.final / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(self.snapshot(), self.before)
        self.assertIn(f"готово: {self.final}", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
