"""Сервер статистики раньше клиента: make_github_release.py отказывается собирать выпуск,
если версию клиента не примет сервер (иначе клиент получает 400 и повторяет пакет без конца).

Фальшивый репозиторий во временной папке и настоящий приёмник tools/server на loopback;
публичный сервер не вызывается.

    python -X utf8 tools/release/test_metrics_preflight.py
"""
import contextlib
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tools/server"))
try:
    from metrics_service import MetricsServer, Store, VERSION  # noqa: E402
except ModuleNotFoundError:  # публичный снимок без tools/server: проверять там нечего
    MetricsServer = None

LICENSE_FILES = [
    "PRIVACY.md", "LICENSING.md", "LICENSE.md", "ASSETS_LICENSE.md", "TRADEMARKS.md",
    "THIRD_PARTY_NOTICES.md", "tools/release/GODOT_LICENSE.txt", "tools/release/GODOT_COPYRIGHT.txt",
    "godot/assets/fonts/OFL-Underdog.txt", "godot/assets/fonts/OFL-Neucha.txt",
    "godot/addons/juicee/LICENSE.md", "godot/scripts/dev/GODOT_MCP_LICENSE.txt",
]


@unittest.skipIf(MetricsServer is None, "нет tools/server (публичный снимок)")
class ReleasePreflightTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="necro-release-")
        self.root = Path(self.scratch.name) / "repo"
        self.db = Path(self.scratch.name) / "live.sqlite3"
        self.store = Store(self.db)
        self.server = MetricsServer(("127.0.0.1", 0), self.store, deadline=2)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05})
        self.thread.start()
        host, port = self.server.server_address
        self.build_fake_repo(f"http://{host}:{port}/metrics/v1")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.scratch.cleanup()

    def write(self, rel: str, text: str = "x\n") -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def build_fake_repo(self, endpoint: str) -> None:
        for name in ("make_github_release.py", "metrics_preflight.py"):
            if (HERE / name).is_file():  # старый код без проверки тоже должен запускаться
                (self.root / "tools/release").mkdir(parents=True, exist_ok=True)
                shutil.copy2(HERE / name, self.root / "tools/release" / name)
        for rel in LICENSE_FILES + ["tools/release/README-macOS.txt", "tools/release/README-Linux.txt",
                                    "dist/Necromancer-single/Necromancer.exe",
                                    "dist/Necromancer/Necromancer.exe", "dist/Necromancer/Necromancer.pck",
                                    "dist/Necromancer/README.txt", "dist/linux/Necromancer.x86_64"]:
            self.write(rel)
        (self.root / "dist/macOS").mkdir(parents=True)
        with zipfile.ZipFile(self.root / "dist/macOS/Necromancer-macOS.zip", "w") as z:
            z.writestr("Necromancer.app/Contents/Info.plist", "x")
        self.write("godot/scripts/common/play_metrics.gd",
                   f'class_name PlayMetrics\n\nconst ENDPOINT := "{endpoint}"\n')
        self.set_client("9.9.9-alpha")
        self.set_repo_server({VERSION})

    def set_client(self, version: str) -> None:
        self.write("godot/scripts/common/release_info.gd",
                   f'class_name ReleaseInfo\nextends RefCounted\n\nconst VERSION := "{version}"\n')

    def set_repo_server(self, accepted: set) -> None:
        self.write("tools/server/metrics_service.py",
                   f"VERSION = {VERSION!r}\nACCEPTED_VERSIONS = frozenset({sorted(accepted)!r})\n")

    def release(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-X", "utf8", str(self.root / "tools/release/make_github_release.py"),
                               *args], capture_output=True, text=True, encoding="utf-8", timeout=60)

    def out_dir(self, version: str) -> Path:
        return self.root / "dist/github-release" / version

    def live_rows(self):
        with contextlib.closing(sqlite3.connect(self.db)) as db:
            return (db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0],
                    db.execute("SELECT COUNT(*) FROM daily").fetchone()[0])

    def test_refuses_version_missing_from_server_code(self):
        result = self.release("9.9.9-alpha")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("ACCEPTED_VERSIONS", result.stdout + result.stderr)
        self.assertFalse(self.out_dir("9.9.9-alpha").exists())

    def test_refuses_when_live_server_not_updated(self):
        # Код сервера в репозитории дополнен, а рабочий сервер ещё старый: настоящий приёмник 400.
        self.set_repo_server({VERSION, "9.9.9-alpha"})
        result = self.release("9.9.9-alpha")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("400", result.stdout + result.stderr)
        self.assertFalse(self.out_dir("9.9.9-alpha").exists())
        self.assertEqual(self.live_rows(), (0, 0))

    def test_accepted_version_builds_and_probe_writes_nothing(self):
        self.set_client(VERSION)
        result = self.release(VERSION)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.out_dir(VERSION) / "SHA256SUMS.txt").is_file())
        self.assertEqual(self.live_rows(), (0, 0))

    def test_release_tag_must_match_client_version(self):
        self.set_client(VERSION)
        result = self.release("0.0.1-alpha")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ReleaseInfo.VERSION", result.stdout + result.stderr)
        self.assertFalse(self.out_dir("0.0.1-alpha").exists())

    def test_offline_mode_still_checks_repository(self):
        self.write("godot/scripts/common/play_metrics.gd",
                   'class_name PlayMetrics\n\nconst ENDPOINT := "http://127.0.0.1:9/metrics/v1"\n')
        result = self.release("9.9.9-alpha", "--skip-live-metrics")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ACCEPTED_VERSIONS", result.stdout + result.stderr)
        self.set_client(VERSION)
        result = self.release(VERSION, "--skip-live-metrics")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("не проверен", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
