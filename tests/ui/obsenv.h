#pragma once
#include <obs.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool env_start(const char *obs_prefix, const char *plugin, const char *data, uint32_t w, uint32_t h);
void env_tick(float dt);
/* Render a source at its own size into a bmalloc'd RGBA buffer (premultiplied). */
bool env_render(obs_source_t *source, uint8_t **rgba, uint32_t *w, uint32_t *h);

#ifdef __cplusplus
}
#endif
