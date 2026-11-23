"""Side-by-side comparisons on the REAL 4K footage (no synthetic noise), for judging by eye.

For each review clip it writes, under review_out/<run>/:
  <clip>.png        the middle frame, one panel per denoiser (first panel = untouched)
  <clip>_zoom.png   the same, 2x zoom on the centre, where grain is easiest to see
  <clip>.mp4        all panels playing together, to spot flicker and ghosting
  <clip>/<denoiser>/  16-bit TIFFs in DWG/DI, to import into Resolve (skip the input CST)

Usage:
  python review.py none mdegrain 'vbm3d:{"sigma_y": 8}' --run baseline [--clips ...] [--tiff]
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from lab import colour_pipeline as cp, denoisers, video_io as vio  # noqa: E402

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

ap = argparse.ArgumentParser()
ap.add_argument("specs", nargs="+", help='denoiser or denoiser:{"param": value}')
ap.add_argument("--run", default="review")
ap.add_argument("--testset", default="testset")
ap.add_argument("--clips", nargs="*")
ap.add_argument("--tiff", action="store_true", help="also write DWG/DI TIFFs for Resolve")
args = ap.parse_args()

clips = args.clips or sorted(p.stem for p in (Path(args.testset) / "review").glob("*.npy"))
out_dir = Path("review_out") / args.run
out_dir.mkdir(parents=True, exist_ok=True)


def parse(spec):
    name, _, p = spec.partition(":")
    return name, (json.loads(p) if p else {})


def label(path_in, path_out, text):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(path_in), "-vf",
                    f"drawtext=fontfile={FONT}:text='{text}':x=12:y=12:fontsize=28:fontcolor=white:"
                    "box=1:boxcolor=black@0.6:boxborderw=6", str(path_out)], check=True)


for clip in clips:
    frames = np.load(Path(args.testset) / "review" / f"{clip}.npy").astype(np.float32)
    mid = len(frames) // 2
    panels, videos = [], []
    for spec in args.specs:
        name, params = parse(spec)
        out = denoisers.run(name, frames, **params)
        tag = name + ("".join(f" {k}={v}" for k, v in params.items()))
        safe = "".join(ch if ch.isalnum() else "_" for ch in tag)
        disp = cp.dwgdi_to_display(out)
        tmp = out_dir / f".{clip}_{safe}.png"
        vio.write_png(disp[mid], tmp)
        label(tmp, tmp.with_suffix(".l.png"), tag.replace(":", "\\:"))
        panels.append(tmp.with_suffix(".l.png"))
        vid = out_dir / f".{clip}_{safe}.mp4"
        vio.write_preview(disp, vid, fps=23.976)
        videos.append(vid)
        if args.tiff:
            vio.write_tiff_sequence(out, out_dir / clip / safe)
        print(clip, tag, flush=True)
    n = len(panels)
    cols = 2 if n > 1 else 1
    rows = (n + cols - 1) // cols
    layout = "|".join(f"{(i % cols) * 960}_{(i // cols) * 540}" for i in range(n))
    ins = sum((["-i", str(p)] for p in panels), [])
    stack = f"xstack=inputs={n}:layout={layout}:fill=black" if n > 1 else "null"
    subprocess.run(["ffmpeg", "-v", "error", "-y", *ins, "-filter_complex", stack,
                    str(out_dir / f"{clip}.png")], check=True)
    zoom = ";".join(f"[{i}]crop=480:270:240:135,scale=960:540:flags=neighbor[z{i}]" for i in range(n))
    zin = "".join(f"[z{i}]" for i in range(n))
    zst = f"{zin}xstack=inputs={n}:layout={layout}:fill=black" if n > 1 else f"{zin}null"
    # Zoom panels are cropped from unlabelled frames so the label doesn't cover the detail.
    zins = sum((["-i", str(p).replace(".l.png", ".png")] for p in panels), [])
    subprocess.run(["ffmpeg", "-v", "error", "-y", *zins, "-filter_complex", f"{zoom};{zst}",
                    str(out_dir / f"{clip}_zoom.png")], check=True)
    vins = sum((["-i", str(v)] for v in videos), [])
    subprocess.run(["ffmpeg", "-v", "error", "-y", *vins, "-filter_complex",
                    (f"xstack=inputs={n}:layout={layout}:fill=black" if n > 1 else "null"),
                    "-c:v", "libx265", "-crf", "16", "-tag:v", "hvc1", "-x265-params", "log-level=error",
                    str(out_dir / f"{clip}.mp4")], check=True)
print("wrote", out_dir)
