"""Measure noise per frame type in a static region, using frames 12 apart (one per GOP).

Frames n, n+12, n+24, ... share the same position in each GOP. Subtracting their
average leaves each frame's own noise without scene texture, and because frames a
GOP apart don't share references within it, this avoids the frame-to-frame noise
carry-over that consecutive-frame differences suffer from.

Usage: python tests/keyframe_noise.py clip.MP4 y0 y1 x0 x1
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lab import colour_pipeline as cp, video_io as vio  # noqa: E402

clip, y0, y1, x0, x1 = sys.argv[1], *map(int, sys.argv[2:6])
frames = []
for chunk in vio.iter_clog3(clip, chunk=4):
    frames += [cp.clog3cg_to_dwgdi(f[y0:y1, x0:x1]) for f in chunk]
frames = np.array(frames)
types = __import__("subprocess").run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pict_type", "-of", "csv=p=0", clip],
    capture_output=True, text=True).stdout.split()
f = np.fft.fftfreq(64)
r = np.hypot(*np.meshgrid(f, f))
edges = [0, 0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75]


def describe(noise, label):
    lum = noise.mean(-1)
    h, w = lum.shape[1] // 4 * 4, lum.shape[2] // 4 * 4
    keep4 = np.mean([n[:h, :w].reshape(h // 4, 4, w // 4, 4).mean((1, 3)).std() / n.std() for n in lum])
    hs, ws = lum.shape[1] // 64, lum.shape[2] // 64
    p = lum[:, :hs * 64, :ws * 64].reshape(len(lum), hs, 64, ws, 64).transpose(0, 1, 3, 2, 4).reshape(-1, 64, 64)
    p = p - p.mean(axis=(1, 2), keepdims=True)
    psd = (np.abs(np.fft.fft2(p)) ** 2).mean(0)
    psd /= psd.mean()
    radial = [psd[(r >= a) & (r < b)].mean() for a, b in zip(edges[:-1], edges[1:])]
    rgb = [noise[..., c].std() for c in range(3)]
    print(f"{label:34s} luma std {lum.std():.4f}  RGB {rgb[0]:.4f} {rgb[1]:.4f} {rgb[2]:.4f}  "
          f"4x-avg keeps {keep4:.2f}  PSD by freq {np.round(radial, 2)}")


print(f"region mean DI luma {frames.mean():.3f}; PSD bands (cycles/px): {edges}")
for offset in range(0, 4):
    idx = np.arange(offset, len(frames), 12)
    stack = frames[idx]
    k = len(idx)
    noise = (stack - stack.mean(0)) * np.sqrt(k / (k - 1))
    describe(noise, f"frame {offset} of GOP ({types[offset]}), n={k}")
d = (frames[60] - frames[61]) / np.sqrt(2), (frames[61] - frames[62]) / np.sqrt(2), (frames[62] - frames[63]) / np.sqrt(2)
describe(np.array(d), "consecutive-frame differences")
