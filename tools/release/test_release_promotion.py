"""Mock Linux/macOS API contracts, not native execution evidence for those hosts."""
import ctypes
import errno
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import make_github_release as release
import test_release_staging as staging


class PromotionContractsTest(unittest.TestCase):
    def test_linux_and_macos_signatures_and_no_replace_flags(self):
        source, destination = Path("/synthetic/stage"), Path("/synthetic/final")
        for platform, symbol, argtypes, arguments in (
            ("linux", "renameat2", [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint],
             (-100, os.fsencode(source), -100, os.fsencode(destination), 1)),
            ("darwin", "renamex_np", [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint],
             (os.fsencode(source), os.fsencode(destination), 4)),
        ):
            with self.subTest(platform=platform):
                function = Mock(return_value=0)
                library = SimpleNamespace(**{symbol: function})
                with patch.object(release.sys, "platform", platform), \
                        patch.object(release.ctypes, "CDLL", return_value=library) as loader, \
                        patch.object(release.os, "rename") as unsafe:
                    release.promote_no_replace(source, destination)
                loader.assert_called_once_with(None, use_errno=True)
                function.assert_called_once_with(*arguments)
                self.assertEqual(function.argtypes, argtypes)
                self.assertIs(function.restype, ctypes.c_int)
                unsafe.assert_not_called()

    def test_native_errors_propagate_without_plain_rename_fallback(self):
        for platform, symbol in (("linux", "renameat2"), ("darwin", "renamex_np")):
            for code in (errno.EEXIST, errno.ENOSYS, errno.EOPNOTSUPP, errno.EIO):
                with self.subTest(platform=platform, code=code):
                    library = SimpleNamespace(**{symbol: Mock(return_value=-1)})
                    with patch.object(release.sys, "platform", platform), \
                            patch.object(release.ctypes, "CDLL", return_value=library), \
                            patch.object(release.ctypes, "get_errno", return_value=code), \
                            patch.object(release.os, "rename") as unsafe:
                        with self.assertRaises(OSError) as caught:
                            release.promote_no_replace(Path("/stage"), Path("/final"))
                    self.assertEqual(caught.exception.errno, code)
                    unsafe.assert_not_called()

    def test_missing_symbol_and_unsupported_platform_fail_closed(self):
        for platform in ("linux", "darwin", "unsupported-test-os"):
            with self.subTest(platform=platform), patch.object(release.sys, "platform", platform), \
                    patch.object(release.ctypes, "CDLL", return_value=SimpleNamespace()), \
                    patch.object(release.os, "rename") as unsafe:
                with self.assertRaises(OSError) as caught:
                    release.promote_no_replace(Path("/stage"), Path("/final"))
                self.assertEqual(caught.exception.errno, errno.ENOTSUP)
                unsafe.assert_not_called()

    def fixture(self):
        case = staging.ReleaseStagingTest("test_success_promotes_only_complete_inventory")
        case.setUp()
        self.addCleanup(case.doCleanups)
        return case

    def test_main_retains_stage_on_native_unknown_error(self):
        case = self.fixture()
        library = SimpleNamespace(renameat2=Mock(return_value=-1))
        with patch.object(release.sys, "platform", "linux"), \
                patch.object(release.ctypes, "CDLL", return_value=library), \
                patch.object(release.ctypes, "get_errno", return_value=errno.EIO):
            case.retained_failure(case.invoke())

    def test_main_retains_stage_on_unavailable_primitive(self):
        case = self.fixture()
        with patch.object(release.sys, "platform", "darwin"), \
                patch.object(release.ctypes, "CDLL", return_value=SimpleNamespace()):
            case.retained_failure(case.invoke())

    def test_success_manifest_lists_each_payload_exactly_once(self):
        case = self.fixture()
        failure, _output, errors, _metrics = case.invoke()
        self.assertIsNone(failure, errors)
        lines = (case.final / "SHA256SUMS.txt").read_text().splitlines()
        self.assertEqual(len(lines), 4)
        self.assertEqual({line.split("  ")[1] for line in lines}, {
            "NecromancerForHire-Windows.exe", "NecromancerForHire-Windows.zip",
            "NecromancerForHire-macOS.zip", "NecromancerForHire-Linux.tar.gz"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
