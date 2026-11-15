// Halation for obs-shaderfilter: the red-orange glow round the bright parts of
// a picture on film. Bright light goes through the emulsion, reflects off the
// back of the film base and exposes the emulsion again in a halo round where
// it came in. In colour film the layer nearest the base records red, so the
// halo is red-orange; in black-and-white film it's a plain lighter glow. Film
// has an anti-halation layer to stop it, which keeps it faint; on older film it
// worked less well.
//
// Unlike Bloom, only what's brighter than the threshold glows, the glow is
// added as light adds (in linear light, so it doesn't grey the picture), and
// its size is in pixels on a 1080-line picture, so it looks the same on a
// source of any size. On smaller film the halo is bigger in the picture: the
// base is about as thick, the frame is smaller (see the presets).
//
// It goes early in a film look, before Film Grain (the halo is in the film,
// under the grain). Where the source is transparent, as round a logo, the glow
// is drawn with its own transparency. If bright parts touch the source's edges,
// Add Space Around the Image (in Show Advanced Options) lets the glow spread
// past them. It treats the picture as an ordinary (SDR) one; on an HDR source
// the threshold falls in a different place.

uniform string Full_Look<
    string label = "Switch to Film Look (adds the rest of the look)";
    string widget_type = "switch";
    string tooltip = "Make this filter a Film Look (the film, projector and lens in one filter), keeping these settings: the parts this filter doesn't have are set to the same Look.";
> = "film_look.shader";
uniform float Strength<
    string label = "Strength";
    string tooltip = "How bright the halo is (in percent): the share of the light above the threshold that spreads into it. Just outside a large white area it's about half this. Dark detail inside bright parts, such as thin lines narrower than the halo, fills with it too, as on film: keep it low for detailed logos.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 11.0;
uniform float Size<
    string label = "Size";
    string tooltip = "How far the halo reaches from a bright edge (to a tenth of its brightness at the edge), in pixels on a 1080-line picture (it's scaled for other sizes). About 15 for 35mm film, 30 for 16mm, 55 for Super 8.";
    string widget_type = "slider";
    float minimum = 2.0;
    float maximum = 120.0;
    float step = 0.5;
> = 22.0;
uniform float Threshold<
    string label = "Threshold";
    string tooltip = "How bright a part of the picture has to be to glow, in percent of white. Lower it for more of the picture to glow.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 99.0;
    float step = 1.0;
> = 80.0;
uniform int Film<
    string label = "Film";
    string tooltip = "Colour film's halo is red-orange; black-and-white film's is a plain lighter glow.";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "Colour";
    int option_1_value = 1;
    string option_1_label = "Black and white";
> = 0;

#define HALO_SIZE Size
#define HALO_THRESHOLD Threshold
#define HALO_ON Strength > 0.0
#include "halo_parts.hlsl"

// The sRGB curve, both ways, carried on above 1.
float3 halation_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 halation_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

float4 stage1(VertData v_in) : TARGET
{
    return halo_down(v_in.uv);
}

float4 stage2(VertData v_in) : TARGET
{
    return halo_blur(v_in.uv, float2(1.0, 0.0));
}

float4 stage3(VertData v_in) : TARGET
{
    return halo_blur(v_in.uv, float2(0.0, 1.0));
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = halo_source(v_in.uv);
    float t = halo_threshold();
    float2 px = v_in.uv / uv_pixel_interval;
    float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    float glow = halo_at(v_in.uv, t, turn) / (1.0 - t);
    // Inside an evenly bright area the halo's light is the same everywhere,
    // and doesn't show: a print is graded so the area has the colour it should.
    // So only what's more than the pixel would get from its own brightness is
    // drawn: the halo spilling onto darker parts round bright ones.
    float own = halo_light(c, t) / (1.0 - t);
    glow = max(glow - own, 0.0) * Strength * 0.01;
    // The halo's colour: red-orange, or neutral for black and white, the two
    // equally bright (luminance 0.31).
    float3 tint = Film == 1 ? float3(0.31, 0.31, 0.31) : float3(1.0, 0.13, 0.03);
    float3 h = tint * glow;

    // Added as light, over the picture with its transparency: where the source
    // is opaque this is the picture plus the halo; where it's transparent, the
    // halo alone, as much opaque as it is bright.
    float3 lit = halation_to_linear(c.rgb) * c.a + h;
    float alpha = saturate(max(c.a, max(h.r, max(h.g, h.b))));
    if (alpha <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(halation_from_linear(lit / alpha), alpha);
}
