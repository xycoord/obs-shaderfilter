// Separable Gaussian along one axis (axis 0 = x, 1 = y), reflect boundary like scipy.
// Input plane p of a [T][3][H][W] buffer (stride_planes = 3) or a [T][H][W] buffer (1).
@group(0) @binding(1) var<storage, read> src: array<f32>;
@group(0) @binding(2) var<storage, read> kern: array<f32>;     // 2*radius+1 taps
@group(0) @binding(3) var<storage, read_write> dst: array<f32>; // [T][H][W]

fn refl(i: i32, n: i32) -> i32 {
    var j = i;
    if (j < 0) { j = -j - 1; }
    if (j >= n) { j = 2 * n - j - 1; }
    return clamp(j, 0, n - 1);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let x = i32(id.x); let y = i32(id.y); let t = id.z;
    if (id.x >= P.w || id.y >= P.h || t >= P.t) { return; }
    // pad1 = plane stride (1 or 3), pad2 = plane index
    let base = (t * P.pad1 + P.pad2) * P.w * P.h;
    let r = i32(P.radius);
    var a = 0.0;
    for (var j = -r; j <= r; j++) {
        var sx = x; var sy = y;
        if (P.axis == 0u) { sx = refl(x + j, i32(P.w)); } else { sy = refl(y + j, i32(P.h)); }
        a += kern[u32(j + r)] * src[base + u32(sy) * P.w + u32(sx)];
    }
    dst[(t * P.h + id.y) * P.w + id.x] = a;
}
