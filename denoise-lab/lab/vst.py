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
    def from_model(cls, model: NoiseModel, lo=-0.1, hi=1.0, n=4096, axis="noise", ref_level=0.1) -> "NoiseTransform":
        """axis="noise": brightness axis = whitened (1, 1, 1), the original choice.
        axis="grey": brightness axis = the direction a neutral (grey) change takes after the
        curves and whitening, at DI level ref_level. With "noise", about 40 % of neutral
        detail lands in the two colour planes, so anything that treats colour more strongly
        than brightness tints fine neutral detail; "grey" keeps neutral detail in plane 0."""
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
        if axis == "grey":
            slope = 1.0 / np.array([np.interp(ref_level, model.bins, sig[:, c]) for c in range(3)])
            a = whiten @ slope
        else:
            a = whiten @ np.ones(3)
        q0 = a / np.linalg.norm(a)
        b = np.array([1.0, 0.0, -1.0]) - q0 * (q0 @ np.array([1.0, 0.0, -1.0]))
        q1 = b / np.linalg.norm(b)
        q2 = np.cross(q0, q1)
        rot = np.stack([q0, q1, q2])
        m = rot @ whiten
        return cls(grid, curves, m, np.linalg.inv(m))

    # Fast lookups: both directions use uniform tables with linear interpolation, which
    # is what a GPU texture lookup would do. (np.interp's binary search was most of
    # the pipeline's run time.)

    @staticmethod
    def _lerp(x, lo, step, table):
        f = (x - lo) / step
        np.clip(f, 0, len(table) - 1.000001, out=f)
        i = f.astype(np.int32)
        f -= i
        return table[i] * (1 - f) + table[i + 1] * f

    def _inverse_tables(self, n=65536):
        if getattr(self, "_inv", None) is None:
            tabs = []
            for c in range(3):
                lo, hi = self.curves[c][0], self.curves[c][-1]
                u = np.linspace(lo, hi, n)
                tabs.append((lo, (hi - lo) / (n - 1), np.interp(u, self.curves[c], self.grid).astype(np.float32)))
            self._inv = tabs
        return self._inv

    def forward(self, x: np.ndarray) -> np.ndarray:
        x = np.asarray(x, np.float32)
        step = (self.grid[-1] - self.grid[0]) / (len(self.grid) - 1)
        y = np.stack([self._lerp(x[..., c], np.float32(self.grid[0]), np.float32(step),
                                 self.curves[c].astype(np.float32)) for c in range(3)], -1)
        return (y @ self.matrix.T.astype(np.float32)).astype(np.float32)

    def backward(self, z: np.ndarray) -> np.ndarray:
        y = np.asarray(z, np.float32) @ self.inverse.T.astype(np.float32)
        return np.stack([self._lerp(y[..., c], np.float32(lo), np.float32(st), tab)
                         for c, (lo, st, tab) in enumerate(self._inverse_tables())], -1).astype(np.float32)
