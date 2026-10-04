#!/usr/bin/env python3
"""Extract manifest-selected AI motion frames with one standing scale and fixed ground pivot.

Requires Python 3.11+, numpy, opencv-python, scipy and Pillow. Raw video stays outside Git.
Run: python tools/directional_motion_extract.py MANIFEST.json --out SCRATCH_DIR
"""

import argparse
import hashlib
import json
import math
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import binary_fill_holes, distance_transform_edt

DIRECTION_VECTORS = {"e": (1, 0), "se": (1, 1), "s": (0, 1), "sw": (-1, 1),
                     "w": (-1, 0), "nw": (-1, -1), "n": (0, -1), "ne": (1, -1)}
KEY_ALGORITHM = "border-hsv-opaque-ink-v2"


def bounds(alpha, threshold=16):
    ys, xs = np.where(alpha > threshold)
    if not len(xs):
        raise ValueError("Empty foreground after background removal")
    return [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]


def key_frame(rgb, config):
    """Measure the actual border hue, including its dark shadow; keep detached props too."""
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    band = max(2, min(rgb.shape[:2]) // 100)
    border = np.concatenate([hsv[:band].reshape(-1, 3), hsv[-band:].reshape(-1, 3),
                             hsv[:, :band].reshape(-1, 3), hsv[:, -band:].reshape(-1, 3)])
    saturated = border[border[:, 1] >= int(config.get("min_saturation", 80))]
    if len(saturated) < len(border) * 0.8:
        raise ValueError("Border is not a consistent saturated key background")
    hue = int(np.argmax(np.bincount(saturated[:, 0], minlength=180)))
    # Purple outlines can share the key hue while being much less saturated.
    # Shadows retain the border chroma; using hue alone punched holes in dark helmets.
    border_saturation = float(np.median(saturated[:, 1]))
    minimum_key_saturation = max(float(config.get("min_saturation", 80)), border_saturation *
                                 float(config.get("border_saturation_ratio", 0.8)))
    distance = np.abs(hsv[:, :, 0].astype(float) - hue)
    distance = np.minimum(distance, 180 - distance) * 2
    background = ((distance <= float(config.get("hue_tolerance_degrees", 18)))
                  & (hsv[:, :, 1] >= minimum_key_saturation))
    if np.mean(background[:band]) < 0.99 or np.mean(background[-band:]) < 0.99:
        raise ValueError("Foreground/key mismatch at source border; source may be clipped")
    # A dark outline enclosed by the character is not the bright backdrop visible through
    # e.g. a wrench ring. Retain enclosed ink; exterior key shadows remain background.
    border_value = float(np.median(saturated[:, 2]))
    enclosed_ink = binary_fill_holes(~background) & background & (hsv[:, :, 2] < border_value * 0.55)
    background[enclosed_ink] = False
    foreground = ~background
    interior = cv2.erode(foreground.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    if not interior.any():
        raise ValueError("No opaque foreground interior")
    # Edge colors are mixed with the video background. Project onto the local BG→FG line;
    # nearest opaque foreground removes pink spill without repainting clothes/props.
    _, bg_index = distance_transform_edt(foreground, return_indices=True)
    core_distance, fg_index = distance_transform_edt(~interior, return_indices=True)
    background_rgb = rgb[bg_index[0], bg_index[1]].astype(np.float32)
    foreground_rgb = rgb[fg_index[0], fg_index[1]].astype(np.float32)
    edge = foreground & ~interior
    delta = foreground_rgb - background_rgb
    denominator = np.maximum(np.sum(delta * delta, axis=2), 1.0)
    alpha = foreground.astype(np.float32)
    projected = np.sum((rgb.astype(np.float32) - background_rgb) * delta, axis=2) / denominator
    alpha[edge] = np.clip(projected[edge], 0.0, 1.0)
    # Dark solid ink is not a BG→FG blend. Projection onto a neighbouring bright shirt
    # otherwise makes opaque outlines transparent. Remote key-hue edge noise
    # is JPEG shadow residue rather than a thin outline next to an opaque foreground core.
    dark_outline = edge & (core_distance <= 3) & (hsv[:, :, 2] < border_value * 0.65)
    shadow_noise = edge & (core_distance > 4) & (distance <= float(config.get("hue_tolerance_degrees", 18)))
    alpha[dark_outline] = 1
    alpha[shadow_noise] = 0
    output_rgb = rgb.copy()
    output_rgb[edge] = foreground_rgb[edge].astype(np.uint8)
    output_rgb[dark_outline] = rgb[dark_outline]
    output_rgb[background] = 0
    rgba = np.dstack([output_rgb, np.rint(alpha * 255).astype(np.uint8)])
    box = bounds(rgba[:, :, 3])
    if min(box[0], box[1], rgb.shape[1] - box[2], rgb.shape[0] - box[3]) < 2:
        raise ValueError("Source foreground touches the video border")
    return rgba, {"hue_degrees": hue * 2, "minimum_key_saturation": minimum_key_saturation,
                  "border_hsv_median": np.median(border, axis=0).tolist(),
                  "source_bbox": box}


def ground_anchor(rgba, box):
    """Bottom-center of the feet band in the first source frame, not the changing body bbox."""
    height = box[3] - box[1]
    band_top = box[3] - max(2, round(height * 0.035))
    _, xs = np.where(rgba[band_top:box[3], box[0]:box[2], 3] > 128)
    xs += box[0]
    if not len(xs):
        raise ValueError("First frame has no opaque feet")
    return [(float(xs.min()) + float(xs.max()) + 1) / 2, float(box[3])]


def layout(reference, frames, config, runtime_scale=1.0):
    first_box = config.get("source_standing_bbox") or bounds(reference[:, :, 3])
    if (len(first_box) != 4 or first_box[2] <= first_box[0] or first_box[3] <= first_box[1]
            or first_box[0] < 0 or first_box[1] < 0 or first_box[2] > reference.shape[1]
            or first_box[3] > reference.shape[0]):
        raise ValueError("Invalid source_standing_bbox")
    master_height = float(config.get("standing_height_px", 192))
    standing_height = master_height * runtime_scale
    if not math.isfinite(standing_height) or standing_height <= 0 or not 0 < runtime_scale <= 1:
        raise ValueError("standing_height_px must be positive")
    scale = standing_height / (first_box[3] - first_box[1])
    anchor = config.get("source_pivot_px") or ground_anchor(reference, first_box)
    if len(anchor) != 2 or not np.isfinite(anchor).all():
        raise ValueError("Invalid source_pivot_px")
    boxes = [bounds(reference[:, :, 3])] + [bounds(frame[:, :, 3]) for frame in frames]
    union = [min(box[0] for box in boxes), min(box[1] for box in boxes),
             max(box[2] for box in boxes), max(box[3] for box in boxes)]
    # Include the ground and interpolation support; the standing master never gets shrunk
    # to make a wider lying body fit. Pick a larger square instead.
    lo = (np.minimum(union[:2], anchor) - anchor) * scale
    hi = (np.maximum(union[2:], anchor) - anchor) * scale
    padding = int(config.get("padding_px", 16))
    sizes = [round(float(size) * runtime_scale) for size in config.get("canvas_sizes", [256, 384, 512])]
    required = max(hi - lo) + 2 * (padding + 4)
    candidates = [int(size) for size in sizes if int(size) >= required]
    if not candidates:
        raise ValueError(f"Union needs {required:.1f}px; allow a larger canvas, do not rescale frames")
    canvas = min(candidates)
    pivot = np.array([canvas / 2, canvas / 2]) - (lo + hi) / 2
    translation = pivot - np.array(anchor) * scale
    matrix = np.array([[scale, 0, translation[0]], [0, scale, translation[1]]], dtype=np.float32)
    return matrix, {"canvas_px": canvas, "pivot_px": pivot.tolist(),
                    "figure_fill": standing_height / canvas, "standing_height_px": standing_height,
                    "master_standing_height_px": master_height, "runtime_scale": runtime_scale,
                    "source_standing_bbox": first_box, "source_pivot_px": list(anchor),
                    "source_union_bbox": union, "scale": scale, "padding_px": padding,
                    "affine_matrix": matrix.tolist()}


def transform_frame(rgba, matrix, canvas):
    # Resampling premultiplied colors prevents black/pink fringes at alpha edges.
    source = rgba.astype(np.float32) / 255
    source[:, :, :3] *= source[:, :, 3:4]
    resized = cv2.warpAffine(source, matrix, (canvas, canvas), flags=cv2.INTER_LANCZOS4,
                             borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0, 0))
    alpha = np.clip(resized[:, :, 3:4], 0, 1)
    colors = np.clip(resized[:, :, :3] / np.maximum(alpha, 1e-6), 0, 1)
    colors[alpha[:, :, 0] <= 1 / 255] = 0
    return np.rint(np.dstack([colors, alpha]) * 255).astype(np.uint8)


def verify(frames, geometry, key_observations):
    canvas = geometry["canvas_px"]
    minimum_pad = canvas
    boxes = []
    key_pixels = 0
    visible_pixels = 0
    for frame, observation in zip(frames, key_observations):
        if frame.shape != (canvas, canvas, 4):
            raise ValueError("Frame canvases differ")
        box = bounds(frame[:, :, 3], threshold=1)
        minimum_pad = min(minimum_pad, box[0], box[1], canvas - box[2], canvas - box[3])
        boxes.append(box)
        hsv = cv2.cvtColor(frame[:, :, :3], cv2.COLOR_RGB2HSV)
        hue_distance = np.abs(hsv[:, :, 0].astype(float) * 2 - observation["hue_degrees"])
        hue_distance = np.minimum(hue_distance, 360 - hue_distance)
        visible = frame[:, :, 3] > 32
        key_pixels += int(np.sum(visible & (hue_distance < 5)
                                 & (hsv[:, :, 1] >= observation.get("minimum_key_saturation", 100))
                                 & (hsv[:, :, 2] >= observation["border_hsv_median"][2] * 0.55)))
        visible_pixels += int(visible.sum())
    if minimum_pad < geometry["padding_px"]:
        raise ValueError(f"Clipping/padding failure: {minimum_pad}px, expected {geometry['padding_px']}")
    fraction = key_pixels / max(1, visible_pixels)
    if fraction > 0.005:
        raise ValueError(f"Key-colored foreground remains ({fraction:.2%}); review key settings")
    return {"same_canvas": True, "minimum_transparent_padding_px": minimum_pad,
            "frame_bboxes": boxes, "key_colored_visible_fraction": fraction,
            "one_affine_for_all_frames": True, "scale_reference_frame": 0,
            "first_frame_scale_preserved": True}


def checkerboard(size):
    yy, xx = np.indices((size, size))
    checker = np.where((xx // 12 + yy // 12) % 2, 185, 220).astype(np.uint8)
    return Image.fromarray(np.dstack([checker] * 3)).convert("RGBA")


def collapse_exact(frames, durations, samples, contact):
    """Merge adjacent identical textures, keeping the impact boundary at its exact time."""
    kept, weights, groups = [], [], []
    remapped_contact = -1
    for index, (frame, duration, sample) in enumerate(zip(frames, durations, samples)):
        if kept and index != contact and np.array_equal(kept[-1], frame):
            weights[-1] += duration
            groups[-1].append(sample)
        else:
            kept.append(frame)
            weights.append(duration)
            groups.append([sample])
        if index == contact:
            remapped_contact = len(kept) - 1
    return kept, weights, groups, remapped_contact


def previews(frames, samples, geometry, seconds_per_frame, out):
    canvas = geometry["canvas_px"]
    composited = []
    game = {height: [] for height in [44, 88]}
    sheet = Image.new("RGB", (6 * 200, ((len(frames) + 5) // 6) * 224), (35, 35, 40))
    draw = ImageDraw.Draw(sheet)
    for index, (frame, sample) in enumerate(zip(frames, samples)):
        image = Image.fromarray(frame)
        preview = Image.alpha_composite(checkerboard(canvas), image).convert("RGB")
        composited.append(preview)
        for height, images in game.items():
            size = round(canvas * height / geometry["standing_height_px"])
            images.append(preview.resize((size, size), Image.Resampling.LANCZOS))
        x, y = (index % 6) * 200, (index // 6) * 224
        sheet.paste(preview.resize((192, 192), Image.Resampling.LANCZOS), (x + 4, y + 28))
        draw.text((x + 5, y + 5), f"{index:02}: src {sample['frame']} / {sample['seconds']:.3f}s", fill="white")
    # GIF stores centiseconds, so cumulative rounding keeps the requested total cycle time.
    boundaries = np.rint(np.concatenate([[0], np.cumsum(seconds_per_frame)]) * 100).astype(int)
    durations = (np.diff(boundaries) * 10).tolist()
    if min(durations) < 10:
        raise ValueError("Runtime GIF cannot represent sub-centisecond frames")
    for filename, images, timing in [("preview_runtime.gif", composited, durations),
                                      ("preview_slow.gif", composited, [100] * len(frames)),
                                      *[(f"preview_game{height}.gif", images, durations)
                                        for height, images in game.items()]]:
        images[0].save(out / filename, save_all=True, append_images=images[1:], duration=timing,
                       loop=0, optimize=False, disposal=2)
    sheet.save(out / "contactsheet.png")


def extract(manifest, manifest_path, out, source_override=None, runtime_scale=1.0):
    samples = manifest["samples"]
    total = float(manifest["total_seconds"])
    fps = float(manifest["fps"])
    contact = int(manifest.get("contact_frame", -1))
    direction = np.array(DIRECTION_VECTORS[manifest["direction"]], dtype=float)
    direction /= np.linalg.norm(direction)
    if (not samples or not math.isfinite(total) or not math.isfinite(fps) or total <= 0 or fps <= 0
            or not -1 <= contact < len(samples)):
        raise ValueError("Invalid samples, total_seconds, fps or final PNG contact_frame")
    if any(type(sample["frame"]) is not int for sample in samples):
        raise ValueError("Source frame indexes must be exact integers")
    if out.exists():
        raise FileExistsError(f"Output directory already exists: {out}")
    source = Path(source_override or manifest["source_video"])
    if not source.is_absolute():
        source = manifest_path.parent / source
    if not source.is_file():
        raise FileNotFoundError("Reviewed raw video unavailable; pass --source PATH matching manifest SHA256")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if manifest.get("source_sha256") and manifest["source_sha256"] != digest:
        raise ValueError("Source SHA256 differs from the reviewed manifest")
    cap = cv2.VideoCapture(str(source))
    try:
        source_fps = cap.get(cv2.CAP_PROP_FPS)
        count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        if source_fps <= 0 or count <= 0:
            raise ValueError("Cannot decode source video")
        if manifest.get("source_fps") and abs(float(manifest["source_fps"]) - source_fps) > 0.001:
            raise ValueError("Video FPS differs from manifest")
        indexes = [int(sample["frame"]) for sample in samples]
        if indexes != sorted(indexes) and manifest.get("allow_reverse_samples") is not True:
            raise ValueError("Nonmonotonic source samples require explicit allow_reverse_samples=true")
        if min(indexes) < 0 or max(indexes) >= count:
            raise ValueError("Source frame list must be inside video")
        for sample in samples:
            if abs(float(sample["seconds"]) - int(sample["frame"]) / source_fps) > 1e-5:
                raise ValueError("Source frame/time mismatch in manifest")
        keyed, observations = {}, {}
        for index in sorted(set([0] + indexes)):
            cap.set(cv2.CAP_PROP_POS_FRAMES, index)
            ok, bgr = cap.read()
            if not ok:
                raise ValueError(f"Cannot decode source frame {index}")
            rgba, observation = key_frame(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB), manifest.get("key", {}))
            keyed[index], observations[index] = rgba, observation
    finally:
        cap.release()
    raw_frames = [keyed[index] for index in indexes]
    matrix, geometry = layout(keyed[0], raw_frames, manifest.get("normalization", {}), runtime_scale)
    frames = [transform_frame(frame, matrix, geometry["canvas_px"]) for frame in raw_frames]
    qa = verify(frames, geometry, [observations[index] for index in indexes])
    weights = np.array([float(sample.get("duration_weight", 1)) for sample in samples])
    if not np.isfinite(weights).all() or (weights <= 0).any():
        raise ValueError("duration_weight must be finite and positive")
    durations = (weights / weights.sum() * total * fps).tolist()
    groups = [[sample] for sample in samples]
    if manifest.get("collapse_exact_duplicates", False):
        frames, durations, groups, contact = collapse_exact(frames, durations, samples, contact)
    output_samples = [group[0] for group in groups]
    out.mkdir(parents=True, exist_ok=False)
    clip = {"durations": durations, "fps": fps, "total_seconds": total, "contact_frame": contact,
            "key_algorithm": KEY_ALGORITHM,
            "pivot_px": geometry["pivot_px"], "figure_fill": geometry["figure_fill"],
            "source_frames": output_samples, "source_sample_groups": groups, "normalization": geometry,
            "state": manifest["state"], "direction": direction.tolist(),
            "direction_name": manifest["direction"]}
    for index, frame in enumerate(frames):
        Image.fromarray(frame).save(out / f"spr_{index:02d}.png")
    Image.fromarray(transform_frame(keyed[0], matrix, geometry["canvas_px"])).save(out / "standing_reference.png")
    (out / "clip.json").write_text(json.dumps(clip, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    record = {"input_manifest": manifest, "source_sha256": digest, "source_fps": source_fps,
              "key_algorithm": KEY_ALGORITHM,
              "source_frame_count": count, "key_observations": observations, "qa": qa,
              "duration_seconds": sum(durations) / fps,
              "rgba_bytes": len(frames) * geometry["canvas_px"] ** 2 * 4,
              "rgba_mipmaps_bytes_estimate": len(frames) * geometry["canvas_px"] ** 2 * 4 * 4 / 3,
              "tool_runtime_scale": runtime_scale, "opencv_version": cv2.__version__,
              "selected_sample_count": len(samples), "output_png_count": len(frames),
              "warning": "Technical extraction only; visual pose/scale/contact approval remains required."}
    (out / "extraction.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    previews(frames, output_samples, geometry, np.array(durations) / fps, out)
    print(f"EXTRACT OK: {len(frames)} PNG, {geometry['canvas_px']}px, standing={geometry['standing_height_px']}, "
          f"fill={geometry['figure_fill']:.4f}, duration={sum(durations) / fps:.6f}s, "
          f"pad={qa['minimum_transparent_padding_px']}px")
    return clip, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="New output directory; existing files are never replaced")
    parser.add_argument("--source", type=Path, help="Override local raw-video path, preserving SHA256 verification")
    parser.add_argument("--runtime-scale", type=float, default=1.0,
                        help="Scale standing size and canvas candidates together, e.g. .5 for standing96")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    extract(manifest, args.manifest, args.out, args.source, args.runtime_scale)


if __name__ == "__main__":
    main()
