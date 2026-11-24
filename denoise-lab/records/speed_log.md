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
