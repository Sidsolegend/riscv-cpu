#!/usr/bin/env python3
"""Rasterize ASCII 0x20..0x7F into a fixed-cell bitmap font.

    python3 tools/genfont.py > fpga/font6x12.hex             # st7789_term.v
    python3 tools/genfont.py --cell 8x16 > fpga/font8x16.hex # hdmi_term.v

One $readmemh line per glyph row, 96 glyphs x CH rows, each row CW bits with
the leftmost pixel as the MSB. Defaults to DejaVu Sans Mono (free license)
from matplotlib's bundled fonts. The .hex files are committed, so PIL is
only needed if you want to regenerate them.
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# cell -> (point size, source row that maps to glyph row 0); both tuned so
# every glyph's ascenders and descenders land inside the cell
CELLS = {"6x12": (10, 1), "8x16": (13, 1)}


def default_font():
    import matplotlib
    return os.path.join(matplotlib.get_data_path(), "fonts", "ttf", "DejaVuSansMono.ttf")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("font", nargs="?", default=None)
    ap.add_argument("--cell", choices=sorted(CELLS), default="6x12")
    args = ap.parse_args()
    CW, CH = (int(v) for v in args.cell.split("x"))
    SIZE, ROW0 = CELLS[args.cell]
    font = ImageFont.truetype(args.font or default_font(), SIZE)
    for code in range(0x20, 0x80):
        img = Image.new("1", (CW + 8, CH + ROW0 + 4), 0)
        d = ImageDraw.Draw(img)
        d.fontmode = "1"
        d.text((0, 0), chr(code) if code != 0x7F else " ", font=font, fill=1)
        # a glyph that overhangs the cell (DejaVu's "R") gets nudged left, not clipped
        bbox = img.getbbox()
        if bbox and bbox[2] > CW:
            img = Image.new("1", img.size, 0)
            d = ImageDraw.Draw(img)
            d.fontmode = "1"
            d.text((CW - bbox[2], 0), chr(code), font=font, fill=1)
        for r in range(CH):
            bits = 0
            for c in range(CW):
                bits = (bits << 1) | (1 if img.getpixel((c, r + ROW0)) else 0)
            print(f"{bits:0{(CW + 3) // 4}x}")


if __name__ == "__main__":
    main()
