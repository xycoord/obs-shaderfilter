"""Fit the camera's noise from real footage, and synthesise matching noise sequences.

Everything is in the DWG/DI domain, which is where the denoisers work.

How the noise is measured
    The camera's HEVC uses a 12-frame GOP (I B B P B B P B B P B B). Within a GOP,
    predicted frames inherit part of the previous frame's noise, so a difference
    between consecutive frames under-measures each frame's noise and gets its grain
    wrong. Instead, each frame's own noise is measured from the difference between
    frames exactly one GOP apart (n and n+12), which are coded independently, in
    areas where nothing moved (judged from a third frame, n+24, so the choice of
    area doesn't depend on the noise being measured).

    The frame-to-frame carry-over is then measured separately: comparing the
    spectrum of consecutive-frame differences with the one-GOP-apart differences
    gives how correlated the noise is between neighbouring frames, at each spatial
    frequency.

The model
    * per-brightness 3x3 RGB covariance (noise is much stronger in the shadows of
      log footage, and the channels' noise is correlated);
    * spatial power spectra for the three principal colour components (grain size);
    * a temporal correlation per spatial frequency (carry-over between frames).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy import ndimage

P = 64      # patch size for spectra
GOP = 12    # frames between independently coded frames


@dataclass
class NoiseModel:
    bins: np.ndarray   # [B] DI luma bin centres
    cov: np.ndarray    # [B, 3, 3] per-frame RGB noise covariance per bin
    psd: np.ndarray    # [3, P, P] normalised spatial power spectra of the principal components
    basis: np.ndarray  # [3, 3] principal colour directions (columns)
    rho: np.ndarray    # [P, P] correlation of the noise between consecutive frames, per frequency
    source: str = ""

    def save(self, path) -> None:
        Path(path).write_text(json.dumps({k: (v.tolist() if isinstance(v, np.ndarray) else v)
                                          for k, v in self.__dict__.items()}))

    @classmethod
    def load(cls, path) -> "NoiseModel":
        d = json.loads(Path(path).read_text())
        return cls(*(np.array(d[k]) for k in ("bins", "cov", "psd", "basis", "rho")), d.get("source", ""))

    def std_table(self) -> np.ndarray:
        """[B, 4]: DI luma, then R, G, B noise std."""
        return np.c_[self.bins, np.sqrt(np.einsum("bii->bi", self.cov))]

    # -- synthesis ----------------------------------------------------------

    def _grid(self, m: np.ndarray, h: int, w: int) -> np.ndarray:
        """Resample a [P, P] frequency-domain map onto an [h, w] FFT grid."""
        fy = np.fft.fftfreq(h)[:, None] * P
        fx = np.fft.fftfreq(w)[None, :] * P
        shifted = np.fft.fftshift(m)
        coords = np.array([np.broadcast_to(fy + P / 2, (h, w)), np.broadcast_to(fx + P / 2, (h, w))])
        return ndimage.map_coordinates(shifted, coords, order=1, mode="nearest")

    def synthesise_sequence(self, clean: np.ndarray, rng: np.random.Generator) -> np.ndarray:
        """Noise for a clip ``clean`` [T, H, W, 3] (DI): grain, colour, brightness dependence
        and frame-to-frame carry-over all matched to the camera."""
        t_len, h, w, _ = clean.shape
        amp = [np.sqrt(np.maximum(self._grid(self.psd[k], h, w), 0)) for k in range(3)]
        amp = [a / np.sqrt(np.mean(a ** 2)) for a in amp]  # unit variance after filtering
        rho = np.clip(self._grid(self.rho, h, w), 0.0, 0.95)
        innov = np.sqrt(1 - rho ** 2)
        chols = np.array([np.linalg.cholesky(self.basis.T @ c @ self.basis + 1e-12 * np.eye(3))
                          for c in self.cov])
        state = [None, None, None]
        out = np.empty(clean.shape, np.float32)
        for t in range(t_len):
            z = []
            for k in range(3):
                e = np.fft.fft2(rng.standard_normal((h, w)))
                state[k] = e if state[k] is None else rho * state[k] + innov * e
                z.append(np.real(np.fft.ifft2(state[k] * amp[k])))
            z = np.stack(z, -1)
            lum = ndimage.gaussian_filter(clean[t].mean(-1), 1.0)
            idx = np.interp(lum, self.bins, np.arange(len(self.bins)))
            lo = np.floor(idx).astype(int)
            hi = np.minimum(lo + 1, len(self.bins) - 1)
            f = (idx - lo)[..., None, None]
            L = chols[lo] * (1 - f) + chols[hi] * f
            comp = np.einsum("hwij,hwj->hwi", L, z)
            out[t] = np.einsum("hwk,ck->hwc", comp, self.basis)
        return out


# --- fitting ---------------------------------------------------------------


def _still_mask(b: np.ndarray, c: np.ndarray, thresh: float = 0.003) -> np.ndarray:
    return np.abs(ndimage.gaussian_filter((c - b).mean(-1), 16)) < thresh


def _patches(d: np.ndarray, still: np.ndarray, *ref):
    """64x64 patches of ``d`` where ``still`` holds throughout and nothing is clipped."""
    h, w = still.shape
    out, means = [], []
    for y in range(0, h - P, P):
        for x in range(0, w - P, P):
            if still[y:y + P, x:x + P].all() and max(r[y:y + P, x:x + P].max() for r in ref) < 0.95:
                out.append(d[y:y + P, x:x + P].astype(np.float32))
                means.append(float(np.mean([r[y:y + P, x:x + P].mean() for r in ref])))
    return out, means


def collect(frames: dict[int, np.ndarray], starts):
    """From decoded frames {index: DI frame}, gather noise patches.

    Returns (gop_patches, gop_means, consecutive_patches): one-GOP-apart differences
    (each frame's own noise) and consecutive-frame differences in the same areas.
    """
    gp, gm, cp_ = [], [], []
    for n in starts:
        a, b, c = frames[n], frames[n + GOP], frames[n + 2 * GOP]
        still = _still_mask(a, b) & _still_mask(b, c)
        p, m = _patches((a - b) / np.sqrt(2), still, a, b)
        gp += p
        gm += m
        if n + 1 in frames:
            q, _ = _patches((a - frames[n + 1]) / np.sqrt(2), still, a, frames[n + 1])
            cp_ += q
    return gp, gm, cp_


def fit(gop_patches, gop_means, consecutive_patches, n_bins: int = 12, source: str = "") -> NoiseModel:
    patches, means = np.array(gop_patches), np.array(gop_means)
    if len(patches) < 50:
        raise RuntimeError(f"only {len(patches)} static patches; need a steadier clip")
    pooled = np.cov(patches.reshape(-1, 3).T)
    evals, evecs = np.linalg.eigh(pooled)
    basis = evecs[:, np.argsort(evals)[::-1]]
    basis *= np.sign(basis.sum(axis=0, keepdims=True) + 1e-12)
    win = np.hanning(P)[:, None] * np.hanning(P)[None, :]

    def spectra(ps):
        comp = np.einsum("nhwc,ck->nhwk", ps, basis)
        comp = comp - comp.mean(axis=(1, 2), keepdims=True)
        return (np.abs(np.fft.fft2(comp * win[None, :, :, None], axes=(1, 2))) ** 2).mean(0).transpose(2, 0, 1)

    psd_abs = spectra(patches)
    psd = psd_abs / psd_abs.mean(axis=(1, 2), keepdims=True)

    # Carry-over: var(consecutive diff) = var(own noise) * (1 - rho), per frequency.
    if len(consecutive_patches) >= 20:
        cons = spectra(np.array(consecutive_patches))
        # Compare like with like: scale by the mean own-noise power of the same areas.
        ratio = cons[0] / np.maximum(psd_abs[0], 1e-20)
        rho = ndimage.gaussian_filter(np.clip(1 - ratio, 0, 0.95), 1.0, mode="wrap")
    else:
        rho = np.zeros((P, P))

    edges = np.quantile(means, np.linspace(0, 1, n_bins + 1))
    bins, covs = [], []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (means >= lo) & (means <= hi)
        if m.sum() < 5:
            continue
        v = patches[m].reshape(m.sum(), -1, 3).var(axis=1).sum(-1)
        keep = v <= 3 * np.median(v)  # drop clear outliers: motion that slipped through
        bins.append(np.median(means[m]))
        covs.append(np.cov(patches[m][keep].reshape(-1, 3).T))
    covs = np.array(covs)
    tot = np.einsum("bii->b", covs)
    covs *= (np.minimum.accumulate(tot) / tot)[:, None, None]  # noise falls with brightness in log
    return NoiseModel(np.array(bins), covs, psd, basis, rho, source)
