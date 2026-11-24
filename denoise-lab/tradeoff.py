"""Noise left versus detail kept, for comparing denoisers at equal noise reduction.

On the tuning set's synthetic clips, splits each clean picture into flat areas (weakest
30 % of fine structure) and textured areas (strongest 15 %), then reports:
  flat_luma, flat_colour  residual noise in flat areas (display units; lower = cleaner)
  colour_err_on_texture   colour error where there is fine texture (tints on detail; lower = better)
  texture_kept            how much of the clean texture survives (1 = all), mean and worst clip
Usage: python tradeoff.py <denoiser>[:<json params>] ...
"""
import json
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).parent))
from lab import colour_pipeline as cp, denoisers  # noqa: E402

W = np.array([0.2126, 0.7152, 0.0722], np.float32)
meta = json.loads(Path("testset/tuning/meta.json").read_text())
clips = []
for e in meta["synthetic"]:
    d = np.load(f"testset/tuning/synthetic/{e['id']}.npz")
    clean = d["clean"].astype(np.float32)
    c = cp.dwgdi_to_display(clean[4:-4])
    yc = c @ W
    hp = yc - ndimage.gaussian_filter(yc, (0, 2, 2))
    energy = ndimage.gaussian_filter(hp ** 2, (0, 4, 4))
    clips.append((e["id"], d["noisy"].astype(np.float32), c, yc, hp, energy < np.quantile(energy, 0.3),
                  energy > np.quantile(energy, 0.85)))

for spec in sys.argv[1:]:
    name, _, p = spec.partition(":")
    params = json.loads(p) if p else {}
    fl, fc, tex, tint = [], [], {}, []
    for cid, noisy, c, yc, hpc, flat, textured in clips:
        o = cp.dwgdi_to_display(denoisers.run(name, noisy, **params)[4:-4])
        yo = o @ W
        err = o - c
        ey = err @ W
        fl.append(np.std(ey[flat]))
        cb, cr = err[..., 2] - ey, err[..., 0] - ey
        fc.append(np.sqrt(np.mean(cb[flat] ** 2 + cr[flat] ** 2)))
        tint.append(np.sqrt(np.mean(cb[textured] ** 2 + cr[textured] ** 2)))
        hpo = yo - ndimage.gaussian_filter(yo, (0, 2, 2))
        tex[cid] = float((hpo[textured] * hpc[textured]).sum() / (hpc[textured] ** 2).sum())
    print(f"{spec}\n   flat_luma {np.mean(fl):.4f}  flat_colour {np.mean(fc):.4f}  colour_err_on_texture {np.mean(tint):.4f}  texture mean {np.mean(list(tex.values())):.3f}"
          f"  worst {min(tex.values()):.3f} ({min(tex, key=tex.get)})", flush=True)
