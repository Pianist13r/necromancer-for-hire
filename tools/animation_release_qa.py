#!/usr/bin/env python3
"""Inventory the runtime registry, silhouettes, timing and memory; make review loops.

First export CfgAnim.CHARS using legion_animation_release_test.gd --inventory <path>.
All output is local to --out. Unreferenced legacy clips are listed, never treated as
runtime failures. Silhouette jumps are a diagnostic, not proof of footplant.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ANIM = ROOT / "godot/assets/anim"
DIRS = ("e", "se", "s", "ne", "n")


def contact_sheet(paths, out, columns=5, cell=(192, 160)):
    canvas = Image.new("RGB", (columns * cell[0], ((len(paths) + columns - 1) // columns) * cell[1]), "#282535")
    draw = ImageDraw.Draw(canvas)
    for i, path in enumerate(paths):
        picture = Image.open(path).convert("RGBA")
        picture.thumbnail((cell[0] - 8, cell[1] - 25), Image.Resampling.LANCZOS)
        x, y = i % columns * cell[0], i // columns * cell[1]
        canvas.paste(picture, (x + (cell[0] - picture.width) // 2, y + 20), picture)
        draw.text((x + 3, y + 3), path.stem if "cutscenes" in str(path) else path.parent.name + "/" + path.stem, fill="white")
    canvas.save(out)


def clip_record(folder, fps, loop, gif=None, retime=False):
    paths = sorted(folder.glob("spr_*.png"))
    meta_path = folder / "clip.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
    durations = meta.get("durations", [1.0] * len(paths))
    if len(durations) != len(paths) or any(d <= 0 for d in durations):
        raise ValueError(f"Invalid duration weights: {folder}")
    if retime:
        phase = np.linspace(0, 1, len(paths))
        t = np.clip((phase - .15) / .65, 0, 1)
        weights = np.asarray(durations) * (1.7 + (.55 - 1.7) * t * t * (3 - 2 * t))
        durations = (weights * sum(durations) / weights.sum()).tolist()
    images = [Image.open(p).convert("RGBA") for p in paths]
    if not images:
        raise ValueError(f"Empty clip: {folder}")
    if [p.name for p in paths] != [f"spr_{i:02d}.png" for i in range(len(paths))]:
        raise ValueError(f"Non-contiguous frames: {folder}")
    masks = [np.asarray(im)[..., 3] > 64 for im in images]
    if len({im.size for im in images}) != 1:
        raise ValueError(f"Changing canvas: {folder}")
    pairs = list(zip(masks, masks[1:] + masks[:1])) if loop else list(zip(masks, masks[1:]))
    differences = [float(np.logical_xor(a, b).sum() / max(1, np.logical_or(a, b).sum())) for a, b in pairs]
    mean = float(np.mean(differences)) if differences else 0.0
    peak = max(differences, default=0.0)
    if gif:
        gif.parent.mkdir(parents=True, exist_ok=True)
        frames = []
        for im in images:
            bg = Image.new("RGB", im.size, "#282535")
            bg.paste(im, mask=im.getchannel("A"))
            bg = bg.resize((im.width * 2, im.height * 2), Image.Resampling.NEAREST)
            frames.append(bg)
        # Round the TOTAL cycle, not each frame: 16 frames at 75fps must not
        # accidentally become 16 * 10ms. Sample at browser-safe 50Hz (20ms).
        count = max(1, round(sum(durations) / fps * 50))
        ends = np.cumsum(durations)
        indices = np.searchsorted(ends, np.arange(count) / count * ends[-1], side="right")
        sampled = [frames[min(int(i), len(frames) - 1)] for i in indices]
        ms = [20] * count
        # One-shots repeat with an explicit end-pose hold for review, not gameplay.
        if not loop:
            sampled.append(frames[-1])
            ms.append(460)
        sampled[0].save(gif, save_all=True, append_images=sampled[1:], loop=0, duration=ms, disposal=2)
    return {"frames": len(paths), "canvas": images[0].size,
            "seconds": sum(durations) / fps, "png_bytes": sum(p.stat().st_size for p in paths),
            "rgba8_mip_bytes": sum(im.width * im.height * 4 * 4 / 3 for im in images),
            "silhouette_steps": differences, "silhouette_mean": mean,
            "silhouette_peak": peak, "peak_to_mean": peak / mean if mean else 0,
            "support_ratio": meta.get("support_ratio"),
            "residual_slide_world_px_s": meta.get("residual_slide_world_px_s")}


def run(registry, out, loops=True, loops_only=False):
    out.mkdir(parents=True, exist_ok=True)
    results, referenced, failures = {}, set(), []
    lines = ["# Runtime animation inventory", "", "Five source views; W/SW/NW mirror E/SE/NE.", "",
             "| Character | Clip | E | SE | S | NE | N | Mode |", "|---|---|---|---|---|---|---|---|"]
    for char, definition in registry.items():
        results[char] = {}
        for state, clip in definition["clips"].items():
            views = clip.get("directions", {}) or {"e": {"dir": clip["dir"]}}
            cells = {}
            for direction, view in views.items():
                relative = view["dir"].replace("res://", "godot/")
                folder = ROOT / relative
                referenced.add(folder.resolve())
                key = state + "_" + direction
                rec = clip_record(folder, view.get("fps", clip["fps"]), clip["loop"],
                                  out / "loops" / f"{char}_{key}.gif" if loops else None,
                                  clip.get("retime_fall", False))
                results[char][key] = rec
                cells[direction] = str(rec["frames"])
                if state == "walk" and (rec["silhouette_peak"] > .55 or rec["peak_to_mean"] > 2.5):
                    failures.append(f"{char}/{key}: silhouette jump {rec['silhouette_peak']:.3f}, ratio {rec['peak_to_mean']:.2f}")
            lines.append("| " + " | ".join([char, state] + [cells.get(d, "—") for d in DIRS] + ["loop" if clip["loop"] else "once"]) + " |")
        lines.append(f"| {char} | hit | procedural | procedural | procedural | procedural | procedural | spring/flash |")
        for state, stub in definition.get("stub", {}).items():
            if state not in definition["clips"]:
                lines.append(f"| {char} | {state} | {stub['kind']} | ← | ← | ← | ← | {stub['dur']} s |")
    if loops_only:
        print("GIF timing resampled at 50Hz; stored inventory metrics preserved")
        return bool(failures)
    legacy = sorted(str(p.relative_to(ROOT)) for p in ANIM.glob("*/*") if p.is_dir() and p.resolve() not in referenced)
    all_png = list(ANIM.rglob("*.png"))
    unique_png = {p for folder in referenced for p in folder.glob("spr_*.png")}
    def memory(paths):
        pixels = 0
        for p in paths:
            with Image.open(p) as im:
                pixels += im.width * im.height
        return {"files": len(paths), "png_bytes": sum(p.stat().st_size for p in paths),
                "rgba8_mip_bytes": round(pixels * 4 * 4 / 3)}
    report = {"clips": results, "failures": failures, "legacy_unreferenced": legacy,
              "all_assets": memory(all_png), "runtime_unique": memory(unique_png)}
    (out / "inventory.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    lines += ["", "Silhouette thresholds: max XOR/union <= 0.55; peak/mean <= 2.5 (includes loop seam).",
              "These detect discontinuity; IK support/slide are separate measurements.", "",
              "## Unreferenced legacy directories", ""] + ["- " + p for p in legacy]
    (out / "inventory.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "clips" and k != "legacy_unreferenced"}, indent=2))
    return bool(failures)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--no-loops", action="store_true")
    parser.add_argument("--loops-only", action="store_true", help="Regenerate previews without overwriting before measurements")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    cuts = sorted((ROOT / "godot/assets/legion/cutscenes").glob("*.png"))
    contact_sheet(cuts, args.out / "cutscenes.jpg", 3, (420, 260))
    for who in ("guard", "clerk", "necromancer"):
        paths = []
        for state in ("idle_e", "walk_e", "attack_e", "death_e", "idle", "cast", "ult"):
            frames = sorted((ANIM / who / state).glob("spr_*.png"))
            paths += frames[::max(1, len(frames) // 5)][:5]
        contact_sheet(paths, args.out / f"{who}.jpg")
        if who != "necromancer":
            paths = []
            for direction in DIRS:
                frames = sorted((ANIM / who / f"attack_{direction}").glob("spr_*.png"))
                paths += [frames[min(len(frames) - 1, round(i * (len(frames) - 1) / 4))] for i in range(5)]
            contact_sheet(paths, args.out / f"{who}_all_attacks.jpg")
    if args.registry:
        raise SystemExit(run(json.loads(args.registry.read_text(encoding="utf-8")), args.out,
                             not args.no_loops, args.loops_only))
