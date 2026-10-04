#!/usr/bin/env python3
"""walk_legs_rig.py — ходьба из ОДНОГО кадра: корпус как есть, ноги рисуются кодом и шагают по земле.

Зачем (Игорь 29.09.2026: «зелёные чуваки в котелках практически не ходят, а просто дрыгаются»):
клипы ходьбы anim_v4 у нотариуса и ещё шести персонажей — одна поза с дрожанием генерации:
опорная ступня не стоит на земле, фигура едет «на коньках» (tools/walk_audit.py: опора 0…0,32),
а живость корпуса (char_view.gd) качает её на месте. Платная перерисовка не нужна: у каждого
персонажа есть чистый кадр в своём стиле; нарисованные ноги ему не нужны — нужен ботинок.

Как устроено (приём скелета v3/v5 — ноги ПОД корпусом, «трубка» под подолом, перекрытие;
docs/ANIM_PIPELINE.md — только без меша и IK):
  * корпус — мастер выше линии подола `cut` (+ предметы в руке ниже неё: `keep` по цвету);
    крошки контура старых ног у линии разреза выкидываются;
  * нога — штанина-трубка от бедра (`hip`, спрятано под подолом) к щиколотке: контур цветом
    обводки мастера, заливка цветом штанов мастера (`fill_at`), тень на задней трети; ширина
    `w_top`→`w_bot`, суперсэмплинг ×4 — край гладкий, как у рисунка. Ботинок — вырезка из
    мастера (`boot`: прямоугольник ниже линии манжеты), выровненный в плоскую стойку
    (`flatten_deg`). Жёстко поворачивать нарисованные ноги пробовали (29.09): косой клин штанов
    не выпрямляется, а ботинок катается по земле — замер опоры это и ловил;
  * опора: щиколотка идёт назад по земле прямой с постоянной скоростью, подошва плоская;
    перенос: вперёд по косинусу, подъём на `lift` px по синусу, носок чуть вниз (`swing_tilt`);
    ноги в противофазе, дальняя притемнена (`far_shade`);
  * стопы стягиваются к общей дорожке (`track_pull`): бёдра чиби разнесены на полкорпуса,
    без стягивания одно касание — «шаг + ширина бёдер», другое — ступни в одной точке (хромота);
  * корпус опускается так, чтобы опорная щиколотка стояла на земле мастера при ноге длины
    `len` — естественный боб (ниже всего на двойной опоре), поэтому motion.bob у этих
    персонажей в CfgAnim = 0;
  * темп из скорости в бою: опорная ступня проходит шаг за полцикла со скоростью
    `support × speed` → fps = кадров / T, T = 2·шаг·масштаб / (support·speed). Скорость, рост и
    figure_fill — tools/walk_audit.py BATTLE (= legion_cfg.gd / cfg_anim.gd). Напечатанный fps
    вписать в CfgAnim *_CLIPS.walk.

Мастер — неизменный кадр anim_v4 (коммит 258a8e0) в tools/walk_rig_masters/<char>.png, разметка —
tools/walk_rig_masters/rig.json. Выход — `godot/assets/anim/<char>/walk/spr_NN.png` (лишние
старые кадры и их .import удаляются) + clip.json (stride — для живости); `idle: true` — ещё кадр
покоя `<char>/idle/spr_00.png` из того же рисунка (счетовод — боец, у него есть покой).

Запуск:  python tools/walk_legs_rig.py signer zombie … [--out ПАПКА] [--dry]
Приёмка: python tools/walk_audit.py; тест — godot/tests/legion_walk_anim_test.gd.
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from walk_audit import BATTLE  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MASTERS = os.path.join(HERE, "walk_rig_masters")
ANIM = os.path.join(HERE, "..", "godot", "assets", "anim")
SS = 4  # суперсэмплинг рисованных штанин


def poly_y(poly: list, xs: np.ndarray) -> np.ndarray:
    """Линия подола: ломаная [[x, y], …] слева направо; y между точками — по x."""
    return np.interp(xs, [p[0] for p in poly], [p[1] for p in poly])


def outline_color(rgba: np.ndarray) -> np.ndarray:
    a = rgba[:, :, 3] > 240
    lum = rgba[:, :, :3].astype(float) @ np.array([0.299, 0.587, 0.114])
    dark = a & (lum < np.percentile(lum[a], 6))
    return np.median(rgba[dark][:, :3], axis=0).astype(np.uint8)


def dilate(m: np.ndarray, r: int) -> np.ndarray:
    out = m.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy <= r * r:
                out |= np.roll(np.roll(m, dy, axis=0), dx, axis=1)
    return out


def keep_mask(rgba: np.ndarray, cfg: dict) -> np.ndarray:
    """Предмет в руке ниже подола (гаечный ключ босса): светлые малонасыщенные пиксели в
    прямоугольнике + их контур — остаются в корпусе."""
    alpha = rgba[:, :, 3] > 0
    keep = np.zeros_like(alpha)
    rgb = rgba[:, :, :3].astype(float) / 255.0
    mx, mn = rgb.max(axis=2), rgb.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    for k in cfg.get("keep", []):
        x0, y0, x1, y1 = k["rect"]
        hit = (sat <= k.get("max_sat", 0.2)) & (mx >= k.get("min_lum", 0.55))
        box = np.zeros_like(alpha)
        box[y0:y1, x0:x1] = True
        keep |= dilate(hit & box, int(k.get("grow", 2))) & box & alpha
    return keep


def to_premul(img: np.ndarray) -> Image.Image:
    return Image.fromarray(img, "RGBA").convert("RGBa")


def rotate_piece(img: np.ndarray, deg: float, pivot: tuple) -> np.ndarray:
    im = to_premul(img).rotate(deg, resample=Image.BICUBIC, center=pivot)
    return np.asarray(im.convert("RGBA"))


def shift(img: np.ndarray, dx: float, dy: float) -> np.ndarray:
    im = to_premul(img).transform(
        (img.shape[1], img.shape[0]), Image.AFFINE, (1, 0, -dx, 0, 1, -dy),
        resample=Image.BICUBIC)
    return np.asarray(im.convert("RGBA"))


def over(dst: np.ndarray, src: np.ndarray) -> np.ndarray:
    """src поверх dst, альфа-композиция."""
    return np.asarray(Image.alpha_composite(Image.fromarray(dst, "RGBA"),
                                            Image.fromarray(src, "RGBA")))


def lowest(img: np.ndarray) -> float:
    rows = np.where((img[:, :, 3] > 128).any(axis=1))[0]
    return float(rows.max()) if len(rows) else 0.0


def leg_pose(u: float, half: float, lift: float) -> tuple:
    """Фаза ноги u∈[0,1): опора 0…0.5 (щиколотка +half → −half по прямой), перенос 0.5…1."""
    if u < 0.5:
        return half - 2.0 * half * (u / 0.5), 0.0, True
    s = (u - 0.5) / 0.5
    return -half + 2.0 * half * (0.5 - 0.5 * math.cos(math.pi * s)), lift * math.sin(math.pi * s), False


def cut_boot(rgba: np.ndarray, bcfg: dict) -> np.ndarray:
    """Ботинок из мастера: прямоугольник ниже линии манжеты, крупнейший связный кусок."""
    h, w = rgba.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    x0, y0, x1, y1 = bcfg["rect"]
    (lx0, ly0), (lx1, ly1) = bcfg["top_line"]
    top = ly0 + (ly1 - ly0) * (xx - lx0) / float(lx1 - lx0)
    m = (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1) & (yy >= top) & (rgba[:, :, 3] > 24)
    lab, n = ndimage.label(m)
    if n > 1:
        sizes = ndimage.sum(m, lab, range(1, n + 1))
        m = lab == (1 + int(np.argmax(sizes)))
    out = np.zeros_like(rgba)
    out[m] = rgba[m]
    return out


def draw_tube(size: tuple, a: tuple, b: tuple, wa: float, wb: float, fill, shade, ink,
              ol: float) -> np.ndarray:
    """Штанина-трубка от бедра a к щиколотке b: контур ink, заливка fill, тень shade сзади."""
    big = Image.new("RGBA", (size[0] * SS, size[1] * SS), (0, 0, 0, 0))
    dr = ImageDraw.Draw(big)
    ax, ay, bx, by = a[0] * SS, a[1] * SS, b[0] * SS, b[1] * SS
    dx, dy = bx - ax, by - ay
    n = math.hypot(dx, dy) or 1.0
    px, py = -dy / n, dx / n     # перпендикуляр

    def quad(w0, w1, off0=0.0, off1=0.0, ext=0.0):
        e0x, e0y = ax - dx / n * ext, ay - dy / n * ext
        e1x, e1y = bx + dx / n * ext, by + dy / n * ext
        return [(e0x + px * (w0 / 2 + off0) * SS, e0y + py * (w0 / 2 + off0) * SS),
                (e1x + px * (w1 / 2 + off1) * SS, e1y + py * (w1 / 2 + off1) * SS),
                (e1x - px * (w1 / 2 - off1) * SS, e1y - py * (w1 / 2 - off1) * SS),
                (e0x - px * (w0 / 2 - off0) * SS, e0y - py * (w0 / 2 - off0) * SS)]
    dr.polygon(quad(wa + 2 * ol, wb + 2 * ol, ext=ol * SS), fill=tuple(ink) + (255,))
    dr.polygon(quad(wa, wb), fill=tuple(fill) + (255,))
    # тень: задняя треть штанины (перпендикуляр при ноге вниз смотрит назад, влево)
    dr.polygon(quad(wa * 0.35, wb * 0.35, off0=wa * 0.325, off1=wb * 0.325),
               fill=tuple(shade) + (255,))
    small = big.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")
    return np.asarray(small)


def render(cfg: dict, master: np.ndarray, frames_n: int, half: float, lift: float,
           stand: bool = False) -> tuple:
    """Кадры цикла (или один кадр покоя при stand) и разнос щиколоток по кадрам."""
    d = cfg["draw"]
    near = cfg.get("near", "front")
    far = "back" if near == "front" else "front"
    offset = {near: 0.0, far: 0.5}   # ближняя нога начинает опору впереди (касание)
    alpha = master[:, :, 3] > 0
    h, w = alpha.shape
    yy = np.mgrid[0:h, 0:w][0]
    cut = poly_y(cfg["cut"], np.arange(w))[None, :]
    body = master.copy()
    body[alpha & (yy >= cut) & ~keep_mask(master, cfg)] = 0
    # крошки контура старых ног у линии разреза стояли бы на месте, пока ноги шагают
    lab, n = ndimage.label(body[:, :, 3] > 0, structure=np.ones((3, 3), bool))
    if n > 1:
        sizes = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
        for k, s in enumerate(sizes, start=1):
            if s < 40:
                body[lab == k] = 0
    ground = lowest(master)
    ink = outline_color(master)
    fill = master[d["fill_at"][1], d["fill_at"][0], :3]
    if "shade_at" in d:
        shade = master[d["shade_at"][1], d["shade_at"][0], :3]
    else:
        shade = (fill.astype(float) * float(d.get("shade_k", 0.78))).astype(np.uint8)
    ank0 = tuple(d["boot"]["ankle"])
    boot = rotate_piece(cut_boot(master, d["boot"]), float(d["boot"].get("flatten_deg", 0.0)), ank0)
    depth = lowest(boot) - ank0[1]
    L = float(d["len"])
    shade_far = float(cfg.get("far_shade", 0.8))
    mid_x = (cfg["hip"]["back"][0] + cfg["hip"]["front"][0]) / 2.0
    track = float(d.get("track_pull", 0.85))
    out, stride = [], []
    for k in range(frames_n):
        ph = k / frames_n
        pose = {}
        for name in ("back", "front"):
            u = (ph + offset[name]) % 1.0
            x, up, stance = (0.0, 0.0, True) if stand else leg_pose(u, half, lift)
            tilt = 0.0 if stance else -float(d.get("swing_tilt", 14.0)) * math.sin(
                math.pi * (u - 0.5) / 0.5)
            pose[name] = (x, up, stance, tilt)
        st = [nm for nm in pose if pose[nm][2]] or list(pose)
        # корпус так, чтобы опорная щиколотка стояла на высоте ground − depth
        dy = min(ground - depth - (cfg["hip"][nm][1] + math.sqrt(max(L * L - pose[nm][0] ** 2, 1.0)))
                 for nm in st)
        body_now = shift(body, 0.0, dy)
        # выше подола нога видна только сквозь корпус: верх трубки, вылезший за силуэт сбоку
        # от подола, срезается — иначе торчит квадратный угол штанины
        hidden = (yy < cut + dy) & ~(body_now[:, :, 3] > 0)
        frame = np.zeros_like(master)
        for name in (far, near):
            x, up, _, tilt = pose[name]
            hx, hy = cfg["hip"][name][0], cfg["hip"][name][1] + dy
            ax = hx + (mid_x - hx) * track + x
            ay = min(hy + math.sqrt(max(L * L - x * x, 1.0)) - up, ground - depth)
            leg = draw_tube((w, h), (hx, hy - d.get("tube_up", 6)), (ax, ay), d["w_top"],
                            d["w_bot"], fill, shade, ink, float(d.get("outline", 2.0)))
            b = shift(rotate_piece(boot, tilt, ank0), ax - ank0[0], ay - ank0[1])
            layer = over(leg, b).copy()
            layer[hidden] = 0
            if name == far:
                layer[:, :, :3] = (layer[:, :, :3].astype(float) * shade_far).astype(np.uint8)
            frame = over(frame, layer)
        out.append(over(frame, body_now))
        stride.append(abs(pose["back"][0] - pose["front"][0]))
    return out, stride


def build(char: str, cfg: dict) -> dict:
    master = np.asarray(Image.open(os.path.join(MASTERS, f"{char}.png")).convert("RGBA")).copy()
    frames_n = int(cfg.get("frames", 16))
    lift = float(cfg.get("lift", 5.0))
    half = float(cfg["draw"]["len"]) * math.sin(math.radians(float(cfg["swing_deg"])))
    out, stride = render(cfg, master, frames_n, half, lift)
    speed, body_h, fill, _ = BATTLE[char]
    scale = body_h / (master.shape[1] * fill)          # px мира на px холста
    support = float(cfg.get("support", 0.9))
    cycle = 2.0 * (2.0 * half) * scale / (support * speed)
    idle = render(cfg, master, 1, half, lift, stand=True)[0][0] if cfg["draw"].get("idle") else None
    if "ground_row" in cfg:
        # земля мастера не всегда там же, где у остальных клипов персонажа (счетовод: мастер
        # стоял на 207, hit/spawn/attack — на 219, и на смене клипа фигура прыгала на 12 px и
        # парила над тенью); ground_row — строка холста, на которой стоят ботинки, целым сдвигом
        dy = int(round(float(cfg["ground_row"]) - lowest(master)))
        out = [shift(f, 0.0, dy) for f in out]
        if idle is not None:
            idle = shift(idle, 0.0, dy)
    mx = max(stride) or 1.0
    meta = {
        "generator": "tools/walk_legs_rig.py", "master": f"tools/walk_rig_masters/{char}.png",
        "loop": True, "fps": round(frames_n / cycle, 2), "cycle_s": round(cycle, 3),
        "step_canvas_px": round(2.0 * half, 2), "support": support,
        "stride": [round(s / mx, 3) for s in stride], "contact_phase": 0.0,
    }
    return {"frames": out, "meta": meta, "idle": idle}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("char", nargs="+")
    ap.add_argument("--out", help="папка вместо godot/assets/anim (кадры в ПАПКА/<char>)")
    ap.add_argument("--dry", action="store_true", help="не писать кадры")
    a = ap.parse_args()
    rig = json.load(open(os.path.join(MASTERS, "rig.json"), encoding="utf-8"))
    for char in a.char:
        res = build(char, rig[char])
        m = res["meta"]
        print(f"{char}: {len(res['frames'])} кадров, fps {m['fps']}, цикл {m['cycle_s']} с, "
              f"шаг {m['step_canvas_px']} px холста")
        if a.dry:
            continue
        dst = os.path.join(a.out, char) if a.out else os.path.join(ANIM, char, "walk")
        os.makedirs(dst, exist_ok=True)
        keep = {f"spr_{i:02d}" for i in range(len(res["frames"]))}
        for f in glob.glob(os.path.join(dst, "spr_*.png*")):
            if os.path.basename(f).split(".png")[0] not in keep:
                os.remove(f)
        for i, fr in enumerate(res["frames"]):
            Image.fromarray(fr, "RGBA").save(os.path.join(dst, f"spr_{i:02d}.png"))
        json.dump(m, open(os.path.join(dst, "clip.json"), "w", encoding="utf-8"), indent=1)
        if res["idle"] is not None:
            # покой бойца — стойка из того же рисунка ног (иначе на остановке ноги «прыгают»
            # из трубок в прежний косой клин штанов)
            idle_dir = os.path.join(a.out, char + "_idle") if a.out else os.path.join(ANIM, char, "idle")
            os.makedirs(idle_dir, exist_ok=True)
            Image.fromarray(res["idle"], "RGBA").save(os.path.join(idle_dir, "spr_00.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
