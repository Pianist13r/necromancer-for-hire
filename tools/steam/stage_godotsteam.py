#!/usr/bin/env python3
"""Раскладка GodotSteam рядом с exe Steam-сборки (ветка slow/steam-net, D-1008-N3).

Расширение в проект не кладётся: SteamNet грузит его на ходу из `<папка exe>/godotsteam/
godotsteam.gdextension` (или NECRO_STEAM_EXT). Этот скрипт берёт распакованный плагин
GodotSteam (godotsteam-4.23.1-gdextension-plugin-4.4.zip, codeberg.org/godotsteam/godotsteam)
и для одной ОС собирает папку `godotsteam/` с библиотекой GodotSteam и `.gdextension`, у
которого пути библиотек переписаны относительно самого файла, а `steam_api64.dll` /
`libsteam_api.so` кладёт и в неё, и рядом с exe (загрузчик ОС ищет зависимости рядом с exe).
`steam_appid.txt` не копируется никогда (в поставку не идёт — godotsteam.com/tutorials/exporting_shipping/).

    python -X utf8 tools/steam/stage_godotsteam.py --plugin <папка с addons/godotsteam> --os windows --dist dist/steam/windows
    python -X utf8 tools/steam/stage_godotsteam.py --plugin <…> --os linux --dist dist/steam/linux
    python -X utf8 tools/steam/stage_godotsteam.py --plugin <…> --list      # что нашёл, ничего не копирует

Только stdlib, скачивания нет. Имена файлов плагина заранее не зашиты: скрипт читает секции
[libraries] и [dependencies] самого .gdextension (формат Godot 4) и берёт записи, чьи теги
содержат нужную ОС и x86_64 без «debug»/«editor» (release-шаблон). Проверить до сборки.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

OS_TAGS = {"windows": "windows", "linux": "linux"}
API_LIB = {"windows": "steam_api64.dll", "linux": "libsteam_api.so"}


def parse_gdextension(text: str) -> dict:
    """[section] → {key: value} (значение — сырой текст без кавычек/словаря, как в файле)."""
    out, section = {}, None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        m = re.match(r"^\[(.+)\]$", line)
        if m:
            section = m.group(1).strip()
            out.setdefault(section, {})
            continue
        if section is None or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[section][key.strip()] = value.strip()
    return out


def pick(entries: dict, os_name: str) -> list:
    """Ключи вида windows.x86_64 / windows.template_release.x86_64 — без debug и editor."""
    want = OS_TAGS[os_name]
    found = []
    for key in entries:
        tags = key.split(".")
        if want in tags and "x86_64" in tags and "debug" not in tags and "editor" not in tags \
                and "template_debug" not in tags:
            found.append(key)
    return found


def plain_key(key: str) -> str:
    """windows.release.x86_64 → windows.x86_64 (тег сборки убран)."""
    return ".".join(t for t in key.split(".") if t not in ("release", "template_release"))


def res_paths(value: str) -> list:
    """Все res://… пути из значения (строка или словарь зависимостей)."""
    return re.findall(r'"(res://[^"]+)"', value)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plugin", required=True, type=Path, help="распакованный плагин (папка, где есть addons/godotsteam)")
    ap.add_argument("--os", choices=sorted(OS_TAGS), default="windows")
    ap.add_argument("--dist", type=Path, help="папка с exe Steam-сборки (туда — godotsteam/ и steam_api)")
    ap.add_argument("--list", action="store_true", help="только показать, что нашлось")
    a = ap.parse_args()

    plugin = a.plugin.resolve()
    ext_files = sorted(plugin.rglob("*.gdextension"))
    if not ext_files:
        sys.exit(f"[FAIL] в {plugin} нет *.gdextension")
    ext = ext_files[0]
    root = ext.parent
    while root != root.parent and not (root / "addons").is_dir():
        root = root.parent
    if not (root / "addons").is_dir():
        root = ext.parent
    cfg = parse_gdextension(ext.read_text(encoding="utf-8"))
    libs = cfg.get("libraries", {})
    deps = cfg.get("dependencies", {})
    lib_keys = pick(libs, a.os)
    dep_keys = pick(deps, a.os)
    print(f"[info] {ext} (res:// = {root})")
    print(f"[info] configuration: {cfg.get('configuration', {})}")
    print(f"[info] libraries {a.os}: {lib_keys or 'НЕТ'}")
    print(f"[info] dependencies {a.os}: {dep_keys or 'нет'}")
    if a.list:
        for k in libs:
            print(f"   lib  {k} = {libs[k]}")
        for k in deps:
            print(f"   dep  {k} = {deps[k]}")
        return
    if not lib_keys:
        sys.exit(f"[FAIL] нет библиотеки для {a.os} x86_64 release в {ext}")
    if a.dist is None:
        sys.exit("[FAIL] --dist обязателен без --list")

    dist = a.dist.resolve()
    out = dist / "godotsteam"
    out.mkdir(parents=True, exist_ok=True)

    def res_to_file(res: str) -> Path:
        p = root / res[len("res://"):]
        if not p.is_file():
            sys.exit(f"[FAIL] нет файла {p} (из {res})")
        return p

    new_libs, copied = {}, []
    for key in lib_keys:
        paths = res_paths(libs[key]) or [libs[key].strip('"')]
        src = res_to_file(paths[0] if paths[0].startswith("res://") else "res://" + paths[0])
        dst = out / src.name
        shutil.copy2(src, dst)
        copied.append(dst)
        new_libs[key] = f'"{src.name}"'   # относительно .gdextension (gdextension_library_loader.cpp 4.7)
        # ключ без release/template_release — чтобы та же папка грузилась и из редактора (у него фичи
        # editor+debug, «release» нет; проба NECRO_STEAM_EXT): Godot берёт ключ, у которого все теги
        # есть у движка, при равенстве — с большим числом тегов
        plain = plain_key(key)
        if plain != key and plain not in libs:
            new_libs[plain] = new_libs[key]
    for key in dep_keys:
        for res in res_paths(deps[key]):
            src = res_to_file(res)
            for dst in (out / src.name, dist / src.name):
                shutil.copy2(src, dst)
                copied.append(dst)
    api_name = API_LIB[a.os]
    api_src = next((p for p in plugin.rglob(api_name)), None)
    if api_src is not None and not (dist / api_name).is_file():
        for dst in (out / api_name, dist / api_name):
            shutil.copy2(api_src, dst)
            copied.append(dst)
    if not (dist / api_name).is_file():
        sys.exit(f"[FAIL] {api_name} не найден в плагине — рядом с exe его нет")

    lines = []
    for section, entries in cfg.items():
        lines.append(f"[{section}]")
        for k, v in entries.items():
            if section == "libraries":
                if k in new_libs:
                    lines.append(f"{k} = {new_libs[k]}")
                    plain = plain_key(k)
                    if plain != k and plain in new_libs and plain not in entries:
                        lines.append(f"{plain} = {new_libs[plain]}")
            elif section == "dependencies":
                if k in dep_keys:
                    names = ", ".join(f'"{Path(r).name}": ""' for r in res_paths(v))
                    lines.append(f"{k} = {{{names}}}")
            else:
                lines.append(f"{k} = {v}")
        lines.append("")
    (out / "godotsteam.gdextension").write_text("\n".join(lines), encoding="utf-8")
    for p in copied:
        print(f"[ok] {p.relative_to(dist)}  {p.stat().st_size:,} байт")
    print(f"[ok] {out / 'godotsteam.gdextension'}")
    print("[note] steam_appid.txt не копируется; AppID берётся из клиента Steam (SteamNet: app_id 0)")


if __name__ == "__main__":
    main()
