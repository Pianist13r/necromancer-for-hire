"""Geometry regressions: direction, knee anatomy, contact, and loop continuity."""
import unittest
import json
import tempfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
if __package__:
    from .directional_walk_rig import DIRECTIONS, forward, project, foot_phase, knee_ik, frame, keyed, warped_segment, normalize, piece
else:
    from directional_walk_rig import DIRECTIONS, forward, project, foot_phase, knee_ik, frame, keyed, warped_segment, normalize, piece


class DirectionalGaitTest(unittest.TestCase):
    def test_reviewed_foot_anchor_excludes_low_accessory_and_checks_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp)
            image=Image.new('RGBA',(256,256))
            draw=ImageDraw.Draw(image)
            draw.ellipse((80,32,210,194),fill=(90,70,130,255))
            draw.rectangle((160,190,180,223),fill=(30,20,50,255))
            draw.rectangle((40,180,80,220),fill=(50,30,80,255))
            image.save(base/'master.png')
            (base/'manifest.json').write_text(json.dumps({'files':{'e':str(base/'master.png')}}))
            (base/'foot_anchors.json').write_text(json.dumps({'e':{'source_name':'master.png','source_x':170}}))
            normalize(base/'manifest.json',base)
            result=np.array(Image.open(base/'e.png'))
            xx=np.where(result[223,:,3]>128)[0]
            self.assertEqual((xx.min()+xx.max())/2,128)
            (base/'foot_anchors.json').write_text(json.dumps({'e':{'source_name':'stale.png','source_x':170}}))
            with self.assertRaises(ValueError):
                normalize(base/'manifest.json',base)

    def test_remaining_boot_masks_do_not_include_second_shoe(self):
        base=Path(__file__).parent/'walk_rig_masters/directional'
        for char in ('beetle','mimic','lawyer','boss'):
            settings=json.loads((base/char/'rig.json').read_text())
            for d,rig in settings['views'].items():
                master=Image.open(base/char/f'{d}.png').convert('RGBA')
                for index,leg in enumerate(rig['legs']):
                    with self.subTest(character=char,direction=d,leg=index):
                        alpha=np.array(piece(master,leg['boot_polygon']))[...,3]>64
                        labels,_=ndimage.label(alpha)
                        counts=np.bincount(labels.ravel())[1:]
                        self.assertEqual(sum(counts>12),1)
    def test_drawn_bone_segment_rotates_and_keeps_its_width(self):
        source = Image.new('RGBA',(32,32))
        ImageDraw.Draw(source).rectangle((4,5,6,15),fill=(255,240,180,255))
        result = warped_segment(source,[5,5],[5,15],np.array([10,10]),np.array([20,10]))
        yy,xx=np.where(np.asarray(result)[...,3]>128)
        self.assertGreater(xx.max()-xx.min(),yy.max()-yy.min())
        self.assertLessEqual(yy.max()-yy.min(),3)
        self.assertGreater(np.asarray(result)[10,15,3],128)
    def test_floating_art_preserved_without_legs_or_double_motion(self):
        master = Image.new('RGBA', (256,256))
        ImageDraw.Draw(master).ellipse((64,32,192,224),fill=(140,220,205,255))
        # No hip/boot/body_polygon annotations: ghost must preserve all artwork.
        rig = {'mode':'float','direction':'n'}
        for phase in (0,.25,.5,.75):
            result, traces = frame(master,rig,phase)
            np.testing.assert_array_equal(result,master)
            self.assertEqual(traces,[])
        lifted, _ = frame(master,dict(rig,float_px=6),.5)
        source_y = np.where(np.asarray(master)[...,3]>128)[0].min()
        result_y = np.where(np.asarray(lifted)[...,3]>128)[0].min()
        self.assertEqual(source_y-result_y,6)
    def test_projected_heading_matches_all_five_views(self):
        for name, direction in DIRECTIONS.items():
            projected = project(forward(name, .6), .6)
            expected = np.array(direction, dtype=float)
            expected /= np.linalg.norm(expected)
            np.testing.assert_allclose(projected / np.linalg.norm(projected), expected)

    def test_stance_world_foot_remains_planted(self):
        for direction in DIRECTIONS:
            fwd = forward(direction, .6)
            velocity = project(fwd, .6) * 4 * 12
            feet = []
            for t in np.linspace(0, .49, 50):
                stride, lift, support = foot_phase(t, 12, 8)
                self.assertTrue(support)
                self.assertEqual(lift, 0)
                feet.append(project(fwd * stride, .6) + velocity * t)
            np.testing.assert_allclose(feet, np.repeat([feet[0]], len(feet), axis=0), atol=1e-12)

    def test_fixed_bones_and_forward_knee_in_all_views(self):
        hip = np.array([0., 0., 30.])
        for direction in DIRECTIONS:
            fwd = forward(direction, .6)
            for phase in np.linspace(0, 1, 100, endpoint=False):
                stride, lift, _ = foot_phase(phase, 12, 8)
                ankle = fwd * stride + [0, 0, lift]
                knee = knee_ik(hip, ankle, 20, 20, fwd)
                self.assertAlmostEqual(np.linalg.norm(knee - hip), 20)
                self.assertAlmostEqual(np.linalg.norm(knee - ankle), 20)
                midpoint = (hip + ankle) / 2
                self.assertGreater(np.dot(knee - midpoint, fwd), 0)
                if direction in ("s", "n"):
                    self.assertAlmostEqual(knee[0], 0)

    def test_continuous_contact_and_loop(self):
        for phase in (0, .5, 1):
            before = foot_phase(phase - 1e-7, 12, 8)[:2]
            after = foot_phase(phase + 1e-7, 12, 8)[:2]
            np.testing.assert_allclose(before, after, atol=1e-5)
        self.assertTrue(foot_phase(0, 12, 8)[2])
        self.assertFalse(foot_phase(.5, 12, 8)[2])

    def test_unreachable_leg_rejected(self):
        with self.assertRaises(ValueError):
            knee_ik(np.array([0., 0., 30.]), np.array([0., 0., 0.]), 10, 10, np.array([1., 0., 0.]))

    def test_measured_chromakey_removes_spill_preserves_dark_outline(self):
        rgb = np.empty((32, 32, 3), dtype=np.uint8)
        bg = np.array([181, 15, 143])
        ink = np.array([29, 15, 68])
        rgb[:] = bg
        rgb[8:24, 8:24] = ink
        rgb[7, 8:24] = (bg + ink) / 2
        result = np.asarray(keyed(Image.fromarray(rgb)))
        self.assertEqual(result[0, 0, 3], 0)
        self.assertEqual(result[15, 15, 3], 255)
        self.assertLess(abs(int(result[7, 15, 3]) - 128), 4)
        np.testing.assert_allclose(result[7, 15, :3], ink, atol=2)

    def test_existing_alpha_is_preserved_without_second_chromakey(self):
        image = Image.new('RGBA',(8,8),(29,15,68,128))
        image.putpixel((0,0),(0,0,0,0))
        np.testing.assert_array_equal(keyed(image),image)

    def test_approved_zombie_all_frames_are_connected_and_inside_canvas(self):
        folder = Path(__file__).parent / 'walk_rig_masters/directional/zombie'
        settings = json.loads((folder / 'rig.json').read_text())
        for direction, annotation in settings['views'].items():
            rig = dict(settings['gait'], **annotation, direction=direction)
            master = Image.open(folder / f'{direction}.png').convert('RGBA')
            for i in range(16):
                with self.subTest(direction=direction, frame=i):
                    image, traces = frame(master, rig, i / 16)
                    alpha = np.asarray(image)[..., 3] > 64
                    ys, xs = np.where(alpha)
                    self.assertGreater(xs.min(), 1)
                    self.assertGreater(ys.min(), 1)
                    self.assertLess(xs.max(), 254)
                    self.assertLess(ys.max(), 254)
                    components, _ = ndimage.label(alpha)
                    counts = np.bincount(components.ravel())[1:]
                    # Antialias specks may separate at the pixel threshold; a
                    # detached boot/leg is a meaningful second component.
                    self.assertEqual(sum(counts > 12), 1)
                    for leg, trace in zip(rig['legs'], traces):
                        hip, knee, ankle = map(np.array, (trace['hip'],trace['knee'],trace['ankle']))
                        self.assertAlmostEqual(np.linalg.norm(knee-hip), leg['links'][0])
                        self.assertAlmostEqual(np.linalg.norm(knee-ankle), leg['links'][1])


if __name__ == '__main__':
    unittest.main()
