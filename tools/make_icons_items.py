#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_icons_items.py — иконки ПРЕДМЕТОВ режима «По истечении договора» (items/item_db.gd),
нарисованные кодом на Pillow в той же дизайн-системе, что tools/make_icons_legion.py:
холст 128x128, рисуем в 4x и давим LANCZOS'ом, «наклеечный» тёмно-индиговый контур (INK)
под каждой заливкой. Детерминизм: ни одной случайности, повторный запуск даёт те же PNG.

    python tools/make_icons_items.py [--out godot/assets/legion/icons] [--only id,id]

Файл: item_<id>.png. Новый предмет в реестре — функция здесь и строка в ICONS.
Канцелярская тема: скрепки, печати, бланки, чернила; редкость показывает рамка в игре,
а не иконка — иконку не перекрашиваем под редкость.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_icons_legion import (  # noqa: E402  — общая дизайн-система, не копия
    BIG, BONE, GOLD, INK, SIZE, SOUL_BLUE, SOUL_CORE, canvas, down, outline_and_fill,
)

STEEL = (190, 200, 215, 255)
RED = (205, 55, 50, 255)
WAX = (190, 40, 45, 255)
FIRE = (255, 140, 40, 255)
FIRE_CORE = (255, 225, 120, 255)
BOLT = (200, 225, 255, 255)
WOOD = (150, 95, 60, 255)
PAPER = (240, 234, 214, 255)
PURPLE = (150, 104, 255, 255)
GREEN = (110, 210, 120, 255)
DARK = (58, 54, 72, 255)
STUN = (255, 225, 90, 255)


def P(x: float, y: float) -> tuple[float, float]:
    """Нормированные координаты 0..1 → холст 4x."""
    return (BIG * x, BIG * y)


def R(x0: float, y0: float, x1: float, y1: float) -> list[float]:
    return [BIG * x0, BIG * y0, BIG * x1, BIG * y1]


def sticker(im: Image.Image, fn, color) -> Image.Image:
    return outline_and_fill(im, fn, color)


def ink_line(im: Image.Image, pts, width: float = 0.018, color=INK) -> None:
    ImageDraw.Draw(im).line([P(*p) for p in pts], fill=color, width=int(BIG * width), joint="curve")


def bolt_poly(cx: float, cy: float, s: float):
    pts = [(0.08, -0.38), (-0.12, 0.02), (0.0, 0.02), (-0.08, 0.38), (0.16, -0.06), (0.03, -0.06)]
    return [P(cx + x * s, cy + y * s) for x, y in pts]


def add_bolt(im, cx, cy, s, color=BOLT):
    return sticker(im, lambda d, c: d.polygon(bolt_poly(cx, cy, s), fill=c), color)


def sheet(im, x0=0.24, y0=0.14, x1=0.76, y1=0.86, color=PAPER):
    return sticker(im, lambda d, c: d.rounded_rectangle(R(x0, y0, x1, y1), radius=BIG * 0.04, fill=c), color)


def rubber_stamp(im, cx, cy, s, color):
    def fn(d, c):
        d.ellipse(R(cx - 0.09 * s, cy - 0.34 * s, cx + 0.09 * s, cy - 0.18 * s), fill=c)
        d.rectangle(R(cx - 0.05 * s, cy - 0.22 * s, cx + 0.05 * s, cy + 0.02 * s), fill=c)
        d.rounded_rectangle(R(cx - 0.22 * s, cy + 0.0 * s, cx + 0.22 * s, cy + 0.14 * s), radius=BIG * 0.02, fill=c)
    im = sticker(im, fn, WOOD)
    return sticker(im, lambda d, c: d.rectangle(R(cx - 0.24 * s, cy + 0.13 * s, cx + 0.24 * s, cy + 0.2 * s), fill=c), color)


def star_burst(im, cx, cy, r0, r1, n, color):
    pts = []
    for i in range(n * 2):
        a = math.pi * i / n - math.pi / 2
        r = r1 if i % 2 == 0 else r0
        pts.append(P(cx + math.cos(a) * r, cy + math.sin(a) * r))
    return sticker(im, lambda d, c: d.polygon(pts, fill=c), color)


# ── числа ───────────────────────────────────────────────────────────────────

def clip_of_fate():
    im = canvas()
    def clip(d, c):
        w = int(BIG * 0.05)
        d.rounded_rectangle(R(0.3, 0.12, 0.62, 0.86), radius=BIG * 0.16, outline=c, width=w)
        d.rounded_rectangle(R(0.38, 0.24, 0.56, 0.72), radius=BIG * 0.09, outline=c, width=w)
    im = sticker(im, clip, STEEL)
    return down(add_bolt(im, 0.72, 0.62, 0.55))


def do_not_disturb():
    im = canvas()
    def hanger(d, c):
        d.rounded_rectangle(R(0.28, 0.1, 0.72, 0.9), radius=BIG * 0.05, fill=c)
    im = sticker(im, hanger, RED)
    dl = ImageDraw.Draw(im)
    dl.ellipse(R(0.4, 0.16, 0.6, 0.36), fill=(0, 0, 0, 0))
    dl.ellipse(R(0.4, 0.16, 0.6, 0.36), outline=INK, width=int(BIG * 0.02))
    for i, y in enumerate((0.5, 0.62, 0.74)):
        dl.line([P(0.36, y), P(0.64 - 0.06 * i, y)], fill=BONE, width=int(BIG * 0.035))
    return down(im)


def double_stamp():
    im = canvas()
    im = rubber_stamp(im, 0.38, 0.52, 1.0, PURPLE)
    im = rubber_stamp(im, 0.64, 0.6, 1.0, RED)
    return down(im)


def staff_schedule():
    im = sheet(canvas())
    for x in (0.4, 0.58):
        ink_line(im, [(x, 0.22), (x, 0.8)], 0.012)
    for y in (0.34, 0.48, 0.62):
        ink_line(im, [(0.28, y), (0.72, y)], 0.012)
    dl = ImageDraw.Draw(im)
    for x, y in ((0.49, 0.41), (0.65, 0.55), (0.49, 0.69), (0.33, 0.55)):
        dl.ellipse(R(x - 0.035, y - 0.035, x + 0.035, y + 0.035), fill=GREEN)
    return down(im)


def overtime_sheet():
    im = sheet(canvas(), 0.18, 0.12, 0.66, 0.84)
    for y in (0.28, 0.4, 0.52):
        ink_line(im, [(0.26, y), (0.56, y)], 0.014)
    im = sticker(im, lambda d, c: d.ellipse(R(0.46, 0.46, 0.86, 0.86), fill=c), BONE)
    ink_line(im, [(0.66, 0.66), (0.66, 0.54)], 0.02)
    ink_line(im, [(0.66, 0.66), (0.75, 0.7)], 0.02)
    return down(im)


def coffee_pass():
    im = canvas()
    def cup(d, c):
        d.polygon([P(0.24, 0.4), P(0.7, 0.4), P(0.64, 0.84), P(0.3, 0.84)], fill=c)
        d.ellipse(R(0.62, 0.48, 0.84, 0.7), outline=c, width=int(BIG * 0.05))
    im = sticker(im, cup, BONE)
    dl = ImageDraw.Draw(im)
    dl.ellipse(R(0.27, 0.36, 0.67, 0.46), fill=WOOD)
    for x in (0.36, 0.5):
        dl.arc(R(x - 0.05, 0.12, x + 0.05, 0.34), 270, 90, fill=BONE, width=int(BIG * 0.025))
    return down(im)


def prolongation():
    im = canvas()
    im = sticker(im, lambda d, c: d.rounded_rectangle(R(0.18, 0.2, 0.82, 0.84), radius=BIG * 0.05, fill=c), BONE)
    ImageDraw.Draw(im).rectangle(R(0.18, 0.2, 0.82, 0.36), fill=RED)
    im = sticker(im, lambda d, c: (d.rectangle(R(0.46, 0.44, 0.54, 0.78), fill=c),
                                   d.rectangle(R(0.33, 0.57, 0.67, 0.65), fill=c)), GREEN)
    return down(im)


def punch_knuckles():
    im = canvas()
    def punch(d, c):
        d.rounded_rectangle(R(0.16, 0.56, 0.84, 0.8), radius=BIG * 0.04, fill=c)
        d.polygon([P(0.22, 0.56), P(0.3, 0.3), P(0.8, 0.36), P(0.78, 0.56)], fill=c)
    im = sticker(im, punch, STEEL)
    dl = ImageDraw.Draw(im)
    for x in (0.36, 0.64):
        dl.ellipse(R(x - 0.05, 0.62, x + 0.05, 0.72), fill=INK)
    return down(star_burst(im, 0.26, 0.26, 0.06, 0.13, 6, FIRE))


def precise_ruler():
    im = canvas()
    ruler = [P(0.12, 0.66), P(0.66, 0.12), P(0.88, 0.34), P(0.34, 0.88)]
    im = sticker(im, lambda d, c: d.polygon(ruler, fill=c), GOLD)
    for i in range(1, 9):
        t = i / 9.0
        x, y = 0.12 + (0.66 - 0.12) * t, 0.66 + (0.12 - 0.66) * t
        k = 0.1 if i % 2 == 0 else 0.06
        ink_line(im, [(x, y), (x + k, y + k)], 0.014)
    return down(im)


def fireproof_safe():
    im = canvas()
    im = sticker(im, lambda d, c: d.rounded_rectangle(R(0.16, 0.16, 0.84, 0.86), radius=BIG * 0.05, fill=c), DARK)
    im = sticker(im, lambda d, c: d.ellipse(R(0.34, 0.34, 0.66, 0.66), fill=c), STEEL)
    ink_line(im, [(0.5, 0.5), (0.58, 0.4)], 0.025)
    dl = ImageDraw.Draw(im)
    dl.rectangle(R(0.74, 0.4, 0.8, 0.6), fill=GOLD)
    return down(im)


def quarter_bonus():
    im = canvas()
    im = sticker(im, lambda d, c: d.rectangle(R(0.12, 0.34, 0.76, 0.8), fill=c), PAPER)
    ink_line(im, [(0.12, 0.34), (0.44, 0.6), (0.76, 0.34)], 0.016)
    im = sticker(im, lambda d, c: d.ellipse(R(0.54, 0.16, 0.9, 0.52), fill=c), SOUL_BLUE)
    ImageDraw.Draw(im).ellipse(R(0.64, 0.26, 0.8, 0.42), fill=SOUL_CORE)
    return down(im)


def megaphone():
    im = canvas()
    def cone(d, c):
        d.polygon([P(0.18, 0.42), P(0.36, 0.42), P(0.78, 0.18), P(0.78, 0.82), P(0.36, 0.58), P(0.18, 0.58)], fill=c)
        d.rectangle(R(0.3, 0.58, 0.38, 0.76), fill=c)
    im = sticker(im, cone, RED)
    dl = ImageDraw.Draw(im)
    for r in (0.1, 0.16):
        dl.arc(R(0.8 - r, 0.5 - r, 0.8 + r, 0.5 + r), 300, 60, fill=BONE, width=int(BIG * 0.02))
    return down(im)


def wholesale_ink():
    im = canvas()
    def bottle(d, c):
        d.rounded_rectangle(R(0.22, 0.4, 0.78, 0.86), radius=BIG * 0.08, fill=c)
        d.rectangle(R(0.38, 0.22, 0.62, 0.42), fill=c)
    im = sticker(im, bottle, PURPLE)
    im = sticker(im, lambda d, c: d.rectangle(R(0.34, 0.12, 0.66, 0.24), fill=c), DARK)
    dl = ImageDraw.Draw(im)
    dl.rounded_rectangle(R(0.3, 0.54, 0.7, 0.74), radius=BIG * 0.02, fill=PAPER)
    ink_line(im, [(0.36, 0.64), (0.64, 0.64)], 0.014)
    return down(im)


def bounty_hunter():
    im = canvas()
    im = sticker(im, lambda d, c: d.ellipse(R(0.16, 0.2, 0.84, 0.88), outline=c, width=int(BIG * 0.06)), RED)
    dl = ImageDraw.Draw(im)
    for a, b in (((0.5, 0.16), (0.5, 0.4)), ((0.5, 0.68), (0.5, 0.92)), ((0.12, 0.54), (0.36, 0.54)), ((0.64, 0.54), (0.88, 0.54))):
        dl.line([P(*a), P(*b)], fill=INK, width=int(BIG * 0.03))
    crown = [P(0.34, 0.62), P(0.34, 0.44), P(0.42, 0.52), P(0.5, 0.4), P(0.58, 0.52), P(0.66, 0.44), P(0.66, 0.62)]
    return down(sticker(im, lambda d, c: d.polygon(crown, fill=c), GOLD))


def lost_found():
    im = canvas()
    im = sticker(im, lambda d, c: d.rectangle(R(0.16, 0.34, 0.84, 0.86), fill=c), WOOD)
    im = sticker(im, lambda d, c: d.polygon([P(0.12, 0.34), P(0.3, 0.18), P(0.7, 0.18), P(0.88, 0.34)], fill=c), (180, 120, 75, 255))
    dl = ImageDraw.Draw(im)
    dl.arc(R(0.4, 0.42, 0.6, 0.62), 180, 90, fill=GOLD, width=int(BIG * 0.04))
    dl.line([P(0.5, 0.62), P(0.5, 0.7)], fill=GOLD, width=int(BIG * 0.04))
    dl.ellipse(R(0.47, 0.74, 0.53, 0.8), fill=GOLD)
    return down(im)


# ── поведение ───────────────────────────────────────────────────────────────

def golden_pen():
    im = canvas()
    def pen(d, c):
        d.polygon([P(0.2, 0.8), P(0.28, 0.6), P(0.7, 0.18), P(0.82, 0.3), P(0.4, 0.72)], fill=c)
    im = sticker(im, pen, GOLD)
    ink_line(im, [(0.24, 0.76), (0.36, 0.64)], 0.014)
    return down(star_burst(im, 0.74, 0.74, 0.04, 0.12, 4, (255, 245, 190, 255)))


def piecework_meter():
    im = canvas()
    im = sticker(im, lambda d, c: d.rectangle(R(0.14, 0.18, 0.86, 0.82), outline=c, width=int(BIG * 0.05)), WOOD)
    dl = ImageDraw.Draw(im)
    for j, y in enumerate((0.34, 0.5, 0.66)):
        dl.line([P(0.18, y), P(0.82, y)], fill=INK, width=int(BIG * 0.012))
        for i in range(4):
            x = 0.26 + i * 0.1 + (0.18 if i >= 2 + j % 2 else 0.0)
            dl.ellipse(R(x - 0.04, y - 0.045, x + 0.04, y + 0.045), fill=[RED, GOLD, PURPLE][j], outline=INK)
    return down(im)


def auditor_noose():
    im = canvas()
    im = sticker(im, lambda d, c: d.ellipse(R(0.18, 0.28, 0.72, 0.82), outline=c, width=int(BIG * 0.07)), (200, 160, 100, 255))
    im = sticker(im, lambda d, c: d.rounded_rectangle(R(0.62, 0.12, 0.76, 0.4), radius=BIG * 0.03, fill=c), (200, 160, 100, 255))
    return down(star_burst(im, 0.45, 0.55, 0.05, 0.1, 5, SOUL_BLUE))


def lightning_rod():
    im = canvas()
    im = sticker(im, lambda d, c: (d.rectangle(R(0.22, 0.14, 0.28, 0.86), fill=c),
                                   d.polygon([P(0.18, 0.2), P(0.25, 0.06), P(0.32, 0.2)], fill=c)), STEEL)
    im = add_bolt(im, 0.52, 0.42, 0.6)
    return down(add_bolt(im, 0.74, 0.7, 0.45))


def exploding_stamp():
    im = canvas()
    im = star_burst(im, 0.5, 0.56, 0.2, 0.42, 9, FIRE)
    im = star_burst(im, 0.5, 0.56, 0.12, 0.24, 9, FIRE_CORE)
    return down(rubber_stamp(im, 0.5, 0.46, 0.8, STUN))


def temp_contract():
    im = sheet(canvas(), 0.14, 0.22, 0.62, 0.86)
    for y in (0.38, 0.5, 0.62):
        ink_line(im, [(0.22, y), (0.52, y)], 0.014)
    im = sticker(im, lambda d, c: d.ellipse(R(0.5, 0.44, 0.86, 0.8), fill=c), DARK)
    ink_line(im, [(0.74, 0.46), (0.8, 0.3)], 0.02, WOOD)
    return down(star_burst(im, 0.8, 0.26, 0.03, 0.09, 5, FIRE))


def burning_seal():
    im = canvas()
    im = star_burst(im, 0.5, 0.46, 0.2, 0.36, 7, FIRE)
    im = sticker(im, lambda d, c: d.ellipse(R(0.24, 0.4, 0.76, 0.9), fill=c), WAX)
    ImageDraw.Draw(im).ellipse(R(0.36, 0.52, 0.64, 0.78), outline=BONE, width=int(BIG * 0.018))
    return down(im)


def echo_clause():
    im = sheet(canvas(), 0.12, 0.26, 0.5, 0.82)
    dl = ImageDraw.Draw(im)
    for i, r in enumerate((0.16, 0.26, 0.36)):
        dl.arc(R(0.3 - r, 0.54 - r, 0.3 + r + 0.2, 0.54 + r), 300, 60,
               fill=(190, 160, 255, 255 - i * 50), width=int(BIG * 0.035))
    return down(im)


def roll_call():
    im = canvas()
    def bell(d, c):
        d.polygon([P(0.3, 0.7), P(0.34, 0.36), P(0.5, 0.2), P(0.66, 0.36), P(0.7, 0.7), P(0.8, 0.78), P(0.2, 0.78)], fill=c)
    im = sticker(im, bell, GOLD)
    im = sticker(im, lambda d, c: d.ellipse(R(0.44, 0.76, 0.56, 0.88), fill=c), WOOD)
    return down(star_burst(im, 0.8, 0.26, 0.03, 0.09, 5, STUN))


def ring_lightning():
    im = canvas()
    im = sticker(im, lambda d, c: d.ellipse(R(0.12, 0.2, 0.88, 0.86), outline=c, width=int(BIG * 0.05)), PURPLE)
    return down(add_bolt(im, 0.5, 0.52, 0.9))


def elite_hr():
    im = canvas()
    im = sticker(im, lambda d, c: (d.ellipse(R(0.26, 0.3, 0.74, 0.74), fill=c),
                                   d.rectangle(R(0.36, 0.66, 0.64, 0.84), fill=c)), BONE)
    dl = ImageDraw.Draw(im)
    for x in (0.4, 0.6):
        dl.ellipse(R(x - 0.06, 0.46, x + 0.06, 0.58), fill=INK)
    crown = [P(0.28, 0.32), P(0.28, 0.14), P(0.39, 0.23), P(0.5, 0.08), P(0.61, 0.23), P(0.72, 0.14), P(0.72, 0.32)]
    return down(sticker(im, lambda d, c: d.polygon(crown, fill=c), GOLD))


def soul_magnet():
    im = canvas()
    def magnet(d, c):
        d.arc(R(0.18, 0.3, 0.82, 0.94), 0, 180, fill=c, width=int(BIG * 0.12))
        d.rectangle(R(0.18, 0.3, 0.3, 0.62), fill=c)
        d.rectangle(R(0.7, 0.3, 0.82, 0.62), fill=c)
    im = sticker(im, magnet, RED)
    dl = ImageDraw.Draw(im)
    dl.rectangle(R(0.18, 0.3, 0.3, 0.4), fill=STEEL)
    dl.rectangle(R(0.7, 0.3, 0.82, 0.4), fill=STEEL)
    im = sticker(im, lambda d, c: d.ellipse(R(0.4, 0.08, 0.6, 0.3), fill=c), SOUL_BLUE)
    return down(im)


def quarterly_report():
    im = sheet(canvas(), 0.14, 0.14, 0.86, 0.86)
    dl = ImageDraw.Draw(im)
    for i, h in enumerate((0.2, 0.32, 0.46)):
        x = 0.26 + i * 0.18
        dl.rectangle(R(x, 0.76 - h, x + 0.12, 0.76), fill=[PURPLE, SOUL_BLUE, GREEN][i], outline=INK, width=int(BIG * 0.01))
    ink_line(im, [(0.22, 0.76), (0.8, 0.76)], 0.014)
    return down(im)


def cauldron_ward():
    im = canvas()
    im = sticker(im, lambda d, c: d.ellipse(R(0.16, 0.34, 0.84, 0.86), fill=c), DARK)
    ImageDraw.Draw(im).ellipse(R(0.22, 0.34, 0.78, 0.48), fill=(120, 230, 90, 255))
    im = sticker(im, lambda d, c: d.ellipse(R(0.52, 0.52, 0.86, 0.86), fill=c), WAX)
    return down(star_burst(im, 0.3, 0.2, 0.04, 0.1, 5, STUN))


def named_stamp():
    im = canvas()
    im = rubber_stamp(im, 0.44, 0.5, 1.1, GREEN)
    im = sticker(im, lambda d, c: d.rounded_rectangle(R(0.58, 0.62, 0.9, 0.82), radius=BIG * 0.03, fill=c), PAPER)
    ink_line(im, [(0.63, 0.72), (0.84, 0.72)], 0.014)
    return down(star_burst(im, 0.78, 0.24, 0.03, 0.09, 5, STUN))


def spare_pen():
    im = canvas()
    for flip in (False, True):
        def pen(d, c, f=flip):
            pts = [(0.2, 0.8), (0.28, 0.62), (0.7, 0.2), (0.8, 0.3), (0.38, 0.72)]
            d.polygon([P(1.0 - x if f else x, y) for x, y in pts], fill=c)
        im = sticker(im, pen, BOLT if flip else PURPLE)
    return down(im)


ICONS = {
    "clip_of_fate": clip_of_fate, "do_not_disturb": do_not_disturb, "double_stamp": double_stamp,
    "staff_schedule": staff_schedule, "overtime_sheet": overtime_sheet, "coffee_pass": coffee_pass,
    "prolongation": prolongation, "punch_knuckles": punch_knuckles, "precise_ruler": precise_ruler,
    "fireproof_safe": fireproof_safe, "quarter_bonus": quarter_bonus, "megaphone": megaphone,
    "wholesale_ink": wholesale_ink, "bounty_hunter": bounty_hunter, "lost_found": lost_found,
    "golden_pen": golden_pen, "piecework_meter": piecework_meter, "auditor_noose": auditor_noose,
    "lightning_rod": lightning_rod, "exploding_stamp": exploding_stamp, "temp_contract": temp_contract,
    "burning_seal": burning_seal, "echo_clause": echo_clause, "roll_call": roll_call,
    "ring_lightning": ring_lightning, "elite_hr": elite_hr, "soul_magnet": soul_magnet,
    "quarterly_report": quarterly_report, "cauldron_ward": cauldron_ward, "named_stamp": named_stamp,
    "spare_pen": spare_pen,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="godot/assets/legion/icons")
    ap.add_argument("--only", default="", help="через запятую: только эти id")
    ap.add_argument("--sheet", default="", help="путь PNG: контактный лист всех иконок (для приёмки)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    only = {s for s in a.only.split(",") if s}
    made = []
    for name, fn in ICONS.items():
        if only and name not in only:
            continue
        im = fn()
        assert im.size == (SIZE, SIZE), name
        path = os.path.join(a.out, f"item_{name}.png")
        im.save(path)
        made.append((name, im))
        print(name, "->", path)
    if a.sheet:
        cols = 8
        rows = (len(made) + cols - 1) // cols
        sheet_im = Image.new("RGBA", (cols * (SIZE + 8), rows * (SIZE + 8)), (40, 34, 48, 255))
        for i, (_, im) in enumerate(made):
            sheet_im.alpha_composite(im, ((i % cols) * (SIZE + 8) + 4, (i // cols) * (SIZE + 8) + 4))
        sheet_im.save(a.sheet)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
