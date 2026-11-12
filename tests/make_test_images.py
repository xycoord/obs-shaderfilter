#!/usr/bin/env python3
"""Generate the deterministic test images used by the harness.

    make_test_images.py OUTDIR [WIDTH HEIGHT]

main.png: gradients, colour bars, fine detail, soft-edged shapes, and regions
          that are fully transparent and semi-transparent (alpha handling is
          the part of a filter chain most easily broken).
alt.png:  a different, mostly opaque pattern used as the second input of
          transitions and as a texture/source parameter.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def main_image(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    u, v = x / (w - 1), y / (h - 1)
    r = u.copy()
    g = v.copy()
    b = 0.5 + 0.5 * np.sin(6.2831 * (u * 2.0 + v))
    a = np.ones_like(u)

    # Colour bars across the top fifth.
    bars = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0)]
    top = v < 0.2
    idx = np.clip((u * len(bars)).astype(int), 0, len(bars) - 1)
    for i, c in enumerate(bars):
        m = top & (idx == i)
        r[m], g[m], b[m] = c

    # Fine checkerboard (1px and 4px) in a block: catches resampling errors.
    blk = (u > 0.05) & (u < 0.25) & (v > 0.3) & (v < 0.5)
    chk1 = ((x.astype(int) + y.astype(int)) % 2).astype(np.float32)
    r[blk] = g[blk] = b[blk] = chk1[blk]
    blk4 = (u > 0.05) & (u < 0.25) & (v > 0.55) & (v < 0.75)
    chk4 = (((x.astype(int) // 4) + (y.astype(int) // 4)) % 2).astype(np.float32)
    r[blk4] = chk4[blk4]
    g[blk4] = 0.25 + 0.5 * chk4[blk4]
    b[blk4] = 1.0 - chk4[blk4]

    # Soft-edged discs with partial alpha.
    for cx, cy, rad, col, alpha in [
        (0.45, 0.5, 0.12, (1.0, 0.3, 0.1), 1.0),
        (0.62, 0.55, 0.10, (0.1, 0.4, 1.0), 0.6),
        (0.55, 0.75, 0.08, (0.2, 1.0, 0.3), 0.35),
    ]:
        d = np.sqrt(((u - cx) * w / h) ** 2 + (v - cy) ** 2)
        cov = np.clip((rad - d) / 0.01, 0, 1)
        r = r * (1 - cov) + col[0] * cov
        g = g * (1 - cov) + col[1] * cov
        b = b * (1 - cov) + col[2] * cov
        a = a * (1 - cov) + alpha * cov

    # Right side: fully transparent band, then an alpha ramp.
    a = np.where(u > 0.8, 0.0, a)
    ramp = (u > 0.7) & (u <= 0.8)
    a = np.where(ramp, (0.8 - u) / 0.1, a)
    # Bottom strip: constant 50% alpha.
    a = np.where(v > 0.9, 0.5, a)

    rgba = np.stack([r, g, b, a], axis=-1)
    return Image.fromarray((np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def alt_image(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    u, v = x / (w - 1), y / (h - 1)
    stripes = (np.floor(u * 12) % 2).astype(np.float32)
    r = 0.2 + 0.6 * stripes
    g = 0.5 + 0.5 * np.cos(6.2831 * v * 3)
    b = 1.0 - 0.7 * u
    a = np.where((u - 0.5) ** 2 + (v - 0.5) ** 2 < 0.02, 0.7, 1.0)
    rgba = np.stack([r, g, b, a], axis=-1)
    return Image.fromarray((np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


if __name__ == "__main__":
    out = Path(sys.argv[1])
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 640
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 360
    out.mkdir(parents=True, exist_ok=True)
    main_image(w, h).save(out / f"main_{w}x{h}.png")
    alt_image(w, h).save(out / f"alt_{w}x{h}.png")
