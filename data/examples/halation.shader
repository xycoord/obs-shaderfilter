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
uniform string Full_Look<
    string label = "Switch to Film Look";
    string widget_type = "switch";
    string tooltip = "Make this filter a Film Look (the film, projector and lens in one filter), keeping these settings: the parts this filter doesn't have are set to the same Look.";
> = "film_look.shader";

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

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);

    // The threshold, set as an everyday brightness, in linear light.
    float t = Threshold * 0.01;
    t = t <= 0.04045 ? t / 12.92 : pow((t + 0.055) / 1.055, 2.4);

    // A Gaussian blur of the light above the threshold, from 64 points on a
    // spiral out to 3.2 standard deviations. Size is 1.645 of them: there, the
    // halo outside a straight bright edge has faded to a tenth of its
    // brightness at the edge. The spiral is turned differently at each pixel,
    // so the gaps between its points come out as an even fine noise, not a
    // pattern. Each point is the last turned by the golden angle, and its
    // weight the last times a constant, so the loop has no sines, cosines or
    // exponentials; the sRGB curve in it is a close cubic (within 0.002).
    // (Sizes and pixel positions from the source's own size: uv_size includes
    // any space added round it.)
    float sigma = max(Size, 1.0) / 1.645 / (uv_pixel_interval.y * 1080.0);
    float2 reach = sigma * 3.2 * uv_pixel_interval;
    float2 px = v_in.uv / uv_pixel_interval;
    float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    float2 dir = float2(cos(turn), sin(turn));
    float w = 0.96078944;
    float glow = 0.0;
    for (int i = 0; i < 64; i++) {
        float4 s = image.Sample(textureSampler, v_in.uv + dir * reach * sqrt((float(i) + 0.5) / 64.0));
        float3 lin = s.rgb * (s.rgb * (s.rgb * 0.305306011 + 0.682171111) + 0.012522878);
        glow += w * s.a * max(dot(lin, float3(0.2126, 0.7152, 0.0722)) - t, 0.0);
        dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
        w *= 0.92311635;
    }
    // (12.421987 is the sum of the weights.)
    glow /= 12.421987 * (1.0 - t);
    // Inside an evenly bright area the halo's light is the same everywhere,
    // and doesn't show: a print is graded so the area has the colour it should.
    // So only what's more than the pixel would get from its own brightness is
    // drawn: the halo spilling onto darker parts round bright ones.
    // (The same close cubic as the samples, so in an even area the two cancel
    // exactly.)
    float3 c_lin = c.rgb * (c.rgb * (c.rgb * 0.305306011 + 0.682171111) + 0.012522878);
    float own = c.a * max(dot(c_lin, float3(0.2126, 0.7152, 0.0722)) - t, 0.0) / (1.0 - t);
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
