// MDegrain-style weighted average, gathered per output pixel from the 2x2 overlapping
// 16x16 blocks that cover it (sin^2 windows sum to 1). Writes the strong (all refs) and
// light (refs within light_tr) results for all three planes.
@group(0) @binding(1) var<storage, read> planes: array<f32>;   // [T][3][H][W]
@group(0) @binding(2) var<storage, read> lookup: array<i32>;   // [T][2*tr] pair index or -1
@group(0) @binding(3) var<storage, read> fvx: array<i32>;      // finest [npairs][nby][nbx]
@group(0) @binding(4) var<storage, read> fvy: array<i32>;
@group(0) @binding(5) var<storage, read> fsad: array<f32>;
@group(0) @binding(6) var<storage, read_write> strong: array<f32>; // [T][3][H][W]
@group(0) @binding(7) var<storage, read_write> light: array<f32>;

fn sample(f: u32, p: u32, x: i32, y: i32) -> f32 {
    let cx = clamp(x, 0, i32(P.w) - 1);
    let cy = clamp(y, 0, i32(P.h) - 1);
    return planes[((f * 3u + p) * P.h + u32(cy)) * P.w + u32(cx)];
}

fn wt(s: f32, th: f32) -> f32 {
    if (s >= th) { return 0.0; }
    return (th * th - s * s) / (th * th + s * s);
}

fn win(i: i32) -> f32 {
    let s = sin(3.14159265 * (f32(i) + 0.5) / 16.0);
    return s * s;
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let x = i32(id.x); let y = i32(id.y); let t = id.z;
    if (id.x >= P.w || id.y >= P.h || t >= P.t) { return; }
    let nk = 2u * P.tr;
    var acc_s = array<f32, 3>(0.0, 0.0, 0.0);
    var acc_l = array<f32, 3>(0.0, 0.0, 0.0);
    let bx1 = (x + 8) / 8; let by1 = (y + 8) / 8;
    for (var byi = by1 - 1; byi <= by1; byi++) {
        for (var bxi = bx1 - 1; bxi <= bx1; bxi++) {
            let ox = bxi * 8 - 8; let oy = byi * 8 - 8;
            let ww = win(x - ox) * win(y - oy);
            let bi = u32(byi) * P.nbx + u32(bxi);
            for (var p = 0u; p < 3u; p++) {
                let th = select(P.th_c, P.th_y, p == 0u);
                let s0 = sample(t, p, x, y);
                var vs = s0; var vl = s0; var ns = 1.0; var nl = 1.0;
                for (var k = 0u; k < nk; k++) {
                    let pi = lookup[t * nk + k];
                    if (pi < 0) { continue; }
                    let fi = u32(pi) * P.nbx * P.nby + bi;
                    let w = wt(fsad[fi], th);
                    if (w <= 0.0) { continue; }
                    let rf = select(t + 1u + k / 2u, t - 1u - k / 2u, (k & 1u) == 0u);
                    let v = sample(rf, p, x + fvx[fi], y + fvy[fi]);
                    vs += w * v; ns += w;
                    if (k / 2u + 1u <= P.light_tr) { vl += w * v; nl += w; }
                }
                acc_s[p] += ww * vs / ns;
                acc_l[p] += ww * vl / nl;
            }
        }
    }
    for (var p = 0u; p < 3u; p++) {
        let o = ((t * 3u + p) * P.h + id.y) * P.w + id.x;
        strong[o] = acc_s[p];
        light[o] = acc_l[p];
    }
}
