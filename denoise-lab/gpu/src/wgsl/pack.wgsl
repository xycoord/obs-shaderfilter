// Brightness level as half floats, two neighbouring pixels per word (x = 2k low half, 2k+1 high
// half; an odd width repeats the last pixel, like the search's edge clamping).
@group(0) @binding(1) var<storage, read> src: array<f32>;          // [T][hl][wl]
@group(0) @binding(2) var<storage, read_write> dst: array<u32>;    // [T][hl][(wl+1)/2]

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let w2 = (P.wl + 1u) / 2u;
    if (id.x >= w2 || id.y >= P.hl || id.z >= P.t) { return; }
    let row = (id.z * P.hl + id.y) * P.wl;
    let x0 = 2u * id.x;
    let x1 = min(x0 + 1u, P.wl - 1u);
    dst[(id.z * P.hl + id.y) * w2 + id.x] = pack2x16float(vec2(src[row + x0], src[row + x1]));
}
