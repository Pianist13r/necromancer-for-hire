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
import zipfile
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch, Mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import build_steam  # noqa: E402
import build_linux  # noqa: E402
import build_macos  # noqa: E402

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


class BuildSandboxCleanupTest(unittest.TestCase):
    """Exercise real main() lifetimes; replace engine/process calls with file fixtures."""

    def exercise(self, module, failure=None):
        # Keep all fixtures in our own temporary directory, including fake Steam dist.
        with tempfile.TemporaryDirectory(prefix="necro-cleanup-test-") as fixture:
            root = Path(fixture)
            godot = root / "fake-godot.exe"
            godot.touch()
            template = root / "template.zip"
            with zipfile.ZipFile(template, "w") as archive:
                for name in getattr(module, "NEED", ()):
                    archive.writestr(name, b"fixture")
            out = root / "result" / "build.bin"
            neighbor = root / "previous-sandbox"
            neighbor.mkdir()
            sentinel = neighbor / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")
            created = []
            real_temporary_directory = tempfile.TemporaryDirectory

            def sandbox_factory(*args, **kwargs):
                tmp = real_temporary_directory(*args, dir=root, **kwargs)
                created.append(Path(tmp.name))
                return tmp

            def fake_engine(*args, **kwargs):
                # Check user profile isolation while the scoped sandbox is still alive.
                cmd, env, log = args[:3] if module is build_steam else args[1:4]
                self.assertEqual(Path(env["APPDATA"]), created[0] / "appdata")
                self.assertTrue(Path(env["APPDATA"]).is_dir())
                log.write_text("fixture log", encoding="utf-8")
                if failure == "engine":
                    raise SystemExit("fixture engine failure")
                if "--export-release" in cmd:
                    result = Path(cmd[cmd.index("--export-release") + 2])
                    # A sparse fixture satisfies the builder's size/footer check.
                    with result.open("wb") as stream:
                        stream.seek(50 * 2**20)
                        stream.write(b"GDPC")
                    log.write_text("\n".join(f"savepack | file: res://fixture{i}.txt"
                                             for i in range(1000)), encoding="utf-8")
                elif "build_probe=1" in cmd:
                    log.write_text("PROBE version=0.1.0 steam=true is_steam=true ship=true debug=false",
                                   encoding="utf-8")
                return 0

            argv = [module.__file__, "--godot", str(godot)]
            argv += (["--template", str(template)] if module is build_macos
                     else ["--tpz", str(template)])
            if module is not build_steam:
                argv += ["--out", str(out)]
            with ExitStack() as stack:
                stack.enter_context(patch.object(sys, "argv", argv))
                stack.enter_context(patch.object(module.tempfile, "TemporaryDirectory", sandbox_factory))
                stack.enter_context(patch.object(module.subprocess, "run", side_effect=AssertionError("unexpected process")))
                if module is build_steam:
                    stack.enter_context(patch.object(module, "REPO", root))
                    stack.enter_context(patch.object(module, "owner_game_running", return_value=False))
                    stack.enter_context(patch.object(module, "release_version", return_value="0.1.0"))
                    stack.enter_context(patch.object(module, "preset_options", return_value={
                        "application/file_version": "0.1.0.0", "application/product_version": "0.1.0.0",
                        "custom_features": "steam", "binary_format/embed_pck": "true"}))
                    stack.enter_context(patch.object(module, "run", side_effect=fake_engine))
                    stack.enter_context(patch.object(module, "stage_godotsteam", return_value="GodotSteam fixture"))
                    stack.enter_context(patch.object(module, "copy_licenses"))
                    stack.enter_context(patch.object(module, "pe_info", return_value={}))
                    stack.enter_context(patch.object(module, "sha256", return_value="fixture"))
                    module.subprocess.run.side_effect = None
                    module.subprocess.run.return_value = Mock(stdout="fixture")
                    out = root / "dist/steam/windows/Necromancer.exe"
                else:
                    stack.enter_context(patch.object(module, "run_godot", side_effect=fake_engine))
                if module is build_macos:
                    stack.enter_context(patch.object(module, "verify"))
                    real_copy = module.shutil.copy2
                    def fake_copy(source, dest):
                        if Path(source) == template:
                            if failure == "template":
                                raise OSError("fixture template failure")
                            return real_copy(source, dest)
                        Path(dest).write_text("fixture readme", encoding="utf-8")
                    stack.enter_context(patch.object(module.shutil, "copy2", side_effect=fake_copy))
                elif failure == "template":
                    stack.enter_context(patch.object(module.zipfile.ZipFile, "read", side_effect=KeyError("fixture missing template")))
                if failure:
                    with self.assertRaises((SystemExit, OSError, KeyError)):
                        module.main()
                else:
                    module.main()
                    self.assertTrue(out.is_file())
                self.assertEqual(len(created), 1)
                self.assertFalse(created[0].exists(), created[0])
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
                if failure != "template":
                    logs = (root / "dist/steam/logs" if module is build_steam else out.parent)
                    self.assertTrue(any(logs.glob("*.log")))

    def test_success_preserves_output_and_logs(self):
        for module in (build_linux, build_macos, build_steam):
            with self.subTest(builder=module.__name__):
                self.exercise(module)

    def test_engine_failure_preserves_logs(self):
        for module in (build_linux, build_macos, build_steam):
            with self.subTest(builder=module.__name__):
                self.exercise(module, "engine")

    def test_template_failure_cleans_partial_sandbox(self):
        for module in (build_linux, build_macos, build_steam):
            with self.subTest(builder=module.__name__):
                self.exercise(module, "template")


if __name__ == "__main__":
    unittest.main(verbosity=2)
