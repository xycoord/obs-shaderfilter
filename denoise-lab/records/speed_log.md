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
