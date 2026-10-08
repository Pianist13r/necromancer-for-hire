#!/usr/bin/env python3
"""Match each existing directional IK contact velocity to movement without redrawing.

The gait's path in phase space is unchanged. Only seconds per cycle / playback FPS
change, both in the reproducible rig and in runtime metadata/configuration.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    cfg_path = ROOT / "godot/scripts/common/cfg_anim.gd"
    cfg = cfg_path.read_text(encoding="utf-8")
    report = {}
    for path in sorted((ROOT / "tools/walk_rig_masters/directional").glob("*/rig.json")):
        raw = path.read_text(encoding="utf-8")
        data = json.loads(raw)
        if data["gait"].get("mode") == "float":
            continue
        who = data["character"]
        report[who] = {}
        for direction, view in data["views"].items():
            rig = dict(data["gait"], **view)
            cycle = 4 * rig["screen_half_stride"] * data["body_h"] / data.get("standing_height_px", 192) / data["speed"]
            fps = rig["frames"] / cycle
            view["cycle"] = cycle
            view_start = r'("' + direction + r'"\s*:\s*\{)(?:"cycle": [0-9.]+, )?'
            raw = re.sub(view_start, lambda m: m[1] + f'"cycle": {cycle:.12f}, ', raw)
            report[who][direction] = {"before_seconds": rig["cycle"], "after_seconds": cycle, "fps": fps}
            relative = f"res://assets/anim/{who}/walk_{direction}"
            # Base clips already have fps; directional overrides generally do not.
            pattern = r'("dir": "' + re.escape(relative) + r'")(?:, "fps": [0-9.]+)?'
            cfg, count = re.subn(pattern, lambda m: m[1] + f', "fps": {fps:.9f}', cfg)
            if count != (2 if direction == "e" else 1):
                raise ValueError(f"Unexpected CfgAnim layout for {relative}: {count}")
            meta_path = ROOT / "godot/assets/anim" / who / f"walk_{direction}/clip.json"
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            meta.update(fps=round(fps, 9), duration=cycle, support_ratio=1.0, residual_slide_world_px_s=0.0)
            meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        path.write_text(raw, encoding="utf-8")
    cfg_path.write_text(cfg, encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
