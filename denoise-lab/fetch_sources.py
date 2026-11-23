"""Download a stretch of frames from Xiph's 4K test sequences (raw y4m, via HTTP ranges).

Writes sources/<name>.y4m containing only the requested frames.
Usage: python fetch_sources.py   (sequence list below)
"""
import subprocess
import sys
from pathlib import Path

BASE = "https://media.xiph.org/video/derf/"
SEQS = {  # name: (path, first frame, frame count)
    "DinnerScene": ("Chimera/Netflix_DinnerScene_4096x2160_60fps_10bit_420.y4m", 300, 66),
    "BarScene": ("Chimera/Netflix_BarScene_4096x2160_60fps_10bit_420.y4m", 200, 66),
    "Dancers": ("Chimera/Netflix_Dancers_4096x2160_60fps_10bit_420.y4m", 200, 66),
    "ToddlerFountain": ("Chimera/Netflix_ToddlerFountain_4096x2160_60fps_10bit_420.y4m", 200, 66),
    "FoodMarket": ("ElFuente/Netflix_FoodMarket_4096x2160_60fps_10bit_420.y4m", 200, 66),
    "Tango": ("ElFuente/Netflix_Tango_4096x2160_60fps_10bit_420.y4m", 100, 66),
    "Boat": ("ElFuente/Netflix_Boat_4096x2160_60fps_10bit_420.y4m", 100, 66),
    "RollerCoaster": ("Chimera/Netflix_RollerCoaster_4096x2160_60fps_10bit_420.y4m", 300, 66),
}
out = Path("sources")
out.mkdir(exist_ok=True)
for name, (path, first, count) in SEQS.items():
    dst = out / f"{name}.y4m"
    if dst.exists():
        continue
    url = BASE + path
    head = subprocess.run(["curl", "-sf", "-r", "0-511", url], capture_output=True, check=True).stdout
    header = head.split(b"\n", 1)[0] + b"\n"
    w = int([t for t in header.split() if t.startswith(b"W")][0][1:])
    h = int([t for t in header.split() if t.startswith(b"H")][0][1:])
    frame = 6 + w * h * 3 // 2 * 2  # "FRAME\n" + 10-bit 4:2:0 samples
    start = len(header) + first * frame
    end = start + count * frame - 1
    tmp = dst.with_suffix(".part")
    with open(tmp, "wb") as f:
        f.write(header)
    with open(tmp, "ab") as f:
        subprocess.run(["curl", "-sf", "--retry", "5", "-r", f"{start}-{end}", url], stdout=f, check=True)
    if tmp.stat().st_size != len(header) + count * frame:
        sys.exit(f"{name}: short download")
    tmp.rename(dst)
    print("fetched", name, flush=True)
