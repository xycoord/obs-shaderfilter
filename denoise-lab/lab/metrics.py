"""Quality measures, all computed on display-referred frames (approximate Rec.709 g2.4)."""

from __future__ import annotations

import numpy as np
from scipy import ndimage
from skimage.metrics import structural_similarity

from . import colour_pipeline as cp

W709 = np.array([0.2126, 0.7152, 0.0722], np.float32)
BLOCK = 32


def _ycc(d):
    y = d @ W709
    return y, (d[..., 2] - y) / 1.8556, (d[..., 0] - y) / 1.5748


def _psnr(mse):
    return float(10 * np.log10(1.0 / max(float(mse), 1e-12)))


def evaluate(out_di: np.ndarray, clean_di: np.ndarray, skip: int = 4) -> dict:
    """Compare a denoised clip with its clean reference (synthetic-noise set).

    ``skip`` frames at each end are ignored, since a temporal denoiser has fewer
    neighbours there.
    """
    o_all = cp.dwgdi_to_display(out_di.astype(np.float32))
    c_all = cp.dwgdi_to_display(clean_di.astype(np.float32))
    sl = slice(skip, len(o_all) - skip) if len(o_all) > 2 * skip else slice(None)
    o, c = o_all[sl], c_all[sl]
    sq = ((o - c) ** 2).mean(-1)  # per-pixel squared error, averaged over RGB
    yo, cbo, cro = _ycc(o)
    yc, cbc, crc = _ycc(c)
    err = yo - yc

    # Worst regions: 32x32 blocks in every frame; the 95th-percentile block error.
    t, h, w = sq.shape
    hb, wb = h // BLOCK, w // BLOCK
    blocks = sq[:, :hb * BLOCK, :wb * BLOCK].reshape(t, hb, BLOCK, wb, BLOCK).mean((2, 4))

    # Moving areas: where the clean picture changes from the previous frame.
    yc_all = c_all @ W709
    motion = np.abs(ndimage.gaussian_filter(yc_all[1:] - yc_all[:-1], (0, 1.5, 1.5)))
    motion = np.concatenate([motion[:1], motion])[sl] > 0.01
    motion = ndimage.binary_dilation(motion, iterations=4, structure=np.ones((1, 3, 3), bool))

    # Texture: the strongest fine structure in the clean picture, where real detail far
    # outweighs any noise left in the reference.
    hp_c = yc - ndimage.gaussian_filter(yc, (0, 2, 2))
    hp_o = yo - ndimage.gaussian_filter(yo, (0, 2, 2))
    energy = ndimage.gaussian_filter(hp_c ** 2, (0, 4, 4))
    tex = energy > np.quantile(energy, 0.85)

    ssim = float(np.mean([structural_similarity(a, b, data_range=1.0, gaussian_weights=True, sigma=1.5,
                                                use_sample_covariance=False) for a, b in zip(yo, yc)]))
    lp = ndimage.gaussian_filter(err, (0, 2, 2))
    return {
        "psnr": _psnr(sq.mean()),
        "psnr_worst5": _psnr(np.quantile(blocks, 0.95)),
        "psnr_moving": _psnr(sq[motion].mean()) if motion.sum() > 1000 else None,
        "moving_fraction": float(motion.mean()),
        "psnr_texture": _psnr(sq[tex].mean()),
        "detail_texture": float((hp_o[tex] * hp_c[tex]).sum() / max((hp_c[tex] ** 2).sum(), 1e-12)),
        "ssim": ssim,
        "colour_noise": float(np.sqrt(np.mean((cbo - cbc) ** 2 + (cro - crc) ** 2))),
        "flicker": float(np.mean(np.std(lp, axis=0))),
    }


def evaluate_real(out_t_di: np.ndarray, noisy_t_di: np.ndarray, later_di: np.ndarray, mask: np.ndarray) -> dict:
    """Real-footage measure in static areas (see lab/realset.py).

    ``later`` is the raw frame one GOP after ``t``: an independent noisy copy of the
    same picture where nothing moved. Comparing with it gives the true error plus the
    later frame's noise, which is the same for every denoiser and is subtracted using
    the noise estimate from the raw pair itself.
    """
    o = cp.dwgdi_to_display(out_t_di.astype(np.float32))
    y = cp.dwgdi_to_display(noisy_t_di.astype(np.float32))
    z = cp.dwgdi_to_display(later_di.astype(np.float32))
    m = mask.astype(bool)
    e = ((o - z) ** 2).mean(-1)[m].mean()
    noise_var = ((y - z) ** 2).mean(-1)[m].mean() / 2
    true_err = e - noise_var
    return {
        "noise_var": float(noise_var),
        "error_var": float(true_err),
        "gain_db": float(10 * np.log10(noise_var / max(true_err, noise_var * 1e-3))),
    }
