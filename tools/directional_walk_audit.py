#!/usr/bin/env python3
"""Audit a directional rig in projected coordinates; report intentional slide honestly."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

from directional_walk_rig import frame


def audit(path: Path, export_scale: float = 1.0) -> dict:
    settings = json.loads(path.read_text(encoding="utf-8"))
    report = {}
    for direction, annotation in settings["views"].items():
        rig = dict(settings["gait"], **annotation, direction=direction)
        master = Image.open(path.parent / f"{direction}.png").convert("RGBA")
        scale = settings["body_h"] / settings.get("standing_height_px", 192)
        cycle = rig["cycle"]
        floating = rig.get("mode") == "float"
        contact_speed = 0 if floating else 4 * rig["screen_half_stride"] * scale / cycle
        margin = 256
        detached = 0
        bone_error = 0
        for index in range(rig["frames"]):
            image, traces = frame(master, rig, index / rig["frames"])
            if export_scale != 1:
                size = (round(master.width * export_scale), round(master.height * export_scale))
                image = image.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")
            alpha = np.asarray(image)[..., 3] > 64
            yy, xx = np.where(alpha)
            margin = min(margin, int(xx.min()), int(yy.min()),
                         image.width - 1 - int(xx.max()), image.height - 1 - int(yy.max()))
            labels, _ = ndimage.label(alpha)
            counts = np.bincount(labels.ravel())[1:]
            detached += int(sum(counts > 12) != 1)
            for leg, trace in zip(rig.get("legs", []), traces):
                hip, knee, foot = map(np.array, (trace["hip"], trace["knee"], trace["ankle"]))
                bone_error = max(bone_error, abs(np.linalg.norm(knee - hip) - leg["links"][0]),
                                 abs(np.linalg.norm(foot - knee) - leg["links"][1]))
        report[direction] = {"frames": rig["frames"], "cycle_s": cycle,
            "fps": rig["frames"] / cycle, "support_ratio": None if floating else contact_speed / settings["speed"],
            "residual_slide_world_px_s": None if floating else settings["speed"] - contact_speed,
            "min_transparent_margin_px": margin, "detached_limb_frames": detached,
            "max_bone_length_error_px": bone_error,
            "runtime_canvas_px": image.width,
            "walk_texture_bytes_rgba8": rig["frames"] * image.width * image.height * 4}
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rig', type=Path)
    parser.add_argument('--export-scale', type=float, default=1.0)
    args = parser.parse_args()
    print(json.dumps(audit(args.rig, args.export_scale), indent=2))
