"""The hill-climb measure: run one denoiser over the scored test set and print the result.

The headline number is the mean PSNR (dB) over all clips, on display-referred
frames. Higher is better. The other columns are guards: a change that raises PSNR
by blurring shows up as a fall in detail_kept and SSIM.

Usage:
  python score.py mdegrain
  python score.py mdegrain --params '{"tr": 3, "thsad": 600}' --label tr3
  python score.py --candidate candidates/my_denoiser.py
"""

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from lab import denoisers, metrics  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("denoiser", nargs="?")
ap.add_argument("--params", default="{}")
ap.add_argument("--candidate", help="Python file defining denoise(frames) -> frames")
ap.add_argument("--testset", default="testset")
ap.add_argument("--clips", nargs="*", help="subset of clip names (default: all)")
ap.add_argument("--label")
ap.add_argument("--quiet", action="store_true")
args = ap.parse_args()

params = json.loads(args.params)
if args.candidate:
    spec = importlib.util.spec_from_file_location("candidate", args.candidate)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    fn = lambda f: mod.denoise(f, **params)  # noqa: E731
    name = Path(args.candidate).stem
else:
    fn = lambda f: denoisers.run(args.denoiser, f, **params)  # noqa: E731
    name = args.denoiser
label = args.label or name

meta = json.loads((Path(args.testset) / "meta.json").read_text())
clips = args.clips or meta["clips"]
rows, t_total, px = {}, 0.0, 0
for clip in clips:
    d = np.load(Path(args.testset) / "scored" / f"{clip}.npz")
    noisy = d["noisy"].astype(np.float32)
    t0 = time.time()
    out = fn(noisy)
    t_total += time.time() - t0
    px += noisy.shape[0] * noisy.shape[1] * noisy.shape[2]
    rows[clip] = metrics.evaluate(out, d["clean"])
    if not args.quiet:
        r = rows[clip]
        print(f"  {clip:28s} psnr {r['psnr']:6.2f}  ssim {r['ssim']:.4f}  detail {r['detail_kept']:.3f}  "
              f"colour {r['colour_noise']:.4f}  flicker {r['flicker']:.4f}", flush=True)

summary = {
    "label": label, "denoiser": name, "params": params,
    "psnr": float(np.mean([r["psnr"] for r in rows.values()])),
    "psnr_worst": float(np.min([r["psnr"] for r in rows.values()])),
    "ssim": float(np.mean([r["ssim"] for r in rows.values()])),
    "detail_kept": float(np.mean([r["detail_kept"] for r in rows.values()])),
    "colour_noise": float(np.mean([r["colour_noise"] for r in rows.values()])),
    "flicker": float(np.mean([r["flicker"] for r in rows.values()])),
    "seconds_per_megapixel_frame": t_total / (px / 1e6),
    "clips": rows,
}
Path("results").mkdir(exist_ok=True)
(Path("results") / f"{label}.json").write_text(json.dumps(summary, indent=2))
print(f"{label}: PSNR {summary['psnr']:.3f} dB (worst clip {summary['psnr_worst']:.2f})  "
      f"SSIM {summary['ssim']:.4f}  detail {summary['detail_kept']:.3f}  "
      f"colour {summary['colour_noise']:.4f}  flicker {summary['flicker']:.4f}  "
      f"{summary['seconds_per_megapixel_frame']:.2f} s/MP-frame")
