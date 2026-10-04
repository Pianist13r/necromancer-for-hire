"""Offline regressions for extraction geometry, real video sampling, keying and retiming."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import cv2
import numpy as np
from PIL import Image

from directional_motion_extract import collapse_exact, extract, ground_anchor, key_frame, layout, transform_frame, verify


class ExtractTests(unittest.TestCase):
    def test_exact_collapse_preserves_duration_and_contact_boundary(self):
        first = np.zeros((2, 2, 4), dtype=np.uint8)
        last = np.ones((2, 2, 4), dtype=np.uint8)
        frames = [first, first.copy(), first.copy(), last, last.copy()]
        samples = [{"frame": n} for n in range(5)]
        kept, durations, groups, contact = collapse_exact(frames, [.2, .3, .4, .5, .6], samples, 2)
        self.assertEqual(len(kept), 3, "identical contact texture still needs its own timing boundary")
        self.assertEqual(contact, 1)
        self.assertAlmostEqual(sum(durations[:contact]), .5)
        self.assertAlmostEqual(sum(durations), 2)
        self.assertEqual(groups, [samples[:2], samples[2:3], samples[3:]])

    def frames(self):
        frames = []
        for index in range(4):
            rgb = np.full((480, 480, 3), [185, 12, 128], dtype=np.uint8)
            cv2.ellipse(rgb, (220, 330), (100, 18), 0, 0, 360, (78, 5, 54), -1)
            if index == 0:
                cv2.rectangle(rgb, (170, 110), (230, 310), (80, 200, 175), -1)
            else:
                cv2.rectangle(rgb, (120, 270), (340, 310), (80, 200, 175), -1)
            # A detached prop must survive: never keep only the largest component.
            cv2.rectangle(rgb, (350, 145), (368, 180), (45, 230, 65), -1)
            frames.append(rgb)
        return frames

    def test_border_hue_shadow_and_detached_prop(self):
        rgba, metadata = key_frame(self.frames()[0], {})
        self.assertGreater(metadata["hue_degrees"], 290)
        self.assertLess(metadata["hue_degrees"], 335)
        self.assertEqual(int(rgba[340, 220, 3]), 0, "dark key-colored shadow was retained")
        self.assertEqual(int(rgba[160, 359, 3]), 255, "detached prop was discarded")
        self.assertEqual(int(rgba[200, 200, 3]), 255)

    def test_key_preserves_dark_purple_outline_with_background_hue(self):
        rgb = self.frames()[0]
        # Both colors share pink hue; the outline's lower chroma is foreground.
        cv2.rectangle(rgb, (170, 110), (230, 310), (60, 29, 52), -1)
        cv2.rectangle(rgb, (175, 115), (225, 305), (34, 12, 28), 3)
        rgba, metadata = key_frame(rgb, {})
        self.assertGreater(metadata["minimum_key_saturation"], 180)
        self.assertEqual(int(rgba[200, 200, 3]), 255)
        self.assertEqual(int(rgba[150, 175, 3]), 255)
        self.assertEqual(int(rgba[340, 220, 3]), 0, "saturated dark key shadow must still disappear")
        matrix, geometry = layout(rgba, [rgba], {})
        report = verify([transform_frame(rgba, matrix, geometry["canvas_px"])], geometry, [metadata])
        self.assertEqual(report["key_colored_visible_fraction"], 0, "real purple foreground is not a BG residual")

    def test_enclosed_dark_ink_survives_but_bright_prop_hole_stays_transparent(self):
        rgb = self.frames()[0]
        cv2.circle(rgb, (200, 200), 8, (50, 2, 37), -1)
        rgb[151:174, 355:363] = [185, 12, 128]
        rgba, _ = key_frame(rgb, {})
        self.assertEqual(int(rgba[200, 200, 3]), 255, "dark enclosed ink must not become a transparent eye")
        self.assertEqual(int(rgba[160, 359, 3]), 0, "bright backdrop through a prop ring is still background")
        self.assertEqual(int(rgba[340, 220, 3]), 0, "exterior key shadow is not enclosed ink")

    def test_fixed_scale_union_and_half_runtime(self):
        rgba = [key_frame(frame, {})[0] for frame in self.frames()]
        matrix, geometry = layout(rgba[0], rgba[1:], {})
        self.assertGreater(geometry["canvas_px"], 256, "lying body/prop should enlarge canvas")
        first_box = geometry["source_standing_bbox"]
        self.assertAlmostEqual(geometry["scale"] * (first_box[3] - first_box[1]), 192)
        anchor = np.array([*geometry["source_pivot_px"], 1])
        np.testing.assert_allclose(matrix @ anchor, geometry["pivot_px"], atol=0.001)
        half_matrix, half = layout(rgba[0], rgba[1:], {}, runtime_scale=0.5)
        self.assertAlmostEqual(half["scale"], geometry["scale"] * 0.5)
        self.assertAlmostEqual(half["figure_fill"] * half["canvas_px"], 96)
        for frame in rgba:
            output = transform_frame(frame, half_matrix, half["canvas_px"])
            self.assertEqual(output.shape, (half["canvas_px"], half["canvas_px"], 4))
        self.assertEqual(ground_anchor(rgba[0], first_box)[1], first_box[3])

    def test_prop_does_not_change_reviewed_body_scale(self):
        rgba = [key_frame(frame, {})[0] for frame in self.frames()]
        matrix, geometry = layout(rgba[0], rgba[1:], {"source_standing_bbox": [170, 110, 231, 311]})
        self.assertAlmostEqual(geometry["scale"], 192 / 201)
        prop_point = matrix @ np.array([359, 160, 1])
        output = transform_frame(rgba[0], matrix, geometry["canvas_px"])
        self.assertGreater(output[round(prop_point[1]), round(prop_point[0]), 3], 250)

    def fixture(self, directory):
        source = directory / "synthetic.avi"
        writer = cv2.VideoWriter(str(source), cv2.VideoWriter_fourcc(*"MJPG"), 30, (480, 480))
        self.assertTrue(writer.isOpened())
        for rgb in self.frames():
            writer.write(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
        writer.release()
        return {"source_video": str(source), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "source_fps": 30, "state": "attack", "direction": "e", "fps": 15,
                "total_seconds": 0.4, "contact_frame": 1,
                "samples": [{"frame": index, "seconds": index / 30, "duration_weight": weight}
                            for index, weight in [(0, 1), (1, 2), (3, 1)]]}

    def test_real_video_sample_manifest_and_durations(self):
        with tempfile.TemporaryDirectory(prefix="necro-motion-test-") as scratch:
            directory = Path(scratch)
            manifest = self.fixture(directory)
            clip, report = extract(manifest, directory / "input.json", directory / "out")
            self.assertEqual(clip["durations"], [1.5, 3.0, 1.5])
            self.assertAlmostEqual(sum(clip["durations"]) / clip["fps"], 0.4)
            self.assertEqual(clip["contact_frame"], 1)
            self.assertEqual(clip["direction"], [1.0, 0.0])
            self.assertEqual(clip["direction_name"], "e")
            self.assertEqual(clip["source_frames"], manifest["samples"])
            self.assertEqual(report["qa"]["scale_reference_frame"], 0)
            self.assertLessEqual(clip["normalization"]["source_standing_bbox"][3], 314,
                                 "JPEG shadow residue must not move standing feet from body bottom310")
            self.assertEqual(report["qa"]["key_colored_visible_fraction"], 0)
            self.assertGreaterEqual(report["qa"]["minimum_transparent_padding_px"], 16)
            duration = 0
            with Image.open(directory / "out" / "preview_runtime.gif") as gif:
                for index in range(gif.n_frames):
                    gif.seek(index)
                    duration += gif.info["duration"]
            self.assertEqual(duration, 400)
            self.assertEqual(json.loads((directory / "out" / "clip.json").read_text())["contact_frame"], 1)
            # Repeated decode/transform emits the same runtime PNG bytes.
            extract(manifest, directory / "input.json", directory / "again")
            for path in (directory / "out").glob("spr_*.png"):
                self.assertEqual(path.read_bytes(), (directory / "again" / path.name).read_bytes())
            with self.assertRaises(FileExistsError):
                extract(manifest, directory / "input.json", directory / "out")

    def test_invalid_source_identity_or_frame_time_fails_before_output(self):
        with tempfile.TemporaryDirectory(prefix="necro-motion-test-") as scratch:
            directory = Path(scratch)
            original = self.fixture(directory)
            for change in [{"source_sha256": "0" * 64},
                           {"samples": [{"frame": 1, "seconds": 0.5}]},
                           {"samples": [{"frame": 1.5, "seconds": 1 / 30}]}]:
                manifest = original | change
                with self.assertRaises(ValueError):
                    extract(manifest, directory / "input.json", directory / "bad")
                self.assertFalse((directory / "bad").exists())

    def test_real_video_exact_duplicates_remap_contact_and_keep_source_provenance(self):
        with tempfile.TemporaryDirectory(prefix="necro-motion-test-") as scratch:
            directory = Path(scratch)
            manifest = self.fixture(directory)
            manifest.update(collapse_exact_duplicates=True, contact_frame=2,
                            samples=[{"frame": n, "seconds": n / 30} for n in [0, 0, 1, 1, 3]])
            clip, report = extract(manifest, directory / "input.json", directory / "out")
            self.assertEqual(len(list((directory / "out").glob("spr_*.png"))), 2)
            self.assertEqual(clip["contact_frame"], 1)
            self.assertAlmostEqual(sum(clip["durations"][:1]) / clip["fps"], .16)
            self.assertAlmostEqual(sum(clip["durations"]) / clip["fps"], .4)
            self.assertEqual([len(group) for group in clip["source_sample_groups"]], [2, 3])
            self.assertEqual(report["selected_sample_count"], 5)
            self.assertEqual(report["output_png_count"], 2)

    def test_reverse_recovery_requires_explicit_flag_and_keeps_contact_time(self):
        with tempfile.TemporaryDirectory(prefix="necro-motion-test-") as scratch:
            directory = Path(scratch)
            manifest = self.fixture(directory)
            manifest.update(contact_frame=2, collapse_exact_duplicates=True,
                            samples=[{"frame": n, "seconds": n / 30} for n in [0, 1, 3, 1, 0]])
            for flag in [None, False, "true"]:
                manifest["allow_reverse_samples"] = flag
                with self.assertRaises(ValueError):
                    extract(manifest, directory / "input.json", directory / "bad")
                self.assertFalse((directory / "bad").exists())
            manifest["allow_reverse_samples"] = True
            clip, _ = extract(manifest, directory / "input.json", directory / "out")
            self.assertEqual(clip["contact_frame"], 2, "identical pre-contact texture must not swallow impact")
            self.assertAlmostEqual(sum(clip["durations"][:2]) / clip["fps"], .16)
            self.assertAlmostEqual(sum(clip["durations"]) / clip["fps"], .4)
            flattened = [sample["frame"] for group in clip["source_sample_groups"] for sample in group]
            self.assertEqual(flattened, [0, 1, 3, 1, 0])

    def test_clipped_source_or_insufficient_canvas_is_rejected(self):
        rgb = self.frames()[0]
        rgb[:, 0:5] = [80, 200, 175]
        with self.assertRaises(ValueError):
            key_frame(rgb, {})
        rgba = [key_frame(frame, {})[0] for frame in self.frames()]
        with self.assertRaises(ValueError):
            layout(rgba[0], rgba[1:], {"canvas_sizes": [128]})


if __name__ == "__main__":
    unittest.main()
