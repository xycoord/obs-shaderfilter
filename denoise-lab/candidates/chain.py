"""Run two denoisers in sequence: denoise(frames, first="mdegrain", first_params={}, second="vbm3d", second_params={})."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lab import denoisers  # noqa: E402


def denoise(frames, first="mdegrain", first_params=None, second="vbm3d", second_params=None):
    out = denoisers.run(first, frames, **(first_params or {}))
    return denoisers.run(second, out, **(second_params or {}))
