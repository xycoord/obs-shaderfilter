// Lens Softness for obs-shaderfilter: the softness of a projected film
// picture. Film resolves less than a 1080p picture (16mm well under it), and a
// projector's lens softens it again, more towards the corners: a lens can't
// hold the whole picture in focus at once. A digital logo's pixel-sharp edges
// are the most digital-looking thing about it on a screen; this takes them off.
//
// Two settings, as blur in pixels on a 1080-line picture (scaled for other
// sizes), as a Gaussian's standard deviation: Softness everywhere, and Edge
// Softness added towards the corners, growing with the square of the distance
// from the middle. Light is blurred as light (in linear light), and
// transparency with it.
//
// It goes before Film Grain: the grain stays crisp on a soft picture, which
// reads as film. Where the source is transparent, as round a logo, the soft
// edge is drawn with its own transparency.

uniform float Softness<
    string label = "Softness";
    string tooltip = "How soft the whole picture is, in pixels on a 1080-line picture (the blur's standard deviation). About 0.5 for 35mm, 1 for 16mm, 1.5 or more for Super 8 and old film; past 2 it looks out of focus.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 1.0;
uniform float Edge_Softness<
    string label = "Edge Softness";
    string tooltip = "How much softer the corners are than the middle, in pixels on a 1080-line picture: none in the middle, growing towards the edges, all of it in the corners, as a lens's focus falls off.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 1.0;

float4 mainImage(VertData v_in) : TARGET
{
    // Distance from the middle, squared, with the corners at 1.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float e = dot(d, d) / ((aspect * aspect + 1.0) * 0.25);

    // The blur's standard deviation here, in the source's own pixels.
    float sigma = (Softness + Edge_Softness * e) / (uv_pixel_interval.y * 1080.0);
    if (sigma < 0.05)
        return image.Sample(textureSampler, v_in.uv);

    // A Gaussian from 24 points on a spiral out to 3 standard deviations,
    // each standing for an equal area of it and the last turned by the golden
    // angle. The spiral is turned differently at each pixel, so the gaps
    // between its points come out as an even fine noise, not a pattern. In
    // linear light, by a close cubic for the sRGB curve (within 0.002),
    // weighted by transparency.
    float2 px = v_in.uv / uv_pixel_interval;
    float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    float2 dir = float2(cos(turn), sin(turn));
    float2 reach = sigma * 3.0 * uv_pixel_interval;
    float3 sum = float3(0.0, 0.0, 0.0);
    float cover = 0.0;
    float total = 0.0;
    float w = 0.91051036;
    for (int i = 0; i < 24; i++) {
        float4 s = image.Sample(textureSampler, v_in.uv + dir * reach * sqrt((float(i) + 0.5) / 24.0));
        float3 lin = s.rgb * (s.rgb * (s.rgb * 0.305306011 + 0.682171111) + 0.012522878);
        sum += w * lin * s.a;
        cover += w * s.a;
        total += w;
        dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
        w *= 0.82902912;
    }
    if (cover <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    // Back to the sRGB curve, over the colour the covered parts have.
    float3 l = max(sum / cover, 0.0);
    float3 enc = lerp(l * 12.92, 1.055 * pow(l, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, l));
    return float4(enc, cover / total);
}
