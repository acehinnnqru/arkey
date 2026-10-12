#!/usr/bin/env python3
"""Draw the legacy placeholder icon from the keyboard's own measured palette.

The original icon was a placeholder: an app store build needs one.
Rather than invent a visual identity, it draws the mark every keyboard needs a word for — 中 — in the colours
S3 §4 measured (the dark backing and the action blue), so it looks like the app it belongs to. Replace
AppIcon-1024.png and friends with real artwork when there is any; nothing in the build depends on how they look,
and the release check only insists that an icon is there.

The asset catalog now contains glass artwork. This script is retained only as an explicit fallback;
it must not overwrite that artwork during routine development.

Usage: scripts/make-app-icon.py --replace-with-placeholder
"""
import argparse
import struct
import zlib
from pathlib import Path

SIZE = 1024
DARK_BACKING = (0x16, 0x16, 0x16)
ACTION_BLUE = (0x33, 0x78, 0xF4)
WHITE = (0xFF, 0xFF, 0xFF)
BLACK = (0x00, 0x00, 0x00)

# 中 as five rectangles: the box, its top and bottom strokes, and the bar through them.
BOX_LEFT, BOX_RIGHT = int(SIZE * 0.30), int(SIZE * 0.70)
BOX_TOP, BOX_BOTTOM = int(SIZE * 0.32), int(SIZE * 0.68)
BOX_STROKE = int(SIZE * 0.075)
BAR_LEFT, BAR_RIGHT = int(SIZE * 0.4625), int(SIZE * 0.5375)
BAR_TOP, BAR_BOTTOM = int(SIZE * 0.22), int(SIZE * 0.78)


def rectangles(colour):
    """The glyph as (left, top, right, bottom, colour) rectangles, all of them inside the safe area."""
    return [
        (BOX_LEFT, BOX_TOP, BOX_RIGHT, BOX_TOP + BOX_STROKE, colour),
        (BOX_LEFT, BOX_BOTTOM - BOX_STROKE, BOX_RIGHT, BOX_BOTTOM, colour),
        (BOX_LEFT, BOX_TOP, BOX_LEFT + BOX_STROKE, BOX_BOTTOM, colour),
        (BOX_RIGHT - BOX_STROKE, BOX_TOP, BOX_RIGHT, BOX_BOTTOM, colour),
        (BAR_LEFT, BAR_TOP, BAR_RIGHT, BAR_BOTTOM, colour),
    ]


def rows(background, mark):
    for y in range(SIZE):
        line = bytearray()
        for x in range(SIZE):
            colour = background
            for left, top, right, bottom, fill in rectangles(mark):
                if left <= x < right and top <= y < bottom:
                    colour = fill
                    break
            line += bytes(colour)
        yield bytes(line)


def write_png(path, background, mark):
    raw = b"".join(b"\x00" + line for line in rows(background, mark))

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    print("wrote", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replace-with-placeholder", action="store_true",
                        help="Replace the current artwork with the legacy placeholder icons.")
    if not parser.parse_args().replace_with_placeholder:
        parser.exit(0, "Current app icon artwork preserved. Use --replace-with-placeholder to replace it.\n")
    catalog = Path(__file__).resolve().parent.parent / "arkey/Assets.xcassets/AppIcon.appiconset"
    # The three appearances the asset catalog asks for: the default, the dark one, and the tinted one, which
    # iOS wants as a grayscale image it can tint itself.
    write_png(catalog / "AppIcon-1024.png", DARK_BACKING, ACTION_BLUE)
    write_png(catalog / "AppIcon-1024-dark.png", BLACK, ACTION_BLUE)
    write_png(catalog / "AppIcon-1024-tinted.png", WHITE, BLACK)


if __name__ == "__main__":
    main()
