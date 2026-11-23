"""Reading camera files and writing results.

Camera files are decoded with ffmpeg to 16-bit RGB using the BT.709 YCbCr matrix,
honouring the file's range flag, so the decoded RGB in [0, 1] is the C-Log3
formula value.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import colour_pipeline as cp


@dataclass
class ProbeInfo:
    width: int
    height: int
    fps: float
    nb_frames: int | None
    pix_fmt: str
    color_range: str  # "tv" (limited) or "pc" (full)
    color_space: str
    color_primaries: str
    color_transfer: str
    codec: str

    def summary(self) -> str:
        return (
            f"{self.codec} {self.width}x{self.height} {self.fps:.3f} fps, {self.pix_fmt}, "
            f"range={self.color_range}, matrix={self.color_space}, "
            f"primaries={self.color_primaries}, transfer={self.color_transfer}"
        )


def probe(path: str | Path) -> ProbeInfo:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    s = json.loads(out)["streams"][0]
    num, den = s.get("avg_frame_rate", "0/1").split("/")
    fps = float(num) / float(den) if float(den) else 0.0
    nb = s.get("nb_frames")
    return ProbeInfo(
        width=int(s["width"]), height=int(s["height"]), fps=fps,
        nb_frames=int(nb) if nb and nb.isdigit() else None,
        pix_fmt=s.get("pix_fmt", "?"),
        color_range=s.get("color_range", "unknown"),
        color_space=s.get("color_space", "unknown"),
        color_primaries=s.get("color_primaries", "unknown"),
        color_transfer=s.get("color_transfer", "unknown"),
        codec=s.get("codec_name", "?"),
    )


def iter_clog3(path: str | Path, start: int = 0, count: int | None = None,
               color_range: str | None = None, chunk: int = 8):
    """Yield chunks of decoded frames as C-Log3/Cinema Gamut RGB, float32 [t, H, W, 3].

    The signal is normalised as the file's range flag says, which is how Resolve
    reads it, so values are the C-Log3 formula value. ``color_range`` overrides the
    flag ("tv" or "pc").
    """
    info = probe(path)
    rng = color_range or (info.color_range if info.color_range in ("tv", "pc") else "tv")
    vf = (
        f"select=gte(n\\,{start}),"
        f"scale=in_color_matrix=bt709:in_range={rng}:out_range=pc"
        ":flags=accurate_rnd+full_chroma_int+bicubic,format=rgb48le"
    )
    cmd = ["ffmpeg", "-v", "error", "-i", str(path), "-vf", vf, "-fps_mode", "passthrough"]
    if count is not None:
        cmd += ["-frames:v", str(count)]
    cmd += ["-f", "rawvideo", "-pix_fmt", "rgb48le", "-"]
    fsize = info.width * info.height * 3 * 2
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    try:
        while True:
            buf = proc.stdout.read(fsize * chunk)
            if not buf:
                break
            n = len(buf) // fsize
            frames = np.frombuffer(buf[: n * fsize], dtype="<u2").reshape(n, info.height, info.width, 3)
            yield frames.astype(np.float32) / 65535.0
    finally:
        proc.stdout.close()
        proc.wait()


def decode_clog3(path: str | Path, start: int = 0, count: int | None = None,
                 color_range: str | None = None) -> np.ndarray:
    """Decode frames to C-Log3/Cinema Gamut RGB (see iter_clog3). Mind the memory at 4K."""
    return np.concatenate(list(iter_clog3(path, start, count, color_range)), axis=0)


def decode_dwgdi(path: str | Path, start: int = 0, count: int | None = None,
                 color_range: str | None = None) -> np.ndarray:
    return cp.clog3cg_to_dwgdi(decode_clog3(path, start, count, color_range))


def write_tiff_sequence(frames_dwgdi: np.ndarray, out_dir: str | Path, prefix: str = "frame") -> None:
    """16-bit RGB TIFFs holding DWG/DI values, for importing into Resolve (skip the input CST)."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    t, h, w, _ = frames_dwgdi.shape
    data = (np.clip(frames_dwgdi, 0, 1) * 65535 + 0.5).astype("<u2").tobytes()
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", f"{w}x{h}",
         "-i", "-", "-pix_fmt", "rgb48le", str(out_dir / f"{prefix}_%05d.tif")],
        input=data, check=True,
    )


def write_preview(frames_display: np.ndarray, path: str | Path, fps: float = 25.0, crf: int = 12) -> None:
    """Near-lossless H.264 preview of display-referred (Rec.709 g2.4) frames."""
    t, h, w, _ = frames_display.shape
    data = (np.clip(frames_display, 0, 1) * 65535 + 0.5).astype("<u2").tobytes()
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", f"{w}x{h}",
         "-r", str(fps), "-i", "-", "-vf",
         "scale=out_color_matrix=bt709:out_range=tv,format=yuv444p10le",
         "-c:v", "libx265", "-crf", str(crf), "-preset", "medium", "-tag:v", "hvc1",
         "-x265-params", "log-level=error",
         "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
         "-color_range", "tv", str(path)],
        input=data, check=True,
    )


def write_png(frame_display: np.ndarray, path: str | Path) -> None:
    h, w, _ = frame_display.shape
    data = (np.clip(frame_display, 0, 1) * 65535 + 0.5).astype("<u2").tobytes()
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", f"{w}x{h}",
         "-i", "-", "-frames:v", "1", str(path)],
        input=data, check=True,
    )
