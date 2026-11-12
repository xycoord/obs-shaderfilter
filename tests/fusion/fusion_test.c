/*
 * Unit checks for shader-fusion.c, run without a GPU.
 *
 *   fusion_test pointwise FILE...      print "1 FILE" / "0 FILE"
 *   fusion_test build FILE FILE [...]  print the fused effect text
 *   fusion_test selftest               check the analysis on known patterns
 */
#include "../../shader-fusion.h"
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <util/bmem.h>
#include <util/platform.h>


#define BODY(x) "float4 mainImage(VertData v_in) : TARGET\n{\n" x "\n}\n"

static const struct {
	const char *body;
	bool pointwise;
} cases[] = {
	{BODY("return image.Sample(textureSampler, v_in.uv);"), true},
	{BODY("float4 c = image.Sample(textureSampler, v_in.uv); return 1.0 - c;"), true},
	{BODY("float2 uv = v_in.uv; return image.Sample(textureSampler, uv);"), true},
	{BODY("string s = \"image\"; return image.Sample(textureSampler, v_in.uv);"), true},
	{BODY("// image.Sample(textureSampler, v_in.uv * 2.0)\nreturn image.Sample(textureSampler, v_in.uv);"), true},
	{BODY("return image.Sample(textureSampler, v_in.uv * 2.0);"), false},
	{BODY("return image.Sample(textureSampler, v_in.uv + uv_pixel_interval);"), false},
	{BODY("v_in.uv.x += 0.1; return image.Sample(textureSampler, v_in.uv);"), false},
	{BODY("v_in.uv = 1.0 - v_in.uv; return image.Sample(textureSampler, v_in.uv);"), false},
	{BODY("float2 uv = v_in.uv; uv.x = 0.5; return image.Sample(textureSampler, uv);"), false},
	{BODY("float2 uv = v_in.uv; uv[0] += 0.1; return image.Sample(textureSampler, uv);"), false},
	{BODY("float2 uv = v_in.uv; uv++; return image.Sample(textureSampler, uv);"), false},
	{"void nudge(inout float2 p) { p.x += 0.1; }\n" BODY("float2 uv = v_in.uv; nudge(uv); return image.Sample(textureSampler, uv);"), false},
	{"float4 helper(float2 uv) { return image.Sample(textureSampler, uv); }\n" BODY("return helper(v_in.uv);"), false},
	{BODY("return image.SampleLevel(textureSampler, v_in.uv, 0);"), false},
	{BODY("return float4(1.0, 0.0, 0.0, 1.0);"), false},
};

static int selftest(void)
{
	int failures = 0;
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		bool got = sf_fusion_is_pointwise(cases[i].body);
		if (got != cases[i].pointwise) {
			printf("FAIL pointwise=%d expected %d:\n%s\n", got, cases[i].pointwise, cases[i].body);
			failures++;
		}
	}
	/* An upstream stage that can discard must not be fused. */
	const char *up_discard[] = {BODY("if (v_in.uv.x > 0.5) discard; return image.Sample(textureSampler, v_in.uv);"),
				    BODY("return image.Sample(textureSampler, v_in.uv);")};
	const char *up_clip[] = {BODY("float4 c = image.Sample(textureSampler, v_in.uv); clip(c.a - 0.5); return c;"),
				 BODY("return image.Sample(textureSampler, v_in.uv);")};
	const char *ok[] = {BODY("return image.Sample(textureSampler, v_in.uv);"),
			    BODY("float4 c = image.Sample(textureSampler, v_in.uv); if (c.a < 0.1) discard; return c;")};
	const char *tb = "uniform float2 uv_scale;\nuniform float2 uv_offset;\nuniform texture2d image;\n"
			 "struct VertData { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n";
	char *r;
	if ((r = sf_fusion_build(up_discard, 2, tb, "")) != NULL) {
		printf("FAIL fused an upstream stage with discard\n");
		bfree(r);
		failures++;
	}
	if ((r = sf_fusion_build(up_clip, 2, tb, "")) != NULL) {
		printf("FAIL fused an upstream stage with clip()\n");
		bfree(r);
		failures++;
	}
	if ((r = sf_fusion_build(ok, 2, tb, "")) == NULL) {
		printf("FAIL refused a downstream stage with discard\n");
		failures++;
	}
	bfree(r);
	printf("%s: %d failure(s)\n", failures ? "FAIL" : "ok", failures);
	return failures ? 1 : 0;
}

int main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "selftest") == 0)
		return selftest();
	if (argc < 3)
		return 2;
	if (strcmp(argv[1], "pointwise") == 0) {
		for (int i = 2; i < argc; i++) {
			char *text = os_quick_read_utf8_file(argv[i]);
			printf("%d %s\n", text ? sf_fusion_is_pointwise(text) : -1, argv[i]);
			bfree(text);
		}
		return 0;
	}
	if (strcmp(argv[1], "build") == 0) {
		const char *bodies[16];
		int n = 0;
		for (int i = 2; i < argc && n < 16; i++)
			bodies[n++] = os_quick_read_utf8_file(argv[i]);
		char *out = sf_fusion_build(bodies, (size_t)n, "/*BEGIN*/\nuniform float2 uv_scale;\nuniform float2 uv_offset;\nuniform texture2d image;\nstruct VertData { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n",
					    "\n/*END*/\n");
		if (!out) {
			fprintf(stderr, "not fusable\n");
			return 1;
		}
		fputs(out, stdout);
		bfree(out);
		return 0;
	}
	return 2;
}
