#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_icons_legion.py — иконки HUD режима «По истечении договора», нарисованные КОДОМ
на Pillow (пакет art1, v15). Тот же метод, что tools/make_icons.py (SPEC §3: иконки
рисуются кодом, не генерацией — детерминизм и воспроизводимость важнее скорости).

    python tools/make_icons_legion.py [--out godot/assets/legion/icons] [--check]

ДИЗАЙН-СИСТЕМА (те же рамки, что у make_icons.py):
  * Холст RGBA 128x128, углы прозрачны. Рисуем в 4x (512x512) и давим LANCZOS'ом —
    сглаживание без сторонних либ. Даунскейл через premultiplied "RGBa".
  * Единый «наклеечный» контур: тёмный индиго (INK), затем заливка поверх.
  * Три вида договора — цвет вида из LegionCfg.UNIT_KINDS (с 26.09 — цвет бойца: подряда
    оранжевый, охраны синий, аудита изумрудно-бирюзовый); способности и души/премия — свои.
"""

from __future__ import annotations

import argparse
import math
import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 128
S = 4
BIG = SIZE * S
OUTLINE = int(3 * (SIZE / 160) * S / 1)  # тот же относительный нарост контура, что в make_icons.py (3px @160)
OUTLINE = max(2 * S, int(round(3 * S * SIZE / 160)))

INK = (24, 24, 48, 255)          # #181830
BONE = (240, 240, 216, 255)      # #f0f0d8

# Печать договора — цвет вида из LegionCfg.UNIT_KINDS[kind]["color"] (26.09: цвет снят с кадров
# бойца, tools/kind_colors.py): каска подрядчика, форма вахтёра, козырёк счетовода.
LABORER_C = (255, 143, 36, 255)  # #ff8f24 — подряда (каска)
GUARD_C = (92, 143, 245, 255)    # #5c8ff5 — охраны (форма)
CLERK_C = (51, 214, 163, 255)    # #33d6a3 — аудита (козырёк)
GOLD = (240, 178, 60, 255)       # премия
SOUL_BLUE = (90, 170, 255, 255)  # души
SOUL_CORE = (220, 240, 255, 255)


def canvas() -> Image.Image:
    return Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))


def down(im: Image.Image) -> Image.Image:
    return im.convert("RGBa").resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")


def stroke_poly(d: ImageDraw.ImageDraw, pts, fill):
    """Наклеечный контур: тёмный INK-полигон шире на OUTLINE, потом заливка поверх."""
    d.polygon(pts, fill=INK)


def outline_and_fill(base: Image.Image, draw_fn, fill_color) -> Image.Image:
    """draw_fn(draw, scale) рисует силуэт; сначала INK-версия раздутая блюром, потом сама фигура."""
    ink_layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    di = ImageDraw.Draw(ink_layer)
    draw_fn(di, INK)
    ink_layer = ink_layer.filter(ImageFilter.MaxFilter(OUTLINE * 2 + 1))
    base.alpha_composite(ink_layer)
    fill_layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    df = ImageDraw.Draw(fill_layer)
    draw_fn(df, fill_color)
    base.alpha_composite(fill_layer)
    return base


def icon_contract(color) -> Image.Image:
    """Значок вида договора: свиток с восковой печатью цвета вида (единый для 3 видов)."""
    im = canvas()
    cx, cy = BIG * 0.5, BIG * 0.52

    def scroll(d: ImageDraw.ImageDraw, col):
        w, h = BIG * 0.62, BIG * 0.44
        x0, y0 = cx - w / 2, cy - h / 2
        d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=BIG * 0.05, fill=col)
        # рулоны по бокам (цилиндры свитка)
        for ex in (x0, x0 + w):
            d.ellipse([ex - BIG * 0.045, y0 - BIG * 0.02, ex + BIG * 0.045, y0 + h + BIG * 0.02], fill=col)

    im = outline_and_fill(im, scroll, BONE)
    # строки текста на свитке
    dl = ImageDraw.Draw(im)
    for i, frac in enumerate((0.42, 0.5, 0.58)):
        y = cy + (frac - 0.5) * BIG * 0.44
        dl.line([cx - BIG * 0.16, y, cx + BIG * 0.16, y], fill=INK, width=int(BIG * 0.012))
    # восковая печать поверх, цвет вида
    seal_r = BIG * 0.19
    seal_c = (cx + BIG * 0.02, cy + BIG * 0.03)

    def seal(d: ImageDraw.ImageDraw, col):
        d.ellipse([seal_c[0] - seal_r, seal_c[1] - seal_r, seal_c[0] + seal_r, seal_c[1] + seal_r], fill=col)

    im = outline_and_fill(im, seal, color)
    dl = ImageDraw.Draw(im)
    dl.ellipse([seal_c[0] - seal_r * 0.55, seal_c[1] - seal_r * 0.55,
                seal_c[0] + seal_r * 0.55, seal_c[1] + seal_r * 0.55], outline=BONE, width=int(BIG * 0.014))
    return down(im)


def icon_ability_q() -> Image.Image:
    """Ку — Разряд: зигзаг-молния (акцент подряда/электричество — холодный голубой)."""
    im = canvas()
    bolt = (200, 225, 255, 255)
    pts = [
        (BIG * 0.58, BIG * 0.12), (BIG * 0.38, BIG * 0.52), (BIG * 0.5, BIG * 0.52),
        (BIG * 0.42, BIG * 0.9), (BIG * 0.66, BIG * 0.46), (BIG * 0.53, BIG * 0.46),
    ]

    def bolt_fn(d: ImageDraw.ImageDraw, col):
        d.polygon(pts, fill=col)

    im = outline_and_fill(im, bolt_fn, bolt)
    return down(im)


def icon_ability_w() -> Image.Image:
    """Дубль-вэ — Оформление в штат: поднятый труп-скелет с нагрудным бейджем."""
    im = canvas()
    body = BONE

    def figure(d: ImageDraw.ImageDraw, col):
        cx = BIG * 0.5
        d.ellipse([cx - BIG * 0.14, BIG * 0.14, cx + BIG * 0.14, BIG * 0.4], fill=col)  # череп
        d.rounded_rectangle([cx - BIG * 0.16, BIG * 0.38, cx + BIG * 0.16, BIG * 0.78],
                             radius=BIG * 0.06, fill=col)  # торс
        # руки в стороны, поднят
        d.line([cx - BIG * 0.16, BIG * 0.46, cx - BIG * 0.34, BIG * 0.3], fill=col, width=int(BIG * 0.06))
        d.line([cx + BIG * 0.16, BIG * 0.46, cx + BIG * 0.34, BIG * 0.3], fill=col, width=int(BIG * 0.06))

    im = outline_and_fill(im, figure, body)
    dl = ImageDraw.Draw(im)
    # глаза-точки
    cx = BIG * 0.5
    for ex in (cx - BIG * 0.05, cx + BIG * 0.05):
        dl.ellipse([ex - BIG * 0.02, BIG * 0.24, ex + BIG * 0.02, BIG * 0.28 + BIG * 0.02], fill=INK)
    # бейдж на груди — золотой прямоугольник
    bx0, by0 = cx - BIG * 0.09, BIG * 0.54
    dl.rounded_rectangle([bx0, by0, bx0 + BIG * 0.18, by0 + BIG * 0.12], radius=BIG * 0.02, fill=GOLD, outline=INK,
                          width=int(BIG * 0.012))
    return down(im)


def icon_ability_e() -> Image.Image:
    """Е — Аврал: будильник с ножками-звонками (оперативность/спешка)."""
    im = canvas()
    face = (255, 168, 75, 255)  # смягчённый оранжевый (как ability_e в старом наборе)
    cx, cy = BIG * 0.5, BIG * 0.56
    r = BIG * 0.28

    def clock(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
        # звонки сверху
        for ex, ang in ((cx - r * 0.75, -35), (cx + r * 0.75, 35)):
            d.ellipse([ex - BIG * 0.06, cy - r - BIG * 0.1, ex + BIG * 0.06, cy - r + BIG * 0.02], fill=col)
        # ножки
        d.line([cx - r * 0.6, cy + r * 0.85, cx - r * 0.85, cy + r * 1.15], fill=col, width=int(BIG * 0.045))
        d.line([cx + r * 0.6, cy + r * 0.85, cx + r * 0.85, cy + r * 1.15], fill=col, width=int(BIG * 0.045))

    im = outline_and_fill(im, clock, face)
    dl = ImageDraw.Draw(im)
    # стрелки
    dl.line([cx, cy, cx, cy - r * 0.55], fill=INK, width=int(BIG * 0.022))
    dl.line([cx, cy, cx + r * 0.4, cy + r * 0.15], fill=INK, width=int(BIG * 0.022))
    dl.ellipse([cx - BIG * 0.015, cy - BIG * 0.015, cx + BIG * 0.015, cy + BIG * 0.015], fill=INK)
    return down(im)


def icon_soul() -> Image.Image:
    """Душа — синий огонёк со светлым ядром (внутрибоевая валюта)."""
    im = canvas()
    cx, cy = BIG * 0.5, BIG * 0.56

    def flame(d: ImageDraw.ImageDraw, col):
        pts = [
            (cx, cy - BIG * 0.34), (cx + BIG * 0.16, cy - BIG * 0.06), (cx + BIG * 0.14, cy + BIG * 0.2),
            (cx, cy + BIG * 0.32), (cx - BIG * 0.14, cy + BIG * 0.2), (cx - BIG * 0.16, cy - BIG * 0.06),
        ]
        d.polygon(pts, fill=col)

    im = outline_and_fill(im, flame, SOUL_BLUE)
    glow = Image.new("RGBA", im.size, (0, 0, 0, 0))
    dg = ImageDraw.Draw(glow)
    dg.ellipse([cx - BIG * 0.09, cy - BIG * 0.02, cx + BIG * 0.09, cy + BIG * 0.18], fill=SOUL_CORE)
    glow = glow.filter(ImageFilter.GaussianBlur(BIG * 0.01))
    im.alpha_composite(glow)
    return down(im)


def icon_premium() -> Image.Image:
    """Премия — золотая монета с оттиском печати (мета-валюта)."""
    im = canvas()
    cx, cy = BIG * 0.5, BIG * 0.5
    r = BIG * 0.34

    def coin(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)

    im = outline_and_fill(im, coin, GOLD)
    dl = ImageDraw.Draw(im)
    dl.ellipse([cx - r * 0.72, cy - r * 0.72, cx + r * 0.72, cy + r * 0.72], outline=INK, width=int(BIG * 0.014))
    # оттиск печати — маленький череп-контур по центру (тема мета-валюты некроманта)
    dl.ellipse([cx - r * 0.32, cy - r * 0.4, cx + r * 0.32, cy + r * 0.12], outline=INK, width=int(BIG * 0.016))
    dl.line([cx - r * 0.14, cy + r * 0.12, cx - r * 0.14, cy + r * 0.32], fill=INK, width=int(BIG * 0.014))
    dl.line([cx + r * 0.14, cy + r * 0.12, cx + r * 0.14, cy + r * 0.32], fill=INK, width=int(BIG * 0.014))
    return down(im)


# ── v17 HUD: значки верхней плашки (мана, армия, Котёл, волна) — тот же наклеечный контур ──
MANA_INK = (150, 104, 255, 255)   # фиолетовые чернила (цвет руны-договора)
HAT = (240, 140, 50, 255)         # оранжевая каска скелета-подрядчика
BREW = (120, 230, 90, 255)        # зелёное варево Котла (как на карте)
POT = (58, 54, 72, 255)
SAND = (230, 90, 70, 255)         # красный песок часов — «проверка идёт»


def icon_mana() -> Image.Image:
    """Мана — чернильница с фиолетовыми чернилами и каплей: договоры пишутся чернилами."""
    im = canvas()
    cx = BIG * 0.5

    def jar(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([cx - BIG * 0.27, BIG * 0.46, cx + BIG * 0.27, BIG * 0.86],
                            radius=BIG * 0.08, fill=col)
        d.rectangle([cx - BIG * 0.12, BIG * 0.36, cx + BIG * 0.12, BIG * 0.48], fill=col)

    im = outline_and_fill(im, jar, (200, 205, 225, 255))
    dl = ImageDraw.Draw(im)
    # чернила внутри банки
    dl.rounded_rectangle([cx - BIG * 0.21, BIG * 0.6, cx + BIG * 0.21, BIG * 0.8],
                         radius=BIG * 0.05, fill=MANA_INK)

    def drop(d: ImageDraw.ImageDraw, col):
        dx, dy = cx + BIG * 0.2, BIG * 0.2
        r = BIG * 0.1
        d.ellipse([dx - r, dy - r * 0.2, dx + r, dy + r * 1.8], fill=col)
        d.polygon([(dx - r * 0.85, dy + r * 0.5), (dx, dy - r * 1.4), (dx + r * 0.85, dy + r * 0.5)], fill=col)

    im = outline_and_fill(im, drop, MANA_INK)
    dl = ImageDraw.Draw(im)
    dl.ellipse([cx + BIG * 0.15, BIG * 0.26, cx + BIG * 0.2, BIG * 0.31], fill=(235, 225, 255, 255))
    return down(im)


def icon_army() -> Image.Image:
    """Армия — череп скелета-подрядчика в оранжевой каске (как бойцы на поле)."""
    im = canvas()
    cx = BIG * 0.5

    def skull(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - BIG * 0.27, BIG * 0.3, cx + BIG * 0.27, BIG * 0.78], fill=col)
        d.rounded_rectangle([cx - BIG * 0.16, BIG * 0.66, cx + BIG * 0.16, BIG * 0.88],
                            radius=BIG * 0.04, fill=col)

    im = outline_and_fill(im, skull, BONE)
    dl = ImageDraw.Draw(im)
    for ex in (cx - BIG * 0.11, cx + BIG * 0.11):
        dl.ellipse([ex - BIG * 0.075, BIG * 0.52, ex + BIG * 0.075, BIG * 0.66], fill=INK)
    for tx in (cx - BIG * 0.08, cx, cx + BIG * 0.08):
        dl.line([tx, BIG * 0.76, tx, BIG * 0.87], fill=INK, width=int(BIG * 0.018))

    def hat(d: ImageDraw.ImageDraw, col):
        d.chord([cx - BIG * 0.3, BIG * 0.14, cx + BIG * 0.3, BIG * 0.62], 180, 360, fill=col)
        d.rounded_rectangle([cx - BIG * 0.37, BIG * 0.36, cx + BIG * 0.37, BIG * 0.45],
                            radius=BIG * 0.03, fill=col)

    im = outline_and_fill(im, hat, HAT)
    dl = ImageDraw.Draw(im)
    dl.line([cx, BIG * 0.17, cx, BIG * 0.37], fill=(255, 200, 120, 255), width=int(BIG * 0.03))
    return down(im)


def icon_cauldron() -> Image.Image:
    """Котёл Душ — чёрный котёл с зелёным варевом и пузырём."""
    im = canvas()
    cx = BIG * 0.5

    def pot(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - BIG * 0.36, BIG * 0.34, cx + BIG * 0.36, BIG * 0.88], fill=col)
        for lx in (cx - BIG * 0.24, cx + BIG * 0.14):
            d.rectangle([lx, BIG * 0.8, lx + BIG * 0.1, BIG * 0.92], fill=col)

    im = outline_and_fill(im, pot, POT)

    def brew(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - BIG * 0.34, BIG * 0.3, cx + BIG * 0.34, BIG * 0.46], fill=col)
        d.ellipse([cx + BIG * 0.02, BIG * 0.14, cx + BIG * 0.18, BIG * 0.3], fill=col)
        d.ellipse([cx - BIG * 0.2, BIG * 0.2, cx - BIG * 0.08, BIG * 0.32], fill=col)

    im = outline_and_fill(im, brew, BREW)
    dl = ImageDraw.Draw(im)
    dl.arc([cx - BIG * 0.26, BIG * 0.46, cx + BIG * 0.1, BIG * 0.8], 150, 220,
           fill=(110, 105, 130, 255), width=int(BIG * 0.03))
    dl.ellipse([cx + BIG * 0.06, BIG * 0.17, cx + BIG * 0.11, BIG * 0.22], fill=(225, 255, 210, 255))
    return down(im)


def icon_wave() -> Image.Image:
    """Волна проверки — песочные часы с красным песком: сколько осталось до проверки."""
    im = canvas()
    cx = BIG * 0.5

    def glass(d: ImageDraw.ImageDraw, col):
        d.polygon([(cx - BIG * 0.24, BIG * 0.18), (cx + BIG * 0.24, BIG * 0.18), (cx + BIG * 0.04, BIG * 0.5),
                   (cx + BIG * 0.24, BIG * 0.82), (cx - BIG * 0.24, BIG * 0.82), (cx - BIG * 0.04, BIG * 0.5)],
                  fill=col)

    im = outline_and_fill(im, glass, (205, 225, 240, 255))
    dl = ImageDraw.Draw(im)
    dl.polygon([(cx - BIG * 0.13, BIG * 0.32), (cx + BIG * 0.13, BIG * 0.32), (cx, BIG * 0.48)], fill=SAND)
    dl.polygon([(cx, BIG * 0.6), (cx + BIG * 0.2, BIG * 0.8), (cx - BIG * 0.2, BIG * 0.8)], fill=SAND)
    dl.line([cx, BIG * 0.48, cx, BIG * 0.66], fill=SAND, width=int(BIG * 0.014))

    def caps(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([cx - BIG * 0.32, BIG * 0.1, cx + BIG * 0.32, BIG * 0.19], radius=BIG * 0.03, fill=col)
        d.rounded_rectangle([cx - BIG * 0.32, BIG * 0.81, cx + BIG * 0.32, BIG * 0.9], radius=BIG * 0.03, fill=col)

    im = outline_and_fill(im, caps, (150, 95, 60, 255))
    return down(im)


# ── Дерево покупок (slow/tree, Игорь 26.09: «дерево… покрасивее, с иконками»): по значку на
# покупку «Конторы», на перк и на ветку героя. Тот же наклеечный контур; смысл читается силуэтом,
# без подписи — «плюс» в зелёном кружке означает «больше этого», знак минус — «меньше/быстрее».
PLUS_C = (110, 220, 120, 255)     # зелёный значок «больше»
BROWN = (150, 95, 60, 255)
VIOLET = (150, 104, 255, 255)     # Cfg.RUNE_COLOR — фирменный цвет договора
GREEN_ARROW = (120, 230, 140, 255)
STEEL = (170, 180, 200, 255)


def badge(im: Image.Image, sign: str = "+", color=PLUS_C, at=(0.76, 0.76)) -> Image.Image:
    """Кружок-значок в углу иконки: «+» — больше этого, «−» — меньше (быстрее, дешевле)."""
    bx, by = BIG * at[0], BIG * at[1]
    r = BIG * 0.15

    def disc(d: ImageDraw.ImageDraw, col):
        d.ellipse([bx - r, by - r, bx + r, by + r], fill=col)

    im = outline_and_fill(im, disc, color)
    dl = ImageDraw.Draw(im)
    w = int(BIG * 0.045)
    dl.line([bx - r * 0.55, by, bx + r * 0.55, by], fill=BONE, width=w)
    if sign == "+":
        dl.line([bx, by - r * 0.55, bx, by + r * 0.55], fill=BONE, width=w)
    return im


def _stick_figure(d: ImageDraw.ImageDraw, col, cx: float, top: float, s: float):
    """Человечек-скелет: голова и трапеция тела; s — масштаб (1.0 — полный рост иконки)."""
    d.ellipse([cx - BIG * 0.09 * s, top, cx + BIG * 0.09 * s, top + BIG * 0.18 * s], fill=col)
    d.polygon([(cx - BIG * 0.07 * s, top + BIG * 0.2 * s), (cx + BIG * 0.07 * s, top + BIG * 0.2 * s),
               (cx + BIG * 0.13 * s, top + BIG * 0.5 * s), (cx - BIG * 0.13 * s, top + BIG * 0.5 * s)], fill=col)


def icon_shop_range() -> Image.Image:
    """Дальность набора — круг-радиус (пунктир чернилами договора) с человечком в центре."""
    im = canvas()
    cx, cy = BIG * 0.5, BIG * 0.5
    r = BIG * 0.38

    def ring(d: ImageDraw.ImageDraw, col):
        for a in range(0, 360, 45):
            d.arc([cx - r, cy - r, cx + r, cy + r], a + 6, a + 34, fill=col, width=int(BIG * 0.07))

    im = outline_and_fill(im, ring, VIOLET)
    im = outline_and_fill(im, lambda d, c: _stick_figure(d, c, cx, BIG * 0.27, 0.95), BONE)

    def arrow(d: ImageDraw.ImageDraw, col):
        d.polygon([(BIG * 0.93, cy), (BIG * 0.78, cy - BIG * 0.1), (BIG * 0.78, cy + BIG * 0.1)], fill=col)

    im = outline_and_fill(im, arrow, GOLD)
    return down(im)


def icon_shop_staff() -> Image.Image:
    """Штат — три фигурки: средняя впереди и крупнее (больше мест на постройке)."""
    im = canvas()
    for cx, top, s in ((BIG * 0.27, BIG * 0.26, 0.8), (BIG * 0.73, BIG * 0.26, 0.8)):
        im = outline_and_fill(im, lambda d, c, cx=cx, top=top, s=s: _stick_figure(d, c, cx, top, s),
                              (205, 205, 185, 255))
    im = outline_and_fill(im, lambda d, c: _stick_figure(d, c, BIG * 0.5, BIG * 0.3, 1.1), BONE)
    return down(im)


def icon_shop_respawn() -> Image.Image:
    """Возрождение — циферблат с круговой зелёной стрелкой (место заполняется снова, быстрее)."""
    im = canvas()
    cx, cy = BIG * 0.5, BIG * 0.52
    r = BIG * 0.25

    def face(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)

    im = outline_and_fill(im, face, BONE)
    dl = ImageDraw.Draw(im)
    dl.line([cx, cy, cx, cy - r * 0.6], fill=INK, width=int(BIG * 0.025))
    dl.line([cx, cy, cx + r * 0.45, cy + r * 0.1], fill=INK, width=int(BIG * 0.025))
    ra = BIG * 0.38

    def loop(d: ImageDraw.ImageDraw, col):
        d.arc([cx - ra, cy - ra, cx + ra, cy + ra], 200, 480, fill=col, width=int(BIG * 0.06))
        tip_a = math.radians(120)
        tx, ty = cx + ra * math.cos(tip_a), cy + ra * math.sin(tip_a)
        d.polygon([(tx - BIG * 0.1, ty - BIG * 0.02), (tx + BIG * 0.05, ty - BIG * 0.1),
                   (tx + BIG * 0.04, ty + BIG * 0.08)], fill=col)

    im = outline_and_fill(im, loop, GREEN_ARROW)
    return down(im)


def icon_shop_mana() -> Image.Image:
    """Мана — чернильница HUD со значком «+»: больше запаса и быстрее восстановление."""
    im = icon_mana().resize((BIG, BIG), Image.LANCZOS)
    return down(badge(im))


def icon_shop_souls() -> Image.Image:
    """Стартовые души — огонёк души со значком «+»."""
    im = icon_soul().resize((BIG, BIG), Image.LANCZOS)
    return down(badge(im, at=(0.74, 0.3)))


def icon_shop_settlement() -> Image.Image:
    """Расчёт — свиток договора и золотая монета перед ним (выплата по истёкшему договору)."""
    im = canvas()

    def scroll(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([BIG * 0.14, BIG * 0.18, BIG * 0.66, BIG * 0.7], radius=BIG * 0.05, fill=col)

    im = outline_and_fill(im, scroll, BONE)
    dl = ImageDraw.Draw(im)
    for y in (0.3, 0.4, 0.5):
        dl.line([BIG * 0.22, BIG * y, BIG * 0.56, BIG * y], fill=INK, width=int(BIG * 0.018))
    cx, cy, r = BIG * 0.62, BIG * 0.64, BIG * 0.24

    def coin(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)

    im = outline_and_fill(im, coin, GOLD)
    dl = ImageDraw.Draw(im)
    dl.ellipse([cx - r * 0.68, cy - r * 0.68, cx + r * 0.68, cy + r * 0.68], outline=INK, width=int(BIG * 0.014))
    return down(im)


def icon_shop_general() -> Image.Image:
    """Общие покупки «Конторы» — портфель конторы с золотой застёжкой."""
    im = canvas()

    def case(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([BIG * 0.12, BIG * 0.32, BIG * 0.88, BIG * 0.82], radius=BIG * 0.07, fill=col)
        d.rounded_rectangle([BIG * 0.36, BIG * 0.18, BIG * 0.64, BIG * 0.36], radius=BIG * 0.05, fill=col)

    im = outline_and_fill(im, case, BROWN)
    dl = ImageDraw.Draw(im)
    dl.rounded_rectangle([BIG * 0.42, BIG * 0.24, BIG * 0.58, BIG * 0.33], radius=BIG * 0.03, fill=(0, 0, 0, 0))
    dl.line([BIG * 0.12, BIG * 0.52, BIG * 0.88, BIG * 0.52], fill=INK, width=int(BIG * 0.02))
    dl.rounded_rectangle([BIG * 0.43, BIG * 0.46, BIG * 0.57, BIG * 0.6], radius=BIG * 0.02, fill=GOLD,
                         outline=INK, width=int(BIG * 0.012))
    return down(im)


def icon_hero_point() -> Image.Image:
    """Очко героя — фиолетовый самоцвет-ромб (валюта экрана героя, рядом с ценой узла)."""
    im = canvas()
    cx, cy = BIG * 0.5, BIG * 0.5

    def gem(d: ImageDraw.ImageDraw, col):
        d.polygon([(cx, BIG * 0.1), (BIG * 0.84, cy), (cx, BIG * 0.9), (BIG * 0.16, cy)], fill=col)

    im = outline_and_fill(im, gem, VIOLET)
    dl = ImageDraw.Draw(im)
    dl.polygon([(cx, BIG * 0.2), (BIG * 0.7, cy), (cx, cy)], fill=(200, 175, 255, 255))
    dl.line([(BIG * 0.16, cy), (BIG * 0.84, cy)], fill=INK, width=int(BIG * 0.014))
    return down(im)


def icon_branch_hr() -> Image.Image:
    """Ветка «Кадровик» — пропуск-бейдж с фото сотрудника."""
    im = canvas()

    def card(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([BIG * 0.2, BIG * 0.2, BIG * 0.8, BIG * 0.86], radius=BIG * 0.06, fill=col)

    im = outline_and_fill(im, card, (225, 225, 240, 255))
    dl = ImageDraw.Draw(im)
    dl.rounded_rectangle([BIG * 0.4, BIG * 0.12, BIG * 0.6, BIG * 0.26], radius=BIG * 0.03, fill=STEEL,
                         outline=INK, width=int(BIG * 0.012))
    dl.rounded_rectangle([BIG * 0.3, BIG * 0.32, BIG * 0.7, BIG * 0.62], radius=BIG * 0.03, fill=LABORER_C)
    _stick_figure(dl, INK, BIG * 0.5, BIG * 0.36, 0.52)
    for y in (0.7, 0.78):
        dl.line([BIG * 0.3, BIG * y, BIG * 0.7, BIG * y], fill=INK, width=int(BIG * 0.02))
    return down(im)


def icon_branch_law() -> Image.Image:
    """Ветка «Юрист» — золотые весы."""
    im = canvas()
    cx = BIG * 0.5

    def scales(d: ImageDraw.ImageDraw, col):
        w = int(BIG * 0.045)
        d.line([cx, BIG * 0.16, cx, BIG * 0.8], fill=col, width=w)
        d.line([BIG * 0.18, BIG * 0.3, BIG * 0.82, BIG * 0.3], fill=col, width=w)
        d.rounded_rectangle([cx - BIG * 0.2, BIG * 0.78, cx + BIG * 0.2, BIG * 0.87], radius=BIG * 0.03, fill=col)
        for px in (BIG * 0.24, BIG * 0.76):
            d.line([px, BIG * 0.3, px - BIG * 0.1, BIG * 0.56], fill=col, width=int(BIG * 0.02))
            d.line([px, BIG * 0.3, px + BIG * 0.1, BIG * 0.56], fill=col, width=int(BIG * 0.02))
            d.chord([px - BIG * 0.15, BIG * 0.44, px + BIG * 0.15, BIG * 0.68], 0, 180, fill=col)
        d.ellipse([cx - BIG * 0.05, BIG * 0.1, cx + BIG * 0.05, BIG * 0.2], fill=col)

    im = outline_and_fill(im, scales, GOLD)
    return down(im)


def icon_branch_warlock() -> Image.Image:
    """Ветка «Чернокнижник» — гримуар с рунным глазом."""
    im = canvas()

    def book(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([BIG * 0.2, BIG * 0.14, BIG * 0.8, BIG * 0.86], radius=BIG * 0.05, fill=col)

    im = outline_and_fill(im, book, (95, 60, 150, 255))
    dl = ImageDraw.Draw(im)
    dl.rectangle([BIG * 0.2, BIG * 0.14, BIG * 0.3, BIG * 0.86], fill=(70, 42, 115, 255))
    cx, cy = BIG * 0.55, BIG * 0.48
    dl.ellipse([cx - BIG * 0.17, cy - BIG * 0.1, cx + BIG * 0.17, cy + BIG * 0.1], fill=(235, 225, 255, 255),
               outline=INK, width=int(BIG * 0.014))
    dl.ellipse([cx - BIG * 0.06, cy - BIG * 0.06, cx + BIG * 0.06, cy + BIG * 0.06], fill=VIOLET)
    dl.ellipse([cx - BIG * 0.025, cy - BIG * 0.025, cx + BIG * 0.025, cy + BIG * 0.025], fill=INK)
    return down(im)


def _clock(im: Image.Image, cx: float, cy: float, r: float, color) -> Image.Image:
    def face(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
        d.rounded_rectangle([cx - r * 0.25, cy - r * 1.3, cx + r * 0.25, cy - r * 0.9], radius=r * 0.08, fill=col)

    im = outline_and_fill(im, face, color)
    dl = ImageDraw.Draw(im)
    dl.ellipse([cx - r * 0.78, cy - r * 0.78, cx + r * 0.78, cy + r * 0.78], fill=BONE)
    dl.line([cx, cy, cx, cy - r * 0.6], fill=INK, width=int(BIG * 0.022))
    dl.line([cx, cy, cx + r * 0.45, cy], fill=INK, width=int(BIG * 0.022))
    return im


def icon_perk_fast_hire() -> Image.Image:
    """«Быстрый найм» — секундомер и значок «−» (возрождение короче)."""
    im = _clock(canvas(), BIG * 0.46, BIG * 0.54, BIG * 0.3, GREEN_ARROW)
    return down(badge(im, "-", GREEN_ARROW, at=(0.78, 0.76)))


def icon_perk_big_staff() -> Image.Image:
    """«Раздутый штат» — плотная толпа из пяти голов-черепов."""
    im = canvas()
    for cx, cy, r in ((0.24, 0.5, 0.13), (0.76, 0.5, 0.13), (0.37, 0.4, 0.14), (0.63, 0.4, 0.14),
                      (0.5, 0.58, 0.17)):
        def head(d: ImageDraw.ImageDraw, col, cx=cx, cy=cy, r=r):
            d.ellipse([BIG * (cx - r), BIG * (cy - r), BIG * (cx + r), BIG * (cy + r * 1.1)], fill=col)
            d.rounded_rectangle([BIG * (cx - r * 0.6), BIG * (cy + r * 0.6), BIG * (cx + r * 0.6),
                                 BIG * (cy + r * 1.5)], radius=BIG * 0.02, fill=col)
        im = outline_and_fill(im, head, BONE)
        dl = ImageDraw.Draw(im)
        for ex in (cx - r * 0.38, cx + r * 0.38):
            dl.ellipse([BIG * (ex - r * 0.2), BIG * (cy - r * 0.05), BIG * (ex + r * 0.2), BIG * (cy + r * 0.38)],
                       fill=INK)
    return down(badge(im, at=(0.8, 0.22)))


def icon_perk_brisk_exit() -> Image.Image:
    """«Бодрый выход» — дверь и зелёная стрелка наружу с линиями скорости."""
    im = canvas()

    def door(d: ImageDraw.ImageDraw, col):
        d.rectangle([BIG * 0.12, BIG * 0.14, BIG * 0.46, BIG * 0.88], fill=col)

    im = outline_and_fill(im, door, BROWN)
    dl = ImageDraw.Draw(im)
    dl.rectangle([BIG * 0.18, BIG * 0.2, BIG * 0.4, BIG * 0.88], fill=(40, 30, 50, 255))

    def arrow(d: ImageDraw.ImageDraw, col):
        d.rectangle([BIG * 0.3, BIG * 0.44, BIG * 0.68, BIG * 0.58], fill=col)
        d.polygon([(BIG * 0.66, BIG * 0.3), (BIG * 0.92, BIG * 0.51), (BIG * 0.66, BIG * 0.72)], fill=col)

    im = outline_and_fill(im, arrow, GREEN_ARROW)
    dl = ImageDraw.Draw(im)
    for y, x0 in ((0.32, 0.5), (0.72, 0.5)):
        dl.line([BIG * x0, BIG * y, BIG * (x0 + 0.12), BIG * y], fill=BONE, width=int(BIG * 0.025))
    return down(im)


def icon_perk_settlement_on_time() -> Image.Image:
    """«Расчёт в срок» — монета и маленькие часы поверх."""
    im = canvas()
    cx, cy, r = BIG * 0.42, BIG * 0.58, BIG * 0.3

    def coin(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)

    im = outline_and_fill(im, coin, GOLD)
    dl = ImageDraw.Draw(im)
    dl.ellipse([cx - r * 0.7, cy - r * 0.7, cx + r * 0.7, cy + r * 0.7], outline=INK, width=int(BIG * 0.014))
    im = _clock(im, BIG * 0.72, BIG * 0.3, BIG * 0.16, (230, 90, 70, 255))
    return down(im)


def icon_perk_far_call() -> Image.Image:
    """«Дальний призыв» — рупор и дуги звука."""
    im = canvas()

    def horn(d: ImageDraw.ImageDraw, col):
        d.polygon([(BIG * 0.14, BIG * 0.42), (BIG * 0.3, BIG * 0.42), (BIG * 0.58, BIG * 0.2),
                   (BIG * 0.58, BIG * 0.8), (BIG * 0.3, BIG * 0.58), (BIG * 0.14, BIG * 0.58)], fill=col)
        d.rectangle([BIG * 0.2, BIG * 0.56, BIG * 0.28, BIG * 0.76], fill=col)

    im = outline_and_fill(im, horn, (230, 90, 70, 255))

    def waves(d: ImageDraw.ImageDraw, col):
        for rr in (0.16, 0.28):
            d.arc([BIG * (0.6 - rr), BIG * (0.5 - rr), BIG * (0.6 + rr), BIG * (0.5 + rr)], -50, 50, fill=col,
                  width=int(BIG * 0.05))

    im = outline_and_fill(im, waves, BONE)
    return down(im)


def icon_perk_fine_print() -> Image.Image:
    """«Мелкий шрифт» — лупа над строками договора."""
    im = canvas()

    def paper(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([BIG * 0.14, BIG * 0.12, BIG * 0.7, BIG * 0.86], radius=BIG * 0.04, fill=col)

    im = outline_and_fill(im, paper, BONE)
    dl = ImageDraw.Draw(im)
    for i in range(7):
        y = BIG * (0.22 + i * 0.085)
        dl.line([BIG * 0.22, y, BIG * 0.62, y], fill=(90, 90, 120, 255), width=int(BIG * 0.012))
    cx, cy, r = BIG * 0.58, BIG * 0.5, BIG * 0.2

    def glass(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=int(BIG * 0.06))
        d.line([cx + r * 0.7, cy + r * 0.7, BIG * 0.9, BIG * 0.88], fill=col, width=int(BIG * 0.08))

    im = outline_and_fill(im, glass, BROWN)
    dl = ImageDraw.Draw(im)
    dl.line([cx - r * 0.5, cy, cx + r * 0.5, cy], fill=VIOLET, width=int(BIG * 0.03))
    return down(im)


def icon_perk_short_cd() -> Image.Image:
    """«Короткий откат» — таймер-пирог отката, где осталась лишь узкая доля."""
    im = canvas()
    cx, cy, r = BIG * 0.48, BIG * 0.52, BIG * 0.34

    def disc(d: ImageDraw.ImageDraw, col):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)

    im = outline_and_fill(im, disc, (60, 50, 85, 255))
    dl = ImageDraw.Draw(im)
    dl.pieslice([cx - r * 0.86, cy - r * 0.86, cx + r * 0.86, cy + r * 0.86], -90, 200, fill=VIOLET)
    dl.line([cx, cy, cx, cy - r * 0.86], fill=BONE, width=int(BIG * 0.02))
    return down(badge(im, "-", GREEN_ARROW, at=(0.8, 0.78)))


def icon_perk_chain_reaction() -> Image.Image:
    """«Цепная реакция» — молния Ку, развилка на две цели."""
    im = canvas()
    bolt = (200, 225, 255, 255)

    def fork(d: ImageDraw.ImageDraw, col):
        w = int(BIG * 0.1)
        d.line([(BIG * 0.2, BIG * 0.14), (BIG * 0.42, BIG * 0.4), (BIG * 0.32, BIG * 0.5),
                (BIG * 0.54, BIG * 0.66)], fill=col, width=w, joint="curve")
        d.line([(BIG * 0.54, BIG * 0.66), (BIG * 0.82, BIG * 0.56)], fill=col, width=w)
        d.line([(BIG * 0.54, BIG * 0.66), (BIG * 0.66, BIG * 0.88)], fill=col, width=w)

    im = outline_and_fill(im, fork, bolt)
    for tx, ty in ((0.84, 0.54), (0.67, 0.88)):
        def orb(d: ImageDraw.ImageDraw, col, tx=tx, ty=ty):
            d.ellipse([BIG * (tx - 0.08), BIG * (ty - 0.08), BIG * (tx + 0.08), BIG * (ty + 0.08)], fill=col)
        im = outline_and_fill(im, orb, (230, 90, 70, 255))
    return down(im)


def icon_perk_overtime() -> Image.Image:
    """«Сверхурочные» — месяц ночной смены и будильник Аврала перед ним."""
    im = canvas()

    def moon(d: ImageDraw.ImageDraw, col):
        d.ellipse([BIG * 0.12, BIG * 0.1, BIG * 0.66, BIG * 0.64], fill=col)

    im = outline_and_fill(im, moon, (250, 225, 130, 255))
    dl = ImageDraw.Draw(im)
    dl.ellipse([BIG * 0.3, BIG * 0.02, BIG * 0.8, BIG * 0.52], fill=(0, 0, 0, 0))
    im = _clock(im, BIG * 0.62, BIG * 0.66, BIG * 0.22, (255, 168, 75, 255))
    return down(im)


def icon_lock() -> Image.Image:
    """Замок — узел дерева закрыт (нет предпосылки): рисуется поверх потускневшей иконки."""
    im = canvas()
    cx = BIG * 0.5

    def shackle(d: ImageDraw.ImageDraw, col):
        d.arc([cx - BIG * 0.2, BIG * 0.12, cx + BIG * 0.2, BIG * 0.6], 180, 360, fill=col, width=int(BIG * 0.08))
        d.line([cx - BIG * 0.2, BIG * 0.36, cx - BIG * 0.2, BIG * 0.5], fill=col, width=int(BIG * 0.08))
        d.line([cx + BIG * 0.2, BIG * 0.36, cx + BIG * 0.2, BIG * 0.5], fill=col, width=int(BIG * 0.08))

    im = outline_and_fill(im, shackle, STEEL)

    def body(d: ImageDraw.ImageDraw, col):
        d.rounded_rectangle([cx - BIG * 0.3, BIG * 0.44, cx + BIG * 0.3, BIG * 0.88], radius=BIG * 0.06, fill=col)

    im = outline_and_fill(im, body, (200, 160, 70, 255))
    dl = ImageDraw.Draw(im)
    dl.ellipse([cx - BIG * 0.06, BIG * 0.56, cx + BIG * 0.06, BIG * 0.68], fill=INK)
    dl.rectangle([cx - BIG * 0.025, BIG * 0.64, cx + BIG * 0.025, BIG * 0.78], fill=INK)
    return down(im)


ICONS = {
    "shop_range": icon_shop_range,
    "shop_staff": icon_shop_staff,
    "shop_respawn": icon_shop_respawn,
    "shop_mana": icon_shop_mana,
    "shop_souls": icon_shop_souls,
    "shop_settlement": icon_shop_settlement,
    "shop_general": icon_shop_general,
    "hero_point": icon_hero_point,
    "branch_hr": icon_branch_hr,
    "branch_law": icon_branch_law,
    "branch_warlock": icon_branch_warlock,
    "perk_fast_hire": icon_perk_fast_hire,
    "perk_big_staff": icon_perk_big_staff,
    "perk_brisk_exit": icon_perk_brisk_exit,
    "perk_settlement_on_time": icon_perk_settlement_on_time,
    "perk_far_call": icon_perk_far_call,
    "perk_fine_print": icon_perk_fine_print,
    "perk_short_cd": icon_perk_short_cd,
    "perk_chain_reaction": icon_perk_chain_reaction,
    "perk_overtime": icon_perk_overtime,
    "tree_lock": icon_lock,
    "hud_mana": icon_mana,
    "hud_army": icon_army,
    "hud_cauldron": icon_cauldron,
    "hud_wave": icon_wave,
    "contract_laborer": lambda: icon_contract(LABORER_C),
    "contract_guard": lambda: icon_contract(GUARD_C),
    "contract_clerk": lambda: icon_contract(CLERK_C),
    "ability_q": icon_ability_q,
    "ability_w": icon_ability_w,
    "ability_e": icon_ability_e,
    "soul": icon_soul,
    "premium": icon_premium,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="godot/assets/legion/icons")
    ap.add_argument("--check", action="store_true", help="только проверить размер/альфу, не печатать превью")
    ap.add_argument("--only", default="", help="через запятую: только эти иконки (прочие PNG не трогать)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    only = {s for s in a.only.split(",") if s}
    for name, fn in ICONS.items():
        if only and name not in only:
            continue
        im = fn()
        assert im.size == (SIZE, SIZE), name
        path = os.path.join(a.out, f"{name}.png")
        im.save(path)
        print(name, "->", path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
