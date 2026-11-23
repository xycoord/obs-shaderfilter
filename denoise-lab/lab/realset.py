"""Real-footage measure: denoising error on genuine camera noise, in static areas.

The camera's HEVC uses a 12-frame GOP, and frames one GOP apart carry independent
noise (measured: their noise correlation is at the level of the measurement's own
noise floor). So in areas where nothing moves, raw frame t+12 is an independent
noisy copy of frame t's picture. Denoise frame t (using its neighbours t-6..t+6),
compare with raw frame t+12, and subtract the noise level estimated from the raw
pair: what remains is the true error of the denoiser, on real noise, with no clean
reference needed. Moving areas aren't covered; the synthetic set handles motion.

Each item stores a 960x540 full-resolution crop: the 13-frame window around t, the
raw frame t+12, and the static mask.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from scipy import ndimage

from . import colour_pipeline as cp, video_io as vio
from .noise_model import GOP, NoiseModel

HALF = 6          # window is t-HALF .. t+HALF
H, W = 540, 960
T_CANDIDATES = range(GOP + GOP // 2, 97, GOP)  # GOP position 6, room for t+24


def _luma(x):
    return x.mean(-1)


def static_mask(a, b, c, model: NoiseModel | None) -> np.ndarray:
    """Where frames a, b (= a + 1 GOP) and c (= b + 1 GOP) show the same picture (DI, [H, W, 3])."""
    la, lb, lc = _luma(a), _luma(b), _luma(c)
    still = (np.abs(ndimage.gaussian_filter(lb - la, 8)) < 0.003) & (np.abs(ndimage.gaussian_filter(lc - lb, 8)) < 0.003)
    # Fine-detail check: the difference must look like noise alone, not like moved texture.
    local = ndimage.uniform_filter((lb - la) ** 2, 16)
    if model is not None:
        sig = np.array([np.sqrt(np.ones(3) @ c_ @ np.ones(3) / 9) for c_ in model.cov])
        expected = 2 * np.interp(ndimage.gaussian_filter(la, 4), model.bins, sig) ** 2
        still &= local < 2.5 * expected
    else:
        still &= local < 4 * np.median(local)
    # The low-pass test is itself noisy, so the raw mask is speckled: fill small holes
    # first, then pull back from the edges of moving areas.
    still = ndimage.binary_closing(still, structure=np.ones((9, 9), bool))
    return ndimage.binary_erosion(still, iterations=4)


def build(clip: Path, out_dir: Path, model: NoiseModel, n_items: int = 2) -> list[str]:
    """Choose the stillest (t, crop) pairs in a clip and save them."""
    need = set()
    for t in T_CANDIDATES:
        need |= {t, t + GOP, t + 2 * GOP}
    half = {}
    for i, ch in enumerate(vio.iter_clog3(clip, start=0, count=max(need) + 1, chunk=1)):
        if i in need:
            half[i] = cp.clog3cg_to_dwgdi(ch[0][::2, ::2])
    scored = []
    for t in T_CANDIDATES:
        m = static_mask(half[t], half[t + GOP], half[t + 2 * GOP], model)
        # Best crop (in half-res coordinates) for this t.
        frac = ndimage.uniform_filter(m.astype(np.float32), (H // 2, W // 2))
        cy, cx = np.unravel_index(np.argmax(frac[H // 4: -H // 4, W // 4: -W // 4]), frac[H // 4: -H // 4, W // 4: -W // 4].shape)
        scored.append((float(frac[cy + H // 4, cx + W // 4]), t, cy * 2, cx * 2))
    scored.sort(reverse=True)
    names = []
    for frac, t, y0, x0 in scored[:n_items]:
        frames = {}
        want = set(range(t - HALF, t + HALF + 1)) | {t + GOP, t + 2 * GOP}
        for i, ch in enumerate(vio.iter_clog3(clip, start=0, count=t + 2 * GOP + 1, chunk=1)):
            if i in want:
                frames[i] = cp.clog3cg_to_dwgdi(ch[0][y0:y0 + H, x0:x0 + W])
        mask = static_mask(frames[t], frames[t + GOP], frames[t + 2 * GOP], model)
        window = np.stack([frames[i] for i in range(t - HALF, t + HALF + 1)])
        name = f"{clip.stem}_t{t:03d}"
        np.savez(out_dir / f"{name}.npz", window=window.astype(np.float16), later=frames[t + GOP].astype(np.float16),
                 mask=mask, t=t, crop=np.array([y0, x0]))
        names.append(name)
        print(f"real item {name}: crop y{y0} x{x0}, static {mask.mean():.0%}", flush=True)
    return names
