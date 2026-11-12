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
