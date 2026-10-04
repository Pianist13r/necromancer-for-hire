#!/usr/bin/env python3
"""
Нарезка AI-СГЕНЕРИРОВАННОГО спрайт-листа на отдельные кадры анимации (Э1-b, 2026-08-23).

Зачем именно так: лист рисует генеративная модель, а она НЕ кладёт персонажей в идеальную
сетку — размер и положение гуляют от кадра к кадру, плюс модель самовольно дорисовывает
линию земли, даже когда её просят этого не делать. Резать такой лист «делением на N равных
ячеек» нельзя: половина кадров окажется обрезана. Поэтому здесь кадры НАХОДЯТСЯ по факту
пикселей, а потом выравниваются.

Конвейер:
  1. Фон вырезается ПО ЦВЕТУ (он ровный и однотонный по построению промпта) — это надёжнее
     нейросетевого remove_background, который на листе из многих фигур видит один объект.
  2. Длинные горизонтальные линии (нарисованная моделью «земля») удаляются: без этого все
     персонажи слипаются в одну связную кляксу и разрезать лист невозможно.
  3. Кадры ищутся как разрывы в вертикальном профиле непрозрачности — сначала строки
     (ряды сетки), потом колонки внутри каждого ряда.
  4. ВЫРАВНИВАНИЕ (главное): все кадры кладутся на общий холст так, чтобы ПОДОШВА (нижняя
     непрозрачная строка) и центр силуэта совпадали. Именно нижняя точка — правильный якорь
     для ходьбы: одна нога всегда на земле, значит низ силуэта и есть уровень пола. Без
     этого шага персонаж в игре подпрыгивает и дёргается по горизонтали.

Запуск (из корня репо):
    python tools/slice_spritesheet.py ЛИСТ.png ПАПКА_ВЫХОДА --cols 8 --rows 2
    ... --name walk          префикс имён кадров (walk_00.png, walk_01.png, ...)
    ... --bg-tol 40          допуск цвета фона (0-255), если фон вышел неровным
    ... --sheet ЛИСТ.png     собрать контактный лист выровненных кадров для приёмки
"""
import argparse
import pathlib
import sys

from PIL import Image


def background_mask(im: Image.Image, tol: int) -> list[list[bool]]:
    """True = пиксель принадлежит ПЕРСОНАЖУ. Цвет фона берём из угла картинки."""
    px = im.load()
    bg = px[2, 2][:3]
    w, h = im.size
    return [
        [
            not all(abs(px[x, y][i] - bg[i]) <= tol for i in range(3))
            for x in range(w)
        ]
        for y in range(h)
    ]


def strip_long_lines(mask: list[list[bool]], w: int, min_share: float = 0.5) -> None:
    """Стереть строки с НЕПРЕРЫВНЫМ отрезком почти во всю ширину — это линия земли.

    ⚠️ Критерий именно непрерывности, а не суммарной доли занятых пикселей: восемь фигур
    в ряд дают на уровне торса ~72 % ширины листа, и порог «по сумме» стирал персонажей
    вместе с линией (поймано первым прогоном, 2026-08-23). Линия земли отличается тем,
    что это ОДИН сплошной отрезок, а фигуры — несколько отрезков с промежутками.
    """
    for row in mask:
        run = best = 0
        for on in row:
            run = run + 1 if on else 0
            best = max(best, run)
        if best > w * min_share:
            for x in range(w):
                row[x] = False


def anchor_width(fr: Image.Image, rgb: tuple[int, int, int], tol: int) -> int:
    """Ширина «якорного» жёсткого объекта в ВЕРХНЕЙ половине кадра (у нас — каска).

    Зачем: генеративная модель рисует персонажа в каждом кадре немного разного размера
    (замер листа 16 кадров, 2026-08-23: разброс высоты силуэта 22 % при норме колебания
    корпуса при ходьбе 3-6 %, плюс систематическая разница ~8 % между рядами листа). По
    высоте силуэта нормировать НЕЛЬЗЯ — она обязана меняться в цикле (подъём таза). Каска
    же — твёрдый предмет: её ширина в кадре обязана быть постоянной, поэтому она и служит
    эталоном масштаба. Верхняя половина берётся, чтобы не спутать с ботинками того же цвета.
    """
    px = fr.load()
    best = 0
    for y in range(fr.height // 2):
        xs = [
            x for x in range(fr.width)
            if px[x, y][3] > 30
            and all(abs(px[x, y][i] - rgb[i]) <= tol for i in range(3))
        ]
        if xs:
            best = max(best, xs[-1] - xs[0])
    return best


def spans(flags: list[bool], min_len: int) -> list[tuple[int, int]]:
    """Непрерывные участки True длиной >= min_len — [начало, конец)."""
    out = []
    start = None
    for i, on in enumerate(flags):
        if on and start is None:
            start = i
        elif not on and start is not None:
            if i - start >= min_len:
                out.append((start, i))
            start = None
    if start is not None and len(flags) - start >= min_len:
        out.append((start, len(flags)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sheet")
    ap.add_argument("out_dir")
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--name", default="frame")
    ap.add_argument("--bg-tol", type=int, default=40)
    ap.add_argument("--pad", type=int, default=12, help="поля вокруг персонажа в готовом кадре")
    ap.add_argument("--sheet-out", default="", help="куда сложить контактный лист для приёмки")
    args = ap.parse_args()

    im = Image.open(args.sheet).convert("RGBA")
    w, h = im.size
    print(f"лист: {w}x{h}, ожидаем {args.cols}x{args.rows} = {args.cols * args.rows} кадров")

    mask = background_mask(im, args.bg_tol)
    strip_long_lines(mask, w)

    row_has = [any(row) for row in mask]
    row_spans = spans(row_has, min_len=int(h * 0.05))
    print(f"найдено рядов: {len(row_spans)} (ожидалось {args.rows})")

    frames: list[Image.Image] = []
    for (y0, y1) in row_spans:
        col_has = [any(mask[y][x] for y in range(y0, y1)) for x in range(w)]
        col_spans = spans(col_has, min_len=int(w * 0.01))
        print(f"  ряд y={y0}..{y1}: колонок {len(col_spans)}")
        for (x0, x1) in col_spans:
            # точный bbox именно этого кадра (без пустых полей ряда)
            ys = [y for y in range(y0, y1) if any(mask[y][x] for x in range(x0, x1))]
            frames.append(im.crop((x0, ys[0], x1, ys[-1] + 1)))

    expected = args.cols * args.rows
    if len(frames) != expected:
        print(f"⚠️  найдено {len(frames)} кадров вместо {expected} — проверь --bg-tol и лист")

    # --- выравнивание: общий холст, подошва и центр силуэта совпадают у всех кадров ---
    max_w = max(f.width for f in frames)
    max_h = max(f.height for f in frames)
    canvas_w = max_w + args.pad * 2
    canvas_h = max_h + args.pad * 2

    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    aligned = []
    for i, fr in enumerate(frames):
        # фон уже не нужен: делаем его прозрачным по тому же признаку цвета
        fr = fr.convert("RGBA")
        px = fr.load()
        bg = Image.open(args.sheet).convert("RGBA").load()[2, 2][:3]
        for y in range(fr.height):
            for x in range(fr.width):
                r, g, b, a = px[x, y]
                if all(abs(c - bgc) <= args.bg_tol for c, bgc in zip((r, g, b), bg)):
                    px[x, y] = (r, g, b, 0)

        canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
        # ПОДОШВА на постоянной высоте: низ силуэта прижат к нижнему полю холста
        ox = (canvas_w - fr.width) // 2
        oy = canvas_h - args.pad - fr.height
        canvas.paste(fr, (ox, oy), fr)
        canvas.save(out_dir / f"{args.name}_{i:02d}.png")
        aligned.append(canvas)

    print(f"\nкадров сохранено: {len(aligned)} → {out_dir} (холст {canvas_w}x{canvas_h})")

    if args.sheet_out:
        cols = min(8, len(aligned))
        rows = (len(aligned) + cols - 1) // cols
        contact = Image.new("RGB", (canvas_w * cols, canvas_h * rows), (40, 40, 50))
        for i, fr in enumerate(aligned):
            contact.paste(fr, ((i % cols) * canvas_w, (i // cols) * canvas_h), fr)
        contact.save(args.sheet_out)
        print(f"контактный лист приёмки: {args.sheet_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
