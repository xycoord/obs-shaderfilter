"""The hill-climb measure: run one denoiser over a set and report the score and guards.

Score (higher is better, in dB) = the average of two gains:
  synthetic gain  PSNR improvement over the untouched noisy input, on the synthetic
                  clips (clean 4K footage + this camera's modelled noise; covers motion);
  real gain       error reduction on genuine camera noise in static areas of the gig
                  clips (see lab/realset.py); 0 dB = untouched.
Guards (a candidate mustn't make these worse; see compare.py):
  psnr_worst5     the 5 % worst 32x32 regions: catches local ghosting and smears;
  psnr_moving     error where the picture moves;
  detail_texture  how much of the strongest fine texture survives (1 = all);
  ssim, flicker, colour_noise, speed.

Usage:
  python score.py mdegrain --params '{"tr": 3}' --label md-tr3
  python score.py --candidate candidates/x.py --label x
  python score.py mdegrain --set heldout --milestone "baseline"   (logged; never for decisions)
"""

import argparse
import datetime
import importlib.util
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from lab import denoisers, metrics, realset  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("denoiser", nargs="?")
ap.add_argument("--params", default="{}")
ap.add_argument("--candidate", help="Python file defining denoise(frames, **params) -> frames")
ap.add_argument("--set", default="tuning", choices=["tuning", "heldout"])
ap.add_argument("--milestone", help="required for --set heldout: why it is being scored now")
ap.add_argument("--testset", default="testset")
ap.add_argument("--label")
ap.add_argument("--quiet", action="store_true")
args = ap.parse_args()

if args.set == "heldout" and not args.milestone:
    sys.exit("The held-back set is scored only at agreed milestones: pass --milestone '<reason>'.")

params = json.loads(args.params)
if args.candidate:
    spec = importlib.util.spec_from_file_location("candidate", args.candidate)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    fn = lambda f: mod.denoise(np.asarray(f, np.float32), **params).astype(np.float32)  # noqa: E731
    name = Path(args.candidate).stem
else:
    fn = lambda f: denoisers.run(args.denoiser, f, **params)  # noqa: E731
    name = args.denoiser
label = args.label or name

sdir = Path(args.testset) / args.set
meta = json.loads((sdir / "meta.json").read_text())
t_total, px = 0.0, 0
synth, real = {}, {}


def timed(frames):
    global t_total, px
    t0 = time.time()
    out = fn(frames)
    t_total += time.time() - t0
    px += frames.shape[0] * frames.shape[1] * frames.shape[2]
    return out


for e in meta["synthetic"]:
    d = np.load(sdir / "synthetic" / f"{e['id']}.npz")
    noisy, clean = d["noisy"].astype(np.float32), d["clean"].astype(np.float32)
    r = metrics.evaluate(timed(noisy), clean)
    r["psnr_input"] = metrics.evaluate(noisy, clean)["psnr"]
    r["gain_db"] = r["psnr"] - r["psnr_input"]
    synth[e["id"]] = r
    if not args.quiet:
        mv = f"{r['psnr_moving']:.2f}" if r["psnr_moving"] is not None else "  -  "
        print(f"  {e['id']:22s} gain {r['gain_db']:+6.2f}  worst5% {r['psnr_worst5']:6.2f}  moving {mv}  "
              f"detail {r['detail_texture']:.3f}  ssim {r['ssim']:.4f}  flicker {r['flicker']:.4f}", flush=True)

for item in meta["real"]:
    d = np.load(sdir / "real" / f"{item}.npz")
    window = d["window"].astype(np.float32)
    out = timed(window)
    r = metrics.evaluate_real(out[realset.HALF], window[realset.HALF], d["later"], d["mask"])
    real[item] = r
    if not args.quiet:
        print(f"  {item:34s} real gain {r['gain_db']:+6.2f} dB", flush=True)


def mean(rows, key):
    vals = [r[key] for r in rows.values() if r.get(key) is not None]
    return float(np.mean(vals)) if vals else None


synth_gain = mean(synth, "gain_db")
real_gain = mean(real, "gain_db")
summary = {
    "label": label, "set": args.set, "denoiser": name, "params": params,
    "score": float(np.mean([g for g in (synth_gain, real_gain) if g is not None])),
    "synthetic_gain_db": synth_gain,
    "real_gain_db": real_gain,
    "psnr": mean(synth, "psnr"),
    "psnr_worst5": mean(synth, "psnr_worst5"),
    "psnr_moving": mean(synth, "psnr_moving"),
    "psnr_texture": mean(synth, "psnr_texture"),
    "detail_texture": mean(synth, "detail_texture"),
    "ssim": mean(synth, "ssim"),
    "flicker": mean(synth, "flicker"),
    "colour_noise": mean(synth, "colour_noise"),
    "seconds_per_megapixel_frame": t_total / (px / 1e6),
    "synthetic": synth, "real": real,
}
rdir = Path("results") / args.set
rdir.mkdir(parents=True, exist_ok=True)
(rdir / f"{label}.json").write_text(json.dumps(summary, indent=2))
if args.set == "heldout":
    with open(Path("records") / "heldout_log.jsonl", "a") as f:
        f.write(json.dumps({"when": datetime.datetime.now().isoformat(timespec="seconds"), "label": label,
                            "milestone": args.milestone, "score": summary["score"]}) + "\n")
s = summary
print(f"{label} [{args.set}]: score {s['score']:+.3f} dB (synthetic {s['synthetic_gain_db']:+.2f}, "
      f"real {s['real_gain_db']:+.2f})  worst5% {s['psnr_worst5']:.2f}  moving {s['psnr_moving']:.2f}  "
      f"detail {s['detail_texture']:.3f}  ssim {s['ssim']:.4f}  flicker {s['flicker']:.4f}  "
      f"{s['seconds_per_megapixel_frame']:.2f} s/MP-frame")
