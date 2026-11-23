"""Quality measures, all computed on display-referred frames (approximate Rec.709 g2.4)."""

from __future__ import annotations

import numpy as np
from scipy import ndimage
from skimage.metrics import structural_similarity

from . import colour_pipeline as cp

W709 = np.array([0.2126, 0.7152, 0.0722], np.float32)


def _ycc(d):
    y = d @ W709
    return y, (d[..., 2] - y) / 1.8556, (d[..., 0] - y) / 1.5748


def evaluate(out_di: np.ndarray, clean_di: np.ndarray, skip: int = 4) -> dict:
    """Compare a denoised clip with its clean reference. ``skip`` frames at each end are ignored,
    since a temporal denoiser has fewer neighbours there."""
    sl = slice(skip, len(out_di) - skip) if len(out_di) > 2 * skip else slice(None)
    o = cp.dwgdi_to_display(out_di[sl].astype(np.float32))
    c = cp.dwgdi_to_display(clean_di[sl].astype(np.float32))
    mse = float(np.mean((o - c) ** 2))
    yo, cbo, cro = _ycc(o)
    yc, cbc, crc = _ycc(c)
    err = yo - yc

    ssim = float(np.mean([structural_similarity(a, b, data_range=1.0, gaussian_weights=True, sigma=1.5,
                                                use_sample_covariance=False) for a, b in zip(yo, yc)]))
    # Detail kept: how much of the reference's fine structure survives (1 = all, <1 = blurred).
    hp_o = yo - ndimage.gaussian_filter(yo, (0, 2, 2))
    hp_c = yc - ndimage.gaussian_filter(yc, (0, 2, 2))
    detail = float((hp_o * hp_c).sum() / max((hp_c ** 2).sum(), 1e-12))
    # Residual brightness noise by tone band of the reference.
    bands = {}
    for name, lo, hi in (("shadows", 0.0, 0.25), ("midtones", 0.25, 0.6), ("highlights", 0.6, 1.01)):
        m = (yc >= lo) & (yc < hi)
        bands[name] = float(err[m].std()) if m.sum() > 1000 else None
    colour_noise = float(np.sqrt(np.mean((cbo - cbc) ** 2 + (cro - crc) ** 2)))
    # Flicker: frame-to-frame variation of the low-frequency error (blotchy shimmer).
    lp = ndimage.gaussian_filter(err, (0, 2, 2))
    flicker = float(np.mean(np.std(lp, axis=0)))
    return {
        "psnr": 10 * np.log10(1.0 / max(mse, 1e-12)),
        "ssim": ssim,
        "detail_kept": detail,
        "luma_noise": bands,
        "colour_noise": colour_noise,
        "flicker": flicker,
    }
