"""Fit testset/noise_model.json from locked-off clips (the camera must not move at all). Usage: python fit_noise.py clip.MP4 [clip.MP4 ...]"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from lab import colour_pipeline as cp, noise_model as nm, video_io as vio  # noqa: E402

N_STARTS = 6
WINDOWS = (4, 34, 64, 90)  # first frame of each window; 6 starts x one-GOP pairs per window
gp, gm, cons = [], [], []
for clip in sys.argv[1:]:
    for start in WINDOWS:
        frames = {}
        for chunk in vio.iter_clog3(clip, start=start, count=N_STARTS + 2 * nm.GOP, chunk=2):
            for f in chunk:
                frames[start + len(frames)] = cp.clog3cg_to_dwgdi(f)
        a, b, c = nm.collect(frames, range(start, start + N_STARTS))
        gp += a; gm += b; cons += c
        print(f"{Path(clip).name} from frame {start}: {len(a)} still patches", flush=True)
        del frames
model = nm.fit(gp, gm, cons, source=" + ".join(Path(c).name for c in sys.argv[1:]))
Path("testset").mkdir(exist_ok=True)
model.save("testset/noise_model.json")
np.set_printoptions(precision=4, suppress=True)
print("DI luma, R, G, B noise std per frame:\n", model.std_table())
f = np.fft.fftfreq(nm.P); r = np.hypot(*np.meshgrid(f, f))
print("frame-to-frame correlation by spatial frequency (cycles/px):")
for a, b in [(0, .05), (.05, .1), (.1, .2), (.2, .3), (.3, .5), (.5, .75)]:
    print(f"  {a:.2f}-{b:.2f}: {model.rho[(r >= a) & (r < b)].mean():.2f}")
