// Lens for obs-shaderfilter: everything the projector's lens does, in one
// pass. Lens Distortion (straight edges bowing), Lens Softness's edge
// softness (the lens's focus falling off towards the corners), Lens Chromatic
// Aberration (colour fringes towards the edges) and Lens Vignette (darker
// corners) together, with the same settings, and one Amount to turn the whole
// lens up or down. The film's own softness, all over the picture, is in Film
// (or Lens Softness on its own), before the grain.
//
// Amount scales every effect from none (0: the picture comes through
// untouched) through the settings as set (100) to twice as strong (200). The
// fringes and the corner softness share one set of samples: each of them sees
// a slightly different wavelength, so together they cost about what the
// softness costs alone. Sizes are in pixels on a 1080-line picture (scaled
// for other sizes). It goes last in a film look.

uniform int Lens_Amount<
    string label = "Amount";
    string tooltip = "How strong the whole lens is, in percent of the settings below: 0 is a perfect lens (the picture untouched), 100 as set, 200 twice as strong.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 200;
    int step = 1;
> = 100;

#include "lens_parts.hlsl"

float4 mainImage(VertData v_in) : TARGET
{
    return lens_at(v_in.uv, float(Lens_Amount) * 0.01);
}
