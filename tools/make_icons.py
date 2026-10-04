#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_icons.py — семь иконок UI, нарисованных КОДОМ на Pillow.

    python tools/make_icons.py [--out assets/img/icons] [--check]

Перезаписывает assets/img/icons/*.png. Ни сети, ни генерации: результат
детерминирован и воспроизводим — этого требует SPEC §3 («иконки рисуются
кодом, не генерацией»). Предыдущий комплект был RGB 160x160 без альфы
(белые углы поверх тёмного HUD) — брак, зафиксированный в SOURCES.md.

ДИЗАЙН-СИСТЕМА (обязательные рамки, менять — только всем комплектом сразу)

  * Холст RGBA 160x160, углы прозрачны. Рисуем в 4x (640x640) и давим
    LANCZOS'ом до 160 — так получается сглаживание без сторонних библиотек.
    Даунскейл идёт через premultiplied "RGBa", иначе прозрачный чёрный
    затекает в края и даёт тёмный ореол.
  * Оптическое поле — вписанный круг ~86% холста; контент-bbox каждой
    иконки держится в коридоре линтера 45-90% и целится в 72-78%.
  * Единый «наклеечный» контур: каждая фигура сначала рисуется тёмным
    индиго (INK) с наростом OUTLINE px, затем поверх — светлой заливкой.
    Толщина контура одинакова у всех семи.
  * Основной штрих — кость #f0f0d8; у каждой иконки свой цветовой акцент
    из палитры игры (js/data/config.js ABILITIES).
  * Главный критерий — читаемость в ~31 px (слот 56 px * 0.56). Поэтому
    силуэты крупные и простые: мелкой детали здесь не выживает ничего.

ПАЛИТРА И ЛИНТЕР. asset_lint.py требует, чтобы >=85% плотного контента
попадало в семейства SPEC §2.3 (dist<=55 в RGB). Два цвета из ТЗ туда не
проходят и взяты в смягчённом варианте:
  * Q  #c8e1ff -> заливка #d8e8f8 (dist 41 до #f0f0d8), сам #c8e1ff остаётся
    в мягком свечении;
  * E  #ffbe5a -> #ffa84b (dist 29 до #ff8c3c).
Свечение рисуется отдельным слоем с потолком альфы GLOW_A < 200 — линтер
считает палитру только по плотным пикселям (alpha>=200), так что свечение
на покрытие не влияет и hue акцента остаётся честным.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 160
S = 4                      # супер-сэмплинг
BIG = SIZE * S
OUTLINE = 3                # нарост тёмного контура, px в 160-пространстве
GLOW_A = 120               # потолок альфы свечения (< ALPHA_SOLID=200 линтера)
GLOW_BLUR = 5              # радиус блюра свечения, px в 160-пространстве
ALPHA_CUT = 20             # хвост свечения ниже этой альфы гасится в ноль:
                           # он невидим глазу, но линтер считает его контентом
                           # (ALPHA_CONTENT=16) и раздувает bbox за коридор

# --- палитра (SPEC §2.3 + акценты способностей) ---
INK = (24, 24, 48)          # #181830 — контур
BONE = (240, 240, 216)      # #f0f0d8 — основной штрих
BONE_D = (240, 240, 192)    # #f0f0c0 — вторая ступень кости
WHITE = (255, 255, 255)
BLUE = (216, 232, 248)      # заливка Q
BLUE_GLOW = (200, 225, 255)  # #c8e1ff — акцент Q в свечении
GREEN = (120, 255, 150)     # #78ff96 — W
GREEN_S = (90, 230, 140)    # #5ae68c — soul
GREEN_L = (168, 240, 120)   # #a8f078 — внутреннее свечение soul
ORANGE = (255, 140, 60)     # #ff8c3c
ORANGE_L = (255, 168, 75)   # смягчённый #ffbe5a
ORANGE_D = (240, 120, 24)   # #f07818
PURPLE = (138, 92, 246)     # #8a5cf6

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "assets", "img", "icons")


# ------------------------------------------------------------- примитивы ---
#
# Каждая иконка — список примитивов. Один и тот же список рисуется дважды:
# проходом "ink" (фигура, раздутая на OUTLINE, тёмным индиго) и проходом
# "fill" (та же фигура своим цветом). Так контур получается замкнутым и
# ровно одинаковым у всех иконок, а порядок наложения задаётся один раз.


class Shapes(object):
    def __init__(self):
        self.items = []

    def line(self, pts, color, w):
        """Толстый штрих со скруглёнными стыками и торцами."""
        self.items.append(("line", list(pts), color, w))
        return self

    def poly(self, pts, color):
        self.items.append(("poly", list(pts), color, 0))
        return self

    def ellipse(self, box, color):
        self.items.append(("ellipse", list(box), color, 0))
        return self

    def rrect(self, box, radius, color):
        self.items.append(("rrect", list(box), color, radius))
        return self

    def pie(self, box, start, end, color):
        self.items.append(("pie", list(box) + [start, end], color, 0))
        return self

    def arc(self, box, start, end, color, w):
        self.items.append(("arc", list(box) + [start, end], color, w))
        return self


def _k(v):
    return [c * S for c in v]


def _draw(d, kind, geom, color, w, grow):
    """grow>0 — раздутая версия примитива (проход контура)."""
    g = float(grow)
    if kind == "line":
        pts = [(x * S, y * S) for x, y in geom]
        width = int(round((w + 2 * g) * S))
        if len(pts) > 1:
            d.line(pts, fill=color, width=width, joint="curve")
        r = width / 2.0
        for (x, y) in pts:           # скруглённые торцы
            d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    elif kind == "poly":
        pts = [(x * S, y * S) for x, y in geom]
        d.polygon(pts, fill=color)
        if g > 0:                    # раздуваем обводкой замкнутого контура
            width = int(round(2 * g * S))
            d.line(pts + [pts[0]], fill=color, width=width, joint="curve")
            r = width / 2.0
            for (x, y) in pts:
                d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    elif kind == "ellipse":
        x0, y0, x1, y1 = geom
        d.ellipse(_k([x0 - g, y0 - g, x1 + g, y1 + g]), fill=color)
    elif kind == "rrect":
        x0, y0, x1, y1 = geom
        d.rounded_rectangle(_k([x0 - g, y0 - g, x1 + g, y1 + g]),
                            radius=(w + g) * S, fill=color)
    elif kind == "pie":
        x0, y0, x1, y1, a, b = geom
        d.pieslice(_k([x0 - g, y0 - g, x1 + g, y1 + g]), a, b, fill=color)
    elif kind == "arc":
        x0, y0, x1, y1, a, b = geom
        d.arc(_k([x0, y0, x1, y1]), a, b, fill=color,
              width=int(round((w + 2 * g) * S)))
    else:
        raise ValueError(kind)


def render(shapes):
    """Список примитивов -> слой 640x640 RGBA (контур + заливка)."""
    layer = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for kind, geom, _color, w in shapes.items:      # проход контура
        _draw(d, kind, geom, INK + (255,), w, OUTLINE)
    for kind, geom, color, w in shapes.items:       # проход заливки
        _draw(d, kind, geom, color + (255,), w, 0)
    return layer


def glow_layer(shapes, color):
    """Мягкое свечение силуэта — отдельным слоем под фигурой.

    Альфа зажата GLOW_A: линтер считает палитру по alpha>=200, значит
    свечение не портит покрытие, а цвет акцента при этом виден глазу.
    """
    mask = Image.new("L", (BIG, BIG), 0)
    d = ImageDraw.Draw(mask)
    for kind, geom, _c, w in shapes.items:
        _draw(d, kind, geom, GLOW_A, w, OUTLINE + 2)
    mask = mask.filter(ImageFilter.GaussianBlur(GLOW_BLUR * S))
    out = Image.new("RGBA", (BIG, BIG), color + (0,))
    out.putalpha(mask)
    return out


def compose(shapes, glow_color=None):
    base = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    if glow_color is not None:
        base = Image.alpha_composite(base, glow_layer(shapes, glow_color))
    base = Image.alpha_composite(base, render(shapes))
    # premultiply -> resize -> unpremultiply: иначе прозрачный чёрный
    # затекает в полупрозрачные края и даёт грязный ореол
    out = base.convert("RGBa").resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")
    a = out.getchannel("A").point(lambda v: 0 if v < ALPHA_CUT else v)
    out.putalpha(a)
    return out


def _teardrop(cx, cy, r, tip_y, n=48):
    """Капля: нижняя дуга окружности + сходящийся кверху хвостик."""
    pts = []
    for i in range(n + 1):
        th = math.radians(-30 + 240.0 * i / n)   # правый бок -> низ -> левый бок
        pts.append((cx + r * math.cos(th), cy + r * math.sin(th)))
    return [(cx, tip_y)] + pts


# --------------------------------------------------------------- иконки ----

def icon_ability_q():
    """Q «Разряд»: толстый зигзаг-молния, бледно-голубой, голубое свечение."""
    s = Shapes()
    bolt = [(94, 24), (52, 88), (78, 88), (66, 136), (110, 68), (84, 68)]
    s.poly(bolt, BLUE)
    # блик вдоль верхней грани — молния не читается плоским пятном
    s.line([(88, 36), (66, 72)], WHITE, 6)
    return compose(s, BLUE_GLOW)


def icon_ability_w():
    """W «Оформление в штат»: кисть скелета встаёт из земли над зелёной линией."""
    s = Shapes()
    s.line([(34, 124), (126, 124)], GREEN, 11)          # линия земли
    s.rrect([66, 86, 94, 126], 12, BONE)                # предплечье
    s.rrect([56, 60, 104, 98], 15, BONE)                # ладонь
    for a, b in (((64, 66), (55, 40)),                  # четыре пальца
                 ((75, 62), (73, 30)),
                 ((87, 62), (91, 32)),
                 ((98, 66), (107, 44))):
        s.line([a, b], BONE, 10)
    s.line([(58, 86), (40, 74)], BONE_D, 10)            # большой палец
    return compose(s, GREEN)


def icon_ability_e():
    """E «Аврал»: офисная кружка, над ней разряд-пар — форсаж по-бюрократически."""
    s = Shapes()
    bolt = [(84, 18), (56, 48), (76, 48), (64, 74), (98, 40), (78, 40)]
    s.poly(bolt, ORANGE_L)                              # пар-молния
    s.arc([88, 84, 134, 124], -85, 85, BONE, 12)        # ручка — крупная,
    s.rrect([38, 78, 102, 136], 10, BONE)               # иначе в 31 px её нет
    s.rrect([38, 78, 102, 94], 7, ORANGE)               # ободок
    return compose(s, ORANGE_L)


def icon_ability_ult():
    """ULT «Финальная директива»: белый череп под фиолетовой короной-печатью."""
    s = Shapes()
    crown = [(44, 52), (44, 22), (62, 37), (80, 18), (98, 37), (116, 22), (116, 52)]
    s.poly(crown, PURPLE)
    s.rrect([58, 98, 102, 130], 8, WHITE)               # челюсть
    s.ellipse([40, 48, 120, 112], WHITE)                # свод черепа
    s.ellipse([52, 66, 74, 88], INK)                    # глазницы
    s.ellipse([86, 66, 108, 88], INK)
    s.poly([(74, 92), (86, 92), (80, 101)], INK)        # нос
    s.line([(74, 112), (74, 128)], INK, 4)              # зубы
    s.line([(86, 112), (86, 128)], INK, 4)
    return compose(s, PURPLE)


def icon_soul():
    """soul «Душа»: капля-огонёк с хвостиком и светлым ядром внутри."""
    s = Shapes()
    s.poly(_teardrop(80, 98, 36, 26), GREEN_S)
    s.poly(_teardrop(80, 102, 18, 64), GREEN_L)         # внутреннее свечение
    return compose(s, GREEN_S)


def icon_trap_mine():
    """trap_mine «Мина»: оранжевая полусфера на опоре, четыре усика, блик."""
    s = Shapes()
    cx, cy, r = 80.0, 122.0, 44.0
    for deg in (212, 246, 294, 328):                    # усики-детонаторы
        th = math.radians(deg)
        s.line([(cx + 38 * math.cos(th), cy + 38 * math.sin(th)),
                (cx + 58 * math.cos(th), cy + 58 * math.sin(th))], BONE, 9)
    s.pie([cx - r, cy - r, cx + r, cy + r], 180, 360, ORANGE)   # купол
    s.rrect([32, 116, 128, 132], 7, ORANGE_D)                   # опора
    s.ellipse([56, 90, 74, 102], BONE)                          # блик
    return compose(s, ORANGE)


def icon_trap_totem():
    """trap_totem «Тотем»: столб-указатель с костяным черепом наверху."""
    s = Shapes()
    s.rrect([62, 72, 98, 138], 10, PURPLE)              # столб
    s.rrect([54, 104, 106, 116], 5, BONE_D)             # костяная стяжка
    s.ellipse([48, 22, 112, 80], BONE)                  # череп
    s.ellipse([56, 40, 74, 60], INK)                    # глазницы
    s.ellipse([86, 40, 104, 60], INK)
    s.ellipse([59, 44, 68, 53], PURPLE)                 # горящий глазок
    s.line([(66, 72), (94, 72)], INK, 4)                # линия челюсти
    return compose(s, PURPLE)


ICONS = {
    "ability_q": icon_ability_q,
    "ability_w": icon_ability_w,
    "ability_e": icon_ability_e,
    "ability_ult": icon_ability_ult,
    "soul": icon_soul,
    "trap_mine": icon_trap_mine,
    "trap_totem": icon_trap_totem,
}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Отрисовка иконок UI кодом")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--only", nargs="*", help="только эти иконки")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.out):
        os.makedirs(args.out)

    names = args.only or sorted(ICONS)
    for name in names:
        if name not in ICONS:
            print("нет такой иконки: %s" % name, file=sys.stderr)
            return 2
        im = ICONS[name]()
        path = os.path.join(args.out, name + ".png")
        im.save(path)
        a = im.getchannel("A")
        bb = a.getbbox()
        corner = max(im.crop(c).getchannel("A").getextrema()[1]
                     for c in ((0, 0, 12, 12), (148, 0, 160, 12),
                               (0, 148, 12, 160), (148, 148, 160, 160)))
        print("%-14s %s  bbox %d%%x%d%%  углы alpha<=%d"
              % (name, path,
                 round(100.0 * (bb[2] - bb[0]) / SIZE),
                 round(100.0 * (bb[3] - bb[1]) / SIZE), corner))
    return 0


if __name__ == "__main__":
    sys.exit(main())
