// Brightness level as 8-bit values, four neighbouring pixels per word (pixel 4k + i in byte i).
// The noise-equalised brightness runs from 0 to about 100 with noise of about 1, so steps of
// LUM_SCALE / 255 (0.4) add little to it. A width that isn't a multiple of 4 repeats the last pixel.
const LUM_SCALE: f32 = 102.0;
@group(0) @binding(1) var<storage, read> src: array<f32>;          // [T][hl][wl]
@group(0) @binding(2) var<storage, read_write> dst: array<u32>;    // [T][hl][(wl+3)/4]

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let w4 = (P.wl + 3u) / 4u;
    if (id.x >= w4 || id.y >= P.hl || id.z >= P.t) { return; }
    let row = (id.z * P.hl + id.y) * P.wl;
    var v: vec4<f32>;
    for (var i = 0u; i < 4u; i++) {
        v[i] = src[row + min(4u * id.x + i, P.wl - 1u)] / LUM_SCALE;
    }
    dst[(id.z * P.hl + id.y) * w4 + id.x] = pack4x8unorm(v);
}
