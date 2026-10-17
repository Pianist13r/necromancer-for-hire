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
Перед сетью/выходом проверяются Windows single/split и структура Linux/macOS:
ELF x86_64 с embedded PCK; Universal 2 app с исполняемыми битами и ресурсным PCK.
Эта проверка не доказывает запуск на ОС, подпись или происхождение из исходников.
"""
import argparse
import ctypes
import errno
import hashlib
import io
import os
import plistlib
import re
import shutil
import stat
import struct
import sys
import tarfile
import tempfile
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


def check_windows_pair(dist: Path) -> None:
    """Compare the local embed_pck layout using bounded reads, before any release writes.

    This proves byte agreement of these inputs, not source/version provenance or runtime.
    Inputs must remain quiescent until packaging finishes (no snapshot/locking here).
    """
    engine_path = need(dist / "Necromancer/Necromancer.exe")
    pck_path = need(dist / "Necromancer/Necromancer.pck")
    single_path = need(dist / "Necromancer-single/Necromancer.exe")

    def reject(reason: str) -> None:
        raise SystemExit(f"Windows pair preflight: {reason}")

    try:
        with engine_path.open("rb") as engine, pck_path.open("rb") as pck, single_path.open("rb") as single:
            engine_size = engine.seek(0, 2)
            pck_size = pck.seek(0, 2)
            single_size = single.seek(0, 2)
            pck.seek(0)
            head = pck.read(32)
            if len(head) != 32 or head[:4] != b"GDPC":
                reject("invalid PCK header")
            version, _major, _minor, _patch, flags = struct.unpack("<5I", head[4:24])
            if version < 2 or not flags & 2:
                reject("PCK requires version >= 2 and relative filebase flag 2")
            engine.seek(max(0, engine_size - 4))
            if engine.read(4) == b"GDPC":
                reject("split engine already has an embedded PCK")
            if single_size != engine_size + pck_size + 12:
                reject("standalone size differs from engine + PCK + trailer")
            single.seek(-12, 2)
            if single.read(12) != struct.pack("<Q", pck_size) + b"GDPC":
                reject("standalone trailer magic or PCK size differs")
            single.seek(0)
            for source, size, label in ((engine, engine_size, "engine"), (pck, pck_size, "PCK")):
                source.seek(0)
                remaining = size
                while remaining:
                    count = min(1024 * 1024, remaining)
                    chunk = source.read(count)
                    if len(chunk) != count or single.read(count) != chunk:
                        reject(f"standalone {label} bytes differ from split input")
                    remaining -= count
    except OSError as error:
        reject(f"cannot read Windows inputs: {error}")


def check_platform_packages(dist: Path) -> None:
    """Reject structurally unusable Linux/macOS inputs before network/output.

    Matches the shipped ELF x86_64 + relative embedded PCK and Universal 2 app
    presets. This is not runtime, code-signature, PCK-content or source/version
    validation. Inputs must remain quiescent throughout packaging.
    """
    def require(ok: bool, reason: str) -> None:
        if not ok:
            raise ValueError(reason)

    def check_pack(stream) -> None:
        header = stream.read(32)
        require(len(header) == 32 and header[:4] == b"GDPC", "invalid PCK header")
        version, _major, _minor, _patch, flags = struct.unpack("<5I", header[4:24])
        require(version >= 2 and bool(flags & 2), "PCK needs relative filebase flag 2")

    try:
        with (dist / "linux/Necromancer.x86_64").open("rb") as stream:
            header = stream.read(64)
            require(len(header) == 64 and header[:7] == b"\x7fELF\x02\x01\x01",
                    "Linux needs a 64-bit little-endian ELF")
            kind, machine, version = struct.unpack("<HHI", header[16:24])
            require(kind in (2, 3) and machine == 62 and version == 1,
                    "Linux needs an x86_64 executable ELF")
            size = stream.seek(0, 2)
            stream.seek(-12, 2)
            tail = stream.read(12)
            pack_size = struct.unpack("<Q", tail[:8])[0]
            require(tail[8:] == b"GDPC" and 32 <= pack_size <= size - 64 - 12,
                    "Linux embedded PCK trailer/size invalid or missing")
            stream.seek(size - 12 - pack_size)
            check_pack(stream)

        with zipfile.ZipFile(dist / "macOS/Necromancer-macOS.zip") as archive:
            infos = archive.infolist()
            names = [i.filename for i in infos]
            entries = {i.filename.rstrip("/").casefold(): i for i in infos}
            require(len(entries) == len(names),
                    "macOS ZIP has duplicate/case-colliding entries")
            for info in infos:
                # ZipInfo normalizes backslashes on Windows and truncates NULs.
                name = info.orig_filename
                require(bool(name) and not name.startswith("/") and "\\" not in name
                        and "\x00" not in name and ":" not in name and all(p not in ("", ".", "..")
                                                  for p in name.rstrip("/").split("/")),
                        f"macOS ZIP unsafe path: {name!r}")
                # This canonical Godot bundle consists of regular files/directories.
                # Preserve neither symlinks (including implicit-parent redirects) nor
                # special files in the distributable archive. A future framework with
                # legitimate symlinks needs an explicit, separately verified contract.
                mode = info.external_attr >> 16
                require(stat.S_ISDIR(mode) if info.is_dir() else stat.S_ISREG(mode),
                        f"macOS ZIP entry type/name mismatch or special file: {name!r}")
                parts = name.rstrip("/").split("/")
                for depth in range(1, len(parts)):
                    parent = entries.get("/".join(parts[:depth]).casefold())
                    require(parent is None or (parent.is_dir()
                            and stat.S_ISDIR(parent.external_attr >> 16)),
                            f"macOS ZIP parent is not a directory: {name!r}")
            plists = [n for n in names if n.endswith(".app/Contents/Info.plist")
                      and len(n.split("/")) == 3]
            require(len(plists) == 1, "macOS needs exactly one top-level app Info.plist")
            plist = archive.getinfo(plists[0])
            require(plist.file_size <= 1024 * 1024, "macOS Info.plist too large")
            meta = plistlib.loads(archive.read(plist))
            require(isinstance(meta, dict) and meta.get("CFBundleIdentifier") == "org.igor.necromancer"
                    and meta.get("CFBundlePackageType") == "APPL", "macOS wrong app identity/type")
            executable = meta.get("CFBundleExecutable")
            require(isinstance(executable, str) and bool(executable)
                    and executable not in (".", "..") and not any(c in executable for c in "/\\:"),
                    "macOS invalid CFBundleExecutable")
            root = plists[0].removesuffix("Info.plist")
            binary = archive.getinfo(root + "MacOS/" + executable)
            pack = archive.getinfo(root + "Resources/" + executable + ".pck")
            for info in (plist, binary, pack):
                require(stat.S_ISREG(info.external_attr >> 16),
                        f"macOS required member is not a regular file: {info.filename}")
            require(bool((binary.external_attr >> 16) & 0o111), "macOS executable lacks execute bit")
            with archive.open(pack) as stream:
                check_pack(stream)
            with archive.open(binary) as stream:
                header = stream.read(8)
                require(len(header) == 8, "macOS truncated Universal header")
                magic, count = struct.unpack(">II", header)
                stride = {0xCAFEBABE: 20, 0xCAFEBABF: 32}.get(magic, 0)
                require(bool(stride) and 0 < count <= 8, "macOS needs a Universal 2 Mach-O")
                table = stream.read(stride * count)
                require(len(table) == stride * count, "macOS truncated architecture table")
                slices = []
                for index in range(count):
                    row = table[index * stride:(index + 1) * stride]
                    cpu = struct.unpack(">I", row[:4])[0]
                    offset, length = struct.unpack(">II" if stride == 20 else ">QQ",
                                                   row[8:16] if stride == 20 else row[8:24])
                    require(length >= 32 and offset >= 8 + count * stride
                            and offset + length <= binary.file_size,
                            "macOS Mach-O slice outside executable")
                    slices.append((offset, length, cpu))
                require({0x01000007, 0x0100000C}.issubset({s[2] for s in slices}),
                        "macOS Universal 2 needs Intel x86_64 and Apple Silicon arm64")
                previous_end = 8 + count * stride
                for offset, length, cpu in sorted(slices):
                    require(offset >= previous_end, "macOS overlapping Mach-O slices")
                    previous_end = offset + length
                    stream.seek(offset)
                    require(stream.read(8) == struct.pack("<II", 0xFEEDFACF, cpu),
                            "macOS invalid 64-bit Mach-O slice header")
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile,
            plistlib.InvalidFileException) as error:
        raise SystemExit(f"platform preflight: {error}") from error


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


def promote_no_replace(stage: Path, destination: Path) -> None:
    """Same-filesystem rename, refusing occupied destinations even after an earlier check.

    Native filesystem support is required; never fall back to replacing POSIX rename.
    Not a power-loss durability guarantee or protection against parent replacement.
    """
    if sys.platform == "win32":
        os.rename(stage, destination)  # Windows refuses an existing destination.
        return
    if sys.platform not in ("linux", "darwin"):
        raise OSError(errno.ENOTSUP, "no no-replace directory promotion on this platform")
    libc = ctypes.CDLL(None, use_errno=True)
    symbol = "renameat2" if sys.platform == "linux" else "renamex_np"
    try:
        rename = getattr(libc, symbol)
    except AttributeError:
        raise OSError(errno.ENOTSUP, f"{symbol} unavailable; staging retained") from None
    rename.restype = ctypes.c_int
    if sys.platform == "linux":
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        # Linux AT_FDCWD=-100, RENAME_NOREPLACE=1 (uapi fcntl.h/fs.h).
        result = rename(-100, os.fsencode(stage), -100, os.fsencode(destination), 1)
    else:
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        # Apple xnu bsd/sys/stdio.h: RENAME_EXCL=4.
        result = rename(os.fsencode(stage), os.fsencode(destination), 4)
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, f"{symbol}: {os.strerror(code)}", str(destination))


def package_into(out_dir: Path) -> None:
    """Populate and validate an already-created private staging directory."""
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
            bad_member = z.testzip()
            if bad_member is not None:
                raise ValueError(f"invalid ZIP: {name}: {bad_member}")
    with tarfile.open(out_dir / f"{PREFIX}-Linux.tar.gz") as t:
        exe = t.getmember("Necromancer/Necromancer.x86_64")
        if not exe.mode & 0o111:
            raise ValueError("у Linux-файла нет бита запуска")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version")
    parser.add_argument("--skip-live-metrics", action="store_true",
                        help="без сети: сверить только код сервера, рабочий — позже вручную")
    args = parser.parse_args()
    reserved = {"CON", "PRN", "AUX", "NUL"} | {f"{prefix}{i}" for prefix in ("COM", "LPT") for i in range(1, 10)}
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.version)
            or args.version.endswith(".") or args.version.split(".")[0].upper() in reserved):
        raise SystemExit("версия должна быть одним безопасным компонентом пути")
    out_dir = DIST / "github-release" / args.version
    if os.path.lexists(out_dir):
        raise SystemExit(f"уже есть: {out_dir} — выберите другую версию или уберите папку сами")
    check_windows_pair(DIST)
    check_platform_packages(DIST)
    metrics_preflight.check(args.version, live=not args.skip_live_metrics, repo=REPO)
    out_dir.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{args.version}.staging-", dir=out_dir.parent))
    try:
        package_into(stage)
        promote_no_replace(stage, out_dir)
    except BaseException:
        if os.path.lexists(stage):
            print(f"Выпуск не завершён; staging сохранён: {stage}", file=sys.stderr)
        else:
            print(f"Исход переноса требует проверки: staging {stage}; итог {out_dir}", file=sys.stderr)
        raise
    print(f"готово: {out_dir}")


if __name__ == "__main__":
    main()
