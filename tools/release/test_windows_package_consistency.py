"""Synthetic Windows pair preflight through main; no engine, live dist or network.

This checks packaging consistency, not ReleaseInfo/source provenance or runtime.
"""
import contextlib
import io
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import make_github_release as release
from release_test_fixtures import write_platform_inputs


class WindowsPairTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="necro-windows-pair-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.engine = b"MZ" + b"synthetic engine" * 80000
        self.pck = b"GDPC" + struct.pack("<5I", 4, 4, 7, 2, 2) + bytes(8) + b"synthetic pack" * 90000
        self.set_dist(self.root / "dist")
        self.write_pair()

    def set_dist(self, dist):
        self.dist = dist
        self.split = self.dist / "Necromancer/Necromancer.exe"
        self.pack = self.split.with_suffix(".pck")
        self.single = self.dist / "Necromancer-single/Necromancer.exe"
        self.out = self.dist / "github-release/test-alpha"

    def write_pair(self):
        for path, data in ((self.split, self.engine), (self.pack, self.pck),
                           (self.single, self.engine + self.pck + struct.pack("<Q", len(self.pck)) + b"GDPC")):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def inputs(self):
        return {str(path.relative_to(self.dist)): path.read_bytes()
                for parent in (self.split.parent, self.single.parent)
                for path in parent.rglob("*") if path.is_file()}

    @staticmethod
    def fake_zip(path):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("synthetic", "payload")

    @staticmethod
    def fake_linux(path):
        with tarfile.open(path, "w:gz") as archive:
            entry = tarfile.TarInfo("Necromancer/Necromancer.x86_64")
            entry.mode = 0o755
            archive.addfile(entry)

    def invoke(self):
        write_platform_inputs(self.dist)
        with patch.object(release, "DIST", self.dist), patch.object(release, "REPO", self.root), \
                patch.object(release.metrics_preflight, "check") as metrics, \
                patch.object(release, "windows_zip", side_effect=self.fake_zip) as windows, \
                patch.object(release, "mac_zip", side_effect=self.fake_zip), \
                patch.object(release, "linux_tar", side_effect=self.fake_linux), \
                patch("sys.argv", ["make_github_release.py", "test-alpha"]), \
                contextlib.redirect_stdout(io.StringIO()):
            error = None
            try:
                release.main()
            except SystemExit as exc:
                error = exc
            return error, metrics.call_count, windows.call_count

    def test_valid_pair_passes_without_changing_sources(self):
        before = self.inputs()
        error, metrics, packaging = self.invoke()
        self.assertIsNone(error)
        self.assertEqual((metrics, packaging), (1, 1))
        self.assertEqual(self.inputs(), before)
        self.assertEqual((self.out / "NecromancerForHire-Windows.exe").read_bytes(),
                         self.single.read_bytes())
        self.assertEqual({p.name for p in self.out.iterdir()}, {
            "NecromancerForHire-Windows.exe", "NecromancerForHire-Windows.zip",
            "NecromancerForHire-macOS.zip", "NecromancerForHire-Linux.tar.gz", "SHA256SUMS.txt"})

    def test_inconsistent_pair_rejected_before_metrics_and_output(self):
        mutations = {
            "same_size_engine": lambda: self.split.write_bytes(b"ZZ" + self.engine[2:]),
            "same_size_pck": lambda: self.pack.write_bytes(self.pck[:-1] + b"!"),
            "truncated_single": lambda: self.single.write_bytes(self.single.read_bytes()[:-1]),
            "wrong_trailer_size": lambda: self.single.write_bytes(
                self.engine + self.pck + struct.pack("<Q", len(self.pck) - 1) + b"GDPC"),
            "wrong_trailer_magic": lambda: self.single.write_bytes(
                self.engine + self.pck + struct.pack("<Q", len(self.pck)) + b"BAD!"),
            "extra_single_bytes": lambda: self.single.write_bytes(self.single.read_bytes() + b"extra"),
            "missing_engine": lambda: self.split.unlink(),
            "missing_pck": lambda: self.pack.unlink(),
            "missing_single": lambda: self.single.unlink(),
        }
        for name, mutate in mutations.items():
            with self.subTest(case=name):
                # Separate dist for every subcase, including RED where old main creates output.
                self.set_dist(self.root / name)
                self.write_pair()
                mutate()
                before = self.inputs()
                error, metrics, packaging = self.invoke()
                self.assertEqual(self.inputs(), before)
                self.assertFalse(self.out.parent.exists(), "output created for invalid pair")
                self.assertEqual((metrics, packaging), (0, 0), "local rejection must precede metrics")
                self.assertIsNotNone(error, "inconsistent Windows pair was packaged")

    def test_invalid_embed_inputs_rejected_even_when_single_matches(self):
        for name in ("pck_magic", "pck_short", "pck_version", "pck_absolute", "embedded_engine"):
            with self.subTest(case=name):
                self.set_dist(self.root / name)
                original_engine, original_pck = self.engine, self.pck
                if name == "pck_magic":
                    self.pck = b"BAD!" + self.pck[4:]
                elif name == "pck_short":
                    self.pck = self.pck[:31]
                elif name == "pck_version":
                    self.pck = self.pck[:4] + struct.pack("<I", 1) + self.pck[8:]
                elif name == "pck_absolute":
                    self.pck = self.pck[:20] + struct.pack("<I", 0) + self.pck[24:]
                else:
                    self.engine += b"GDPC"
                self.write_pair()
                before = self.inputs()
                try:
                    error, metrics, packaging = self.invoke()
                    self.assertEqual(self.inputs(), before)
                    self.assertFalse(self.out.parent.exists(), "output created for invalid embed input")
                    self.assertEqual((metrics, packaging), (0, 0))
                    self.assertIsNotNone(error)
                finally:
                    self.engine, self.pck = original_engine, original_pck


if __name__ == "__main__":
    unittest.main(verbosity=2)
