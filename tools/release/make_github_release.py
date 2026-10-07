"""Файлы выпуска для GitHub Releases из готовых сборок (только stdlib).

Берёт то, что уже собрано (tools/build_exe.bat, tools/build_macos.py, экспорт пресета Linux):
    dist/Necromancer/Necromancer.exe + .pck, dist/Necromancer-single/Necromancer.exe,
    dist/macOS/Necromancer-macOS.zip, dist/linux/Necromancer.x86_64
и кладёт в dist/github-release/<версия>/:
    NecromancerForHire-Windows.exe      один файл, игра вшита
    NecromancerForHire-Windows.zip      exe + pck + README + licenses/
    NecromancerForHire-macOS.zip        приложение (атрибуты zip сохранены) + README + licenses/
    NecromancerForHire-Linux.tar.gz     исполняемый файл (0755) + README + licenses/
    SHA256SUMS.txt
Имена файлов без версии; README указывает конкретный тег «releases/download/<версия>/<имя>».
Альфа-выпуски открываются со страницы Releases, без зависимости от ссылки latest.

    python -X utf8 tools/release/make_github_release.py 0.1.0-alpha [--skip-live-metrics]

До сборки файлов — metrics_preflight.py: версия клиента должна быть принята и кодом сервера
статистики, и рабочим сервером (сервер выкатывается раньше клиента). Собранный exe проверять
с NECRO_NO_METRICS=1: запуск без аргументов иначе уйдёт в статистику как игрок.
"""
import argparse
import hashlib
import io
import shutil
import sys
import tarfile
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import metrics_preflight  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
DIST = REPO / "dist"
LICENSES = [
    REPO / "PRIVACY.md",
    REPO / "LICENSING.md", REPO / "LICENSE.md", REPO / "ASSETS_LICENSE.md", REPO / "TRADEMARKS.md",
    REPO / "THIRD_PARTY_NOTICES.md", REPO / "tools/release/GODOT_LICENSE.txt",
    REPO / "tools/release/GODOT_COPYRIGHT.txt", REPO / "godot/assets/fonts/OFL-Underdog.txt",
    REPO / "godot/assets/fonts/OFL-Neucha.txt", REPO / "godot/addons/juicee/LICENSE.md",
    REPO / "godot/scripts/dev/GODOT_MCP_LICENSE.txt",
]
# одинаковые имена файлов в licenses/ не должны затирать друг друга
LICENSE_NAMES = {REPO / "godot/addons/juicee/LICENSE.md": "JUICEE_LICENSE.md"}
PREFIX = "NecromancerForHire"


def need(p: Path) -> Path:
    if not p.is_file():
        raise SystemExit(f"нет файла: {p}")
    return p


def add_licenses_zip(z: zipfile.ZipFile, root: str) -> None:
    for f in LICENSES:
        z.write(need(f), f"{root}licenses/{LICENSE_NAMES.get(f, f.name)}")


def windows_zip(out: Path) -> None:
    src = DIST / "Necromancer"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for name in ("Necromancer.exe", "Necromancer.pck", "README.txt"):
            z.write(need(src / name), f"Necromancer/{name}")
        add_licenses_zip(z, "Necromancer/")


def mac_zip(out: Path) -> None:
    src = need(DIST / "macOS/Necromancer-macOS.zip")
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            # копируем ZipInfo целиком: в external_attr лежат биты запуска приложения
            zout.writestr(info, zin.read(info.filename))
        zout.write(need(REPO / "tools/release/README-macOS.txt"), "README-macOS.txt")
        add_licenses_zip(zout, "")


def linux_tar(out: Path) -> None:
    def add(t: tarfile.TarFile, path: Path, arc: str, mode: int) -> None:
        data = need(path).read_bytes()
        ti = tarfile.TarInfo(arc)
        ti.size, ti.mode, ti.mtime = len(data), mode, int(time.time())
        t.addfile(ti, io.BytesIO(data))

    with tarfile.open(out, "w:gz") as t:
        add(t, DIST / "linux/Necromancer.x86_64", "Necromancer/Necromancer.x86_64", 0o755)
        add(t, REPO / "tools/release/README-Linux.txt", "Necromancer/README.txt", 0o644)
        for f in LICENSES:
            add(t, f, f"Necromancer/licenses/{LICENSE_NAMES.get(f, f.name)}", 0o644)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version")
    parser.add_argument("--skip-live-metrics", action="store_true",
                        help="без сети: сверить только код сервера, рабочий — позже вручную")
    args = parser.parse_args()
    metrics_preflight.check(args.version, live=not args.skip_live_metrics, repo=REPO)
    out_dir = DIST / "github-release" / args.version
    if out_dir.exists():
        raise SystemExit(f"уже есть: {out_dir} — выберите другую версию или уберите папку сами")
    out_dir.mkdir(parents=True)
    shutil.copy2(need(DIST / "Necromancer-single/Necromancer.exe"), out_dir / f"{PREFIX}-Windows.exe")
    windows_zip(out_dir / f"{PREFIX}-Windows.zip")
    mac_zip(out_dir / f"{PREFIX}-macOS.zip")
    linux_tar(out_dir / f"{PREFIX}-Linux.tar.gz")
    lines = []
    for f in sorted(out_dir.iterdir()):
        h = hashlib.sha256(f.read_bytes()).hexdigest()
        lines.append(f"{h}  {f.name}")
        print(f"{f.stat().st_size / 2**20:8.1f} МБ  {f.name}")
    (out_dir / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    for name in (f"{PREFIX}-Windows.zip", f"{PREFIX}-macOS.zip"):
        with zipfile.ZipFile(out_dir / name) as z:
            assert z.testzip() is None, name
    with tarfile.open(out_dir / f"{PREFIX}-Linux.tar.gz") as t:
        exe = t.getmember("Necromancer/Necromancer.x86_64")
        assert exe.mode & 0o111, "у Linux-файла нет бита запуска"
    print(f"готово: {out_dir}")


if __name__ == "__main__":
    main()
