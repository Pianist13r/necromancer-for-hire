"""Independent runtime footplant/timing regression (not an image similarity verdict)."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WalkContactTest(unittest.TestCase):
    def test_contact_speed_matches_translation(self):
        for path in sorted((ROOT / "tools/walk_rig_masters/directional").glob("*/rig.json")):
            data = json.loads(path.read_text(encoding="utf-8"))
            if data["gait"].get("mode") == "float":
                continue
            for direction, view in data["views"].items():
                rig = dict(data["gait"], **view)
                with self.subTest(character=data["character"], direction=direction):
                    # Derivative of the planted IK target; alpha-edge correlation cannot
                    # distinguish front/back shoes reliably in vertical views.
                    speed = 4 * rig["screen_half_stride"] * data["body_h"] / data.get("standing_height_px", 192) / rig["cycle"]
                    self.assertAlmostEqual(speed / data["speed"], 1.0, delta=.05)
                    folder = ROOT / "godot/assets/anim" / data["character"] / f"walk_{direction}"
                    meta = json.loads((folder / "clip.json").read_text(encoding="utf-8"))
                    self.assertAlmostEqual(meta["duration"], rig["cycle"], places=5)
                    self.assertAlmostEqual(meta["support_ratio"], speed / data["speed"], places=5)


if __name__ == "__main__":
    unittest.main()
