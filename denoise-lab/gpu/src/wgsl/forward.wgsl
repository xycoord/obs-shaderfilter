@group(0) @binding(1) var<storage, read> src: array<f32>;          // [T][H][W][3] DWG/DI
@group(0) @binding(2) var<storage, read> tab: array<f32>;          // [3][fwd_n]
@group(0) @binding(3) var<storage, read> mat: array<f32>;          // [3][3]
@group(0) @binding(4) var<storage, read_write> planes: array<f32>; // [T][3][H][W]
@group(0) @binding(5) var<storage, read_write> lum0: array<f32>;   // [T][H][W]

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let x = id.x; let y = id.y; let t = id.z;
    if (x >= P.w || y >= P.h || t >= P.t) { return; }
    let pix = (t * P.h + y) * P.w + x;
    var v: array<f32, 3>;
    for (var c = 0u; c < 3u; c++) {
        let f = clamp((src[P.in_off + t * P.in_st + y * P.in_sy + x * P.in_sx + c] - P.fwd_lo) / P.fwd_step, 0.0, f32(P.fwd_n - 1u) - 1e-3);
        let i = u32(f);
        let a = f - f32(i);
        v[c] = tab[c * P.fwd_n + i] * (1.0 - a) + tab[c * P.fwd_n + i + 1u] * a;
    }
    let plane = P.w * P.h;
    for (var p = 0u; p < 3u; p++) {
        let z = mat[p * 3u] * v[0] + mat[p * 3u + 1u] * v[1] + mat[p * 3u + 2u] * v[2];
        planes[(t * 3u + p) * plane + y * P.w + x] = z;
        if (p == 0u) { lum0[pix] = z; }
    }
}
