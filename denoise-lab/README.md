# Denoise lab

Test bench for denoising Canon R50 V C-Log3 / Cinema Gamut gig footage, working in
DaVinci Wide Gamut / DaVinci Intermediate like the Resolve pipeline.

Setup: `python3 -m venv .venv && . .venv/bin/activate && pip install vapoursynth vapoursynth-mvtools vapoursynth-bm3d scikit-image scipy numpy colour-science`

1. Put trimmed camera clips (stream-copied, not re-encoded) in `footage/`.
2. `python fit_noise.py footage/<locked-off clip>.MP4` fits `testset/noise_model.json`.
   The camera must not move at all in that clip. Check it with
   `python tests/check_noise_model.py footage/<clip>.MP4 y0 y1 x0 x1` on a static region.
3. Edit `testset_config.json`, then `python build_testset.py`.
4. `python score.py <denoiser> [--params '{...}']` prints the measure (mean PSNR, dB, higher is better)
   plus guards (SSIM, detail kept, colour noise, flicker) and writes `results/<label>.json`.
5. `python review.py none mdegrain vbm3d --run <name>` renders 1:1 comparisons on the real footage.

`python tests/test_colour.py` checks the colour maths against colour-science and published values.
Denoisers live in `lab/denoisers.py`.
