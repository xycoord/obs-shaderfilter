/* libobs set-up for the UI capture tool (kept in C, away from Qt, because the
 * X11 headers' macros clash with Qt's). */
#include <X11/Xlib.h>
#include <obs-module.h>
#include <obs-nix-platform.h>
#include <obs.h>
#include <stdio.h>
#include <string.h>
#include <util/dstr.h>

#include "obsenv.h"

extern void obs_source_video_tick(obs_source_t *source, float seconds);

static bool load_module(const char *bin, const char *data)
{
	obs_module_t *m = NULL;
	if (obs_open_module(&m, bin, data) != MODULE_SUCCESS || !obs_init_module(m)) {
		fprintf(stderr, "cannot load %s\n", bin);
		return false;
	}
	return true;
}

static void log_handler(int lvl, const char *msg, va_list args, void *p)
{
	(void)p;
	if (lvl > LOG_WARNING)
		return;
	vfprintf(stderr, msg, args);
	fputc('\n', stderr);
}

bool env_start(const char *obs_prefix, const char *plugin, const char *data, uint32_t w, uint32_t h)
{
	base_set_log_handler(log_handler, NULL);
	Display *dpy = XOpenDisplay(NULL);
	if (!dpy) {
		fprintf(stderr, "no X display\n");
		return false;
	}
	obs_set_nix_platform(OBS_NIX_PLATFORM_X11_EGL);
	obs_set_nix_platform_display(dpy);
	if (!obs_startup("en-US", NULL, NULL))
		return false;
	struct obs_video_info ovi = {0};
	ovi.graphics_module = "libobs-opengl";
	ovi.fps_num = 1;
	ovi.fps_den = 3600;
	ovi.base_width = ovi.output_width = w;
	ovi.base_height = ovi.output_height = h;
	ovi.output_format = VIDEO_FORMAT_RGBA;
	ovi.colorspace = VIDEO_CS_709;
	ovi.range = VIDEO_RANGE_FULL;
	ovi.gpu_conversion = true;
	ovi.scale_type = OBS_SCALE_BILINEAR;
	if (obs_reset_video(&ovi) != OBS_VIDEO_SUCCESS)
		return false;
	struct dstr bin = {0}, dat = {0};
	dstr_printf(&bin, "%s/lib/obs-modules/core/image-source.so", obs_prefix);
	dstr_printf(&dat, "%s/share/obs/obs-modules/core/image-source", obs_prefix);
	bool ok = load_module(bin.array, dat.array) && load_module(plugin, data);
	dstr_free(&bin);
	dstr_free(&dat);
	obs_post_load_modules();
	return ok;
}

static bool tick_one(void *param, obs_source_t *source)
{
	obs_source_video_tick(source, *(float *)param);
	return true;
}

void env_tick(float dt)
{
	obs_enum_all_sources(tick_one, &dt);
}

bool env_render(obs_source_t *source, uint8_t **rgba, uint32_t *w, uint32_t *h)
{
	*w = obs_source_get_width(source);
	*h = obs_source_get_height(source);
	if (!*w || !*h)
		return false;
	bool ok = false;
	obs_enter_graphics();
	gs_texrender_t *tr = gs_texrender_create(GS_RGBA, GS_ZS_NONE);
	gs_stagesurf_t *st = gs_stagesurface_create(*w, *h, GS_RGBA);
	if (gs_texrender_begin_with_color_space(tr, *w, *h, GS_CS_SRGB)) {
		struct vec4 clear;
		vec4_zero(&clear);
		gs_clear(GS_CLEAR_COLOR, &clear, 1.0f, 0);
		gs_ortho(0.0f, (float)*w, 0.0f, (float)*h, -100.0f, 100.0f);
		gs_blend_state_push();
		gs_reset_blend_state();
		obs_source_video_render(source);
		gs_blend_state_pop();
		gs_texrender_end(tr);
		gs_stage_texture(st, gs_texrender_get_texture(tr));
		uint8_t *data;
		uint32_t ls;
		if (gs_stagesurface_map(st, &data, &ls)) {
			*rgba = bmalloc((size_t)*w * *h * 4);
			for (uint32_t y = 0; y < *h; y++)
				memcpy(*rgba + (size_t)y * *w * 4, data + (size_t)y * ls, (size_t)*w * 4);
			gs_stagesurface_unmap(st);
			ok = true;
		}
	}
	gs_stagesurface_destroy(st);
	gs_texrender_destroy(tr);
	obs_leave_graphics();
	return ok;
}
