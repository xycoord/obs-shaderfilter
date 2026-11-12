// Version 2.0 by Exeldro https://github.com/exeldro/obs-shaderfilter
// Version 1.21 by Charles Fettinger https://github.com/Oncorporation/obs-shaderfilter
// original version by nleseul https://github.com/nleseul/obs-shaderfilter
#include "version.h"
#include "shader-fusion.h"
#include <float.h>
#include <graphics/graphics.h>
#include <graphics/image-file.h>
#include <graphics/math-extra.h>
#include <limits.h>
#include <math.h>
#include <obs-module.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <util/base.h>
#include <util/darray.h>
#include <util/dstr.h>
#include <util/platform.h>
#include <util/threading.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#include <sys/time.h>
#endif

float (*move_get_transition_filter)(obs_source_t *filter_from, obs_source_t **filter_to) = NULL;

struct image_file {
	gs_texture_t *texture;
	enum gs_color_format format;
	uint32_t cx;
	uint32_t cy;
	bool is_animated_gif;
	bool frame_updated;
	bool loaded;
};

void *(*gs_image_file_create_func)() = NULL;
void (*gs_image_file_free_func)(struct image_file *image) = NULL;
void (*gs_image_file_init_func)(struct image_file *image, const char *file, enum gs_image_alpha_mode alpha_mode) = NULL;
void (*gs_image_file_init_texture_func)(struct image_file *image) = NULL;
bool (*gs_image_file_tick_func)(struct image_file *image, uint64_t elapsed_time_ns) = NULL;
void (*gs_image_file_update_texture_func)(struct image_file *image) = NULL;

void *gs_image_file4_create()
{
	return bzalloc(41336); //sizeof(gs_image_file4_t)
}

void *gs_image_file_ex_create()
{
	return bzalloc(72); //sizeof(gs_image_file_ex_t));
}

#define nullptr ((void *)0)

static const char *effect_template_begin = "\
uniform float4x4 ViewProj;\n\
uniform texture2d image;\n\
\n\
uniform float2 uv_offset;\n\
uniform float2 uv_scale;\n\
uniform float2 uv_pixel_interval;\n\
uniform float2 uv_size;\n\
uniform float rand_f;\n\
uniform float rand_instance_f;\n\
uniform float rand_activation_f;\n\
uniform float elapsed_time;\n\
uniform float elapsed_time_start;\n\
uniform float elapsed_time_show;\n\
uniform float elapsed_time_active;\n\
uniform float elapsed_time_enable;\n\
uniform int loops;\n\
uniform float loop_second;\n\
uniform float local_time;\n\
\n\
sampler_state textureSampler{\n\
	Filter = Linear;\n\
	AddressU = Border;\n\
	AddressV = Border;\n\
	BorderColor = 00000000;\n\
};\n\
\n\
struct VertData {\n\
	float4 pos : POSITION;\n\
	float2 uv : TEXCOORD0;\n\
};\n\
\n\
VertData mainTransform(VertData v_in)\n\
{\n\
	VertData vert_out;\n\
	vert_out.pos = mul(float4(v_in.pos.xyz, 1.0), ViewProj);\n\
	vert_out.uv = v_in.uv * uv_scale + uv_offset;\n\
	return vert_out;\n\
}\n\
\n\
float srgb_nonlinear_to_linear_channel(float u)\n\
{\n\
	return (u <= 0.04045) ? (u / 12.92) : pow((u + 0.055) / 1.055, 2.4);\n\
}\n\
\n\
float3 srgb_nonlinear_to_linear(float3 v)\n\
{\n\
	return float3(srgb_nonlinear_to_linear_channel(v.r),\n\
		      srgb_nonlinear_to_linear_channel(v.g),\n\
		      srgb_nonlinear_to_linear_channel(v.b));\n\
}\n\
\n";

static const char *effect_template_default_image_shader = "\n\
float4 mainImage(VertData v_in) : TARGET\n\
{\n\
	return image.Sample(textureSampler, v_in.uv);\n\
}\n\
";

static const char *effect_template_default_transition_image_shader = "\n\
uniform texture2d image_a;\n\
uniform texture2d image_b;\n\
uniform float transition_time = 0.5;\n\
uniform bool convert_linear = true;\n\
\n\
float4 mainImage(VertData v_in) : TARGET\n\
{\n\
	float4 a_val = image_a.Sample(textureSampler, v_in.uv);\n\
	float4 b_val = image_b.Sample(textureSampler, v_in.uv);\n\
	float4 rgba = lerp(a_val, b_val, transition_time);\n\
	if (convert_linear)\n\
		rgba.rgb = srgb_nonlinear_to_linear(rgba.rgb);\n\
	return rgba;\n\
}\n\
";

static const char *effect_template_end = "\n\
technique Draw\n\
{\n\
	pass\n\
	{\n\
		vertex_shader = mainTransform(v_in);\n\
		pixel_shader = mainImage(v_in);\n\
	}\n\
}\n";

/* The end of *derived* effects (see "Linked rendering" below), which are built
 * separately from a filter's own effect, so a filter's own effect is exactly
 * what it always was and anything generated here can only fail the
 * optimisation, never the filter.
 *
 * "DrawLinked" is used when this filter's output is handed straight to the next
 * shader filter on the same source instead of going through libobs. It
 * reproduces, in this pass, what the boundary between two filters does to the
 * pixels: the output is stored in 8 bits, linearised and premultiplied by
 * render_output.effect into an 8-bit sRGB texture, then un-premultiplied by
 * DrawAlphaDivide into another 8-bit sRGB texture. Notably, colour is zeroed
 * where alpha is zero, and translucent colour is quantised in premultiplied
 * form. Opaque pixels round-trip unchanged, so they skip the arithmetic.
 * "DrawPremul" stops half way, producing what libobs' texture would hold
 * (premultiplied in linear light, sRGB-encoded), for a downstream filter that
 * still makes its own input copy (expansion, previous_image, USE_PM_ALPHA).
 * Locals are prefixed so a user's object-like macro can't capture them. */
static const char *effect_template_end_derived = "\n\
float _sf_q8(float _sf_x)\n\
{\n\
	float _sf_v = saturate(_sf_x) * 255.0 + 0.5;\n\
	return (_sf_v - frac(_sf_v)) / 255.0;\n\
}\n\
\n\
float _sf_enc(float _sf_l)\n\
{\n\
	return (_sf_l <= 0.0031308) ? (12.92 * _sf_l) : (1.055 * pow(_sf_l, 1.0 / 2.4) - 0.055);\n\
}\n\
\n\
float4 _sf_boundary(float4 _sf_r)\n\
{\n\
	float _sf_a = _sf_q8(_sf_r.a);\n\
	if (_sf_a <= 0.0)\n\
		return float4(0.0, 0.0, 0.0, 0.0);\n\
	float3 _sf_c = float3(_sf_q8(_sf_r.r), _sf_q8(_sf_r.g), _sf_q8(_sf_r.b));\n\
	if (_sf_a >= 1.0)\n\
		return float4(_sf_c, 1.0);\n\
	float3 _sf_pm = srgb_nonlinear_to_linear(_sf_c) * _sf_a;\n\
	float3 _sf_s = float3(_sf_q8(_sf_enc(_sf_pm.r)), _sf_q8(_sf_enc(_sf_pm.g)), _sf_q8(_sf_enc(_sf_pm.b)));\n\
	float3 _sf_lin = srgb_nonlinear_to_linear(_sf_s) / _sf_a;\n\
	return float4(_sf_enc(_sf_lin.r), _sf_enc(_sf_lin.g), _sf_enc(_sf_lin.b), _sf_a);\n\
}\n\
\n\
float4 _sf_linked(VertData v_in) : TARGET\n\
{\n\
	return _sf_boundary(mainImage(v_in));\n\
}\n\
\n\
float4 _sf_premul(VertData v_in) : TARGET\n\
{\n\
	float4 _sf_r = mainImage(v_in);\n\
	float _sf_a = _sf_q8(_sf_r.a);\n\
	float3 _sf_c = float3(_sf_q8(_sf_r.r), _sf_q8(_sf_r.g), _sf_q8(_sf_r.b));\n\
	if (_sf_a >= 1.0)\n\
		return float4(_sf_c, 1.0);\n\
	float3 _sf_pm = srgb_nonlinear_to_linear(_sf_c) * _sf_a;\n\
	return float4(_sf_enc(_sf_pm.r), _sf_enc(_sf_pm.g), _sf_enc(_sf_pm.b), _sf_a);\n\
}\n\
\n\
technique Draw\n\
{\n\
	pass\n\
	{\n\
		vertex_shader = mainTransform(v_in);\n\
		pixel_shader = mainImage(v_in);\n\
	}\n\
}\n\
\n\
technique DrawLinked\n\
{\n\
	pass\n\
	{\n\
		vertex_shader = mainTransform(v_in);\n\
		pixel_shader = _sf_linked(v_in);\n\
	}\n\
}\n\
\n\
technique DrawPremul\n\
{\n\
	pass\n\
	{\n\
		vertex_shader = mainTransform(v_in);\n\
		pixel_shader = _sf_premul(v_in);\n\
	}\n\
}\n";

struct effect_param_data {
	struct dstr name;
	struct dstr display_name;
	struct dstr widget_type;
	struct dstr group;
	struct dstr path;
	struct dstr tooltip;
	DARRAY(int) option_values;
	DARRAY(struct dstr) option_labels;

	enum gs_shader_param_type type;
	gs_eparam_t *param;

	struct image_file *image;
	gs_texrender_t *render;
	obs_weak_source_t *source;

	union {
		long long i;
		double f;
		char *string;
		struct vec2 vec2;
		struct vec3 vec3;
		struct vec4 vec4;
	} value;
	union {
		long long i;
		double f;
		char *string;
		struct vec2 vec2;
		struct vec3 vec3;
		struct vec4 vec4;
	} default_value;
	bool has_default;
	char *label;
	union {
		long long i;
		double f;
	} minimum;
	union {
		long long i;
		double f;
	} maximum;
	union {
		long long i;
		double f;
	} step;
};

/* GPU timer queries for the filter's pass. Reading a query waits for the GPU
 * to finish it (on Direct3D and OpenGL alike), so a query is only read once
 * GPU_TIMER_AGE frames have passed since it was issued; until then the slot
 * is skipped and that draw isn't timed. */
#define GPU_TIMER_SLOTS 6
#define GPU_TIMER_AGE 4
struct gpu_timer_slot {
	gs_timer_t *timer;
	gs_timer_range_t *range; /* NULL where the driver has none (OpenGL) */
	bool pending;
	uint64_t issued_tick;
};

struct shader_filter_data {
	obs_source_t *context;
	gs_effect_t *effect;
	gs_effect_t *output_effect;
	gs_vertbuffer_t *sprite_buffer;

	gs_texrender_t *input_texrender;
	gs_texrender_t *previous_input_texrender;
	gs_texrender_t *output_texrender;
	gs_texrender_t *previous_output_texrender;
	gs_eparam_t *param_output_image;

	bool reload_effect;
	/* Until this time, a properties rebuild is a refresh of an open panel
	 * after the shader changed (so browsing tools stay as they were). */
	uint64_t props_refresh_until;
	/* The person opened the browsing tools on this filter (this session);
	 * browse_shown is what the panel was last built with, so a change can be
	 * told apart from libobs re-running callbacks when it builds the panel. */
	bool browse_kept;
	bool browse_shown;

	/* Measured GPU time of this filter's own pass (graphics thread). */
	struct gpu_timer_slot gpu_slots[GPU_TIMER_SLOTS];
	size_t gpu_slot;
	uint64_t gpu_tick; /* video ticks seen, to age the queries */
	double gpu_sum_ms;
	uint32_t gpu_samples;
	uint64_t gpu_window_start;
	float gpu_ms;          /* average over the last second; < 0 if not drawn */
	bool gpu_merged;       /* last frame: drawn inside the next shader filter's pass */
	uint32_t gpu_group;    /* last frame: filters drawn in this filter's pass, itself included */
	bool frame_merged;     /* the same, for the frame being drawn */
	uint32_t frame_group;
	bool gpu_props_waiting; /* the panel was built before there was a figure */
	struct dstr last_path;
	bool last_from_file;
	bool transition;
	bool transitioning;
	bool prev_transitioning;

	bool use_pm_alpha;
	bool output_rendered;
	bool input_rendered;
	/* Which form output_texrender holds this frame (enum out_form). */
	int output_form;

	float shader_start_time;
	float shader_show_time;
	float shader_active_time;
	float shader_enable_time;
	bool enabled;
	bool use_template;

	gs_eparam_t *param_uv_offset;
	gs_eparam_t *param_uv_scale;
	gs_eparam_t *param_uv_pixel_interval;
	gs_eparam_t *param_uv_size;
	gs_eparam_t *param_current_time_ms;
	gs_eparam_t *param_current_time_sec;
	gs_eparam_t *param_current_time_min;
	gs_eparam_t *param_current_time_hour;
	gs_eparam_t *param_current_time_day_of_week;
	gs_eparam_t *param_current_time_day_of_month;
	gs_eparam_t *param_current_time_month;
	gs_eparam_t *param_current_time_day_of_year;
	gs_eparam_t *param_current_time_year;
	gs_eparam_t *param_elapsed_time;
	gs_eparam_t *param_elapsed_time_start;
	gs_eparam_t *param_elapsed_time_show;
	gs_eparam_t *param_elapsed_time_active;
	gs_eparam_t *param_elapsed_time_enable;
	gs_eparam_t *param_loops;
	gs_eparam_t *param_loop_second;
	gs_eparam_t *param_local_time;
	gs_eparam_t *param_rand_f;
	gs_eparam_t *param_rand_instance_f;
	gs_eparam_t *param_rand_activation_f;
	gs_eparam_t *param_image;
	gs_eparam_t *param_previous_image;
	gs_eparam_t *param_image_a;
	gs_eparam_t *param_image_b;
	gs_eparam_t *param_transition_time;
	gs_eparam_t *param_convert_linear;
	gs_eparam_t *param_previous_output;
	gs_eparam_t *param_audio_peak;
	gs_eparam_t *param_audio_magnitude;

	int expand_left;
	int expand_right;
	int expand_top;
	int expand_bottom;

	int total_width;
	int total_height;
	bool no_repeat;
	bool rendering;

	struct vec2 uv_offset;
	struct vec2 uv_scale;
	struct vec2 uv_pixel_interval;
	struct vec2 uv_size;
	float elapsed_time;
	float elapsed_time_loop;
	int loops;
	float local_time;
	float rand_f;
	float rand_instance_f;
	float rand_activation_f;
	float audio_peak;
	float audio_magnitude;

	char *audio_source_name;
	obs_volmeter_t *volmeter;
	float current_audio_peak;
	float current_audio_magnitude;

	DARRAY(struct effect_param_data) stored_param_list;
	uint64_t last_frame_time;

	/* Fusion (see shader-fusion.h): the template shader body, whether it
	 * only reads `image` at its own pixel, and a generation number that
	 * changes whenever the effect is rebuilt. */
	char *shader_body;
	bool pointwise;
	bool can_feed;
	bool own_technique;
	long effect_gen;
	/* Ticks left in which derived effects may be compiled while showing,
	 * after this filter's own effect was (re)built (a stall then anyway). */
	int fresh_ticks;
	struct derived_effect *derived[4];
};

static volatile long effect_generation = 0;

/* Derived effects (linking and fusion; see "Linked rendering" below) are cached
 * on the last filter of the run they render, keyed by the run's filters and
 * their effect generations (so a rebuilt or freed filter never matches), a few
 * per filter so that toggling a filter back and forth finds its effects
 * again. `copies` maps each stage's own uniforms to the derived effect's. */
#define SF_MAX_FUSED 16
#define SF_DERIVED_CACHE 4

struct fused_param_copy {
	gs_eparam_t *src;
	gs_eparam_t *dst;
};

struct derived_effect {
	gs_effect_t *effect;
	size_t count;
	struct shader_filter_data *stages[SF_MAX_FUSED];
	long gens[SF_MAX_FUSED];
	bool failed;
	uint64_t last_used;
	DARRAY(struct fused_param_copy) copies;
};

static uint64_t derived_use_counter = 0;

static void derived_effect_destroy(struct derived_effect *de)
{
	if (!de)
		return;
	if (de->effect) {
		obs_enter_graphics();
		gs_effect_destroy(de->effect);
		obs_leave_graphics();
	}
	da_free(de->copies);
	bfree(de);
}

static void derived_effects_free(struct shader_filter_data *filter)
{
	for (size_t i = 0; i < SF_DERIVED_CACHE; i++) {
		derived_effect_destroy(filter->derived[i]);
		filter->derived[i] = NULL;
	}
}

static unsigned int rand_interval(unsigned int min, unsigned int max)
{
	unsigned int r;
	const unsigned int range = 1 + max - min;
	const unsigned int buckets = RAND_MAX / range;
	const unsigned int limit = buckets * range;

	/* Create equal size buckets all in a row, then fire randomly towards
	 * the buckets until you land in one of them. All buckets are equally
	 * likely. If you land off the end of the line of buckets, try again. */
	do {
		r = rand();
	} while (r >= limit);

	return min + (r / buckets);
}

static char *load_shader_from_file(const char *file_name) // add input of visited files
{
	char *file_ptr = os_quick_read_utf8_file(file_name);
	if (file_ptr == NULL) {
		blog(LOG_WARNING, "[obs-shaderfilter] failed to read file: %s", file_name);
		return NULL;
	}
	char **lines = strlist_split(file_ptr, '\n', true);
	struct dstr shader_file;
	dstr_init(&shader_file);

	size_t line_i = 0;
	while (lines[line_i] != NULL) {
		char *line = lines[line_i];
		line_i++;
		if (strncmp(line, "#include", 8) == 0) {
			// Open the included file, place contents here.
			char *pos = strrchr(file_name, '/');
			const size_t length = pos - file_name + 1;
			struct dstr include_path = {0};
			dstr_ncopy(&include_path, file_name, length);
			char *start = strchr(line, '"') + 1;
			char *end = strrchr(line, '"');

			dstr_ncat(&include_path, start, end - start);
			char *abs_include_path = os_get_abs_path_ptr(include_path.array);
			char *file_contents = load_shader_from_file(abs_include_path);
			dstr_cat(&shader_file, file_contents);
			dstr_cat(&shader_file, "\n");
			bfree(abs_include_path);
			bfree(file_contents);
			dstr_free(&include_path);
		} else {
			// else place current line here.
			dstr_cat(&shader_file, line);
			dstr_cat(&shader_file, "\n");
		}
	}

	// Add file_name to visited files
	// Do stuff with the file, and populate shader_file
	/*

		for line in file:
		   if line starts with #include
		       get path
		       if path is not in visited files
			   include_file_contents = load_shader_from_file(path)
	                   concat include_file_contents onto shader_file
	           else
		       concat line onto shader_file
	*/
	bfree(file_ptr);
	strlist_free(lines);
	return shader_file.array;
}

static void shader_filter_clear_params(struct shader_filter_data *filter)
{
	filter->param_current_time_ms = NULL;
	filter->param_current_time_sec = NULL;
	filter->param_current_time_min = NULL;
	filter->param_current_time_hour = NULL;
	filter->param_current_time_day_of_week = NULL;
	filter->param_current_time_day_of_month = NULL;
	filter->param_current_time_month = NULL;
	filter->param_current_time_day_of_year = NULL;
	filter->param_current_time_year = NULL;
	filter->param_elapsed_time = NULL;
	filter->param_elapsed_time_start = NULL;
	filter->param_elapsed_time_show = NULL;
	filter->param_elapsed_time_active = NULL;
	filter->param_elapsed_time_enable = NULL;
	filter->param_uv_offset = NULL;
	filter->param_uv_pixel_interval = NULL;
	filter->param_uv_scale = NULL;
	filter->param_uv_size = NULL;
	filter->param_rand_f = NULL;
	filter->param_rand_activation_f = NULL;
	filter->param_rand_instance_f = NULL;
	filter->param_loops = NULL;
	filter->param_loop_second = NULL;
	filter->param_local_time = NULL;
	filter->param_audio_peak = NULL;
	filter->param_audio_magnitude = NULL;
	filter->param_image = NULL;
	filter->param_previous_image = NULL;
	filter->param_image_a = NULL;
	filter->param_image_b = NULL;
	filter->param_transition_time = NULL;
	filter->param_convert_linear = NULL;
	filter->param_previous_output = NULL;

	size_t param_count = filter->stored_param_list.num;
	for (size_t param_index = 0; param_index < param_count; param_index++) {
		struct effect_param_data *param = (filter->stored_param_list.array + param_index);
		if (param->image) {
			obs_enter_graphics();
			gs_image_file_free_func(param->image);
			obs_leave_graphics();

			bfree(param->image);
			param->image = NULL;
		}
		if (param->source) {
			obs_source_t *source = obs_weak_source_get_source(param->source);
			if (source) {
				if ((!filter->transition || filter->prev_transitioning) && obs_source_active(filter->context))
					obs_source_dec_active(source);
				if ((!filter->transition || filter->prev_transitioning) && obs_source_showing(filter->context))
					obs_source_dec_showing(source);
				obs_source_release(source);
			}
			obs_weak_source_release(param->source);
			param->source = NULL;
		}
		if (param->render) {
			obs_enter_graphics();
			gs_texrender_destroy(param->render);
			obs_leave_graphics();
			param->render = NULL;
		}
		if (param->type == GS_SHADER_PARAM_STRING)
			bfree(param->value.string);
		dstr_free(&param->name);
		dstr_free(&param->display_name);
		dstr_free(&param->widget_type);
		dstr_free(&param->group);
		dstr_free(&param->path);
		dstr_free(&param->tooltip);
		da_free(param->option_values);
		for (size_t i = 0; i < param->option_labels.num; i++) {
			dstr_free(&param->option_labels.array[i]);
		}
		da_free(param->option_labels);
	}

	da_free(filter->stored_param_list);
}

/* render_output.effect is the same for every filter: compile it once. */
static pthread_mutex_t output_effect_mutex = PTHREAD_MUTEX_INITIALIZER;
static gs_effect_t *shared_output_effect = NULL;
static gs_eparam_t *shared_output_image = NULL;
static long shared_output_refs = 0;

static void create_shared_output_effect(void);

static void load_output_effect(struct shader_filter_data *filter)
{
	pthread_mutex_lock(&output_effect_mutex);
	if (shared_output_refs++ == 0)
		create_shared_output_effect();
	filter->output_effect = shared_output_effect;
	filter->param_output_image = shared_output_image;
	pthread_mutex_unlock(&output_effect_mutex);
}

static void release_output_effect(struct shader_filter_data *filter)
{
	pthread_mutex_lock(&output_effect_mutex);
	if (--shared_output_refs == 0 && shared_output_effect) {
		obs_enter_graphics();
		gs_effect_destroy(shared_output_effect);
		obs_leave_graphics();
		shared_output_effect = NULL;
		shared_output_image = NULL;
	}
	pthread_mutex_unlock(&output_effect_mutex);
	filter->output_effect = NULL;
	filter->param_output_image = NULL;
}

static void create_shared_output_effect(void)
{
	char *shader_text = NULL;
	struct dstr filename = {0};
	dstr_cat(&filename, obs_get_module_data_path(obs_current_module()));
	dstr_cat(&filename, "/internal/render_output.effect");
	char *abs_path = os_get_abs_path_ptr(filename.array);
	if (abs_path) {
		shader_text = load_shader_from_file(abs_path);
		bfree(abs_path);
	}
	if (!shader_text)
		shader_text = load_shader_from_file(filename.array);

	char *errors = NULL;
	dstr_free(&filename);

	obs_enter_graphics();
	shared_output_effect = gs_effect_create(shader_text, NULL, &errors);
	obs_leave_graphics();

	bfree(shader_text);
	if (shared_output_effect == NULL) {
		blog(LOG_WARNING, "[obs-shaderfilter] Unable to load render_output.effect file.  Errors:\n%s",
		     (errors == NULL || strlen(errors) == 0 ? "(None)" : errors));
		bfree(errors);
	} else {
		shared_output_image = gs_effect_get_param_by_name(shared_output_effect, "output_image");
	}
}

static void load_sprite_buffer(struct shader_filter_data *filter)
{
	if (filter->sprite_buffer)
		return;
	struct gs_vb_data *vbd = gs_vbdata_create();
	vbd->num = 4;
	vbd->points = bmalloc(sizeof(struct vec3) * 4);
	vbd->num_tex = 1;
	vbd->tvarray = bmalloc(sizeof(struct gs_tvertarray));
	vbd->tvarray[0].width = 2;
	vbd->tvarray[0].array = bmalloc(sizeof(struct vec2) * 4);
	memset(vbd->points, 0, sizeof(struct vec3) * 4);
	memset(vbd->tvarray[0].array, 0, sizeof(struct vec2) * 4);
	filter->sprite_buffer = gs_vertexbuffer_create(vbd, GS_DYNAMIC);
}

static char *shader_display_name(const char *path);

/* What the panel shows when the shader can't be used: a plain first line, then
 * the compiler's messages without the effect parser's "(null) (line, col): "
 * prefixes (they refer to the generated effect, not the file). */
static void set_error_message(obs_data_t *settings, const char *plain_fmt, const char *file, const char *details)
{
	struct dstr msg = {0}, errs = {0}, warns = {0};
	char *name = file && *file ? shader_display_name(file) : bstrdup(obs_module_text("ShaderFilter.ThisShader"));
	dstr_printf(&msg, plain_fmt, name);
	bfree(name);
	if (details && *details) {
		char **lines = strlist_split(details, '\n', false);
		for (char **l = lines; l && *l; l++) {
			const char *line = *l;
			if (strncmp(line, "(null) (", 8) == 0) {
				const char *colon = strstr(line, "): ");
				if (colon)
					line = colon + 3;
			}
			if (!*line || strcmp(line, "Error compiling shader:") == 0)
				continue;
			struct dstr *to = strstr(line, "warning") ? &warns : &errs;
			if (to->len)
				dstr_cat(to, "\n");
			dstr_cat(to, line);
		}
		strlist_free(lines);
	}
	/* Where: "glow.shader: <first compiler error>", then the full path. */
	struct dstr where = {0};
	if (file && *file) {
		const char *base = strrchr(file, '/');
		const char *base2 = strrchr(file, '\\');
		if (base2 > base)
			base = base2;
		dstr_copy(&where, base ? base + 1 : file);
	} else {
		dstr_copy(&where, obs_module_text("ShaderFilter.InlineCode"));
	}
	if (errs.len) {
		const char *nl = strchr(errs.array, '\n');
		struct dstr first = {0};
		dstr_ncopy(&first, errs.array, nl ? (size_t)(nl - errs.array) : errs.len);
		/* "0:41(12): error: msg" / "file(41,12): error X3004: msg" -> "msg"
		 * (line numbers refer to generated code, not the file). */
		const char *text = first.array;
		const char *e = strstr(text, ": error");
		const char *colon = e ? strstr(e + 2, ": ") : NULL;
		if (colon)
			text = colon + 2;
		dstr_catf(&where, ": %s", text);
		dstr_free(&first);
	}
	if (file && *file)
		dstr_catf(&where, "\n%s", file);
	obs_data_set_string(settings, "error_where", where.array);
	dstr_free(&where);
	obs_data_set_string(settings, "error_message", msg.array);
	obs_data_set_string(settings, "error_details", errs.array ? errs.array : "");
	obs_data_set_string(settings, "warning_details", warns.array ? warns.array : "");
	dstr_free(&msg);
	dstr_free(&errs);
	dstr_free(&warns);
}

/* While its shader fails, a filter the plugin named shows it in the filter
 * list ("Glow (error)"); names the person typed are left alone. */
static void mark_error_in_name(struct shader_filter_data *filter, obs_data_t *settings, bool failed)
{
	if (filter->transition)
		return;
	const char *auto_name = obs_data_get_string(settings, "auto_name");
	if (!auto_name || !*auto_name)
		return;
	const char *cur = obs_source_get_name(filter->context);
	struct dstr marked = {0};
	dstr_printf(&marked, obs_module_text("ShaderFilter.ErrorName"), auto_name);
	if (failed && strcmp(cur, auto_name) == 0)
		obs_source_set_name(filter->context, marked.array);
	else if (!failed && strcmp(cur, marked.array) == 0)
		obs_source_set_name(filter->context, auto_name);
	dstr_free(&marked);
}

static char *examples_dir(void);

static void shader_filter_reload_effect(struct shader_filter_data *filter)
{
	obs_data_t *settings = obs_source_get_settings(filter->context);

	// First, clean up the old effect and all references to it.
	filter->shader_start_time = 0.0f;
	shader_filter_clear_params(filter);

	if (filter->effect != NULL) {
		obs_enter_graphics();
		gs_effect_destroy(filter->effect);
		filter->effect = NULL;
		obs_leave_graphics();
	}

	bfree(filter->shader_body);
	filter->shader_body = NULL;
	filter->pointwise = false;
	filter->can_feed = false;
	filter->own_technique = false;
	filter->effect_gen = os_atomic_inc_long(&effect_generation);
	filter->fresh_ticks = 3;

	// Load text and build the effect from the template, if necessary.
	char *shader_text = NULL;
	bool use_template = !obs_data_get_bool(settings, "override_entire_effect");

	if (obs_data_get_bool(settings, "from_file")) {
		const char *file_name = obs_data_get_string(settings, "shader_file_name");
		if (!strlen(file_name)) {
			obs_data_unset_user_value(settings, "last_error");
			obs_data_unset_user_value(settings, "error_message");
			obs_data_unset_user_value(settings, "error_details");
		obs_data_unset_user_value(settings, "error_where");
			obs_data_unset_user_value(settings, "warning_details");
			goto end;
		}
		shader_text = load_shader_from_file(file_name);
		if (!shader_text) {
			obs_data_set_string(settings, "last_error", obs_module_text("ShaderFilter.FileLoadFailed"));
			set_error_message(settings,
					  obs_module_text(os_file_exists(file_name) ? "ShaderFilter.CantRead"
										    : "ShaderFilter.CantFind"),
					  file_name, NULL);
			goto end;
		}
	} else {
		shader_text = bstrdup(obs_data_get_string(settings, "shader_text"));
		use_template = true;
	}
	filter->use_template = use_template;

	struct dstr effect_text = {0};

	if (use_template) {
		dstr_cat(&effect_text, effect_template_begin);
	}

	if (shader_text) {
		dstr_cat(&effect_text, shader_text);
		/* A .shader body that declares its own technique draws with that
		 * (the first "Draw" wins), not necessarily through mainImage, so
		 * it can't be linked from or fused. */
		filter->own_technique = use_template && strstr(shader_text, "technique") != NULL;
		if (use_template && !filter->own_technique && !filter->transition && !strstr(shader_text, "USE_PM_ALPHA")) {
			filter->shader_body = shader_text;
			filter->pointwise = sf_fusion_is_pointwise(shader_text);
			filter->can_feed = sf_fusion_can_feed(shader_text);
		} else {
			bfree(shader_text);
		}
	}

	if (use_template) {
		dstr_cat(&effect_text, effect_template_end);
	}

	// Create the effect.
	char *errors = NULL;

	obs_enter_graphics();
	int device_type = gs_get_device_type();
	if (device_type == GS_DEVICE_OPENGL) {
		dstr_replace(&effect_text, "[loop]", "");
		dstr_insert(&effect_text, 0, "#define OPENGL 1\n");
	}

	if (effect_text.len && dstr_find(&effect_text, "#define USE_PM_ALPHA 1")) {
		filter->use_pm_alpha = true;
	} else {
		filter->use_pm_alpha = false;
	}

	if (filter->effect)
		gs_effect_destroy(filter->effect);
	filter->effect = gs_effect_create(effect_text.array, NULL, &errors);
	obs_leave_graphics();

	if (filter->effect == NULL) {
		blog(LOG_WARNING, "[obs-shaderfilter] Unable to create effect. Errors returned from parser:\n%s",
		     (errors == NULL || strlen(errors) == 0 ? "(None)" : errors));
		if (errors && strlen(errors)) {
			obs_data_set_string(settings, "last_error", errors);
		} else {
			obs_data_set_string(settings, "last_error", obs_module_text("ShaderFilter.Unknown"));
		}
		const char *failed_file = obs_data_get_bool(settings, "from_file")
						  ? obs_data_get_string(settings, "shader_file_name")
						  : NULL;
		char *bundled = examples_dir();
		const bool from_library = failed_file && bundled && strncmp(failed_file, bundled, strlen(bundled)) == 0;
		bfree(bundled);
		set_error_message(settings,
				  obs_module_text(from_library ? "ShaderFilter.CantCompileLibrary" : "ShaderFilter.CantCompile"),
				  obs_data_get_bool(settings, "from_file") ? obs_data_get_string(settings, "shader_file_name")
									   : NULL,
				  obs_data_get_string(settings, "last_error"));
		dstr_free(&effect_text);
		bfree(errors);
		goto end;
	} else {
		dstr_free(&effect_text);
		obs_data_unset_user_value(settings, "last_error");
		obs_data_unset_user_value(settings, "error_message");
		obs_data_unset_user_value(settings, "error_details");
		obs_data_unset_user_value(settings, "error_where");
		obs_data_unset_user_value(settings, "warning_details");
	}

	// Store references to the new effect's parameters.
	da_free(filter->stored_param_list);

	size_t effect_count = gs_effect_get_num_params(filter->effect);
	for (size_t effect_index = 0; effect_index < effect_count; effect_index++) {
		gs_eparam_t *param = gs_effect_get_param_by_idx(filter->effect, effect_index);
		if (!param)
			continue;
		struct gs_effect_param_info info;
		gs_effect_get_param_info(param, &info);

		if (strcmp(info.name, "uv_offset") == 0) {
			filter->param_uv_offset = param;
		} else if (strcmp(info.name, "uv_scale") == 0) {
			filter->param_uv_scale = param;
		} else if (strcmp(info.name, "uv_pixel_interval") == 0) {
			filter->param_uv_pixel_interval = param;
		} else if (strcmp(info.name, "uv_size") == 0) {
			filter->param_uv_size = param;
		} else if (strcmp(info.name, "current_time_ms") == 0) {
			filter->param_current_time_ms = param;
		} else if (strcmp(info.name, "current_time_sec") == 0) {
			filter->param_current_time_sec = param;
		} else if (strcmp(info.name, "current_time_min") == 0) {
			filter->param_current_time_min = param;
		} else if (strcmp(info.name, "current_time_hour") == 0) {
			filter->param_current_time_hour = param;
		} else if (strcmp(info.name, "current_time_day_of_week") == 0) {
			filter->param_current_time_day_of_week = param;
		} else if (strcmp(info.name, "current_time_day_of_month") == 0) {
			filter->param_current_time_day_of_month = param;
		} else if (strcmp(info.name, "current_time_month") == 0) {
			filter->param_current_time_month = param;
		} else if (strcmp(info.name, "current_time_day_of_year") == 0) {
			filter->param_current_time_day_of_year = param;
		} else if (strcmp(info.name, "current_time_year") == 0) {
			filter->param_current_time_year = param;
		} else if (strcmp(info.name, "elapsed_time") == 0) {
			filter->param_elapsed_time = param;
		} else if (strcmp(info.name, "elapsed_time_start") == 0) {
			filter->param_elapsed_time_start = param;
		} else if (strcmp(info.name, "elapsed_time_show") == 0) {
			filter->param_elapsed_time_show = param;
		} else if (strcmp(info.name, "elapsed_time_active") == 0) {
			filter->param_elapsed_time_active = param;
		} else if (strcmp(info.name, "elapsed_time_enable") == 0) {
			filter->param_elapsed_time_enable = param;
		} else if (strcmp(info.name, "rand_f") == 0) {
			filter->param_rand_f = param;
		} else if (strcmp(info.name, "rand_activation_f") == 0) {
			filter->param_rand_activation_f = param;
		} else if (strcmp(info.name, "rand_instance_f") == 0) {
			filter->param_rand_instance_f = param;
		} else if (strcmp(info.name, "loops") == 0) {
			filter->param_loops = param;
		} else if (strcmp(info.name, "loop_second") == 0) {
			filter->param_loop_second = param;
		} else if (strcmp(info.name, "local_time") == 0) {
			filter->param_local_time = param;
		} else if (strcmp(info.name, "audio_peak") == 0) {
			filter->param_audio_peak = param;
		} else if (strcmp(info.name, "audio_magnitude") == 0) {
			filter->param_audio_magnitude = param;
		} else if (strcmp(info.name, "ViewProj") == 0) {
			// Nothing.
		} else if (strcmp(info.name, "image") == 0) {
			filter->param_image = param;
		} else if (strcmp(info.name, "previous_image") == 0) {
			filter->param_previous_image = param;
		} else if (strcmp(info.name, "previous_output") == 0) {
			filter->param_previous_output = param;
		} else if (filter->transition && strcmp(info.name, "image_a") == 0) {
			filter->param_image_a = param;
		} else if (filter->transition && strcmp(info.name, "image_b") == 0) {
			filter->param_image_b = param;
		} else if (filter->transition && strcmp(info.name, "transition_time") == 0) {
			filter->param_transition_time = param;
		} else if (filter->transition && strcmp(info.name, "convert_linear") == 0) {
			filter->param_convert_linear = param;
		} else {
			struct effect_param_data *cached_data = da_push_back_new(filter->stored_param_list);
			dstr_copy(&cached_data->name, info.name);
			cached_data->type = info.type;
			cached_data->param = param;
			da_init(cached_data->option_values);
			da_init(cached_data->option_labels);
			const size_t annotation_count = gs_param_get_num_annotations(param);
			for (size_t annotation_index = 0; annotation_index < annotation_count; annotation_index++) {
				gs_eparam_t *annotation = gs_param_get_annotation_by_idx(param, annotation_index);
				void *annotation_default = gs_effect_get_default_val(annotation);
				gs_effect_get_param_info(annotation, &info);
				if (strcmp(info.name, "name") == 0 && info.type == GS_SHADER_PARAM_STRING) {
					dstr_copy(&cached_data->display_name, (const char *)annotation_default);
				} else if (strcmp(info.name, "label") == 0 && info.type == GS_SHADER_PARAM_STRING) {
					dstr_copy(&cached_data->display_name, (const char *)annotation_default);
				} else if (strcmp(info.name, "widget_type") == 0 && info.type == GS_SHADER_PARAM_STRING) {
					dstr_copy(&cached_data->widget_type, (const char *)annotation_default);
				} else if (strcmp(info.name, "group") == 0 && info.type == GS_SHADER_PARAM_STRING) {
					dstr_copy(&cached_data->group, (const char *)annotation_default);
				} else if (strcmp(info.name, "tooltip") == 0 && info.type == GS_SHADER_PARAM_STRING) {
					dstr_copy(&cached_data->tooltip, (const char *)annotation_default);
				} else if (strcmp(info.name, "minimum") == 0) {
					if (info.type == GS_SHADER_PARAM_FLOAT || info.type == GS_SHADER_PARAM_VEC2 ||
					    info.type == GS_SHADER_PARAM_VEC3 || info.type == GS_SHADER_PARAM_VEC4) {
						cached_data->minimum.f = *(float *)annotation_default;
					} else if (info.type == GS_SHADER_PARAM_INT) {
						cached_data->minimum.i = *(int *)annotation_default;
					}
				} else if (strcmp(info.name, "maximum") == 0) {
					if (info.type == GS_SHADER_PARAM_FLOAT || info.type == GS_SHADER_PARAM_VEC2 ||
					    info.type == GS_SHADER_PARAM_VEC3 || info.type == GS_SHADER_PARAM_VEC4) {
						cached_data->maximum.f = *(float *)annotation_default;
					} else if (info.type == GS_SHADER_PARAM_INT) {
						cached_data->maximum.i = *(int *)annotation_default;
					}
				} else if (strcmp(info.name, "step") == 0) {
					if (info.type == GS_SHADER_PARAM_FLOAT || info.type == GS_SHADER_PARAM_VEC2 ||
					    info.type == GS_SHADER_PARAM_VEC3 || info.type == GS_SHADER_PARAM_VEC4) {
						cached_data->step.f = *(float *)annotation_default;
					} else if (info.type == GS_SHADER_PARAM_INT) {
						cached_data->step.i = *(int *)annotation_default;
					}
				} else if (strncmp(info.name, "option_", 7) == 0) {
					int id = atoi(info.name + 7);
					if (info.type == GS_SHADER_PARAM_INT) {
						int val = *(int *)annotation_default;
						int *cd = da_insert_new(cached_data->option_values, id);
						*cd = val;

					} else if (info.type == GS_SHADER_PARAM_STRING) {
						struct dstr val = {0};
						dstr_copy(&val, (const char *)annotation_default);
						struct dstr *cs = da_insert_new(cached_data->option_labels, id);
						*cs = val;
					}
				}
				bfree(annotation_default);
			}
		}
	}

end:
	mark_error_in_name(filter, settings, obs_data_has_user_value(settings, "error_message"));
	obs_data_release(settings);
}

static const char *shader_filter_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("ShaderFilter");
}

static void *shader_filter_create(obs_data_t *settings, obs_source_t *source)
{
	struct shader_filter_data *filter = bzalloc(sizeof(struct shader_filter_data));
	filter->context = source;
	filter->reload_effect = true;
	filter->gpu_ms = -1.0f;
	filter->gpu_group = 1;

	dstr_init(&filter->last_path);
	dstr_copy(&filter->last_path, obs_data_get_string(settings, "shader_file_name"));
	filter->last_from_file = obs_data_get_bool(settings, "from_file");
	filter->rand_instance_f = (float)((double)rand_interval(0, 10000) / (double)10000);
	filter->rand_activation_f = (float)((double)rand_interval(0, 10000) / (double)10000);

	da_init(filter->stored_param_list);
	load_output_effect(filter);
	/* A filter just added (no settings at all) starts on a shader file, not
	 * typed code; filters saved by older versions keep what they had. */
	obs_data_item_t *first = obs_data_first(settings);
	if (!first) {
		obs_data_set_bool(settings, "from_file", true);
		filter->last_from_file = true;
	}
	obs_data_item_release(&first);
	obs_source_update(source, settings);

	return filter;
}

static void shader_filter_destroy(void *data)
{
	struct shader_filter_data *filter = data;
	shader_filter_clear_params(filter);

	obs_enter_graphics();
	if (filter->effect)
		gs_effect_destroy(filter->effect);
	if (filter->input_texrender)
		gs_texrender_destroy(filter->input_texrender);
	if (filter->output_texrender)
		gs_texrender_destroy(filter->output_texrender);
	if (filter->previous_input_texrender)
		gs_texrender_destroy(filter->previous_input_texrender);
	if (filter->previous_output_texrender)
		gs_texrender_destroy(filter->previous_output_texrender);
	if (filter->sprite_buffer)
		gs_vertexbuffer_destroy(filter->sprite_buffer);
	for (size_t i = 0; i < GPU_TIMER_SLOTS; i++) {
		gs_timer_destroy(filter->gpu_slots[i].timer);
		gs_timer_range_destroy(filter->gpu_slots[i].range);
	}
	obs_leave_graphics();

	if (!filter->transition)
		release_output_effect(filter);
	dstr_free(&filter->last_path);
	da_free(filter->stored_param_list);
	bfree(filter->shader_body);
	derived_effects_free(filter);

	if (filter->volmeter)
		obs_volmeter_destroy(filter->volmeter);
	if (filter->audio_source_name)
		bfree(filter->audio_source_name);

	bfree(filter);
}

/* ------------------------------------------------------------------------
 * Shader library and naming (properties UI)
 *
 * The "Shader" list shows the shader files in a library folder: the folder of
 * the current shader file, or the bundled examples. Filters list filter
 * shaders and transitions list transition shaders (those using image_a and
 * image_b). Whether a file is a full effect is worked out from its extension
 * (or, for other extensions, whether it declares a technique), so the
 * "Use Effect File" setting is managed for the user.
 * ------------------------------------------------------------------------ */

#define PICK_NONE ""
#define PICK_INLINE "*inline*"
#define PICK_OTHER "*other*"
#define PICK_HEADING "*heading*"

struct shader_entry {
	char *path;
	char *label;
	char *category;
	size_t rank; /* category's place in library.ini; uncategorised last */
	int cost;    /* from library.ini, see struct library_item */
};

/* A folder's library.ini: "file = Category | Display name" under [shaders]. */
struct library_item {
	char *stem;
	char *category;
	char *name;
	bool space; /* draws outside the image: offer "Add Space Around the Image" up front */
	int cost;   /* rough GPU cost: 0 light, 1 medium, 2 heavy, 3 very heavy */
};
typedef DARRAY(struct library_item) library_t;

static void library_free(library_t *lib)
{
	for (size_t i = 0; i < lib->num; i++) {
		bfree(lib->array[i].stem);
		bfree(lib->array[i].category);
		bfree(lib->array[i].name);
	}
	da_free(*lib);
}

static char *trimmed(const char *s, size_t len)
{
	while (len && (*s == ' ' || *s == '\t')) {
		s++;
		len--;
	}
	while (len && (s[len - 1] == ' ' || s[len - 1] == '\t' || s[len - 1] == '\r'))
		len--;
	return bstrdup_n(s, len);
}

static bool contains_ci(const char *haystack, const char *needle);

static void library_load(const char *dir, library_t *lib)
{
	da_init(*lib);
	struct dstr path = {0};
	dstr_printf(&path, "%s/library.ini", dir);
	char *text = os_quick_read_utf8_file(path.array);
	dstr_free(&path);
	if (!text)
		return;
	bool in_shaders = false;
	char **lines = strlist_split(text, '\n', false);
	for (char **l = lines; l && *l; l++) {
		const char *line = *l;
		while (*line == ' ' || *line == '\t')
			line++;
		if (*line == ';' || *line == '#' || !*line)
			continue;
		if (*line == '[') {
			in_shaders = astrcmpi_n(line, "[shaders]", 9) == 0;
			continue;
		}
		const char *eq = strchr(line, '=');
		if (!in_shaders || !eq)
			continue;
		const char *val = eq + 1;
		const char *bar = strchr(val, '|');
		struct library_item it;
		it.stem = trimmed(line, eq - line);
		it.category = trimmed(val, bar ? (size_t)(bar - val) : strlen(val));
		const char *bar2 = bar ? strchr(bar + 1, '|') : NULL;
		it.name = bar ? trimmed(bar + 1, bar2 ? (size_t)(bar2 - bar - 1) : strlen(bar + 1)) : bstrdup("");
		it.space = false;
		it.cost = 0;
		if (bar2) {
			char *flags = trimmed(bar2 + 1, strlen(bar2 + 1));
			it.space = contains_ci(flags, "space");
			it.cost = contains_ci(flags, "very heavy") ? 3 : contains_ci(flags, "heavy") ? 2
								   : contains_ci(flags, "medium") ? 1 : 0;
			bfree(flags);
		}
		da_push_back(*lib, &it);
	}
	strlist_free(lines);
	bfree(text);
}

static const struct library_item *library_find(const library_t *lib, const char *path)
{
	const char *base = strrchr(path, '/');
	const char *base2 = strrchr(path, '\\');
	if (base2 > base)
		base = base2;
	base = base ? base + 1 : path;
	const char *dot = strrchr(base, '.');
	size_t len = dot ? (size_t)(dot - base) : strlen(base);
	for (size_t i = 0; i < lib->num; i++)
		if (strlen(lib->array[i].stem) == len && astrcmpi_n(lib->array[i].stem, base, len) == 0)
			return &lib->array[i];
	return NULL;
}

static char *parent_dir(const char *path)
{
	struct dstr d = {0};
	dstr_copy(&d, path);
	char *slash = strrchr(d.array, '/');
	char *bslash = strrchr(d.array, '\\');
	if (bslash > slash)
		slash = bslash;
	if (slash)
		dstr_resize(&d, slash - d.array);
	return d.array;
}

static char *friendly_shader_name(const char *path);

/* The name shown for a shader file: its library.ini name, else one made from
 * the file name. */
static char *shader_display_name(const char *path)
{
	char *dir = parent_dir(path);
	library_t lib;
	library_load(dir, &lib);
	bfree(dir);
	const struct library_item *it = library_find(&lib, path);
	char *name = it && *it->name ? bstrdup(it->name) : friendly_shader_name(path);
	library_free(&lib);
	return name;
}

typedef DARRAY(struct shader_entry) shader_list_t;

/* Whether two folder paths name the same folder, written either way: libobs
 * gives the bundled folder with backslashes on Windows, while paths saved
 * from file dialogs use forward slashes; Windows and macOS ignore case. */
static bool same_folder(const char *a, const char *b)
{
	if (!a || !b)
		return false;
	struct dstr x = {0}, y = {0};
	dstr_copy(&x, a);
	dstr_copy(&y, b);
	dstr_replace(&x, "\\", "/");
	dstr_replace(&y, "\\", "/");
	while (x.len > 1 && x.array[x.len - 1] == '/')
		dstr_resize(&x, x.len - 1);
	while (y.len > 1 && y.array[y.len - 1] == '/')
		dstr_resize(&y, y.len - 1);
#if defined(_WIN32) || defined(__APPLE__)
	const bool same = astrcmpi(x.array, y.array) == 0;
#else
	const bool same = strcmp(x.array, y.array) == 0;
#endif
	dstr_free(&x);
	dstr_free(&y);
	return same;
}

static char *examples_dir(void)
{
	struct dstr d = {0};
	dstr_cat(&d, obs_get_module_data_path(obs_current_module()));
	dstr_cat(&d, "/examples");
	char *abs = os_get_abs_path_ptr(d.array);
	if (abs) {
		dstr_free(&d);
		return abs;
	}
	return d.array;
}

static bool has_ext(const char *path, const char *ext)
{
	size_t l = strlen(path), e = strlen(ext);
	return l > e && astrcmpi(path + l - e, ext) == 0;
}

static bool path_is_effect(const char *path)
{
	if (has_ext(path, ".effect"))
		return true;
	if (has_ext(path, ".shader"))
		return false;
	char *text = os_quick_read_utf8_file(path);
	bool effect = text && strstr(text, "technique") != NULL;
	bfree(text);
	return effect;
}

/* Whether a shader file is a transition. Filling the Shader list asks this of
 * every file, on every keystroke in Search, so the answer is remembered per
 * file until the file changes (size or modification time). */
struct transition_memo {
	char *path;
	time_t mtime;
	int64_t size;
	bool transition;
};
static DARRAY(struct transition_memo) transition_memos;
static pthread_mutex_t transition_memo_mutex = PTHREAD_MUTEX_INITIALIZER;

static bool file_is_transition(const char *path)
{
	struct stat st;
	const bool known = os_stat(path, &st) == 0;
	bool t = false, found = false;
	pthread_mutex_lock(&transition_memo_mutex);
	for (size_t i = 0; known && i < transition_memos.num && !found; i++) {
		struct transition_memo *m = &transition_memos.array[i];
		if (strcmp(m->path, path) != 0)
			continue;
		if (m->mtime == st.st_mtime && m->size == (int64_t)st.st_size) {
			t = m->transition;
			found = true;
		} else {
			bfree(m->path);
			da_erase(transition_memos, i);
			break;
		}
	}
	pthread_mutex_unlock(&transition_memo_mutex);
	if (found)
		return t;

	char *text = os_quick_read_utf8_file(path);
	t = text && strstr(text, "image_a") && strstr(text, "image_b");
	bfree(text);
	if (known) {
		struct transition_memo m = {bstrdup(path), st.st_mtime, (int64_t)st.st_size, t};
		pthread_mutex_lock(&transition_memo_mutex);
		da_push_back(transition_memos, &m);
		pthread_mutex_unlock(&transition_memo_mutex);
	}
	return t;
}

static void transition_memos_free(void)
{
	pthread_mutex_lock(&transition_memo_mutex);
	for (size_t i = 0; i < transition_memos.num; i++)
		bfree(transition_memos.array[i].path);
	da_free(transition_memos);
	pthread_mutex_unlock(&transition_memo_mutex);
}

/* Names for bundled files whose file names don't make good titles. */
static const char *name_overrides[][2] = {
	{"hue-rotaton", "Hue Rotation"},
	{"bt601tobt709", "BT.601 to BT.709"},
	{"bt709tobt601", "BT.709 to BT.601"},
	{"rgbvisibility", "RGB Visibility"},
	{"rgssaa", "RGSSAA"},
};

static const char *acronyms[] = {"3d", "ascii", "bt", "crt", "gb", "hdr", "hsl", "hsv", "led", "lut", "obs", "rgb",
				 "rgba", "sdr", "tv", "uv", "vcr", "vhs"};

/* "chromatic-aberration.shader" -> "Chromatic Aberration", "fireworks2" ->
 * "Fireworks 2", "tv-crt-subpixel" -> "TV CRT Subpixel" */
static char *friendly_shader_name(const char *path)
{
	const char *base = strrchr(path, '/');
	const char *base2 = strrchr(path, '\\');
	if (base2 > base)
		base = base2;
	base = base ? base + 1 : path;
	struct dstr stem = {0};
	dstr_copy(&stem, base);
	char *dot = strrchr(stem.array, '.');
	if (dot && dot != stem.array)
		dstr_resize(&stem, dot - stem.array);

	for (size_t i = 0; i < sizeof(name_overrides) / sizeof(name_overrides[0]); i++) {
		if (astrcmpi(stem.array, name_overrides[i][0]) == 0) {
			dstr_free(&stem);
			return bstrdup(name_overrides[i][1]);
		}
	}

	struct dstr out = {0};
	char **words = strlist_split(stem.array, '_', false);
	struct dstr spaced = {0};
	for (char **w = words; w && *w; w++) {
		if (spaced.len)
			dstr_cat_ch(&spaced, ' ');
		dstr_cat(&spaced, *w);
	}
	strlist_free(words);
	dstr_replace(&spaced, "-", " ");
	words = strlist_split(spaced.array ? spaced.array : "", ' ', false);
	for (char **w = words; w && *w; w++) {
		struct dstr word = {0};
		dstr_copy(&word, *w);
		/* split a trailing number off a word: "fireworks2" -> "fireworks 2" */
		size_t k = word.len;
		while (k > 0 && word.array[k - 1] >= '0' && word.array[k - 1] <= '9')
			k--;
		struct dstr num = {0};
		if (k > 0 && k < word.len && !(word.array[k - 1] >= '0' && word.array[k - 1] <= '9')) {
			bool acronym_with_digits = false;
			for (size_t a = 0; a < sizeof(acronyms) / sizeof(acronyms[0]); a++)
				acronym_with_digits = acronym_with_digits || astrcmpi(word.array, acronyms[a]) == 0;
			if (!acronym_with_digits) {
				dstr_copy(&num, word.array + k);
				dstr_resize(&word, k);
			}
		}
		bool acronym = false;
		for (size_t a = 0; a < sizeof(acronyms) / sizeof(acronyms[0]); a++)
			acronym = acronym || astrcmpi(word.array, acronyms[a]) == 0;
		if (acronym) {
			for (size_t c = 0; c < word.len; c++)
				if (word.array[c] >= 'a' && word.array[c] <= 'z')
					word.array[c] = (char)(word.array[c] - 'a' + 'A');
		} else if (word.len && word.array[0] >= 'a' && word.array[0] <= 'z') {
			word.array[0] = (char)(word.array[0] - 'a' + 'A');
		}
		if (out.len)
			dstr_cat_ch(&out, ' ');
		dstr_cat_dstr(&out, &word);
		if (num.len) {
			dstr_cat_ch(&out, ' ');
			dstr_cat_dstr(&out, &num);
		}
		dstr_free(&word);
		dstr_free(&num);
	}
	strlist_free(words);
	dstr_free(&spaced);
	dstr_free(&stem);
	if (!out.array)
		dstr_copy(&out, base);
	return out.array;
}

static int cmp_entry(const void *a, const void *b)
{
	return astrcmpi(((const struct shader_entry *)a)->label, ((const struct shader_entry *)b)->label);
}

static int cmp_entry_ranked(const void *a, const void *b)
{
	const struct shader_entry *x = a, *y = b;
	if (x->rank != y->rank)
		return x->rank < y->rank ? -1 : 1;
	return astrcmpi(x->label, y->label);
}

static void free_shader_list(shader_list_t *list)
{
	for (size_t i = 0; i < list->num; i++) {
		bfree(list->array[i].path);
		bfree(list->array[i].label);
		bfree(list->array[i].category);
	}
	da_free(*list);
}

static bool contains_ci(const char *haystack, const char *needle)
{
	if (!needle || !*needle)
		return true;
	size_t n = strlen(needle);
	for (const char *h = haystack; *h; h++)
		if (astrcmpi_n(h, needle, n) == 0)
			return true;
	return false;
}

/* The shaders in `dir` for a filter or a transition, by name, in `category`
 * (if any) and matching `search` (if any, against name and category). An
 * .effect with a .shader of the same name is listed once, as the .shader. */
static void list_shaders(const char *dir, bool transitions, const char *search, const char *category,
			 shader_list_t *out)
{
	da_init(*out);
	/* Templates and examples in the bundled folder are starting points, not
	 * shaders to use; in the person's own folders everything is listed. */
	char *bundled_dir = examples_dir();
	const bool bundled = same_folder(dir, bundled_dir);
	bfree(bundled_dir);
	library_t lib;
	library_load(dir, &lib);
	os_dir_t *d = os_opendir(dir);
	if (!d) {
		library_free(&lib);
		return;
	}
	struct os_dirent *ent;
	while ((ent = os_readdir(d)) != NULL) {
		if (ent->directory)
			continue;
		const char *n = ent->d_name;
		if (!has_ext(n, ".shader") && !has_ext(n, ".effect"))
			continue;
		if (bundled && (contains_ci(n, "template") || contains_ci(n, "example")))
			continue;
		struct dstr path = {0};
		dstr_printf(&path, "%s/%s", dir, n);
		if (has_ext(n, ".effect")) {
			struct dstr twin = {0};
			dstr_ncopy(&twin, path.array, path.len - strlen(".effect"));
			dstr_cat(&twin, ".shader");
			bool has_twin = os_file_exists(twin.array);
			dstr_free(&twin);
			if (has_twin) {
				dstr_free(&path);
				continue;
			}
		}
		if (file_is_transition(path.array) != transitions) {
			dstr_free(&path);
			continue;
		}
		const struct library_item *it = library_find(&lib, path.array);
		size_t rank = SIZE_MAX;
		if (it && *it->category) {
			/* first appearance of the category in the file */
			for (size_t c = 0; c < lib.num && rank == SIZE_MAX; c++)
				if (astrcmpi(lib.array[c].category, it->category) == 0)
					rank = c;
		}
		struct shader_entry e = {path.array,
					 it && *it->name ? bstrdup(it->name) : friendly_shader_name(path.array),
					 bstrdup(it ? it->category : ""), rank, it ? it->cost : 0};
		da_push_back(*out, &e);
	}
	os_closedir(d);
	library_free(&lib);
	qsort(out->array, out->num, sizeof(struct shader_entry), cmp_entry);

	/* Same name twice: add the file name. */
	for (size_t i = 0; i + 1 < out->num; i++) {
		if (astrcmpi(out->array[i].label, out->array[i + 1].label) != 0)
			continue;
		for (size_t k = i; k <= i + 1; k++) {
			const char *base = strrchr(out->array[k].path, '/');
			struct dstr l = {0};
			dstr_printf(&l, "%s (%s)", out->array[k].label, base ? base + 1 : out->array[k].path);
			bfree(out->array[k].label);
			out->array[k].label = l.array;
		}
	}
	/* In category order (as library.ini lists them), then by name. */
	qsort(out->array, out->num, sizeof(struct shader_entry), cmp_entry_ranked);
	size_t w = 0;
	for (size_t i = 0; i < out->num; i++) {
		struct shader_entry *e = &out->array[i];
		bool keep = (!category || !*category || astrcmpi(e->category, category) == 0) &&
			    (contains_ci(e->label, search) || (*e->category && contains_ci(e->category, search)));
		if (keep) {
			out->array[w++] = *e;
		} else {
			bfree(e->path);
			bfree(e->label);
			bfree(e->category);
		}
	}
	out->num = w;
}

typedef DARRAY(char *) category_list_t;

/* The categories used in a folder's library.ini, in file order. */
static void library_categories(const char *dir, category_list_t *out)
{
	library_t lib;
	library_load(dir, &lib);
	for (size_t i = 0; i < lib.num; i++) {
		const char *c = lib.array[i].category;
		bool seen = !*c;
		for (size_t k = 0; k < out->num && !seen; k++)
			seen = astrcmpi(out->array[k], c) == 0;
		if (!seen) {
			char *copy = bstrdup(c);
			da_push_back(*out, &copy);
		}
	}
	library_free(&lib);
}

/* The folder whose shaders the list offers. */
static char *library_dir(obs_data_t *settings)
{
	const char *file = obs_data_get_string(settings, "shader_file_name");
	if (obs_data_get_bool(settings, "from_file") && file && *file) {
		struct dstr d = {0};
		dstr_copy(&d, file);
		char *slash = strrchr(d.array, '/');
		char *bslash = strrchr(d.array, '\\');
		if (bslash > slash)
			slash = bslash;
		if (slash) {
			dstr_resize(&d, slash - d.array);
			if (os_file_exists(d.array))
				return d.array;
		}
		dstr_free(&d);
	}
	return examples_dir();
}

static bool is_default_filter_name(const char *name)
{
	const char *defaults[] = {obs_module_text("ShaderFilter"), "User-defined shader", "Shader"};
	for (size_t i = 0; i < sizeof(defaults) / sizeof(defaults[0]); i++) {
		size_t l = strlen(defaults[i]);
		if (strncmp(name, defaults[i], l) != 0)
			continue;
		const char *rest = name + l;
		if (!*rest)
			return true;
		if (*rest != ' ' || !rest[1])
			continue;
		bool digits = true;
		for (const char *c = rest + 1; *c; c++)
			digits = digits && *c >= '0' && *c <= '9';
		if (digits)
			return true;
	}
	return false;
}

/* The name the filter would get for its shader, unique among its siblings. */
static char *auto_filter_name(struct shader_filter_data *filter, const char *path)
{
	char *base = shader_display_name(path);
	struct dstr name = {0};
	dstr_copy(&name, base);
	obs_source_t *parent = obs_filter_get_parent(filter->context);
	for (int k = 2; parent; k++) {
		obs_source_t *other = obs_source_get_filter_by_name(parent, name.array);
		bool clash = other && other != filter->context;
		obs_source_release(other);
		if (!clash)
			break;
		dstr_printf(&name, "%s %d", base, k);
	}
	bfree(base);
	return name.array;
}

/* Name the filter after its shader, unless the person has named it: only a
 * default name or the name this function gave it last time is replaced. */
static void auto_name_filter(struct shader_filter_data *filter, obs_data_t *settings, const char *path, bool force)
{
	if (filter->transition || !path || !*path)
		return;
	const char *cur = obs_source_get_name(filter->context);
	const char *last = obs_data_get_string(settings, "auto_name");
	struct dstr marked = {0};
	dstr_printf(&marked, obs_module_text("ShaderFilter.ErrorName"), last);
	const bool automatic = is_default_filter_name(cur) || strcmp(cur, last) == 0 || (*last && strcmp(cur, marked.array) == 0);
	dstr_free(&marked);
	if (!force && !automatic)
		return;
	char *name = auto_filter_name(filter, path);
	if (strcmp(cur, name) != 0)
		obs_source_set_name(filter->context, name);
	obs_data_set_string(settings, "auto_name", name);
	bfree(name);
}

/* Switch the filter to a shader file, as if chosen in the list. */
static void choose_shader_file(struct shader_filter_data *filter, obs_data_t *settings, const char *path)
{
	obs_data_set_bool(settings, "from_file", true);
	obs_data_set_string(settings, "shader_file_name", path);
	obs_data_set_string(settings, "shader_pick", path);
	obs_data_set_bool(settings, "override_entire_effect", path_is_effect(path));
	filter->last_from_file = true;
	if (dstr_cmp(&filter->last_path, path) != 0 || !filter->effect)
		filter->reload_effect = true;
	dstr_copy(&filter->last_path, path);
	auto_name_filter(filter, settings, path, false);
}

/* A greyed heading in the Shader list, which can't be chosen. */
static void add_list_heading(obs_property_t *pick, const char *title)
{
	struct dstr h = {0};
	dstr_printf(&h, obs_module_text("ShaderFilter.Heading"), title);
	size_t idx = obs_property_list_add_string(pick, h.array, PICK_HEADING);
	obs_property_list_item_disable(pick, idx, true);
	dstr_free(&h);
}

/* A shader in the Shader list, with its cost rating if it has one. */
static void add_shader_entry(obs_property_t *pick, const struct shader_entry *e)
{
	static const char *cost_fmt[] = {"%s", "ShaderFilter.CostMedium", "ShaderFilter.CostHeavy",
					 "ShaderFilter.CostVeryHeavy"};
	struct dstr label = {0};
	dstr_printf(&label, e->cost > 0 && e->cost <= 3 ? obs_module_text(cost_fmt[e->cost]) : "%s", e->label);
	obs_property_list_add_string(pick, label.array, e->path);
	dstr_free(&label);
}

/* Fill the "Shader" list for the current settings; returns how many shaders
 * it lists (not counting the fixed entries and headings) and sets *pos to the
 * current shader's place among them (1-based; 0 if not among them). */
static size_t fill_shader_list(obs_property_t *pick, obs_data_t *settings, bool transition, size_t *pos)
{
	*pos = 0;
	obs_property_list_clear(pick);
	const bool from_file = obs_data_get_bool(settings, "from_file");
	const char *file = obs_data_get_string(settings, "shader_file_name");
	const bool has_file = from_file && file && *file;
	const bool has_code = obs_data_has_user_value(settings, "shader_text");

	const bool code_in_use = !from_file && has_code;
	size_t top = 0;
	if (!has_file && !code_in_use) {
		obs_property_list_add_string(pick, obs_module_text("ShaderFilter.ChooseShader"), PICK_NONE);
		top++;
	}
	if (has_code) {
		obs_property_list_add_string(pick, obs_module_text("ShaderFilter.InlineCode"), PICK_INLINE);
		top++;
	}

	/* The bundled library always, by category; then, when the shader comes
	 * from a folder of the person's own, that folder's shaders. */
	char *bundled = examples_dir();
	char *own = library_dir(settings);
	const bool own_folder = bundled && own && !same_folder(own, bundled);
	const bool narrow = obs_data_get_bool(settings, "browse_shaders");
	const char *search = narrow ? obs_data_get_string(settings, "shader_search") : "";
	const char *category = narrow ? obs_data_get_string(settings, "shader_category") : "";
	shader_list_t list, mine;
	list_shaders(bundled, transition, search, category, &list);
	da_init(mine);
	if (own_folder)
		list_shaders(own, transition, search, category, &mine);

	bool listed = false;
	bool any_category = false;
	for (size_t i = 0; i < list.num; i++)
		any_category = any_category || *list.array[i].category;
	const char *last_category = NULL;
	for (size_t i = 0; i < list.num; i++) {
		const char *c = list.array[i].category;
		if (any_category && (!last_category || astrcmpi(c, last_category) != 0)) {
			add_list_heading(pick, *c ? c : obs_module_text("ShaderFilter.Uncategorised"));
			last_category = c;
		}
		add_shader_entry(pick, &list.array[i]);
		if (has_file && strcmp(list.array[i].path, file) == 0) {
			listed = true;
			*pos = i + 1;
		}
	}
	if (mine.num) {
		const char *folder = strrchr(own, '/');
		const char *folder2 = strrchr(own, '\\');
		if (folder2 > folder)
			folder = folder2;
		add_list_heading(pick, folder ? folder + 1 : own);
		for (size_t i = 0; i < mine.num; i++) {
			add_shader_entry(pick, &mine.array[i]);
			if (has_file && strcmp(mine.array[i].path, file) == 0) {
				listed = true;
				*pos = list.num + i + 1;
			}
		}
	}
	if (has_file && !listed) {
		/* The current shader always appears, even when filtered out. */
		char *name = shader_display_name(file);
		struct dstr label = {0};
		dstr_printf(&label, os_file_exists(file) ? "%s" : obs_module_text("ShaderFilter.Missing"), name);
		obs_property_list_insert_string(pick, top, label.array, file);
		dstr_free(&label);
		bfree(name);
	}
	/* Files elsewhere, last. */
	if (any_category)
		add_list_heading(pick, obs_module_text("ShaderFilter.OwnFiles"));
	obs_property_list_add_string(pick, obs_module_text("ShaderFilter.OtherFile"), PICK_OTHER);

	struct dstr help = {0};
	if (has_file)
		dstr_printf(&help, obs_module_text("ShaderFilter.ShaderHelpFile"), file);
	else
		dstr_printf(&help, obs_module_text("ShaderFilter.ShaderHelpFolder"), bundled);
	if (any_category) {
		dstr_cat(&help, "\n\n");
		dstr_cat(&help, obs_module_text("ShaderFilter.CostHelp"));
	}
	obs_property_set_long_description(pick, help.array);
	dstr_free(&help);
	size_t n = list.num + mine.num;
	free_shader_list(&list);
	free_shader_list(&mine);
	bfree(bundled);
	bfree(own);
	return n;
}

/* Where the current shader is in the list ("12 of 160 shaders"), or how many
 * match while narrowing it. */
static void update_browse_status(obs_properties_t *props, obs_data_t *settings, size_t n, size_t pos)
{
	obs_property_t *status = obs_properties_get(props, "browse_status");
	if (!status)
		return;
	const char *search = obs_data_get_string(settings, "shader_search");
	const char *category = obs_data_get_string(settings, "shader_category");
	const bool narrowed = (search && *search) || (category && *category);
	/* "8 of 11 in Blur & Glow, matching "blur"" / "154 shaders" */
	struct dstr text = {0};
	if (n == 0) {
		dstr_copy(&text, obs_module_text("ShaderFilter.BrowseNone"));
	} else {
		if (pos)
			dstr_printf(&text, obs_module_text("ShaderFilter.BrowsePos"), (int)pos, (int)n);
		else
			dstr_printf(&text, obs_module_text(n == 1 ? "ShaderFilter.BrowseOne" : "ShaderFilter.BrowseMany"),
				    (int)n);
		if (category && *category)
			dstr_catf(&text, obs_module_text("ShaderFilter.BrowseIn"), category);
		if (search && *search)
			dstr_catf(&text, obs_module_text("ShaderFilter.BrowseMatching"), search);
		if (!pos) {
			const char *file = obs_data_get_string(settings, "shader_file_name");
			if (obs_data_get_bool(settings, "from_file") && file && *file) {
				char *name = shader_display_name(file);
				dstr_catf(&text, obs_module_text("ShaderFilter.BrowseNotAmong"), name);
				bfree(name);
			}
		}
	}
	obs_property_set_description(status, text.array);
	obs_property_text_set_info_type(status, n == 0 ? OBS_TEXT_INFO_WARNING : OBS_TEXT_INFO_NORMAL);
	obs_property_set_visible(status, obs_data_get_bool(settings, "browse_shaders"));
	dstr_free(&text);
}

static bool shader_search_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	struct shader_filter_data *filter = obs_properties_get_param(props);
	obs_property_t *pick = obs_properties_get(props, "shader_pick");
	if (!filter || !pick)
		return false;
	size_t pos;
	size_t n = fill_shader_list(pick, settings, filter->transition, &pos);
	update_browse_status(props, settings, n, pos);
	return true;
}

static bool browse_shaders_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	bool show = obs_data_get_bool(settings, "browse_shaders");
	struct shader_filter_data *bf = obs_properties_get_param(props);
	if (bf && show != bf->browse_shown) {
		bf->browse_kept = show;
		bf->browse_shown = show;
	}
	const char *keys[] = {"shader_category", "shader_search", "browse_status"};
	for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
		obs_property_t *q = obs_properties_get(props, keys[i]);
		if (q)
			obs_property_set_visible(q, show);
	}
	return shader_search_changed(props, p, settings);
}

static bool shader_pick_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	struct shader_filter_data *filter = obs_properties_get_param(props);
	if (!filter)
		return false;
	const char *pick = obs_data_get_string(settings, "shader_pick");
	obs_property_set_visible(obs_properties_get(props, "shader_file_name"), strcmp(pick, PICK_OTHER) == 0);
	if (strcmp(pick, PICK_INLINE) == 0) {
		if (obs_data_get_bool(settings, "from_file")) {
			obs_data_set_bool(settings, "from_file", false);
			filter->last_from_file = false;
			filter->reload_effect = true;
		}
		return true;
	}
	if (!*pick || strcmp(pick, PICK_OTHER) == 0)
		return true;
	if (strcmp(pick, PICK_HEADING) == 0)
		return false;
	if (strcmp(pick, obs_data_get_string(settings, "shader_file_name")) == 0 && obs_data_get_bool(settings, "from_file"))
		return true;
	char *path = bstrdup(pick);
	choose_shader_file(filter, settings, path);
	bfree(path);
	return true;
}

static bool shader_filter_file_name_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	struct shader_filter_data *filter = obs_properties_get_param(props);
	const char *new_file_name = obs_data_get_string(settings, obs_property_name(p));
	if (!filter || !*new_file_name)
		return false;
	if (dstr_cmp(&filter->last_path, new_file_name) != 0 || !obs_data_get_bool(settings, "from_file")) {
		char *path = bstrdup(new_file_name);
		choose_shader_file(filter, settings, path);
		bfree(path);
		return true;
	}
	return false;
}

static bool rename_after_shader_clicked(obs_properties_t *props, obs_property_t *property, void *data)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(property);
	struct shader_filter_data *filter = data;
	obs_data_t *settings = obs_source_get_settings(filter->context);
	if (obs_data_get_bool(settings, "from_file"))
		auto_name_filter(filter, settings, obs_data_get_string(settings, "shader_file_name"), true);
	obs_data_release(settings);
	return true;
}

static bool show_compiler_messages_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	bool show = obs_data_get_bool(settings, "show_compiler_messages");
	obs_property_t *e = obs_properties_get(props, "error_details_text");
	obs_property_t *w = obs_properties_get(props, "warning_details_text");
	if (e)
		obs_property_set_visible(e, show);
	if (w)
		obs_property_set_visible(w, show);
	return true;
}

static bool show_code_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	bool show = obs_data_get_bool(settings, "show_code");
	const char *keys[] = {"shader_text", "shader_convert", "reload_code"};
	for (size_t i = 0; i < 3; i++) {
		obs_property_t *q = obs_properties_get(props, keys[i]);
		if (q)
			obs_property_set_visible(q, show);
	}
	return true;
}

static bool show_expand_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	bool show = obs_data_get_bool(settings, "show_expand");
	const char *keys[] = {"expand_left", "expand_right", "expand_top", "expand_bottom"};
	for (size_t i = 0; i < 4; i++)
		obs_property_set_visible(obs_properties_get(props, keys[i]), show);
	return true;
}

static bool show_advanced_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	obs_property_set_visible(obs_properties_get(props, "advanced"), obs_data_get_bool(settings, "show_advanced"));
	return true;
}

/* "Show Full Compiler Output" and the output itself, hidden until ticked. */
static void add_compiler_messages(obs_properties_t *props, obs_data_t *settings, const char *errs, const char *warns)
{
	obs_property_t *show = obs_properties_add_bool(props, "show_compiler_messages",
						       obs_module_text("ShaderFilter.ShowCompilerMessages"));
	obs_property_set_modified_callback(show, show_compiler_messages_changed);
	const bool visible = obs_data_get_bool(settings, "show_compiler_messages");
	if (errs && *errs) {
		obs_property_t *e = obs_properties_add_text(props, "error_details_text", errs, OBS_TEXT_INFO);
		obs_property_text_set_info_type(e, OBS_TEXT_INFO_ERROR);
		obs_property_set_visible(e, visible);
	}
	if (warns && *warns) {
		obs_property_t *w = obs_properties_add_text(props, "warning_details_text", warns, OBS_TEXT_INFO);
		obs_property_text_set_info_type(w, OBS_TEXT_INFO_WARNING);
		obs_property_set_visible(w, visible);
	}
}

/* Presets: "<shader file name without extension>.presets.ini" next to the
 * shader, one [section] per preset, "parameter = value" lines in it. */
struct shader_preset {
	char *name;
	obs_data_t *values; /* parameter name -> value text */
};
typedef DARRAY(struct shader_preset) preset_list_t;

static void presets_free(preset_list_t *list)
{
	for (size_t i = 0; i < list->num; i++) {
		bfree(list->array[i].name);
		obs_data_release(list->array[i].values);
	}
	da_free(*list);
}

static void presets_load(const char *shader_path, preset_list_t *out)
{
	da_init(*out);
	if (!shader_path || !*shader_path)
		return;
	struct dstr path = {0};
	dstr_copy(&path, shader_path);
	const char *slash = strrchr(path.array, '/');
	const char *bslash = strrchr(path.array, '\\');
	if (bslash > slash)
		slash = bslash;
	char *dot = strrchr(path.array, '.');
	if (dot && (!slash || dot > slash))
		dstr_resize(&path, dot - path.array);
	dstr_cat(&path, ".presets.ini");
	char *text = os_quick_read_utf8_file(path.array);
	dstr_free(&path);
	if (!text)
		return;
	char **lines = strlist_split(text, '\n', false);
	for (char **l = lines; l && *l; l++) {
		const char *line = *l;
		while (*line == ' ' || *line == '\t')
			line++;
		if (!*line || *line == ';' || *line == '#' || *line == '\r')
			continue;
		if (*line == '[') {
			const char *end = strchr(line, ']');
			if (!end)
				continue;
			struct shader_preset preset = {trimmed(line + 1, end - line - 1), obs_data_create()};
			da_push_back(*out, &preset);
			continue;
		}
		const char *eq = strchr(line, '=');
		if (!eq || !out->num)
			continue;
		char *key = trimmed(line, eq - line);
		char *value = trimmed(eq + 1, strlen(eq + 1));
		size_t vlen = strlen(value);
		while (vlen && (value[vlen - 1] == '\r' || value[vlen - 1] == ' '))
			value[--vlen] = 0;
		obs_data_set_string(out->array[out->num - 1].values, key, value);
		bfree(key);
		bfree(value);
	}
	strlist_free(lines);
	bfree(text);
}

static struct effect_param_data *find_param(struct shader_filter_data *filter, const char *name)
{
	for (size_t i = 0; i < filter->stored_param_list.num; i++)
		if (strcmp(filter->stored_param_list.array[i].name.array, name) == 0)
			return &filter->stored_param_list.array[i];
	return NULL;
}

static bool preset_bool(const char *v)
{
	return astrcmpi(v, "true") == 0 || astrcmpi(v, "yes") == 0 || atof(v) != 0.0;
}

/* Whether the filter's current values are the preset's (so the list shows it). */
static bool preset_matches(struct shader_filter_data *filter, obs_data_t *settings, const struct shader_preset *preset)
{
	size_t known = 0;
	for (obs_data_item_t *it = obs_data_first(preset->values); it; obs_data_item_next(&it)) {
		const char *key = obs_data_item_get_name(it);
		const char *v = obs_data_item_get_string(it);
		struct effect_param_data *param = find_param(filter, key);
		if (!param)
			continue;
		known++;
		bool same = true;
		if (param->type == GS_SHADER_PARAM_FLOAT)
			same = fabs(obs_data_get_double(settings, key) - atof(v)) < 1e-4;
		else if (param->type == GS_SHADER_PARAM_INT)
			same = obs_data_get_int(settings, key) == (long long)floor(atof(v) + 0.5);
		else if (param->type == GS_SHADER_PARAM_BOOL)
			same = obs_data_get_bool(settings, key) == preset_bool(v);
		if (!same) {
			obs_data_item_release(&it);
			return false;
		}
	}
	return known > 0;
}

static void preset_apply(struct shader_filter_data *filter, obs_data_t *settings, const struct shader_preset *preset)
{
	for (obs_data_item_t *it = obs_data_first(preset->values); it; obs_data_item_next(&it)) {
		const char *key = obs_data_item_get_name(it);
		const char *v = obs_data_item_get_string(it);
		struct effect_param_data *param = find_param(filter, key);
		if (!param)
			continue;
		if (param->type == GS_SHADER_PARAM_FLOAT)
			obs_data_set_double(settings, key, atof(v));
		else if (param->type == GS_SHADER_PARAM_INT)
			obs_data_set_int(settings, key, (long long)floor(atof(v) + 0.5));
		else if (param->type == GS_SHADER_PARAM_BOOL)
			obs_data_set_bool(settings, key, preset_bool(v));
	}
}

/* The filter whose panel a (possibly nested) properties object belongs to. */
static struct shader_filter_data *props_filter(obs_properties_t *props)
{
	for (; props; props = obs_properties_get_parent(props)) {
		void *param = obs_properties_get_param(props);
		if (param)
			return param;
	}
	return NULL;
}

static bool shader_preset_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	struct shader_filter_data *filter = props_filter(props);
	const char *name = obs_data_get_string(settings, "shader_preset");
	if (!filter || !name || !*name || !obs_data_get_bool(settings, "from_file"))
		return false;
	preset_list_t presets;
	presets_load(obs_data_get_string(settings, "shader_file_name"), &presets);
	bool applied = false;
	for (size_t i = 0; i < presets.num && !applied; i++) {
		if (strcmp(presets.array[i].name, name) == 0 && !preset_matches(filter, settings, &presets.array[i])) {
			preset_apply(filter, settings, &presets.array[i]);
			applied = true;
		}
	}
	presets_free(&presets);
	return applied;
}

/* Whether a shader file is one of those shipped with the plugin. */
static bool is_bundled_shader(const char *path)
{
	if (!path || !*path)
		return false;
	struct dstr dir = {0};
	dstr_copy(&dir, path);
	char *slash = strrchr(dir.array, '/');
	char *bslash = strrchr(dir.array, '\\');
	if (bslash > slash)
		slash = bslash;
	bool yes = false;
	if (slash) {
		dstr_resize(&dir, slash - dir.array);
		char *bundled = examples_dir();
		yes = same_folder(dir.array, bundled);
		bfree(bundled);
	}
	dstr_free(&dir);
	return yes;
}

/* Whether the library marks this shader as drawing outside the image. */
static bool shader_wants_space(const char *path)
{
	struct dstr dir = {0};
	dstr_copy(&dir, path);
	char *slash = strrchr(dir.array, '/');
	char *bslash = strrchr(dir.array, '\\');
	if (bslash > slash)
		slash = bslash;
	bool space = false;
	if (slash) {
		dstr_resize(&dir, slash - dir.array);
		library_t lib;
		library_load(dir.array, &lib);
		const struct library_item *it = library_find(&lib, path);
		space = it && it->space;
		library_free(&lib);
	}
	dstr_free(&dir);
	return space;
}

static bool shader_filter_text_changed(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
	UNUSED_PARAMETER(p);
	struct shader_filter_data *filter = obs_properties_get_param(props);
	if (!filter)
		return false;

	const char *shader_text = obs_data_get_string(settings, "shader_text");
	bool can_convert = strstr(shader_text, "void mainImage( out vec4") || strstr(shader_text, "void mainImage(out vec4") ||
			   strstr(shader_text, "void main()") || strstr(shader_text, "vec4 effect(vec4");
	obs_property_t *shader_convert = obs_properties_get(props, "shader_convert");
	bool visible = obs_property_visible(obs_properties_get(props, "shader_text"));
	if (obs_property_visible(shader_convert) != (can_convert && visible)) {
		obs_property_set_visible(shader_convert, can_convert && visible);
		return true;
	}
	return false;
}

static bool shader_filter_reload_effect_clicked(obs_properties_t *props, obs_property_t *property, void *data)
{
	UNUSED_PARAMETER(props);
	UNUSED_PARAMETER(property);
	struct shader_filter_data *filter = data;

	filter->reload_effect = true;

	obs_source_update(filter->context, NULL);

	return false;
}

static bool add_source_to_list(void *data, obs_source_t *source)
{
	obs_property_t *p = data;
	const char *name = obs_source_get_name(source);
	size_t count = obs_property_list_item_count(p);
	size_t idx = 0;
	while (idx < count && strcmp(name, obs_property_list_item_string(p, idx)) > 0)
		idx++;
	obs_property_list_insert_string(p, idx, name, name);
	return true;
}

static bool is_var_char(char ch)
{
	return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_';
}

static void convert_if_defined(struct dstr *effect_text)
{
	char *pos = strstr(effect_text->array, "#if defined(");
	while (pos) {
		size_t diff = pos - effect_text->array;
		char *ch = strstr(effect_text->array + diff + 12, ")\n");
		pos = strstr(effect_text->array + diff + 12, "#if defined(");
		if (ch && (!pos || ch < pos)) {
			*ch = ' ';
			dstr_remove(effect_text, diff, 12);
			dstr_insert(effect_text, diff, "#ifdef ");
			pos = strstr(effect_text->array + diff + 5, "#if defined(");
		}
	}
}

static void convert_atan(struct dstr *effect_text)
{
	char *pos = strstr(effect_text->array, "atan(");
	while (pos) {
		if (is_var_char(*(pos - 1))) {
			pos = strstr(pos + 5, "atan(");
			continue;
		}
		size_t diff = pos - effect_text->array;
		char *comma = strstr(pos + 5, ",");
		char *divide = strstr(pos + 5, "/");
		if (!comma && !divide)
			return;

		int depth = 0;
		char *open = strstr(pos + 5, "(");
		char *close = strstr(pos + 5, ")");
		if (!close)
			return;
		do {
			while (open && open < close) {
				depth++;
				open = strstr(open + 1, "(");
			}
			while (depth > 0 && close && (!open || close < open)) {
				depth--;
				if (depth == 0 && (!comma || comma < close))
					comma = strstr(close + 1, ",");
				if (depth == 0 && (!divide || divide < close))
					divide = strstr(close + 1, "/");
				if (comma && open && comma > open && comma < close)
					comma = NULL;
				if (divide && open && divide > open && divide < close)
					divide = NULL;

				open = strstr(close + 1, "(");
				close = strstr(close + 1, ")");
			}
		} while (depth > 0 && close);

		if (close && comma && comma < close && (!open || comma < open)) {
			//*comma = '/';
			dstr_insert(effect_text, diff + 4, "2");
		}
		if (close && divide && divide < close && (!open || divide < open)) {
			*divide = ',';
			dstr_insert(effect_text, diff + 4, "2");
		}

		pos = strstr(effect_text->array + diff + 5, "atan(");
	}
}

static void insert_begin_of_block(struct dstr *effect_text, size_t diff, char *insert)
{
	int depth = 0;
	char *ch = effect_text->array + diff;
	while (ch > effect_text->array && (*ch == ' ' || *ch == '\t'))
		ch--;
	while (ch > effect_text->array) {
		while (*ch != '=' && *ch != '(' && *ch != ')' && *ch != '+' && *ch != '-' && *ch != '/' && *ch != '*' &&
		       *ch != ' ' && *ch != '\t' && ch > effect_text->array)
			ch--;
		if (*ch == '(') {
			if (depth == 0) {
				dstr_insert(effect_text, ch - effect_text->array + 1, insert);
				return;
			}
			ch--;
			depth--;
		} else if (*ch == ')') {
			ch--;
			depth++;
		} else if (*ch == '=') {
			dstr_insert(effect_text, ch - effect_text->array + 1, insert);
			return;
		} else if (*ch == '+' || *ch == '-' || *ch == '/' || *ch == '*' || *ch == ' ' || *ch == '\t') {
			if (depth == 0) {
				dstr_insert(effect_text, ch - effect_text->array + 1, insert);
				return;
			}
			ch--;
		}
	}
}

static void insert_end_of_block(struct dstr *effect_text, size_t diff, char *insert)
{
	int depth = 0;
	char *ch = effect_text->array + diff;
	while (*ch == ' ' || *ch == '\t')
		ch++;
	while (*ch != 0) {
		while (*ch != ';' && *ch != '(' && *ch != ')' && *ch != '+' && *ch != '-' && *ch != '/' && *ch != '*' &&
		       *ch != ' ' && *ch != '\t' && *ch != ',' && *ch != 0)
			ch++;
		if (*ch == '(') {
			ch++;
			depth++;
		} else if (*ch == ')') {
			if (depth == 0) {
				dstr_insert(effect_text, ch - effect_text->array, insert);
				return;
			}
			ch++;
			depth--;
		} else if (*ch == ';') {
			dstr_insert(effect_text, ch - effect_text->array, insert);
			return;
		} else if (*ch == '+' || *ch == '-' || *ch == '/' || *ch == '*' || *ch == ' ' || *ch == '\t' || *ch == ',') {
			if (depth == 0) {
				dstr_insert(effect_text, ch - effect_text->array, insert);
				return;
			}
			ch++;
		}
	}
}

static void convert_mat_mul_var(struct dstr *effect_text, struct dstr *var_function_name)
{
	char *pos = strstr(effect_text->array, var_function_name->array);
	while (pos) {
		if (is_var_char(*(pos - 1)) || is_var_char(*(pos + var_function_name->len))) {
			pos = strstr(pos + var_function_name->len, var_function_name->array);
			continue;
		}
		size_t diff = pos - effect_text->array;
		char *ch = pos + var_function_name->len;
		while (*ch == ' ' || *ch == '\t')
			ch++;
		if (*ch == '*' && *(ch + 1) != '=') {
			size_t diff3 = ch - effect_text->array + 1;
			*ch = ',';
			insert_end_of_block(effect_text, diff3, ")");
			dstr_insert(effect_text, diff, "mul(");
			pos = strstr(effect_text->array + diff + 4 + var_function_name->len, var_function_name->array);
			continue;
		}
		ch = pos - 1;
		while ((*ch == ' ' || *ch == '\t') && ch > effect_text->array)
			ch--;
		if (*ch == '=' && *(ch - 1) == '*') {
			char *end = ch - 2;
			while ((*end == ' ' || *end == '\t') && end > effect_text->array)
				end--;
			char *start = end;
			while ((is_var_char(*start) || *start == '.') && start > effect_text->array)
				start--;
			start++;
			end++;

			diff = ch - 1 - effect_text->array;

			struct dstr insert = {0};
			dstr_init_copy(&insert, "= mul(");
			dstr_ncat(&insert, start, end - start);
			dstr_cat(&insert, ",");
			dstr_remove(effect_text, diff, 2);
			dstr_insert(effect_text, diff, insert.array);

			char *line_end = effect_text->array + diff;
			while (*line_end != ';' && *line_end != 0)
				line_end++;

			dstr_insert(effect_text, line_end - effect_text->array, ")");

			pos = strstr(effect_text->array + diff + insert.len + 1 + var_function_name->len, var_function_name->array);
			dstr_free(&insert);

			continue;
		} else if (*ch == '*') {
			size_t diff2 = ch - effect_text->array - 1;
			*ch = ',';
			insert_end_of_block(effect_text, diff + var_function_name->len, ")");
			insert_begin_of_block(effect_text, diff2, "mul(");

			pos = strstr(effect_text->array + diff + 4 + var_function_name->len, var_function_name->array);
			continue;
		}

		pos = strstr(effect_text->array + diff + var_function_name->len, var_function_name->array);
	}
}

static void convert_mat_mul(struct dstr *effect_text, char *var_type)
{
	size_t len = strlen(var_type);
	char *pos = strstr(effect_text->array, var_type);
	while (pos) {
		if (is_var_char(*(pos - 1))) {
			pos = strstr(pos + len, var_type);
			continue;
		}
		size_t diff = pos - effect_text->array;
		char *begin = pos + len;
		if (*begin == '(') {
			char *ch = pos - 1;
			while ((*ch == ' ' || *ch == '\t') && ch > effect_text->array)
				ch--;
			if (*ch == '=' && *(ch - 1) == '*') {
				// mat constructor with *= in front of it
				char *end = ch - 2;
				while ((*end == ' ' || *end == '\t') && end > effect_text->array)
					end--;
				char *start = end;
				while ((is_var_char(*start) || *start == '.') && start > effect_text->array)
					start--;
				start++;
				end++;

				size_t diff2 = ch - effect_text->array - 1;

				struct dstr insert = {0};
				dstr_init_copy(&insert, "= mul(");
				dstr_ncat(&insert, start, end - start);
				dstr_cat(&insert, ",");
				dstr_remove(effect_text, diff2, 2);
				dstr_insert(effect_text, diff2, insert.array);

				char *line_end = effect_text->array + diff2;
				while (*line_end != ';' && *line_end != 0)
					line_end++;

				dstr_insert(effect_text, line_end - effect_text->array, ")");

				pos = strstr(effect_text->array + diff + insert.len + len + 1, var_type);
				dstr_free(&insert);

				continue;
			} else if (*ch == '*') {
				// mat constructor with * in front of it
				size_t diff2 = ch - effect_text->array - 1;
				*ch = ',';
				insert_end_of_block(effect_text, diff + len, ")");
				insert_begin_of_block(effect_text, diff2, "mul(");

				pos = strstr(effect_text->array + diff + len + 4, var_type);
				continue;
			}

			int depth = 1;
			ch = begin + 1;
			while (*ch != 0) {
				while (*ch != ';' && *ch != '(' && *ch != ')' && *ch != '+' && *ch != '-' && *ch != '/' &&
				       *ch != '*' && *ch != 0)
					ch++;
				if (*ch == '(') {
					ch++;
					depth++;
				} else if (*ch == ')') {
					if (depth == 0) {
						break;
					}
					ch++;
					depth--;
				} else if (*ch == '*') {
					if (depth == 0) {
						//mat constructor follow by *
						*ch = ',';
						insert_end_of_block(effect_text, ch - effect_text->array + 1, ")");
						dstr_insert(effect_text, diff, "mul(");
						break;
					}
					ch++;
				} else if (*ch == ';') {
					break;
				} else if (depth == 0) {
					break;
				} else if (*ch != 0) {
					ch++;
				}
			}
		}
		if (*begin != ' ' && *begin != '\t') {
			pos = strstr(pos + len, var_type);
			continue;
		}
		while (*begin == ' ' || *begin == '\t')
			begin++;
		if (!is_var_char(*begin)) {
			pos = strstr(pos + len, var_type);
			continue;
		}
		char *end = begin;
		while (is_var_char(*end))
			end++;
		struct dstr var_function_name = {0};
		dstr_ncat(&var_function_name, begin, end - begin);

		convert_mat_mul_var(effect_text, &var_function_name);
		dstr_free(&var_function_name);

		pos = strstr(effect_text->array + diff + len, var_type);
	}
}

static bool is_in_function(struct dstr *effect_text, size_t diff)
{
	char *pos = effect_text->array + diff;
	int depth = 0;
	while (depth >= 0) {
		char *end = strstr(pos, "}");
		char *begin = strstr(pos, "{");
		if (end && begin && begin < end) {
			pos = begin + 1;
			depth++;
		} else if (end && begin && end < begin) {
			pos = end + 1;
			depth--;
		} else if (end) {
			pos = end + 1;
			depth--;
		} else if (begin && depth < 0) {
			break;
		} else if (begin) {
			pos = begin + 1;
			depth++;
		} else {
			break;
		}
	}
	return depth != 0;
}

static void convert_init(struct dstr *effect_text, char *name)
{
	const size_t len = strlen(name);
	char extra = 0;
	char *pos = strstr(effect_text->array, name);
	while (pos) {
		size_t diff = pos - effect_text->array;
		if (pos > effect_text->array && is_var_char(*(pos - 1))) {
			pos = strstr(effect_text->array + diff + len, name);
			continue;
		}
		char *ch = pos + len;
		if (*ch >= '2' && *ch <= '9') {
			extra = *ch;
			ch++;
		} else {
			extra = 0;
		}
		if (*ch != ' ' && *ch != '\t') {
			pos = strstr(effect_text->array + diff + len, name);
			continue;
		}
		char *begin = pos - 1;
		while (begin > effect_text->array && (*begin == ' ' || *begin == '\t'))
			begin--;
		if (*begin == '(' || *begin == ',' ||
		    (is_var_char(*begin) && memcmp("uniform", begin - 6, 7) != 0 && memcmp("const", begin - 4, 5) != 0)) {
			pos = strstr(effect_text->array + diff + len, name);
			continue;
		}
		if (!is_in_function(effect_text, diff)) {
			while (true) {
				while (*ch != 0 && (*ch == ' ' || *ch == '\t'))
					ch++;
				while (is_var_char(*ch))
					ch++;
				while (*ch != 0 && (*ch == ' ' || *ch == '\t'))
					ch++;
				if (*ch != ',')
					break;
				*ch = ';';
				diff = ch - effect_text->array;
				dstr_insert(effect_text, diff + 1, " ");
				if (extra) {
					dstr_insert_ch(effect_text, diff + 1, extra);
				}
				dstr_insert(effect_text, diff + 1, name);
				if (memcmp("const", begin - 4, 5) == 0) {
					dstr_insert(effect_text, diff + 1, "\nconst ");
					diff += 9;
				} else {
					dstr_insert(effect_text, diff + 1, "\nuniform ");
					diff += 11;
				}
				if (extra)
					diff++;
				ch = effect_text->array + diff + len;
			}

			if ((*ch == '=' && *(ch + 1) != '=') || *ch == ';') {
				if (memcmp("uniform", begin - 6, 7) != 0 && memcmp("const", begin - 4, 5) != 0) {
					dstr_insert(effect_text, begin - effect_text->array + 1, "uniform ");
					diff += 8;
				}
			}
		}
		pos = strstr(effect_text->array + diff + len, name);
	}
}

static void convert_vector_init(struct dstr *effect_text, char *name, int count)
{
	const size_t len = strlen(name);

	char *pos = strstr(effect_text->array, name);
	while (pos) {
		size_t diff = pos - effect_text->array;
		char *ch = pos + len;
		int depth = 0;
		int function_depth = -1;
		bool only_one = true;
		bool only_numbers = true;
		bool only_float = true;
		while (*ch != 0 && (only_numbers || only_float)) {
			if (*ch == '(') {
				depth++;
			} else if (*ch == ')') {
				if (depth == 0) {
					break;
				}
				depth--;
				if (depth == function_depth) {
					function_depth = -1;
				}
			} else if (*ch == ',') {
				if (depth == 0) {
					only_one = false;
				}
			} else if (*ch == ';') {
				only_one = false;
				break;
			} else if (is_var_char(*ch) && (*ch < '0' || *ch > '9')) {
				only_numbers = false;
				char *begin = ch;
				while (is_var_char(*ch))
					ch++;
				if (*ch == '.') {
					size_t c = 1;
					while (is_var_char(*(ch + c)))
						c++;
					if (c != 2 && function_depth < 0)
						only_float = false;
					ch += c - 1;
				} else if (function_depth >= 0) {
					ch--;
				} else if (*ch == '(' &&
					   (strncmp(begin, "length(", 7) == 0 || strncmp(begin, "float(", 6) == 0 ||
					    strncmp(begin, "uint(", 5) == 0 || strncmp(begin, "int(", 4) == 0 ||
					    strncmp(begin, "asfloat(", 8) == 0 || strncmp(begin, "asdouble(", 9) == 0 ||
					    strncmp(begin, "asint(", 6) == 0 || strncmp(begin, "asuint(", 7) == 0 ||
					    strncmp(begin, "determinant(", 12) == 0 || strncmp(begin, "distance(", 9) == 0 ||
					    strncmp(begin, "dot(", 4) == 0 || strncmp(begin, "countbits(", 10) == 0 ||
					    strncmp(begin, "firstbithigh(", 13) == 0 || strncmp(begin, "firstbitlow(", 12) == 0 ||
					    strncmp(begin, "reversebits(", 12) == 0)) {
					function_depth = depth;
					depth++;
				} else if (*ch == '(' &&
					   (strncmp(begin, "abs(", 4) == 0 || strncmp(begin, "acos(", 5) == 0 ||
					    strncmp(begin, "asin(", 5) == 0 || strncmp(begin, "atan(", 5) == 0 ||
					    strncmp(begin, "atan2(", 6) == 0 || strncmp(begin, "ceil(", 5) == 0 ||
					    strncmp(begin, "clamp(", 6) == 0 || strncmp(begin, "cos(", 4) == 0 ||
					    strncmp(begin, "cosh(", 5) == 0 || strncmp(begin, "ddx(", 4) == 0 ||
					    strncmp(begin, "ddy(", 4) == 0 || strncmp(begin, "degrees(", 8) == 0 ||
					    strncmp(begin, "exp(", 4) == 0 || strncmp(begin, "exp2(", 5) == 0 ||
					    strncmp(begin, "floor(", 6) == 0 || strncmp(begin, "fma(", 4) == 0 ||
					    strncmp(begin, "fmod(", 5) == 0 || strncmp(begin, "frac(", 5) == 0 ||
					    strncmp(begin, "frexp(", 6) == 0 || strncmp(begin, "fwidth(", 7) == 0 ||
					    strncmp(begin, "ldexp(", 6) == 0 || strncmp(begin, "lerp(", 5) == 0 ||
					    strncmp(begin, "log(", 4) == 0 || strncmp(begin, "log10(", 6) == 0 ||
					    strncmp(begin, "log2(", 5) == 0 || strncmp(begin, "mad(", 4) == 0 ||
					    strncmp(begin, "max(", 4) == 0 || strncmp(begin, "min(", 4) == 0 ||
					    strncmp(begin, "modf(", 5) == 0 || strncmp(begin, "mod(", 4) == 0 ||
					    strncmp(begin, "mul(", 4) == 0 || strncmp(begin, "normalize(", 10) == 0 ||
					    strncmp(begin, "pow(", 4) == 0 || strncmp(begin, "radians(", 8) == 0 ||
					    strncmp(begin, "rcp(", 4) == 0 || strncmp(begin, "reflect(", 8) == 0 ||
					    strncmp(begin, "refract(", 8) == 0 || strncmp(begin, "round(", 6) == 0 ||
					    strncmp(begin, "rsqrt(", 6) == 0 || strncmp(begin, "saturate(", 9) == 0 ||
					    strncmp(begin, "sign(", 5) == 0 || strncmp(begin, "sin(", 4) == 0 ||
					    strncmp(begin, "sincos(", 7) == 0 || strncmp(begin, "sinh(", 5) == 0 ||
					    strncmp(begin, "smoothstep(", 11) == 0 || strncmp(begin, "sqrt(", 5) == 0 ||
					    strncmp(begin, "step(", 5) == 0 || strncmp(begin, "tan(", 4) == 0 ||
					    strncmp(begin, "tanh(", 5) == 0 || strncmp(begin, "transpose(", 10) == 0 ||
					    strncmp(begin, "trunc(", 6) == 0)) {
					depth++;
				} else {
					struct dstr find = {0};
					bool found = false;
					dstr_copy(&find, "float ");
					dstr_ncat(&find, begin, ch - begin + (*ch == '(' ? 1 : 0));
					char *t = strstr(effect_text->array, find.array);
					while (t != NULL) {
						t += find.len;
						if (*ch == '(') {
							found = true;
							break;
						} else if (!is_var_char(*t)) {
							found = true;
							break;
						}
						t = strstr(t, find.array);
					}
					if (!found) {
						dstr_copy(&find, "int ");
						dstr_ncat(&find, begin, ch - begin + (*ch == '(' ? 1 : 0));
						t = strstr(effect_text->array, find.array);
						while (t != NULL) {
							t += find.len;
							if (*ch == '(') {
								found = true;
								break;
							} else if (!is_var_char(*t)) {
								found = true;
								break;
							}
							t = strstr(t, find.array);
						}
					}
					if (!found && *ch != '(') {
						dstr_copy(&find, "#define ");
						dstr_ncat(&find, begin, ch - begin);
						char *t = strstr(effect_text->array, find.array);
						while (t != NULL) {
							t += find.len;
							if (!is_var_char(*t)) {
								while (*t == ' ' || *t == '\t')
									t++;
								if (*t >= '0' && *t <= '9') {
									found = true;
									break;
								}
							}
							t = strstr(t, find.array);
						}
					}
					if (!found) {
						only_float = false;
					} else if (*ch == '(') {
						function_depth = depth;
					}
					dstr_free(&find);
					ch--;
				}
			} else if ((*ch < '0' || *ch > '9') && *ch != '.' && *ch != ' ' && *ch != '\t' && *ch != '+' &&
				   *ch != '-' && *ch != '*' && *ch != '/') {
				only_numbers = false;
			}
			ch++;
		}
		size_t end_diff = ch - effect_text->array;
		if (count > 1 && only_one && (only_numbers || only_float)) {
			//only 1 simple arg in the float4
			struct dstr found = {0};
			dstr_init(&found);
			dstr_ncat(&found, pos, ch - pos + 1);

			struct dstr replacement = {0};
			dstr_init_copy(&replacement, name);
			dstr_ncat(&replacement, pos + len, ch - (pos + len));
			for (int i = 1; i < count; i++) {
				dstr_cat(&replacement, ",");
				dstr_ncat(&replacement, pos + len, ch - (pos + len));
			}
			dstr_cat(&replacement, ")");

			dstr_replace(effect_text, found.array, replacement.array);

			end_diff -= found.len;
			end_diff += replacement.len;
			dstr_free(&replacement);
			dstr_free(&found);
		}

		if (!is_in_function(effect_text, diff)) {
			char *begin = effect_text->array + diff - 1;
			while (begin > effect_text->array && (*begin == ' ' || *begin == '\t'))
				begin--;
			if (*begin == '=') {
				begin--;
				while (begin > effect_text->array && (*begin == ' ' || *begin == '\t'))
					begin--;
				while (is_var_char(*begin))
					begin--;
				while (begin > effect_text->array && (*begin == ' ' || *begin == '\t'))
					begin--;
				if (memcmp(name, begin - len + 2, len - 1) == 0) {

					begin -= len - 1;
					while (begin > effect_text->array && (*begin == ' ' || *begin == '\t'))
						begin--;
					if (memcmp("uniform", begin - 6, 7) != 0 && memcmp("const", begin - 4, 5) != 0) {
						dstr_insert(effect_text, begin - effect_text->array + 1, "uniform ");
						diff += 8;
						end_diff += 8;
					}
					if (effect_text->array[end_diff] == ')') {
						if (count > 1) {
							effect_text->array[end_diff] = '}';
							dstr_remove(effect_text, diff, len);
							dstr_insert(effect_text, diff, "{");
						} else {
							dstr_remove(effect_text, end_diff, 1);
							dstr_remove(effect_text, diff, len);
						}
					}
				}
			}
		}

		pos = strstr(effect_text->array + diff + len, name);
	}
}

static void convert_if0(struct dstr *effect_text)
{
	char *begin = strstr(effect_text->array, "#if 0");
	while (begin) {
		size_t diff = begin - effect_text->array;
		char *end = strstr(begin, "#endif");
		if (!end)
			return;
		char *el = strstr(begin, "#else");
		char *eli = strstr(begin, "#elif");
		if (eli && eli < end && (!el || eli < el)) {
			//replace #elif with #if
			dstr_remove(effect_text, diff, el - begin + 5);
			dstr_insert(effect_text, diff, "#if");
			begin = strstr(effect_text->array + diff + 3, "#if 0");
		} else if (el && el < end) {
			dstr_remove(effect_text, end - effect_text->array,
				    6); // #endif
			dstr_remove(effect_text, diff, el - begin + 5);
			begin = strstr(effect_text->array + diff, "#if 0");
		} else if (!el || el > end) {
			dstr_remove(effect_text, diff, end - begin + 6);
			begin = strstr(effect_text->array + diff, "#if 0");
		} else {
			begin = strstr(effect_text->array + diff + 5, "#if 0");
		}
	}
}

static void convert_if1(struct dstr *effect_text)
{
	char *begin = strstr(effect_text->array, "#if 1");
	while (begin) {
		size_t diff = begin - effect_text->array;
		char *end = strstr(begin, "#endif");
		if (!end)
			return;
		char *el = strstr(begin, "#el");
		if (el && el < end) {
			dstr_remove(effect_text, el - effect_text->array,
				    end - el + 6); // #endif
			end = strstr(effect_text->array + diff, "\n");
			if (end)
				dstr_remove(effect_text, diff, end - (effect_text->array + diff));
			begin = strstr(effect_text->array + diff, "#if 1");
		} else if (!el || el > end) {
			dstr_remove(effect_text, end - effect_text->array, 6);
			end = strstr(effect_text->array + diff, "\n");
			if (end)
				dstr_remove(effect_text, diff, end - (effect_text->array + diff));
			begin = strstr(effect_text->array + diff, "#if 1");
		} else {
			begin = strstr(effect_text->array + diff + 5, "#if 1");
		}
	}
}

static void convert_define(struct dstr *effect_text)
{
	char *pos = strstr(effect_text->array, "#define ");
	while (pos) {
		size_t diff = pos - effect_text->array;
		char *start = pos + 8;
		while (*start == ' ' || *start == '\t')
			start++;
		char *end = start;
		while (*end != ' ' && *end != '\t' && *end != '\n' && *end != 0)
			end++;
		char *t = strstr(start, "(");
		if (t && t < end) {
			// don't replace macro
			pos = strstr(effect_text->array + diff + 8, "#define ");
			continue;
		}

		struct dstr def_name = {0};
		dstr_ncat(&def_name, start, end - start);

		start = end;
		while (*start == ' ' || *start == '\t')
			start++;

		end = start;
		while (*end != '\n' && *end != 0 && (*end != '/' || *(end + 1) != '/'))
			end++;

		t = strstr(start, "(");
		if (*start == '(' || (t && t < end)) {
			struct dstr replacement = {0};
			dstr_ncat(&replacement, start, end - start);

			dstr_remove(effect_text, diff, end - (effect_text->array + diff));

			dstr_replace(effect_text, def_name.array, replacement.array);

			dstr_free(&replacement);
			pos = strstr(effect_text->array + diff, "#define ");
		} else {
			pos = strstr(effect_text->array + diff + 8, "#define ");
		}
		dstr_free(&def_name);
	}
}

static void convert_return(struct dstr *effect_text, struct dstr *var_name, size_t main_diff)
{
	size_t count = 0;
	char *pos = strstr(effect_text->array + main_diff, var_name->array);
	while (pos) {
		if (is_var_char(*(pos - 1)) || (*(pos - 1) == '/' && *(pos - 2) == '/')) {
			pos = strstr(pos + var_name->len, var_name->array);
			continue;
		}
		size_t diff = pos - effect_text->array;
		char *ch = pos + var_name->len;
		if (*ch == '.') {
			ch++;
			while (is_var_char(*ch))
				ch++;
		}
		while (*ch == ' ' || *ch == '\t')
			ch++;

		if (*ch == '=' || (*(ch + 1) == '=' && (*ch == '*' || *ch == '/' || *ch == '+' || *ch == '-'))) {
			char *bpos = pos - 1;
			while (*bpos != '\n' && (*bpos != '/' || *(bpos + 1) != '/') && bpos > effect_text->array)
				bpos--;
			if (*bpos == '/' && *(bpos + 1) == '/') {
				//comment line
			} else {
				count++;
			}
		}

		pos = strstr(effect_text->array + diff + var_name->len, var_name->array);
	}
	if (count == 0)
		return;
	if (count == 1) {
		pos = strstr(effect_text->array + main_diff, var_name->array);
		while (pos) {
			if (is_var_char(*(pos - 1))) {
				pos = strstr(pos + var_name->len, var_name->array);
				continue;
			}
			char *bpos = pos - 1;
			while (*bpos != '\n' && (*bpos != '/' || *(bpos + 1) != '/') && bpos > effect_text->array)
				bpos--;
			if (*bpos == '/' && *(bpos + 1) == '/') {
				pos = strstr(pos + var_name->len, var_name->array);
				continue;
			}

			size_t diff = pos - effect_text->array;
			char *ch = pos + var_name->len;
			bool contains_alpha = true;
			if (*ch == '.') {
				contains_alpha = false;
				ch++;
				while (is_var_char(*ch)) {
					if (*ch == 'a' || *ch == 'A' || *ch == 'w' || *ch == 'W')
						contains_alpha = true;
					ch++;
				}
			}

			while (*ch == ' ' || *ch == '\t')
				ch++;

			if (*ch == '=') {
				dstr_remove(effect_text, diff, ch - pos + 1);
				if (!contains_alpha) {
					dstr_insert(effect_text, diff, "return float4(");
					while (diff < effect_text->len && effect_text->array[diff] != ';')
						diff++;
					dstr_insert(effect_text, diff, ",1.0)");
				} else {
					dstr_insert(effect_text, diff, "return ");
				}
				return;
			} else if (*(ch + 1) == '=' && (*ch == '*' || *ch == '/' || *ch == '+' || *ch == '-')) {
				dstr_remove(effect_text, diff, ch - pos + 2);
				if (!contains_alpha) {
					dstr_insert(effect_text, diff, "return float4(");
					while (diff < effect_text->len && effect_text->array[diff] != ';')
						diff++;
					dstr_insert(effect_text, diff, ",1.0)");
				} else {
					dstr_insert(effect_text, diff, "return ");
				}
				return;
			}

			pos = strstr(effect_text->array + diff + var_name->len, var_name->array);
		}
		return;
	}

	size_t replaced = 0;
	size_t start_diff = 0;
	bool declared = false;
	pos = strstr(effect_text->array + main_diff, "{");
	if (pos) {
		size_t insert_diff = pos - effect_text->array + 1;
		dstr_insert(effect_text, insert_diff, " = float4(0.0,0.0,0.0,1.0);\n");
		dstr_insert(effect_text, insert_diff, var_name->array);
		dstr_insert(effect_text, insert_diff, "\n\tfloat4 ");
		declared = true;
		start_diff = insert_diff - main_diff + 37 + var_name->len;
	}

	pos = strstr(effect_text->array + main_diff + start_diff, var_name->array);
	while (pos) {
		size_t diff = pos - effect_text->array;
		char *ch = pos + var_name->len;
		bool part = false;
		if (*ch == '.') {
			part = true;
			ch++;
			while (is_var_char(*ch))
				ch++;
		}
		while (*ch == ' ' || *ch == '\t')
			ch++;

		if (*ch == '=') {
			replaced++;
			if (replaced == 1 && !declared) {
				if (part) {
					dstr_insert(effect_text, diff, " = float4(0.0,0.0,0.0,1.0);\n");
					dstr_insert(effect_text, diff, var_name->array);
					dstr_insert(effect_text, diff, "float4 ");
					diff += 35 + var_name->len;
				} else {
					dstr_insert(effect_text, diff, "float4 ");
					diff += 7;
				}
			} else if (replaced == count) {
				if (part) {
					while (*ch != ';' && *ch != 0)
						ch++;
					diff = ch - effect_text->array + 1;
					dstr_insert(effect_text, diff, ";");
					dstr_insert(effect_text, diff, var_name->array);
					dstr_insert(effect_text, diff, "\n\treturn ");
				} else {
					dstr_remove(effect_text, diff, ch - pos + 1);
					dstr_insert(effect_text, diff, "return ");
				}
				return;
			}
		} else if (*(ch + 1) == '=' && (*ch == '*' || *ch == '/' || *ch == '+' || *ch == '-')) {
			replaced++;
			if (replaced == 1 && !declared) {
				dstr_insert(effect_text, diff, " = float4(0.0,0.0,0.0,1.0);\n");
				dstr_insert(effect_text, diff, var_name->array);
				dstr_insert(effect_text, diff, "float4 ");
				diff += 35 + var_name->len;
			} else if (replaced == count) {
				while (*ch != ';' && *ch != 0)
					ch++;
				diff = ch - effect_text->array + 1;
				dstr_insert(effect_text, diff, ";");
				dstr_insert(effect_text, diff, var_name->array);
				dstr_insert(effect_text, diff, "\n\treturn ");
				return;
			}
		}

		pos = strstr(effect_text->array + diff + var_name->len, var_name->array);
	}
}

static bool shader_filter_convert(obs_properties_t *props, obs_property_t *property, void *data)
{
	UNUSED_PARAMETER(props);
	if (!data)
		return false;
	struct shader_filter_data *filter = data;
	obs_data_t *settings = obs_source_get_settings(filter->context);
	if (!settings)
		return false;
	struct dstr effect_text = {0};
	dstr_init_copy(&effect_text, obs_data_get_string(settings, "shader_text"));

	//convert_define(&effect_text);

	size_t start_diff = 24;
	bool main_no_args = false;
	int uv = 0;
	char *main_pos = strstr(effect_text.array, "void mainImage(out vec4");
	if (!main_pos) {
		main_pos = strstr(effect_text.array, "void mainImage( out vec4");
		start_diff++;
	}
	if (!main_pos) {
		main_pos = strstr(effect_text.array, "void main()");
		if (main_pos)
			main_no_args = true;
	}
	if (!main_pos) {
		main_pos = strstr(effect_text.array, "vec4 effect(vec4");
		start_diff = 17;
		uv = 1;
	}

	if (!main_pos) {
		dstr_free(&effect_text);
		obs_data_release(settings);
		return false;
	}
	size_t main_diff = main_pos - effect_text.array;
	struct dstr return_color_name = {0};
	struct dstr coord_name = {0};
	if (main_no_args) {

		dstr_replace(&effect_text, "void main()", "float4 mainImage(VertData v_in) : TARGET");
		if (strstr(effect_text.array, "varying vec2 position;")) {
			uv = 1;
			dstr_init_copy(&coord_name, "position");
		} else if (strstr(effect_text.array, "varying vec2 pos;")) {
			uv = 1;
			dstr_init_copy(&coord_name, "pos");
		} else if (strstr(effect_text.array, "fNormal")) {
			uv = 2;
			dstr_init_copy(&coord_name, "fNormal");
		} else {
			uv = 0;
			dstr_init_copy(&coord_name, "gl_FragCoord");
		}

		char *out_start = strstr(effect_text.array, "out vec4");
		if (out_start) {
			char *start = out_start + 9;
			while (*start == ' ' || *start == '\t')
				start++;
			char *end = start;
			while (*end != ' ' && *end != '\t' && *end != '\n' && *end != ',' && *end != '(' && *end != ')' &&
			       *end != ';' && *end != 0)
				end++;
			dstr_ncat(&return_color_name, start, end - start);
			while (*end == ' ' || *end == '\t')
				end++;
			if (*end == ';')
				dstr_remove(&effect_text, out_start - effect_text.array, (end + 1) - out_start);
		} else {
			dstr_init_copy(&return_color_name, "gl_FragColor");
		}
	} else {

		char *start = main_pos + start_diff;
		while (*start == ' ' || *start == '\t')
			start++;
		char *end = start;
		while (*end != ' ' && *end != '\t' && *end != '\n' && *end != ',' && *end != ')' && *end != 0)
			end++;

		dstr_ncat(&return_color_name, start, end - start);

		start = strstr(end, ",");
		if (!start) {
			dstr_free(&effect_text);
			dstr_free(&return_color_name);
			obs_data_release(settings);
			return false;
		}
		start++;
		while (*start == ' ' || *start == '\t')
			start++;
		char *v2i = strstr(start, "in vec2 ");
		char *v2 = strstr(start, "vec2 ");
		char *close = strstr(start, ")");
		if (v2i && close && v2i < close) {
			start = v2i + 8;
		} else if (v2 && close && v2 < close) {
			start = v2 + 5;
		} else {
			if (*start == 'i' && *(start + 1) == 'n' && (*(start + 2) == ' ' || *(start + 2) == '\t'))
				start += 3;
			while (*start == ' ' || *start == '\t')
				start++;
			if (*start == 'v' && *(start + 1) == 'e' && *(start + 2) == 'c' && *(start + 3) == '2' &&
			    (*(start + 4) == ' ' || *(start + 4) == '\t'))
				start += 5;
		}
		while (*start == ' ' || *start == '\t')
			start++;

		end = start;
		while (*end != ' ' && *end != '\t' && *end != '\n' && *end != ',' && *end != ')' && *end != 0)
			end++;

		dstr_ncat(&coord_name, start, end - start);

		while (*end != ')' && *end != 0)
			end++;
		size_t idx = main_pos - effect_text.array;
		dstr_remove(&effect_text, idx, end - main_pos + 1);
		dstr_insert(&effect_text, idx, "float4 mainImage(VertData v_in) : TARGET");
	}

	convert_return(&effect_text, &return_color_name, main_diff);

	dstr_free(&return_color_name);

	if (dstr_cmp(&coord_name, "fragCoord") != 0) {
		if (dstr_find(&coord_name, "fragCoord")) {
			dstr_replace(&effect_text, coord_name.array, "fragCoord");
		} else {
			char *pos = strstr(effect_text.array, coord_name.array);
			while (pos) {
				size_t diff = pos - effect_text.array;
				if (((main_no_args || diff < main_diff) || diff > main_diff + 24) && !is_var_char(*(pos - 1)) &&
				    !is_var_char(*(pos + coord_name.len))) {
					dstr_remove(&effect_text, diff, coord_name.len);
					dstr_insert(&effect_text, diff, "fragCoord");
					pos = strstr(effect_text.array + diff + 9, coord_name.array);

				} else {
					pos = strstr(effect_text.array + diff + coord_name.len, coord_name.array);
				}
			}
		}
	}
	dstr_free(&coord_name);

	convert_if0(&effect_text);
	convert_if1(&effect_text);

	dstr_replace(&effect_text, "varying vec3", "//varying vec3");
	dstr_replace(&effect_text, "precision highp float;", "//precision highp float;");
	if (uv == 1) {
		dstr_replace(&effect_text, "fragCoord", "v_in.uv");
	} else if (uv == 2) {
		dstr_replace(&effect_text, "fragCoord.xy", "v_in.uv");
		dstr_replace(&effect_text, "fragCoord", "float3(v_in.uv,0.0)");
	} else {
		dstr_replace(&effect_text, "fragCoord.xy/iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "fragCoord.xy / iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "fragCoord/iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "fragCoord / iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "fragCoord", "(v_in.uv * uv_size)");
		dstr_replace(&effect_text, "gl_FragCoord.xy/iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "gl_FragCoord.xy / iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "gl_FragCoord/iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "gl_FragCoord / iResolution.xy", "v_in.uv");
		dstr_replace(&effect_text, "gl_FragCoord", "(v_in.uv * uv_size)");
	}
	dstr_replace(&effect_text, "love_ScreenSize", "uv_size");
	dstr_replace(&effect_text, "u_resolution", "uv_size");
	dstr_replace(&effect_text, "uResolution", "uv_size");
	dstr_replace(&effect_text, "iResolution.xyz", "float3(uv_size,0.0)");
	dstr_replace(&effect_text, "iResolution.xy", "uv_size");
	dstr_replace(&effect_text, "iResolution.x", "uv_size.x");
	dstr_replace(&effect_text, "iResolution.y", "uv_size.y");
	dstr_replace(&effect_text, "iResolution", "float4(uv_size,uv_pixel_interval)");

	dstr_replace(&effect_text, "uniform vec2 uv_size;", "");

	if (strstr(effect_text.array, "iTime"))
		dstr_replace(&effect_text, "iTime", "elapsed_time");
	else if (strstr(effect_text.array, "uTime"))
		dstr_replace(&effect_text, "uTime", "elapsed_time");
	else if (strstr(effect_text.array, "u_time"))
		dstr_replace(&effect_text, "u_time", "elapsed_time");
	else
		dstr_replace(&effect_text, "time", "elapsed_time");

	dstr_replace(&effect_text, "uniform float elapsed_time;", "");

	dstr_replace(&effect_text, "iDate.w", "local_time");

	dstr_replace(&effect_text, "bvec2", "bool2");
	dstr_replace(&effect_text, "bvec3", "bool3");
	dstr_replace(&effect_text, "bvec4", "bool4");

	dstr_replace(&effect_text, "ivec4", "int4");
	dstr_replace(&effect_text, "ivec3", "int3");
	dstr_replace(&effect_text, "ivec2", "int2");

	dstr_replace(&effect_text, "uvec4", "uint4");
	dstr_replace(&effect_text, "uvec3", "uint3");
	dstr_replace(&effect_text, "uvec2", "uint2");

	dstr_replace(&effect_text, "vec4", "float4");
	dstr_replace(&effect_text, "vec3", "float3");
	dstr_replace(&effect_text, "vec2", "float2");

	dstr_replace(&effect_text, " number ", " float ");

	//dstr_replace(&effect_text, "mat4", "float4x4");
	//dstr_replace(&effect_text, "mat3", "float3x3");
	//dstr_replace(&effect_text, "mat2", "float2x2");

	dstr_replace(&effect_text, "dFdx(", "ddx(");
	dstr_replace(&effect_text, "dFdy(", "ddy(");
	dstr_replace(&effect_text, "mix(", "lerp(");
	dstr_replace(&effect_text, "fract(", "frac(");
	dstr_replace(&effect_text, "inversesqrt(", "rsqrt(");

	dstr_replace(&effect_text, "extern bool", "uniform bool");
	dstr_replace(&effect_text, "extern uint", "uniform uint");
	dstr_replace(&effect_text, "extern int", "uniform int");
	dstr_replace(&effect_text, "extern float", "uniform float");

	convert_init(&effect_text, "bool");
	convert_init(&effect_text, "uint");
	convert_init(&effect_text, "int");
	convert_init(&effect_text, "float");

	convert_vector_init(&effect_text, "bool(", 1);
	convert_vector_init(&effect_text, "bool2(", 2);
	convert_vector_init(&effect_text, "bool3(", 3);
	convert_vector_init(&effect_text, "bool4(", 4);
	convert_vector_init(&effect_text, "uint(", 1);
	convert_vector_init(&effect_text, "uint2(", 2);
	convert_vector_init(&effect_text, "uint3(", 3);
	convert_vector_init(&effect_text, "uint4(", 4);
	convert_vector_init(&effect_text, "int(", 1);
	convert_vector_init(&effect_text, "int2(", 2);
	convert_vector_init(&effect_text, "int3(", 3);
	convert_vector_init(&effect_text, "int4(", 4);
	convert_vector_init(&effect_text, "float(", 1);
	convert_vector_init(&effect_text, "float2(", 2);
	convert_vector_init(&effect_text, "float3(", 3);
	convert_vector_init(&effect_text, "float4(", 4);
	convert_vector_init(&effect_text, "mat2(", 4);
	convert_vector_init(&effect_text, "mat3(", 9);
	convert_vector_init(&effect_text, "mat4(", 16);

	convert_atan(&effect_text);
	convert_mat_mul(&effect_text, "mat2");
	convert_mat_mul(&effect_text, "mat3");
	convert_mat_mul(&effect_text, "mat4");

	dstr_replace(&effect_text, "point(", "point2(");
	dstr_replace(&effect_text, "line(", "line2(");

	dstr_replace(&effect_text, "#version ", "//#version ");

	convert_if_defined(&effect_text);

	dstr_replace(&effect_text, "acos(-1.0)", "3.14159265359");
	dstr_replace(&effect_text, "acos(-1.)", "3.14159265359");
	dstr_replace(&effect_text, "acos(-1)", "3.14159265359");

	struct dstr insert_text = {0};
	dstr_init_copy(&insert_text, "#ifndef OPENGL\n");

	if (dstr_find(&effect_text, "mat2"))
		dstr_cat(&insert_text, "#define mat2 float2x2\n");
	if (dstr_find(&effect_text, "mat3"))
		dstr_cat(&insert_text, "#define mat3 float3x3\n");
	if (dstr_find(&effect_text, "mat4"))
		dstr_cat(&insert_text, "#define mat4 float4x4\n");

	if (dstr_find(&effect_text, "mod("))
		dstr_cat(&insert_text, "#define mod(x,y) ((x) - (y) * floor((x) / (y)))\n");
	if (dstr_find(&effect_text, "lessThan("))
		dstr_cat(&insert_text, "#define lessThan(a,b) ((a) < (b))\n");
	if (dstr_find(&effect_text, "greaterThan("))
		dstr_cat(&insert_text, "#define greaterThan(a,b) ((a) > (b))\n");
	dstr_cat(&insert_text, "#endif\n");

	if (dstr_find(&effect_text, "iMouse") && !dstr_find(&effect_text, "float2 iMouse"))
		dstr_cat(
			&insert_text,
			"uniform float4 iMouse<\nstring widget_type = \"slider\";\nfloat minimum=0.0;\nfloat maximum=1000.0;\nfloat step=1.0;\n>;\n");

	if (dstr_find(&effect_text, "iFrame") && !dstr_find(&effect_text, "float iFrame"))
		dstr_cat(&insert_text, "uniform float iFrame;\n");

	if (dstr_find(&effect_text, "iSampleRate") && !dstr_find(&effect_text, "float iSampleRate"))
		dstr_cat(&insert_text, "uniform float iSampleRate;\n");

	if (dstr_find(&effect_text, "iTimeDelta") && !dstr_find(&effect_text, "float iTimeDelta"))
		dstr_cat(&insert_text, "uniform float iTimeDelta;\n");

	int num_textures = 0;
	struct dstr texture_name = {0};
	struct dstr replacing = {0};
	struct dstr replacement = {0};

	char *texture_find[] = {"texture(", "texture2D(", "texelFetch(", "Texel(", "textureLod("};
	char *texture = NULL;
	size_t texture_diff = 0;
	for (size_t i = 0; i < sizeof(texture_find) / sizeof(char *); i++) {
		char *t = strstr(effect_text.array, texture_find[i]);
		if (t && (!texture || t < texture)) {
			texture = t;
			texture_diff = strlen(texture_find[i]);
		}
	}
	while (texture) {
		const size_t diff = texture - effect_text.array;
		if (is_var_char(*(texture - 1))) {
			texture = NULL;
			size_t prev_diff = texture_diff;
			for (size_t i = 0; i < 3; i++) {
				char *t = strstr(effect_text.array + diff + prev_diff, texture_find[i]);
				if (t && (!texture || t < texture)) {
					texture = t;
					texture_diff = strlen(texture_find[i]);
				}
			}
			continue;
		}
		char *start = texture + texture_diff;
		while (*start == ' ' || *start == '\t')
			start++;
		char *end = start;
		while (*end != ' ' && *end != '\t' && *end != ',' && *end != ')' && *end != '\n' && *end != 0)
			end++;
		dstr_copy(&texture_name, "");
		dstr_ncat(&texture_name, start, end - start);

		dstr_copy(&replacing, "");
		dstr_ncat(&replacing, texture, end - texture);

		dstr_copy(&replacement, "");

		if (num_textures) {
			dstr_cat_dstr(&replacement, &texture_name);
			dstr_cat(&replacement, ".Sample(textureSampler");

			dstr_cat(&insert_text, "uniform texture2d ");
			dstr_cat(&insert_text, texture_name.array);
			dstr_cat(&insert_text, ";\n");
		} else {
			dstr_cat(&replacement, "image.Sample(textureSampler");
		}
		dstr_replace(&effect_text, replacing.array, replacement.array);

		dstr_copy(&replacing, "textureSize(");
		dstr_cat(&replacing, texture_name.array);
		dstr_cat(&replacing, ", 0)");

		dstr_replace(&effect_text, replacing.array, "uv_size");
		dstr_replace(&replacing, ", 0)", ",0)");
		dstr_replace(&effect_text, replacing.array, "uv_size");

		num_textures++;
		size_t prev_diff = texture_diff;
		texture = NULL;
		for (size_t i = 0; i < sizeof(texture_find) / sizeof(char *); i++) {
			char *t = strstr(effect_text.array + diff + prev_diff, texture_find[i]);
			if (t && (!texture || t < texture)) {
				texture = t;
				texture_diff = strlen(texture_find[i]);
			}
		}
	}
	dstr_free(&replacing);
	dstr_free(&replacement);
	dstr_free(&texture_name);

	if (insert_text.len > 24) {
		dstr_insert_dstr(&effect_text, 0, &insert_text);
	}
	dstr_free(&insert_text);

	obs_data_set_string(settings, "shader_text", effect_text.array);

	dstr_free(&effect_text);

	obs_data_release(settings);
	obs_property_set_visible(property, false);

	filter->reload_effect = true;

	obs_source_update(filter->context, NULL);
	return true;
}

static const char *shader_filter_texture_file_filter = "Textures (*.bmp *.tga *.png *.jpeg *.jpg *.gif);;";
static const char *shader_filter_shader_file_filter = "Shaders (*.shader *.effect);;All files (*.*)";

#define MIN_AUDIO_THRESHOLD -60.0f

static float convert_db_to_linear(float db_value)
{
	if (db_value <= MIN_AUDIO_THRESHOLD || db_value > 0.0f)
		return 0.0f;

	return fmaxf(0.0f, fminf(1.0f, (db_value - MIN_AUDIO_THRESHOLD) / (-MIN_AUDIO_THRESHOLD)));
}

static void shader_filter_audio_callback(void *data, const float magnitude[MAX_AUDIO_CHANNELS],
					 const float peak[MAX_AUDIO_CHANNELS], const float input_peak[MAX_AUDIO_CHANNELS])
{
	UNUSED_PARAMETER(input_peak);
	struct shader_filter_data *filter = (struct shader_filter_data *)data;

	float max_peak = MIN_AUDIO_THRESHOLD;
	for (int i = 0; i < MAX_AUDIO_CHANNELS; i++) {
		if (peak[i] > max_peak && peak[i] != 0.0f) {
			max_peak = peak[i];
		}
	}

	float max_magnitude = MIN_AUDIO_THRESHOLD;
	for (int i = 0; i < MAX_AUDIO_CHANNELS; i++) {
		if (magnitude[i] > max_magnitude && magnitude[i] != 0.0f) {
			max_magnitude = magnitude[i];
		}
	}

	filter->current_audio_peak = convert_db_to_linear(max_peak);
	filter->current_audio_magnitude = convert_db_to_linear(max_magnitude);
}

static bool shader_filter_enum_audio_sources(void *data, obs_source_t *source)
{
	obs_property_t *prop = (obs_property_t *)data;
	uint32_t flags = obs_source_get_output_flags(source);

	if ((flags & OBS_SOURCE_AUDIO) != 0) {
		const char *name = obs_source_get_name(source);
		obs_property_list_add_string(prop, name, name);
	}

	return true;
}

static inline void shader_filter_set_tooltip(obs_property_t *p, const struct dstr *tooltip)
{
	if (p && tooltip && tooltip->len)
		obs_property_set_long_description(p, tooltip->array);
}

/* Is a shader filter directly before or after this one (so an effect file,
 * which can't share their pass, costs more)? */
static bool neighbour_is(obs_source_t *parent, obs_source_t *child, void *param)
{
	UNUSED_PARAMETER(parent);
	struct shader_filter_data *filter = param;
	if (child == filter->context || strcmp(obs_source_get_id(child), "shader_filter") != 0)
		return false;
	return obs_filter_get_target(child) == filter->context;
}

struct neighbour_search {
	struct shader_filter_data *filter;
	bool found;
};

static void find_downstream_shader(obs_source_t *parent, obs_source_t *child, void *param)
{
	struct neighbour_search *ns = param;
	if (neighbour_is(parent, child, ns->filter))
		ns->found = true;
}

static bool has_shader_neighbour(struct shader_filter_data *filter)
{
	obs_source_t *target = obs_filter_get_target(filter->context);
	if (target && obs_source_get_type(target) == OBS_SOURCE_TYPE_FILTER &&
	    strcmp(obs_source_get_id(target), "shader_filter") == 0)
		return true;
	obs_source_t *parent = obs_filter_get_parent(filter->context);
	if (!parent)
		return false;
	struct neighbour_search ns = {filter, false};
	obs_source_enum_filters(parent, find_downstream_shader, &ns);
	return ns.found;
}

static obs_properties_t *shader_filter_properties(void *data)
{
	struct shader_filter_data *filter = data;

	obs_properties_t *props = obs_properties_create();
	obs_properties_set_param(props, filter, NULL);
	obs_data_t *settings = filter ? obs_source_get_settings(filter->context) : obs_data_create();
	const bool transition = filter && filter->transition;

	const bool from_file = obs_data_get_bool(settings, "from_file");
	const char *file = obs_data_get_string(settings, "shader_file_name");
	const bool has_file = from_file && file && *file;
	const bool inline_code = !from_file && obs_data_has_user_value(settings, "shader_text");

	/* ---- the shader, and (when browsing) ways to find and step through others ---- */
	obs_property_t *pick = obs_properties_add_list(props, "shader_pick", obs_module_text("ShaderFilter.Shader"),
						       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	obs_property_set_modified_callback(pick, shader_pick_changed);

	/* Keep the list's selection in step with the shader actually used. */
	const char *cur_pick = obs_data_get_string(settings, "shader_pick");
	const bool picking_other = strcmp(cur_pick, PICK_OTHER) == 0 && !has_file;
	if (!picking_other)
		obs_data_set_string(settings, "shader_pick", has_file ? file : inline_code ? PICK_INLINE : PICK_NONE);

	char *lib = library_dir(settings);
	obs_property_t *file_name = obs_properties_add_path(props, "shader_file_name",
							    obs_module_text("ShaderFilter.ShaderFileName"), OBS_PATH_FILE,
							    shader_filter_shader_file_filter, lib);
	obs_property_set_visible(file_name, picking_other);
	obs_property_set_modified_callback(file_name, shader_filter_file_name_changed);

	const char *error_message = obs_data_get_string(settings, "error_message");

	/* What's wrong (or special) about the shader, right under it. A bundled
	 * shader isn't the person's to fix: no path, no Reload, and its compiler
	 * output is under Advanced. */
	const bool bundled = has_file && is_bundled_shader(file);
	const char *errs = obs_data_get_string(settings, "error_details");
	const char *warns = obs_data_get_string(settings, "warning_details");
	const bool has_messages = (errs && *errs) || (warns && *warns);
	if (error_message && *error_message) {
		obs_property_t *error = obs_properties_add_text(props, "error_line", error_message, OBS_TEXT_INFO);
		obs_property_text_set_info_type(error, OBS_TEXT_INFO_ERROR);
		const char *where = obs_data_get_string(settings, "error_where");
		if (!bundled && where && *where)
			obs_properties_add_text(props, "error_where_text", where, OBS_TEXT_INFO);
		if (has_file && !bundled)
			obs_properties_add_button2(props, "reload_after_error", obs_module_text("ShaderFilter.ReloadEffect"),
						   shader_filter_reload_effect_clicked, data);
		if (has_messages && !bundled)
			add_compiler_messages(props, settings, errs, warns);
	}
	if (inline_code)
	{
		obs_property_t *note = obs_properties_add_text(props, "inline_note", obs_module_text("ShaderFilter.InlineNote"),
							       OBS_TEXT_INFO);
		/* the rest of the story is on the Shader list's help icon */
		obs_property_set_long_description(pick, obs_module_text("ShaderFilter.InlineNoteHelp"));
	}
	if (has_file && filter && path_is_effect(file) && has_shader_neighbour(filter))
		obs_properties_add_text(props, "effect_note", obs_module_text("ShaderFilter.EffectNote"), OBS_TEXT_INFO);

	/* The browsing tools show on a filter with no shader yet. Once a filter
	 * has a shader they start hidden each time its settings are opened,
	 * unless the person opened them on this filter themselves. */
	const bool refreshing = filter && os_gettime_ns() < filter->props_refresh_until;
	if (has_file || inline_code) {
		if (!refreshing && !(filter && filter->browse_kept))
			obs_data_set_bool(settings, "browse_shaders", false);
	} else if (!obs_data_has_user_value(settings, "browse_shaders")) {
		obs_data_set_bool(settings, "browse_shaders", true);
	}
	const bool browsing = obs_data_get_bool(settings, "browse_shaders");
	if (filter)
		filter->browse_shown = browsing;
	obs_property_t *browse = obs_properties_add_bool(props, "browse_shaders", obs_module_text("ShaderFilter.Browse"));
	obs_property_set_long_description(browse, obs_module_text("ShaderFilter.BrowseHelp"));
	obs_property_set_modified_callback(browse, browse_shaders_changed);

	category_list_t categories;
	da_init(categories);
	/* Categories come from the bundled library, which is always listed. */
	char *bundled_lib = examples_dir();
	library_categories(bundled_lib, &categories);
	bfree(bundled_lib);
	if (categories.num) {
		obs_property_t *cat = obs_properties_add_list(props, "shader_category", obs_module_text("ShaderFilter.Category"),
							      OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
		obs_property_list_add_string(cat, obs_module_text("ShaderFilter.AllCategories"), "");
		for (size_t i = 0; i < categories.num; i++)
			obs_property_list_add_string(cat, categories.array[i], categories.array[i]);
		obs_property_set_modified_callback(cat, shader_search_changed);
		obs_property_set_long_description(cat, obs_module_text("ShaderFilter.CategoryHelp"));
		obs_property_set_visible(cat, browsing);
	} else if (*obs_data_get_string(settings, "shader_category")) {
		obs_data_set_string(settings, "shader_category", "");
	}
	for (size_t i = 0; i < categories.num; i++)
		bfree(categories.array[i]);
	da_free(categories);
	bfree(lib);

	obs_property_t *search = obs_properties_add_text(props, "shader_search", obs_module_text("ShaderFilter.Search"),
							 OBS_TEXT_DEFAULT);
	obs_property_set_long_description(search, obs_module_text("ShaderFilter.SearchHelp"));
	obs_property_set_modified_callback(search, shader_search_changed);
	obs_property_set_visible(search, browsing);

	/* Where the shader is in the (narrowed) list. (The arrow keys on the
	 * Shader list apply the next or previous entry, as in any dropdown.) */
	obs_property_text_set_info_word_wrap(obs_properties_add_text(props, "browse_status", "", OBS_TEXT_INFO), false);


	size_t pos;
	size_t n_listed = fill_shader_list(pick, settings, transition, &pos);
	update_browse_status(props, settings, n_listed, pos);

	/* ---- the shader's own settings ---- */
	obs_properties_t *params = obs_properties_create();
	if (filter && has_file && filter->stored_param_list.num) {
		/* Presets first: choosing one sets the sliders below. The list shows
		 * the preset the values match, or Custom. */
		preset_list_t presets;
		presets_load(file, &presets);
		if (presets.num) {
			obs_property_t *pl = obs_properties_add_list(params, "shader_preset", obs_module_text("ShaderFilter.Preset"),
								     OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
			obs_property_set_long_description(pl, obs_module_text("ShaderFilter.PresetHelp"));
			obs_property_list_add_string(pl, obs_module_text("ShaderFilter.PresetCustom"), "");
			const char *current = "";
			for (size_t i = 0; i < presets.num; i++) {
				obs_property_list_add_string(pl, presets.array[i].name, presets.array[i].name);
				if (!*current && preset_matches(filter, settings, &presets.array[i]))
					current = presets.array[i].name;
			}
			obs_data_set_string(settings, "shader_preset", current);
			obs_property_set_modified_callback(pl, shader_preset_changed);
		}
		presets_free(&presets);
	}
	if (filter && (filter->param_audio_magnitude || filter->param_audio_peak)) {
		obs_property_t *audio_source = obs_properties_add_list(params, "audio_source", "Audio source",
								       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
		obs_property_list_add_string(audio_source, "None", "");
		obs_enum_sources(shader_filter_enum_audio_sources, audio_source);
	}

	DARRAY(obs_property_t *) groups;
	da_init(groups);

	/* The shader's description (its "info" text) goes first, then its
	 * parameters in the order it declares them. */
	size_t param_count = filter ? filter->stored_param_list.num : 0;
	for (size_t pass = 0; pass < 2; pass++)
	for (size_t param_index = 0; param_index < param_count; param_index++) {
		struct effect_param_data *param = (filter->stored_param_list.array + param_index);
		const bool is_info = param->type == GS_SHADER_PARAM_STRING && param->widget_type.array &&
				     strcmp(param->widget_type.array, "info") == 0;
		if (is_info != (pass == 0))
			continue;
		const char *param_name = param->name.array;
		const char *label = param->display_name.array;
		const char *widget_type = param->widget_type.array;
		const char *group_name = param->group.array;
		const int *options = param->option_values.array;
		const struct dstr *option_labels = param->option_labels.array;

		struct dstr display_name = {0};
		struct dstr sources_name = {0};

		if (label == NULL) {
			dstr_ncat(&display_name, param_name, param->name.len);
			dstr_replace(&display_name, "_", " ");
			if (display_name.len && display_name.array[0] >= 'a' && display_name.array[0] <= 'z')
				display_name.array[0] = (char)(display_name.array[0] - 'a' + 'A');
		} else {
			dstr_ncat(&display_name, label, param->display_name.len);
		}
		obs_properties_t *group = NULL;
		if (group_name && strlen(group_name)) {
			for (size_t i = 0; i < groups.num; i++) {
				const char *n = obs_property_name(groups.array[i]);
				if (strcmp(n, group_name) == 0) {
					group = obs_property_group_content(groups.array[i]);
				}
			}
			if (!group) {
				group = obs_properties_create();
				obs_property_t *p =
					obs_properties_add_group(params, group_name, group_name, OBS_GROUP_NORMAL, group);
				da_push_back(groups, &p);
			}
		}
		if (!group)
			group = params;
		obs_property_t *p = NULL;
		switch (param->type) {
		case GS_SHADER_PARAM_BOOL:
			p = obs_properties_add_bool(group, param_name, display_name.array);
			break;
		case GS_SHADER_PARAM_FLOAT: {
			double range_min = param->minimum.f;
			double range_max = param->maximum.f;
			double step = param->step.f;
			if (range_min == range_max) {
				range_min = -1000.0;
				range_max = 1000.0;
				step = 0.0001;
			}
			obs_properties_remove_by_name(params, param_name);
			if (widget_type != NULL && strcmp(widget_type, "slider") == 0) {
				p = obs_properties_add_float_slider(group, param_name, display_name.array, range_min, range_max,
								    step);
			} else {
				p = obs_properties_add_float(group, param_name, display_name.array, range_min, range_max, step);
			}
			break;
		}
		case GS_SHADER_PARAM_INT: {
			int range_min = (int)param->minimum.i;
			int range_max = (int)param->maximum.i;
			int step = (int)param->step.i;
			if (range_min == range_max) {
				range_min = -1000;
				range_max = 1000;
				step = 1;
			}
			obs_properties_remove_by_name(params, param_name);

			if (widget_type != NULL && strcmp(widget_type, "slider") == 0) {
				p = obs_properties_add_int_slider(group, param_name, display_name.array, range_min, range_max,
								  step);
			} else if (widget_type != NULL && strcmp(widget_type, "select") == 0) {
				p = obs_properties_add_list(group, param_name, display_name.array, OBS_COMBO_TYPE_LIST,
							    OBS_COMBO_FORMAT_INT);
				for (size_t i = 0; i < param->option_values.num; i++) {
					obs_property_list_add_int(p, option_labels[i].array, options[i]);
				}
			} else {
				p = obs_properties_add_int(group, param_name, display_name.array, range_min, range_max, step);
			}
			break;
		}
		case GS_SHADER_PARAM_INT3:

			break;
		case GS_SHADER_PARAM_VEC2: {
			double range_min = param->minimum.f;
			double range_max = param->maximum.f;
			double step = param->step.f;
			if (range_min == range_max) {
				range_min = -1000.0;
				range_max = 1000.0;
				step = 0.0001;
			}

			bool slider = (widget_type != NULL && strcmp(widget_type, "slider") == 0);

			for (size_t i = 0; i < 2; i++) {
				dstr_printf(&sources_name, "%s_%zu", param_name, i);
				obs_property_t *sub = NULL;
				if (i < param->option_labels.num) {
					if (slider) {
						sub = obs_properties_add_float_slider(group, sources_name.array,
										      param->option_labels.array[i].array,
										      range_min, range_max, step);
					} else {
						sub = obs_properties_add_float(group, sources_name.array,
									       param->option_labels.array[i].array, range_min,
									       range_max, step);
					}
				} else if (slider) {

					sub = obs_properties_add_float_slider(group, sources_name.array, display_name.array,
									      range_min, range_max, step);
				} else {
					sub = obs_properties_add_float(group, sources_name.array, display_name.array, range_min,
								       range_max, step);
				}
				shader_filter_set_tooltip(sub, &param->tooltip);
				if (i == 0)
					p = sub;
			}
			dstr_free(&sources_name);

			break;
		}
		case GS_SHADER_PARAM_VEC3:
			if (widget_type != NULL && strcmp(widget_type, "slider") == 0) {
				double range_min = param->minimum.f;
				double range_max = param->maximum.f;
				double step = param->step.f;
				if (range_min == range_max) {
					range_min = -1000.0;
					range_max = 1000.0;
					step = 0.0001;
				}
				for (size_t i = 0; i < 3; i++) {
					dstr_printf(&sources_name, "%s_%zu", param_name, i);
					obs_property_t *sub = NULL;
					if (i < param->option_labels.num) {
						sub = obs_properties_add_float_slider(group, sources_name.array,
										      param->option_labels.array[i].array,
										      range_min, range_max, step);
					} else {
						sub = obs_properties_add_float_slider(group, sources_name.array, display_name.array,
										      range_min, range_max, step);
					}
					shader_filter_set_tooltip(sub, &param->tooltip);
					if (i == 0)
						p = sub;
				}
				dstr_free(&sources_name);
			} else {
				p = obs_properties_add_color(group, param_name, display_name.array);
			}
			break;
		case GS_SHADER_PARAM_VEC4:
			if (widget_type != NULL && strcmp(widget_type, "slider") == 0) {
				double range_min = param->minimum.f;
				double range_max = param->maximum.f;
				double step = param->step.f;
				if (range_min == range_max) {
					range_min = -1000.0;
					range_max = 1000.0;
					step = 0.0001;
				}
				for (size_t i = 0; i < 4; i++) {
					dstr_printf(&sources_name, "%s_%zu", param_name, i);
					obs_property_t *sub = NULL;
					if (i < param->option_labels.num) {
						sub = obs_properties_add_float_slider(group, sources_name.array,
										      param->option_labels.array[i].array,
										      range_min, range_max, step);
					} else {
						sub = obs_properties_add_float_slider(group, sources_name.array, display_name.array,
										      range_min, range_max, step);
					}
					shader_filter_set_tooltip(sub, &param->tooltip);
					if (i == 0)
						p = sub;
				}
				dstr_free(&sources_name);
			} else {
				p = obs_properties_add_color_alpha(group, param_name, display_name.array);
			}
			break;
		case GS_SHADER_PARAM_TEXTURE:
			if (widget_type != NULL && strcmp(widget_type, "source") == 0) {
				dstr_init_copy_dstr(&sources_name, &param->name);
				dstr_cat(&sources_name, "_source");
				p = obs_properties_add_list(group, sources_name.array, display_name.array, OBS_COMBO_TYPE_EDITABLE,
							    OBS_COMBO_FORMAT_STRING);
				dstr_free(&sources_name);
				obs_enum_sources(add_source_to_list, p);
				obs_enum_scenes(add_source_to_list, p);
				obs_property_list_insert_string(p, 0, "", "");

			} else if (widget_type != NULL && strcmp(widget_type, "file") == 0) {
				p = obs_properties_add_path(group, param_name, display_name.array, OBS_PATH_FILE,
							    shader_filter_texture_file_filter, NULL);
			} else {
				dstr_init_copy_dstr(&sources_name, &param->name);
				dstr_cat(&sources_name, "_source");
				obs_property_t *src = obs_properties_add_list(group, sources_name.array, display_name.array,
									      OBS_COMBO_TYPE_EDITABLE, OBS_COMBO_FORMAT_STRING);
				dstr_free(&sources_name);
				obs_property_list_add_string(src, "", "");
				obs_enum_sources(add_source_to_list, src);
				obs_enum_scenes(add_source_to_list, src);
				shader_filter_set_tooltip(src, &param->tooltip);
				p = obs_properties_add_path(group, param_name, display_name.array, OBS_PATH_FILE,
							    shader_filter_texture_file_filter, NULL);
			}
			break;
		case GS_SHADER_PARAM_STRING:
			if (widget_type != NULL && strcmp(widget_type, "info") == 0) {
				p = obs_properties_add_text(group, param_name, display_name.array, OBS_TEXT_INFO);
			} else {
				p = obs_properties_add_text(group, param_name, display_name.array, OBS_TEXT_MULTILINE);
			}
			break;
		default:;
		}
		shader_filter_set_tooltip(p, &param->tooltip);
		dstr_free(&display_name);
	}
	da_free(groups);

	obs_property_t *first_param = obs_properties_first(params);
	obs_properties_t *params_group = first_param ? params : NULL;
	if (first_param) {
		struct dstr title = {0};
		if (has_file || inline_code) {
			char *name = has_file ? shader_display_name(file) : bstrdup(obs_module_text("ShaderFilter.SavedCodeName"));
			dstr_printf(&title, obs_module_text("ShaderFilter.SettingsOf"), name);
			bfree(name);
		} else {
			dstr_copy(&title, obs_module_text("ShaderFilter.Settings"));
		}
		obs_properties_add_group(props, "shader_params", title.array, OBS_GROUP_NORMAL, params);
		dstr_free(&title);
	} else {
		obs_properties_destroy(params);
	}

	/* ---- what it costs, measured on this computer ---- */
	if (filter && !transition && (has_file || inline_code) && !(error_message && *error_message)) {
		struct dstr t = {0};
		if (filter->gpu_merged) {
			dstr_copy(&t, obs_module_text("ShaderFilter.GpuMerged"));
		} else if (filter->gpu_ms >= 0.0f) {
			struct obs_video_info ovi;
			double frame_ms = 1000.0 / 60.0;
			int fps = 60;
			if (obs_get_video_info(&ovi) && ovi.fps_num && ovi.fps_den &&
			    (double)ovi.fps_num / ovi.fps_den >= 1.0) {
				frame_ms = 1000.0 * ovi.fps_den / ovi.fps_num;
				fps = (int)((double)ovi.fps_num / ovi.fps_den + 0.5);
			}
			const double pct = filter->gpu_ms / frame_ms * 100.0;
			if (filter->gpu_group > 1)
				dstr_printf(&t, obs_module_text("ShaderFilter.GpuTimeGroup"), filter->gpu_ms, pct, fps,
					    (int)filter->gpu_group - 1);
			else
				dstr_printf(&t, obs_module_text("ShaderFilter.GpuTime"), filter->gpu_ms, pct, fps);
		} else {
			dstr_copy(&t, obs_module_text("ShaderFilter.GpuMeasuring"));
			filter->gpu_props_waiting = true;
		}
		obs_property_text_set_info_word_wrap(obs_properties_add_text(props, "gpu_time", t.array, OBS_TEXT_INFO),
						     false);
		dstr_free(&t);
	}

	/* ---- rarely needed ---- */
	obs_properties_t *adv = obs_properties_create();
	const bool space_up_front = has_file && shader_wants_space(file);
	if (!transition && (has_file || inline_code)) {
		obs_properties_t *space_in = !space_up_front ? adv : params_group ? params_group : props;
		const char *keys[] = {"expand_left", "expand_right", "expand_top", "expand_bottom"};
		const char *labels[] = {"ShaderFilter.ExpandLeft", "ShaderFilter.ExpandRight", "ShaderFilter.ExpandTop",
					"ShaderFilter.ExpandBottom"};
		bool any = false;
		for (size_t i = 0; i < 4; i++)
			any = any || obs_data_get_int(settings, keys[i]) != 0;
		if (any)
			obs_data_set_bool(settings, "show_expand", true);
		obs_property_t *show = obs_properties_add_bool(space_in, "show_expand", obs_module_text("ShaderFilter.ShowExpand"));
		obs_property_set_long_description(show, obs_module_text("ShaderFilter.ShowExpandHelp"));
		obs_property_set_modified_callback(show, show_expand_changed);
		const bool visible = obs_data_get_bool(settings, "show_expand");
		for (size_t i = 0; i < 4; i++) {
			obs_property_t *e = obs_properties_add_int(space_in, keys[i], obs_module_text(labels[i]), 0, 9999, 1);
			obs_property_int_set_suffix(e, " px");
			obs_property_set_visible(e, visible);
		}
	}
	if (filter && !transition && has_file && is_default_filter_name(obs_source_get_name(filter->context))) {
		char *name = auto_filter_name(filter, file);
		struct dstr label = {0};
		dstr_printf(&label, obs_module_text("ShaderFilter.RenameAfterShader"), name);
		obs_property_t *rename = obs_properties_add_button2(props, "rename_after_shader", label.array,
								    rename_after_shader_clicked, data);
		obs_property_set_long_description(rename, obs_module_text("ShaderFilter.RenameHelp"));
		dstr_free(&label);
		bfree(name);
	}
	if (has_file && !(error_message && *error_message)) {
		obs_property_t *reload = obs_properties_add_button2(adv, "reload_effect", obs_module_text("ShaderFilter.ReloadEffect"),
								    shader_filter_reload_effect_clicked, data);
		obs_property_set_long_description(reload, obs_module_text("ShaderFilter.ReloadHelp"));
	}
	if (bundled && error_message && *error_message && has_messages)
		add_compiler_messages(adv, settings, errs, warns);
	if (inline_code) {
		obs_property_t *show = obs_properties_add_bool(adv, "show_code", obs_module_text("ShaderFilter.ShowCode"));
		obs_property_set_modified_callback(show, show_code_changed);
		const bool visible = obs_data_get_bool(settings, "show_code");
		obs_property_t *shader_text = obs_properties_add_text(adv, "shader_text", obs_module_text("ShaderFilter.ShaderText"),
								      OBS_TEXT_MULTILINE);
		obs_property_set_modified_callback(shader_text, shader_filter_text_changed);
		obs_property_set_visible(shader_text, visible);
		obs_property_t *convert = obs_properties_add_button2(adv, "shader_convert", obs_module_text("ShaderFilter.Convert"),
								     shader_filter_convert, data);
		obs_property_set_visible(convert, false);
		obs_property_t *apply = obs_properties_add_button2(adv, "reload_code", obs_module_text("ShaderFilter.ReloadCode"),
								   shader_filter_reload_effect_clicked, data);
		obs_property_set_visible(apply, visible);
	}
	if (obs_properties_first(adv)) {
		/* Shown on request; open already if something in it is in use. */
		bool in_use = obs_data_get_bool(settings, "show_code");
		if (!space_up_front)
			in_use = in_use || obs_data_get_bool(settings, "show_expand");
		if (in_use)
			obs_data_set_bool(settings, "show_advanced", true);
		obs_property_t *show = obs_properties_add_bool(props, "show_advanced", obs_module_text("ShaderFilter.ShowAdvanced"));
		obs_property_set_modified_callback(show, show_advanced_changed);
		obs_property_t *group = obs_properties_add_group(props, "advanced", obs_module_text("ShaderFilter.Advanced"),
								 OBS_GROUP_NORMAL, adv);
		obs_property_set_visible(group, obs_data_get_bool(settings, "show_advanced"));
	} else {
		obs_properties_destroy(adv);
	}

	obs_properties_add_text(
		props, "plugin_info",
		"<a href=\"https://obsproject.com/forum/resources/obs-shaderfilter.1736/\">obs-shaderfilter</a> (" PROJECT_VERSION
		") by <a href=\"https://www.exeldro.com\">Exeldro</a>",
		OBS_TEXT_INFO);
	obs_data_release(settings);
	return props;
}

static void shader_filter_update(void *data, obs_data_t *settings)
{
	struct shader_filter_data *filter = data;

	// Get expansions. Will be used in the video_tick() callback.

	filter->expand_left = (int)obs_data_get_int(settings, "expand_left");
	filter->expand_right = (int)obs_data_get_int(settings, "expand_right");
	filter->expand_top = (int)obs_data_get_int(settings, "expand_top");
	filter->expand_bottom = (int)obs_data_get_int(settings, "expand_bottom");
	filter->rand_activation_f = (float)((double)rand_interval(0, 10000) / (double)10000);

	if (filter->reload_effect) {
		filter->reload_effect = false;
		shader_filter_reload_effect(filter);
		filter->props_refresh_until = os_gettime_ns() + 1000000000ULL;
		obs_source_update_properties(filter->context);
	}

	if (filter->param_audio_magnitude || filter->param_audio_peak) {
		const char *audio_source_name = obs_data_get_string(settings, "audio_source");
		if (!filter->audio_source_name || strcmp(filter->audio_source_name, audio_source_name) != 0) {
			obs_source_t *audio_source = strlen(audio_source_name) > 0 ? obs_get_source_by_name(audio_source_name)
										   : NULL;
			if (audio_source && ((obs_source_get_output_flags(audio_source) & OBS_SOURCE_AUDIO) == 0)) {
				obs_source_release(audio_source);
				audio_source = NULL;
			}
			if (audio_source) {
				if (filter->audio_source_name)
					bfree(filter->audio_source_name);
				filter->audio_source_name = bstrdup(audio_source_name);
			}

			if (!audio_source) {
				audio_source = obs_source_get_ref(obs_filter_get_parent(filter->context));
				if (audio_source && ((obs_source_get_output_flags(audio_source) & OBS_SOURCE_AUDIO) == 0)) {
					obs_source_release(audio_source);
					audio_source = NULL;
				}
			}
			if (audio_source) {
				if (!filter->volmeter) {
					filter->volmeter = obs_volmeter_create(OBS_FADER_LOG);
					obs_volmeter_add_callback(filter->volmeter, shader_filter_audio_callback, filter);
				}
				obs_volmeter_attach_source(filter->volmeter, audio_source);
				obs_source_release(audio_source);
			} else {
				if (filter->volmeter) {
					obs_volmeter_destroy(filter->volmeter);
					filter->volmeter = NULL;
				}
				if (filter->audio_source_name) {
					bfree(filter->audio_source_name);
					filter->audio_source_name = NULL;
				}
			}
		}
	} else {
		if (filter->volmeter) {
			obs_volmeter_destroy(filter->volmeter);
			filter->volmeter = NULL;
		}
		if (filter->audio_source_name) {
			bfree(filter->audio_source_name);
			filter->audio_source_name = NULL;
		}
	}

	size_t param_count = filter->stored_param_list.num;
	for (size_t param_index = 0; param_index < param_count; param_index++) {
		struct effect_param_data *param = (filter->stored_param_list.array + param_index);
		//gs_eparam_t *annot = gs_param_get_annotation_by_idx(param->param, param_index);
		const char *param_name = param->name.array;
		struct dstr sources_name = {0};
		obs_source_t *source = NULL;
		void *default_value = gs_effect_get_default_val(param->param);
		param->has_default = false;
		switch (param->type) {
		case GS_SHADER_PARAM_BOOL:
			if (default_value != NULL) {
				obs_data_set_default_bool(settings, param_name, *(bool *)default_value);
				param->default_value.i = *(bool *)default_value;
				param->has_default = true;
			}
			param->value.i = obs_data_get_bool(settings, param_name);
			break;
		case GS_SHADER_PARAM_FLOAT:
			if (default_value != NULL) {
				obs_data_set_default_double(settings, param_name, *(float *)default_value);
				param->default_value.f = *(float *)default_value;
				param->has_default = true;
			}
			param->value.f = obs_data_get_double(settings, param_name);
			break;
		case GS_SHADER_PARAM_INT:
			if (default_value != NULL) {
				obs_data_set_default_int(settings, param_name, *(int *)default_value);
				param->default_value.i = *(int *)default_value;
				param->has_default = true;
			}
			param->value.i = obs_data_get_int(settings, param_name);
			break;
		case GS_SHADER_PARAM_VEC2: {
			struct vec2 *xy = default_value;

			for (size_t i = 0; i < 2; i++) {
				dstr_printf(&sources_name, "%s_%zu", param_name, i);
				if (xy != NULL) {
					obs_data_set_default_double(settings, sources_name.array, xy->ptr[i]);
					param->default_value.vec2.ptr[i] = xy->ptr[i];
					param->has_default = true;
				}
				param->value.vec2.ptr[i] = (float)obs_data_get_double(settings, sources_name.array);
			}
			dstr_free(&sources_name);
			break;
		}
		case GS_SHADER_PARAM_VEC3: {
			struct vec3 *rgb = default_value;
			if (param->widget_type.array && strcmp(param->widget_type.array, "slider") == 0) {
				for (size_t i = 0; i < 3; i++) {
					dstr_printf(&sources_name, "%s_%zu", param_name, i);
					if (rgb != NULL) {
						obs_data_set_default_double(settings, sources_name.array, rgb->ptr[i]);
						param->default_value.vec3.ptr[i] = rgb->ptr[i];
						param->has_default = true;
					}
					param->value.vec3.ptr[i] = (float)obs_data_get_double(settings, sources_name.array);
				}
				dstr_free(&sources_name);
			} else {
				if (rgb != NULL) {
					struct vec4 rgba;
					vec4_from_vec3(&rgba, rgb);
					obs_data_set_default_int(settings, param_name, vec4_to_rgba(&rgba));
					param->default_value.vec4 = rgba;
					param->has_default = true;
				} else {
					// Hack to ensure we have a default...(white)
					obs_data_set_default_int(settings, param_name, 0xffffffff);
				}
				vec4_from_rgba(&param->value.vec4, (uint32_t)obs_data_get_int(settings, param_name));
			}
			break;
		}
		case GS_SHADER_PARAM_VEC4: {
			struct vec4 *rgba = default_value;
			if (param->widget_type.array && strcmp(param->widget_type.array, "slider") == 0) {
				for (size_t i = 0; i < 4; i++) {
					dstr_printf(&sources_name, "%s_%zu", param_name, i);
					if (rgba != NULL) {
						obs_data_set_default_double(settings, sources_name.array, rgba->ptr[i]);
						param->default_value.vec4.ptr[i] = rgba->ptr[i];
						param->has_default = true;
					}
					param->value.vec4.ptr[i] = (float)obs_data_get_double(settings, sources_name.array);
				}
				dstr_free(&sources_name);
			} else {
				if (rgba != NULL) {
					obs_data_set_default_int(settings, param_name, vec4_to_rgba(rgba));
					param->default_value.vec4 = *rgba;
					param->has_default = true;
				} else {
					// Hack to ensure we have a default...(white)
					obs_data_set_default_int(settings, param_name, 0xffffffff);
				}
				vec4_from_rgba(&param->value.vec4, (uint32_t)obs_data_get_int(settings, param_name));
			}
			break;
		}
		case GS_SHADER_PARAM_TEXTURE:
			dstr_init_copy_dstr(&sources_name, &param->name);
			dstr_cat(&sources_name, "_source");
			const char *sn = obs_data_get_string(settings, sources_name.array);
			dstr_free(&sources_name);
			source = obs_weak_source_get_source(param->source);
			if (source && strcmp(obs_source_get_name(source), sn) != 0) {
				obs_source_release(source);
				source = NULL;
			}
			if (!source)
				source = (sn && strlen(sn)) ? obs_get_source_by_name(sn) : NULL;
			if (source) {
				if (!obs_weak_source_references_source(param->source, source)) {
					if ((!filter->transition || filter->prev_transitioning) &&
					    obs_source_active(filter->context))
						obs_source_inc_active(source);
					if ((!filter->transition || filter->prev_transitioning) &&
					    obs_source_showing(filter->context))
						obs_source_inc_showing(source);

					obs_source_t *old_source = obs_weak_source_get_source(param->source);
					if (old_source) {
						if ((!filter->transition || filter->prev_transitioning) &&
						    obs_source_active(filter->context))
							obs_source_dec_active(old_source);
						if ((!filter->transition || filter->prev_transitioning) &&
						    obs_source_showing(filter->context))
							obs_source_dec_showing(old_source);
						obs_source_release(old_source);
					}
					obs_weak_source_release(param->source);
					param->source = obs_source_get_weak_source(source);
				}
				obs_source_release(source);
				if (param->image) {
					obs_enter_graphics();
					gs_image_file_free_func(param->image);
					obs_leave_graphics();
					bfree(param->image);
					param->image = NULL;
				}
				dstr_free(&param->path);
			} else {
				const char *path = default_value;
				if (!obs_data_has_user_value(settings, param_name) && path && strlen(path)) {
					if (os_file_exists(path)) {
						char *abs_path = os_get_abs_path_ptr(path);
						obs_data_set_default_string(settings, param_name, abs_path);
						bfree(abs_path);
						param->has_default = true;
					} else {
						struct dstr texture_path = {0};
						dstr_init(&texture_path);
						dstr_cat(&texture_path, obs_get_module_data_path(obs_current_module()));
						dstr_cat(&texture_path, "/textures/");
						dstr_cat(&texture_path, path);
						char *abs_path = os_get_abs_path_ptr(texture_path.array);
						if (os_file_exists(abs_path)) {
							obs_data_set_default_string(settings, param_name, abs_path);
							param->has_default = true;
						}
						bfree(abs_path);
						dstr_free(&texture_path);
					}
				}
				path = obs_data_get_string(settings, param_name);
				bool n = false;
				if (param->image == NULL && gs_image_file_create_func) {
					param->image = gs_image_file_create_func();
					n = true;
				}
				if (n || !path || !param->path.array || strcmp(path, param->path.array) != 0) {
					if (gs_image_file_free_func && gs_image_file_init_func && gs_image_file_init_texture_func) {
						if (!n) {
							obs_enter_graphics();
							gs_image_file_free_func(param->image);
							obs_leave_graphics();
						}
						gs_image_file_init_func(param->image, path, GS_IMAGE_ALPHA_PREMULTIPLY_SRGB);
						dstr_copy(&param->path, path);
						obs_enter_graphics();
						gs_image_file_init_texture_func(param->image);
						obs_leave_graphics();
					}
				}
				obs_source_t *old_source = obs_weak_source_get_source(param->source);
				if (old_source) {
					if ((!filter->transition || filter->prev_transitioning) &&
					    obs_source_active(filter->context))
						obs_source_dec_active(old_source);
					if ((!filter->transition || filter->prev_transitioning) &&
					    obs_source_showing(filter->context))
						obs_source_dec_showing(old_source);
					obs_source_release(old_source);
				}
				obs_weak_source_release(param->source);
				param->source = NULL;
			}
			break;
		case GS_SHADER_PARAM_STRING:
			if (default_value != NULL) {
				obs_data_set_default_string(settings, param_name, (const char *)default_value);
				param->has_default = true;
			}
			bfree(param->value.string);
			param->value.string = bstrdup(obs_data_get_string(settings, param_name));
			break;
		default:;
		}
		bfree(default_value);
	}
}

static void prepare_derived(struct shader_filter_data *filter);

static void gpu_publish(struct shader_filter_data *filter);

static void shader_filter_tick(void *data, float seconds)
{
	struct shader_filter_data *filter = data;
	filter->gpu_tick++;
	gpu_publish(filter);
	obs_source_t *target = filter->transition ? filter->context : obs_filter_get_target(filter->context);
	if (!target)
		return;
	// Determine offsets from expansion values.
	int base_width = obs_source_get_base_width(target);
	int base_height = obs_source_get_base_height(target);

	filter->total_width = filter->expand_left + base_width + filter->expand_right;
	filter->total_height = filter->expand_top + base_height + filter->expand_bottom;

	filter->uv_size.x = (float)filter->total_width;
	filter->uv_size.y = (float)filter->total_height;

	if (base_width > 0 && base_height > 0) {
		filter->uv_scale.x = (float)filter->total_width / base_width;
		filter->uv_scale.y = (float)filter->total_height / base_height;

		filter->uv_offset.x = (float)(-filter->expand_left) / base_width;
		filter->uv_offset.y = (float)(-filter->expand_top) / base_height;

		filter->uv_pixel_interval.x = 1.0f / base_width;
		filter->uv_pixel_interval.y = 1.0f / base_height;
	}

	if (filter->shader_start_time == 0.0f) {
		filter->shader_start_time = filter->elapsed_time + seconds;
	}
	filter->elapsed_time += seconds;
	filter->elapsed_time_loop += seconds;
	if (filter->elapsed_time_loop > 1.0f) {
		filter->elapsed_time_loop -= 1.0f;

		// Loops
		filter->loops += 1;
		if (filter->loops >= 4194304)
			filter->loops = -filter->loops;
	}
	filter->local_time = (float)(os_gettime_ns() / 1000000000.0);
	if (filter->enabled != obs_source_enabled(filter->context)) {
		filter->enabled = !filter->enabled;
		if (filter->enabled)
			filter->shader_enable_time = filter->elapsed_time;
	}
	obs_source_t *parent = obs_filter_get_parent(filter->context);
	if (obs_source_enabled(filter->context) && parent && obs_source_active(parent)) {
		filter->shader_active_time += seconds;
	} else {
		filter->shader_active_time = 0.0f;
	}
	if (obs_source_enabled(filter->context) && parent && obs_source_showing(parent)) {
		filter->shader_show_time += seconds;
	} else {
		filter->shader_show_time = 0.0f;
	}

	// undecided between this and "rand_float(1);"
	filter->rand_f = (float)((double)rand_interval(0, 10000) / (double)10000);

	if (filter->volmeter) {
		filter->audio_peak = filter->current_audio_peak;
		filter->audio_magnitude = filter->current_audio_magnitude;
	} else {
		filter->audio_peak = 0.0f;
		filter->audio_magnitude = 0.0f;
	}

	filter->output_rendered = false;
	filter->input_rendered = false;
	filter->output_form = 0;

	/* How the last frame drew this filter, for its settings panel. */
	filter->gpu_merged = filter->frame_merged;
	filter->gpu_group = filter->frame_group ? filter->frame_group : 1;
	filter->frame_merged = false;
	filter->frame_group = 0;

	if (gs_image_file_tick_func && gs_image_file_update_texture_func) {
		uint64_t frame_time = obs_get_video_frame_time();
		if (filter->last_frame_time) {
			bool g = false;
			uint64_t elapsed = frame_time - filter->last_frame_time;
			size_t param_count = filter->stored_param_list.num;
			for (size_t param_index = 0; param_index < param_count; param_index++) {
				struct effect_param_data *param = (filter->stored_param_list.array + param_index);
				if (!param->image)
					continue;

				bool updated = gs_image_file_tick_func(param->image, elapsed);
				if (updated) {
					if (!g) {
						obs_enter_graphics();
						g = true;
					}
					gs_image_file_update_texture_func(param->image);
				}
			}
			if (g) {
				obs_leave_graphics();
			}
		}
		filter->last_frame_time = frame_time;
	}

	if (!filter->transition)
		prepare_derived(filter);
}

gs_texrender_t *create_or_reset_texrender(gs_texrender_t *render, const enum gs_color_format format)
{
	if (render && gs_texrender_get_format(render) != format) {
		gs_texrender_destroy(render);
		render = NULL;
	}
	if (!render) {
		render = gs_texrender_create(format, GS_ZS_NONE);
	} else {
		gs_texrender_reset(render);
	}
	return render;
}

static void get_input_source(struct shader_filter_data *filter)
{
	if (filter->input_rendered)
		return;

	// Use the OBS default effect file as our effect.
	gs_effect_t *pass_through = obs_get_base_effect(OBS_EFFECT_DEFAULT);

	// Set up our color space info.
	const enum gs_color_space preferred_spaces[] = {
		GS_CS_SRGB,
		GS_CS_SRGB_16F,
		GS_CS_709_EXTENDED,
	};

	const enum gs_color_space source_space =
		obs_source_get_color_space(obs_filter_get_target(filter->context), OBS_COUNTOF(preferred_spaces), preferred_spaces);

	const enum gs_color_format format = gs_get_format_from_space(source_space);

	if (filter->param_previous_image) {
		gs_texrender_t *temp = filter->input_texrender;
		filter->input_texrender = filter->previous_input_texrender;
		filter->previous_input_texrender = temp;
	}

	// Set up our input_texrender to catch the output texture.
	filter->input_texrender = create_or_reset_texrender(filter->input_texrender, format);

	// Start the rendering process with our correct color space params,
	// And set up your texrender to recieve the created texture.
	// Without expansion, libobs may let an image source draw itself straight
	// through DrawAlphaDivide into our texture instead of first rendering it
	// into its own (one full-screen pass fewer). With expansion the input must
	// be stretched from libobs' texture as before.
	// Only the image source is known to draw a single sprite: drawn directly
	// with blending off, a source compositing several translucent primitives
	// would come out differently.
	const bool expanded = filter->expand_left || filter->expand_right || filter->expand_top || filter->expand_bottom;
	obs_source_t *parent = obs_filter_get_parent(filter->context);
	const bool direct = !expanded && source_space == GS_CS_SRGB && parent &&
			    obs_filter_get_target(filter->context) == parent &&
			    strcmp(obs_source_get_id(parent), "image_source") == 0;
	if (!filter->transition &&
	    !obs_source_process_filter_begin_with_color_space(filter->context, format, source_space,
							      direct ? OBS_ALLOW_DIRECT_RENDERING : OBS_NO_DIRECT_RENDERING))
		return;

	if (gs_texrender_begin(filter->input_texrender, filter->total_width, filter->total_height)) {

		gs_blend_state_push();
		gs_reset_blend_state();
		gs_enable_blending(false);
		gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);

		if (direct) {
			// A source drawing itself need not cover the whole texture.
			struct vec4 clear_color;
			vec4_zero(&clear_color);
			gs_clear(GS_CLEAR_COLOR, &clear_color, 0.0f, 0);
		}

		gs_ortho(0.0f, (float)filter->total_width, 0.0f, (float)filter->total_height, -100.0f, 100.0f);
		// The incoming source is pre-multiplied alpha, so use the
		// OBS default effect "DrawAlphaDivide" technique to convert
		// the colors back into non-pre-multiplied space. If the shader
		// file has #define USE_PM_ALPHA 1, then use normal "Draw"
		// technique.
		const char *technique = filter->use_pm_alpha ? "Draw" : "DrawAlphaDivide";
		if (!filter->transition)
			obs_source_process_filter_tech_end(filter->context, pass_through, filter->total_width, filter->total_height,
							   technique);
		gs_texrender_end(filter->input_texrender);
		gs_blend_state_pop();
		filter->input_rendered = true;
	}
}

void shader_filter_set_effect_params(struct shader_filter_data *filter)
{

	if (filter->param_uv_scale != NULL) {
		gs_effect_set_vec2(filter->param_uv_scale, &filter->uv_scale);
	}
	if (filter->param_uv_offset != NULL) {
		gs_effect_set_vec2(filter->param_uv_offset, &filter->uv_offset);
	}
	if (filter->param_uv_pixel_interval != NULL) {
		gs_effect_set_vec2(filter->param_uv_pixel_interval, &filter->uv_pixel_interval);
	}
	if (filter->param_current_time_ms != NULL) {
#ifdef _WIN32
		SYSTEMTIME system_time;
		GetSystemTime(&system_time);
		gs_effect_set_int(filter->param_current_time_ms, system_time.wMilliseconds);
#else
		struct timeval tv;
		gettimeofday(&tv, NULL);
		gs_effect_set_int(filter->param_current_time_ms, tv.tv_usec / 1000);
#endif
	}
	if (filter->param_current_time_sec != NULL || filter->param_current_time_min != NULL ||
	    filter->param_current_time_hour != NULL || filter->param_current_time_day_of_week != NULL ||
	    filter->param_current_time_day_of_month != NULL || filter->param_current_time_month != NULL ||
	    filter->param_current_time_day_of_year != NULL || filter->param_current_time_year != NULL) {
		time_t t = time(NULL);
		struct tm *lt = localtime(&t);
		if (filter->param_current_time_sec != NULL)
			gs_effect_set_int(filter->param_current_time_sec, lt->tm_sec);
		if (filter->param_current_time_min != NULL)
			gs_effect_set_int(filter->param_current_time_min, lt->tm_min);
		if (filter->param_current_time_hour != NULL)
			gs_effect_set_int(filter->param_current_time_hour, lt->tm_hour);
		if (filter->param_current_time_day_of_week != NULL)
			gs_effect_set_int(filter->param_current_time_day_of_week, lt->tm_wday);
		if (filter->param_current_time_day_of_month != NULL)
			gs_effect_set_int(filter->param_current_time_day_of_month, lt->tm_mday);
		if (filter->param_current_time_month != NULL)
			gs_effect_set_int(filter->param_current_time_month, lt->tm_mon);
		if (filter->param_current_time_day_of_year != NULL)
			gs_effect_set_int(filter->param_current_time_day_of_year, lt->tm_yday);
		if (filter->param_current_time_year != NULL)
			gs_effect_set_int(filter->param_current_time_year, lt->tm_year);
	}
	if (filter->param_elapsed_time != NULL) {
		gs_effect_set_float(filter->param_elapsed_time, filter->elapsed_time);
	}
	if (filter->param_elapsed_time_start != NULL) {
		gs_effect_set_float(filter->param_elapsed_time_start, filter->elapsed_time - filter->shader_start_time);
	}
	if (filter->param_elapsed_time_show != NULL) {
		gs_effect_set_float(filter->param_elapsed_time_show, filter->shader_show_time);
	}
	if (filter->param_elapsed_time_active != NULL) {
		gs_effect_set_float(filter->param_elapsed_time_active, filter->shader_active_time);
	}
	if (filter->param_elapsed_time_enable != NULL) {
		gs_effect_set_float(filter->param_elapsed_time_enable, filter->elapsed_time - filter->shader_enable_time);
	}
	if (filter->param_uv_size != NULL) {
		gs_effect_set_vec2(filter->param_uv_size, &filter->uv_size);
	}
	if (filter->param_local_time != NULL) {
		gs_effect_set_float(filter->param_local_time, filter->local_time);
	}
	if (filter->param_audio_peak != NULL) {
		gs_effect_set_float(filter->param_audio_peak, filter->audio_peak);
	}
	if (filter->param_audio_magnitude != NULL) {
		gs_effect_set_float(filter->param_audio_magnitude, filter->audio_magnitude);
	}
	if (filter->param_loops != NULL) {
		gs_effect_set_int(filter->param_loops, filter->loops);
	}
	if (filter->param_loop_second != NULL) {
		gs_effect_set_float(filter->param_loop_second, filter->elapsed_time_loop);
	}
	if (filter->param_rand_f != NULL) {
		gs_effect_set_float(filter->param_rand_f, filter->rand_f);
	}
	if (filter->param_rand_activation_f != NULL) {
		gs_effect_set_float(filter->param_rand_activation_f, filter->rand_activation_f);
	}
	if (filter->param_rand_instance_f != NULL) {
		gs_effect_set_float(filter->param_rand_instance_f, filter->rand_instance_f);
	}

	size_t param_count = filter->stored_param_list.num;
	for (size_t param_index = 0; param_index < param_count; param_index++) {
		struct effect_param_data *param = (filter->stored_param_list.array + param_index);
		if (!param->param)
			continue;
		obs_source_t *source = NULL;

		switch (param->type) {
		case GS_SHADER_PARAM_BOOL:
			gs_effect_set_bool(param->param, param->value.i);
			break;
		case GS_SHADER_PARAM_FLOAT:
			gs_effect_set_float(param->param, (float)param->value.f);
			break;
		case GS_SHADER_PARAM_INT:
			gs_effect_set_int(param->param, (int)param->value.i);
			break;
		case GS_SHADER_PARAM_VEC2:
			gs_effect_set_vec2(param->param, &param->value.vec2);
			break;
		case GS_SHADER_PARAM_VEC3:
			gs_effect_set_vec3(param->param, &param->value.vec3);
			break;
		case GS_SHADER_PARAM_VEC4:
			gs_effect_set_vec4(param->param, &param->value.vec4);
			break;
		case GS_SHADER_PARAM_TEXTURE:
			source = obs_weak_source_get_source(param->source);
			if (source) {
				const enum gs_color_space preferred_spaces[] = {
					GS_CS_SRGB,
					GS_CS_SRGB_16F,
					GS_CS_709_EXTENDED,
				};
				const enum gs_color_space space =
					obs_source_get_color_space(source, OBS_COUNTOF(preferred_spaces), preferred_spaces);
				const enum gs_color_format format = gs_get_format_from_space(space);
				if (!param->render || gs_texrender_get_format(param->render) != format) {
					gs_texrender_destroy(param->render);
					param->render = gs_texrender_create(format, GS_ZS_NONE);
				} else {
					gs_texrender_reset(param->render);
				}
				uint32_t base_width = obs_source_get_base_width(source);
				uint32_t base_height = obs_source_get_base_height(source);
				gs_blend_state_push();
				gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);
				if (gs_texrender_begin_with_color_space(param->render, base_width, base_height, space)) {
					const float w = (float)base_width;
					const float h = (float)base_height;
					uint32_t flags = obs_source_get_output_flags(source);
					const bool custom_draw = (flags & OBS_SOURCE_CUSTOM_DRAW) != 0;
					const bool async = (flags & OBS_SOURCE_ASYNC) != 0;
					struct vec4 clear_color;

					vec4_zero(&clear_color);
					gs_clear(GS_CLEAR_COLOR, &clear_color, 0.0f, 0);
					gs_ortho(0.0f, w, 0.0f, h, -100.0f, 100.0f);

					if (!custom_draw && !async)
						obs_source_default_render(source);
					else
						obs_source_video_render(source);
					gs_texrender_end(param->render);
				}
				gs_blend_state_pop();
				obs_source_release(source);
				gs_texture_t *tex = gs_texrender_get_texture(param->render);
				gs_effect_set_texture(param->param, tex);
			} else if (param->image) {
				gs_effect_set_texture(param->param, param->image->texture);
			} else {
				gs_effect_set_texture(param->param, NULL);
			}

			break;
		case GS_SHADER_PARAM_STRING:
			if (param->value.string)
				gs_effect_set_val(param->param, param->value.string, strlen(param->value.string) + 1);
			break;
		default:;
		}
	}
}

static void build_sprite(struct gs_vb_data *data, float fcx, float fcy, float start_u, float end_u, float start_v, float end_v)
{
	struct vec2 *tvarray = data->tvarray[0].array;

	vec3_zero(data->points);
	vec3_set(data->points + 1, fcx, 0.0f, 0.0f);
	vec3_set(data->points + 2, 0.0f, fcy, 0.0f);
	vec3_set(data->points + 3, fcx, fcy, 0.0f);
	vec2_set(tvarray, start_u, start_v);
	vec2_set(tvarray + 1, end_u, start_v);
	vec2_set(tvarray + 2, start_u, end_v);
	vec2_set(tvarray + 3, end_u, end_v);
}

static inline void build_sprite_norm(struct gs_vb_data *data, float fcx, float fcy)
{
	build_sprite(data, fcx, fcy, 0.0f, 1.0f, 0.0f, 1.0f);
}

static enum gs_color_space shader_filter_get_color_space(void *data, size_t count, const enum gs_color_space *preferred_spaces)
{
	UNUSED_PARAMETER(count);
	UNUSED_PARAMETER(preferred_spaces);
	struct shader_filter_data *filter = data;
	obs_source_t *target = obs_filter_get_target(filter->context);
	const enum gs_color_space potential_spaces[] = {
		GS_CS_SRGB,
		GS_CS_SRGB_16F,
		GS_CS_709_EXTENDED,
	};
	return obs_source_get_color_space(target, OBS_COUNTOF(potential_spaces), potential_spaces);
}

/* Swap/reset output_texrender for this frame's draw. */
static void prepare_output(struct shader_filter_data *filter)
{
	if (filter->param_previous_output) {
		gs_texrender_t *temp = filter->output_texrender;
		filter->output_texrender = filter->previous_output_texrender;
		filter->previous_output_texrender = temp;
	}

	enum gs_color_space space = shader_filter_get_color_space(filter, 0, NULL);
	enum gs_color_format format = gs_get_format_from_space(space);
	filter->output_texrender = create_or_reset_texrender(filter->output_texrender, format);
}

/* Set every uniform of the filter's own effect for this frame, with `texture`
 * as its input image (and move-transition interpolation applied). */
static void bind_shader_params(struct shader_filter_data *filter, gs_texture_t *texture, float f, obs_source_t *filter_to)
{
	if (filter->param_image)
		gs_effect_set_texture(filter->param_image, texture);
	if (filter->param_previous_image)
		gs_effect_set_texture(filter->param_previous_image, gs_texrender_get_texture(filter->previous_input_texrender));
	if (filter->param_previous_output)
		gs_effect_set_texture(filter->param_previous_output, gs_texrender_get_texture(filter->previous_output_texrender));

	shader_filter_set_effect_params(filter);

	if (f > 0.0f) {
		if (filter_to) {
			struct shader_filter_data *filter2 = obs_obj_get_data(filter_to);
			if (strcmp(obs_source_get_id(filter_to), obs_source_get_id(filter->context)) != 0)
				filter2 = NULL;
			for (size_t i = 0; filter2 && i < filter->stored_param_list.num; i++) {
				struct effect_param_data *param = (filter->stored_param_list.array + i);
				if (!param->param)
					continue;

				for (size_t j = 0; j < filter2->stored_param_list.num; j++) {
					struct effect_param_data *param2 = (filter2->stored_param_list.array + j);
					if (!param2->param)
						continue;
					if (param->type != param2->type)
						continue;
					if (strcmp(param->name.array, param2->name.array) != 0)
						continue;

					switch (param->type) {
					case GS_SHADER_PARAM_FLOAT:
						gs_effect_set_float(param->param, (float)param2->value.f * f +
											  (float)param->value.f * (1.0f - f));
						break;
					case GS_SHADER_PARAM_INT:
						gs_effect_set_int(param->param, (int)((double)param2->value.i * f +
										      (double)param->value.i * (1.0f - f)));
						break;
					case GS_SHADER_PARAM_VEC2: {
						struct vec2 v2;
						v2.x = (float)param2->value.vec2.x * f + (float)param->value.vec2.x * (1.0f - f);
						v2.y = (float)param2->value.vec2.y * f + (float)param->value.vec2.y * (1.0f - f);
						gs_effect_set_vec2(param->param, &v2);
						break;
					}
					case GS_SHADER_PARAM_VEC3: {
						struct vec3 v3;
						v3.x = (float)param2->value.vec3.x * f + (float)param->value.vec3.x * (1.0f - f);
						v3.y = (float)param2->value.vec3.y * f + (float)param->value.vec3.y * (1.0f - f);
						v3.z = (float)param2->value.vec3.z * f + (float)param->value.vec3.z * (1.0f - f);
						gs_effect_set_vec3(param->param, &v3);
						break;
					}
					case GS_SHADER_PARAM_VEC4: {
						struct vec4 v4;
						v4.x = (float)param2->value.vec4.x * f + (float)param->value.vec4.x * (1.0f - f);
						v4.y = (float)param2->value.vec4.y * f + (float)param->value.vec4.y * (1.0f - f);
						v4.z = (float)param2->value.vec4.z * f + (float)param->value.vec4.z * (1.0f - f);
						v4.w = (float)param2->value.vec4.w * f + (float)param->value.vec4.w * (1.0f - f);
						gs_effect_set_vec4(param->param, &v4);
						break;
					}
					default:;
					}
					break;
				}
			}
		} else {
			for (size_t i = 0; i < filter->stored_param_list.num; i++) {
				struct effect_param_data *param = (filter->stored_param_list.array + i);
				if (!param->param || !param->has_default)
					continue;

				switch (param->type) {
				case GS_SHADER_PARAM_FLOAT:
					gs_effect_set_float(param->param,
							    (float)param->default_value.f * f + (float)param->value.f * (1.0f - f));
					break;
				case GS_SHADER_PARAM_INT:
					gs_effect_set_int(param->param, (int)((double)param->default_value.i * f +
									      (double)param->value.i * (1.0f - f)));
					break;
				case GS_SHADER_PARAM_VEC2: {
					struct vec2 v2;
					v2.x = param->default_value.vec2.x * f + param->value.vec2.x * (1.0f - f);
					v2.y = param->default_value.vec2.y * f + param->value.vec2.y * (1.0f - f);
					gs_effect_set_vec2(param->param, &v2);
					break;
				}
				case GS_SHADER_PARAM_VEC3: {
					struct vec3 v3;
					v3.x = param->default_value.vec3.x * f + param->value.vec3.x * (1.0f - f);
					v3.y = param->default_value.vec3.y * f + param->value.vec3.y * (1.0f - f);
					v3.z = param->default_value.vec3.z * f + param->value.vec3.z * (1.0f - f);
					gs_effect_set_vec3(param->param, &v3);
					break;
				}
				case GS_SHADER_PARAM_VEC4: {
					struct vec4 v4;
					v4.x = param->default_value.vec4.x * f + param->value.vec4.x * (1.0f - f);
					v4.y = param->default_value.vec4.y * f + param->value.vec4.y * (1.0f - f);
					v4.z = param->default_value.vec4.z * f + param->value.vec4.z * (1.0f - f);
					v4.w = param->default_value.vec4.w * f + param->value.vec4.w * (1.0f - f);
					gs_effect_set_vec4(param->param, &v4);
					break;
				}
				default:;
				}
			}
		}
	}
}

/* Draw `effect` (the filter's own or a fused one) into output_texrender. */
/* Forms a filter's output can be rendered in (see effect_template_end). */
enum out_form {
	OUT_RAW,    /* the shader's own output ("Draw") */
	OUT_LINKED, /* after the filter boundary, straight alpha ("DrawLinked") */
	OUT_PREMUL, /* half way through the boundary ("DrawPremul") */
};

static const char *out_form_technique(enum out_form form)
{
	return form == OUT_LINKED ? "DrawLinked" : form == OUT_PREMUL ? "DrawPremul" : "Draw";
}

/* Read a query old enough to be finished into the running average. */
static void gpu_timer_collect(struct shader_filter_data *filter, struct gpu_timer_slot *slot)
{
	bool disjoint = false;
	uint64_t frequency = 0, ticks = 0;
	slot->pending = false;
	if (!gs_timer_range_get_data(slot->range, &disjoint, &frequency) || !gs_timer_get_data(slot->timer, &ticks))
		return;
	if (!disjoint && frequency) {
		filter->gpu_sum_ms += (double)ticks * 1000.0 / (double)frequency;
		filter->gpu_samples++;
	}
}

static struct gpu_timer_slot *gpu_timer_begin(struct shader_filter_data *filter)
{
	struct gpu_timer_slot *slot = &filter->gpu_slots[filter->gpu_slot];
	if (!slot->timer) {
		slot->timer = gs_timer_create();
		slot->range = gs_timer_range_create();
	}
	if (!slot->timer)
		return NULL;
	if (slot->pending) {
		if (filter->gpu_tick - slot->issued_tick < GPU_TIMER_AGE)
			return NULL;
		gpu_timer_collect(filter, slot);
	}
	gs_timer_range_begin(slot->range);
	gs_timer_begin(slot->timer);
	return slot;
}

static void gpu_timer_end(struct shader_filter_data *filter, struct gpu_timer_slot *slot)
{
	if (!slot)
		return;
	gs_timer_end(slot->timer);
	gs_timer_range_end(slot->range);
	slot->pending = true;
	slot->issued_tick = filter->gpu_tick;
	filter->gpu_slot = (filter->gpu_slot + 1) % GPU_TIMER_SLOTS;
}

static void draw_shader(struct shader_filter_data *filter, gs_effect_t *effect, gs_texture_t *texture, enum out_form form)
{
	/* This is the filter's own pass (with any filters merged into it); the
	 * passes of filters before it happen before this, so aren't counted. */
	struct gpu_timer_slot *timing = gpu_timer_begin(filter);

	gs_blend_state_push();
	gs_reset_blend_state();
	gs_enable_blending(false);
	gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);

	if (gs_texrender_begin(filter->output_texrender, filter->total_width, filter->total_height)) {
		gs_ortho(0.0f, (float)filter->total_width, 0.0f, (float)filter->total_height, -100.0f, 100.0f);
		const char *technique = out_form_technique(form);
		while (gs_effect_loop(effect, technique)) {
			if (filter->use_template) {
				gs_draw_sprite(texture, 0, filter->total_width, filter->total_height);
			} else {
				if (!filter->sprite_buffer)
					load_sprite_buffer(filter);

				struct gs_vb_data *data = gs_vertexbuffer_get_data(filter->sprite_buffer);
				build_sprite_norm(data, (float)filter->total_width, (float)filter->total_height);
				gs_vertexbuffer_flush(filter->sprite_buffer);
				gs_load_vertexbuffer(filter->sprite_buffer);
				gs_load_indexbuffer(NULL);
				gs_draw(GS_TRISTRIP, 0, 0);
			}
		}
		gs_texrender_end(filter->output_texrender);
	}

	gs_blend_state_pop();
	gpu_timer_end(filter, timing);
}

static void render_shader(struct shader_filter_data *filter, gs_texture_t *texture, float f, obs_source_t *filter_to,
			  enum out_form form)
{
	if (!texture)
		return;
	prepare_output(filter);
	bind_shader_params(filter, texture, f, filter_to);
	draw_shader(filter, filter->effect, texture, form);
}

/* ------------------------------------------------------------------------
 * Linked rendering of consecutive shader filters.
 *
 * Normally every filter makes libobs render its upstream into a texture, then
 * copies that (un-premultiplying alpha), runs its shader, and draws the result
 * into the downstream's texture: three full-screen passes per filter.
 *
 * When the filter directly upstream (skipping disabled filters) is another
 * shader filter, this filter instead asks it for its shader output texture and
 * samples that as `image`. The upstream renders with its "DrawLinked"
 * technique, which applies in-shader what the skipped passes would have done
 * to the pixels. Only the first filter of such a run captures its input
 * through libobs, and only the last one draws into the caller's target, so a
 * run of N filters costs N + 2 passes instead of 3N + 1 (the first filter lets
 * a plain source draw itself straight into its input texture).
 *
 * A downstream filter that needs its own input copy (expansion stretches it,
 * previous_image keeps last frame's) gets it with one DrawAlphaDivide copy of
 * the upstream's "DrawPremul" output, which is what libobs' texture would have
 * held, instead of two passes through libobs. Runs whose later filters only
 * read their input at their own pixel are further fused into a single pass
 * (shader-fusion.h).
 *
 * The normal path is kept for anything a link cannot reproduce: full .effect
 * files, a .shader with its own technique, previous_output or USE_PM_ALPHA
 * upstream, and non-SDR colour spaces.
 * ------------------------------------------------------------------------ */

static const char *shader_filter_id = "shader_filter";

/* How a filter takes its input from a shader filter directly upstream. */
enum link_kind {
	LINK_DIRECT,    /* sample the upstream's OUT_LINKED output as `image` */
	LINK_DIRECT_PM, /* USE_PM_ALPHA: sample its OUT_PREMUL output as `image` */
	LINK_COPY,      /* copy its OUT_PREMUL output into our input texture with
			   DrawAlphaDivide/Draw, as libobs' texture would have been
			   (expansion stretches it; previous_image keeps the copy) */
};

/* On success *ref holds a reference to the upstream filter, as libobs holds
 * one on a source while rendering it, so it can't be destroyed (on libobs'
 * destruction thread) while we use its data; release it after drawing.
 * check_size is false only when preparing effects ahead, before sources have
 * their sizes. */
static struct shader_filter_data *linked_upstream(struct shader_filter_data *filter, enum link_kind *kind,
						  obs_source_t **ref, bool check_size)
{
	*ref = NULL;
	if (filter->transition)
		return NULL;
	const int ex = filter->expand_left + filter->expand_right;
	const int ey = filter->expand_top + filter->expand_bottom;
	const bool copy = ex || ey || filter->param_previous_image;
	*kind = copy ? LINK_COPY : filter->use_pm_alpha ? LINK_DIRECT_PM : LINK_DIRECT;

	obs_source_t *target = obs_filter_get_target(filter->context);
	while (target && obs_source_get_type(target) == OBS_SOURCE_TYPE_FILTER && !obs_source_enabled(target))
		target = obs_filter_get_target(target);
	if (!target || obs_source_get_type(target) != OBS_SOURCE_TYPE_FILTER)
		return NULL;
	if (strcmp(obs_source_get_id(target), shader_filter_id) != 0)
		return NULL;

	obs_source_t *held = obs_source_get_ref(target);
	if (!held)
		return NULL;
	struct shader_filter_data *up = obs_obj_get_data(held);
	/* shader_body is only kept for plain template shaders. */
	bool ok = up && up->effect && up->shader_body && !up->rendering && !up->param_previous_output;
	/* Our base size is the upstream's output size. */
	if (ok && check_size)
		ok = up->total_width == filter->total_width - ex && up->total_height == filter->total_height - ey &&
		     up->total_width && up->total_height;
	ok = ok && shader_filter_get_color_space(filter, 0, NULL) == GS_CS_SRGB;
	if (!ok) {
		obs_source_release(held);
		return NULL;
	}
	*ref = held;
	return up;
}

static void release_refs(obs_source_t **refs, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		obs_source_release(refs[i]);
		refs[i] = NULL;
	}
}

static bool fusion_disabled(void)
{
	static int disabled = -1;
	if (disabled < 0) {
		const char *e = getenv("SHADERFILTER_NO_FUSION");
		disabled = e && *e && *e != '0';
	}
	return disabled;
}

/* The longest run ending at `last` in which every filter after the first only
 * reads its input at its own pixel, upstream first; at least `last` itself.
 * refs[i] holds a reference for every stage but `last` (the caller's). */
static size_t collect_fusion_group(struct shader_filter_data *last, struct shader_filter_data **stages,
				   obs_source_t **refs, bool check_size)
{
	struct shader_filter_data *rev[SF_MAX_FUSED];
	obs_source_t *rev_refs[SF_MAX_FUSED];
	size_t n = 0;
	struct shader_filter_data *cur = last;
	rev_refs[n] = NULL;
	rev[n++] = cur;
	while (n < SF_MAX_FUSED && cur->pointwise && !fusion_disabled()) {
		enum link_kind kind;
		obs_source_t *ref;
		struct shader_filter_data *up = linked_upstream(cur, &kind, &ref, check_size);
		if (up && (kind != LINK_DIRECT || !up->can_feed)) {
			obs_source_release(ref);
			up = NULL;
		}
		if (!up)
			break;
		rev_refs[n] = ref;
		rev[n++] = up;
		cur = up;
	}
	for (size_t i = 0; i < n; i++) {
		stages[i] = rev[n - 1 - i];
		refs[i] = rev_refs[n - 1 - i];
	}
	return n;
}

static struct derived_effect *find_derived(struct shader_filter_data *last, struct shader_filter_data **stages, size_t n)
{
	for (size_t k = 0; k < SF_DERIVED_CACHE; k++) {
		struct derived_effect *de = last->derived[k];
		if (!de || de->count != n)
			continue;
		bool same = true;
		for (size_t i = 0; i < n && same; i++)
			same = de->stages[i] == stages[i] && de->gens[i] == stages[i]->effect_gen;
		if (same) {
			de->last_used = ++derived_use_counter;
			return de;
		}
	}
	return NULL;
}

/* Compile the derived effect for `stages` (which ends at `last`) into the
 * least recently used cache slot. The failure is cached too. */
static struct derived_effect *build_derived(struct shader_filter_data *last, struct shader_filter_data **stages, size_t n)
{
	size_t slot = 0;
	for (size_t k = 0; k < SF_DERIVED_CACHE; k++) {
		if (!last->derived[k]) {
			slot = k;
			break;
		}
		if (last->derived[k]->last_used < last->derived[slot]->last_used)
			slot = k;
	}
	derived_effect_destroy(last->derived[slot]);

	struct derived_effect *de = bzalloc(sizeof(*de));
	de->count = n;
	de->last_used = ++derived_use_counter;
	da_init(de->copies);
	const char *bodies[SF_MAX_FUSED];
	for (size_t i = 0; i < n; i++) {
		de->stages[i] = stages[i];
		de->gens[i] = stages[i]->effect_gen;
		bodies[i] = stages[i]->shader_body;
	}
	last->derived[slot] = de;

	const char *name = obs_source_get_name(last->context);

	/* libobs binds at most GS_MAX_TEXTURES textures per shader. */
	size_t textures = 0;
	for (size_t i = 0; i < n; i++) {
		size_t count = gs_effect_get_num_params(stages[i]->effect);
		for (size_t k = 0; k < count; k++) {
			struct gs_effect_param_info info;
			gs_effect_get_param_info(gs_effect_get_param_by_idx(stages[i]->effect, k), &info);
			if (info.type == GS_SHADER_PARAM_TEXTURE)
				textures++;
		}
	}
	if (textures > GS_MAX_TEXTURES) {
		blog(LOG_INFO, "[obs-shaderfilter] '%s': rendering %zu filters separately; %zu textures is too many for one pass",
		     name, n, textures);
		de->failed = true;
		return de;
	}

	char *text = sf_fusion_build(bodies, n, effect_template_begin, effect_template_end_derived);
	if (!text) {
		blog(LOG_INFO, "[obs-shaderfilter] '%s': rendering %zu filters separately; they can't be combined", name, n);
		de->failed = true;
		return de;
	}
	struct dstr effect_text = {0};
	dstr_cat(&effect_text, text);
	bfree(text);
	if (gs_get_device_type() == GS_DEVICE_OPENGL) {
		dstr_replace(&effect_text, "[loop]", "");
		dstr_insert(&effect_text, 0, "#define OPENGL 1\n");
	}
	char *errors = NULL;
	de->effect = gs_effect_create(effect_text.array, NULL, &errors);
	dstr_free(&effect_text);
	if (!de->effect) {
		blog(LOG_INFO, "[obs-shaderfilter] '%s': rendering %zu filter(s) the normal way; derived effect failed: %s",
		     name, n, errors ? errors : "(no errors)");
		bfree(errors);
		de->failed = true;
		return de;
	}
	bfree(errors);

	/* Every uniform of every stage must exist under its expected name, or
	 * a stage would silently render with a default value. */
	for (size_t i = 0; i < n && !de->failed; i++) {
		gs_effect_t *own = stages[i]->effect;
		size_t count = gs_effect_get_num_params(own);
		for (size_t k = 0; k < count; k++) {
			gs_eparam_t *src = gs_effect_get_param_by_idx(own, k);
			struct gs_effect_param_info info;
			gs_effect_get_param_info(src, &info);
			if (strcmp(info.name, "ViewProj") == 0)
				continue;
			char *pname = sf_fusion_param_name(i, n, info.name);
			gs_eparam_t *dst = gs_effect_get_param_by_name(de->effect, pname);
			if (!dst) {
				blog(LOG_INFO,
				     "[obs-shaderfilter] '%s': rendering %zu filters separately; uniform '%s' not found when combined",
				     name, n, pname);
				de->failed = true;
			}
			bfree(pname);
			if (!dst)
				break;
			struct fused_param_copy c = {src, dst};
			da_push_back(de->copies, &c);
		}
	}
	if (de->failed) {
		gs_effect_destroy(de->effect);
		de->effect = NULL;
		da_free(de->copies);
		return de;
	}
	if (n > 1)
		blog(LOG_INFO, "[obs-shaderfilter] '%s': combined %zu filters into one pass", name, n);
	return de;
}

static bool shader_filter_produce(struct shader_filter_data *filter, enum out_form form);

/* Make input_texrender from an upstream filter's OUT_PREMUL output exactly as
 * get_input_source() would from libobs' texture of it. */
static void copy_linked_input(struct shader_filter_data *filter, gs_texture_t *src)
{
	if (filter->param_previous_image) {
		gs_texrender_t *temp = filter->input_texrender;
		filter->input_texrender = filter->previous_input_texrender;
		filter->previous_input_texrender = temp;
	}
	filter->input_texrender = create_or_reset_texrender(filter->input_texrender, GS_RGBA);

	if (gs_texrender_begin(filter->input_texrender, filter->total_width, filter->total_height)) {
		gs_blend_state_push();
		gs_reset_blend_state();
		gs_enable_blending(false);
		gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);
		gs_ortho(0.0f, (float)filter->total_width, 0.0f, (float)filter->total_height, -100.0f, 100.0f);

		const bool previous_linear = gs_set_linear_srgb(true);
		const bool previous_fb = gs_framebuffer_srgb_enabled();
		gs_enable_framebuffer_srgb(true);
		gs_effect_t *effect = obs_get_base_effect(OBS_EFFECT_DEFAULT);
		gs_effect_set_texture_srgb(gs_effect_get_param_by_name(effect, "image"), src);
		const char *technique = filter->use_pm_alpha ? "Draw" : "DrawAlphaDivide";
		while (gs_effect_loop(effect, technique))
			gs_draw_sprite(src, 0, filter->total_width, filter->total_height);
		gs_enable_framebuffer_srgb(previous_fb);
		gs_set_linear_srgb(previous_linear);

		gs_texrender_end(filter->input_texrender);
		gs_blend_state_pop();
		filter->input_rendered = true;
	}
}

/* This frame's input texture for `filter`: from a linked upstream shader
 * filter where possible, otherwise captured through libobs. *ref may receive
 * a reference to the upstream filter, to release once the input is drawn. */
static gs_texture_t *acquire_input(struct shader_filter_data *filter, obs_source_t **ref)
{
	enum link_kind kind;
	struct shader_filter_data *up = linked_upstream(filter, &kind, ref, true);
	if (up) {
		if (kind == LINK_DIRECT && shader_filter_produce(up, OUT_LINKED))
			return gs_texrender_get_texture(up->output_texrender);
		if (kind == LINK_DIRECT_PM && shader_filter_produce(up, OUT_PREMUL))
			return gs_texrender_get_texture(up->output_texrender);
		if (kind == LINK_COPY && (filter->input_rendered || shader_filter_produce(up, OUT_PREMUL))) {
			if (!filter->input_rendered)
				copy_linked_input(filter, gs_texrender_get_texture(up->output_texrender));
			return gs_texrender_get_texture(filter->input_texrender);
		}
		obs_source_release(*ref);
		*ref = NULL;
	}
	get_input_source(filter);
	return gs_texrender_get_texture(filter->input_texrender);
}

/* Render a run with its derived effect, in one pass, into the last filter's
 * output_texrender. */
static void render_derived(struct shader_filter_data **stages, size_t n, struct derived_effect *de, enum out_form form)
{
	struct shader_filter_data *last = stages[n - 1];

	for (size_t i = 0; i < n; i++)
		stages[i]->rendering = true;

	obs_source_t *input_ref = NULL;
	gs_texture_t *input = acquire_input(stages[0], &input_ref);

	if (input) {
		prepare_output(last);
		for (size_t i = 0; i < n; i++) {
			float f = 0.0f;
			obs_source_t *filter_to = NULL;
			if (move_get_transition_filter)
				f = move_get_transition_filter(stages[i]->context, &filter_to);
			bind_shader_params(stages[i], i == 0 ? input : NULL, f, filter_to);
		}
		for (size_t i = 0; i < de->copies.num; i++) {
			struct fused_param_copy *c = &de->copies.array[i];
			size_t size = gs_effect_get_val_size(c->src);
			if (!size)
				continue;
			void *val = gs_effect_get_val(c->src);
			if (val) {
				gs_effect_set_val(c->dst, val, size);
				bfree(val);
			}
		}
		draw_shader(last, de->effect, input, form);
		last->frame_group = (uint32_t)n;
		for (size_t i = 0; i + 1 < n; i++)
			stages[i]->frame_merged = true;
	}
	obs_source_release(input_ref);

	for (size_t i = 0; i + 1 < n; i++)
		stages[i]->rendering = false;
}

struct downstream_search {
	obs_source_t *self;
	obs_source_t *found[32];
	size_t num;
};

static void collect_shader_filters(obs_source_t *parent, obs_source_t *child, void *param)
{
	UNUSED_PARAMETER(parent);
	struct downstream_search *ds = param;
	if (child != ds->self && ds->num < 32 && strcmp(obs_source_get_id(child), shader_filter_id) == 0) {
		obs_source_t *ref = obs_source_get_ref(child);
		if (ref)
			ds->found[ds->num++] = ref;
	}
}

enum downstream_use {
	DOWN_NONE,   /* no shader filter takes our output directly */
	DOWN_LINKED, /* one samples or copies it (we render a derived form) */
	DOWN_FUSED,  /* one compiles us into its own pass */
};

/* Once a second (on the graphics thread): the average GPU time of the
 * filter's own pass, for its settings panel. */
static void gpu_publish(struct shader_filter_data *filter)
{
	const uint64_t now = os_gettime_ns();
	if (!filter->gpu_window_start) {
		filter->gpu_window_start = now;
		return;
	}
	if (now - filter->gpu_window_start < 1000000000ULL)
		return;
	filter->gpu_window_start = now;
	filter->gpu_ms = filter->gpu_samples ? (float)(filter->gpu_sum_ms / filter->gpu_samples) : -1.0f;
	filter->gpu_sum_ms = 0.0;
	filter->gpu_samples = 0;

	/* A panel built before there was a figure is rebuilt once to show it
	 * (as a refresh, so the browsing tools stay as they are). */
	if (filter->gpu_props_waiting && (filter->gpu_ms >= 0.0f || filter->gpu_merged)) {
		filter->gpu_props_waiting = false;
		filter->props_refresh_until = now + 1000000000ULL;
		obs_source_update_properties(filter->context);
	}
}

static enum downstream_use downstream_use(struct shader_filter_data *filter)
{
	obs_source_t *parent = obs_filter_get_parent(filter->context);
	if (!parent)
		return DOWN_NONE;
	struct downstream_search ds = {.self = filter->context};
	obs_source_enum_filters(parent, collect_shader_filters, &ds);
	enum downstream_use use = DOWN_NONE;
	for (size_t i = 0; i < ds.num && use == DOWN_NONE; i++) {
		struct shader_filter_data *down = obs_obj_get_data(ds.found[i]);
		if (!down || !obs_source_enabled(ds.found[i]))
			continue;
		enum link_kind kind;
		obs_source_t *ref;
		if (linked_upstream(down, &kind, &ref, false) == filter) {
			use = DOWN_LINKED;
			if (kind == LINK_DIRECT && down->pointwise && filter->can_feed && !fusion_disabled()) {
				/* Unless the downstream run's effect is known to have
				 * failed, it will take us in. */
				struct shader_filter_data *stages[SF_MAX_FUSED];
				obs_source_t *refs[SF_MAX_FUSED];
				size_t n = collect_fusion_group(down, stages, refs, false);
				struct derived_effect *de = find_derived(down, stages, n);
				use = (de && de->failed) ? DOWN_LINKED : DOWN_FUSED;
				release_refs(refs, n);
			}
		}
		obs_source_release(ref);
	}
	release_refs(ds.found, ds.num);
	return use;
}

/* Prepare the derived effects this filter will need, during video_tick.
 *
 * Compiling an effect stalls the graphics thread, and with it every output
 * (all sources tick on it before the frame is rendered, visible or not), so it
 * is only done when a stall happens anyway: in the few ticks after one of the
 * filters involved had its own effect (re)built - loading a scene collection,
 * adding a filter, editing a shader, "Reload effect". Never on a render, and
 * never because filters were toggled, reordered or removed: until the effect
 * for the new arrangement exists, the filters render linked or the normal way,
 * which is correct, just slower.
 *
 * Besides the effect for its own run, a filter that a downstream filter takes
 * input from keeps a single-filter derived effect, so that toggling a filter
 * live falls back to linked rendering rather than to the normal path. */
static void prepare_derived(struct shader_filter_data *filter)
{
	if (filter->fresh_ticks > 0)
		filter->fresh_ticks--;
	if (!filter->shader_body || !filter->effect)
		return;

	enum downstream_use use = downstream_use(filter);
	struct shader_filter_data *stages[SF_MAX_FUSED];
	obs_source_t *refs[SF_MAX_FUSED];
	size_t n = collect_fusion_group(filter, stages, refs, false);

	bool allowed = false;
	for (size_t i = 0; i < n && !allowed; i++)
		allowed = stages[i]->fresh_ticks > 0;

	if (allowed) {
		bool entered = false;
		if (use != DOWN_FUSED && (n >= 2 || use == DOWN_LINKED) && !find_derived(filter, stages, n)) {
			obs_enter_graphics();
			entered = true;
			build_derived(filter, stages, n);
		}
		if (use != DOWN_NONE && !find_derived(filter, &filter, 1)) {
			if (!entered)
				obs_enter_graphics();
			entered = true;
			build_derived(filter, &filter, 1);
		}
		if (entered)
			obs_leave_graphics();
	}
	release_refs(refs, n);
}

/* Render this filter's shader output into output_texrender for the current
 * frame in the given form (or reuse it). Returns false when the filter can't
 * (or, for a derived form, can't yet). */
static bool shader_filter_produce(struct shader_filter_data *filter, enum out_form form)
{
	float f = 0.0f;
	obs_source_t *filter_to = NULL;
	if (move_get_transition_filter)
		f = move_get_transition_filter(filter->context, &filter_to);

	if (f == 0.0f && filter->output_rendered && filter->output_form == (int)form)
		return true;

	if (filter->effect == NULL || filter->rendering)
		return false;

	struct shader_filter_data *stages[SF_MAX_FUSED];
	obs_source_t *refs[SF_MAX_FUSED];
	size_t n = 1;
	stages[0] = filter;
	refs[0] = NULL;
	if (filter->shader_body)
		n = collect_fusion_group(filter, stages, refs, true);

	/* The prepared effect for the whole run, else (for a derived form) the
	 * one for this filter alone; never compiled here. */
	struct derived_effect *de = NULL;
	size_t used = n;
	if (n >= 2) {
		de = find_derived(filter, stages, n);
		if (de && de->failed)
			de = NULL;
	}
	if (!de && form != OUT_RAW && filter->shader_body) {
		de = find_derived(filter, &filter, 1);
		if (de && de->failed)
			de = NULL;
		used = 1;
	}
	if (!de && form != OUT_RAW) {
		release_refs(refs, n);
		return false;
	}

	filter->rendering = true;
	if (de) {
		render_derived(stages + (n - used), used, de, form);
	} else {
		obs_source_t *input_ref = NULL;
		gs_texture_t *input = acquire_input(filter, &input_ref);
		render_shader(filter, input, f, filter_to, OUT_RAW);
		obs_source_release(input_ref);
	}
	release_refs(refs, n);
	if (f == 0.0f) {
		filter->output_rendered = true;
		filter->output_form = (int)form;
	}
	filter->rendering = false;
	return true;
}

/* Draw output_texrender into the current target exactly as
 * obs_source_process_filter_end() would with render_output.effect, but without
 * obs_source_process_filter_begin(): a linked filter, or one whose input was
 * drawn directly by its source, never had libobs render its upstream into
 * libobs' own texture, and asking for it would cost a full extra pass. */
static void draw_output(struct shader_filter_data *filter)
{
	gs_texture_t *texture = gs_texrender_get_texture(filter->output_texrender);
	if (!texture || !filter->total_width || !filter->total_height)
		return;

	gs_effect_t *effect = filter->output_effect;
	gs_eparam_t *param = filter->param_output_image;
	bool srgb_param = false;
	if (!effect || !param) {
		effect = obs_get_base_effect(OBS_EFFECT_DEFAULT);
		param = gs_effect_get_param_by_name(effect, "image");
		srgb_param = true;
	}

	const bool previous_linear = gs_set_linear_srgb(true);
	const bool previous_fb = gs_framebuffer_srgb_enabled();
	gs_enable_framebuffer_srgb(true);

	if (srgb_param)
		gs_effect_set_texture_srgb(param, texture);
	else
		gs_effect_set_texture(param, texture);

	while (gs_effect_loop(effect, "Draw"))
		gs_draw_sprite(texture, 0, filter->total_width, filter->total_height);

	gs_enable_framebuffer_srgb(previous_fb);
	gs_set_linear_srgb(previous_linear);
}

static void shader_filter_render(void *data, gs_effect_t *effect)
{
	UNUSED_PARAMETER(effect);

	struct shader_filter_data *filter = data;

	float f = 0.0f;
	obs_source_t *filter_to = NULL;
	if (move_get_transition_filter)
		f = move_get_transition_filter(filter->context, &filter_to);

	if (!(f == 0.0f && filter->output_rendered && filter->output_form == OUT_RAW)) {
		if (filter->effect == NULL || filter->rendering) {
			obs_source_skip_video_filter(filter->context);
			return;
		}
		if (!shader_filter_produce(filter, OUT_RAW)) {
			obs_source_skip_video_filter(filter->context);
			return;
		}
	}

	draw_output(filter);
}

static uint32_t shader_filter_getwidth(void *data)
{
	struct shader_filter_data *filter = data;

	return filter->total_width;
}

static uint32_t shader_filter_getheight(void *data)
{
	struct shader_filter_data *filter = data;

	return filter->total_height;
}

static void shader_filter_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "shader_text", effect_template_default_image_shader);
}

void shader_filter_param_source_action(void *data, void (*action)(obs_source_t *source))
{
	struct shader_filter_data *filter = data;
	size_t param_count = filter->stored_param_list.num;
	for (size_t param_index = 0; param_index < param_count; param_index++) {
		struct effect_param_data *param = (filter->stored_param_list.array + param_index);
		if (!param->source)
			continue;
		obs_source_t *source = obs_weak_source_get_source(param->source);
		if (!source)
			continue;
		action(source);
		obs_source_release(source);
	}
}

void shader_filter_activate(void *data)
{
	shader_filter_param_source_action(data, obs_source_inc_active);
}

void shader_filter_deactivate(void *data)
{
	shader_filter_param_source_action(data, obs_source_dec_active);
}

void shader_filter_show(void *data)
{
	shader_filter_param_source_action(data, obs_source_inc_showing);
}

void shader_filter_hide(void *data)
{
	shader_filter_param_source_action(data, obs_source_dec_showing);
}

static void missing_file_callback(void *src, const char *new_path, void *data)
{
	struct shader_filter_data *filter = src;
	const char *setting_name = data;
	obs_data_t *settings = obs_source_get_settings(filter->context);
	obs_data_set_string(settings, setting_name, new_path);
	obs_source_update(filter->context, settings);
	obs_data_release(settings);
}

obs_missing_files_t *shader_filter_missing_files(void *data)
{
	struct shader_filter_data *filter = data;
	obs_missing_files_t *files = obs_missing_files_create();
	obs_data_t *settings = obs_source_get_settings(filter->context);
	if (obs_data_get_bool(settings, "from_file")) {
		const char *file_name = obs_data_get_string(settings, "shader_file_name");
		if (file_name && strlen(file_name) > 0 && !os_file_exists(file_name)) {
			obs_missing_file_t *file = obs_missing_file_create(
				file_name, missing_file_callback, OBS_MISSING_FILE_SOURCE, filter->context, "shader_file_name");
			obs_missing_files_add_file(files, file);
		}
	}
	size_t param_count = filter->stored_param_list.num;
	for (size_t param_index = 0; param_index < param_count; param_index++) {
		struct effect_param_data *param = (filter->stored_param_list.array + param_index);
		if (param->type != GS_SHADER_PARAM_TEXTURE)
			continue;
		const char *widget_type = param->widget_type.array;
		if (widget_type && strcmp(widget_type, "source") == 0)
			continue;
		const char *param_name = param->name.array;
		const char *path = obs_data_get_string(settings, param_name);
		if (path && strlen(path) > 0 && !os_file_exists(path)) {
			obs_missing_file_t *file = obs_missing_file_create(path, missing_file_callback, OBS_MISSING_FILE_SOURCE,
									   filter->context, param->name.array);

			obs_missing_files_add_file(files, file);
		}
	}
	obs_data_release(settings);
	return files;
}

struct obs_source_info shader_filter = {
	.id = "shader_filter",
	.type = OBS_SOURCE_TYPE_FILTER,
	.output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_SRGB | OBS_SOURCE_CUSTOM_DRAW,
	.create = shader_filter_create,
	.destroy = shader_filter_destroy,
	.update = shader_filter_update,
	.load = shader_filter_update,
	.video_tick = shader_filter_tick,
	.get_name = shader_filter_get_name,
	.get_defaults = shader_filter_defaults,
	.get_width = shader_filter_getwidth,
	.get_height = shader_filter_getheight,
	.video_render = shader_filter_render,
	.get_properties = shader_filter_properties,
	.video_get_color_space = shader_filter_get_color_space,
	.activate = shader_filter_activate,
	.deactivate = shader_filter_deactivate,
	.show = shader_filter_show,
	.hide = shader_filter_hide,
	.missing_files = shader_filter_missing_files,
};

static void *shader_transition_create(obs_data_t *settings, obs_source_t *source)
{
	struct shader_filter_data *filter = bzalloc(sizeof(struct shader_filter_data));
	filter->context = source;
	filter->reload_effect = true;
	filter->gpu_ms = -1.0f;
	filter->gpu_group = 1;
	filter->transition = true;

	dstr_init(&filter->last_path);
	dstr_copy(&filter->last_path, obs_data_get_string(settings, "shader_file_name"));
	filter->last_from_file = obs_data_get_bool(settings, "from_file");
	filter->rand_instance_f = (float)((double)rand_interval(0, 10000) / (double)10000);
	filter->rand_activation_f = (float)((double)rand_interval(0, 10000) / (double)10000);

	da_init(filter->stored_param_list);

	obs_source_update(source, settings);

	return filter;
}

static const char *shader_transition_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("ShaderFilter");
}

static float mix_a(void *data, float t)
{
	UNUSED_PARAMETER(data);
	return 1.0f - t;
}

static float mix_b(void *data, float t)
{
	UNUSED_PARAMETER(data);
	return t;
}

static bool shader_transition_audio_render(void *data, uint64_t *ts_out, struct obs_source_audio_mix *audio, uint32_t mixers,
					   size_t channels, size_t sample_rate)
{
	struct shader_filter_data *filter = data;
	return obs_transition_audio_render(filter->context, ts_out, audio, mixers, channels, sample_rate, mix_a, mix_b);
}

static void shader_transition_video_callback(void *data, gs_texture_t *a, gs_texture_t *b, float t, uint32_t cx, uint32_t cy)
{
	if (!a && !b)
		return;

	struct shader_filter_data *filter = data;
	if (filter->effect == NULL || filter->rendering)
		return;

	if (!filter->prev_transitioning) {
		if (obs_source_active(filter->context))
			shader_filter_param_source_action(data, obs_source_inc_active);
		if (obs_source_showing(filter->context))
			shader_filter_param_source_action(data, obs_source_inc_showing);
	}
	filter->transitioning = true;

	const bool previous = gs_framebuffer_srgb_enabled();
	gs_enable_framebuffer_srgb(true);

	if (gs_get_color_space() == GS_CS_SRGB) {
		if (filter->param_image_a != NULL)
			gs_effect_set_texture(filter->param_image_a, a);
		if (filter->param_image_b != NULL)
			gs_effect_set_texture(filter->param_image_b, b);
		if (filter->param_image != NULL)
			gs_effect_set_texture(filter->param_image, t < 0.5 ? a : b);
		if (filter->param_convert_linear)
			gs_effect_set_bool(filter->param_convert_linear, true);
	} else {
		if (filter->param_image_a != NULL)
			gs_effect_set_texture_srgb(filter->param_image_a, a);
		if (filter->param_image_b != NULL)
			gs_effect_set_texture_srgb(filter->param_image_b, b);
		if (filter->param_image != NULL)
			gs_effect_set_texture_srgb(filter->param_image, t < 0.5 ? a : b);
		if (filter->param_convert_linear)
			gs_effect_set_bool(filter->param_convert_linear, false);
	}
	if (filter->param_transition_time != NULL)
		gs_effect_set_float(filter->param_transition_time, t);

	shader_filter_set_effect_params(filter);

	while (gs_effect_loop(filter->effect, "Draw"))
		gs_draw_sprite(NULL, 0, cx, cy);

	gs_enable_framebuffer_srgb(previous);
}

static void shader_transition_video_render(void *data, gs_effect_t *effect)
{
	UNUSED_PARAMETER(effect);

	const bool previous = gs_set_linear_srgb(true);

	struct shader_filter_data *filter = data;
	filter->transitioning = false;
	obs_transition_video_render2(filter->context, shader_transition_video_callback, NULL);
	if (!filter->transitioning && filter->prev_transitioning) {
		if (obs_source_active(filter->context))
			shader_filter_param_source_action(data, obs_source_dec_active);
		if (obs_source_showing(filter->context))
			shader_filter_param_source_action(data, obs_source_dec_showing);
	}
	filter->prev_transitioning = filter->transitioning;
	gs_set_linear_srgb(previous);
}

static void shader_transition_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "shader_text", effect_template_default_transition_image_shader);
}

static enum gs_color_space shader_transition_get_color_space(void *data, size_t count, const enum gs_color_space *preferred_spaces)
{
	struct shader_filter_data *filter = data;
	const enum gs_color_space transition_space = obs_transition_video_get_color_space(filter->context);

	enum gs_color_space space = transition_space;
	for (size_t i = 0; i < count; ++i) {
		space = preferred_spaces[i];
		if (space == transition_space)
			break;
	}

	return space;
}

struct obs_source_info shader_transition = {
	.id = "shader_transition",
	.type = OBS_SOURCE_TYPE_TRANSITION,
	.create = shader_transition_create,
	.destroy = shader_filter_destroy,
	.update = shader_filter_update,
	.load = shader_filter_update,
	.video_tick = shader_filter_tick,
	.get_name = shader_transition_get_name,
	.audio_render = shader_transition_audio_render,
	.get_defaults = shader_transition_defaults,
	.video_render = shader_transition_video_render,
	.get_properties = shader_filter_properties,
	.video_get_color_space = shader_transition_get_color_space,
	.missing_files = shader_filter_missing_files,
};

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-shaderfilter", "en-US")

bool obs_module_load(void)
{
	blog(LOG_INFO, "[obs-shaderfilter] loaded version %s", PROJECT_VERSION);
	obs_register_source(&shader_filter);
	obs_register_source(&shader_transition);

#ifdef _WIN32
	void *dl = os_dlopen("obs");
#else
	void *dl = dlopen(nullptr, RTLD_LAZY);
#endif
	if (dl) {
		if (obs_get_version() >= MAKE_SEMANTIC_VERSION(33, 0, 0)) {
			gs_image_file_create_func = gs_image_file_ex_create;
			gs_image_file_free_func = os_dlsym(dl, "gs_image_file_ex_free");
			gs_image_file_init_func = os_dlsym(dl, "gs_image_file_ex_init");
			gs_image_file_init_texture_func = os_dlsym(dl, "gs_image_file_ex_init_texture");
			gs_image_file_tick_func = os_dlsym(dl, "gs_image_file_ex_tick");
			gs_image_file_update_texture_func = os_dlsym(dl, "gs_image_file_ex_update_texture");
		} else {
			gs_image_file_create_func = gs_image_file4_create;
			gs_image_file_free_func = os_dlsym(dl, "gs_image_file4_free");
			gs_image_file_init_func = os_dlsym(dl, "gs_image_file4_init");
			gs_image_file_init_texture_func = os_dlsym(dl, "gs_image_file4_init_texture");
			gs_image_file_tick_func = os_dlsym(dl, "gs_image_file4_tick");
			gs_image_file_update_texture_func = os_dlsym(dl, "gs_image_file4_update_texture");
		}
		os_dlclose(dl);
	}
	return true;
}

void obs_module_unload(void)
{
	transition_memos_free();
}

void obs_module_post_load()
{
	if (obs_get_module("move-transition") == NULL)
		return;
	proc_handler_t *ph = obs_get_proc_handler();
	struct calldata cd;
	calldata_init(&cd);
	calldata_set_string(&cd, "filter_id", shader_filter.id);
	if (proc_handler_call(ph, "move_get_transition_filter_function", &cd)) {
		move_get_transition_filter = calldata_ptr(&cd, "callback");
	}
	calldata_free(&cd);
}
