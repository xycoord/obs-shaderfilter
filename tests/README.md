# Tests

Parity and performance tests for obs-shaderfilter, run in a real (headless) OBS.

## Pieces

| | |
|---|---|
| `setup/build-libobs.sh` | Builds libobs, the OpenGL renderer and the image source from upstream OBS (33.0.1) with two test-only patches: `obs_source_video_tick()` is exported so frames can be ticked with fixed time steps, and only the image-source module is built. |
| `harness/harness.c` | Boots libobs on an X display (Xvfb + Mesa llvmpipe), loads one build of the plugin, builds scenes from a JSON spec, ticks and renders them like OBS's own frame loop, and writes PNGs (parity) or frame times (bench). Steps can change the filter stack mid-run (enable, reorder, update settings, remove). |
| `harness/detshim.c` | `LD_PRELOAD` shim: pins `rand()`, `time()`, `gettimeofday()` and the plugin's `os_gettime_ns()` so two builds see identical random and clock uniforms; optionally counts GL draws and render-target pixels per frame. |
| `make_test_images.py` | Test patterns with colour bars, 1 px and 4 px checkerboards, gradients, and translucent/transparent regions (alpha handling is the part a render-path change most easily breaks). |
| `shadertest.py` | Builds the specs, runs the harness against a reference and a new build, compares frames, and benchmarks. |
| `fusion/fusion_test.c` | Unit tool for `shader-fusion.c` (no GPU): which shaders are pointwise, and the fused effect text for a list of shaders. |
| `run.sh` | Sets everything up and runs it; used by `.github/workflows/parity.yml`. |

## Parity

`run.sh parity` renders 464 cases with release 2.6.1 and with this tree:

* every example shader as a filter (or as a transition, for those using `image_a`/`image_b`);
* inline shaders, expansion, non-default parameters, texture parameters bound to another source;
* temporal shaders (`previous_output`, `previous_image`) behind an animated filter;
* chains, the same shader twice, a disabled filter mid-chain, a source shown twice in the scene;
* the filter stack changing while it runs;
* a fusion sweep: every `.shader` upstream of a pointwise filter and every one downstream of an animated filter.

Frames are compared pixel by pixel and each case gets a verdict:

* **exact**: bit-identical.
* **close**: rounding-level. Translucent pixels can't be bit-identical: the old filter boundary rounds through hardware sRGB conversions, and llvmpipe's are approximate (it disagrees with exact rounding on about a third of translucent values). Separately, the same shader compiled into a different program can round 1 LSB differently. A few LSB per link, accumulating along a chain, is expected.
* **edge**: confined to a sliver of pixels where a translucent edge meets fully transparent pixels and a later shader samples across it. llvmpipe interpolates texture coordinates without snapping, so the reference picks up a ~1e-5 weight from the opaque neighbour and, after un-premultiplying, bleeds its colour into the alpha-0 pixel; real GPUs snap to 1/256 texel and don't.
* **amplified**: a listed shader that turns a 1-LSB input difference into a large one by design (thresholds, histograms; see `AMPLIFIERS` in `shadertest.py`).
* **FAIL**: anything else.

Every non-exact case gets a montage (reference | new | difference × 16) in `diffs/` for a visual check.

`--opaque` uses a fully opaque test image. The filter boundary is then exactly the identity, so only
rounding is allowed and an "edge" verdict fails.

A separate **boundary check** holds the in-shader emulation of the old filter boundary to an exact
numerical model of it (sRGB conversions and 8-bit rounding done exactly), over 16384 colour/alpha pairs.

## Benchmark

`run.sh bench` times filter chains at 1080p (`--size 64 36` measures per-frame CPU overhead instead) and
reports, per case, the median frame time and the number of draws and megapixels of render target written
per frame. The draw and pixel counts don't depend on the GPU, and the pixels written are what costs time on
a bandwidth-limited one; llvmpipe times overweight shader arithmetic compared with a real GPU. Every case
includes 2 draws of harness overhead (the source in the scene and a 1×1 read-back).

## Limits

Everything here runs on OpenGL through Mesa's software renderer. Direct3D 11 (Windows) and Metal compile
the same effect text but aren't exercised; HDR colour spaces take the unchanged path and aren't covered
beyond that.
