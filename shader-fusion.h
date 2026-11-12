#pragma once

/*
 * Fusing consecutive shader filters into one effect.
 *
 * A template shader (.shader) that reads its input only at its own pixel,
 * i.e. every use of `image` is `image.Sample(textureSampler, v_in.uv)` inside
 * mainImage (or through a never-reassigned `float2 uv = v_in.uv;`), can call
 * the upstream filter's mainImage directly instead of sampling a texture of
 * its output. Sampling at an exact texel centre returns the stored texel, so
 * as long as the upstream value goes through the same 8-bit filter boundary
 * the output is identical, and a full-screen pass is saved.
 *
 * sf_fusion_build() takes the shader bodies of a run of filters, upstream
 * first, and returns one effect: every stage but the last is copied with all
 * of its identifiers (its uniforms, functions, the template's uniforms and
 * types) prefixed with "_sfN_", and each use of `image` at the pixel in the
 * stage after it is replaced by a call into the previous stage. The last stage
 * keeps its names, so its techniques and the plugin's uniform names work
 * unchanged. Uniforms of stage N are therefore found in the fused effect as
 * sf_fusion_param_name(N, name).
 */

#include <stdbool.h>
#include <stddef.h>

/* True if the template shader body samples `image` only at the current pixel. */
bool sf_fusion_is_pointwise(const char *body);

/* Build the fused effect text, or NULL if the bodies can't be fused. bodies[0]
 * is the most upstream stage; every stage after the first must be pointwise.
 * With one body this is just that shader with template_end (used for the
 * linking techniques, kept out of the filter's own effect).
 * template_begin/template_end are the plugin's effect template. bfree() it. */
char *sf_fusion_build(const char *const *bodies, size_t count, const char *template_begin, const char *template_end);

/* Name of stage `stage`'s uniform `name` in a fused effect of `count` stages
 * (the last stage keeps its own names). bfree() it. */
char *sf_fusion_param_name(size_t stage, size_t count, const char *name);
