// Half-size brightness level: 2x2 box average of the finer level (wc x hc -> wl x hl).
@group(0) @binding(1) var<storage, read> fine: array<f32>;
@group(0) @binding(2) var<storage, read_write> coarse: array<f32>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let x = id.x; let y = id.y; let t = id.z;
    if (x >= P.wl || y >= P.hl || t >= P.t) { return; }
    let base = t * P.wc * P.hc;
    let x0 = min(2u * x, P.wc - 1u); let x1 = min(2u * x + 1u, P.wc - 1u);
    let y0 = min(2u * y, P.hc - 1u); let y1 = min(2u * y + 1u, P.hc - 1u);
    coarse[(t * P.hl + y) * P.wl + x] = 0.25 * (fine[base + y0 * P.wc + x0] + fine[base + y0 * P.wc + x1]
                                              + fine[base + y1 * P.wc + x0] + fine[base + y1 * P.wc + x1]);
}
