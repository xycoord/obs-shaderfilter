# Climb log (tuning set; held-back set not used for decisions)

| Round | Candidate | Score | Texture | Decision | Note |
|---|---|---|---|---|---|
| 0 | MDegrain default | +3.72 | 0.746 | start | |
| 1 | Frequency split (2 and 3 levels, several radii) | +3.82 to +4.44 | 0.70-0.71 | rejected | texture below floor; 3-level also worse in moving areas and flicker |
| 2 | MDegrain in noise-equalised space (lab/vst.py) | +4.18 | 0.752 | **accepted** | every guard held or improved |
| 3 | Noise-equalised MDegrain: radius 3 | +4.49 | 0.722 | **accepted** | radius 4 scored +5.06 but texture 0.700; stricter/looser block matching, stronger colour matching and blurred motion search all scored lower |
| 4 | Texture-aware blend: radius 4 in flat areas, radius 2 on fine texture (one shared motion analysis) | +5.11 | 0.734 | **accepted** | radius 6 / 3 blend scored +5.77 but texture 0.701 |
| 5 | Same blend with stricter block matching (thSAD 300): radius 6 flat, radius 2 texture | +5.81 | 0.780 | **accepted** | stricter matching kept far more texture, which allowed radius 6; plain radius 6 at thSAD 250 scored +5.71 (texture 0.790) |
| 6 | Round 5 plus a light spatial BM3D in the noise-equalised space (0.4 of the noise on brightness, 0.8 on colour) | +7.65 | 0.734 | **accepted: target reached** | 0.3/0.6 scored +7.21. The noise-equalising lookups were rewritten as uniform tables (same scores, about 0.3 s/MP-frame faster) so this fits the 1.5 s/MP-frame limit at 1.22 |

## Held-back check (once, at the end)

| Candidate | Score | Synthetic | Real | Texture kept | Moving |
|---|---|---|---|---|---|
| MDegrain default (start) | +2.96 | +2.67 | +3.25 | 0.575 | 31.05 |
| Final (round 6) | +6.10 | +5.05 | +7.16 | 0.408 | 33.42 |

The improvement holds on unseen material (+3.15 dB, against +3.93 dB on the tuning set), but the texture
measure falls on the held-back clips (0.575 to 0.408), more than on the tuning set (0.746 to 0.734). Per clip,
the tuning set's average hid a similar fall on the dim warm interior (dinner: 0.550 to 0.436). On the darkest
held-back clip (bar, median DI luma 0.01) the clean reference's own grain makes up much of what the texture
measure counts, so part of that fall is the measure, not the denoiser.
