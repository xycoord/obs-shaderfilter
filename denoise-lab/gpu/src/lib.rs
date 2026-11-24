//! GPU (wgpu: Vulkan / DirectX 12 / Metal) version of the round-5 denoiser.
//!
//! Same stages as the CPU reference in ../rust: noise-equalising transform, hierarchical
//! block matching on brightness, MDegrain-style strong + light averages, texture blend,
//! inverse transform. The motion search differs in one way: blocks are searched in
//! parallel, so predictors come only from the coarser level (no left/top neighbours).

use bytemuck::{Pod, Zeroable};
use numpy::{IntoPyArray, PyArray4, PyReadonlyArray1, PyReadonlyArray2, PyReadonlyArray4};
use pyo3::prelude::*;
use wgpu::util::DeviceExt;

const COMMON: &str = include_str!("wgsl/common.wgsl");

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable, Default)]
struct Params {
    w: u32, h: u32, t: u32, tr: u32,
    light_tr: u32, nbx: u32, nby: u32, npairs: u32,
    wl: u32, hl: u32, nbxl: u32, nbyl: u32,
    bsl: u32, offl: u32, range: u32, has_coarse: u32,
    wc: u32, hc: u32, nbxc: u32, nbyc: u32,
    radius: u32, axis: u32, pad1: u32, pad2: u32,
    th_y: f32, th_c: f32, tex_lo: f32, tex_hi: f32,
    fwd_lo: f32, fwd_step: f32, fwd_n: u32, inv_n: u32,
    inv_lo: [f32; 4],
    inv_step: [f32; 4],
}

pub struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pub adapter_name: String,
    pipes: std::collections::HashMap<&'static str, wgpu::ComputePipeline>,
}

impl Gpu {
    pub fn new() -> Result<Gpu, String> {
        let instance = wgpu::Instance::default();
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        }))
        .map_err(|e| format!("no GPU adapter: {e}"))?;
        let info = adapter.get_info();
        let mut limits = wgpu::Limits::default();
        let al = adapter.limits();
        limits.max_storage_buffer_binding_size = al.max_storage_buffer_binding_size;
        limits.max_buffer_size = al.max_buffer_size;
        limits.max_storage_buffers_per_shader_stage = al.max_storage_buffers_per_shader_stage.min(16);
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: None,
            required_features: wgpu::Features::empty(),
            required_limits: limits,
            ..Default::default()
        }))
        .map_err(|e| format!("device: {e}"))?;
        let mut pipes = std::collections::HashMap::new();
        for (name, src) in [
            ("forward", include_str!("wgsl/forward.wgsl")),
            ("down", include_str!("wgsl/down.wgsl")),
            ("search", include_str!("wgsl/search.wgsl")),
            ("degrain", include_str!("wgsl/degrain.wgsl")),
            ("blur", include_str!("wgsl/blur.wgsl")),
            ("hp2", include_str!("wgsl/hp2.wgsl")),
            ("final", include_str!("wgsl/final.wgsl")),
        ] {
            let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some(name),
                source: wgpu::ShaderSource::Wgsl(format!("{COMMON}\n{src}").into()),
            });
            let pipe = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(name),
                layout: None,
                module: &module,
                entry_point: Some("main"),
                compilation_options: Default::default(),
                cache: None,
            });
            pipes.insert(name, pipe);
        }
        Ok(Gpu { device, queue, adapter_name: format!("{} ({:?})", info.name, info.backend), pipes })
    }

    fn storage(&self, bytes: &[u8]) -> wgpu::Buffer {
        self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: None,
            contents: bytes,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
        })
    }

    fn empty(&self, n_words: usize) -> wgpu::Buffer {
        self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: (n_words.max(1) * 4) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        })
    }

    fn dispatch(&self, enc: &mut wgpu::CommandEncoder, name: &str, p: &Params, bufs: &[&wgpu::Buffer], gx: u32, gy: u32, gz: u32) {
        let ubuf = self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: None,
            contents: bytemuck::bytes_of(p),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let pipe = &self.pipes[name];
        let mut entries = vec![wgpu::BindGroupEntry { binding: 0, resource: ubuf.as_entire_binding() }];
        for (i, b) in bufs.iter().enumerate() {
            entries.push(wgpu::BindGroupEntry { binding: (i + 1) as u32, resource: b.as_entire_binding() });
        }
        let bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &pipe.get_bind_group_layout(0),
            entries: &entries,
        });
        let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some(name), timestamp_writes: None });
        pass.set_pipeline(pipe);
        pass.set_bind_group(0, &bg, &[]);
        pass.dispatch_workgroups(gx, gy, gz);
    }

    fn read(&self, buf: &wgpu::Buffer, n_words: usize) -> Vec<f32> {
        let staging = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: (n_words * 4) as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut enc = self.device.create_command_encoder(&Default::default());
        enc.copy_buffer_to_buffer(buf, 0, &staging, 0, (n_words * 4) as u64);
        self.queue.submit([enc.finish()]);
        let slice = staging.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        self.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
        let view = slice.get_mapped_range().expect("map");
        let out = bytemuck::cast_slice::<u8, f32>(&view).to_vec();
        drop(view);
        out
    }
}

fn gauss_kernel(sigma: f32) -> Vec<f32> {
    let r = (4.0 * sigma + 0.5) as i32;
    let mut k: Vec<f32> = (-r..=r).map(|i| (-(i * i) as f32 / (2.0 * sigma * sigma)).exp()).collect();
    let s: f32 = k.iter().sum();
    k.iter_mut().for_each(|v| *v /= s);
    k
}

fn groups(n: u32) -> u32 {
    (n + 7) / 8
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    gpu: &Gpu, input: &[f32], t_len: usize, h: usize, w: usize,
    fwd_tab: &[f32], fwd_lo: f32, fwd_step: f32, mat: &[f32], imat: &[f32],
    inv_tab: &[f32], inv_lo: [f32; 3], inv_step: [f32; 3],
    tr: usize, light_tr: usize, th_y: f32, th_c: f32, tex_lo: f32, tex_hi: f32,
    hp_sigma: f32, energy_sigma: f32, range: u32,
) -> Vec<f32> {
    let (t, hh, ww) = (t_len as u32, h as u32, w as u32);
    let nbx = (ww + 8) / 8 + 1;
    let nby = (hh + 8) / 8 + 1;
    // Pairs and the per-frame lookup (k = 2*(d-1) + 0 for t-d, +1 for t+d).
    let mut pairs: Vec<u32> = vec![];
    let mut lookup: Vec<i32> = vec![-1; t_len * 2 * tr];
    for ti in 0..t_len {
        for d in 1..=tr {
            for (s, side) in [(0usize, -1isize), (1, 1)] {
                let r = ti as isize + side * d as isize;
                if r >= 0 && (r as usize) < t_len {
                    lookup[ti * 2 * tr + 2 * (d - 1) + s] = (pairs.len() / 2) as i32;
                    pairs.extend([ti as u32, r as u32]);
                }
            }
        }
    }
    let npairs = (pairs.len() / 2) as u32;
    let fwd_n = (fwd_tab.len() / 3) as u32;
    let inv_n = (inv_tab.len() / 3) as u32;
    let mut base = Params {
        w: ww, h: hh, t, tr: tr as u32, light_tr: light_tr as u32, nbx, nby, npairs,
        th_y, th_c, tex_lo, tex_hi, fwd_lo, fwd_step, fwd_n, inv_n,
        inv_lo: [inv_lo[0], inv_lo[1], inv_lo[2], 0.0],
        inv_step: [inv_step[0], inv_step[1], inv_step[2], 1.0],
        range,
        ..Default::default()
    };
    let b_in = gpu.storage(bytemuck::cast_slice(input));
    let b_ftab = gpu.storage(bytemuck::cast_slice(fwd_tab));
    let b_mat = gpu.storage(bytemuck::cast_slice(mat));
    let b_imat = gpu.storage(bytemuck::cast_slice(imat));
    let b_itab = gpu.storage(bytemuck::cast_slice(inv_tab));
    let b_pairs = gpu.storage(bytemuck::cast_slice(&pairs));
    let b_lookup = gpu.storage(bytemuck::cast_slice(&lookup));
    let plane_words = t_len * 3 * h * w;
    let b_planes = gpu.empty(plane_words);
    let mut enc = gpu.device.create_command_encoder(&Default::default());

    // 1. forward transform (+ level-0 brightness)
    let mut levels: Vec<(u32, u32, wgpu::Buffer)> = vec![(ww, hh, gpu.empty(t_len * h * w))];
    gpu.dispatch(&mut enc, "forward", &base, &[&b_in, &b_ftab, &b_mat, &b_planes, &levels[0].2], groups(ww), groups(hh), t);
    // 2. pyramid
    while levels.len() < 5 && levels.last().unwrap().0 > 128 && levels.last().unwrap().1 > 72 {
        let (wc, hc) = (levels.last().unwrap().0, levels.last().unwrap().1);
        let (wl, hl) = ((wc + 1) / 2, (hc + 1) / 2);
        let buf = gpu.empty((wl * hl) as usize * t_len);
        let mut p = base;
        p.wl = wl; p.hl = hl; p.wc = wc; p.hc = hc;
        gpu.dispatch(&mut enc, "down", &p, &[&levels.last().unwrap().2, &buf], groups(wl), groups(hl), t);
        levels.push((wl, hl, buf));
    }
    // 3. motion search, coarsest to finest
    let mut coarse: Option<(u32, u32, wgpu::Buffer, wgpu::Buffer)> = None;
    let mut finest: Option<(wgpu::Buffer, wgpu::Buffer, wgpu::Buffer)> = None;
    for l in (0..levels.len()).rev() {
        let (wl, hl, ref lum) = levels[l];
        let (bsl, offl) = if l == 0 { (16u32, 8u32) } else { (8, 0) };
        let (nbxl, nbyl) = if l == 0 { (nbx, nby) } else { ((wl + 7) / 8, (hl + 7) / 8) };
        let n = (nbxl * nbyl * npairs) as usize;
        let (bvx, bvy, bsad) = (gpu.empty(n), gpu.empty(n), gpu.empty(n));
        let mut p = base;
        p.wl = wl; p.hl = hl; p.nbxl = nbxl; p.nbyl = nbyl; p.bsl = bsl; p.offl = offl;
        let dummy = gpu.empty(1);
        let (cvx, cvy) = match &coarse {
            Some((nx, ny, cx, cy)) => {
                p.has_coarse = 1; p.nbxc = *nx; p.nbyc = *ny;
                (cx, cy)
            }
            None => (&dummy, &dummy),
        };
        gpu.dispatch(&mut enc, "search", &p, &[lum, &b_pairs, cvx, cvy, &bvx, &bvy, &bsad], groups(nbxl), groups(nbyl), npairs);
        if l == 0 {
            finest = Some((bvx, bvy, bsad));
        } else {
            coarse = Some((nbxl, nbyl, bvx, bvy));
        }
    }
    let (fvx, fvy, fsad) = finest.unwrap();
    // 4. averaging
    let b_strong = gpu.empty(plane_words);
    let b_light = gpu.empty(plane_words);
    gpu.dispatch(&mut enc, "degrain", &base, &[&b_planes, &b_lookup, &fvx, &fvy, &fsad, &b_strong, &b_light], groups(ww), groups(hh), t);
    // 5. texture energy of the light brightness plane
    let k1 = gauss_kernel(hp_sigma);
    let k2 = gauss_kernel(energy_sigma);
    let (bk1, bk2) = (gpu.storage(bytemuck::cast_slice(&k1)), gpu.storage(bytemuck::cast_slice(&k2)));
    let one = t_len * h * w;
    let (ta, tb) = (gpu.empty(one), gpu.empty(one));
    let blur = |enc: &mut wgpu::CommandEncoder, src: &wgpu::Buffer, stride: u32, kern: &wgpu::Buffer, r: usize, axis: u32, dst: &wgpu::Buffer| {
        let mut p = base;
        p.radius = r as u32; p.axis = axis; p.pad1 = stride; p.pad2 = 0;
        gpu.dispatch(enc, "blur", &p, &[src, kern, dst], groups(ww), groups(hh), t);
    };
    blur(&mut enc, &b_light, 3, &bk1, k1.len() / 2, 0, &ta);
    blur(&mut enc, &ta, 1, &bk1, k1.len() / 2, 1, &tb);
    gpu.dispatch(&mut enc, "hp2", &base, &[&b_light, &tb, &ta], groups(ww), groups(hh), t);
    blur(&mut enc, &ta, 1, &bk2, k2.len() / 2, 0, &tb);
    let energy = gpu.empty(one);
    blur(&mut enc, &tb, 1, &bk2, k2.len() / 2, 1, &energy);
    // 6. mix and inverse
    let b_out = gpu.empty(plane_words);
    base.pad1 = 0;
    gpu.dispatch(&mut enc, "final", &base, &[&b_strong, &b_light, &energy, &b_imat, &b_itab, &b_out], groups(ww), groups(hh), t);
    gpu.queue.submit([enc.finish()]);
    gpu.read(&b_out, plane_words)
}

thread_local! {
    static GPU: std::cell::OnceCell<Result<Gpu, String>> = const { std::cell::OnceCell::new() };
}

#[pyfunction]
fn adapter() -> PyResult<String> {
    GPU.with(|g| match g.get_or_init(Gpu::new) {
        Ok(gpu) => Ok(gpu.adapter_name.clone()),
        Err(e) => Err(pyo3::exceptions::PyRuntimeError::new_err(e.clone())),
    })
}

#[pyfunction]
#[allow(clippy::too_many_arguments)]
#[pyo3(signature = (frames, fwd_tables, fwd_lo, fwd_step, matrix, inv_matrix, inv_tables, inv_lo, inv_step,
                    tr=6, light_tr=2, th_y=2.39, th_c=3.58, tex_lo=0.3, tex_hi=1.0, hp_sigma=1.5,
                    energy_sigma=3.0, search_range=4))]
fn denoise<'py>(
    py: Python<'py>, frames: PyReadonlyArray4<'py, f32>, fwd_tables: PyReadonlyArray2<'py, f32>,
    fwd_lo: f32, fwd_step: f32, matrix: PyReadonlyArray2<'py, f32>, inv_matrix: PyReadonlyArray2<'py, f32>,
    inv_tables: PyReadonlyArray2<'py, f32>, inv_lo: PyReadonlyArray1<'py, f32>, inv_step: PyReadonlyArray1<'py, f32>,
    tr: usize, light_tr: usize, th_y: f32, th_c: f32, tex_lo: f32, tex_hi: f32, hp_sigma: f32,
    energy_sigma: f32, search_range: u32,
) -> PyResult<Bound<'py, PyArray4<f32>>> {
    let fr = frames.as_array();
    let (t_len, h, w, _) = fr.dim();
    let input: Vec<f32> = fr.iter().cloned().collect();
    let ft: Vec<f32> = fwd_tables.as_array().iter().cloned().collect();
    let m: Vec<f32> = matrix.as_array().iter().cloned().collect();
    let mi: Vec<f32> = inv_matrix.as_array().iter().cloned().collect();
    let it: Vec<f32> = inv_tables.as_array().iter().cloned().collect();
    let il = inv_lo.as_array();
    let is = inv_step.as_array();
    let (il, is) = ([il[0], il[1], il[2]], [is[0], is[1], is[2]]);
    let out = GPU.with(|g| -> Result<Vec<f32>, String> {
        let gpu = g.get_or_init(Gpu::new).as_ref().map_err(|e| e.clone())?;
        Ok(run(gpu, &input, t_len, h, w, &ft, fwd_lo, fwd_step, &m, &mi, &it, il, is, tr, light_tr, th_y, th_c,
               tex_lo, tex_hi, hp_sigma, energy_sigma, search_range))
    })
    .map_err(pyo3::exceptions::PyRuntimeError::new_err)?;
    let arr = numpy::ndarray::Array4::from_shape_vec((t_len, h, w, 3), out)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
    Ok(arr.into_pyarray(py))
}

#[pymodule]
fn gigdenoise_gpu(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(denoise, m)?)?;
    m.add_function(wrap_pyfunction!(adapter, m)?)?;
    Ok(())
}
