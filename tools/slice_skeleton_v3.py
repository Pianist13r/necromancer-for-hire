#!/usr/bin/env python3
"""
Нарезка мастера скелета v3 — лечение вердикта «склеен из двух частей» (сессия 2026-08-26).

Чем v3 отличается от v2 (slice_skeleton_v2.py):
  v2 резал ноги ГОРИЗОНТАЛЬЮ ПОСРЕДИ ШОРТ (y=580-585): верхняя половина кропа ноги — кусок
  зелёных шорт, при повороте ноги срез ездил по статичным шортам тела — тот самый шов.
  v3 режет по канону cut-up для скелетной 2D-анимации (ресёрч 2026-08-26: рез по суставам +
  перекрытия): ТЕЛО владеет шортами целиком, включая подол и его тёмный контур; НОГА владеет
  всем, что ниже контура (носок+ботинок), плюс СИНТЕЗИРОВАННАЯ светлая «трубка» вверх до
  тазового пивота — она спрятана под шортами и показывается только краем при махе.
  Z-порядок при этом меняется: ОБЕ ноги рисуются ПОД телом (в v2 ближняя была поверх).

Граница «тело/нога» ищется ПО КОЛОНКАМ, а не одной горизонталью: в колонке x тело
забирает пиксели до конца зелёной массы шорт и примыкающего снизу тёмного контура,
нога — всё, что ниже. Так контур подола остаётся ЦЕЛЫМ на теле (не двоится и не ездит).

Источник: assets/img/skeleton_v2.png (832x832, прозрачный фон).
Выход: godot/assets/parts/{body_v3,leg_near_v3,leg_far_v3}.png
     + skeleton_rig_v3.json + leg_meta_v3.json (голова/инструмент — ссылки на файлы v2,
       их нарезка не менялась).

Запуск (из корня репо):  python tools/slice_skeleton_v3.py
"""
import json
import pathlib
import statistics

from PIL import Image

SRC = pathlib.Path("assets/img/skeleton_v2.png")
OUT_DIR = pathlib.Path("godot/assets/parts")
V2_RIG = OUT_DIR / "skeleton_rig_v2.json"

# Пивот таза и земля — te же, что в cfg.gd (RIG_PELVIS_IN_MASTER / RIG_GROUND_IN_MASTER):
#游戏ные числа походки не трогаем, меняется только раскрой текстур.
HIP_Y = 584.5

# y 419..710, x от 175: торс + ВСЕ шорты с контуром подола + КИРКА ЦЕЛИКОМ (голова
# кирки слева доходит до x≈180 и вниз до y≈709). Кирка ЗАПЕЧЕНА в тело: отдельный спрайт
# инструмента в v2 был сырым бокс-кропом с копией всего низа персонажа и качался поверх
# настоящих ног («нижняя часть качается», вердикт v7), а чистая маска кирки по цвету
# нестабильна (крем кости малонасыщен, как сталь). В ходьбе руки статичны — статичная кирка
# в статичных руках выглядит честно; замах киркой живёт в клипах (char_anim), не в риге.
# ⚠️ y0=419, НЕ 380: ряды 375-418 мастера — ТОЛЬКО череп (замер пробегами 2026-08-26), а
# кроп головы кончается на y=418. Прежний y0=380 запекал низ черепа в ОБА спрайта, и копия
# челюсти из тела выглядывала из-за поворачивающейся головы «плавающим шипом» (вердикт
# владельца «часть черепа странно себя ведёт») — тот же класс бага, что кирка v2.
BODY_BOX = (175, 419, 475, 291)
LEG_XRANGES = {"near": (305, 440), "far": (430, 565)}
LEG_TOP = 578                             # чуть выше тазового пивота (запас для меша)
LEG_BOT = 778                             # ниже подошвы (земля 769)
# Подол шорт: зелёная масса кончается на y≈661-664 (замер профилем 2026-08-26).
HEM_DEFAULT = 663                         # для колонок без зелени выше (раструб ботинка)
OUTLINE_MAX = 16                          # потолок толщины тёмного контура под зеленью, px
# Сустав сгиба ноги («щиколотка», серо-зелёная манжета носка) ищется минимумом ширины
# силуэта в этом диапазоне y мастера — метод v2, диапазон сдвинут под новый кроп.
JOINT_Y_RANGE = (683, 710)
# Боксы ног перекрываются на x≈424-446 (ботинки визуально соприкасаются). Пиксель в этой
# полосе принадлежит тому ботинку, к чьей оранжевой компоненте он ближе (BFS от оранжевых
# семян обоих ботинков): без этого куски чужого ботинка ездили «не с той» ногой (проверено
# рендером — плавающие тёмные завитки у заднего ботинка).
OVERLAP_X = (424, 446)
BOOT_ZONE_Y = (688, 778)
TUBE_MIN_RUN = 46                         # минимальная ширина сплошного ряда носка для трубки


def alpha(px, x, y) -> int:
    return px[x, y][3]


def is_green(px, x, y) -> bool:
    r, g, b, a = px[x, y]
    return a > 100 and g > 110 and g > r + 30 and g > b + 30


def is_dark(px, x, y) -> bool:
    r, g, b, a = px[x, y]
    return a > 100 and (r + g + b) < 330


def is_orange(px, x, y) -> bool:
    r, g, b, a = px[x, y]
    return a > 100 and r > 170 and 50 < g < 150 and b < 90


def boot_ownership(px) -> dict:
    """Разметка полосы перекрытия ботинок: multi-source BFS от оранжевых пикселей каждого
    ботинка (семена — колонки заведомо своей стороны), метка = чей источник ближе.
    Возвращает {(x,y): 'near'|'far'} только для полосы OVERLAP_X."""
    from collections import deque
    y0, y1 = BOOT_ZONE_Y
    queue = deque()
    label: dict[tuple[int, int], str] = {}
    for y in range(y0, y1):
        for x in range(300, 570):
            if not is_orange(px, x, y):
                continue
            side = "near" if x < OVERLAP_X[0] else ("far" if x > OVERLAP_X[1] else None)
            if side:
                label[(x, y)] = side
                queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if not (300 <= nx < 570 and y0 <= ny < y1):
                continue
            if (nx, ny) in label or alpha(px, nx, ny) <= 100:
                continue
            label[(nx, ny)] = label[(x, y)]
            queue.append((nx, ny))
    return {k: v for k, v in label.items() if OVERLAP_X[0] <= k[0] <= OVERLAP_X[1]}


def smooth_boundaries(raw: dict[int, int]) -> dict[int, int]:
    """Медиана по окну ±3 колонки: одиночные выбросы границы (тёмно-зелёная тень подола не
    прошла порог зелени) выедали белые зазубрины в подоле — сглаживание их закрывает."""
    xs = sorted(raw)
    out = {}
    for x in xs:
        window = [raw[nx] for nx in range(x - 3, x + 4) if nx in raw]
        out[x] = int(statistics.median(window))
    return out


def column_boundary(px, x: int) -> int:
    """Последний y, принадлежащий ТЕЛУ в колонке x: конец зелёной массы ШОРТ + примыкающий
    снизу тёмный контур. Зелень в колонке бывает трижды (жилет, шорты, полоска носка), и они
    не всегда контачат — поэтому берётся САМАЯ НИЖНЯЯ серия, кончающаяся не глубже подола
    (HEM_DEFAULT+12): полоска носка (y≈685-695) под этот потолок не проходит и остаётся ноге."""
    green_end = None
    y = 470
    while y < HEM_DEFAULT + 13:
        if is_green(px, x, y):
            run_end = y
            while run_end + 1 < 720 and is_green(px, x, run_end + 1):
                run_end += 1
            if run_end <= HEM_DEFAULT + 12:
                green_end = run_end
            y = run_end + 1
        else:
            y += 1
    if green_end is None:
        return HEM_DEFAULT
    boundary = green_end
    steps = 0
    while steps < OUTLINE_MAX and boundary + 1 < 730 and is_dark(px, x, boundary + 1):
        boundary += 1
        steps += 1
    return boundary


def solid_run(im: Image.Image, y: int) -> tuple[int, int] | None:
    """Самая длинная непрерывная серия непрозрачных пикселей строки y кропа."""
    px = im.load()
    best, cur = None, None
    for x in range(im.width):
        if px[x, y][3] > 100:
            cur = [x, x] if cur is None else [cur[0], x]
        else:
            if cur and (best is None or cur[1] - cur[0] > best[1] - best[0]):
                best = tuple(cur)
            cur = None
    if cur and (best is None or cur[1] - cur[0] > best[1] - best[0]):
        best = tuple(cur)
    return best


def build_leg(im: Image.Image, key: str, boundaries: dict[int, int], boot_own: dict) -> dict:
    px = im.load()
    x0, x1 = LEG_XRANGES[key]
    w, h = x1 - x0, LEG_BOT - LEG_TOP
    crop = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cpx = crop.load()

    # 1. Реальные пиксели ноги: всё ниже границы тела в каждой колонке; в полосе перекрытия
    # ботинок пиксель берётся, только если BFS-разметка отдала его ЭТОМУ ботинку.
    for x in range(x0, x1):
        y_from = max(LEG_TOP, boundaries[x] + 1)
        overlap = OVERLAP_X[0] <= x <= OVERLAP_X[1]
        for y in range(y_from, LEG_BOT):
            if overlap and boot_own.get((x, y)) != key:
                continue
            c = px[x, y]
            if c[3] > 0:
                cpx[x - x0, y - LEG_TOP] = c

    # 2. Верх носка — первый ряд со сплошной серией достаточной ширины: он задаёт колонки
    # и стык синтетической трубки.
    sock_y = None
    sock_run = None
    for y in range(0, h):
        run = solid_run(crop, y)
        if run and run[1] - run[0] >= TUBE_MIN_RUN:
            sock_y, sock_run = y, run
            break
    if sock_y is None:
        raise SystemExit(f"нога {key}: не найден сплошной ряд носка (TUBE_MIN_RUN={TUBE_MIN_RUN})")

    # 2b. Всё ВЫШЕ верха носка — транзитный мусор стыка (обрезки контура подола, полузелёная
    # кромка): в покое его закрывает подол, в махе он вылезал «рваной бумагой» (рендер
    # 2026-08-26). Сносим — это место займёт трубка.
    for y in range(0, max(0, sock_y - 3)):
        for x in range(w):
            if cpx[x, y][3] > 0:
                cpx[x, y] = (0, 0, 0, 0)

    # 3. Синтетическая трубка от верха кропа до реальных пикселей каждой колонки: ЗЕЛЁНАЯ
    # ШТАНИНА с тёмным контуром по краям. Была светлая «кость» — в махе выглядывала из-под
    # подола «белым обрубком» (вердикт владельца). Зелёная трубка читается как штанина шорт,
    # следующая за ногой: выглядывание ткани при махе естественно. Цвет — медиана зелени
    # шорт прямо над подолом этой ноги, контур — медиана тёмного кластера носка.
    px_master = im.load()
    greens, dark = [], []
    for y in range(HEM_DEFAULT - 34, HEM_DEFAULT - 4):
        for x in range(x0, x1):
            if is_green(px_master, x, y):
                greens.append(px_master[x, y])
    for y in range(sock_y, min(sock_y + 22, h)):
        for x in range(w):
            c = cpx[x, y]
            if c[3] > 100 and (c[0] + c[1] + c[2]) < 330:
                dark.append(c)
    fill = (tuple(int(statistics.median(c[i] for c in greens)) for i in range(3)) + (255,)
            ) if len(greens) >= 30 else (109, 190, 68, 255)
    edge = (tuple(int(statistics.median(c[i] for c in dark)) for i in range(3)) + (255,)
            ) if len(dark) >= 30 else (16, 15, 66, 255)
    outline_w = 4
    for x in range(sock_run[0], sock_run[1] + 1):
        col = edge if (x - sock_run[0] < outline_w or sock_run[1] - x < outline_w) else fill
        y = 0
        while y < h and cpx[x, y][3] <= 100:
            cpx[x, y] = col
            y += 1

    out_name = f"leg_{key}_v3"
    crop.save(OUT_DIR / f"{out_name}.png")

    # 4. Опорные точки. Бедро: центр трубки на уровне тазового пивота. Сустав сгиба:
    # минимум ширины силуэта в JOINT_Y_RANGE (манжета над ботинком) — метод v2.
    hip_x = (sock_run[0] + sock_run[1]) / 2.0
    best_y, best_w, best_cx = None, 10 ** 9, None
    for ym in range(JOINT_Y_RANGE[0], JOINT_Y_RANGE[1]):
        run = solid_run(crop, ym - LEG_TOP)
        if run and run[1] - run[0] < best_w:
            best_y, best_w, best_cx = ym, run[1] - run[0], (run[0] + run[1]) / 2.0
    sole = 0
    for y in range(h - 1, -1, -1):
        if solid_run(crop, y):
            sole = y
            break

    meta = {
        "file": f"res://assets/parts/{out_name}.png",
        "w": w, "h": h,
        "box_origin": [x0, LEG_TOP],
        "hip_in_crop": [hip_x, HIP_Y - LEG_TOP],
        "knee_in_crop": [best_cx, float(best_y - LEG_TOP)],
        "sole_row": sole,
        "sock_top_row": sock_y,
    }
    print(f"  {key:<5} hip_x={hip_x:.1f} knee=({best_cx:.1f},{best_y}) "
          f"sock_y={sock_y} sole={sole} tube_cols={sock_run}")
    return meta


def build_body(im: Image.Image, boundaries: dict[int, int]) -> Image.Image:
    """Тело: весь бокс (кирка запечена, см. BODY_BOX), но в зоне ног ниже границы колонки
    пиксели не берутся — носки и ботинки не должны статично дублироваться поверх подвижных
    ног. Колонки левее ног (x<325: рука, кисть, голова кирки со спицей) берутся целиком."""
    px = im.load()
    bx, by, bw, bh = BODY_BOX
    crop = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    cpx = crop.load()
    for x in range(bx, bx + bw):
        limit = boundaries.get(x) if x >= 325 else None
        for y in range(by, by + bh):
            if limit is not None and y > limit:
                continue
            c = px[x, y]
            if c[3] > 0:
                cpx[x - bx, y - by] = c
    crop.save(OUT_DIR / "body_v3.png")
    return crop


def main() -> None:
    im = Image.open(SRC).convert("RGBA")
    px = im.load()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Граница тело/нога по всем колонкам, где вообще есть силуэт ниже пояса.
    boundaries = smooth_boundaries(
        {x: column_boundary(px, x) for x in range(BODY_BOX[0], BODY_BOX[0] + BODY_BOX[2])})
    boot_own = boot_ownership(px)

    v2 = json.loads(V2_RIG.read_text(encoding="utf-8"))
    pelvis = [423.8, HIP_Y]   # cfg.RIG_PELVIS_IN_MASTER — источник истины не здесь

    body_meta = {
        "file": "res://assets/parts/body_v3.png",
        "w": BODY_BOX[2], "h": BODY_BOX[3],
        "offset_from_center": [BODY_BOX[2] / 2.0 - (pelvis[0] - BODY_BOX[0]),
                               BODY_BOX[3] / 2.0 - (pelvis[1] - BODY_BOX[1])],
        "pivot_in_crop": [pelvis[0] - BODY_BOX[0], pelvis[1] - BODY_BOX[1]],
        "pivot_in_master": pelvis,
    }
    build_body(im, boundaries)

    rig = {
        "source": str(SRC).replace("\\", "/"),
        "parts": {
            "body": body_meta,
            "head": v2["parts"]["head"],   # нарезка головы не менялась — файл v2
        },
    }
    leg_meta = {key: build_leg(im, key, boundaries, boot_own) for key in ("far", "near")}

    (OUT_DIR / "skeleton_rig_v3.json").write_text(
        json.dumps(rig, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT_DIR / "leg_meta_v3.json").write_text(
        json.dumps(leg_meta, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"→ {OUT_DIR}: body_v3.png, leg_near_v3.png, leg_far_v3.png + json v3")


if __name__ == "__main__":
    main()
