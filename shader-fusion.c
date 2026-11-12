#include "shader-fusion.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <util/bmem.h>
#include <util/darray.h>
#include <util/dstr.h>

/* ------------------------------------------------------------------------
 * Tokenizer for the HLSL-like OBS effect language. Only what fusion needs:
 * identifiers, numbers, strings and single-character punctuation, with the
 * text between tokens (whitespace, comments) kept so the source can be
 * re-emitted unchanged apart from the tokens we rewrite.
 * ------------------------------------------------------------------------ */

enum tok_type { TOK_IDENT, TOK_NUMBER, TOK_STRING, TOK_PUNCT };

struct tok {
	enum tok_type type;
	size_t start; /* offset of the token in the source */
	size_t len;
	size_t trivia; /* offset where the whitespace/comments before it begin */
};

struct toks {
	const char *src;
	DARRAY(struct tok) a;
	size_t tail; /* trivia after the last token */
};

static void tokenize(const char *src, struct toks *t)
{
	t->src = src;
	da_init(t->a);
	size_t i = 0, n = strlen(src);
	for (;;) {
		size_t trivia = i;
		for (;;) {
			if (i < n && isspace((unsigned char)src[i])) {
				i++;
			} else if (i + 1 < n && src[i] == '/' && src[i + 1] == '/') {
				while (i < n && src[i] != '\n')
					i++;
			} else if (i + 1 < n && src[i] == '/' && src[i + 1] == '*') {
				i += 2;
				while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/'))
					i++;
				i = (i + 1 < n) ? i + 2 : n;
			} else {
				break;
			}
		}
		if (i >= n) {
			t->tail = trivia;
			return;
		}
		struct tok tk = {.start = i, .trivia = trivia};
		char c = src[i];
		if (isalpha((unsigned char)c) || c == '_') {
			tk.type = TOK_IDENT;
			while (i < n && (isalnum((unsigned char)src[i]) || src[i] == '_'))
				i++;
		} else if (isdigit((unsigned char)c) || (c == '.' && i + 1 < n && isdigit((unsigned char)src[i + 1]))) {
			tk.type = TOK_NUMBER;
			while (i < n) {
				char d = src[i];
				if (isalnum((unsigned char)d) || d == '.' || d == '_') {
					i++;
				} else if ((d == '+' || d == '-') && (src[i - 1] == 'e' || src[i - 1] == 'E') &&
					   !(src[tk.start] == '0' && (src[tk.start + 1] == 'x' || src[tk.start + 1] == 'X'))) {
					i++;
				} else {
					break;
				}
			}
		} else if (c == '"') {
			tk.type = TOK_STRING;
			i++;
			while (i < n && src[i] != '"') {
				if (src[i] == '\\' && i + 1 < n)
					i++;
				i++;
			}
			if (i < n)
				i++;
		} else {
			tk.type = TOK_PUNCT;
			i++;
		}
		tk.len = i - tk.start;
		da_push_back(t->a, &tk);
	}
}

static inline bool tok_is(const struct toks *t, size_t idx, const char *s)
{
	if (idx >= t->a.num)
		return false;
	const struct tok *tk = &t->a.array[idx];
	size_t l = strlen(s);
	return tk->len == l && strncmp(t->src + tk->start, s, l) == 0;
}

static inline bool tok_ident(const struct toks *t, size_t idx)
{
	return idx < t->a.num && t->a.array[idx].type == TOK_IDENT;
}

static inline bool tok_same(const struct toks *t, size_t a, size_t b)
{
	const struct tok *x = &t->a.array[a], *y = &t->a.array[b];
	return x->len == y->len && strncmp(t->src + x->start, t->src + y->start, x->len) == 0;
}

/* Is the identifier at idx followed by an assignment (=, op=, ++, --),
 * possibly through member accesses or subscripts (v_in.uv.x = ..., uv[0] += ...)? */
static bool assigned_at(const struct toks *t, size_t idx)
{
	size_t j = idx + 1;
	for (;;) {
		if (tok_is(t, j, ".") && tok_ident(t, j + 1)) {
			j += 2;
		} else if (tok_is(t, j, "[")) {
			int depth = 0;
			for (; j < t->a.num; j++) {
				if (tok_is(t, j, "["))
					depth++;
				else if (tok_is(t, j, "]") && --depth == 0)
					break;
			}
			j++;
		} else {
			break;
		}
	}
	if (tok_is(t, j, "=") && !tok_is(t, j + 1, "="))
		return true;
	if ((tok_is(t, j, "+") && tok_is(t, j + 1, "+")) || (tok_is(t, j, "-") && tok_is(t, j + 1, "-")))
		return true;
	static const char *ops[] = {"+", "-", "*", "/", "%", "&", "|", "^"};
	for (size_t k = 0; k < sizeof(ops) / sizeof(ops[0]); k++)
		if (tok_is(t, j, ops[k]) && tok_is(t, j + 1, "=") && !tok_is(t, j + 2, "="))
			return true;
	/* ++x / --x */
	if (idx >= 2 && ((tok_is(t, idx - 1, "+") && tok_is(t, idx - 2, "+")) ||
			 (tok_is(t, idx - 1, "-") && tok_is(t, idx - 2, "-"))))
		return true;
	return false;
}

/* ------------------------------------------------------------------------
 * Pointwise analysis
 * ------------------------------------------------------------------------ */

struct span {
	size_t first, last; /* token indices, inclusive */
};

struct pointwise_info {
	bool ok;
	size_t param; /* token index of mainImage's VertData parameter name */
	DARRAY(struct span) samples;
};

static size_t match_brace(const struct toks *t, size_t open)
{
	int depth = 0;
	for (size_t i = open; i < t->a.num; i++) {
		if (tok_is(t, i, "{"))
			depth++;
		else if (tok_is(t, i, "}") && --depth == 0)
			return i;
	}
	return (size_t)-1;
}

static void analyse(const struct toks *t, struct pointwise_info *info)
{
	memset(info, 0, sizeof(*info));
	da_init(info->samples);

	/* float4 mainImage(VertData v) [: TARGET] { ... } */
	size_t body_open = (size_t)-1, param = 0;
	for (size_t i = 0; i + 4 < t->a.num; i++) {
		if (tok_is(t, i, "mainImage") && tok_is(t, i + 1, "(") && tok_is(t, i + 2, "VertData") &&
		    tok_ident(t, i + 3) && tok_is(t, i + 4, ")")) {
			size_t j = i + 5;
			while (j < t->a.num && !tok_is(t, j, "{") && !tok_is(t, j, ";"))
				j++;
			if (!tok_is(t, j, "{"))
				continue;
			if (body_open != (size_t)-1)
				return; /* more than one definition */
			body_open = j;
			param = i + 3;
		}
	}
	if (body_open == (size_t)-1)
		return;
	size_t body_close = match_brace(t, body_open);
	if (body_close == (size_t)-1)
		return;
	info->param = param;

	/* Anything passed by reference could be modified behind our back (the
	 * VertData, or a uv alias handed to a helper). */
	for (size_t i = 0; i < t->a.num; i++)
		if (tok_is(t, i, "out") || tok_is(t, i, "inout"))
			return;

	/* Aliases: float2 A = v.uv; never assigned again. */
	DARRAY(size_t) aliases;
	da_init(aliases);
	for (size_t i = body_open; i + 6 < body_close; i++) {
		if (tok_is(t, i, "float2") && tok_ident(t, i + 1) && tok_is(t, i + 2, "=") && !tok_is(t, i + 3, "=") &&
		    tok_same(t, i + 3, param) && tok_is(t, i + 4, ".") && tok_is(t, i + 5, "uv") && tok_is(t, i + 6, ";")) {
			bool reassigned = false;
			for (size_t k = i + 7; k < body_close; k++)
				if (tok_ident(t, k) && tok_same(t, k, i + 1) && !tok_is(t, k - 1, ".") && assigned_at(t, k))
					reassigned = true;
			if (!reassigned)
				da_push_back(aliases, &(size_t){i + 1});
		}
	}

	bool ok = true;
	for (size_t i = 0; i < t->a.num && ok; i++) {
		if (!tok_ident(t, i) || (i > 0 && tok_is(t, i - 1, ".")))
			continue;
		if (i > body_open && i < body_close && tok_same(t, i, param) && assigned_at(t, i))
			ok = false;
		if (!tok_is(t, i, "image") || tok_is(t, i - 1, "texture2d"))
			continue;
		/* image . Sample ( textureSampler , <uv> ) */
		if (i <= body_open || i >= body_close || !tok_is(t, i + 1, ".") || !tok_is(t, i + 2, "Sample") ||
		    !tok_is(t, i + 3, "(") || !tok_is(t, i + 4, "textureSampler") || !tok_is(t, i + 5, ",")) {
			ok = false;
			break;
		}
		size_t end = (size_t)-1;
		if (tok_same(t, i + 6, param) && tok_is(t, i + 7, ".") && tok_is(t, i + 8, "uv") && tok_is(t, i + 9, ")")) {
			end = i + 9;
		} else if (tok_ident(t, i + 6) && tok_is(t, i + 7, ")")) {
			for (size_t k = 0; k < aliases.num; k++) {
				size_t a = aliases.array[k];
				if (a < i && tok_same(t, i + 6, a))
					end = i + 7;
			}
		}
		if (end == (size_t)-1) {
			ok = false;
			break;
		}
		struct span sp = {i, end};
		da_push_back(info->samples, &sp);
		i = end;
	}
	da_free(aliases);
	info->ok = ok && info->samples.num > 0;
}

bool sf_fusion_is_pointwise(const char *body)
{
	if (!body)
		return false;
	struct toks t;
	tokenize(body, &t);
	struct pointwise_info info;
	analyse(&t, &info);
	bool ok = info.ok;
	da_free(info.samples);
	da_free(t.a);
	return ok;
}

/* ------------------------------------------------------------------------
 * Renaming
 * ------------------------------------------------------------------------ */

/* Identifiers that belong to the language, the effect system or OBS and must
 * keep their names when a stage is prefixed. Sorted for bsearch. An intrinsic
 * missing from this list only makes the fused effect fail to compile, and the
 * plugin then renders the filters separately. */
static const char *reserved[] = {
	"Anisotropy", "BorderColor", "Clamp", "Filter", "Linear", "MaxAnisotropy", "MaxLOD", "MinLOD", "MipLODBias",
	"Mirror", "MirrorOnce", "OPENGL", "Point", "Wrap",
	"AddressU", "AddressV", "AddressW", "Border",
	"COLOR", "COLOR0", "COLOR1", "NORMAL", "POSITION", "POSITION0", "SV_Position", "SV_Target", "TARGET",
	"TEXCOORD0", "TEXCOORD1", "TEXCOORD2", "TEXCOORD3", "TEXCOORD4", "TEXCOORD5", "TEXCOORD6", "TEXCOORD7",
	"USE_PM_ALPHA", "VERTEXID",
	"abs", "acos", "all", "allow_uav_condition", "any", "asfloat", "asin", "asint", "asuint", "atan", "atan2",
	"bool", "bool2", "bool3", "bool4", "branch", "break", "case", "ceil", "clamp", "clip", "const", "continue",
	"cos", "cosh", "countbits", "cross", "ddx", "ddy", "default", "defined", "degrees", "determinant", "discard",
	"distance", "do", "dot", "double", "else", "endif", "exp", "exp2", "false", "fastopt", "firstbithigh",
	"firstbitlow", "flatten", "float", "float1", "float2", "float2x2", "float3", "float3x3", "float3x4",
	"float4", "float4x3", "float4x4", "floor", "fmod", "for", "frac", "frexp", "fwidth", "half", "half2",
	"half3", "half4", "if", "ifdef", "ifndef", "in", "include", "inout", "int", "int2", "int3", "int4",
	"isfinite", "isinf", "isnan", "ldexp", "length", "lerp", "lit", "log", "log10", "log2", "loop", "mad",
	"matrix", "max", "min", "modf", "mul", "normalize", "out", "pass", "pixel_shader", "pow",
	"radians", "rcp", "reflect", "refract", "return", "reversebits", "round", "rsqrt", "sampler",
	"sampler_state", "saturate", "sign", "sin", "sincos", "sinh", "smoothstep", "sqrt", "static", "step",
	"string", "struct", "switch", "tan", "tanh", "technique", "texture2d", "texture3d", "texture_cube",
	"texture_rect", "transpose", "true", "trunc", "uint", "uint2", "uint3", "uint4", "undef", "uniform",
	"unroll", "vector", "vertex_shader", "void", "while",
	"define", "elif", "error", "pragma", "line",
	/* GLSL names used in #ifdef OPENGL branches */
	"atanh", "bvec2", "bvec3", "bvec4", "dFdx", "dFdy", "equal", "fract", "greaterThan", "greaterThanEqual",
	"inversesqrt", "ivec2", "ivec3", "ivec4", "lessThan", "lessThanEqual", "mat2", "mat3", "mat4", "mix", "mod",
	"not", "notEqual", "texelFetch", "texture", "texture2D", "textureLod", "textureSize", "uvec2", "uvec3",
	"uvec4", "vec2", "vec3", "vec4",
};

static int cmp_str(const void *a, const void *b)
{
	return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static bool reserved_sorted = false;

static bool is_reserved(const char *s, size_t len)
{
	if (!reserved_sorted) {
		qsort(reserved, sizeof(reserved) / sizeof(reserved[0]), sizeof(reserved[0]), cmp_str);
		reserved_sorted = true;
	}
	if (len >= 3 && strncmp(s, "_sf", 3) == 0)
		return true;
	char buf[64];
	if (len >= sizeof(buf))
		return false;
	memcpy(buf, s, len);
	buf[len] = 0;
	const char *key = buf;
	return bsearch(&key, reserved, sizeof(reserved) / sizeof(reserved[0]), sizeof(reserved[0]), cmp_str) != NULL;
}

/* Names that appear after a '.' (struct members, swizzles, methods) keep
 * their names everywhere, so `float2 uv : TEXCOORD0;` still matches `.uv`. */
static bool is_member_name(const struct toks *t, size_t idx)
{
	for (size_t i = 1; i < t->a.num; i++)
		if (t->a.array[i].type == TOK_IDENT && tok_is(t, i - 1, ".") && tok_same(t, i, idx))
			return true;
	return false;
}

static void emit_prefix(struct dstr *out, size_t stage)
{
	dstr_catf(out, "_sf%zu_", stage);
}

/* Append `src` to `out`, prefixing identifiers with the stage prefix (if
 * rename) and replacing the given sample spans with calls to the fetch
 * function for this stage. */
static void emit_stage(struct dstr *out, const struct toks *t, const struct pointwise_info *pw, bool rename,
		       size_t stage)
{
	size_t next_sample = 0;
	char *member_cache = bzalloc(t->a.num ? t->a.num : 1); /* 0 unknown, 1 member, 2 not */
	for (size_t i = 0; i < t->a.num; i++) {
		const struct tok *tk = &t->a.array[i];
		dstr_ncat(out, t->src + tk->trivia, tk->start - tk->trivia);

		if (pw && next_sample < pw->samples.num && pw->samples.array[next_sample].first == i) {
			const struct tok *p = &t->a.array[pw->param];
			dstr_catf(out, "_sf_fetch%zu(", stage);
			if (rename)
				emit_prefix(out, stage);
			dstr_ncat(out, t->src + p->start, p->len);
			dstr_cat(out, ".pos, ");
			if (rename)
				emit_prefix(out, stage);
			dstr_ncat(out, t->src + p->start, p->len);
			dstr_cat(out, ".uv)");
			i = pw->samples.array[next_sample].last;
			next_sample++;
			continue;
		}

		if (rename && tk->type == TOK_IDENT && !(i > 0 && tok_is(t, i - 1, ".")) &&
		    !is_reserved(t->src + tk->start, tk->len)) {
			if (!member_cache[i]) {
				bool m = is_member_name(t, i);
				for (size_t k = i; k < t->a.num; k++)
					if (t->a.array[k].type == TOK_IDENT && tok_same(t, k, i))
						member_cache[k] = m ? 1 : 2;
			}
			if (member_cache[i] == 2)
				emit_prefix(out, stage);
		}
		dstr_ncat(out, t->src + tk->start, tk->len);
	}
	dstr_cat(out, t->src + t->tail);
	bfree(member_cache);
}

static const char *fusion_prelude = "\n\
float _sfx_q8(float x)\n\
{\n\
	float v = saturate(x) * 255.0 + 0.5;\n\
	return (v - frac(v)) / 255.0;\n\
}\n\
\n\
float _sfx_dec(float u)\n\
{\n\
	return (u <= 0.04045) ? (u / 12.92) : pow((u + 0.055) / 1.055, 2.4);\n\
}\n\
\n\
float _sfx_enc(float l)\n\
{\n\
	return (l <= 0.0031308) ? (12.92 * l) : (1.055 * pow(l, 1.0 / 2.4) - 0.055);\n\
}\n\
\n\
float4 _sfx_boundary(float4 r)\n\
{\n\
	float a = _sfx_q8(r.a);\n\
	if (a <= 0.0)\n\
		return float4(0.0, 0.0, 0.0, 0.0);\n\
	float3 v = float3(_sfx_q8(r.r), _sfx_q8(r.g), _sfx_q8(r.b));\n\
	if (a >= 1.0)\n\
		return float4(v, 1.0);\n\
	float3 pm = float3(_sfx_dec(v.r), _sfx_dec(v.g), _sfx_dec(v.b)) * a;\n\
	float3 s = float3(_sfx_q8(_sfx_enc(pm.r)), _sfx_q8(_sfx_enc(pm.g)), _sfx_q8(_sfx_enc(pm.b)));\n\
	float3 lin = float3(_sfx_dec(s.r), _sfx_dec(s.g), _sfx_dec(s.b)) / a;\n\
	return float4(_sfx_q8(_sfx_enc(lin.r)), _sfx_q8(_sfx_enc(lin.g)), _sfx_q8(_sfx_enc(lin.b)), a);\n\
}\n\
\n";

char *sf_fusion_build(const char *const *bodies, size_t count, const char *template_begin, const char *template_end)
{
	if (count < 2)
		return NULL;

	struct dstr out = {0};
	dstr_cat(&out, fusion_prelude);
	bool ok = true;

	for (size_t s = 0; s < count && ok; s++) {
		struct dstr stage_src = {0};
		dstr_cat(&stage_src, template_begin);
		dstr_cat(&stage_src, bodies[s]);
		bool last = s + 1 == count;
		if (last)
			dstr_cat(&stage_src, template_end);

		struct toks t;
		tokenize(stage_src.array, &t);
		struct pointwise_info pw = {0};
		da_init(pw.samples);
		if (s > 0) {
			analyse(&t, &pw);
			if (!pw.ok)
				ok = false;
		}
		/* An upstream stage that can discard would kill the whole fused
		 * pixel, where on its own it only skipped writing its own output. */
		for (size_t i = 0; !last && ok && i < t.a.num; i++)
			if (tok_is(&t, i, "discard") || (tok_is(&t, i, "clip") && tok_is(&t, i + 1, "(")))
				ok = false;
		if (ok) {
			emit_stage(&out, &t, s > 0 ? &pw : NULL, !last, s);
			if (!last) {
				/* Stage s+1 reads stage s's output at its own pixel,
				 * through the same 8-bit boundary as a texture would. */
				dstr_catf(&out,
					  "\nfloat4 _sf_fetch%zu(float4 pos, float2 uv)\n"
					  "{\n"
					  "\t_sf%zu_VertData v;\n"
					  "\tv.pos = pos;\n"
					  "\tv.uv = uv * _sf%zu_uv_scale + _sf%zu_uv_offset;\n"
					  "\treturn _sfx_boundary(_sf%zu_mainImage(v));\n"
					  "}\n",
					  s + 1, s, s, s, s);
			}
		}
		da_free(pw.samples);
		da_free(t.a);
		dstr_free(&stage_src);
	}

	if (!ok) {
		dstr_free(&out);
		return NULL;
	}
	return out.array;
}

char *sf_fusion_param_name(size_t stage, size_t count, const char *name)
{
	struct dstr s = {0};
	if (stage + 1 < count)
		dstr_printf(&s, "_sf%zu_%s", stage, name);
	else
		dstr_copy(&s, name);
	return s.array;
}
