//! Gig footage denoiser: a from-scratch Rust implementation of the climb's round-5 pipeline.
//!
//! 1. Noise-equalising transform (per-channel curves + 3x3 matrix, tables from Python),
//!    so the camera's noise has std ~1 everywhere.
//! 2. Hierarchical block-matching motion search on the brightness plane, 16x16 blocks
//!    every 8 pixels, whole-pixel vectors, for every frame against its neighbours
//!    t-tr..t+tr.
//! 3. MDegrain-style averaging: each reference block gets weight
//!    (T^2 - s^2) / (T^2 + s^2) (0 when s >= T), s = mean absolute difference of the
//!    matched brightness block; the current frame has weight 1. Overlapping blocks are
//!    blended with raised-cosine windows. Done twice from the same vectors: strong
//!    (radius tr) and light (radius light_tr).
//! 4. Texture-aware blend: strong where the light result's fine-band energy is low,
//!    light where it is high.
//! 5. Inverse transform.

use numpy::{IntoPyArray, PyArray4, PyReadonlyArray1, PyReadonlyArray2, PyReadonlyArray4};
use pyo3::prelude::*;
use rayon::prelude::*;

const BS: usize = 16; // block size at full resolution
const STEP: usize = 8; // block step (50 % overlap)
const PAD: usize = 64; // padding around each plane, bounds the vectors

/// A plane with replicated-edge padding of PAD pixels.
#[derive(Clone)]
struct Plane {
    w: usize,
    h: usize,
    stride: usize,
    data: Vec<f32>,
}

impl Plane {
    fn from_slice(src: &[f32], w: usize, h: usize) -> Plane {
        let stride = w + 2 * PAD;
        let hp = h + 2 * PAD;
        let mut data = vec![0f32; stride * hp];
        for y in 0..hp {
            let sy = (y as isize - PAD as isize).clamp(0, h as isize - 1) as usize;
            let row = &src[sy * w..sy * w + w];
            let dst = &mut data[y * stride..(y + 1) * stride];
            for x in 0..stride {
                let sx = (x as isize - PAD as isize).clamp(0, w as isize - 1) as usize;
                dst[x] = row[sx];
            }
        }
        Plane { w, h, stride, data }
    }
    #[inline]
    fn idx(&self, x: isize, y: isize) -> usize {
        ((y + PAD as isize) as usize) * self.stride + (x + PAD as isize) as usize
    }
    /// Half-size copy (2x2 box average), re-padded.
    fn half(&self) -> Plane {
        let w = (self.w + 1) / 2;
        let h = (self.h + 1) / 2;
        let mut src = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let (x2, y2) = (2 * x as isize, 2 * y as isize);
                let s = self.data[self.idx(x2, y2)]
                    + self.data[self.idx(x2 + 1, y2)]
                    + self.data[self.idx(x2, y2 + 1)]
                    + self.data[self.idx(x2 + 1, y2 + 1)];
                src[y * w + x] = s * 0.25;
            }
        }
        Plane::from_slice(&src, w, h)
    }
}

/// Mean absolute difference between an N x N block of `a` at (ax, ay) and of `b` at (bx, by).
#[inline(always)]
fn sad_n<const N: usize>(a: &Plane, ax: isize, ay: isize, b: &Plane, bx: isize, by: isize) -> f32 {
    let mut acc = [0f32; N];
    let ia = a.idx(ax, ay);
    let ib = b.idx(bx, by);
    for r in 0..N {
        let ra: &[f32; N] = a.data[ia + r * a.stride..ia + r * a.stride + N].try_into().unwrap();
        let rb: &[f32; N] = b.data[ib + r * b.stride..ib + r * b.stride + N].try_into().unwrap();
        for k in 0..N {
            acc[k] += (ra[k] - rb[k]).abs();
        }
    }
    acc.iter().sum::<f32>() / (N * N) as f32
}

#[inline(always)]
fn sad(a: &Plane, ax: isize, ay: isize, b: &Plane, bx: isize, by: isize, bs: usize) -> f32 {
    if bs == 16 {
        sad_n::<16>(a, ax, ay, b, bx, by)
    } else {
        sad_n::<8>(a, ax, ay, b, bx, by)
    }
}

/// Motion vectors (dx, dy) and their block SAD for every block of the finest grid.
struct Field {
    nbx: usize,
    nby: usize,
    vx: Vec<i32>,
    vy: Vec<i32>,
    sad: Vec<f32>,
}

fn grid(w: usize, h: usize) -> (usize, usize) {
    // Blocks start at -STEP so the first and last pixels are covered by two windows.
    ((w + STEP) / STEP + 1, (h + STEP) / STEP + 1)
}

/// Block origin of block (bx, by) on the finest grid.
#[inline]
fn origin(bx: usize, by: usize) -> (isize, isize) {
    (bx as isize * STEP as isize - STEP as isize, by as isize * STEP as isize - STEP as isize)
}

fn clamp_vec(v: (i32, i32), ox: isize, oy: isize, bs: usize, p: &Plane) -> (i32, i32) {
    let lim = PAD as isize - 1;
    let minx = -lim - ox;
    let maxx = p.w as isize + lim - bs as isize - ox;
    let miny = -lim - oy;
    let maxy = p.h as isize + lim - bs as isize - oy;
    (
        (v.0 as isize).clamp(minx, maxx.max(minx)) as i32,
        (v.1 as isize).clamp(miny, maxy.max(miny)) as i32,
    )
}

/// Search one level: blocks of `bs` every `step`, starting from predicted vectors.
fn search_level(
    cur: &Plane,
    rf: &Plane,
    bs: usize,
    step: usize,
    offset: isize,
    nbx: usize,
    nby: usize,
    predict: &dyn Fn(usize, usize) -> (i32, i32),
    range: i32,
) -> (Vec<i32>, Vec<i32>, Vec<f32>) {
    let n = nbx * nby;
    let (mut vx, mut vy, mut sd) = (vec![0i32; n], vec![0i32; n], vec![0f32; n]);
    for by in 0..nby {
        for bx in 0..nbx {
            let ox = bx as isize * step as isize - offset;
            let oy = by as isize * step as isize - offset;
            let mut cands: Vec<(i32, i32)> = Vec::with_capacity(5);
            cands.push((0, 0));
            cands.push(predict(bx, by));
            if bx > 0 {
                cands.push((vx[by * nbx + bx - 1], vy[by * nbx + bx - 1]));
            }
            if by > 0 {
                cands.push((vx[(by - 1) * nbx + bx], vy[(by - 1) * nbx + bx]));
                if bx + 1 < nbx {
                    cands.push((vx[(by - 1) * nbx + bx + 1], vy[(by - 1) * nbx + bx + 1]));
                }
            }
            let mut best = (0i32, 0i32);
            let mut best_s = f32::MAX;
            cands.sort_unstable();
            cands.dedup();
            for c in cands {
                let c = clamp_vec(c, ox, oy, bs, rf);
                let s = sad(cur, ox, oy, rf, ox + c.0 as isize, oy + c.1 as isize, bs);
                if s < best_s {
                    best_s = s;
                    best = c;
                }
            }
            // Small-diamond refinement until no neighbour improves (bounded steps).
            for it in 0..=range {
                let mut improved = false;
                let centre = best;
                let pts: &[(i32, i32)] = if it < range {
                    &[(1, 0), (-1, 0), (0, 1), (0, -1)]
                } else {
                    &[(1, 1), (-1, -1), (1, -1), (-1, 1)]
                };
                for &(dx, dy) in pts {
                    let c = clamp_vec((centre.0 + dx, centre.1 + dy), ox, oy, bs, rf);
                    if c == centre {
                        continue;
                    }
                    let s = sad(cur, ox, oy, rf, ox + c.0 as isize, oy + c.1 as isize, bs);
                    if s < best_s {
                        best_s = s;
                        best = c;
                        improved = true;
                    }
                }
                if !improved && it < range {
                    // converged: do the diagonal polish once and stop
                    let centre = best;
                    for (dx, dy) in [(1, 1), (-1, -1), (1, -1), (-1, 1)] {
                        let c = clamp_vec((centre.0 + dx, centre.1 + dy), ox, oy, bs, rf);
                        let s = sad(cur, ox, oy, rf, ox + c.0 as isize, oy + c.1 as isize, bs);
                        if s < best_s {
                            best_s = s;
                            best = c;
                        }
                    }
                    break;
                }
            }
            let i = by * nbx + bx;
            vx[i] = best.0;
            vy[i] = best.1;
            sd[i] = best_s;
        }
    }
    (vx, vy, sd)
}

/// Hierarchical motion estimation from `cur` to `rf` (pyramids, finest first).
fn estimate(cur: &[Plane], rf: &[Plane], range: i32) -> Field {
    let levels = cur.len();
    // Coarse levels: 8x8 blocks every 8 pixels.
    let mut prev: Option<(usize, usize, Vec<i32>, Vec<i32>)> = None;
    for l in (1..levels).rev() {
        let (c, r) = (&cur[l], &rf[l]);
        let nbx = (c.w + 7) / 8;
        let nby = (c.h + 7) / 8;
        let pr = prev.clone();
        let predict = move |bx: usize, by: usize| -> (i32, i32) {
            match &pr {
                None => (0, 0),
                Some((pnx, pny, pvx, pvy)) => {
                    let px = (bx / 2).min(pnx - 1);
                    let py = (by / 2).min(pny - 1);
                    (pvx[py * pnx + px] * 2, pvy[py * pnx + px] * 2)
                }
            }
        };
        let (vx, vy, _) = search_level(c, r, 8, 8, 0, nbx, nby, &predict, range);
        prev = Some((nbx, nby, vx, vy));
    }
    // Finest level: BS blocks every STEP, offset -STEP.
    let (c, r) = (&cur[0], &rf[0]);
    let (nbx, nby) = grid(c.w, c.h);
    let pr = prev.clone();
    let predict = move |bx: usize, by: usize| -> (i32, i32) {
        match &pr {
            None => (0, 0),
            Some((pnx, pny, pvx, pvy)) => {
                // Block centre at full res -> coarse (half-res) 8x8 block.
                let (ox, oy) = origin(bx, by);
                let cx = ((ox + BS as isize / 2).max(0) as usize / 2 / 8).min(pnx - 1);
                let cy = ((oy + BS as isize / 2).max(0) as usize / 2 / 8).min(pny - 1);
                (pvx[cy * pnx + cx] * 2, pvy[cy * pnx + cx] * 2)
            }
        }
    };
    let (vx, vy, sad) = search_level(c, r, BS, STEP, STEP as isize, nbx, nby, &predict, range);
    Field { nbx, nby, vx, vy, sad }
}

fn window() -> [f32; BS] {
    // sin^2 window: two copies offset by STEP sum to exactly 1.
    let mut w = [0f32; BS];
    for (i, v) in w.iter_mut().enumerate() {
        let s = (std::f32::consts::PI * (i as f32 + 0.5) / BS as f32).sin();
        *v = s * s;
    }
    w
}

/// Weighted motion-compensated averages of frame `t`: light (references within
/// `light_tr`) and strong (all references), in one pass. `refs` must be sorted by
/// distance. Returns ([light planes], [strong planes]).
fn degrain2(
    planes: &[[Plane; 3]],
    t: usize,
    refs: &[(usize, &Field)],
    n_light: usize,
    th_y: f32,
    th_c: f32,
) -> ([Vec<f32>; 3], [Vec<f32>; 3]) {
    let p0 = &planes[t][0];
    let (w, h, stride) = (p0.w, p0.h, p0.stride);
    let hp = h + 2 * PAD;
    let win = window();
    let mut light: [Vec<f32>; 3] = [vec![0f32; stride * hp], vec![0f32; stride * hp], vec![0f32; stride * hp]];
    let mut strong: [Vec<f32>; 3] = [vec![0f32; stride * hp], vec![0f32; stride * hp], vec![0f32; stride * hp]];
    let (nbx, nby) = grid(w, h);
    let wt = |s: f32, th: f32| -> f32 {
        if s >= th {
            0.0
        } else {
            (th * th - s * s) / (th * th + s * s)
        }
    };
    let nr = refs.len();
    let mut wts = vec![0f32; nr];
    let mut offs = vec![0isize; nr];
    for by in 0..nby {
        for bx in 0..nbx {
            let i = by * nbx + bx;
            let (ox, oy) = origin(bx, by);
            let base = p0.idx(ox, oy) as isize;
            for k in 0..nr {
                let f = refs[k].1;
                offs[k] = f.vy[i] as isize * stride as isize + f.vx[i] as isize;
            }
            for p in 0..3 {
                let th = if p == 0 { th_y } else { th_c };
                let (mut nl, mut ns) = (1f32, 1f32);
                for k in 0..nr {
                    wts[k] = wt(refs[k].1.sad[i], th);
                    if k < n_light {
                        nl += wts[k];
                    }
                    ns += wts[k];
                }
                let src = &planes[t][p].data;
                for r in 0..BS {
                    let row = (base + (r * stride) as isize) as usize;
                    let mut v: [f32; BS] = src[row..row + BS].try_into().unwrap();
                    let mut vl = [0f32; BS];
                    for k in 0..nr {
                        if k == n_light {
                            vl = v;
                        }
                        if wts[k] > 0.0 {
                            let rr = (row as isize + offs[k]) as usize;
                            let rd: &[f32; BS] = planes[refs[k].0][p].data[rr..rr + BS].try_into().unwrap();
                            let wk = wts[k];
                            for c in 0..BS {
                                v[c] += wk * rd[c];
                            }
                        }
                    }
                    if n_light >= nr {
                        vl = v;
                    }
                    let (il, is) = (1.0 / nl, 1.0 / ns);
                    let wr = win[r];
                    let dl: &mut [f32] = &mut light[p][row..row + BS];
                    for c in 0..BS {
                        dl[c] += wr * win[c] * vl[c] * il;
                    }
                    let ds: &mut [f32] = &mut strong[p][row..row + BS];
                    for c in 0..BS {
                        ds[c] += wr * win[c] * v[c] * is;
                    }
                }
            }
        }
    }
    // Crop the padding away.
    let crop = |buf: &Vec<f32>| -> Vec<f32> {
        let mut o = vec![0f32; w * h];
        for y in 0..h {
            let s0 = (y + PAD) * stride + PAD;
            o[y * w..(y + 1) * w].copy_from_slice(&buf[s0..s0 + w]);
        }
        o
    };
    (
        [crop(&light[0]), crop(&light[1]), crop(&light[2])],
        [crop(&strong[0]), crop(&strong[1]), crop(&strong[2])],
    )
}

#[inline]
fn degrain_weight(s: f32, th: f32) -> f32 {
    if s >= th {
        0.0
    } else {
        (th * th - s * s) / (th * th + s * s)
    }
}

fn gaussian(src: &[f32], w: usize, h: usize, sigma: f32) -> Vec<f32> {
    let r = (4.0 * sigma + 0.5) as usize;
    let mut k: Vec<f32> = (0..=2 * r)
        .map(|i| {
            let d = i as f32 - r as f32;
            (-(d * d) / (2.0 * sigma * sigma)).exp()
        })
        .collect();
    let s: f32 = k.iter().sum();
    k.iter_mut().for_each(|v| *v /= s);
    // Mirror boundary ("reflect"), like scipy.ndimage's default.
    let refl = |i: isize, n: isize| -> usize {
        let mut i = i;
        if i < 0 {
            i = -i - 1;
        }
        if i >= n {
            i = 2 * n - i - 1;
        }
        i.clamp(0, n - 1) as usize
    };
    let mut tmp = vec![0f32; w * h];
    let mut line = vec![0f32; w + 2 * r];
    for y in 0..h {
        for x in 0..w + 2 * r {
            line[x] = src[y * w + refl(x as isize - r as isize, w as isize)];
        }
        let out = &mut tmp[y * w..(y + 1) * w];
        for (j, kv) in k.iter().enumerate() {
            let seg = &line[j..j + w];
            for x in 0..w {
                out[x] += kv * seg[x];
            }
        }
    }
    let mut out = vec![0f32; w * h];
    for y in 0..h {
        let o = &mut out[y * w..(y + 1) * w];
        for (j, kv) in k.iter().enumerate() {
            let sy = refl(y as isize + j as isize - r as isize, h as isize);
            let seg = &tmp[sy * w..(sy + 1) * w];
            for x in 0..w {
                o[x] += kv * seg[x];
            }
        }
    }
    out
}

/// Sliding-window DCT shrinkage: 8x8 blocks every `step` pixels, coefficients below
/// lambda * sigma set to zero (DC kept), blocks aggregated with weight 1 / kept-count,
/// as in BM3D's first stage but without grouping similar blocks.
fn dct_shrink(src: &[f32], w: usize, h: usize, sigma: f32, lambda: f32, step: usize) -> Vec<f32> {
    if sigma <= 0.0 || w < 8 || h < 8 {
        return src.to_vec();
    }
    let mut d = [[0f32; 8]; 8];
    for k in 0..8 {
        for n in 0..8 {
            let a = if k == 0 { (1.0f32 / 8.0).sqrt() } else { (2.0f32 / 8.0).sqrt() };
            d[k][n] = a * (std::f32::consts::PI * (2 * n + 1) as f32 * k as f32 / 16.0).cos();
        }
    }
    let thr = lambda * sigma;
    let mut num = vec![0f32; w * h];
    let mut den = vec![0f32; w * h];
    let pos = |n: usize| -> Vec<usize> {
        let mut v: Vec<usize> = (0..=n - 8).step_by(step).collect();
        if *v.last().unwrap() != n - 8 {
            v.push(n - 8);
        }
        v
    };
    let (xs, ys) = (pos(w), pos(h));
    for &y0 in &ys {
        for &x0 in &xs {
            let mut b = [[0f32; 8]; 8];
            for r in 0..8 {
                b[r].copy_from_slice(&src[(y0 + r) * w + x0..(y0 + r) * w + x0 + 8]);
            }
            // C = D B D^T
            let mut t = [[0f32; 8]; 8];
            for k in 0..8 {
                for c in 0..8 {
                    let mut a = 0f32;
                    for n in 0..8 {
                        a += d[k][n] * b[n][c];
                    }
                    t[k][c] = a;
                }
            }
            let mut cf = [[0f32; 8]; 8];
            let mut kept = 0usize;
            for k in 0..8 {
                for l in 0..8 {
                    let mut a = 0f32;
                    for n in 0..8 {
                        a += t[k][n] * d[l][n];
                    }
                    if (k == 0 && l == 0) || a.abs() >= thr {
                        cf[k][l] = a;
                        kept += 1;
                    }
                }
            }
            // B' = D^T C D
            for k in 0..8 {
                for c in 0..8 {
                    let mut a = 0f32;
                    for l in 0..8 {
                        a += cf[k][l] * d[l][c];
                    }
                    t[k][c] = a;
                }
            }
            let wt = 1.0 / kept as f32;
            for r in 0..8 {
                for c in 0..8 {
                    let mut a = 0f32;
                    for k in 0..8 {
                        a += d[k][r] * t[k][c];
                    }
                    let o = (y0 + r) * w + x0 + c;
                    num[o] += wt * a;
                    den[o] += wt;
                }
            }
        }
    }
    num.iter().zip(den.iter()).map(|(a, b)| a / b).collect()
}

#[inline]
fn lerp(table: &[f32], lo: f32, step: f32, x: f32) -> f32 {
    let n = table.len();
    let f = ((x - lo) / step).clamp(0.0, (n - 1) as f32 - 1e-6);
    let i = f as usize;
    let t = f - i as f32;
    table[i] * (1.0 - t) + table[i + 1] * t
}

/// Denoise DWG/DI frames [T, H, W, 3]. Transform tables come from lab/vst.py.
#[pyfunction]
#[allow(clippy::too_many_arguments)]
#[pyo3(signature = (frames, fwd_tables, fwd_lo, fwd_step, matrix, inv_matrix, inv_tables, inv_lo, inv_step,
                    tr=6, light_tr=2, th_y=2.39, th_c=3.58, tex_lo=0.3, tex_hi=1.0, hp_sigma=1.5,
                    energy_sigma=3.0, search_range=4, spatial_y=0.0, spatial_c=0.0, spatial_lambda=2.7,
                    spatial_step=4, spatial_pre=false))]
fn denoise<'py>(
    py: Python<'py>,
    frames: PyReadonlyArray4<'py, f32>,
    fwd_tables: PyReadonlyArray2<'py, f32>,
    fwd_lo: f32,
    fwd_step: f32,
    matrix: PyReadonlyArray2<'py, f32>,
    inv_matrix: PyReadonlyArray2<'py, f32>,
    inv_tables: PyReadonlyArray2<'py, f32>,
    inv_lo: PyReadonlyArray1<'py, f32>,
    inv_step: PyReadonlyArray1<'py, f32>,
    tr: usize,
    light_tr: usize,
    th_y: f32,
    th_c: f32,
    tex_lo: f32,
    tex_hi: f32,
    hp_sigma: f32,
    energy_sigma: f32,
    search_range: i32,
    spatial_y: f32,
    spatial_c: f32,
    spatial_lambda: f32,
    spatial_step: usize,
    spatial_pre: bool,
) -> PyResult<Bound<'py, PyArray4<f32>>> {
    let fr = frames.as_array();
    let (t_len, h, w, _) = fr.dim();
    let fwd = fwd_tables.as_array().to_owned();
    let m = matrix.as_array().to_owned();
    let mi = inv_matrix.as_array().to_owned();
    let inv = inv_tables.as_array().to_owned();
    let inv_lo = inv_lo.as_array().to_owned();
    let inv_step = inv_step.as_array().to_owned();
    let input: Vec<f32> = match fr.as_slice() {
        Some(sl) => sl.to_vec(), // contiguous: one memcpy
        None => fr.iter().cloned().collect(),
    }; // [T][H][W][3]

    let out = py.detach(move || {
        let prof = std::env::var("GIGDENOISE_PROFILE").is_ok();
        let t0 = std::time::Instant::now();
        let lap = |name: &str| {
            if prof {
                eprintln!("{:>10.3}s {}", t0.elapsed().as_secs_f64(), name);
            }
        };
        let fwd_rows: Vec<Vec<f32>> = (0..3).map(|c| fwd.row(c).to_vec()).collect();
        let inv_rows: Vec<Vec<f32>> = (0..3).map(|c| inv.row(c).to_vec()).collect();
        // 1. Forward transform into three padded planes per frame.
        let planes: Vec<[Plane; 3]> = (0..t_len)
            .into_par_iter()
            .map(|t| {
                let mut z = [vec![0f32; w * h], vec![0f32; w * h], vec![0f32; w * h]];
                let base = t * h * w * 3;
                for i in 0..w * h {
                    let mut y = [0f32; 3];
                    for c in 0..3 {
                        y[c] = lerp(&fwd_rows[c], fwd_lo, fwd_step, input[base + i * 3 + c]);
                    }
                    for p in 0..3 {
                        z[p][i] = m[[p, 0]] * y[0] + m[[p, 1]] * y[1] + m[[p, 2]] * y[2];
                    }
                }
                if spatial_pre {
                    // Spatial pass on every input frame, before temporal averaging, so the
                    // averaging smooths out frame-to-frame differences the spatial pass makes.
                    for p in 0..3 {
                        let sg = if p == 0 { spatial_y } else { spatial_c };
                        if sg > 0.0 {
                            z[p] = dct_shrink(&z[p], w, h, sg, spatial_lambda, spatial_step);
                        }
                    }
                }
                [Plane::from_slice(&z[0], w, h), Plane::from_slice(&z[1], w, h), Plane::from_slice(&z[2], w, h)]
            })
            .collect();
        lap("forward transform");
        // Brightness pyramids for the motion search.
        let pyr: Vec<Vec<Plane>> = planes
            .par_iter()
            .map(|p| {
                let mut v = vec![p[0].clone()];
                while v.last().unwrap().w > 128 && v.last().unwrap().h > 72 && v.len() < 5 {
                    let next = v.last().unwrap().half();
                    v.push(next);
                }
                v
            })
            .collect();
        lap("pyramids");
        // 2. Motion fields for every (frame, neighbour) pair.
        let jobs: Vec<(usize, usize)> = (0..t_len)
            .flat_map(|t| {
                (1..=tr).flat_map(move |d| {
                    let mut v = vec![];
                    if t >= d {
                        v.push((t, t - d));
                    }
                    if t + d < t_len {
                        v.push((t, t + d));
                    }
                    v
                })
            })
            .collect();
        let fields: Vec<((usize, usize), Field)> = jobs
            .par_iter()
            .map(|&(t, r)| ((t, r), estimate(&pyr[t], &pyr[r], search_range)))
            .collect();
        lap("motion search");
        // 3-5. Per frame: strong and light averages, texture blend, inverse transform.
        let mut out = vec![0f32; t_len * h * w * 3];
        out.par_chunks_mut(h * w * 3).enumerate().for_each(|(t, out)| {
            let mut refs: Vec<(usize, &Field)> = fields
                .iter()
                .filter(|((a, b), _)| *a == t && (*b as isize - t as isize).unsigned_abs() <= tr)
                .map(|((_, b), f)| (*b, f))
                .collect();
            refs.sort_by_key(|(b, _)| (*b as isize - t as isize).unsigned_abs());
            let n_light = refs
                .iter()
                .filter(|(b, _)| (*b as isize - t as isize).unsigned_abs() <= light_tr)
                .count();
            let (light, strong) = degrain2(&planes, t, &refs, n_light, th_y, th_c);
            let ly = &light[0];
            let g = gaussian(ly, w, h, hp_sigma);
            let hp2: Vec<f32> = ly.iter().zip(g.iter()).map(|(a, b)| (a - b) * (a - b)).collect();
            let energy = gaussian(&hp2, w, h, energy_sigma);
            let mut zz3: [Vec<f32>; 3] = std::array::from_fn(|p| {
                strong[p]
                    .iter()
                    .zip(light[p].iter())
                    .zip(energy.iter())
                    .map(|((s, l), e)| {
                        let mk = ((e - tex_lo) / (tex_hi - tex_lo)).clamp(0.0, 1.0);
                        s + mk * (l - s)
                    })
                    .collect()
            });
            for p in 0..3 {
                let sg = if p == 0 { spatial_y } else { spatial_c };
                if sg > 0.0 && !spatial_pre {
                    zz3[p] = dct_shrink(&zz3[p], w, h, sg, spatial_lambda, spatial_step);
                }
            }
            for i in 0..w * h {
                let zz = [zz3[0][i], zz3[1][i], zz3[2][i]];
                for c in 0..3 {
                    let y = mi[[c, 0]] * zz[0] + mi[[c, 1]] * zz[1] + mi[[c, 2]] * zz[2];
                    out[i * 3 + c] = lerp(&inv_rows[c], inv_lo[c], inv_step[c], y);
                }
            }
        });
        lap("averaging, blend, inverse");
        out
    });
    let arr = numpy::ndarray::Array4::from_shape_vec((t_len, h, w, 3), out)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
    Ok(arr.into_pyarray(py))
}

#[pymodule]
fn gigdenoise(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(denoise, m)?)?;
    Ok(())
}
