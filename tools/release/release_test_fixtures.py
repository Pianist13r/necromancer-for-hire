"""Small structural fixtures, never executable games or runtime evidence."""
import plistlib
from pathlib import Path
import struct
import zipfile


def pack_bytes():
    return b"GDPC" + struct.pack("<5I", 4, 4, 7, 2, 2) + bytes(80)


def linux_bytes():
    elf = bytearray(64)
    elf[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", elf, 16, 2, 62, 1)
    pck = pack_bytes()
    return bytes(elf) + pck + struct.pack("<Q", len(pck)) + b"GDPC"


def mac_members():
    root = "Necromancer.app/Contents/"
    binary = bytearray(112)
    struct.pack_into(">II", binary, 0, 0xCAFEBABE, 2)
    for index, cpu in enumerate((0x01000007, 0x0100000C)):
        offset = 48 + index * 32
        struct.pack_into(">5I", binary, 8 + index * 20, cpu, 0, offset, 32, 0)
        struct.pack_into("<II", binary, offset, 0xFEEDFACF, cpu)
    return {
        root + "Info.plist": (plistlib.dumps({
            "CFBundleIdentifier": "org.igor.necromancer",
            "CFBundleExecutable": "Necromancer",
            "CFBundlePackageType": "APPL",
        }), 0o100644),
        root + "MacOS/Necromancer": (bytes(binary), 0o100755),
        root + "Resources/Necromancer.pck": (pack_bytes(), 0o100644),
    }


def write_mac(path, members=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        for name, (data, mode) in (mac_members() if members is None else members).items():
            info = zipfile.ZipInfo(name)
            info.filename = name  # Preserve deliberately unsafe test names on Windows.
            info.create_system = 3
            info.external_attr = mode << 16
            archive.writestr(info, data)


def write_platform_inputs(dist: Path):
    linux = dist / "linux/Necromancer.x86_64"
    linux.parent.mkdir(parents=True, exist_ok=True)
    linux.write_bytes(linux_bytes())
    write_mac(dist / "macOS/Necromancer-macOS.zip")
