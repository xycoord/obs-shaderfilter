# Climb log (tuning set; held-back set not used for decisions)

| Round | Candidate | Score | Texture | Decision | Note |
|---|---|---|---|---|---|
| 0 | MDegrain default | +3.72 | 0.746 | start | |
| 1 | Frequency split (2 and 3 levels, several radii) | +3.82 to +4.44 | 0.70-0.71 | rejected | texture below floor; 3-level also worse in moving areas and flicker |
| 2 | MDegrain in noise-equalised space (lab/vst.py) | +4.18 | 0.752 | **accepted** | every guard held or improved |
| 3 | Noise-equalised MDegrain: radius 3 | +4.49 | 0.722 | **accepted** | radius 4 scored +5.06 but texture 0.700; stricter/looser block matching, stronger colour matching and blurred motion search all scored lower |
| 4 | Texture-aware blend: radius 4 in flat areas, radius 2 on fine texture (one shared motion analysis) | +5.11 | 0.734 | **accepted** | radius 6 / 3 blend scored +5.77 but texture 0.701 |
