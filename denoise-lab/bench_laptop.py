"""Speed benchmark for a local machine (no footage or VapourSynth needed).

Times the Rust CPU denoiser (rust_blend) and the GPU denoiser (gpu_blend) on 13 frames,
at 1920x1080 and, if it fits in memory, full 4K. Uses a real clip from footage/ if one is
there, otherwise synthetic frames (a textured picture moving slowly, plus this camera's
modelled noise); speed barely depends on content.

Usage (from denoise-lab/, after building both crates, see LAPTOP.md):
    python bench_laptop.py
"""
import platform
import statistics
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from lab import denoisers  # noqa: E402
from lab.noise_model import NoiseModel  # noqa: E402


def synthetic(t, h, w, seed=0):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    frames = []
    for k in range(t):
        x = xx + 2.0 * k  # slow pan
        base = 0.1 + 0.05 * np.sin(x / 37.0) * np.cos(yy / 23.0) + 0.03 * np.sin((x + yy) / 5.0)
        frames.append(np.stack([base * 1.1, base, base * 0.8], -1))
    clean = np.array(frames, np.float32)
    model = NoiseModel.load(Path(__file__).parent / "testset" / "noise_model.json")
    return clean + model.synthesise_sequence(clean, rng)


def load(t, h, w):
    clips = sorted((Path(__file__).parent / "footage").glob("*.MP4"))
    if clips:
        from lab import colour_pipeline as cp, video_io as vio
        y0, x0 = (2160 - h) // 2, (3840 - w) // 2
        return np.array([cp.clog3cg_to_dwgdi(f[y0:y0 + h, x0:x0 + w])
                         for ch in vio.iter_clog3(clips[0], start=48, count=t, chunk=1) for f in ch], np.float32), "real"
    return synthetic(t, h, w), "synthetic"


def bench(name, x, repeats):
    mp = x.shape[0] * x.shape[1] * x.shape[2] / 1e6
    denoisers.run(name, x[:3])  # warm-up (GPU shader compilation, thread pools)
    times = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        denoisers.run(name, x)
        times.append((time.perf_counter() - t0) / mp)
    return statistics.median(times)


print(f"machine: {platform.processor() or platform.machine()}, {platform.system()} {platform.release()}")
try:
    import gigdenoise_gpu
    print("GPU adapter:", gigdenoise_gpu.adapter())
except Exception as e:  # noqa: BLE001
    print("GPU not available:", e)
for (h, w) in [(1080, 1920), (2160, 3840)]:
    try:
        x, kind = load(13, h, w)
    except MemoryError:
        print(f"{w}x{h}: not enough memory for the input")
        continue
    for name in ("rust_blend", "gpu_blend"):
        try:
            s = bench(name, x, 3)
            fps = 1.0 / (s * w * h / 1e6)
            print(f"{w}x{h} ({kind}) {name:11s}: {s:.4f} s per megapixel-frame = {fps:.2f} frames/s at this size")
        except Exception as e:  # noqa: BLE001
            print(f"{w}x{h} {name}: failed: {e}")
