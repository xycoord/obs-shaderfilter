"""Speed benchmark: one denoiser on a real 13-frame window of 4K gig footage (a 1920x1080
crop at full 4K pixel scale; a whole 4K window does not fit in this machine's memory
with the current pipeline, which holds every frame several times over).

Runs the denoiser `--repeats` times and reports the median seconds per megapixel-frame,
which is steadier than the timings score.py records along the way. The input is cached
in bench_input.npy (not committed).

Usage: python bench.py best [--params '{...}'] [--repeats 3]
"""
import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from lab import colour_pipeline as cp, denoisers, video_io as vio  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("denoiser")
ap.add_argument("--params", default="{}")
ap.add_argument("--repeats", type=int, default=3)
args = ap.parse_args()

cache = Path("bench_input.npy")
if not cache.exists():
    frames = [cp.clog3cg_to_dwgdi(f[540:1620, 960:2880]) for ch in vio.iter_clog3("footage/06_C029_wide-fiddle.MP4", start=48, count=13,
                                                                chunk=1) for f in ch]
    np.save(cache, np.array(frames, np.float32))
x = np.load(cache)
mp = x.shape[0] * x.shape[1] * x.shape[2] / 1e6
times = []
for _ in range(args.repeats):
    t0 = time.perf_counter()
    denoisers.run(args.denoiser, x, **json.loads(args.params))
    times.append((time.perf_counter() - t0) / mp)
print(f"{args.denoiser} {args.params}: median {statistics.median(times):.3f} s/MP-frame "
      f"(runs: {', '.join(f'{t:.3f}' for t in times)})")
