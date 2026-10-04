# -*- coding: utf-8 -*-
"""Однофайловая сборка: вшить Necromancer.pck в конец Necromancer.exe.

Зачем: владелец (25.09.2026) хочет exe, который работает сам по себе, без .pck рядом. Шаблоны
экспорта в проекте не ставятся (правило), а движок и без них умеет читать пак, приклеенный к
собственному файлу: при старте Godot 4 открывает свой exe как пак — читает последние 4 байта
(маркер GDPC), перед ними 8 байт с размером пака, отступает на размер и находит заголовок пака.
Заголовок нашего pck (версия 4, флаг PACK_REL_FILEBASE = 2) хранит смещения относительно начала
пака, поэтому патчить его при вшивании не нужно — проверяется здесь и при запуске тестом.

Использование: python -X utf8 tools/embed_pck.py <exe> <pck> <выход.exe>
"""
import pathlib
import struct
import sys

MAGIC = b"GDPC"
PACK_REL_FILEBASE = 2


def main(argv: list) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    exe, pck, out = (pathlib.Path(a) for a in argv)
    head = pck.read_bytes()[:32] if pck.stat().st_size >= 32 else b""
    if head[:4] != MAGIC:
        print("не pck:", pck)
        return 1
    version, _major, _minor, _patch, flags = struct.unpack("<5I", head[4:24])
    if version < 2 or not flags & PACK_REL_FILEBASE:
        print("pck версии %d с флагами %d: смещения абсолютные, вшивать без патча нельзя" % (version, flags))
        return 1
    exe_bytes = exe.read_bytes()
    if exe_bytes[-4:] == MAGIC:
        print("в exe уже вшит пак:", exe)
        return 1
    pck_bytes = pck.read_bytes()
    with out.open("wb") as fh:
        fh.write(exe_bytes)
        fh.write(pck_bytes)
        fh.write(struct.pack("<Q", len(pck_bytes)))
        fh.write(MAGIC)
    print("ok:", out, out.stat().st_size, "байт (exe %d + pck %d + 12)" % (len(exe_bytes), len(pck_bytes)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
