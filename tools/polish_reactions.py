"""Rebuild v6 reactions with one shared canvas; prepare/finish the 4x4 polish sheet.

Usage: python tools/polish_reactions.py build|finish OUTPUT_DIRECTORY
Render idle_v6 into OUTPUT_DIRECTORY first (recipe in ANIM_PIPELINE.md).
"""
import json
import math
import pathlib
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent


def build(out):
    raw = Image.open(out / "idle_v6/sprites/spr_00.png").convert("RGBA")
    frames = []
    # Pivot on the original sole; keep scale/position, including the final idle pose.
    for i in range(5):
        k = math.sin(math.pi * min(1.0, i / 4 * 1.15)) ** 0.6
        frames.append(raw.rotate(-9 * k, Image.Resampling.BICUBIC,
                                 center=(250, 450), translate=(-16 * k, -3 * k)))
    for i in range(8):
        canvas = Image.new("RGBA", raw.size)
        offset = round((1 - i / 7) * 360)
        canvas.alpha_composite(raw, (0, offset))
        canvas.paste((0, 0, 0, 0), (0, 451, 460, 460))
        frames.append(canvas)
    frames += [raw] * 3
    guide = out / "guide"
    guide.mkdir(exist_ok=True)
    sheet = Image.new("RGB", (2048, 2048), (128, 128, 128))
    for i, frame in enumerate(frames):
        frame.save(guide / f"spr_{i:02d}.png")
        cell = Image.new("RGBA", (512, 512), (128, 128, 128, 255))
        cell.alpha_composite(frame, (26, 26))
        sheet.paste(cell.convert("RGB"), ((i % 4) * 512, (i // 4) * 512))
    sheet.save(out / "reactions_sheet.png")


def finish(out):
    import anim_post
    anim_post.FLAT_BG = (128, 128, 128)
    sheet = Image.open(out / "reactions_polished.png").convert("RGB").resize((2048, 2048))
    # Cell 13 is the shared idle anchor. One transform across both clips avoids breathing.
    frames = []
    for i in range(16):
        cell = sheet.crop(((i % 4) * 512, (i // 4) * 512,
                           (i % 4 + 1) * 512, (i // 4 + 1) * 512))
        mask = anim_post.largest_component(anim_post.keyout(cell))
        rgba = np.array(cell.convert("RGBA"))
        rgba[:, :, 3] = mask.astype(np.uint8) * 255
        frames.append(Image.fromarray(rgba))
    # Further alignment/QA is deliberately separate: inspect generated sheet first.
    cuts = out / "cuts"
    cuts.mkdir(exist_ok=True)
    for i, frame in enumerate(frames):
        frame.save(cuts / f"spr_{i:02d}.png")


def assemble(out):
    """Rejected generated cells must not reintroduce size drift: use accepted v6 paint.

    ANIM_PIPELINE v3 prescribes whole-figure transforms for these service reactions.
    The standing endpoints are byte-identical to the accepted polished v6 idle.
    """
    import shutil
    source = ROOT / "godot/assets/anim/skeleton/idle/spr_00.png"
    idle = Image.open(source).convert("RGBA")
    report = {}
    for kind, n, fps in (("hit", 5, 12), ("spawn", 8, 20)):
        dest = ROOT / "godot/assets/anim/skeleton" / kind
        preview = []
        for i in range(n):
            frame = Image.new("RGBA", idle.size)
            if kind == "hit":
                k = math.sin(math.pi * min(1.0, i / (n - 1) * 1.15)) ** 0.6
                frame = idle.rotate(-9 * k, Image.Resampling.BICUBIC,
                                    center=(250, 450), translate=(-16 * k, -3 * k))
            else:
                offset = round((1 - i / (n - 1)) * 360)
                frame.alpha_composite(idle, (0, offset))
                frame.paste((0, 0, 0, 0), (0, 451, 460, 460))
            target = dest / f"spr_{i:02d}.png"
            frame.save(target)
            if i == n - 1 or (kind == "hit" and i == 0):
                shutil.copyfile(source, target)
                frame = idle.copy()
            bg = Image.new("RGBA", idle.size, (28, 24, 38, 255))
            bg.alpha_composite(frame)
            preview.append(bg.resize((115, 115), Image.Resampling.LANCZOS).convert("RGB"))
        # Include idle holds around each reaction to make the actual transition reviewable.
        rest = Image.new("RGBA", idle.size, (28, 24, 38, 255))
        rest.alpha_composite(idle)
        rest = rest.resize((115, 115), Image.Resampling.LANCZOS).convert("RGB")
        sequence = [rest] + preview + [rest]
        sequence[0].save(out / f"{kind}_v6_game.gif", save_all=True,
                         append_images=sequence[1:], loop=0,
                         duration=[500] + [round(1000 / fps)] * n + [500])
        contact = Image.new("RGB", (115 * len(sequence), 115), (28, 24, 38))
        for j, img in enumerate(sequence):
            contact.paste(img, (j * 115, 0))
        contact.save(out / f"{kind}_v6_transition.png")
        report[kind] = {"frames": n, "fps": fps, "endpoint_identical_to_idle": True,
                        "source": str(source)}
    (out / "reaction_assembly.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    globals()[sys.argv[1]](pathlib.Path(sys.argv[2]))
