"""Denoisers under test. Each takes and returns DWG/DI frames, float32 [T, H, W, 3].

Add one by writing a function ``name(frames, **params)`` and registering it in
DENOISERS with its default parameters.
"""

from __future__ import annotations

import subprocess

import numpy as np

OFFSET, SCALE = 0.1, 1.2
PREFETCH = 4  # frames VapourSynth renders in parallel (one per core); MVTools itself is single-threaded  # map DI (which dips slightly below 0 in noise) into [0, 1] for 16-bit tools


# --- VapourSynth bridge -------------------------------------------------------

def _vs():
    import vapoursynth as vs
    return vs, vs.core


def to_clip(frames: np.ndarray):
    """[T, H, W, 3] float32 -> VapourSynth RGBS clip."""
    vs, core = _vs()
    t, h, w, _ = frames.shape
    blank = core.std.BlankClip(format=vs.RGBS, width=w, height=h, length=t, fpsnum=24000, fpsden=1001)
    arr = np.ascontiguousarray(frames, dtype=np.float32)

    def fill(n, f):
        fout = f.copy()
        for p in range(3):
            np.asarray(fout[p])[:] = arr[n, :, :, p]
        return fout

    return core.std.ModifyFrame(blank, blank, fill)


def from_clip(clip) -> np.ndarray:
    vs, core = _vs()
    if clip.format.id != vs.RGBS:
        clip = core.resize.Point(clip, format=vs.RGBS, matrix_in_s="709")
    out = np.empty((clip.num_frames, clip.height, clip.width, 3), np.float32)
    for n, f in enumerate(clip.frames(prefetch=PREFETCH)):
        for p in range(3):
            out[n, :, :, p] = np.asarray(f[p])
    return out


def _to_yuv16(frames):
    """DI RGB -> YUV444P16 (BT.709 matrix used purely to separate brightness from colour)."""
    vs, core = _vs()
    c = to_clip((frames + OFFSET) / SCALE)
    return core.resize.Point(c, format=vs.YUV444P16, matrix_s="709", range_s="full")


def _from_yuv16(clip):
    vs, core = _vs()
    return from_clip(core.resize.Point(clip, format=vs.RGBS, matrix_in_s="709", range_in_s="full")) * SCALE - OFFSET


# --- Denoisers --------------------------------------------------------------

def none(frames):
    return frames


def ffmpeg_filter(frames, vf: str):
    t, h, w, _ = frames.shape
    data = (np.clip((frames + OFFSET) / SCALE, 0, 1) * 65535 + 0.5).astype("<u2").tobytes()
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", f"{w}x{h}", "-r", "24",
         "-i", "-", "-vf", f"format=gbrp16le,{vf},format=rgb48le", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-"],
        input=data, check=True, capture_output=True,
    ).stdout
    out = np.frombuffer(raw, "<u2").reshape(t, h, w, 3).astype(np.float32) / 65535
    return out * SCALE - OFFSET


def hqdn3d(frames, luma_spatial=4.0, chroma_spatial=3.0, luma_tmp=6.0, chroma_tmp=4.5):
    return ffmpeg_filter(frames, f"hqdn3d={luma_spatial}:{chroma_spatial}:{luma_tmp}:{chroma_tmp}")


def atadenoise(frames, s=9, thr_a=0.02, thr_b=0.04):
    return ffmpeg_filter(frames, f"atadenoise=s={s}:0a={thr_a}:0b={thr_b}:1a={thr_a}:1b={thr_b}:2a={thr_a}:2b={thr_b}")


def mdegrain(frames, tr=2, blksize=16, overlap=8, pel=2, thsad=400, thsadc=None, search=4,
             searchparam=2, prefilter_sigma=0.0):
    """MVTools motion-compensated temporal averaging (MDegrain), tr = frames each side (1-6)."""
    vs, core = _vs()
    clip = _to_yuv16(frames)
    search_clip = clip
    if prefilter_sigma > 0:  # motion search on a blurred copy is more robust in heavy noise
        search_clip = core.std.Convolution(clip, matrix=[1, 2, 1, 2, 4, 2, 1, 2, 1])
    sup_search = core.mv.Super(search_clip, pel=pel, sharp=2)
    sup = core.mv.Super(clip, pel=pel, sharp=2, levels=1)
    vecs = []
    for d in range(1, tr + 1):
        for back in (True, False):
            vecs.append(core.mv.Analyse(sup_search, isb=back, delta=d, blksize=blksize, overlap=overlap,
                                        search=search, searchparam=searchparam, truemotion=False))
    thsadc = thsad if thsadc is None else thsadc
    fn = getattr(core.mv, f"Degrain{tr}")
    out = fn(clip, sup, *vecs, thsad=thsad, thsadc=thsadc)
    return _from_yuv16(out)


def vbm3d(frames, sigma_y=6.0, sigma_c=6.0, radius=1, final=True, block_step=8, bm_range=9, ps_num=2, ps_range=4):
    """Video BM3D (VS-BM3D, CPU). sigma is on the 0-255 scale of the [0, 1] working signal."""
    vs, core = _vs()
    c = to_clip((frames + OFFSET) / SCALE)
    opp = core.bm3d.RGB2OPP(c, sample=1)
    sig = [sigma_y, sigma_c, sigma_c]
    basic = core.bm3d.VBasic(opp, sigma=sig, radius=radius, block_step=block_step, bm_range=bm_range,
                             ps_num=ps_num, ps_range=ps_range, matrix=100)
    basic = core.bm3d.VAggregate(basic, radius=radius, sample=1)
    out = basic
    if final:
        fin = core.bm3d.VFinal(opp, ref=basic, sigma=sig, radius=radius, block_step=block_step,
                               bm_range=bm_range, ps_num=ps_num, ps_range=ps_range, matrix=100)
        out = core.bm3d.VAggregate(fin, radius=radius, sample=1)
    rgb = core.bm3d.OPP2RGB(out, sample=1)
    return from_clip(rgb) * SCALE - OFFSET


DENOISERS = {
    "none": (none, {}),
    "hqdn3d": (hqdn3d, {}),
    "atadenoise": (atadenoise, {}),
    "mdegrain": (mdegrain, {}),
    "vbm3d": (vbm3d, {}),
}


def run(name: str, frames: np.ndarray, **params) -> np.ndarray:
    fn, defaults = DENOISERS[name]
    return fn(np.asarray(frames, np.float32), **{**defaults, **params}).astype(np.float32)


# --- Denoising in the noise-equalised space (lab/vst.py) ---------------------

_TRANSFORM = None
VST_SCALE, VST_OFFSET = 130.0, (10.0, 65.0, 65.0)  # unit noise -> ~2 8-bit steps; fits [0, 1]


def noise_transform():
    global _TRANSFORM
    if _TRANSFORM is None:
        from pathlib import Path
        from .noise_model import NoiseModel
        from .vst import NoiseTransform
        _TRANSFORM = NoiseTransform.from_model(NoiseModel.load(Path(__file__).resolve().parents[1] / "testset" / "noise_model.json"))
    return _TRANSFORM


def to_clip16(planes: np.ndarray):
    """[T, H, W, 3] values in [0, 1] -> YUV444P16 clip, planes passed through untouched."""
    vs, core = _vs()
    t, h, w, _ = planes.shape
    blank = core.std.BlankClip(format=vs.YUV444P16, width=w, height=h, length=t, fpsnum=24000, fpsden=1001)
    arr = np.ascontiguousarray((np.clip(planes, 0, 1) * 65535 + 0.5).astype(np.uint16))

    def fill(n, f):
        fout = f.copy()
        for p in range(3):
            np.asarray(fout[p])[:] = arr[n, :, :, p]
        return fout

    return core.std.ModifyFrame(blank, blank, fill)


def from_clip16(clip) -> np.ndarray:
    out = np.empty((clip.num_frames, clip.height, clip.width, 3), np.float32)
    for n, f in enumerate(clip.frames(prefetch=PREFETCH)):
        for p in range(3):
            out[n, :, :, p] = np.asarray(f[p])
    return out / 65535


def per_frame_chunks(fn, *arrays, workers=4):
    """Apply fn to matching chunks of frames on several threads (numpy releases the GIL)."""
    from concurrent.futures import ThreadPoolExecutor
    t = arrays[0].shape[0]
    bounds = np.linspace(0, t, min(workers, t) + 1).astype(int)
    with ThreadPoolExecutor(len(bounds) - 1) as ex:
        parts = list(ex.map(lambda ab: fn(*(a[ab[0]:ab[1]] for a in arrays)), zip(bounds[:-1], bounds[1:])))
    return np.concatenate(parts)


def to_vst(frames):
    off = np.array(VST_OFFSET, np.float32)
    return per_frame_chunks(lambda f: (noise_transform().forward(f) + off) / VST_SCALE, np.asarray(frames, np.float32))


def from_vst(planes):
    off = np.array(VST_OFFSET, np.float32)
    return per_frame_chunks(lambda p: noise_transform().backward(p * VST_SCALE - off), np.asarray(planes, np.float32))


def mdegrain_planes(planes, tr=2, blksize=16, overlap=8, pel=2, thsad=400, thsadc=None, search=4,
                    searchparam=2, chroma_search=True, limit=None, limitc=None, search_blur=0.0,
                    truemotion=False, recalc_blksize=None, light_tr=None):
    """MDegrain on three planes already in [0, 1] (no colour conversion).

    search_blur > 0 estimates motion on a Gaussian-blurred copy (so coarse noise blotches
    don't steer the vectors) while still averaging the original pixels. recalc_blksize
    refines the vectors with smaller blocks.
    """
    vs, core = _vs()
    clip = to_clip16(planes)
    sup = core.mv.Super(clip, pel=pel, sharp=2, levels=1 if search_blur > 0 else 0)
    if search_blur > 0:
        from scipy import ndimage
        blurred = ndimage.gaussian_filter(planes, (0, search_blur, search_blur, 0))
        sup_search = core.mv.Super(to_clip16(blurred), pel=pel, sharp=2)
    else:
        sup_search = sup
    vecs = []
    for d in range(1, tr + 1):
        for back in (True, False):
            v = core.mv.Analyse(sup_search, isb=back, delta=d, blksize=blksize, overlap=overlap, search=search,
                                searchparam=searchparam, chroma=chroma_search, truemotion=truemotion)
            if recalc_blksize:
                v = core.mv.Recalculate(sup_search, v, blksize=recalc_blksize, overlap=recalc_blksize // 2,
                                        thsad=thsad, truemotion=truemotion)
            vecs.append(v)
    kw = {"thsad": thsad, "thsadc": thsad if thsadc is None else thsadc}
    if limit is not None:
        kw["limit"] = limit
    if limitc is not None:
        kw["limitc"] = limitc
    out = getattr(core.mv, f"Degrain{tr}")(clip, sup, *vecs, **kw)
    if light_tr:
        light = getattr(core.mv, f"Degrain{light_tr}")(clip, sup, *vecs[: 2 * light_tr], **kw)
        return from_clip16(out), from_clip16(light)
    return from_clip16(out)


def mdegrain_vst(frames, **params):
    """MDegrain in the noise-equalised, decorrelated space."""
    return from_vst(mdegrain_planes(to_vst(frames), **params))


DENOISERS["mdegrain_vst"] = (mdegrain_vst, {})


def mdegrain_vst_blend(frames, tr=4, light_tr=2, tex_lo=0.3, tex_hi=1.0, hp_sigma=1.5, energy_sigma=3.0,
                       spatial_sigma_y=0.0, spatial_sigma_c=0.0, spatial_mode="basic", **params):
    """Strong MDegrain where the picture is flat, lighter where there is fine texture.

    Both results share one motion analysis. Texture is detected on the light result's
    brightness plane in the noise-equalised space (noise std 1), as local energy of its
    fine band; tex_lo/tex_hi are in those units squared.
    """
    from scipy import ndimage
    planes = to_vst(frames)
    strong, light = mdegrain_planes(planes, tr=tr, light_tr=light_tr, **params)
    def blend(st, li):
        y = li[..., 0] * VST_SCALE
        hp = y - ndimage.gaussian_filter(y, (0, hp_sigma, hp_sigma))
        energy = ndimage.gaussian_filter(hp ** 2, (0, energy_sigma, energy_sigma))
        m = np.clip((energy - tex_lo) / (tex_hi - tex_lo), 0, 1)[..., None]
        return st * (1 - m) + li * m

    out = per_frame_chunks(blend, strong, light)
    if spatial_sigma_y > 0 or spatial_sigma_c > 0:
        out = bm3d_planes(out, spatial_sigma_y, spatial_sigma_c, spatial_mode)
    return from_vst(out)


def bm3d_planes(planes, sigma_y, sigma_c, mode="basic", block_step=8, bm_range=9):
    """Spatial BM3D on planes in the noise-equalised space (no colour conversion).

    sigma_* are in units of the original noise std (1.0 = the camera's full noise).
    """
    vs, core = _vs()
    t, h, w, _ = planes.shape
    blank = core.std.BlankClip(format=vs.YUV444PS, width=w, height=h, length=t)
    arr = np.ascontiguousarray(planes, dtype=np.float32)

    def fill(n, f):
        fout = f.copy()
        for p in range(3):
            np.asarray(fout[p])[:] = arr[n, :, :, p]
        return fout

    clip = core.std.ModifyFrame(blank, blank, fill)
    unit = 255.0 / VST_SCALE  # one noise std on BM3D's 0-255 sigma scale
    sig = [sigma_y * unit, sigma_c * unit, sigma_c * unit]
    basic = core.bm3d.Basic(clip, sigma=sig, block_step=block_step, bm_range=bm_range)
    out = basic if mode == "basic" else core.bm3d.Final(clip, ref=basic, sigma=sig, block_step=block_step,
                                                        bm_range=bm_range)
    res = np.empty_like(arr)
    for n, f in enumerate(out.frames(prefetch=PREFETCH)):
        for p in range(3):
            res[n, :, :, p] = np.asarray(f[p])
    return res


DENOISERS["mdegrain_vst_blend"] = (mdegrain_vst_blend, {})


# The climb's result (records/climb_log.md, round 6).
BEST_PARAMS = {"tr": 6, "light_tr": 2, "thsad": 300, "thsadc": 300, "spatial_sigma_y": 0.4, "spatial_sigma_c": 0.8}
DENOISERS["best"] = (mdegrain_vst_blend, BEST_PARAMS)

# Named versions from the climb, for side-by-side comparisons.
ROUND5_PARAMS = {"tr": 6, "light_tr": 2, "thsad": 300, "thsadc": 300}
DENOISERS["round5"] = (mdegrain_vst_blend, ROUND5_PARAMS)
DENOISERS["round6"] = (mdegrain_vst_blend, BEST_PARAMS)
