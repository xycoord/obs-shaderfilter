"""Build the test set.

Scored set (testset/scored/<id>.npz, the hill-climb measure)
    Each entry takes a well-lit stretch of real 4K footage as the "clean" picture,
    darkens and tints it in linear light to gig-like levels, and adds synthetic
    noise from the camera's fitted noise model (testset/noise_model.json, made by
    fit_noise.py), at full 4K pixel scale, including the frame-to-frame carry-over. Darkening doesn't change log-encoded noise, so the reference
    keeps its own (smaller) noise; meta.json reports how big it is relative to the
    added noise for each entry.

Review set (testset/review/<clip>.npy)
    Real, untouched 4K frames (a 960x540 centre crop of each camera clip), for
    judging the denoisers by eye on genuine gig noise.

Entries are listed in testset_config.json. Usage: python build_testset.py
"""

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from lab import colour_pipeline as cp, noise_model as nm, video_io as vio  # noqa: E402

cfg = json.loads(Path("testset_config.json").read_text())
out = Path(cfg.get("out", "testset"))
(out / "scored").mkdir(parents=True, exist_ok=True)
(out / "review").mkdir(parents=True, exist_ok=True)
model = nm.NoiseModel.load(out / "noise_model.json")
footage = Path(cfg.get("footage", "footage"))
H, W = cfg.get("crop_size", [540, 960])
n_frames = cfg.get("frames", 33)


def noise_std_at(lum):
    """Model's luma-noise std (mean of R, G, B) at a DI luma value."""
    c = np.array([np.interp(lum, model.bins, model.cov[:, i, j]) for i in range(3) for j in range(3)]).reshape(3, 3)
    return float(np.sqrt(np.ones(3) @ c @ np.ones(3) / 9))


meta = {"frames": n_frames, "scored": [], "review": []}
for k, e in enumerate(cfg["scored"]):
    y0, x0 = e["crop"]
    vy, vx = e.get("pan_px_per_frame", [0, 0])
    span_y, span_x = abs(vy) * (n_frames - 1), abs(vx) * (n_frames - 1)
    gain = np.array(e.get("tint", [1, 1, 1]), np.float64) * 2.0 ** (-e.get("darken_stops", 0))
    clean = []
    for chunk in vio.iter_clog3(footage / e["clip"], start=e.get("start", 40), count=n_frames, chunk=4):
        region = chunk[:, y0:y0 + H + span_y, x0:x0 + W + span_x]
        lin = cp.dwgdi_to_linear(cp.clog3cg_to_dwgdi(region)) * gain
        clean.append(cp.linear_to_dwgdi(lin))
    clean = np.concatenate(clean)
    if span_y or span_x:  # synthetic camera move: slide the window across the (static) picture
        ys = [(t * vy if vy >= 0 else span_y + t * vy) for t in range(n_frames)]
        xs = [(t * vx if vx >= 0 else span_x + t * vx) for t in range(n_frames)]
        clean = np.stack([clean[t, ys[t]:ys[t] + H, xs[t]:xs[t] + W] for t in range(n_frames)])
    rng = np.random.default_rng(cfg.get("seed", 1234) + k)
    noisy = clean + model.synthesise_sequence(clean, rng)
    np.savez(out / "scored" / f"{e['id']}.npz", clean=clean.astype(np.float16), noisy=noisy.astype(np.float16))

    # How noisy is the reference itself? Its own noise is what the source had at its
    # original brightness; the added noise is what the model gives at the new one.
    lum_now = float(np.median(clean.mean(-1)))
    lum_src = float(np.median(cp.linear_to_dwgdi(cp.dwgdi_to_linear(clean) / gain).mean(-1)))
    if lum_src <= model.bins[-1]:
        ratio = round(noise_std_at(lum_src) / noise_std_at(lum_now), 3)
        note = f"reference noise ~{ratio:.2f}x the added noise"
    else:  # the model was fitted on darker footage, so it can't say how noisy the source is
        ratio = None
        note = f"source (DI luma {lum_src:.2f}) is brighter than the noise model covers; reference noise not estimated"
    meta["scored"].append({**e, "median_di_luma": lum_now, "source_di_luma": lum_src, "reference_noise_ratio": ratio})
    print(f"scored {e['id']:24s} median DI luma {lum_now:.3f}  {note}", flush=True)

for clip in sorted(footage.glob("*.MP4")):
    dst = out / "review" / f"{clip.stem}.npy"
    if not dst.exists():
        frames = [cp.clog3cg_to_dwgdi(c[:, 810:1350, 1440:2400])
                  for c in vio.iter_clog3(clip, start=40, count=n_frames, chunk=4)]
        np.save(dst, np.concatenate(frames).astype(np.float16))
    meta["review"].append(clip.stem)
    print("review", clip.stem, flush=True)

meta["clips"] = [e["id"] for e in cfg["scored"]]
(out / "meta.json").write_text(json.dumps(meta, indent=2))
