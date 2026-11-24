// Block matching on one pyramid level for every (frame, reference) pair.
// Blocks of bsl x bsl every 8 pixels starting at -offl. Predictors: zero, and the
// coarser level's vector (x2) for the block under this one's centre and its four
// neighbours. Then a small-diamond descent and one diagonal polish.
@group(0) @binding(1) var<storage, read> lum: array<f32>;      // this level, [T][hl][wl]
@group(0) @binding(2) var<storage, read> pairs: array<u32>;    // [npairs][2] (cur, ref)
@group(0) @binding(3) var<storage, read> cvx: array<i32>;      // coarser vectors [npairs][nbyc][nbxc]
@group(0) @binding(4) var<storage, read> cvy: array<i32>;
@group(0) @binding(5) var<storage, read_write> vx: array<i32>; // this level [npairs][nbyl][nbxl]
@group(0) @binding(6) var<storage, read_write> vy: array<i32>;
@group(0) @binding(7) var<storage, read_write> sad_out: array<f32>;

fn px(f: u32, x: i32, y: i32) -> f32 {
    let cx = clamp(x, 0, i32(P.wl) - 1);
    let cy = clamp(y, 0, i32(P.hl) - 1);
    return lum[(f * P.hl + u32(cy)) * P.wl + u32(cx)];
}

fn sad(cur: u32, rf: u32, ox: i32, oy: i32, dx: i32, dy: i32) -> f32 {
    var s = 0.0;
    let b = i32(P.bsl);
    for (var j = 0; j < b; j++) {
        for (var i = 0; i < b; i++) {
            s += abs(px(cur, ox + i, oy + j) - px(rf, ox + i + dx, oy + j + dy));
        }
    }
    return s / f32(b * b);
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let bx = id.x; let by = id.y; let pi = id.z;
    if (bx >= P.nbxl || by >= P.nbyl || pi >= P.npairs) { return; }
    let cur = pairs[pi * 2u]; let rf = pairs[pi * 2u + 1u];
    let ox = i32(bx * 8u) - i32(P.offl);
    let oy = i32(by * 8u) - i32(P.offl);
    let lim = 128;
    var best = vec2<i32>(0, 0);
    var best_s = sad(cur, rf, ox, oy, 0, 0);
    if (P.has_coarse == 1u) {
        let cxb = clamp((ox + i32(P.bsl) / 2) / 2 / 8, 0, i32(P.nbxc) - 1);
        let cyb = clamp((oy + i32(P.bsl) / 2) / 2 / 8, 0, i32(P.nbyc) - 1);
        let offs = array<vec2<i32>, 5>(vec2(0, 0), vec2(-1, 0), vec2(1, 0), vec2(0, -1), vec2(0, 1));
        for (var k = 0u; k < 5u; k++) {
            let qx = clamp(cxb + offs[k].x, 0, i32(P.nbxc) - 1);
            let qy = clamp(cyb + offs[k].y, 0, i32(P.nbyc) - 1);
            let ci = pi * P.nbxc * P.nbyc + u32(qy) * P.nbxc + u32(qx);
            let c = clamp(vec2<i32>(cvx[ci] * 2, cvy[ci] * 2), vec2(-lim), vec2(lim));
            let s = sad(cur, rf, ox, oy, c.x, c.y);
            if (s < best_s) { best_s = s; best = c; }
        }
    }
    let dia = array<vec2<i32>, 4>(vec2(1, 0), vec2(-1, 0), vec2(0, 1), vec2(0, -1));
    let diag = array<vec2<i32>, 4>(vec2(1, 1), vec2(-1, -1), vec2(1, -1), vec2(-1, 1));
    for (var it = 0u; it < P.range; it++) {
        let centre = best;
        var improved = false;
        for (var k = 0u; k < 4u; k++) {
            let c = clamp(centre + dia[k], vec2(-lim), vec2(lim));
            let s = sad(cur, rf, ox, oy, c.x, c.y);
            if (s < best_s) { best_s = s; best = c; improved = true; }
        }
        if (!improved) { break; }
    }
    let centre = best;
    for (var k = 0u; k < 4u; k++) {
        let c = clamp(centre + diag[k], vec2(-lim), vec2(lim));
        let s = sad(cur, rf, ox, oy, c.x, c.y);
        if (s < best_s) { best_s = s; best = c; }
    }
    let o = pi * P.nbxl * P.nbyl + by * P.nbxl + bx;
    vx[o] = best.x; vy[o] = best.y; sad_out[o] = best_s;
}
