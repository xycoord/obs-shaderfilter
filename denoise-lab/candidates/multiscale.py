"""Frequency-split denoiser (council round 1, idea agreed by all four judges).

The camera's noise sits almost entirely below ~0.2 cycles/px while fine texture sits
above, so: denoise the full-resolution picture lightly (MDegrain, short radius) and
take only its fine band; denoise downscaled copies hard (long radius) and take
their coarse bands. Reconstruction:
    out = D0 - up(down(D0)) + up(D1')      where D1' is built the same way from levels 1, 2.
If the coarse levels did nothing beyond downscaling D0, out == D0 exactly.
"""
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lab import denoisers  # noqa: E402


def down(x, sigma=1.0):
    """Blur then take every second pixel ([T, H, W, C], H and W even)."""
    return ndimage.gaussian_filter(x, (0, sigma, sigma, 0))[:, ::2, ::2]


def up(x, shape):
    """Bilinear upsample back to ``shape`` (T, H, W, C)."""
    t, h, w, c = shape
    return ndimage.zoom(x, (1, h / x.shape[1], w / x.shape[2], 1), order=1, mode="nearest", grid_mode=True)


def _pad_even(x, mult):
    h, w = x.shape[1:3]
    ph, pw = (-h) % mult, (-w) % mult
    if ph or pw:
        x = np.pad(x, ((0, 0), (0, ph), (0, pw), (0, 0)), mode="edge")
    return x, h, w


def denoise(frames, levels=2, tr0=2, th0=400, tr1=6, th1=400, blk1=8, tr2=6, th2=400, blk2=8, sigma=1.0):
    x, h, w = _pad_even(np.asarray(frames, np.float32), 2 ** levels * 8)
    d0 = denoisers.run("mdegrain", x, tr=tr0, thsad=th0)
    # Build the coarse estimate from the bottom level up.
    l1 = down(x, sigma)
    d1 = denoisers.run("mdegrain", l1, tr=tr1, thsad=th1, blksize=blk1, overlap=blk1 // 2)
    if levels >= 3:
        l2 = down(l1, sigma)
        d2 = denoisers.run("mdegrain", l2, tr=tr2, thsad=th2, blksize=blk2, overlap=blk2 // 2)
        d1 = d1 - up(down(d1, sigma), d1.shape) + up(d2, d1.shape)
    out = d0 - up(down(d0, sigma), d0.shape) + up(d1, d0.shape)
    return out[:, :h, :w]
