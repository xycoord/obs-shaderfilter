// GPU version of the round-5 denoiser (see ../../rust/src/lib.rs for the CPU reference).
// Images are planar f32 storage buffers; coordinates are clamped at the edges.
struct Params {
    w: u32, h: u32, t: u32, tr: u32,
    light_tr: u32, nbx: u32, nby: u32, npairs: u32,
    wl: u32, hl: u32, nbxl: u32, nbyl: u32,
    bsl: u32, offl: u32, range: u32, has_coarse: u32,
    wc: u32, hc: u32, nbxc: u32, nbyc: u32,
    radius: u32, axis: u32, pad1: u32, pad2: u32,
    th_y: f32, th_c: f32, tex_lo: f32, tex_hi: f32,
    fwd_lo: f32, fwd_step: f32, fwd_n: u32, inv_n: u32,
    inv_lo: vec4<f32>,
    inv_step: vec4<f32>,
    // input element (word) offset and strides; output offset and strides; crop start and size
    in_off: u32, in_st: u32, in_sy: u32, in_sx: u32,
    out_off: u32, out_st: u32, out_sy: u32, out_sx: u32,
    ct: u32, cy: u32, cx: u32, ot: u32,
    oh: u32, ow: u32, pad3: u32, pad4: u32,
};
@group(0) @binding(0) var<uniform> P: Params;
