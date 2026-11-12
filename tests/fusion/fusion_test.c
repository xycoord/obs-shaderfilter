/*
 * Unit checks for shader-fusion.c, run without a GPU.
 *
 *   fusion_test pointwise FILE...      print "1 FILE" / "0 FILE"
 *   fusion_test build FILE FILE [...]  print the fused effect text
 */
#include "../../shader-fusion.h"
#include <stdio.h>
#include <string.h>
#include <util/bmem.h>
#include <util/platform.h>


int main(int argc, char **argv)
{
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
