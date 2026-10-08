#!/usr/bin/env python3
"""Раскладка GodotSteam в tools/build_steam.py (без движка и без сети).

    python -X utf8 tools/steam/test_build_steam_godotsteam.py

Поддельный плагин повторяет схему настоящего godotsteam.gdextension 4.23.1 (ключи
windows.release.x86_64 / linux.release.x86_64, зависимости steam_api); если настоящий плагин
лежит на месте (build_steam.GODOTSTEAM), раскладка проверяется и на нём.
"""
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_steam  # noqa: E402

MANIFEST = """[configuration]
entry_symbol = "godotsteam_init"
compatibility_minimum = "4.4"

[libraries]
linux.debug.x86_64 = "res://addons/godotsteam/linux64/libgodotsteam.linux.template_debug.x86_64.so"
linux.release.x86_64 = "res://addons/godotsteam/linux64/libgodotsteam.linux.template_release.x86_64.so"
windows.debug.x86_64 = "res://addons/godotsteam/win64/libgodotsteam.windows.template_debug.x86_64.dll"
windows.release.x86_64 = "res://addons/godotsteam/win64/libgodotsteam.windows.template_release.x86_64.dll"

[dependencies]
linux.x86_64 = { "res://addons/godotsteam/linux64/libsteam_api.so": "" }
windows.x86_64 = { "res://addons/godotsteam/win64/steam_api64.dll": "" }
"""
FILES = ("win64/libgodotsteam.windows.template_debug.x86_64.dll",
         "win64/libgodotsteam.windows.template_release.x86_64.dll", "win64/steam_api64.dll",
         "linux64/libgodotsteam.linux.template_debug.x86_64.so",
         "linux64/libgodotsteam.linux.template_release.x86_64.so", "linux64/libsteam_api.so")


class StageGodotSteamTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="necro-gs-test-")
        self.root = Path(self.tmp.name)
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.targets = {"windows": self.root / "dist/windows", "linux": self.root / "dist/linux"}
        for d in self.targets.values():
            d.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def fake_plugin(self, with_license: bool = True) -> Path:
        plugin = self.root / "plugin"
        gs = plugin / "stage1/addons/godotsteam"
        for rel in FILES:
            (gs / rel).parent.mkdir(parents=True, exist_ok=True)
            (gs / rel).write_bytes(rel.encode())
        (gs / "godotsteam.gdextension").write_text(MANIFEST, encoding="utf-8")
        if with_license:
            (gs / "license.md").write_text("MIT License\n", encoding="utf-8")
        return plugin

    def check_staged(self):
        win, linux = self.targets["windows"], self.targets["linux"]
        for d, api, lib in ((win, "steam_api64.dll", "libgodotsteam.windows.template_release.x86_64.dll"),
                            (linux, "libsteam_api.so", "libgodotsteam.linux.template_release.x86_64.so")):
            self.assertTrue((d / api).is_file(), d / api)                       # рядом с бинарём
            self.assertTrue((d / "godotsteam" / api).is_file())
            self.assertTrue((d / "godotsteam" / lib).is_file())
            self.assertTrue((d / "licenses" / "GODOTSTEAM_LICENSE.md").is_file())
            self.assertFalse(any(d.rglob("steam_appid.txt")))
            ext = (d / "godotsteam" / "godotsteam.gdextension").read_text(encoding="utf-8")
            self.assertNotIn("res://", ext)                                     # пути относительные
            self.assertNotIn("debug", ext)                                      # только release
        # чужая ОС в папку не попадает
        self.assertFalse(any(win.rglob("*.so")))
        self.assertFalse(any(linux.rglob("*.dll")))

    def test_fake_plugin_staged_for_both_os(self):
        note = build_steam.stage_godotsteam(self.fake_plugin(), self.targets, self.logs)
        self.assertTrue(note.startswith("GodotSteam"), note)
        self.check_staged()

    def test_missing_plugin_builds_without_steam_net(self):
        note = build_steam.stage_godotsteam(self.root / "nope", self.targets, self.logs)
        self.assertIn("без GodotSteam", note)
        for d in self.targets.values():
            self.assertEqual(list(d.iterdir()), [])                             # ничего не положено

    def test_disabled_builds_without_steam_net(self):
        note = build_steam.stage_godotsteam(None, self.targets, self.logs)
        self.assertIn("--no-godotsteam", note)

    def test_plugin_without_license_fails(self):
        with self.assertRaises(SystemExit):
            build_steam.stage_godotsteam(self.fake_plugin(with_license=False), self.targets, self.logs)

    @unittest.skipUnless(build_steam.GODOTSTEAM.is_dir(), "настоящего плагина нет на этой машине")
    def test_real_plugin(self):
        note = build_steam.stage_godotsteam(build_steam.GODOTSTEAM.resolve(), self.targets, self.logs)
        self.assertTrue(note.startswith("GodotSteam"), note)
        self.check_staged()


if __name__ == "__main__":
    unittest.main(verbosity=2)
