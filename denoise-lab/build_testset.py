"""Build the tuning and held-back sets from testset_config.json.

Each set has two parts:

synthetic/<id>.npz  clean + noisy frames, DWG/DI, 960x540 at full 4K pixel scale.
    The clean picture is professionally shot 4K footage (Xiph's test sequences),
    converted to scene light, darkened and tinted to gig levels, then given synthetic
    noise from this camera's fitted model (testset/noise_model.json, from fit_noise.py),
    including the frame-to-frame carry-over. This part covers motion.

real/<item>.npz     genuine camera noise from the gig clips, scored in static areas
    against the raw frame one GOP later (see lab/realset.py). This part checks that
    the denoiser works on the real noise, not just on the model of it.

The tuning set is what the hill climb optimises. The held-back set is scored only at
agreed milestones, never to make a decision. Material is split by source sequence and
by camera take, so nothing in one set shares a scene with the other.

Also writes review/<clip>.npy: real 4K crops of every gig clip for judging by eye.

Usage: python build_testset.py [--only tuning|heldout] [--skip-real] [--skip-synthetic]
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).parent))
from lab import colour_pipeline as cp, noise_model as nm, realset, video_io as vio  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--only")
ap.add_argument("--skip-real", action="store_true")
ap.add_argument("--skip-synthetic", action="store_true")
args = ap.parse_args()

cfg = json.loads(Path("testset_config.json").read_text())
root = Path(cfg.get("out", "testset"))
model = nm.NoiseModel.load(root / "noise_model.json")
H, W = cfg.get("crop_size", [540, 960])
N = cfg.get("frames", 33)


def y4m_info(path):
    with open(path, "rb") as f:
        head = f.readline().split()
    w = int([t for t in head if t.startswith(b"W")][0][1:])
    h = int([t for t in head if t.startswith(b"H")][0][1:])
    return w, h


def decode_display(path, step, count, crop=None, scale=1):
    """Decode a BT.709 y4m to display RGB in [0, 1], every ``step``-th frame, optional crop."""
    w, h = y4m_info(path)
    vf = [f"select=not(mod(n\\,{step}))"]
    ow, oh = w, h
    if crop is not None:
        y0, x0 = crop
        vf.append(f"crop={W}:{H}:{x0}:{y0}")
        ow, oh = W, H
    if scale > 1:
        ow, oh = ow // scale, oh // scale
        vf.append(f"scale={ow}:{oh}:flags=area")
    vf.append("scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int+bicubic,"
              "format=rgb48le")
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf", ",".join(vf), "-fps_mode", "passthrough",
                          "-frames:v", str(count), "-f", "rawvideo", "-pix_fmt", "rgb48le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, "<u2").reshape(-1, oh, ow, 3).astype(np.float32) / 65535


def display_to_dwg_linear(rgb):
    """BT.709 display RGB -> scene-ish linear DWG (inverse BT.1886 gamma 2.4, then primaries)."""
    lin = np.maximum(rgb, 0) ** 2.4
    return cp.apply_matrix(lin, cp.conversion_matrix(cp.REC709, cp.DAVINCI_WIDE_GAMUT))


def auto_crop(path, step):
    """Crop with the most fine texture plus motion, judged at quarter resolution."""
    q = decode_display(path, step, 3, scale=4)
    y = q @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    tex = ndimage.gaussian_filter((y[0] - ndimage.gaussian_filter(y[0], 1.5)) ** 2, 3)
    mot = np.abs(ndimage.gaussian_filter(y[2] - y[0], 2))
    score = tex / tex.mean() + mot / (mot.mean() + 1e-9)
    hq, wq = H // 4, W // 4
    win = ndimage.uniform_filter(score, (hq, wq))[hq // 2: -hq // 2, wq // 2: -wq // 2]
    cy, cx = np.unravel_index(np.argmax(win), win.shape)
    return [int(cy * 4), int(cx * 4)]


def synthetic_entry(e, out_dir, seed):
    step = e.get("frame_step", 2)
    crop = e.get("crop", "auto")
    if crop == "auto":
        crop = auto_crop(e["source"], step)
    lin = display_to_dwg_linear(decode_display(e["source"], step, N, crop=crop))
    # Exposure: find the shift that puts the median DI luma (after tint) at the target.
    tint = np.array(e.get("tint", [1, 1, 1]))
    target = e.get("target_di_luma", 0.1)
    sample = lin[::4, ::4, ::4]

    def median_at(s):
        return float(np.median(cp.linear_to_dwgdi(sample * 2.0 ** s * tint).mean(-1)))

    lo, hi = -12.0, 12.0
    for _ in range(40):  # bisection: median brightness rises with exposure
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if median_at(mid) < target else (lo, mid)
    # Never brighten by more than a stop: lifting a dark source would also lift its own
    # noise and compression, and the reference would stop being clean.
    stops = min((lo + hi) / 2, cfg.get("max_brighten_stops", 1.0))
    lin = lin * (2.0 ** stops) * tint
    clean = cp.linear_to_dwgdi(lin)
    noisy = clean + model.synthesise_sequence(clean, np.random.default_rng(seed))
    np.savez(out_dir / f"{e['id']}.npz", clean=clean.astype(np.float16), noisy=noisy.astype(np.float16))
    return {**e, "crop": crop, "stops_applied": round(float(stops), 2),
            "median_di_luma": round(float(np.median(clean.mean(-1))), 3)}


for set_name in ("tuning", "heldout"):
    if args.only and args.only != set_name:
        continue
    sdir = root / set_name
    (sdir / "synthetic").mkdir(parents=True, exist_ok=True)
    (sdir / "real").mkdir(parents=True, exist_ok=True)
    meta = {"set": set_name, "frames": N, "synthetic": [], "real": []}
    base_seed = cfg["seeds"][set_name]
    old_meta = json.loads((sdir / "meta.json").read_text()) if (sdir / "meta.json").exists() else {}
    if args.skip_synthetic:
        meta["synthetic"] = old_meta.get("synthetic", [])
    for k, e in enumerate(x for x in cfg["synthetic"] if x["set"] == set_name):
        if args.skip_synthetic:
            break
        info = synthetic_entry(e, sdir / "synthetic", base_seed + k)
        meta["synthetic"].append(info)
        print(f"[{set_name}] synthetic {e['id']:22s} crop {info['crop']}  {info['stops_applied']:+.2f} stops  "
              f"median DI luma {info['median_di_luma']}", flush=True)
    if not args.skip_real:
        for clip in cfg["real"][set_name]:
            meta["real"] += realset.build(Path(cfg.get("footage", "footage")) / clip, sdir / "real", model,
                                          n_items=cfg.get("real_items_per_clip", 2))
    else:
        meta["real"] = old_meta.get("real", [])
    (sdir / "meta.json").write_text(json.dumps(meta, indent=2))

# Review crops of every gig clip (real noise, for judging by eye).
(root / "review").mkdir(exist_ok=True)
for clip in sorted(Path(cfg.get("footage", "footage")).glob("*.MP4")):
    dst = root / "review" / f"{clip.stem}.npy"
    if not dst.exists():
        frames = [cp.clog3cg_to_dwgdi(c[:, 810:1350, 1440:2400]) for c in vio.iter_clog3(clip, start=40, count=N, chunk=4)]
        np.save(dst, np.concatenate(frames).astype(np.float16))
