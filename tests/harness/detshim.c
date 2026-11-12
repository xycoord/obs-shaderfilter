/*
 * Deterministic-environment shim, loaded with LD_PRELOAD into the harness.
 *
 * The shader filter feeds shaders random numbers (rand()) and wall-clock time
 * (time(), localtime(), gettimeofday(), os_gettime_ns()). For pixel-exact
 * comparisons between two builds of the plugin those must be identical, so the
 * plugin's calls are pinned here:
 *
 *   rand()          always returns the same value, so every rand_f /
 *                   rand_instance_f / rand_activation_f is the same constant
 *                   regardless of how many times or in what order it is called.
 *   time()          fixed epoch (localtime() of it is therefore fixed too).
 *   gettimeofday()  fixed.
 *   os_gettime_ns() real time, unless the harness has frozen it with
 *                   detshim_freeze_ns(); libobs' own internal calls are bound
 *                   inside libobs and are not affected.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

#define FIXED_EPOCH 1700000000 /* 2023-11-14 22:13:20 UTC */
#define FIXED_RAND 794617000   /* rand_interval(0, 10000) -> 3700 -> 0.37 */

static volatile uint64_t frozen_ns = 0;

void detshim_freeze_ns(uint64_t ns)
{
	frozen_ns = ns;
}

int rand(void)
{
	return FIXED_RAND;
}

time_t time(time_t *t)
{
	if (t)
		*t = FIXED_EPOCH;
	return FIXED_EPOCH;
}

int gettimeofday(struct timeval *tv, void *tz)
{
	(void)tz;
	if (tv) {
		tv->tv_sec = FIXED_EPOCH;
		tv->tv_usec = 250000;
	}
	return 0;
}

uint64_t os_gettime_ns(void)
{
	if (frozen_ns)
		return frozen_ns;
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/*
 * Optional GL draw counter (SHADERTEST_COUNT_GL=1): a hardware-independent
 * measure of how many draws, and how many pixels of render target they cover,
 * a frame costs. glad resolves GL entry points through glXGetProcAddressARB,
 * which it looks up with dlsym(); interposing dlsym lets us hand it wrappers.
 */
#include <string.h>

typedef void *(*gpa_fn)(const char *);
typedef void (*draw_arrays_fn)(unsigned, int, int);
typedef void (*draw_elements_fn)(unsigned, int, unsigned, const void *);
typedef void (*viewport_fn)(int, int, int, int);

static void *(*real_dlsym)(void *, const char *);
static gpa_fn real_gpa;
static draw_arrays_fn real_draw_arrays;
static draw_elements_fn real_draw_elements;
static viewport_fn real_viewport;
static uint64_t gl_draws, gl_pixels, vp_area;

void detshim_gl_counts(uint64_t *draws, uint64_t *pixels)
{
	*draws = gl_draws;
	*pixels = gl_pixels;
}

static void wrap_draw_arrays(unsigned mode, int first, int count)
{
	gl_draws++;
	gl_pixels += vp_area;
	real_draw_arrays(mode, first, count);
}

static void wrap_draw_elements(unsigned mode, int count, unsigned type, const void *idx)
{
	gl_draws++;
	gl_pixels += vp_area;
	real_draw_elements(mode, count, type, idx);
}

static void wrap_viewport(int x, int y, int w, int h)
{
	vp_area = (uint64_t)w * (uint64_t)h;
	real_viewport(x, y, w, h);
}

static void *wrap_gpa(const char *name)
{
	void *p = real_gpa(name);
	if (!p)
		return p;
	if (!strcmp(name, "glDrawArrays")) {
		real_draw_arrays = (draw_arrays_fn)p;
		return (void *)wrap_draw_arrays;
	}
	if (!strcmp(name, "glDrawElements")) {
		real_draw_elements = (draw_elements_fn)p;
		return (void *)wrap_draw_elements;
	}
	if (!strcmp(name, "glViewport")) {
		real_viewport = (viewport_fn)p;
		return (void *)wrap_viewport;
	}
	return p;
}

void *dlsym(void *handle, const char *name)
{
	if (!real_dlsym) {
		real_dlsym = (void *(*)(void *, const char *))dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.34");
		if (!real_dlsym)
			real_dlsym = (void *(*)(void *, const char *))dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
	}
	void *r = real_dlsym(handle, name);
	static int enabled = -1;
	if (enabled < 0) {
		const char *e = getenv("SHADERTEST_COUNT_GL");
		enabled = e && *e == '1';
	}
	if (enabled && r && name && !strcmp(name, "glXGetProcAddressARB")) {
		real_gpa = (gpa_fn)r;
		return (void *)wrap_gpa;
	}
	return r;
}
