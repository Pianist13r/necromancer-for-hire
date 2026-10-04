#!/usr/bin/env python3
"""Сверить ботинки до/после полировки без подмены проверки solo-ног.

Один общий affine fit по краям оранжевых ботинок учитывает масштаб и перенос
постобработки. Остаток показывает изменение поз, наклон — поправку к темпу.
Это проверка сохранения движения моделью, не независимый тест футпланта:
взаимно перекрытые ноги здесь не разделяются. Футплант проверять walk_foot_qa.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

from walk_foot_qa import GAME_SCALE


def boot_edges(path):
    a = np.array(Image.open(path).convert('RGBA'))
    rgb = a[:, :, :3].astype(float)
    r, g, b = rgb.transpose(2, 0, 1)
    orange = (r > 170) & (g > 55) & (g < 195) & (b < 105) & (r > g * 1.3)
    orange &= a[:, :, 3] > 100
    orange[:int(a.shape[0] * 0.65)] = False  # каска не участвует
    ys, xs = np.where(orange)
    if not len(xs):
        raise ValueError(f'Оранжевые ботинки не найдены: {path}')
    return [float(xs.min()), float(xs.max())]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('raw')
    ap.add_argument('polished')
    ap.add_argument('--boot-speed', type=float, required=True,
                    help='render px/кадр, среднее двух ног из walk_foot_qa')
    ap.add_argument('--out')
    ap.add_argument('--log', help='drive_log.json для контроля скорости цели IK')
    ap.add_argument('--stance-runs', nargs=2,
                    help='near и far: индексы кадров плоской одиночной опоры через запятую')
    ap.add_argument('--fps', type=float, default=33.57)
    args = ap.parse_args()
    raw = sorted(Path(args.raw).glob('frame_*.png'))
    polished = sorted(Path(args.polished).glob('spr_*.png'))
    if len(raw) != len(polished) or len(raw) < 4:
        raise ValueError('Нужны одинаковые полные циклы')
    x = np.array([boot_edges(p) for p in raw])
    y = np.array([boot_edges(p) for p in polished])
    scale, offset = np.polyfit(x.ravel(), y.ravel(), 1)
    error = y - (x * scale + offset)
    result = {
        'frames': len(raw), 'render_to_sprite_scale': float(scale),
        'offset_sprite_px': float(offset),
        'max_boot_pose_error_game_px': float(np.abs(error).max() * GAME_SCALE),
        'rms_boot_pose_error_game_px': float(np.sqrt(np.mean(error ** 2)) * GAME_SCALE),
        'fps_for_135': float(135 / (args.boot_speed * scale * GAME_SCALE)),
        'method': 'one affine fit of orange boot extrema; footplant requires solo QA',
    }
    if args.stance_runs:
        if not args.log:
            raise ValueError('--stance-runs требует --log')
        feet = json.loads(Path(args.log).read_text(encoding='utf-8'))['feet']
        speeds = []
        result['single_support'] = {}
        for leg, indices in zip(('near', 'far'), args.stance_runs):
            ids = [int(i) for i in indices.split(',')]
            centers = []
            for i in ids:
                a = np.array(Image.open(polished[i]).convert('RGBA'))
                r, g, b = a[:, :, :3].transpose(2, 0, 1).astype(float)
                m = (r > 170) & (g > 55) & (g < 195) & (b < 105) & (r > g * 1.3)
                m &= a[:, :, 3] > 100
                m[:int(a.shape[0] * 0.65)] = False
                ys, xs = np.where(m)
                sel = ys >= ys.max() - 3
                centers.append(float(xs[sel].min() + xs[sel].max()) * 0.5)
            t = np.arange(len(ids))
            line = np.polyfit(t, centers, 1)
            speed = float(-line[0])
            targets = [feet[i][leg + '_x'] for i in ids]
            target_speed = float(-np.polyfit(t, targets, 1)[0]) * scale
            result['single_support'][leg] = {
                'frames': ids, 'boot_vs_ik_ratio': speed / target_speed,
                'speed_game_px_s': speed * GAME_SCALE * args.fps,
                'max_line_error_game_px': float(np.abs(centers - np.polyval(line, t)).max() * GAME_SCALE),
            }
            speeds.append(speed)
        result['fps_for_135_single_support'] = 135 / (float(np.mean(speeds)) * GAME_SCALE)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        Path(args.out).write_text(text, encoding='utf-8')


if __name__ == '__main__':
    main()
