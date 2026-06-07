#!/usr/bin/env python3
"""Generate a retina DMG background image (pure stdlib, no Pillow)."""

import struct
import zlib
import sys
import os

WIDTH = 1320
HEIGHT = 800

TOP = (0xFF, 0xF8, 0xF0)
BOTTOM = (0xFF, 0xF0, 0xE8)


def _lerp(a, b, t):
    return int(a + (b - a) * t + 0.5)


def _png_chunk(chunk_type, data):
    chunk = chunk_type + data
    return struct.pack(">I", len(data)) + chunk + struct.pack(">I", zlib.crc32(chunk) & 0xFFFFFFFF)


def create_png(output_path):
    raw = bytearray()
    for y in range(HEIGHT):
        raw.append(0)  # filter byte: None
        t = y / (HEIGHT - 1)
        r = _lerp(TOP[0], BOTTOM[0], t)
        g = _lerp(TOP[1], BOTTOM[1], t)
        b = _lerp(TOP[2], BOTTOM[2], t)
        raw.extend(bytes([r, g, b]) * WIDTH)

    ihdr = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    compressed = zlib.compress(bytes(raw), 9)

    with open(output_path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_png_chunk(b"IHDR", ihdr))
        f.write(_png_chunk(b"IDAT", compressed))
        f.write(_png_chunk(b"IEND", b""))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "build/dmg-background@2x.png"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    create_png(out)
    print(f"Generated {out} ({WIDTH}x{HEIGHT})")
