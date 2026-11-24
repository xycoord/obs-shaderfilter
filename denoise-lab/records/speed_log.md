# Speed climb (quality held constant)

Speed is the median of three runs of `python bench.py <denoiser>` on a 13-frame, 1920x1080 crop of real
4K footage at full pixel scale, on this 4-core cloud machine. Quality is checked by rescoring the tuning set.

| Step | Change | Round-6 settings (s/MP-frame) | Speed-up | Quality |
|---|---|---|---|---|
| Start | | 1.18 | 1.0x | +7.648 dB |
| 1 | VapourSynth renders 4 frames at once instead of one (MVTools and BM3D are single-threaded per frame) | 0.74 | 1.6x | identical |
| 2 | Noise-equalising transform and texture blend run on 4 threads | 0.53 | 2.2x | identical (every measure and every clip unchanged) |

Round-5 settings (no spatial BM3D) now run at 0.43 s/MP-frame.

Where the time goes now (round-6 settings, single-threaded stage timings): MDegrain analysis and averaging
about 0.33, spatial BM3D 0.12, texture blend 0.11, the two transforms 0.09 together.

## Round-5 settings (chosen version)

Starting point: round 5 after steps 1-2, 0.425 s/MP-frame. Acceptance (`compare_speed.py`): quality checked against
this fixed start, score may fall at most 0.1 dB, every guard within tolerance, texture may fall at most 0.01 on any
clip, and at least 1.10x faster than the current fastest.

| Step | Change | s/MP-frame | vs start | Quality vs start | Result |
|---|---|---|---|---|---|
| 3a | Motion search on brightness only | 0.294 | 1.45x | moving areas -0.21 dB, worst regions -0.27 dB | rejected |
| 3b | ...and smaller block overlap | 0.229 | 1.86x | moving -0.50 dB, SSIM and colour noise worse | rejected |
| 3c | Whole-pixel motion search (colour still used) | 0.338 | 1.26x | all held | accepted |
| 3d | ...and a narrower search refinement | 0.324 | 1.31x | all held | (superseded) |
| 3e | Brightness-only, whole-pixel search, colour matching loosened to compensate (thSADC 450) | 0.250 | 1.70x | all held; score +0.36 dB, texture 0.780 to 0.817 | **accepted** |

## Rust rewrite (bold option, approved overnight)

`rust/` reimplements the round-5 pipeline from scratch (no MVTools, no VapourSynth): noise-equalising
transform, hierarchical whole-pixel block matching on brightness (16x16 blocks every 8 px), MDegrain-style
weighted averaging for the strong and light results in one pass, texture blend, inverse transform, all in
one multi-threaded call. Built with `maturin develop --release`; used as the `rust_blend` denoiser.

| Version | s/MP-frame (median of 5) | Quality vs round-5 start | Result |
|---|---|---|---|
| round5_fast (MVTools, step 3e) | 0.232 | accepted earlier | |
| Rust v1 | ~0.18 | worst regions -0.16 dB, flicker +3.0 % (just outside tolerance) | rejected |
| Rust v2: cheaper diamond search, zero-copy input | 0.124 | all held; score +6.30 dB (start +5.81), texture 0.809 | **accepted** (1.9x over MVTools fast, 3.4x over the round-5 start) |

| Rust v3 (single-pass averaging restored, no output copy) | 0.127 | identical output to v2 | accepted |

Rust v3 is 3.3x faster than the round-5 start (0.425) and 9x faster than the original round-6 timing (1.18),
on the same benchmark.

Blind council check, real footage, MVTools round 5 against Rust v3: the two are near-identical. Three of four
judges preferred Rust (cleaner colour noise, crisper moving hair); one preferred MVTools because of an apparent
colour shift in the darkest panning shot. Averaged over all frames there is no colour bias (R-G +0.2, B-G +0.7,
brightness +0.8 levels for Rust against -0.1, +0.7, +0.7 for MVTools): the per-frame difference is Rust removing
more of the coarse colour mottle. Both lift near-blacks by under a level on average.

## GPU version (wgpu compute shaders)

`gpu/` runs the round-5 pipeline on the GPU (Vulkan, DirectX 12 or Metal through wgpu), processing the clip in
tiles that fit the GPU's buffer limits (tiled and untiled output are identical). Tested here only on a software
Vulkan driver (llvmpipe), so no meaningful speed yet; `bench_laptop.py` and LAPTOP.md measure it on real hardware.

Quality against the round-5 start (tuning set):

| Version | Score | Worst 5 % | Moving | Flicker | Texture | Result |
|---|---|---|---|---|---|---|
| CPU Rust v3 (reference) | +6.30 | 30.52 | 33.47 | 0.0068 | 0.809 | accepted |
| GPU v1: motion search predicts only from the coarser level | +6.26 | 30.37 | 33.28 | 0.0072 | 0.817 | rejected (worst regions, moving, flicker, one clip's texture) |
| GPU v2: plus one pass using neighbours' vectors | +6.17 | 30.38 | 33.34 | 0.0072 | 0.810 | rejected (worst regions -0.28 dB, flicker +7 %) |

The remaining gap is in the motion search: blocks are searched in parallel, so they can't build on their
neighbours' finished vectors the way the CPU version does. Next to try on real hardware, where iterations are
fast: more refinement passes, a wider search, and vector smoothness costs.
