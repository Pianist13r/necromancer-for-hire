"""Structural release acceptance through main; synthetic inputs, no engine/network."""
import plistlib
import struct
import tarfile
import unittest
import zipfile

from release_test_fixtures import linux_bytes, mac_members, write_mac, write_platform_inputs
import test_release_staging as staging


class PlatformPackagesTest(unittest.TestCase):
    snapshot = staging.ReleaseStagingTest.snapshot
    invoke = staging.ReleaseStagingTest.invoke

    def setUp(self):
        staging.ReleaseStagingTest.setUp(self)
        write_platform_inputs(self.dist)
        self.before = self.snapshot()
        self.case_number = 0

    def rejected_before_output(self):
        self.case_number += 1
        version = f"test-alpha-{self.case_number}"
        self.final = self.parent / version
        before = self.snapshot()
        failure, output, _errors, metrics = self.invoke(version)
        self.assertIsNotNone(failure, "invalid platform package was accepted")
        self.assertEqual(metrics, 0, "invalid input reached network preflight")
        self.assertIn("platform preflight", str(failure))
        self.assertNotIn("готово:", output)
        self.assertFalse(self.final.exists())
        self.assertEqual(list(self.parent.glob(f".{version}.staging-*")), [])
        self.assertEqual(self.snapshot(), before)

    def test_linux_invalid_inputs(self):
        valid = linux_bytes()
        cases = {
            "text": b"linux", "missing pack": valid[:64],
            "truncated trailer": valid[:-1],
            "wrong machine": valid[:18] + struct.pack("<H", 183) + valid[20:],
            "oversized pack": valid[:-12] + struct.pack("<Q", len(valid)) + b"GDPC",
            "empty pack": valid[:-12] + struct.pack("<Q", 0) + b"GDPC",
            "bad pack magic": valid[:64] + b"XXXX" + valid[68:],
            "absolute pack": valid[:84] + bytes(4) + valid[88:],
        }
        for label, data in cases.items():
            with self.subTest(case=label):
                (self.dist / "linux/Necromancer.x86_64").write_bytes(data)
                self.rejected_before_output()

    def test_mac_missing_or_invalid_members(self):
        for key in mac_members():
            with self.subTest(missing=key):
                members = mac_members()
                del members[key]
                write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
                self.rejected_before_output()
        for key, replacement in {
            "Info.plist": (b"invalid plist", 0o100644),
            "MacOS/Necromancer": (b"not a Mach-O", 0o100755),
            "Resources/Necromancer.pck": (b"not a PCK", 0o100644),
        }.items():
            with self.subTest(invalid=key):
                members = mac_members()
                members["Necromancer.app/Contents/" + key] = replacement
                write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
                self.rejected_before_output()

    def test_mac_permissions_and_architecture(self):
        key = "Necromancer.app/Contents/MacOS/Necromancer"
        data, _ = mac_members()[key]
        wrong_slice = bytearray(data)
        wrong_slice[80:84] = b"xxxx"
        outside = bytearray(data)
        struct.pack_into(">I", outside, 16, 10000)
        for label, binary, mode in (
            ("no execute", data, 0o100644), ("symlink", data, 0o120755),
            ("only Intel", data[:4] + struct.pack(">I", 1) + data[8:], 0o100755),
            ("invalid slice", bytes(wrong_slice), 0o100755),
            ("outside file", bytes(outside), 0o100755),
        ):
            with self.subTest(case=label):
                members = mac_members()
                members[key] = (binary, mode)
                write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
                self.rejected_before_output()

    def test_mac_unsafe_paths_and_duplicates(self):
        for name in ("../escape", "/absolute", "C:/absolute", "a\\escape"):
            with self.subTest(path=name):
                members = mac_members()
                members[name] = (b"bad", 0o100644)
                write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
                self.rejected_before_output()
        path = self.dist / "macOS/Necromancer-macOS.zip"
        write_mac(path)
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("necromancer.app/Contents/INFO.plist", b"duplicate")
        self.rejected_before_output()

    def test_mac_wrong_bundle_or_executable(self):
        for field, value in (("CFBundleIdentifier", "other.game"),
                             ("CFBundleExecutable", "../outside")):
            with self.subTest(field=field):
                members = mac_members()
                key = "Necromancer.app/Contents/Info.plist"
                meta = plistlib.loads(members[key][0])
                meta[field] = value
                members[key] = (plistlib.dumps(meta), 0o100644)
                write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
                self.rejected_before_output()

    def test_mac_non_directory_parents_and_special_entries(self):
        parents = ("Necromancer.app", "Necromancer.app/Contents",
                   "Necromancer.app/Contents/Resources", "Necromancer.app/Contents/MacOS")
        for parent in parents:
            for mode in (0o120777, 0o100644, 0o010644):
                with self.subTest(parent=parent, mode=oct(mode)):
                    members = mac_members()
                    members[parent] = (b"../../../../outside", mode)
                    write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
                    self.rejected_before_output()
        for name, mode in (("unrelated-link", 0o120777),
                           ("Necromancer.app/Contents/Resources/", 0o100644),
                           ("unrelated-directory", 0o040755)):
            with self.subTest(name=name, mode=oct(mode)):
                members = mac_members()
                members[name] = (b"../../../../outside", mode)
                write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
                self.rejected_before_output()

    def test_mac_explicit_directories_are_supported(self):
        members = mac_members()
        for parent in ("Necromancer.app/", "Necromancer.app/Contents/",
                       "Necromancer.app/Contents/Resources/", "Necromancer.app/Contents/MacOS/"):
            members[parent] = (b"", 0o040755)
        write_mac(self.dist / "macOS/Necromancer-macOS.zip", members)
        failure, _output, _errors, metrics = self.invoke()
        self.assertIsNone(failure)
        self.assertEqual(metrics, 1)

    def test_valid_packages_preserve_payload_and_execute_modes(self):
        before = self.snapshot()
        failure, _output, _errors, metrics = self.invoke()
        self.assertIsNone(failure)
        self.assertEqual(metrics, 1)
        self.assertEqual(self.snapshot(), before)
        with tarfile.open(self.final / "NecromancerForHire-Linux.tar.gz") as archive:
            member = archive.getmember("Necromancer/Necromancer.x86_64")
            self.assertEqual(member.mode, 0o755)
            self.assertEqual(archive.extractfile(member).read(), linux_bytes())
        with zipfile.ZipFile(self.final / "NecromancerForHire-macOS.zip") as archive:
            for name, (data, mode) in mac_members().items():
                self.assertEqual(archive.read(name), data)
                self.assertEqual(archive.getinfo(name).external_attr >> 16, mode)


if __name__ == "__main__":
    unittest.main(verbosity=2)
