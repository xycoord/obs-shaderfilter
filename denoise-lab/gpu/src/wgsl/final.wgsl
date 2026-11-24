// Texture-aware mix of strong and light, inverse matrix, inverse curves -> [T][H][W][3].
@group(0) @binding(1) var<storage, read> strong: array<f32>;
@group(0) @binding(2) var<storage, read> light: array<f32>;
@group(0) @binding(3) var<storage, read> energy: array<f32>;  // [T][H][W]
@group(0) @binding(4) var<storage, read> imat: array<f32>;    // [3][3]
@group(0) @binding(5) var<storage, read> itab: array<f32>;    // [3][inv_n]
@group(0) @binding(6) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    // one thread per output pixel; the output is the crop of the tile starting at (ct, cy, cx)
    if (id.x >= P.ow || id.y >= P.oh || id.z >= P.ot) { return; }
    let t = id.z + P.ct;
    let y = id.y + P.cy;
    let x = id.x + P.cx;
    let pix = (t * P.h + y) * P.w + x;
    let o_at = P.out_off + id.z * P.out_st + id.y * P.out_sy + id.x * P.out_sx;
    let mk = clamp((energy[pix] - P.tex_lo) / (P.tex_hi - P.tex_lo), 0.0, 1.0);
    var z: array<f32, 3>;
    for (var p = 0u; p < 3u; p++) {
        let o = ((t * 3u + p) * P.h + y) * P.w + x;
        z[p] = strong[o] + mk * (light[o] - strong[o]);
    }
    for (var c = 0u; c < 3u; c++) {
        let yv = imat[c * 3u] * z[0] + imat[c * 3u + 1u] * z[1] + imat[c * 3u + 2u] * z[2];
        let f = clamp((yv - P.inv_lo[c]) / P.inv_step[c], 0.0, f32(P.inv_n - 1u) - 1e-3);
        let i = u32(f);
        let a = f - f32(i);
        dst[o_at + c] = itab[c * P.inv_n + i] * (1.0 - a) + itab[c * P.inv_n + i + 1u] * a;
    }
}
