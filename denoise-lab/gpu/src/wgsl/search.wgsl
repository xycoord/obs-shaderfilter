// Block matching on one pyramid level for every (frame, reference) pair.
// Blocks of bsl x bsl every 8 pixels starting at -offl. Predictors: zero, and the
// coarser level's vector (x2) for the block under this one's centre and its four
// neighbours. Then a small-diamond descent and one diagonal polish.
@group(0) @binding(1) var<storage, read> lum: array<u32>;      // this level, 8-bit in fours [T][hl][(wl+3)/4] (see pack.wgsl)
@group(0) @binding(2) var<storage, read> pairs: array<u32>;    // [npairs][2] (cur, ref)
@group(0) @binding(3) var<storage, read> cvx: array<i32>;      // coarser vectors [npairs][nbyc][nbxc]
@group(0) @binding(4) var<storage, read> cvy: array<i32>;
@group(0) @binding(5) var<storage, read_write> vx: array<i32>; // this level [npairs][nbyl][nbxl]
@group(0) @binding(6) var<storage, read_write> vy: array<i32>;
@group(0) @binding(7) var<storage, read_write> sad_out: array<f32>;

fn px(f: u32, x: i32, y: i32) -> f32 {
    let cx = clamp(x, 0, i32(P.wl) - 1);
    let cy = clamp(y, 0, i32(P.hl) - 1);
    let w4 = (P.wl + 3u) / 4u;
    let v = unpack4x8unorm(lum[(f * P.hl + u32(cy)) * w4 + u32(cx) / 4u]);
    return v[u32(cx) & 3u] * 102.0;
}

// SAD of the block at (ox, oy) against the reference block moved by (dx, dy), or a value
// >= best when it can't beat best: abs differences are never negative, so the running sum only
// grows and a row-end partial already at or past best decides the comparison exactly.
fn sad(cur: u32, rf: u32, ox: i32, oy: i32, dx: i32, dy: i32, best: f32) -> f32 {
    var s = 0.0;
    let b = i32(P.bsl);
    let bb = f32(b * b);
    let wl = i32(P.wl); let hl = i32(P.hl);
    // Fast path when both blocks (and the reference's extra word) lie inside the level: whole
    // words, no clamping. The current block starts on a word; a reference starting `sh` bytes
    // into a word takes each four pixels from two neighbouring words.
    let w4 = (P.wl + 3u) / 4u;
    let rx = ox + dx;
    if ((ox & 3) == 0 && min(min(ox, rx), min(oy, oy + dy)) >= 0 && max(ox, rx) + b + 4 <= wl
        && max(oy, oy + dy) + b <= hl) {
        let sh = u32(rx & 3) * 8u;
        var ci = (cur * P.hl + u32(oy)) * w4 + u32(ox) / 4u;
        var ri = (rf * P.hl + u32(oy + dy)) * w4 + u32(rx) / 4u;
        let nw = u32(b) / 4u;
        for (var j = 0; j < b; j++) {
            var prev = lum[ri];
            for (var k = 0u; k < nw; k++) {
                let nxt = lum[ri + k + 1u];
                let rw = select((prev >> sh) | (nxt << (32u - sh)), prev, sh == 0u);
                let d = abs(unpack4x8unorm(lum[ci + k]) - unpack4x8unorm(rw));
                s += (d.x + d.y) + (d.z + d.w);
                prev = nxt;
            }
            if (s * 102.0 / bb >= best) { return s * 102.0 / bb; }
            ci += w4; ri += w4;
        }
        return s * 102.0 / bb;
    }
    for (var j = 0; j < b; j++) {
        for (var i = 0; i < b; i++) {
            s += abs(px(cur, ox + i, oy + j) - px(rf, ox + i + dx, oy + j + dy));
        }
        if (s / bb >= best) { return s / bb; }
    }
    return s / bb;
}

const NSEEN: u32 = 32u;
var<private> seen: array<vec2<i32>, 32>;
var<private> nseen: u32 = 0u;

// True if v was scored already (its SAD can't beat best_s, so scoring it again changes nothing).
fn was_seen(v: vec2<i32>) -> bool {
    for (var i = 0u; i < nseen; i++) {
        if (all(seen[i] == v)) { return true; }
    }
    if (nseen < NSEEN) { seen[nseen] = v; nseen++; }
    return false;
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
    var best_s = sad(cur, rf, ox, oy, 0, 0, 3.0e38);
    _ = was_seen(best);
    if (P.has_coarse == 1u) {
        let cxb = clamp((ox + i32(P.bsl) / 2) / 2 / 8, 0, i32(P.nbxc) - 1);
        let cyb = clamp((oy + i32(P.bsl) / 2) / 2 / 8, 0, i32(P.nbyc) - 1);
        let offs = array<vec2<i32>, 5>(vec2(0, 0), vec2(-1, 0), vec2(1, 0), vec2(0, -1), vec2(0, 1));
        for (var k = 0u; k < 5u; k++) {
            let qx = clamp(cxb + offs[k].x, 0, i32(P.nbxc) - 1);
            let qy = clamp(cyb + offs[k].y, 0, i32(P.nbyc) - 1);
            let ci = pi * P.nbxc * P.nbyc + u32(qy) * P.nbxc + u32(qx);
            let c = clamp(vec2<i32>(cvx[ci] * 2, cvy[ci] * 2), vec2(-lim), vec2(lim));
            if (was_seen(c)) { continue; }
            let s = sad(cur, rf, ox, oy, c.x, c.y, best_s);
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
            if (was_seen(c)) { continue; }
            let s = sad(cur, rf, ox, oy, c.x, c.y, best_s);
            if (s < best_s) { best_s = s; best = c; improved = true; }
        }
        if (!improved) { break; }
    }
    let centre = best;
    for (var k = 0u; k < 4u; k++) {
        let c = clamp(centre + diag[k], vec2(-lim), vec2(lim));
        if (was_seen(c)) { continue; }
        let s = sad(cur, rf, ox, oy, c.x, c.y, best_s);
        if (s < best_s) { best_s = s; best = c; }
    }
    let o = pi * P.nbxl * P.nbyl + by * P.nbxl + bx;
    vx[o] = best.x; vy[o] = best.y; sad_out[o] = best_s;
}
