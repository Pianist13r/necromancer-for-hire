#!/usr/bin/env python3
# Сборка Linux-версии (x86_64, pck вшит в один файл) с Windows-хоста: шаблон linux_release.x86_64
# достаётся из уже скачанного официального архива шаблонов (.tpz) в песочницу APPDATA, затем
# --import и --export-release пресета Linux. Только stdlib, скачивания нет.
# Песочница и логи НЕ удаляются — диагностический след (как tools/build_macos.py).
#
#   python -X utf8 tools/build_linux.py --tpz C:/AI/necro/export-templates/4.7.2/Godot_v4.7.2-stable_export_templates.tpz

import argparse
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

TEMPLATE_DIR = "Godot/export_templates/4.7.2.stable"  # относительно APPDATA
NEED = ("templates/linux_release.x86_64", "templates/linux_debug.x86_64", "templates/version.txt")


def run_godot(godot, args, env, log):
    with open(log, "w", encoding="utf-8", errors="replace") as f:
        proc = subprocess.run([str(godot), *args], env=env, stdout=f, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        sys.exit(f"[FAIL] код {proc.returncode}, журнал: {log}")


def main():
    repo = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description="Экспорт Linux x86_64 одним файлом; шаблон и APPDATA — в песочнице")
    ap.add_argument("--tpz", required=True, type=Path, help="официальный архив шаблонов экспорта 4.7.2 (.tpz)")
    ap.add_argument("--godot", type=Path,
                    default=Path("C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe"))
    ap.add_argument("--out", type=Path, default=None,
                    help="итоговый файл (по умолчанию <репо>/dist/linux/Necromancer.x86_64)")
    a = ap.parse_args()

    godot, tpz = a.godot.resolve(), a.tpz.resolve()
    out = (a.out or repo / "dist" / "linux" / "Necromancer.x86_64").resolve()
    for p, what in ((godot, "движка"), (tpz, "архива шаблонов")):
        if not p.is_file():
            sys.exit(f"[FAIL] нет {what}: {p}")
    if out.exists():
        sys.exit(f"[FAIL] отказ перезаписывать существующий файл: {out}")
    out.parent.mkdir(parents=True, exist_ok=True)

    sandbox = Path(tempfile.mkdtemp(prefix="necro-linux-"))
    tdir = sandbox / "appdata" / TEMPLATE_DIR
    tdir.mkdir(parents=True)
    with zipfile.ZipFile(tpz) as z:
        for name in NEED:
            (tdir / Path(name).name).write_bytes(z.read(name))
    env = {**os.environ, "APPDATA": str(sandbox / "appdata"), "NECRO_NO_DEV_BRIDGE": "1"}

    base = ["--headless", "--path", str(repo / "godot"), "--fixed-fps", "60"]
    run_godot(godot, [*base, "--import", "--", "--mute"], env, out.with_suffix(".import.log"))
    run_godot(godot, [*base, "--export-release", "Linux", str(out), "--", "--mute"], env,
              out.with_suffix(".export.log"))
    if not out.is_file() or out.stat().st_size < 50 * 2**20:
        sys.exit(f"[FAIL] нет результата или он подозрительно мал: {out}")
    tail = out.read_bytes()[-4:]
    print(f"[OK] собрано: {out} ({out.stat().st_size / 2**20:.1f} МБ, хвост pck: {tail!r})")
    print(f"Песочница (не удаляется): {sandbox}")


if __name__ == "__main__":
    main()
