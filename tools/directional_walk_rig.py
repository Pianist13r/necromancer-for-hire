#!/usr/bin/env python3
"""Offline directional sprites from approved standing art; no runtime simulation changes.

normalize accepts a private raw manifest. render accepts portable normalized masters
and their explicitly reviewed per-view leg annotations. Coordinates are source PNG
pixels, z is height, and the camera projects ground depth onto screen y.

python tools/directional_walk_rig.py normalize PRIVATE_MANIFEST NORMALIZED_FOLDER
python tools/directional_walk_rig.py render NORMALIZED_FOLDER/rig.json godot/assets/anim --export-scale .5

Each rig sets character/body_h/speed and gait defaults. Each views entry contains
its own body_polygon, hip/ankle, constant link lengths, cloth widths/colors, boot
polygon and depth bias. Floating art uses gait.mode="float", no leg annotations;
float_px defaults to0 so the existing CharView floating motion is applied once.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

DIRECTIONS = {"e": (1, 0), "se": (1, 1), "s": (0, 1), "ne": (1, -1), "n": (0, -1)}


def keyed(image: Image.Image) -> Image.Image:
    """Remove the measured border background, including antialiased edge spill."""
    if "A" in image.getbands() and image.getextrema()[image.getbands().index("A")][0] < 255:
        return image.convert("RGBA")
    rgb = np.asarray(image.convert("RGB"), dtype=float)
    border = np.concatenate((rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]))
    bg = np.median(border, axis=0)
    distance = np.linalg.norm(rgb - bg, axis=2)
    hard = ndimage.binary_erosion(distance > 35, iterations=3)
    if not hard.any():
        raise ValueError("No foreground distinct from border background")
    _, nearest = ndimage.distance_transform_edt(~hard, return_indices=True)
    foreground = rgb[nearest[0], nearest[1]]
    vector = foreground - bg
    alpha = np.clip(np.sum((rgb - bg) * vector, axis=2) /
                    np.maximum(np.sum(vector * vector, axis=2), 1), 0, 1)
    alpha[distance < 35] = 0
    alpha[hard] = 1
    recovered = np.clip((rgb - (1 - alpha[..., None]) * bg) /
                        np.maximum(alpha[..., None], 1 / 255), 0, 255)
    rgba = np.dstack((recovered, alpha * 255)).astype(np.uint8)
    rgba[alpha == 0, :3] = 0
    return Image.fromarray(rgba)


def normalize(manifest: Path, out: Path, directions: list[str] | None = None) -> None:
    source = json.loads(manifest.read_text(encoding="utf-8"))
    out.mkdir(parents=True, exist_ok=True)
    report_path = out / "normalization.json"
    anchors_path = out / "foot_anchors.json"
    anchors = json.loads(anchors_path.read_text(encoding="utf-8")) if anchors_path.exists() else {}
    report = json.loads(report_path.read_text(encoding="utf-8")) if directions and report_path.exists() else {}
    for direction, filename in source["files"].items():
        if directions and direction not in directions:
            continue
        image = keyed(Image.open(filename))
        alpha = np.asarray(image)[..., 3]
        yy, xx = np.where(alpha > 128)
        bbox = (int(xx.min()), int(yy.min()), int(xx.max()) + 1, int(yy.max()) + 1)
        crop = image.crop(bbox)
        scale = 192 / crop.height
        size = (round(crop.width * scale), 192)
        crop = crop.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")
        # Ground pivot follows the stance, not an asymmetric head/hand bounding box.
        contact_band = max(1, round((bbox[3] - bbox[1]) * 0.047))
        shoes = np.where((alpha > 128) & (np.indices(alpha.shape)[0] >= bbox[3] - contact_band))
        foot_center = (float(shoes[1].min()) + float(shoes[1].max())) / 2
        if direction in anchors:
            anchor = anchors[direction]
            if anchor["source_name"] != Path(filename).name:
                raise ValueError(f"Reviewed foot anchor belongs to a different {direction} source")
            foot_center = float(anchor["source_x"])
        left = round(128 - (foot_center - bbox[0]) * scale)
        master = Image.new("RGBA", (256, 256))
        master.alpha_composite(crop, (left, 32))
        master.save(out / f"{direction}.png")
        report[direction] = {"source_name": Path(filename).name, "source_bbox": bbox,
                             "scale": scale, "paste": [left, 32], "pivot_px": [128, 224],
                             "foot_center_source_x": foot_center,
                             "reviewed_foot_anchor": direction in anchors}
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def project(point: np.ndarray, depth: float) -> np.ndarray:
    return np.array([point[0], point[1] * depth - point[2]])


def forward(direction: str, depth: float) -> np.ndarray:
    x, y = DIRECTIONS[direction]
    vector = np.array([x, y / depth, 0.0])
    return vector / np.linalg.norm(vector)


def foot_phase(phase: float, half: float, lift: float) -> tuple[float, float, bool]:
    phase %= 1
    if phase < 0.5:
        return half * (1 - 4 * phase), 0, True
    u = (phase - 0.5) * 2
    return -half * math.cos(math.pi * u), lift * math.sin(math.pi * u) ** 2, False


def knee_ik(hip: np.ndarray, ankle: np.ndarray, upper: float, lower: float,
            bend: np.ndarray) -> np.ndarray:
    delta = ankle - hip
    distance = np.linalg.norm(delta)
    if not abs(upper - lower) + 1e-6 < distance < upper + lower - 1e-6:
        raise ValueError(f"Unreachable leg: distance {distance:.3f}, links {upper}, {lower}")
    axis = delta / distance
    normal = bend - np.dot(bend, axis) * axis
    if np.linalg.norm(normal) < 1e-6:
        raise ValueError("Knee bend parallel to leg")
    normal /= np.linalg.norm(normal)
    along = (upper * upper - lower * lower + distance * distance) / (2 * distance)
    radius = math.sqrt(max(0, upper * upper - along * along))
    return hip + axis * along + normal * radius


def shifted(image: Image.Image, dx: float, dy: float) -> Image.Image:
    return image.convert("RGBa").transform(image.size, Image.Transform.AFFINE,
        (1, 0, -dx, 0, 1, -dy), Image.Resampling.BICUBIC).convert("RGBA")


def piece(image: Image.Image, polygon: list) -> Image.Image:
    mask = Image.new("L", image.size)
    ImageDraw.Draw(mask).polygon([tuple(p) for p in polygon], fill=255)
    out = image.copy()
    out.putalpha(Image.fromarray(np.minimum(np.asarray(mask), np.asarray(image)[..., 3])))
    return out


def warped_segment(image: Image.Image, source_a: list, source_b: list,
                   target_a: np.ndarray, target_b: np.ndarray) -> Image.Image:
    """Preserve drawn bone/detail, foreshortening its length but not its width."""
    source_a, source_b = np.array(source_a, dtype=float), np.array(source_b, dtype=float)
    source_delta, target_delta = source_b - source_a, target_b - target_a
    source_length, target_length = np.linalg.norm(source_delta), np.linalg.norm(target_delta)
    if min(source_length, target_length) < 1e-6:
        raise ValueError("Cannot warp a zero-length segment")
    source_axis, target_axis = source_delta / source_length, target_delta / target_length
    source_normal = np.array([-source_axis[1], source_axis[0]])
    target_normal = np.array([-target_axis[1], target_axis[0]])
    matrix = np.outer(source_axis, target_axis) * source_length / target_length + np.outer(source_normal, target_normal)
    offset = source_a - matrix @ target_a
    return image.convert("RGBa").transform(image.size, Image.Transform.AFFINE,
        (matrix[0,0], matrix[0,1], offset[0], matrix[1,0], matrix[1,1], offset[1]),
        Image.Resampling.BICUBIC).convert("RGBA")


def pants(points: list[np.ndarray], widths: list[float], fill: list, outline: list,
          size: tuple[int, int]) -> Image.Image:
    """Joined two-link cloth silhouette. Round joints prevent knee seams."""
    ss = 4
    image = Image.new("RGBA", (size[0] * ss, size[1] * ss))
    draw = ImageDraw.Draw(image)
    points = [p * ss for p in points]
    widths = [w * ss for w in widths]
    edge = 2.5 * ss
    def shape(extra: float, color: list) -> None:
        for a, b, wa, wb in zip(points, points[1:], widths, widths[1:]):
            delta = b - a
            length = np.linalg.norm(delta)
            normal = np.array([-delta[1], delta[0]]) / max(length, 1e-6)
            draw.polygon([tuple(a + normal * (wa + extra) / 2),
                          tuple(b + normal * (wb + extra) / 2),
                          tuple(b - normal * (wb + extra) / 2),
                          tuple(a - normal * (wa + extra) / 2)], fill=tuple(color))
        for point, width in zip(points, widths):
            radius = (width + extra) / 2
            draw.ellipse((*tuple(point - radius), *tuple(point + radius)), fill=tuple(color))
    shape(edge, outline)
    shape(0, fill)
    return image.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")


def frame(master: Image.Image, rig: dict, phase: float) -> tuple[Image.Image, list]:
    if rig.get("mode") == "float":
        lift = rig.get("float_px", 0.0) * (1 - math.cos(2 * math.pi * phase)) / 2
        return shifted(master, 0, -lift), []
    depth = rig.get("depth_scale", 0.6)
    fwd = forward(rig["direction"], depth)
    screen_factor = np.linalg.norm(project(fwd, depth))
    half = rig["screen_half_stride"] / screen_factor
    body = piece(master, rig["body_polygon"])
    for polygon in rig.get("keep_polygons", []):
        # Union alpha, not repeated over-composition of antialiased source edges.
        kept = piece(master, polygon)
        alpha = Image.fromarray(np.maximum(np.asarray(body)[...,3], np.asarray(kept)[...,3]))
        body.putalpha(alpha)
    bob = rig.get("bob", 1.0) * (1 - math.cos(4 * math.pi * phase)) / 2
    traces = []
    layers = []
    for index, leg in enumerate(rig["legs"]):
        u = (phase + index * 0.5) % 1
        stride, lift, support = foot_phase(u, half, rig["lift"])
        hip_screen = np.array(leg["hip"], dtype=float) + [0, bob]
        neutral = np.array(leg["ankle"], dtype=float)
        height = neutral[1] - leg["hip"][1]
        hip = np.array([0.0, 0.0, height - bob])
        foot = np.array([neutral[0] - leg["hip"][0], 0.0, 0.0]) + fwd * stride
        foot[2] = lift
        knee = knee_ik(hip, foot, *leg["links"], fwd)
        anchor = np.array(leg["hip"], dtype=float) + [0, height]
        knee_screen = anchor + project(knee, depth)
        foot_screen = anchor + project(foot, depth)
        cloth = pants([hip_screen, knee_screen, foot_screen], leg["widths"],
                      leg["fill"], rig["outline"], master.size)
        if "lower_piece" in leg:
            annotation = leg["lower_piece"]
            lower = warped_segment(piece(master, annotation["polygon"]),
                annotation["from"], annotation["to"], knee_screen, foot_screen)
            upper = pants([hip_screen, knee_screen], leg["widths"][:2],
                          leg["fill"], rig["outline"], master.size)
            lower.alpha_composite(upper)
            cloth = lower
        boot = piece(master, leg["boot_polygon"])
        # Some approved masters contain a lifted resting shoe. Its source
        # attachment differs from the neutral ground anchor used by IK.
        boot = shifted(boot, *(foot_screen - np.array(leg.get("boot_anchor", neutral))))
        cloth.alpha_composite(boot)
        layers.append((float(foot[1]) + leg.get("depth", 0), cloth))
        traces.append({"phase": u, "support": support, "hip": hip.tolist(),
                       "knee": knee.tolist(), "ankle": foot.tolist(),
                       "screen_ankle": foot_screen.tolist()})
    image = Image.new("RGBA", master.size)
    for _, layer in sorted(layers, key=lambda pair: pair[0]):
        image.alpha_composite(layer)
    image.alpha_composite(shifted(body, 0, bob))
    return image, traces


def render(rigfile: Path, out: Path, qa: Path | None = None, export_scale: float = 1.0) -> None:
    settings = json.loads(rigfile.read_text(encoding="utf-8"))
    for direction, annotation in settings["views"].items():
        rig = dict(settings["gait"], **annotation, direction=direction)
        master = Image.open(rigfile.parent / f"{direction}.png").convert("RGBA")
        if not 0 < export_scale <= 1:
            raise ValueError("export_scale must be in (0,1]")
        size = (round(master.width * export_scale), round(master.height * export_scale))
        folder = out / settings["character"] / f"walk_{direction}"
        folder.mkdir(parents=True, exist_ok=True)
        scale = settings["body_h"] / settings.get("standing_height_px", 192)
        cycle = rig["cycle"] if "cycle" in rig else (
            4 * rig["screen_half_stride"] * scale / (settings["speed"] * rig["support_ratio"]))
        floating = rig.get("mode") == "float"
        count = rig["frames"]
        traces = []
        for i in range(count):
            image, trace = frame(master, rig, i / count)
            if image.size != size:
                image = image.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")
            image.save(folder / f"spr_{i:02d}.png")
            traces.append(trace)
        meta = {"frames": count, "fps": round(count / cycle, 4), "loop": True,
                "duration": cycle, "pivot_px": [p * export_scale for p in settings.get("pivot_px", [128, 224])],
                "figure_fill": settings.get("standing_height_px", 192) / master.height,
                "stride": [] if floating else [abs(math.cos(2 * math.pi * i / count)) for i in range(count)],
                "step_canvas_px": 0 if floating else 2 * rig["screen_half_stride"] * export_scale,
                "contact_phase": 0.0,
                "support_ratio": None if floating else 4 * rig["screen_half_stride"] * scale / (cycle * settings["speed"]),
                "residual_slide_world_px_s": None if floating else settings["speed"] - 4 * rig["screen_half_stride"] * scale / cycle}
        (folder / "clip.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        idle = out / settings["character"] / f"idle_{direction}"
        idle.mkdir(parents=True, exist_ok=True)
        master.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA").save(idle / "spr_00.png")
        idle_meta = {"frames": 1, "fps": 1, "loop": True,
                     "pivot_px": meta["pivot_px"], "figure_fill": meta["figure_fill"]}
        (idle / "clip.json").write_text(json.dumps(idle_meta, indent=2) + "\n", encoding="utf-8")
        if qa is not None:
            qa.mkdir(parents=True, exist_ok=True)
            (qa / f"{settings['character']}_{direction}_rig_trace.json").write_text(
                json.dumps(traces, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    norm = commands.add_parser("normalize")
    norm.add_argument("manifest", type=Path)
    norm.add_argument("out", type=Path)
    norm.add_argument("--direction", choices=DIRECTIONS, action="append", help="Replace only selected approved views")
    walk = commands.add_parser("render")
    walk.add_argument("rig", type=Path)
    walk.add_argument("out", type=Path)
    walk.add_argument("--qa", type=Path, help="Optional geometry traces kept outside runtime assets")
    walk.add_argument("--export-scale", type=float, default=1.0, help="Runtime export size; master geometry remains unchanged")
    args = parser.parse_args()
    if args.command == "normalize":
        normalize(args.manifest, args.out, args.direction)
    elif args.command == "render":
        render(args.rig, args.out, args.qa, args.export_scale)


if __name__ == "__main__":
    main()
