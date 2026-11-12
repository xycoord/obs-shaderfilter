/*
 * Headless OBS harness for obs-shaderfilter.
 *
 * Boots libobs with the OpenGL renderer on an X display (Xvfb + Mesa llvmpipe
 * in CI), loads one build of the plugin, builds scenes described by a JSON
 * spec, drives ticks with fixed time steps and either
 *   - captures frames to PNG (parity mode), or
 *   - times frames (bench mode).
 *
 *   harness --plugin path/to/obs-shaderfilter.so --data path/to/data \
 *           --spec spec.json --out outdir [--bench]
 *
 * Spec (JSON):
 * {
 *   "width": 640, "height": 360,
 *   "images": { "main": "test.png", "alt": "test2.png" },   image sources
 *   "cases": [
 *     { "name": "invert",
 *       "source": "main",                                    filter target
 *       "filters": [ { "id": "shader_filter", "settings": { ... } } ],
 *       "steps": [ { "dt": 0.1, "capture": true }, ... ] },
 *     { "name": "fade",
 *       "transition": { "id": "shader_transition", "settings": { ... },
 *                       "from": "main", "to": "alt" },
 *       "steps": [ { "dt": 0.1, "t": 0.25, "capture": true } ] }
 *   ],
 *   "bench": { "frames": 300, "warmup": 30, "dt": 0.016666 }   optional
 * }
 *
 * Each case writes <out>/<name>_<step>.png and appends a line to
 * <out>/results.jsonl with per-case information (errors, timings).
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <dlfcn.h>
#include <obs-module.h>
#include <obs-nix-platform.h>
#include <obs.h>
#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <util/darray.h>
#include <util/dstr.h>
#include <util/platform.h>

/* Exported only by the test build of libobs (tests/setup/build-libobs.sh). */
extern void obs_source_video_tick(obs_source_t *source, float seconds);

static void (*freeze_ns)(uint64_t) = NULL;
static void (*gl_counts)(uint64_t *, uint64_t *) = NULL;
static uint64_t sim_ns = 1000000000ULL * 1000;
static uint32_t canvas_w = 640, canvas_h = 360;
static FILE *results;
static const char *out_dir;
static bool quiet_logs = true;

static void log_handler(int lvl, const char *msg, va_list args, void *p)
{
	(void)p;
	if (quiet_logs && lvl > LOG_WARNING)
		return;
	vfprintf(stderr, msg, args);
	fputc('\n', stderr);
}

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static bool tick_one(void *param, obs_source_t *source)
{
	float dt = *(float *)param;
	obs_source_video_tick(source, dt);
	return true;
}

static void tick_all(float dt)
{
	sim_ns += (uint64_t)(dt * 1e9);
	if (freeze_ns)
		freeze_ns(sim_ns);
	obs_enum_all_sources(tick_one, &dt);
}

static gs_texrender_t *main_tr;
static gs_stagesurf_t *stage;
static gs_texrender_t *sync_tr;
static gs_stagesurf_t *sync_stage;

/* Render like libobs' render_main_texture(): sRGB GS_RGBA target. */
static void render_root(obs_source_t *root)
{
	gs_texrender_reset(main_tr);
	if (gs_texrender_begin_with_color_space(main_tr, canvas_w, canvas_h, GS_CS_SRGB)) {
		struct vec4 clear;
		vec4_zero(&clear);
		gs_clear(GS_CLEAR_COLOR, &clear, 1.0f, 0);
		gs_enable_depth_test(false);
		gs_set_cull_mode(GS_NEITHER);
		gs_ortho(0.0f, (float)canvas_w, 0.0f, (float)canvas_h, -100.0f, 100.0f);
		gs_set_viewport(0, 0, canvas_w, canvas_h);
		gs_blend_state_push();
		gs_reset_blend_state();
		obs_source_video_render(root);
		gs_blend_state_pop();
		gs_texrender_end(main_tr);
	}
}

/* Force the GPU to finish by reading back a 1x1 downscale of the frame. */
static void sync_gpu(void)
{
	gs_texrender_reset(sync_tr);
	if (gs_texrender_begin(sync_tr, 1, 1)) {
		gs_ortho(0.0f, 1.0f, 0.0f, 1.0f, -100.0f, 100.0f);
		gs_effect_t *e = obs_get_base_effect(OBS_EFFECT_DEFAULT);
		gs_effect_set_texture(gs_effect_get_param_by_name(e, "image"), gs_texrender_get_texture(main_tr));
		while (gs_effect_loop(e, "Draw"))
			gs_draw_sprite(gs_texrender_get_texture(main_tr), 0, 1, 1);
		gs_texrender_end(sync_tr);
	}
	gs_stage_texture(sync_stage, gs_texrender_get_texture(sync_tr));
	uint8_t *data;
	uint32_t ls;
	if (gs_stagesurface_map(sync_stage, &data, &ls))
		gs_stagesurface_unmap(sync_stage);
}

static bool write_png(const char *path, const uint8_t *data, uint32_t linesize)
{
	png_image img;
	memset(&img, 0, sizeof(img));
	img.version = PNG_IMAGE_VERSION;
	img.width = canvas_w;
	img.height = canvas_h;
	img.format = PNG_FORMAT_RGBA;
	return png_image_write_to_file(&img, path, 0, data, (png_int_32)linesize, NULL) != 0;
}

static void capture(const char *name, int step)
{
	gs_stage_texture(stage, gs_texrender_get_texture(main_tr));
	uint8_t *data;
	uint32_t ls;
	if (gs_stagesurface_map(stage, &data, &ls)) {
		struct dstr path = {0};
		dstr_printf(&path, "%s/%s_%d.png", out_dir, name, step);
		if (!write_png(path.array, data, ls))
			fprintf(stderr, "failed to write %s\n", path.array);
		dstr_free(&path);
		gs_stagesurface_unmap(stage);
	}
}

static obs_source_t *create_image(const char *name, const char *file)
{
	obs_data_t *s = obs_data_create();
	obs_data_set_string(s, "file", file);
	obs_source_t *src = obs_source_create("image_source", name, s, NULL);
	obs_data_release(s);
	return src;
}

static void json_escape(struct dstr *out, const char *s)
{
	for (; s && *s; s++) {
		if (*s == '"' || *s == '\\') {
			dstr_cat_ch(out, '\\');
			dstr_cat_ch(out, *s);
		} else if (*s == '\n') {
			dstr_cat(out, "\\n");
		} else if ((unsigned char)*s < 0x20) {
			continue;
		} else {
			dstr_cat_ch(out, *s);
		}
	}
}

static void append_error(struct dstr *errors, obs_source_t *source)
{
	obs_data_t *rs = obs_source_get_settings(source);
	const char *err = obs_data_get_string(rs, "last_error");
	if (err && *err) {
		if (errors->len)
			dstr_cat(errors, " | ");
		json_escape(errors, err);
	}
	obs_data_release(rs);
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static void run_case(obs_data_t *c, obs_data_t *bench)
{
	const char *name = obs_data_get_string(c, "name");
	obs_data_t *trans_spec = obs_data_get_obj(c, "transition");
	obs_scene_t *scene = obs_scene_create_private("harness_scene");
	obs_source_t *scene_src = obs_scene_get_source(scene);
	obs_source_t *root = NULL;
	obs_source_t *target = NULL;
	DARRAY(obs_source_t *) filters;
	da_init(filters);
	struct dstr errors = {0};

	if (trans_spec) {
		obs_data_t *ts = obs_data_get_obj(trans_spec, "settings");
		root = obs_source_create_private(obs_data_get_string(trans_spec, "id"), "harness_transition", ts);
		obs_data_release(ts);
		obs_source_t *from = obs_get_source_by_name(obs_data_get_string(trans_spec, "from"));
		obs_source_t *to = obs_get_source_by_name(obs_data_get_string(trans_spec, "to"));
		obs_transition_set_size(root, canvas_w, canvas_h);
		obs_transition_set_alignment(root, OBS_ALIGN_CENTER);
		obs_transition_set_scale_type(root, OBS_TRANSITION_SCALE_ASPECT);
		obs_transition_set(root, from);
		obs_transition_set_manual_torque(root, 0.0f, 0.0f);
		if (!obs_transition_start(root, OBS_TRANSITION_MODE_MANUAL, 0, to))
			fprintf(stderr, "obs_transition_start failed for %s\n", name);
		obs_source_release(from);
		obs_source_release(to);
	} else {
		target = obs_get_source_by_name(obs_data_get_string(c, "source"));
		obs_data_array_t *fa = obs_data_get_array(c, "filters");
		size_t n = obs_data_array_count(fa);
		for (size_t i = 0; i < n; i++) {
			obs_data_t *f = obs_data_array_item(fa, i);
			obs_data_t *fs = obs_data_get_obj(f, "settings");
			struct dstr fname = {0};
			dstr_printf(&fname, "%s_f%zu", name, i);
			obs_source_t *filter = obs_source_create(obs_data_get_string(f, "id"), fname.array, fs, NULL);
			dstr_free(&fname);
			obs_source_filter_add(target, filter);
			if (obs_data_has_user_value(f, "enabled") && !obs_data_get_bool(f, "enabled"))
				obs_source_set_enabled(filter, false);
			da_push_back(filters, &filter);
			obs_data_release(fs);
			obs_data_release(f);
		}
		obs_data_array_release(fa);
		obs_scene_add(scene, target);
		if (obs_data_get_bool(c, "duplicate_item")) {
			/* The same source shown twice: its filters render twice per frame. */
			obs_sceneitem_t *item = obs_scene_add(scene, target);
			struct vec2 pos = {(float)canvas_w / 3.0f, (float)canvas_h / 4.0f};
			struct vec2 scale = {0.5f, 0.5f};
			obs_sceneitem_set_pos(item, &pos);
			obs_sceneitem_set_scale(item, &scale);
		}
		root = obs_source_get_ref(scene_src);
	}

	obs_set_output_source(0, root);

	obs_data_array_t *steps = obs_data_get_array(c, "steps");
	size_t nsteps = obs_data_array_count(steps);
	for (size_t i = 0; i < nsteps; i++) {
		obs_data_t *st = obs_data_array_item(steps, i);
		if (trans_spec && obs_data_has_user_value(st, "t"))
			obs_transition_set_manual_time(root, (float)obs_data_get_double(st, "t"));
		tick_all((float)obs_data_get_double(st, "dt"));
		obs_enter_graphics();
		render_root(root);
		if (obs_data_get_bool(st, "capture"))
			capture(name, (int)i);
		obs_leave_graphics();
		obs_data_release(st);
	}
	obs_data_array_release(steps);

	/* Updates (and so shader compilation) are deferred to the first tick, so
	 * errors can only be read after the steps have run. */
	if (trans_spec) {
		append_error(&errors, root);
	} else {
		for (size_t i = 0; i < filters.num; i++)
			append_error(&errors, filters.array[i]);
	}

	struct dstr timing = {0};
	if (bench) {
		int frames = (int)obs_data_get_int(bench, "frames");
		int warmup = (int)obs_data_get_int(bench, "warmup");
		float dt = (float)obs_data_get_double(bench, "dt");
		double *times = bzalloc(sizeof(double) * frames);
		uint64_t draws0 = 0, px0 = 0, draws1 = 0, px1 = 0;
		for (int i = -warmup; i < frames; i++) {
			if (i == 0 && gl_counts)
				gl_counts(&draws0, &px0);
			double t0 = now_ms();
			tick_all(dt);
			obs_enter_graphics();
			render_root(root);
			sync_gpu();
			obs_leave_graphics();
			if (i >= 0)
				times[i] = now_ms() - t0;
		}
		if (gl_counts)
			gl_counts(&draws1, &px1);
		qsort(times, frames, sizeof(double), cmp_double);
		double sum = 0;
		for (int i = 0; i < frames; i++)
			sum += times[i];
		dstr_printf(&timing, ", \"median_ms\": %.4f, \"mean_ms\": %.4f, \"p10_ms\": %.4f, \"p90_ms\": %.4f",
			    times[frames / 2], sum / frames, times[frames / 10], times[frames * 9 / 10]);
		if (draws1 > draws0)
			dstr_catf(&timing, ", \"draws_per_frame\": %.2f, \"mpix_per_frame\": %.3f",
				  (double)(draws1 - draws0) / frames, (double)(px1 - px0) / frames / 1e6);
		bfree(times);
	}

	fprintf(results, "{\"name\": \"%s\", \"error\": \"%s\"%s}\n", name, errors.array ? errors.array : "",
		timing.array ? timing.array : "");
	fflush(results);
	dstr_free(&errors);
	dstr_free(&timing);

	obs_set_output_source(0, NULL);
	if (target) {
		for (size_t i = 0; i < filters.num; i++) {
			obs_source_filter_remove(target, filters.array[i]);
			obs_source_release(filters.array[i]);
		}
		obs_sceneitem_t *item;
		while ((item = obs_scene_find_source(scene, obs_source_get_name(target))) != NULL)
			obs_sceneitem_remove(item);
		obs_source_release(target);
	} else {
		obs_transition_clear(root);
	}
	da_free(filters);
	obs_source_release(root);
	obs_scene_release(scene);
	obs_data_release(trans_spec);
}

static bool load_module(const char *bin, const char *data)
{
	obs_module_t *m = NULL;
	int r = obs_open_module(&m, bin, data);
	if (r != MODULE_SUCCESS) {
		fprintf(stderr, "failed to open module %s (%d)\n", bin, r);
		return false;
	}
	if (!obs_init_module(m)) {
		fprintf(stderr, "failed to init module %s\n", bin);
		return false;
	}
	return true;
}

int main(int argc, char **argv)
{
	const char *plugin = NULL, *data = NULL, *spec_path = NULL, *obs_prefix = NULL;
	bool bench_mode = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--plugin") && i + 1 < argc)
			plugin = argv[++i];
		else if (!strcmp(argv[i], "--data") && i + 1 < argc)
			data = argv[++i];
		else if (!strcmp(argv[i], "--spec") && i + 1 < argc)
			spec_path = argv[++i];
		else if (!strcmp(argv[i], "--out") && i + 1 < argc)
			out_dir = argv[++i];
		else if (!strcmp(argv[i], "--obs-prefix") && i + 1 < argc)
			obs_prefix = argv[++i];
		else if (!strcmp(argv[i], "--bench"))
			bench_mode = true;
		else if (!strcmp(argv[i], "--verbose"))
			quiet_logs = false;
	}
	if (!plugin || !data || !spec_path || !out_dir || !obs_prefix) {
		fprintf(stderr, "usage: harness --obs-prefix DIR --plugin SO --data DIR --spec JSON --out DIR [--bench]\n");
		return 2;
	}
	freeze_ns = (void (*)(uint64_t))dlsym(RTLD_DEFAULT, "detshim_freeze_ns");
	gl_counts = (void (*)(uint64_t *, uint64_t *))dlsym(RTLD_DEFAULT, "detshim_gl_counts");
	base_set_log_handler(log_handler, NULL);
	os_mkdirs(out_dir);

	obs_data_t *spec = obs_data_create_from_json_file(spec_path);
	if (!spec) {
		fprintf(stderr, "cannot read spec %s\n", spec_path);
		return 2;
	}
	if (obs_data_has_user_value(spec, "width"))
		canvas_w = (uint32_t)obs_data_get_int(spec, "width");
	if (obs_data_has_user_value(spec, "height"))
		canvas_h = (uint32_t)obs_data_get_int(spec, "height");

	Display *dpy = XOpenDisplay(NULL);
	if (!dpy) {
		fprintf(stderr, "no X display\n");
		return 1;
	}
	obs_set_nix_platform(OBS_NIX_PLATFORM_X11_EGL);
	obs_set_nix_platform_display(dpy);
	if (!obs_startup("en-US", NULL, NULL))
		return 1;

	struct obs_video_info ovi = {0};
	ovi.graphics_module = "libobs-opengl";
	ovi.fps_num = 1;
	ovi.fps_den = 3600; /* graphics thread wakes once an hour; we drive frames ourselves */
	ovi.base_width = canvas_w;
	ovi.base_height = canvas_h;
	ovi.output_width = canvas_w;
	ovi.output_height = canvas_h;
	ovi.output_format = VIDEO_FORMAT_RGBA;
	ovi.colorspace = VIDEO_CS_709;
	ovi.range = VIDEO_RANGE_FULL;
	ovi.gpu_conversion = true;
	ovi.scale_type = OBS_SCALE_BILINEAR;
	int vr = obs_reset_video(&ovi);
	if (vr != OBS_VIDEO_SUCCESS) {
		fprintf(stderr, "obs_reset_video failed: %d\n", vr);
		return 1;
	}

	struct dstr img_bin = {0}, img_data = {0};
	dstr_printf(&img_bin, "%s/lib/obs-modules/core/image-source.so", obs_prefix);
	dstr_printf(&img_data, "%s/share/obs/obs-modules/core/image-source", obs_prefix);
	if (!load_module(img_bin.array, img_data.array))
		return 1;
	dstr_free(&img_bin);
	dstr_free(&img_data);
	if (!load_module(plugin, data))
		return 1;
	obs_post_load_modules();

	obs_data_t *images = obs_data_get_obj(spec, "images");
	DARRAY(obs_source_t *) image_sources;
	da_init(image_sources);
	for (obs_data_item_t *it = obs_data_first(images); it; obs_data_item_next(&it)) {
		obs_source_t *src = create_image(obs_data_item_get_name(it), obs_data_item_get_string(it));
		da_push_back(image_sources, &src);
	}
	obs_data_release(images);

	/* Let image sources load their textures. */
	tick_all(0.0f);

	obs_enter_graphics();
	main_tr = gs_texrender_create(GS_RGBA, GS_ZS_NONE);
	stage = gs_stagesurface_create(canvas_w, canvas_h, GS_RGBA);
	sync_tr = gs_texrender_create(GS_RGBA, GS_ZS_NONE);
	sync_stage = gs_stagesurface_create(1, 1, GS_RGBA);
	obs_leave_graphics();

	struct dstr rpath = {0};
	dstr_printf(&rpath, "%s/results.jsonl", out_dir);
	results = fopen(rpath.array, "w");
	dstr_free(&rpath);

	obs_data_t *bench = bench_mode ? obs_data_get_obj(spec, "bench") : NULL;
	obs_data_array_t *cases = obs_data_get_array(spec, "cases");
	size_t ncases = obs_data_array_count(cases);
	for (size_t i = 0; i < ncases; i++) {
		obs_data_t *c = obs_data_array_item(cases, i);
		run_case(c, bench);
		obs_data_release(c);
	}
	obs_data_array_release(cases);
	obs_data_release(bench);
	fclose(results);

	obs_enter_graphics();
	gs_texrender_destroy(main_tr);
	gs_stagesurface_destroy(stage);
	gs_texrender_destroy(sync_tr);
	gs_stagesurface_destroy(sync_stage);
	obs_leave_graphics();
	for (size_t i = 0; i < image_sources.num; i++) {
		obs_source_remove(image_sources.array[i]);
		obs_source_release(image_sources.array[i]);
	}
	da_free(image_sources);
	obs_data_release(spec);
	/* obs_shutdown() can hang with a sleeping graphics thread; exit directly. */
	fflush(stdout);
	fflush(stderr);
	_exit(0);
}
