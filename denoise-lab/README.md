# Denoise lab

Test bench for denoising Canon R50 V C-Log3 / Cinema Gamut gig footage, working in
DaVinci Wide Gamut / DaVinci Intermediate like the Resolve pipeline.

Setup: `python3 -m venv .venv && . .venv/bin/activate && pip install vapoursynth vapoursynth-mvtools vapoursynth-bm3d scikit-image scipy numpy colour-science`

## Data (not committed)

- `footage/`: trimmed camera clips, stream-copied, never re-encoded.
- `sources/`: clean 4K stretches of Xiph's Netflix test sequences, fetched by
  `python fetch_sources.py`. Licence CC BY-NC-ND 4.0: personal, non-commercial use only.

## Building the sets

1. `python fit_noise.py footage/<locked-off clip>.MP4` fits `testset/noise_model.json`
   from frames one GOP (12 frames) apart, plus the frame-to-frame carry-over.
   Check it with `python tests/check_noise_model.py footage/<clip>.MP4 y0 y1 x0 x1`.
2. `python build_testset.py` builds `testset/tuning/` and `testset/heldout/` from
   `testset_config.json`. Each set has a synthetic part (clean 4K + modelled noise; covers
   motion) and a real part (genuine noise in static areas of the gig clips, scored against
   the raw frame one GOP later). The sets are split by source sequence and by camera take.

## The measure

`python score.py <denoiser> [--params '{...}'] --label <name>` scores the tuning set:
a score in dB (average of the synthetic and real gains) plus guards: worst 5 % regions,
moving areas, texture detail, SSIM, flicker, colour noise and speed.

`python compare.py results/tuning/<best>.json results/tuning/<candidate>.json` applies the
acceptance rules in `climb_rules.json`: the score must rise and no guard may get worse
beyond its tolerance.

The held-back set (`--set heldout --milestone "<reason>"`) is only scored at agreed
milestones and every run is logged to `records/heldout_log.jsonl` (committed). It never decides anything.

`python review.py none mdegrain --run <name>` renders 1:1 comparisons on the real footage.
`python tests/test_colour.py` checks the colour maths. Denoisers live in `lab/denoisers.py`.
