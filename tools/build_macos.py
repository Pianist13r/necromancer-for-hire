#!/usr/bin/env python3
# Сборка macOS-версии «Некроманта» с Windows-хоста: официальный шаблон macos.zip
# кладётся в песочницу APPDATA, затем --import и --export-release пресета macOS.
# Только stdlib. Скачивания нет: --template даёт уже скачанный официальный macos.zip.
# Песочница и логи НЕ удаляются — остаются как диагностический след.

import argparse
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

TEMPLATE_DIR = "Godot/export_templates/4.7.2.stable"  # относительно APPDATA


def run_godot(godot, args, env, log):
    with open(log, "w", encoding="utf-8", errors="replace") as f:
        proc = subprocess.run([str(godot), *args], env=env, stdout=f,
                              stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        sys.exit(f"[FAIL] код {proc.returncode}, журнал: {log}")


def verify(out):
    # Структурная проверка результата: целостность zip, Info.plist, .pck,
    # unix-биты запуска у бинарника в Contents/MacOS.
    with zipfile.ZipFile(out) as z:
        corrupt = z.testzip()
        names = z.namelist()
        infos = z.infolist()
        plist_names = [n for n in names if n.endswith(".app/Contents/Info.plist")]
        meta = plistlib.loads(z.read(plist_names[0])) if len(plist_names) == 1 else {}
        binary = (plist_names[0].removesuffix("Info.plist") + "MacOS/" +
                  meta.get("CFBundleExecutable", "")) if meta else ""
        architectures = set()
        if binary in names:
            with z.open(binary) as stream:
                magic, count = struct.unpack(">II", stream.read(8))
                stride = 20 if magic == 0xCAFEBABE else 32 if magic == 0xCAFEBABF else 0
                if stride and 0 < count <= 8:
                    for _ in range(count):
                        architectures.add(struct.unpack(">I", stream.read(stride)[:4])[0])
    plist = meta.get("CFBundleIdentifier") == "org.igor.necromancer"
    pck = any(n.endswith(".pck") for n in names)
    exe = [i for i in infos if "/Contents/MacOS/" in i.filename and not i.is_dir()]
    perms = bool(exe) and all((i.external_attr >> 16) & 0o111 for i in exe)
    checks = [
        ("целостность zip (testzip)", corrupt is None),
        ("Contents/Info.plist", plist),
        ("Universal 2: Intel x86_64 и Apple Silicon arm64",
         {0x01000007, 0x0100000C}.issubset(architectures)),
        ("файл .pck внутри", pck),
        ("бинарнику в Contents/MacOS заданы биты 0o111", perms),
    ]
    for label, ok in checks:
        print(f"  [{'OK' if ok else 'FAIL'}] {label}")
    if not all(ok for _, ok in checks):
        sys.exit(f"[FAIL] структурная проверка не прошла: {out}")


def main():
    repo = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(
        description="Экспорт macOS (universal, ad-hoc) в zip; APPDATA и шаблон — в одноразовой песочнице")
    ap.add_argument("--template", required=True, type=Path,
                    help="абсолютный путь к официальному macos.zip (шаблоны экспорта 4.7.2)")
    ap.add_argument("--godot", type=Path,
                    default=Path("C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe"))
    ap.add_argument("--out", type=Path, default=None,
                    help="итоговый zip (по умолчанию <репо>/dist/macOS/Necromancer-macOS.zip)")
    a = ap.parse_args()

    godot = a.godot.resolve()
    if not a.template.is_absolute():
        sys.exit(f"[FAIL] --template требует абсолютный путь: {a.template}")
    template = a.template.resolve()
    out = (a.out or repo / "dist" / "macOS" / "Necromancer-macOS.zip").resolve()
    if not godot.is_file():
        sys.exit(f"[FAIL] нет движка: {godot}")
    if not template.is_file():
        sys.exit(f"[FAIL] нет шаблона: {template}")
    if out.exists():
        sys.exit(f"[FAIL] отказ перезаписывать существующий файл: {out}")
    out.parent.mkdir(parents=True, exist_ok=True)

    sandbox = Path(tempfile.mkdtemp(prefix="necro-macos-"))
    appdata = sandbox / "appdata"
    (appdata / TEMPLATE_DIR).mkdir(parents=True)
    shutil.copy2(template, appdata / TEMPLATE_DIR / "macos.zip")
    env = {**os.environ, "APPDATA": str(appdata)}

    base = ["--headless", "--path", str(repo / "godot"), "--fixed-fps", "60"]
    run_godot(godot, [*base, "--import", "--", "--mute"], env,
              out.with_suffix(".import.log"))
    run_godot(godot, [*base, "--export-release", "macOS", str(out), "--", "--mute"],
              env, out.with_suffix(".export.log"))

    print(f"[OK] собрано: {out}")
    verify(out)
    shutil.copy2(repo / "tools/release/README-macOS.txt", out.parent / "README-macOS.txt")
    print(f"Песочница (не удаляется): {sandbox}")
    print("ВНИМАНИЕ: сборка не запускалась на настоящем macOS — проверена только структура zip.")


if __name__ == "__main__":
    main()
