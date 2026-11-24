// (light_y - blurred)^2
@group(0) @binding(1) var<storage, read> light: array<f32>;   // [T][3][H][W]
@group(0) @binding(2) var<storage, read> blurred: array<f32>; // [T][H][W]
@group(0) @binding(3) var<storage, read_write> dst: array<f32>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= P.w || id.y >= P.h || id.z >= P.t) { return; }
    let i = (id.z * P.h + id.y) * P.w + id.x;
    let l = light[(id.z * 3u * P.h + id.y) * P.w + id.x];
    let d = l - blurred[i];
    dst[i] = d * d;
}
