"""Cross-check the hand-written colour maths against colour-science and published values.

Run: python -m pytest tests/ -q   (or: python tests/test_colour.py)
"""

import sys
import warnings
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
warnings.filterwarnings("ignore")

import colour  # noqa: E402

from lab import colour_pipeline as cp  # noqa: E402

X = np.concatenate([np.linspace(-0.05, 0.05, 201), np.geomspace(0.05, 40, 400)])


def test_clog3_matches_colour_science():
    ours = cp.clog3_encode(X)
    ref = colour.models.log_encoding_CanonLog3(X, method="v1.2")
    assert np.max(np.abs(ours - ref)) < 1e-6
    assert np.max(np.abs(cp.clog3_decode(ours) - X)) < 1e-6


def test_clog3_published_points():
    # Canon: 18 % grey -> 34.3 % (legal-normalised signal); 0 % reflectance -> 12.5 %.
    assert abs(cp.clog3_encode(0.18) - 0.343389) < 1e-5
    assert abs(cp.clog3_encode(0.0) - 0.12512219) < 1e-7


def test_davinci_intermediate_matches_colour_science():
    pos = X[X >= 0]
    ours = cp.di_encode(pos)
    ref = colour.models.oetf_DaVinciIntermediate(pos)
    assert np.max(np.abs(ours - ref)) < 1e-6
    assert np.max(np.abs(cp.di_decode(ours) - pos)) < 1e-6
    # Blackmagic: 18 % grey -> 0.336 in DaVinci Intermediate.
    assert abs(cp.di_encode(0.18) - 0.336043) < 1e-5


def test_gamut_matrix_matches_colour_science():
    ref = colour.matrix_RGB_to_RGB(
        colour.RGB_COLOURSPACES["Cinema Gamut"], colour.RGB_COLOURSPACES["DaVinci Wide Gamut"]
    )
    assert np.max(np.abs(cp.M_CG_TO_DWG - ref)) < 1e-6
    # White stays white.
    assert np.allclose(cp.M_CG_TO_DWG @ np.ones(3), np.ones(3), atol=1e-9)


def test_round_trip_and_display_mid_grey():
    rgb = np.random.default_rng(0).uniform(0.1, 0.8, (50, 3))
    di = cp.clog3cg_to_dwgdi(rgb)
    assert np.max(np.abs(cp.dwgdi_to_clog3cg(di) - rgb)) < 1e-4
    grey = cp.linear_to_dwgdi(np.full((1, 3), 0.18))
    disp = cp.dwgdi_to_display(grey)
    assert abs(float(disp[0, 0]) - 0.18 ** (1 / 2.4)) < 1e-3


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
