//! GPU (wgpu: Vulkan / DirectX 12 / Metal) version of the round-5 denoiser.
//!
//! Same stages as the CPU reference in ../rust: noise-equalising transform, hierarchical
//! block matching on brightness, MDegrain-style strong + light averages, texture blend,
//! inverse transform. The motion search differs in one way: blocks are searched in
//! parallel, so predictors come only from the coarser level (no left/top neighbours).

use bytemuck::{Pod, Zeroable};
use numpy::ndarray::{s, ArrayView4, ArrayViewMut4};
use numpy::{PyReadonlyArray1, PyReadonlyArray2, PyReadonlyArray4, PyReadwriteArray4};
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
    in_off: u32, in_st: u32, in_sy: u32, in_sx: u32,
    out_off: u32, out_st: u32, out_sy: u32, out_sx: u32,
    ct: u32, cy: u32, cx: u32, ot: u32,
    oh: u32, ow: u32, pad3: u32, pad4: u32,
}

/// Vulkan's VK_EXT_external_memory_host: lets the GPU use ordinary program memory (here the
/// numpy arrays) as a buffer in place, so the frames are not copied in or out.
struct HostImport {
    dev: ash::Device,
    ext: ash::ext::external_memory_host::Device,
    align: usize,
}

pub struct Gpu {
    pub max_binding: u64,
    host: Option<HostImport>,
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
        let max_binding = limits.max_storage_buffer_binding_size as u64;
        let desc = wgpu::DeviceDescriptor {
            label: None,
            required_features: wgpu::Features::empty(),
            required_limits: limits.clone(),
            ..Default::default()
        };
        // With GIGDENOISE_IMPORT set, open the device with VK_EXT_external_memory_host where the
        // driver has it, so frames are used in place; otherwise they are copied in and out.
        // Opt-in because it lost the device twice at 4K under memory pressure (see speed_log.md).
        let ext_name = ash::ext::external_memory_host::NAME;
        let open = if std::env::var_os("GIGDENOISE_IMPORT").is_none() {
            None
        } else {
            unsafe { adapter.as_hal::<wgpu::hal::api::Vulkan>() }.and_then(|ha| {
                let inst = ha.shared_instance().raw_instance();
                let has = unsafe { inst.enumerate_device_extension_properties(ha.raw_physical_device()) }
                    .map(|v| v.iter().any(|e| e.extension_name_as_c_str() == Ok(ext_name)))
                    .unwrap_or(false);
                if !has {
                    return None;
                }
                unsafe {
                    ha.open_with_callback(
                        wgpu::Features::empty(), &limits, &wgpu::MemoryHints::default(),
                        Some(Box::new(move |args: wgpu::hal::vulkan::CreateDeviceCallbackArgs| args.extensions.push(ext_name))),
                    )
                }
                .ok()
            })
        };
        let (device, queue) = match open {
            Some(open) => unsafe { adapter.create_device_from_hal(open, &desc) },
            None => pollster::block_on(adapter.request_device(&desc)),
        }
        .map_err(|e| format!("device: {e}"))?;
        let host = if open_is_import(&device, ext_name) {
            unsafe { device.as_hal::<wgpu::hal::api::Vulkan>() }.map(|hd| {
                let inst = hd.shared_instance().raw_instance();
                let dev = hd.raw_device().clone();
                let ext = ash::ext::external_memory_host::Device::new(inst, &dev);
                let mut emh = ash::vk::PhysicalDeviceExternalMemoryHostPropertiesEXT::default();
                let mut p2 = ash::vk::PhysicalDeviceProperties2::default().push_next(&mut emh);
                unsafe { inst.get_physical_device_properties2(hd.raw_physical_device(), &mut p2) };
                let align = emh.min_imported_host_pointer_alignment.max(4096) as usize;
                HostImport { dev, ext, align }
            })
        } else {
            None
        };
        let mut pipes = std::collections::HashMap::new();
        for (name, src) in [
            ("forward", include_str!("wgsl/forward.wgsl")),
            ("down", include_str!("wgsl/down.wgsl")),
            ("search", include_str!("wgsl/search.wgsl")),
            ("pack", include_str!("wgsl/pack.wgsl")),
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
        Ok(Gpu { max_binding, host, device, queue, adapter_name: format!("{} ({:?})", info.name, info.backend), pipes })
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
        // GIGDENOISE_PROFILE=1: run each dispatch on its own and wait for it, adding its time to
        // the per-stage totals that profile() returns.
        let prof = std::env::var_os("GIGDENOISE_PROFILE").is_some();
        let mut own = prof.then(|| self.device.create_command_encoder(&Default::default()));
        {
            let enc = own.as_mut().unwrap_or(enc);
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some(name), timestamp_writes: None });
            pass.set_pipeline(pipe);
            pass.set_bind_group(0, &bg, &[]);
            pass.dispatch_workgroups(gx, gy, gz);
        }
        if let Some(e) = own {
            let t0 = std::time::Instant::now();
            self.queue.submit([e.finish()]);
            self.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
            let dt = t0.elapsed().as_secs_f64();
            PROFILE.with(|m| *m.borrow_mut().entry(name.to_string()).or_insert(0.0) += dt);
        }
    }

    /// Map a copy of `buf` and hand its contents to `f` (no intermediate copy).
    fn read_with(&self, buf: &wgpu::Buffer, n_words: usize, f: impl FnOnce(&[f32])) {
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
        f(bytemuck::cast_slice::<u8, f32>(&view));
    }

    /// Wrap the memory holding `len` bytes at `ptr` as a GPU buffer, in place. Returns the buffer
    /// and the word offset of `ptr` inside it (the buffer starts at the page holding `ptr`).
    /// The memory must stay valid, and not be touched by the CPU, until the buffer is destroyed.
    unsafe fn import(&self, ptr: *const u8, len: usize) -> Option<(wgpu::Buffer, u32)> {
        use ash::vk;
        let hi = self.host.as_ref()?;
        let a = hi.align;
        let start = ptr as usize & !(a - 1);
        let end = (ptr as usize + len + a - 1) & !(a - 1);
        let size = (end - start) as u64;
        if size > self.max_binding || (ptr as usize - start) % 4 != 0 {
            return None;
        }
        let ht = vk::ExternalMemoryHandleTypeFlags::HOST_ALLOCATION_EXT;
        let mut hp = vk::MemoryHostPointerPropertiesEXT::default();
        (hi.ext.fp().get_memory_host_pointer_properties_ext)(hi.ext.device(), ht, start as *const std::ffi::c_void, &mut hp).result().ok()?;
        let mut ebi = vk::ExternalMemoryBufferCreateInfo::default().handle_types(ht);
        let bci = vk::BufferCreateInfo::default()
            .size(size)
            .usage(vk::BufferUsageFlags::STORAGE_BUFFER | vk::BufferUsageFlags::TRANSFER_SRC | vk::BufferUsageFlags::TRANSFER_DST)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .push_next(&mut ebi);
        let b = hi.dev.create_buffer(&bci, None).ok()?;
        let req = hi.dev.get_buffer_memory_requirements(b);
        let bits = req.memory_type_bits & hp.memory_type_bits;
        if bits == 0 || req.size > size {
            hi.dev.destroy_buffer(b, None);
            return None;
        }
        let mut imp = vk::ImportMemoryHostPointerInfoEXT::default().handle_type(ht).host_pointer(start as *mut std::ffi::c_void);
        let mai = vk::MemoryAllocateInfo::default().allocation_size(size).memory_type_index(bits.trailing_zeros()).push_next(&mut imp);
        let mem = match hi.dev.allocate_memory(&mai, None) {
            Ok(m) => m,
            Err(_) => { hi.dev.destroy_buffer(b, None); return None; }
        };
        if hi.dev.bind_buffer_memory(b, mem, 0).is_err() {
            hi.dev.free_memory(mem, None);
            hi.dev.destroy_buffer(b, None);
            return None;
        }
        let hb = wgpu::hal::vulkan::Buffer::from_raw_managed(b, mem, 0, size);
        let buf = self.device.create_buffer_from_hal::<wgpu::hal::api::Vulkan>(hb, &wgpu::BufferDescriptor {
            label: None,
            size,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Some((buf, ((ptr as usize - start) / 4) as u32))
    }

    /// Storage buffer filled row by row from a (possibly strided) [T][H][W][3] view.
    fn upload_frames(&self, v: &ArrayView4<f32>) -> wgpu::Buffer {
        let (t, h, w, c) = v.dim();
        let buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: (t * h * w * c * 4) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: true,
        });
        {
            let mut map = buf.slice(..).get_mapped_range_mut().expect("map");
            let row_bytes = w * c * 4;
            let mut tmp: Vec<f32> = vec![];
            for i in 0..t * h {
                let src = v.slice(s![i / h, i % h, .., ..]);
                let sl = match src.as_slice() {
                    Some(sl) => sl,
                    None => { tmp.clear(); tmp.extend(src.iter()); &tmp[..] }
                };
                map.slice(i * row_bytes..(i + 1) * row_bytes).copy_from_slice(bytemuck::cast_slice(sl));
            }
        }
        buf.unmap();
        buf
    }
}

/// Bytes from the first to just past the last element of a [T][H][W][3] view whose strides are
/// all positive and whose channels are adjacent; None otherwise.
fn view_span(st: &[isize], d: (usize, usize, usize, usize)) -> Option<usize> {
    if st.iter().any(|&x| x <= 0) || st[3] != 1 || d.0 == 0 || d.1 == 0 || d.2 == 0 {
        return None;
    }
    let last = (d.0 - 1) * st[0] as usize + (d.1 - 1) * st[1] as usize + (d.2 - 1) * st[2] as usize + 3;
    Some(last * 4)
}

fn open_is_import(device: &wgpu::Device, ext_name: &std::ffi::CStr) -> bool {
    unsafe { device.as_hal::<wgpu::hal::api::Vulkan>() }
        .map(|hd| hd.enabled_device_extensions().contains(&ext_name))
        .unwrap_or(false)
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
/// A whole numpy array imported once and shared by all the tiles cut from it: the buffer, the
/// word offset of the array's first element in it, and that element's address.
pub struct Whole {
    buf: wgpu::Buffer,
    off: u32,
    ptr: usize,
}

impl Whole {
    /// The buffer and the word offset of the element at `p`, which must lie inside the array.
    fn at(&self, p: usize) -> (wgpu::Buffer, u32) {
        (self.buf.clone(), self.off + ((p - self.ptr) / 4) as u32)
    }
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    gpu: &Gpu, input: ArrayView4<f32>, out: &mut ArrayViewMut4<f32>, crop: (usize, usize, usize),
    in_whole: Option<&Whole>, out_whole: Option<&Whole>,
    fwd_tab: &[f32], fwd_lo: f32, fwd_step: f32, mat: &[f32], imat: &[f32],
    inv_tab: &[f32], inv_lo: [f32; 3], inv_step: [f32; 3],
    tr: usize, light_tr: usize, th_y: f32, th_c: f32, tex_lo: f32, tex_hi: f32,
    hp_sigma: f32, energy_sigma: f32, range: u32,
) {
    let (t_len, h, w, _) = input.dim();
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
    let prof = std::env::var_os("GIGDENOISE_PROFILE").is_some();
    let t_up = std::time::Instant::now();
    // Input: use the numpy memory in place if the driver allows, else copy it in.
    let in_import = match in_whole {
        Some(wh) => Some(wh.at(input.as_ptr() as usize)),
        None => view_span(input.strides(), input.dim()).and_then(|len| unsafe { gpu.import(input.as_ptr() as *const u8, len) }),
    };
    let b_in = match &in_import {
        Some((buf, off)) => {
            let st = input.strides();
            (base.in_off, base.in_st, base.in_sy, base.in_sx) = (*off, st[0] as u32, st[1] as u32, st[2] as u32);
            buf.clone()
        }
        None => {
            (base.in_off, base.in_st, base.in_sy, base.in_sx) = (0, hh * ww * 3, ww * 3, 3);
            gpu.upload_frames(&input)
        }
    };
    if prof { PROFILE.with(|m| *m.borrow_mut().entry("host_upload".into()).or_insert(0.0) += t_up.elapsed().as_secs_f64()); }
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
        let (wl, hl, ref lum32) = levels[l];
        let lum = &gpu.empty((((wl + 3) / 4) * hl * t) as usize);
        {
            let mut p = base;
            p.wl = wl; p.hl = hl;
            gpu.dispatch(&mut enc, "pack", &p, &[lum32, lum], groups((wl + 3) / 4), groups(hl), t);
        }
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
    // Output: the crop is written straight into `out`'s memory if the driver allows, else into a
    // compact buffer that is copied out.
    let (ot, oh, ow, _) = out.dim();
    (base.ct, base.cy, base.cx, base.ot, base.oh, base.ow) =
        (crop.0 as u32, crop.1 as u32, crop.2 as u32, ot as u32, oh as u32, ow as u32);
    let out_import = match out_whole {
        Some(wh) => Some(wh.at(out.as_mut_ptr() as usize)),
        None => view_span(out.strides(), out.dim()).and_then(|len| unsafe { gpu.import(out.as_mut_ptr() as *const u8, len) }),
    };
    let b_out = match &out_import {
        Some((buf, off)) => {
            let st = out.strides();
            (base.out_off, base.out_st, base.out_sy, base.out_sx) = (*off, st[0] as u32, st[1] as u32, st[2] as u32);
            buf.clone()
        }
        None => {
            (base.out_off, base.out_st, base.out_sy, base.out_sx) = (0, (oh * ow * 3) as u32, (ow * 3) as u32, 3);
            gpu.empty(ot * oh * ow * 3)
        }
    };
    base.pad1 = 0;
    gpu.dispatch(&mut enc, "final", &base, &[&b_strong, &b_light, &energy, &b_imat, &b_itab, &b_out], groups(ow as u32), groups(oh as u32), ot as u32);
    gpu.queue.submit([enc.finish()]);
    let t_rd = std::time::Instant::now();
    if out_import.is_some() {
        gpu.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
    } else {
        gpu.read_with(&b_out, ot * oh * ow * 3, |res| {
            for ti in 0..ot {
                for y in 0..oh {
                    let src = &res[(ti * oh + y) * ow * 3..(ti * oh + y + 1) * ow * 3];
                    let mut dst = out.slice_mut(s![ti, y, .., ..]);
                    match dst.as_slice_mut() {
                        Some(d) => d.copy_from_slice(src),
                        None => dst.iter_mut().zip(src).for_each(|(d, s)| *d = *s),
                    }
                }
            }
        });
    }
    if prof {
        PROFILE.with(|m| {
            let mut m = m.borrow_mut();
            *m.entry("imported_in".into()).or_insert(0.0) += in_import.is_some() as u8 as f64;
            *m.entry("imported_out".into()).or_insert(0.0) += out_import.is_some() as u8 as f64;
            *m.entry("calls".into()).or_insert(0.0) += 1.0;
        });
    }
    // Release imported memory now, while the numpy arrays are certainly still alive.
    if in_whole.is_none() { b_in.destroy(); }
    if out_whole.is_none() { b_out.destroy(); }
    if prof { PROFILE.with(|m| *m.borrow_mut().entry("host_read".into()).or_insert(0.0) += t_rd.elapsed().as_secs_f64()); }
}

thread_local! {
    static PROFILE: std::cell::RefCell<std::collections::BTreeMap<String, f64>> = const { std::cell::RefCell::new(std::collections::BTreeMap::new()) };
}

/// Per-stage GPU seconds since the last call (only collected with GIGDENOISE_PROFILE set).
#[pyfunction]
fn profile() -> std::collections::BTreeMap<String, f64> {
    PROFILE.with(|m| std::mem::take(&mut *m.borrow_mut()))
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

/// Largest storage buffer binding the device accepts, in bytes.
#[pyfunction]
fn max_binding() -> PyResult<u64> {
    GPU.with(|g| match g.get_or_init(Gpu::new) {
        Ok(gpu) => Ok(gpu.max_binding),
        Err(e) => Err(pyo3::exceptions::PyRuntimeError::new_err(e.clone())),
    })
}

/// Denoise `frames` ([T][H][W][3]) piece by piece into `out` (same shape). Each tile is
/// (S, E, Y0, Y1, X0, X1, s, e, y0, y1, x0, x1): frames[S:E, Y0:Y1, X0:X1] are denoised together
/// and the part out[s:e, y0:y1, x0:x1] is kept. Where the driver allows, frames and out are each
/// imported once as GPU buffers and used in place; otherwise each tile is copied in and out.
#[pyfunction]
#[allow(clippy::too_many_arguments)]
#[pyo3(signature = (frames, out, tiles, fwd_tables, fwd_lo, fwd_step, matrix, inv_matrix, inv_tables, inv_lo, inv_step,
                    tr=6, light_tr=2, th_y=2.39, th_c=3.58, tex_lo=0.3, tex_hi=1.0, hp_sigma=1.5,
                    energy_sigma=3.0, search_range=4))]
#[allow(non_snake_case)]
fn denoise_tiles<'py>(
    py: Python<'py>, frames: PyReadonlyArray4<'py, f32>, mut out: PyReadwriteArray4<'py, f32>, tiles: Vec<[usize; 12]>,
    fwd_tables: PyReadonlyArray2<'py, f32>,
    fwd_lo: f32, fwd_step: f32, matrix: PyReadonlyArray2<'py, f32>, inv_matrix: PyReadonlyArray2<'py, f32>,
    inv_tables: PyReadonlyArray2<'py, f32>, inv_lo: PyReadonlyArray1<'py, f32>, inv_step: PyReadonlyArray1<'py, f32>,
    tr: usize, light_tr: usize, th_y: f32, th_c: f32, tex_lo: f32, tex_hi: f32, hp_sigma: f32,
    energy_sigma: f32, search_range: u32,
) -> PyResult<()> {
    let _ = py;
    let fr = frames.as_array();
    let mut ov = out.as_array_mut();
    let (t_len, h, w, c) = fr.dim();
    if c != 3 || ov.dim() != fr.dim() {
        return Err(pyo3::exceptions::PyValueError::new_err("frames and out must both be [T][H][W][3]"));
    }
    for k in &tiles {
        let [S, E, Y0, Y1, X0, X1, s0, e0, y0, y1, x0, x1] = *k;
        if !(S <= s0 && s0 < e0 && e0 <= E && E <= t_len && Y0 <= y0 && y0 < y1 && y1 <= Y1 && Y1 <= h
            && X0 <= x0 && x0 < x1 && x1 <= X1 && X1 <= w) {
            return Err(pyo3::exceptions::PyValueError::new_err("each tile's kept part must lie inside its input part, inside frames"));
        }
    }
    let ft: Vec<f32> = fwd_tables.as_array().iter().cloned().collect();
    let m: Vec<f32> = matrix.as_array().iter().cloned().collect();
    let mi: Vec<f32> = inv_matrix.as_array().iter().cloned().collect();
    let it: Vec<f32> = inv_tables.as_array().iter().cloned().collect();
    let il = inv_lo.as_array();
    let is = inv_step.as_array();
    let (il, is) = ([il[0], il[1], il[2]], [is[0], is[1], is[2]]);
    GPU.with(|g| -> Result<(), String> {
        let gpu = g.get_or_init(Gpu::new).as_ref().map_err(|e| e.clone())?;
        let prof = std::env::var_os("GIGDENOISE_PROFILE").is_some();
        let t0 = std::time::Instant::now();
        let whole = |p: usize, st: &[isize]| -> Option<Whole> {
            let len = view_span(st, (t_len, h, w, 3))?;
            let (buf, off) = unsafe { gpu.import(p as *const u8, len)? };
            Some(Whole { buf, off, ptr: p })
        };
        let in_whole = whole(fr.as_ptr() as usize, fr.strides());
        let out_whole = whole(ov.as_mut_ptr() as usize, ov.strides());
        if prof { PROFILE.with(|m| *m.borrow_mut().entry("host_import".into()).or_insert(0.0) += t0.elapsed().as_secs_f64()); }
        for k in &tiles {
            let [S, E, Y0, Y1, X0, X1, s0, e0, y0, y1, x0, x1] = *k;
            let mut o = ov.slice_mut(s![s0..e0, y0..y1, x0..x1, ..]);
            run(gpu, fr.slice(s![S..E, Y0..Y1, X0..X1, ..]), &mut o, (s0 - S, y0 - Y0, x0 - X0),
                in_whole.as_ref(), out_whole.as_ref(), &ft, fwd_lo, fwd_step, &m, &mi, &it, il, is, tr, light_tr,
                th_y, th_c, tex_lo, tex_hi, hp_sigma, energy_sigma, search_range);
        }
        // Release the imported memory before returning, while frames and out are still alive.
        let t1 = std::time::Instant::now();
        for wh in [in_whole, out_whole].into_iter().flatten() {
            wh.buf.destroy();
        }
        gpu.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
        if prof { PROFILE.with(|m| *m.borrow_mut().entry("host_release".into()).or_insert(0.0) += t1.elapsed().as_secs_f64()); }
        Ok(())
    })
    .map_err(pyo3::exceptions::PyRuntimeError::new_err)
}

#[pymodule]
fn gigdenoise_gpu(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(denoise_tiles, m)?)?;
    m.add_function(wrap_pyfunction!(adapter, m)?)?;
    m.add_function(wrap_pyfunction!(max_binding, m)?)?;
    m.add_function(wrap_pyfunction!(profile, m)?)?;
    Ok(())
}
