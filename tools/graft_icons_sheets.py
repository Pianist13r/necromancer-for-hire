#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
graft_icons_sheets.py — нарезка и нормализация иконок, нарисованных ГЕНЕРАЦИЕЙ.

    python tools/graft_icons_sheets.py prompts                 # тексты промптов всех листов
    python tools/graft_icons_sheets.py install --sheets <dir>  # нарезка листов в godot/assets/legion/icons

Почему так. Решение владельца 06.10.2026 отменило прежнее правило «иконки рисуются кодом»
(tools/make_icons*.py остаются историей). Иконки рисует модель `qwen-image-3.0-pro` (MCP ali,
ali_image) листами по шесть штук (сетка 3x2) на ровном тёмном фоне; локальный
`remove_background` (isnet-general-use) снимает фон уже с ЦЕЛОГО листа и отдаёт RGBA — он
корректно отделяет все шесть объектов разом (проверено), поэтому вырезание зовётся 13 раз,
а не 75. Этот скрипт только режет готовый RGBA-лист на шесть ячеек и приводит каждую к общему
виду (RGBA 256x256, единые поля), имена файлов = ключи иконок из реестра ниже.

Лист: 2048x1024 (2,1 МП — дешёвый тир $0.04 у qwen-image-3.0-pro), 3 столбца x 2 строки.
Ключи и порядок ячеек держит SHEETS — он же источник и для промптов, и для нарезки.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "godot", "assets", "legion", "icons")

# Стиль утверждён владельцем по пробным листам 06.10.2026 — менять только перечень предметов
# в двух последних строках (см. BRIEF, C:/AI/necro/batches/icons-1006/BRIEF.md).
STYLE = (
    "A single sheet image containing a 3 by 2 grid of six cartoon game UI icons, laid out in six "
    "equal cells with even spacing and thin empty gutters between them, on a flat dark charcoal "
    "background, no text, no letters, no numbers, no watermark. One single centered object per "
    "cell, each object filling about 80 percent of its cell and reading clearly at small size. "
    "Cartoon style, consistent across all six icons: bold clean dark outlines, flat cheerful "
    "colors with only one simple shading tone plus a soft highlight, chunky rounded exaggerated "
    "shapes, slightly simplified details, a friendly hand-drawn storybook look, the palette "
    "limited to bone white, warm amber gold, oxblood red, teal green and muted violet. Slightly "
    "spooky but cute and playful dark-fantasy office theme. "
    "Top row left to right: {top}. Bottom row left to right: {bottom}."
)
# Последний лист — три иконки, а не шесть: 75 УНИКАЛЬНЫХ иконок не делятся на 6 (78 файлов =
# 64 PNG + 14 SVG, но ability_q/w/e лежат и PNG, и SVG одним смыслом — после снятия SVG
# остаётся 75 картинок). Сетка — единственное слово, которое меняется ради арифметики; всё
# остальное (палитра, контур, тема) дословно то же.
STYLE_ROW3 = (
    "A single sheet image containing a single horizontal row of three cartoon game UI icons, laid "
    "out in three equal cells side by side with even spacing and thin empty gutters between them, "
    "on a flat dark charcoal background, no text, no letters, no numbers, no watermark. One single "
    "centered object per cell, each object filling about 80 percent of its cell and reading "
    "clearly at small size. Cartoon style, consistent across all three icons: bold clean dark "
    "outlines, flat cheerful colors with only one simple shading tone plus a soft highlight, "
    "chunky rounded exaggerated shapes, slightly simplified details, a friendly hand-drawn "
    "storybook look, the palette limited to bone white, warm amber gold, oxblood red, teal green "
    "and muted violet. Slightly spooky but cute and playful dark-fantasy office theme. "
    "Left to right: {top}."
)
NEGATIVE = (
    "text, letters, numbers, watermark, signature, logo, multiple objects in one cell, crowded, "
    "busy background, photograph, realistic render, 3d render, grimdark, horror gore"
)

# Листы: n — номер, top/bottom — описания предметов ячеек, keys — имена итоговых PNG (без .png).
SHEETS = [
    {"n": 1,
     "top": ["a small floating pale-teal soul flame with a bright white core",
             "a single thick gold coin stamped with a small cute skull",
             "a glass inkwell full of violet ink with one floating ink drop above it"],
     "bottom": ["a round black cauldron with bubbling teal-green brew and a light bubble",
                "a friendly skeleton skull wearing an orange hard hat",
                "a glass hourglass with red sand in a brass frame"],
     "keys": ["soul", "premium", "hud_mana", "hud_cauldron", "hud_army", "hud_wave"]},
    {"n": 2,
     "top": ["a square staff ID badge on a lanyard showing a tiny skeleton portrait",
             "a golden two-pan balance scale",
             "a closed purple spellbook with a glowing magic eye on its cover"],
     "bottom": ["a single faceted violet gem shaped like a rhombus",
                "a brown leather attache briefcase with a gold clasp",
                "a chunky brass padlock with a steel shackle"],
     "keys": ["branch_hr", "branch_law", "branch_warlock", "hero_point", "shop_general", "tree_lock"]},
    {"n": 3,
     "top": ["a pale-teal soul flame cupped inside an open bone hand",
             "a stout ceramic jar of violet ink with a quill pen resting in it",
             "a round bone-white clock face with a green circular refill arrow around it"],
     "bottom": ["a small skeleton worker standing inside a dashed violet circle",
                "three small skeleton workers standing together in a row",
                "a rolled paper contract scroll beside a gold coin"],
     "keys": ["shop_souls", "shop_mana", "shop_respawn", "shop_range", "shop_staff", "shop_settlement"]},
    {"n": 4,
     "top": ["a steel paperclip with a small pale-blue lightning spark beside it",
             "a blank red door-hanger sign on a loop",
             "two chunky rubber stamp handles, one violet and one oxblood red"],
     "bottom": ["a blank paper timesheet with a small grid of teal dots",
                "a blank paper sheet with a small round clock on it",
                "a steaming white office coffee mug"],
     "keys": ["item_clip_of_fate", "item_do_not_disturb", "item_double_stamp",
              "item_staff_schedule", "item_overtime_sheet", "item_coffee_pass"]},
    {"n": 5,
     "top": ["a steel knuckle-duster with a small fire spark",
             "a golden measuring ruler with tick marks",
             "a dark steel fireproof safe with a round dial and gold handle"],
     "bottom": ["a closed paper envelope with a glowing teal soul orb on top",
                "a red hand megaphone with a handle",
                "a glass bottle of violet ink with a blank label"],
     "keys": ["item_punch_knuckles", "item_precise_ruler", "item_fireproof_safe",
              "item_quarter_bonus", "item_megaphone", "item_wholesale_ink"]},
    {"n": 6,
     "top": ["an oxblood-red concentric shooting target",
             "an open wooden crate with a bone inside",
             "a golden fountain pen with a small sparkle"],
     "bottom": ["a wooden meter panel with a row of small colored indicator lights",
                "a coiled rope noose",
                "a steel lightning rod with two pale-blue lightning bolts"],
     "keys": ["item_bounty_hunter", "item_lost_found", "item_golden_pen",
              "item_piecework_meter", "item_auditor_noose", "item_lightning_rod"]},
    {"n": 7,
     "top": ["a wooden rubber stamp with a bright fire burst above it",
             "a blank paper contract with a dark wax blob and a small burning wick",
             "an oxblood-red wax seal with a tiny flame"],
     "bottom": ["a blank folded paper sheet with faint violet echo arcs",
                "a golden hand bell with a small spark",
                "a violet metal ring with a pale-teal lightning bolt"],
     "keys": ["item_exploding_stamp", "item_temp_contract", "item_burning_seal",
              "item_echo_clause", "item_roll_call", "item_ring_lightning"]},
    {"n": 8,
     "top": ["a cute skeleton skull wearing a small gold crown",
             "an oxblood-red horseshoe magnet with a teal soul flame above it",
             "a blank paper sheet with a simple three-bar teal and violet chart"],
     "bottom": ["a small black cauldron with a red wax seal and a spark",
                "a green rubber stamp resting on a small blank paper slip",
                "two crossed fountain pens, one violet and one pale steel"],
     "keys": ["item_elite_hr", "item_soul_magnet", "item_quarterly_report",
              "item_cauldron_ward", "item_named_stamp", "item_spare_pen"]},
    {"n": 9,
     "top": ["a round stopwatch with a small green arc",
             "a tight cluster of five cute skeleton skulls",
             "a brown office door with a green arrow pointing out"],
     "bottom": ["a gold payout coin with a small red alarm clock resting on it",
                "a brass speaking-trumpet horn with sound arcs",
                "a magnifying glass over a blank paper with faint lines"],
     "keys": ["perk_fast_hire", "perk_big_staff", "perk_brisk_exit",
              "perk_settlement_on_time", "perk_far_call", "perk_fine_print"]},
    {"n": 10,
     "top": ["a dark round timer dial with a narrow violet slice",
             "a pale-teal lightning bolt forking into two small red sparks",
             "a yellow crescent moon with a small orange alarm clock"],
     "bottom": ["a blank paper sheet with a big green plus sign",
                "a bold pale-violet lightning bolt with a soft glow",
                "a raised parchment contract with a red wax seal stamped with a tiny skull"],
     "keys": ["perk_short_cd", "perk_chain_reaction", "perk_overtime",
              "item_prolongation", "ability_q", "ability_w"]},
    {"n": 11,
     "top": ["a brass-framed hourglass with amber sand",
             "a rolled parchment contract with a green wax seal and a quill pen",
             "a violet shield crest with a small skeleton skull"],
     "bottom": ["a brown leather briefcase with a small gold skull emblem",
                "a folded parchment map with a dashed route and a small teal pin",
                "an open book with a quill pen"],
     "keys": ["ability_e", "menu_play", "menu_hero", "menu_office", "menu_map", "menu_guide"]},
    {"n": 12,
     "top": ["a bronze gear cog",
             "a brown door with a pale-teal arrow pointing out through it",
             "two crossed swords"],
     "bottom": ["a desk calendar page with a gold star",
                "a thick bronze infinity symbol",
                "a small stack of parchment contract cards on a bronze keyring"],
     "keys": ["menu_settings", "menu_exit", "menu_pvp", "menu_daily", "menu_endless", "menu_collection"]},
    {"n": 13,
     "top": ["a rolled paper contract scroll with an orange wax seal",
             "a rolled paper contract scroll with a steel-blue wax seal",
             "a rolled paper contract scroll with a teal-green wax seal"],
     "bottom": [],
     "keys": ["contract_laborer", "contract_guard", "contract_clerk"]},
]


# Метаданные вызовов ali_image (call_id / request_id из ответа инструмента, файл генерации).
REFERENCE = "2026-10-06_qwen-image-3.0-pro_cce82b1c4c_1.png"
CALLS = {
    1: ("0fc5e4fe26", "6ca8986a-77f7-9343-9f91-c68d9bc98519"),
    2: ("9677829e49", "a7ecfd8f-24e7-978c-9f7a-c52339d4046b"),
    3: ("cab16e2a3a", "42d64e91-5494-98e9-8198-ea61a2a08cdd"),
    4: ("1862a09c9a", "6fc151f1-420d-9fb7-a771-045a91a340cb"),
    5: ("b2e8e180a6", "800578fb-8f43-9a77-9c91-6d42a64287a4"),
    6: ("73428b5cf0", "543773d0-752d-9a38-b6cd-e797ca6dbb84"),
    7: ("92f12061b5", "43f18df4-d520-9edd-9c48-c415729d9c78"),
    8: ("7614acb168", "978e2589-79d2-9679-8104-677888058386"),
    9: ("41c322be84", "471d4701-cb26-9475-951d-43c7339122c7"),
    10: ("7695f69e0d", "fccebaba-b674-9579-8706-dd3fb9988987"),
    11: ("d67717592a", "59378fce-eeeb-933d-99ee-1b13d8eba020"),
    12: ("dd667e77d5", "0eeb7aa9-6ea8-9061-be0c-ec550cdb944f"),
    13: ("e6cb2cd498", "092be7f2-06af-9164-b142-84646c0f4969"),
}


def cmd_provenance(args: argparse.Namespace) -> int:
    lines: list[str] = []
    lines.append("### Сводка")
    lines.append("")
    lines.append("| Лист | Файл генерации | Ключи иконок | call_id | request_id |")
    lines.append("|---|---|---|---|---|")
    for s in SHEETS:
        call, req = CALLS[s["n"]]
        f = "%02d/%s_%s_1.png" % (s["n"], "2026-10-06_qwen-image-3.0-pro", call)
        lines.append("| %d | `%s` | %s | `%s` | `%s` |"
                     % (s["n"], f, ", ".join(s["keys"]), call, req))
    lines.append("")
    lines.append("### Промпты листов (дословно)")
    for s in SHEETS:
        lines.append("")
        lines.append("**Лист %d** (`%s`):" % (s["n"], ", ".join(s["keys"])))
        lines.append("")
        lines.append("```text")
        lines.append(prompt_for(s))
        lines.append("```")
        lines.append("")
        lines.append("negative_prompt:")
        lines.append("")
        lines.append("```text")
        lines.append(NEGATIVE)
        lines.append("```")
    text = "\n".join(lines) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.buffer.write(text.encode("utf-8"))
    return 0


def prompt_for(sheet: dict) -> str:
    if sheet["bottom"]:
        return STYLE.format(top=", ".join(sheet["top"]), bottom=", ".join(sheet["bottom"]))
    return STYLE_ROW3.format(top=", ".join(sheet["top"]))


def cell_count(sheet: dict) -> int:
    return len(sheet["keys"])


def cmd_prompts(_args: argparse.Namespace) -> int:
    for sheet in SHEETS:
        print("=" * 100)
        print("SHEET %d  keys=%s  negative=%s" % (sheet["n"], ",".join(sheet["keys"]), NEGATIVE))
        print(prompt_for(sheet))
    return 0


def _normalize(cell: Image.Image, side: int = 256, content: float = 0.86) -> Image.Image:
    """Ячейка листа -> RGBA side x side: обрезать по альфе, вписать с единым полем."""
    cell = cell.convert("RGBA")
    bbox = cell.getchannel("A").getbbox()
    if bbox is not None:
        cell = cell.crop(bbox)
    w, h = cell.size
    scale = (side * content) / max(1, max(w, h))
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    resized = cell.resize((nw, nh), Image.LANCZOS)
    out = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    out.alpha_composite(resized, ((side - nw) // 2, (side - nh) // 2))
    return out


def cmd_install(args: argparse.Namespace) -> int:
    made: list[tuple[str, str]] = []
    for sheet in SHEETS:
        src = os.path.join(args.sheets, "%02d_nobg.png" % sheet["n"])
        if not os.path.isfile(src):
            print("нет листа: %s" % src, file=sys.stderr)
            return 1
        im = Image.open(src).convert("RGBA")
        W, H = im.size
        cols, rows = 3, (2 if len(sheet["keys"]) > 3 else 1)
        cw, ch = W / cols, H / rows
        for i, key in enumerate(sheet["keys"]):
            col, row = i % cols, i // cols
            cell = im.crop((round(col * cw), round(row * ch), round((col + 1) * cw), round((row + 1) * ch)))
            norm = _normalize(cell, args.side, args.content)
            dst = os.path.join(args.out, key + ".png")
            norm.save(dst)
            made.append((key, dst))
    print(json.dumps({"installed": len(made), "out": args.out}, ensure_ascii=False))
    for key, dst in made:
        print("  %-24s -> %s" % (key, dst))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prompts").set_defaults(fn=cmd_prompts)
    prov = sub.add_parser("provenance")
    prov.add_argument("--out", default="")
    prov.set_defaults(fn=cmd_provenance)
    inst = sub.add_parser("install")
    inst.add_argument("--sheets", default="C:/AI/necro/batches/icons-1006/sheets")
    inst.add_argument("--out", default=ICON_DIR)
    inst.add_argument("--side", type=int, default=256)
    inst.add_argument("--content", type=float, default=0.86)
    inst.set_defaults(fn=cmd_install)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
