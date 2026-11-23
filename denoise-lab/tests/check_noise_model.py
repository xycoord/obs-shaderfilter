"""Compare synthetic noise with real noise in a static region of a real clip.

Measures, for both: each frame's own noise (from frames one GOP apart), the
consecutive-frame difference (which reflects carry-over), and grain size.

Usage: python tests/check_noise_model.py clip.MP4 y0 y1 x0 x1
"""
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lab import colour_pipeline as cp, noise_model as nm, video_io as vio  # noqa: E402

clip, y0, y1, x0, x1 = sys.argv[1], *map(int, sys.argv[2:6])
m = nm.NoiseModel.load("testset/noise_model.json")
real = np.array([cp.clog3cg_to_dwgdi(f[y0:y1, x0:x1]) for ch in vio.iter_clog3(clip, start=60, count=26, chunk=2)
                 for f in ch])
clean = np.stack([ndimage.gaussian_filter(real.mean(0)[..., c], 2) for c in range(3)], -1)
syn = clean[None] + m.synthesise_sequence(np.repeat(clean[None], 26, 0), np.random.default_rng(0))


def measure(x):
    own = np.array([(x[t] - x[t + 12]) / np.sqrt(2) for t in range(0, 12)])
    con = np.array([(x[t] - x[t + 1]) / np.sqrt(2) for t in range(0, 24)])
    h, w = own.shape[1] // 4 * 4, own.shape[2] // 4 * 4
    keep = np.mean([o.mean(-1)[:h, :w].reshape(h // 4, 4, w // 4, 4).mean((1, 3)).std() / o.mean(-1).std()
                    for o in own])
    rgb = own.reshape(-1, 3).std(0)
    return (f"own noise R {rgb[0]:.4f} G {rgb[1]:.4f} B {rgb[2]:.4f} luma {own.mean(-1).std():.4f} | "
            f"consecutive diff luma {con.mean(-1).std():.4f} | 4x-avg keeps {keep:.2f}")


print(f"region mean DI luma {real.mean():.3f}")
print("real  ", measure(real))
print("model ", measure(syn))
