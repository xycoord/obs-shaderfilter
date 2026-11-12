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
	{"#define FLIP v_in.uv.y = 1.0 - v_in.uv.y\n" BODY("FLIP; return image.Sample(textureSampler, v_in.uv);"), false},
	{"#define WOBBLE(p) p.x += 0.1\n" BODY("float2 uv = v_in.uv; WOBBLE(uv); return image.Sample(textureSampler, uv);"), false},
	{"#define MOVE(p) \\\n  p++\n" BODY("float2 uv = v_in.uv; MOVE(uv); return image.Sample(textureSampler, uv);"), false},
	{"#define PI 3.14159\n#define SAME(a, b) ((a) == (b))\n" BODY("return image.Sample(textureSampler, v_in.uv) * PI;"), true},
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
	/* Sampler state values in a renamed stage keep their names. */
	const char *sampled[] = {"sampler_state tiled { Filter = Point; AddressU = Repeat; AddressV = wrap; };\n" BODY(
					 "return image.Sample(tiled, v_in.uv * 4.0);"),
				 BODY("return image.Sample(textureSampler, v_in.uv);")};
	if ((r = sf_fusion_build(sampled, 2, tb, "")) == NULL ||
	    !strstr(r, "sampler_state _sf0_tiled { Filter = Point; AddressU = Repeat; AddressV = wrap; }")) {
		printf("FAIL sampler_state body renamed:\n%s\n", r ? r : "(not built)");
		failures++;
	}
	bfree(r);
	/* A macro used inside a sampler_state body is renamed with its #define. */
	const char *macro_sampler[] = {"#define MODE Point\nsampler_state px { Filter = MODE; };\n" BODY(
					       "return image.Sample(px, v_in.uv * 2.0);"),
				       BODY("return image.Sample(textureSampler, v_in.uv);")};
	if ((r = sf_fusion_build(macro_sampler, 2, tb, "")) == NULL || !strstr(r, "#define _sf0_MODE Point") ||
	    !strstr(r, "Filter = _sf0_MODE;")) {
		printf("FAIL macro in sampler_state not renamed with its #define:\n%s\n", r ? r : "(not built)");
		failures++;
	}
	bfree(r);
	if (sf_fusion_can_feed(up_clip[0]) || sf_fusion_can_feed(up_discard[0]) || !sf_fusion_can_feed(ok[0])) {
		printf("FAIL sf_fusion_can_feed\n");
		failures++;
	}
	/* A builtin's name the stage defines itself is renamed. */
	const char *own_floor[] = {"uniform float floor = 0.5;\n" BODY("return image.Sample(textureSampler, v_in.uv) * floor;"),
				   BODY("return image.Sample(textureSampler, v_in.uv);")};
	if ((r = sf_fusion_build(own_floor, 2, tb, "")) == NULL || !strstr(r, "uniform float _sf0_floor") ||
	    !strstr(r, "* _sf0_floor")) {
		printf("FAIL user uniform named like a builtin not renamed:\n%s\n", r ? r : "(not built)");
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
