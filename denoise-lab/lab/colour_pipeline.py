"""Colour conversions for Canon C-Log3 / Cinema Gamut footage.

Working space for denoising and storage is DaVinci Wide Gamut / DaVinci
Intermediate ("DWG/DI"), matching the user's Resolve pipeline:

    camera file (YCbCr) -> C-Log3 / Cinema Gamut RGB
        -> scene-linear Cinema Gamut -> scene-linear DWG -> DI encoded   (exact, published maths)
    DWG/DI -> Rec.709 primaries, gamma 2.4 display                     (APPROXIMATE: Resolve's
                                                                         tone/gamut mapping is
                                                                         unpublished)

The published curves and primaries are written out here independently and
cross-checked against the colour-science library in tests/test_colour.py.
"""

from __future__ import annotations

import numpy as np

# --- Canon Log 3 (Canon white paper, v1.2 formulae) ---------------------------
# The formula's output is a *legal-range* normalised signal: 0 = code 64, 1 = code 940
# (10-bit). Its input is scene-linear "relative to 90 % reflectance"; Canon's
# convention divides reflectance by 0.9, so 18 % grey -> 0.2 in formula terms.


def clog3_decode(v: np.ndarray) -> np.ndarray:
    """C-Log3 legal-range normalised signal -> scene-linear reflectance (0.18 = mid grey)."""
    v = np.asarray(v, dtype=np.float64)
    x = np.where(
        v < 0.097465473,
        -(10.0 ** ((0.12783901 - v) / 0.36726845) - 1.0) / 14.98325,
        np.where(
            v <= 0.15277891,
            (v - 0.12512219) / 1.9754798,
            (10.0 ** ((v - 0.12240537) / 0.36726845) - 1.0) / 14.98325,
        ),
    )
    return x * 0.9


def clog3_encode(x: np.ndarray) -> np.ndarray:
    """Scene-linear reflectance -> C-Log3 legal-range normalised signal."""
    x = np.asarray(x, dtype=np.float64) / 0.9
    lo = -0.36726845 * np.log10(np.maximum(-x * 14.98325 + 1.0, 1e-12)) + 0.12783901
    mid = 1.9754798 * x + 0.12512219
    hi = 0.36726845 * np.log10(np.maximum(x * 14.98325 + 1.0, 1e-12)) + 0.12240537
    return np.where(x < -0.014, lo, np.where(x <= 0.014, mid, hi))


# --- DaVinci Intermediate (Blackmagic DWG/Intermediate white paper) -----------
DI_A = 0.0075
DI_B = 7.0
DI_C = 0.07329248
DI_M = 10.44426855
DI_LIN_CUT = 0.00262409
DI_LOG_CUT = 0.02740668


def di_encode(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    return np.where(x <= DI_LIN_CUT, x * DI_M, DI_C * (np.log2(np.maximum(x + DI_A, 1e-12)) + DI_B))


def di_decode(v: np.ndarray) -> np.ndarray:
    v = np.asarray(v, dtype=np.float64)
    return np.where(v <= DI_LOG_CUT, v / DI_M, 2.0 ** (v / DI_C - DI_B) - DI_A)


# --- Primaries -----------------------------------------------------------------
D65 = (0.3127, 0.3290)
CINEMA_GAMUT = ((0.74, 0.27), (0.17, 1.14), (0.08, -0.10))
DAVINCI_WIDE_GAMUT = ((0.8000, 0.3130), (0.1682, 0.9877), (0.0790, -0.1155))
REC709 = ((0.64, 0.33), (0.30, 0.60), (0.15, 0.06))


def rgb_to_xyz_matrix(primaries, white=D65) -> np.ndarray:
    def xyz(xy):
        x, y = xy
        return np.array([x / y, 1.0, (1 - x - y) / y])

    p = np.stack([xyz(c) for c in primaries], axis=1)
    s = np.linalg.solve(p, xyz(white))
    return p * s


def conversion_matrix(src, dst) -> np.ndarray:
    return np.linalg.inv(rgb_to_xyz_matrix(dst)) @ rgb_to_xyz_matrix(src)


M_CG_TO_DWG = conversion_matrix(CINEMA_GAMUT, DAVINCI_WIDE_GAMUT)
M_DWG_TO_709 = conversion_matrix(DAVINCI_WIDE_GAMUT, REC709)
M_DWG_TO_CG = np.linalg.inv(M_CG_TO_DWG)


def apply_matrix(rgb: np.ndarray, m: np.ndarray) -> np.ndarray:
    return np.einsum("...c,dc->...d", rgb, m)


# --- Full pipelines ----------------------------------------------------------


def clog3cg_to_dwgdi(signal: np.ndarray) -> np.ndarray:
    """C-Log3/Cinema Gamut legal-normalised RGB -> DWG/DI (float32)."""
    lin = apply_matrix(clog3_decode(signal), M_CG_TO_DWG)
    return di_encode(lin).astype(np.float32)


def dwgdi_to_linear(di: np.ndarray) -> np.ndarray:
    return di_decode(di)


def linear_to_dwgdi(lin: np.ndarray) -> np.ndarray:
    return di_encode(lin).astype(np.float32)


def dwgdi_to_clog3cg(di: np.ndarray) -> np.ndarray:
    return clog3_encode(apply_matrix(di_decode(di), M_DWG_TO_CG)).astype(np.float32)


def dwgdi_to_display(di: np.ndarray, exposure: float = 1.0) -> np.ndarray:
    """APPROXIMATE output transform: DWG/DI -> Rec.709 primaries, gamma 2.4, [0, 1].

    Stands in for Resolve's CST with tone mapping. Used for scoring and previews
    only; every denoiser gets the same transform, so comparisons stay fair.
    Tone curve: a smooth highlight roll-off placing 18 % grey at ~0.18 display-linear
    (about 49 % signal), with gentle gamut compression by clipping negative values
    after desaturating out-of-gamut colours towards their luminance.
    """
    lin = apply_matrix(di_decode(di) * exposure, M_DWG_TO_709)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722])
    lum = np.maximum(lum, 0.0)[..., None]
    # Desaturate towards luminance just enough to remove negative components.
    neg = np.minimum(lin.min(axis=-1, keepdims=True), 0.0)
    t = np.where(lum - neg > 1e-9, -neg / np.maximum(lum - neg, 1e-9), 1.0)
    lin = lin + t * (lum - lin)
    # Highlight roll-off (Reinhard-style on a scaled signal), white point ~16x mid grey.
    w = 16.0 * 0.18
    mapped = lin * (1.0 + lin / (w * w)) / (1.0 + lin)
    mapped = mapped / (0.18 * (1 + 0.18 / (w * w)) / 1.18) * 0.18  # keep mid grey at 0.18
    mapped = np.clip(mapped, 0.0, 1.0)
    return (mapped ** (1.0 / 2.4)).astype(np.float32)


def luma709(display: np.ndarray) -> np.ndarray:
    return display @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
