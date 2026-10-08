#!/usr/bin/env python3
"""Steam-сборка Windows + Linux release-шаблонами Godot 4.7.2 (пресеты «Steam Windows», «Steam Linux»).

Шаблоны достаются из уже скачанного официального архива (.tpz, SHA512 сверен 08.10) в песочницу
APPDATA — в %APPDATA% владельца ничего не ставится (как tools/build_linux.py). Скачивания нет.
Результат — депо SteamPipe (tools/steam/*.vdf):
    dist/steam/windows/Necromancer.exe      pck вшит, иконка и свойства файла из пресета
    dist/steam/linux/Necromancer.x86_64     pck вшит
    dist/steam/<os>/licenses/               лицензии (список — tools/release/make_github_release.py)
    dist/steam/SHA256SUMS.txt, dist/steam/BUILD.md
Прежняя dist/steam не удаляется, а переименовывается в dist/steam.prev-<время>.

Проверки после экспорта: размер и вшитый pck, состав pck по журналу экспорта (исключённое не
попало), свойства Windows-exe (pefile, если установлен), проба exe `-- --dev build_probe=1`
(версия и фичи steam/ship изнутри сборки; `--script` release-шаблон игнорирует) и запуск игры
`--headless --quit-after 300` на своём save — в песочнице APPDATA и с NECRO_NO_METRICS=1.
Linux-файл на Windows не запускается: только размер, хвост pck и состав.
Свойства exe (иконка, версия) Godot 4.7.2 пишет сам, без rcedit (проверено pefile 08.10.2026).

Steam-сеть «Схватки» (GodotSteam, docs/dev/ONLINE.md «Реализация Steam Networking»): после проб
tools/steam/stage_godotsteam.py кладёт рядом с бинарём каждой ОС папку godotsteam/ и
steam_api64.dll / libsteam_api.so, лицензию GodotSteam — в licenses/. Плагин: --godotsteam,
иначе NECRO_GODOTSTEAM_PLUGIN, иначе C:/AI/necro/export-templates/godotsteam-4.23.1. Нет плагина
(или --no-godotsteam) — сборка идёт без Steam-сети с предупреждением: игра без GodotSteam
работает (SteamNet.boot → «По сети» через ретранслятор), пробы выше идут именно так. Сборку с
godotsteam/ скрипт не запускает: это вызвало бы steamInitEx под аккаунтом владельца.

    python -X utf8 tools/build_steam.py [--tpz …] [--skip-import] [--godotsteam DIR | --no-godotsteam]
"""
import argparse
import fnmatch
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools" / "release"))
from make_github_release import LICENSE_NAMES, LICENSES  # noqa: E402

GODOT = Path("C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe")
TPZ = Path("C:/AI/necro/export-templates/4.7.2/Godot_v4.7.2-stable_export_templates.tpz")
TEMPLATE_DIR = "Godot/export_templates/4.7.2.stable"  # относительно APPDATA
NEED = ("templates/windows_release_x86_64.exe", "templates/windows_debug_x86_64.exe",
        "templates/linux_release.x86_64", "templates/linux_debug.x86_64", "templates/version.txt")
WIN_PRESET, LINUX_PRESET = "Steam Windows", "Steam Linux"
# GodotSteam 4.23.1 (скачан по слову Игоря 08.10, D-1008-N7); папка, где лежит addons/godotsteam.
GODOTSTEAM = Path(os.environ.get("NECRO_GODOTSTEAM_PLUGIN")
                  or "C:/AI/necro/export-templates/godotsteam-4.23.1")
STAGE_GODOTSTEAM = REPO / "tools" / "steam" / "stage_godotsteam.py"
STEAM_API = {"windows": "steam_api64.dll", "linux": "libsteam_api.so"}
# Что не должно попасть в pck (аудит build_steam B5 + оснастка): исходные пути и имена
# импортированных текстур (.godot/imported/<имя>-<хэш>); имена сверены — в проекте уникальны.
# Сверх этого каждый путь pck сверяется с exclude_filter самого пресета (leaked_files).
FORBIDDEN = re.compile(
    r"res://(tests/|scripts/net_spike/|scripts/dev/corr_play|assets/img/story/|assets/img/icons/"
    r"|assets/img/(bg|bg2|cover)\.png|assets/parts/|assets/levels/|assets/anim-lab/|override\.cfg)"
    r"|/\.godot/imported/(story_\w+\.jpg|bg2?\.png|cover\.png|level\d_mask\.png"
    r"|item_(auditor_noose|bounty_hunter|coffee_pass|do_not_disturb|double_stamp|echo_clause"
    r"|elite_hr|fireproof_safe|lost_found|piecework_meter|precise_ruler|punch_knuckles"
    r"|quarter_bonus|quarterly_report|ring_lightning|roll_call|spare_pen)\.png)-")
SYSTEM32 = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32"
# Ошибки, которые в пробе запуска считаются провалом (предупреждения движка — нет).
BAD_LOG = re.compile(r"SCRIPT ERROR|Parse Error|ERROR: .*(Failed|Cannot|Can't|not found)", re.I)


def fail(msg: str) -> None:
    sys.exit(f"[FAIL] {msg}")


def owner_game_running() -> bool:
    """Как build_exe.bat: открытый Necromancer.exe — не трогаем dist (25.09 сборка снесла pck)."""
    out = subprocess.run([str(SYSTEM32 / "tasklist.exe"), "/FI", "IMAGENAME eq Necromancer.exe"],
                         capture_output=True, text=True, errors="replace").stdout
    return "necromancer.exe" in out.lower()


def run(cmd: list, env: dict, log: Path, timeout: int = 1800) -> int:
    with open(log, "w", encoding="utf-8", errors="replace") as f:
        try:   # по таймауту subprocess.run сам убивает свой процесс (только его PID)
            proc = subprocess.run([str(c) for c in cmd], env=env, stdout=f,
                                  stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired:
            fail(f"не завершился за {timeout} с: {Path(str(cmd[0])).name}, журнал {log}")
    return proc.returncode


def release_version() -> str:
    text = (REPO / "godot/scripts/common/release_info.gd").read_text(encoding="utf-8")
    found = re.findall(r'(?m)^const VERSION := "([^"]+)"', text)
    if len(found) != 1:
        fail("не найдено const VERSION в release_info.gd")
    return found[0]


def numeric_version(version: str) -> str:
    """0.2.2-alpha → 0.2.2.0 (формат VERSIONINFO Windows: четыре числа)."""
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", version)
    if not m:
        fail(f"версия {version!r} не начинается с X.Y.Z")
    return ".".join(m.groups()) + ".0"


def preset_options(name: str) -> dict:
    """Параметры пресета (секция и её .options) из export_presets.cfg."""
    text = (REPO / "godot/export_presets.cfg").read_text(encoding="utf-8")
    sections = re.split(r"(?m)^\[(preset\.\d+(?:\.options)?)\]\s*$", text)
    found, opts = None, {}
    for i in range(1, len(sections), 2):
        head, body = sections[i], sections[i + 1]
        kv = dict(re.findall(r'(?m)^([\w/]+)="?(.*?)"?$', body))
        if not head.endswith(".options") and kv.get("name") == name:
            found = head
            opts.update(kv)
        elif found and head == found + ".options":
            opts.update(kv)
    if not found:
        fail(f"нет пресета {name!r} в export_presets.cfg")
    return opts


def leaked_files(packed: list, exclude_filter: str) -> list:
    """Пути pck, которые не должны там быть: по FORBIDDEN и по exclude_filter пресета."""
    patterns = [x.strip() for x in exclude_filter.split(",") if x.strip()]
    out = set()
    for path in packed:
        rel = re.sub(r"[.](import|remap)$", "", path.removeprefix("res://"))
        rel = re.sub(r"[.]gdc$", ".gd", rel)
        if FORBIDDEN.search(path) or any(fnmatch.fnmatchcase(rel, pat) for pat in patterns):
            out.add(path)
    return sorted(out)


def pe_info(exe: Path) -> dict:
    try:
        import pefile
    except ImportError:
        return {"pefile": "нет модуля pefile — свойства exe не прочитаны"}
    pe = pefile.PE(str(exe), fast_load=False)
    info = {}
    for fi in getattr(pe, "FileInfo", []) or []:
        for entry in fi:
            for st in getattr(entry, "StringTable", []) or []:
                for k, v in st.entries.items():
                    info[k.decode(errors="replace")] = v.decode("utf-8", errors="replace")
    sizes = []
    resources = pe.DIRECTORY_ENTRY_RESOURCE.entries if hasattr(pe, "DIRECTORY_ENTRY_RESOURCE") else []
    for res in resources:
        if res.id == pefile.RESOURCE_TYPE["RT_GROUP_ICON"]:
            for name_entry in res.directory.entries:
                for lang in name_entry.directory.entries:
                    data = pe.get_data(lang.data.struct.OffsetToData, lang.data.struct.Size)
                    count = int.from_bytes(data[4:6], "little")
                    for k in range(count):
                        w = data[6 + 14 * k] or 256
                        sizes.append(w)
    info["icon_sizes"] = ",".join(str(s) for s in sorted(set(sizes)))
    pe.close()
    return info


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def copy_licenses(dest: Path) -> None:
    lic = dest / "licenses"
    lic.mkdir(parents=True, exist_ok=True)
    for f in LICENSES:
        if not f.is_file():
            fail(f"нет файла лицензии: {f}")
        shutil.copy2(f, lic / LICENSE_NAMES.get(f, f.name))


def stage_godotsteam(plugin, targets: dict, logs: Path) -> str:
    """GodotSteam рядом с бинарём каждой ОС ({"windows": папка, …}); итог — строка для BUILD.md.

    Нет плагина — предупреждение и сборка без Steam-сети; плагин есть, но раскладка не удалась —
    провал (молча выпускать без сети, когда её ждут, хуже, чем остановиться)."""
    exts = sorted(plugin.rglob("*.gdextension")) if plugin is not None and plugin.is_dir() else []
    if not exts:
        why = "отключено --no-godotsteam" if plugin is None else f"нет плагина в {plugin}"
        print(f"[WARN] GodotSteam: {why} — Steam-сборка без Steam-сети («По сети» через ретранслятор)")
        return f"без GodotSteam ({why}): Steam-сеть «Схватки» в этой сборке выключена"
    licenses = sorted(exts[0].parent.glob("[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*"))
    if not licenses:
        fail(f"GodotSteam: нет файла лицензии рядом с {exts[0]}")
    for os_name, dest in targets.items():
        log = logs / f"stage-godotsteam-{os_name}.log"
        code = run([sys.executable, "-X", "utf8", STAGE_GODOTSTEAM, "--plugin", plugin,
                    "--os", os_name, "--dist", dest], dict(os.environ), log, timeout=300)
        if code:
            fail(f"раскладка GodotSteam {os_name} (код {code}), журнал {log}")
        need = [dest / "godotsteam" / "godotsteam.gdextension", dest / STEAM_API[os_name]]
        missing = [p for p in need if not p.is_file()]
        if missing or not any((dest / "godotsteam").glob("libgodotsteam*")):
            fail(f"GodotSteam {os_name}: не хватает {missing or 'libgodotsteam*'}, журнал {log}")
        if any(dest.rglob("steam_appid.txt")):
            fail(f"GodotSteam {os_name}: steam_appid.txt в поставку не идёт — {dest}")
        (dest / "licenses").mkdir(parents=True, exist_ok=True)
        shutil.copy2(licenses[0], dest / "licenses" / "GODOTSTEAM_LICENSE.md")
    print(f"[build] GodotSteam разложен ({', '.join(targets)}) из {plugin}")
    return (f"GodotSteam из {plugin}: godotsteam/ и {', '.join(STEAM_API[o] for o in targets)} рядом "
            "с бинарём; загрузка расширения из этой сборки скриптом не проверялась (нужен клиент Steam)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tpz", type=Path, default=TPZ, help="официальный архив шаблонов 4.7.2")
    ap.add_argument("--godot", type=Path, default=GODOT)
    ap.add_argument("--skip-import", action="store_true", help="импорт уже сделан в этой папке")
    ap.add_argument("--godotsteam", type=Path, default=GODOTSTEAM,
                    help="распакованный плагин GodotSteam (папка с addons/godotsteam)")
    ap.add_argument("--no-godotsteam", action="store_true", help="собрать без Steam-сети")
    a = ap.parse_args()

    godot, tpz = a.godot.resolve(), a.tpz.resolve()
    for p, what in ((godot, "движка"), (tpz, "архива шаблонов")):
        if not p.is_file():
            fail(f"нет {what}: {p}")
    if owner_game_running():
        fail("Necromancer.exe запущен — закройте игру, dist не трогаю")

    version = release_version()
    numeric = numeric_version(version)
    win_opts = preset_options(WIN_PRESET)
    linux_opts = preset_options(LINUX_PRESET)
    for key in ("application/file_version", "application/product_version"):
        if win_opts.get(key) != numeric:
            fail(f"{WIN_PRESET}: {key}={win_opts.get(key)!r}, а ReleaseInfo.VERSION={version} → {numeric}")
    for name, opts in ((WIN_PRESET, win_opts), (LINUX_PRESET, linux_opts)):
        if "steam" not in opts.get("custom_features", "").split(","):
            fail(f"{name}: нет фичи steam в custom_features")
        if opts.get("binary_format/embed_pck") != "true":
            fail(f"{name}: pck не вшит (binary_format/embed_pck)")

    dist = REPO / "dist" / "steam"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    if dist.exists():
        prev = dist.with_name(f"steam.prev-{stamp}")
        dist.rename(prev)
        print(f"[build] прежняя сборка отложена: {prev}")
    win_exe = dist / "windows" / "Necromancer.exe"
    linux_bin = dist / "linux" / "Necromancer.x86_64"
    logs = dist / "logs"
    for d in (win_exe.parent, linux_bin.parent, logs):
        d.mkdir(parents=True, exist_ok=True)

    sandbox = Path(tempfile.mkdtemp(prefix="necro-steam-"))
    appdata = sandbox / "appdata"
    tdir = appdata / TEMPLATE_DIR
    tdir.mkdir(parents=True)
    with zipfile.ZipFile(tpz) as z:
        for name in NEED:
            (tdir / Path(name).name).write_bytes(z.read(name))
    env = {**os.environ, "APPDATA": str(appdata), "NECRO_NO_DEV_BRIDGE": "1",
           "NECRO_NO_METRICS": "1"}
    print(f"[build] версия {version} → {numeric}; песочница {sandbox}")

    base = [godot, "--headless", "--path", REPO / "godot", "--fixed-fps", "60"]
    if not a.skip_import:
        print("[build] import")
        if run([*base, "--import", "--", "--mute"], env, logs / "import.log"):
            fail(f"импорт, журнал {logs / 'import.log'}")
    for preset, out, log in ((WIN_PRESET, win_exe, "export-windows.log"),
                             (LINUX_PRESET, linux_bin, "export-linux.log")):
        print(f"[build] export-release {preset}")
        code = run([*base, "--export-release", preset, out, "--", "--mute"], env, logs / log)
        if code or not out.is_file():
            fail(f"экспорт {preset} (код {code}), журнал {logs / log}")
        if out.stat().st_size < 50 * 2**20:
            fail(f"подозрительно мал: {out} ({out.stat().st_size} байт)")
        if out.read_bytes()[-4:] != b"GDPC":
            fail(f"в конце {out.name} нет вшитого pck (GDPC)")

        packed = re.findall(r"savepack\S* \| [^:]*: (res://\S+?)(?:\x1b|\s|$)",
                            (logs / log).read_text(encoding="utf-8", errors="replace"))
        leaked = leaked_files(packed, preset_options(preset).get("exclude_filter", ""))
        if len(packed) < 1000 or leaked:
            fail(f"{preset}: в pck {len(packed)} файлов, лишние: {leaked[:5]} — журнал {logs / log}")
        print(f"[build] {preset}: в pck {len(packed)} файлов, исключённое не попало")

    # Проба 1: версия и фичи изнутри сборки (`--script` release-шаблон игнорирует — через игру).
    probe_log = logs / "probe-build.log"
    code = run([win_exe, "--headless", "--", "--mute", "--dev", "build_probe=1"], env, probe_log,
               timeout=120)
    probe = probe_log.read_text(encoding="utf-8", errors="replace")
    want = f"PROBE version={version} steam=true is_steam=true ship=true debug=false"
    if code or want not in probe:
        fail(f"проба сборки (код {code}): ждали «{want}», журнал {probe_log}")

    # Проба 2: запуск игры как у игрока, но на своём сохранении и в песочнице, 300 кадров.
    game_log = logs / "probe-game.log"
    code = run([win_exe, "--headless", "--quit-after", "300", "--", "--mute", "--dev",
                "save=user://steam_probe.cfg"], env, game_log, timeout=300)
    game = game_log.read_text(encoding="utf-8", errors="replace")
    bad = [ln for ln in game.splitlines() if BAD_LOG.search(ln)]
    if code or bad:
        fail(f"запуск игры (код {code}), ошибок {len(bad)}: {bad[:3]} — журнал {game_log}")

    # После проб: они проверили запуск без GodotSteam (так игра обязана работать всегда).
    steam_note = stage_godotsteam(None if a.no_godotsteam else a.godotsteam.resolve(),
                                  {"windows": win_exe.parent, "linux": linux_bin.parent}, logs)
    for d in (win_exe.parent, linux_bin.parent):
        copy_licenses(d)
    pe = pe_info(win_exe)
    files = sorted(p for p in dist.rglob("*") if p.is_file() and p.parent != logs)
    sums = [f"{sha256(p)}  {p.relative_to(dist).as_posix()}" for p in files]
    (dist / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n", encoding="utf-8")

    probe_lines = [ln for ln in probe.splitlines() if ln.startswith("PROBE")]
    rows = "\n".join(f"| {p.relative_to(dist).as_posix()} | {p.stat().st_size:,} | "
                     f"{p.stat().st_size / 2**20:.1f} МБ |".replace(",", " ")
                     for p in (win_exe, linux_bin))
    pe_rows = "\n".join(f"- {k}: {v}" for k, v in sorted(pe.items()))
    commit = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True).stdout.strip()
    (dist / "BUILD.md").write_text(f"""# Steam-сборка {version}

Собрано {time.strftime('%d.%m.%Y %H:%M %z')} скриптом tools/build_steam.py; коммит {commit}{' (+ незакоммиченные правки)' if dirty else ''}.
Шаблоны: {tpz.name} (release-шаблоны 4.7.2), фичи пресетов: ship, steam.

| Файл | Байт | Размер |
|---|---|---|
{rows}

Свойства Windows-exe (pefile):
{pe_rows}

Проба сборки (`-- --dev build_probe=1`):
```
{chr(10).join(probe_lines)}
```
Запуск игры headless 300 кадров на user://steam_probe.cfg: код 0, строк с ошибками — 0
(журнал logs/probe-game.log). Linux-файл на этой машине не запускался.
Обе пробы — без GodotSteam рядом с exe. Steam-сеть: {steam_note}.

Контрольные суммы — SHA256SUMS.txt; журналы — logs/.
""", encoding="utf-8")

    print(f"[OK] {win_exe} {win_exe.stat().st_size / 2**20:.1f} МБ")
    print(f"[OK] {linux_bin} {linux_bin.stat().st_size / 2**20:.1f} МБ")
    for ln in probe_lines:
        print(f"[OK] {ln}")
    print(f"[{'OK' if steam_note.startswith('GodotSteam') else 'WARN'}] Steam-сеть: {steam_note}")
    for k, v in sorted(pe.items()):
        print(f"     {k}: {v}")
    print(f"[OK] {dist / 'BUILD.md'}; песочница (не удаляется): {sandbox}")


if __name__ == "__main__":
    main()
