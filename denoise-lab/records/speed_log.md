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

## GPU speed climb on an Intel Arc 130V laptop (Core Ultra 5 226V, Vulkan, plugged in, performance mode)

Measure: median of 5 runs (3 at 4K) of `gpu_blend` on 13 synthetic frames, seconds per megapixel-frame.
Quality guard: PSNR against the clean picture on three synthetic 1080p scenes (slow pan; texture with a
moving object; smooth uneven sub-pixel flow, which loses 0.58 dB with `search_range=1`), within 0.05 dB
overall and 0.15 dB on the worst 5 % of regions. Rounds 1-5 kept output bit-identical; later rounds are
"same quality".

| Round | Change | 1080p | 4K | Result |
|---|---|---|---|---|
| start | | 0.98 | 1.06 | |
| 1 | frame windows as long as memory allows (were 1 output frame each) | 0.112 | 0.124 | kept |
| 2 | unclamped SAD fast path | 0.103 | 0.115 | kept |
| 3 | don't re-score vectors already tried | 0.081 | 0.090 | kept |
| 4 | current block cached in workgroup memory | 0.172 | 0.191 | undone |
| 5 | stop a SAD once it can't win | 0.076 | 0.085 | kept |
| 6 | one subgroup per block (lanes over pixels) | search 1.4 s vs 1.06 s | | undone |
| 7 | brightness in textures | search 3.0 s vs 1.06 s | | undone |
| 8 | search on half-float brightness, 2 pixels per word | 0.056 | 0.063 | kept |
| 9 | one copy each way between numpy and the GPU | 0.042 | 0.050 | kept |
| 10 | tiles and windows chosen for least work in a 2 GB working set | 0.037 | 0.044 | kept |
| 11 | search on 8-bit brightness, 4 pixels per word | 0.032 | 0.040 | kept |
| 12 | averaging: vector read once for 3 planes; interleaved planes; half-float references | | | undone (no gain / slower) |
| 13 | search workgroup shapes 16x4, 32x2, 64x1 | | | 8x8 stays fastest |
| 14 | directly mapped input/output buffers | 0.032 | | undone (no gain) |
| 15 | multi-threaded upload/readback copies | 0.038 | | undone (slower) |

Rust CPU on the same machine: 0.048-0.049 at 1080p, so the GPU version is about 1.5x faster there. At 4K
both vary widely with memory pressure on this 16 GB machine (Rust 0.054-0.092, GPU 0.040-0.078).
The search is memory-bound, not arithmetic-bound: shrinking the data it reads gave the big wins, while
spreading each sum across lanes, textures and on-chip tiles all slowed it down. Remaining time at 1080p
(about 1 s per 13-frame clip): search 41 %, averaging 21 %, copies in and out about 17 %, blurs 8 %.
