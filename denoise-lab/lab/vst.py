"""Noise-equalising transform: makes the camera's noise the same strength everywhere.

Two steps, both from the fitted noise model:
1. Per-channel curve f_c(v) = integral of dv / sigma_c(v), so noise std is ~1 at every
   brightness (log footage is far noisier in the shadows).
2. A fixed 3x3 matrix that decorrelates the channels' noise and gives it unit
   variance, with the first output aligned to brightness (the most detail) and the
   other two carrying colour.
Then every threshold (MDegrain thSAD, BM3D sigma) means the same thing everywhere.

Approximation: the model gives noise against overall brightness, and the curve uses
each channel's own value in its place. Exact for neutral colours, approximate under
saturated stage light.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .noise_model import NoiseModel


@dataclass
class NoiseTransform:
    grid: np.ndarray      # DI values the curves are tabulated at
    curves: np.ndarray    # [3, G] f_c on the grid
    matrix: np.ndarray    # [3, 3] decorrelating matrix (applied after the curves)
    inverse: np.ndarray

    @classmethod
    def from_model(cls, model: NoiseModel, lo=-0.1, hi=1.0, n=4096) -> "NoiseTransform":
        grid = np.linspace(lo, hi, n)
        sig = np.sqrt(np.einsum("bii->bi", model.cov))           # [B, 3]
        curves = []
        for c in range(3):
            s = np.interp(grid, model.bins, sig[:, c])            # flat beyond the fitted range
            curves.append(np.concatenate([[0], np.cumsum((1 / s[1:] + 1 / s[:-1]) / 2 * np.diff(grid))]))
        curves = np.array(curves)
        # Noise correlation after the curves (unit variance per channel by construction).
        d = np.sqrt(np.einsum("bii->bi", model.cov))
        corr = np.mean([c / np.outer(dd, dd) for c, dd in zip(model.cov, d)], axis=0)
        evals, evecs = np.linalg.eigh(corr)
        whiten = evecs @ np.diag(evals ** -0.5) @ evecs.T         # symmetric R^-1/2
        # Rotate so the first axis is brightness: Gram-Schmidt starting from W @ (1,1,1).
        a = whiten @ np.ones(3)
        q0 = a / np.linalg.norm(a)
        b = np.array([1.0, 0.0, -1.0]) - q0 * (q0 @ np.array([1.0, 0.0, -1.0]))
        q1 = b / np.linalg.norm(b)
        q2 = np.cross(q0, q1)
        rot = np.stack([q0, q1, q2])
        m = rot @ whiten
        return cls(grid, curves, m, np.linalg.inv(m))

    def forward(self, x: np.ndarray) -> np.ndarray:
        y = np.stack([np.interp(x[..., c], self.grid, self.curves[c]) for c in range(3)], -1)
        return np.einsum("...c,dc->...d", y, self.matrix).astype(np.float32)

    def backward(self, z: np.ndarray) -> np.ndarray:
        y = np.einsum("...c,dc->...d", z, self.inverse)
        return np.stack([np.interp(y[..., c], self.curves[c], self.grid) for c in range(3)], -1).astype(np.float32)
