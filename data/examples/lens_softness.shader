// Lens Softness for obs-shaderfilter: the softness of a projected film
// picture. Film resolves less than a 1080p picture (16mm well under it), and a
// projector's lens softens it again, more towards the corners: a lens can't
// hold the whole picture in focus at once. A digital logo's pixel-sharp edges
// are the most digital-looking thing about it on a screen; this takes them off.
//
// Two settings, as blur in pixels on a 1080-line picture (scaled for other
// sizes), as a Gaussian's standard deviation: Softness everywhere, and Edge
// Softness added towards the corners, growing with the square of the distance
// from the middle. Light is blurred as light (in near-linear light), and
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
uniform string Full_Look<
    string label = "Switch to Film Look";
    string widget_type = "switch";
    string tooltip = "Make this filter a Film Look (the film, projector and lens in one filter), keeping these settings: the parts this filter doesn't have are set to the same Look.";
> = "film_look.shader";

// Near enough linear light for a blur, both ways: the square (a gamma of 2,
// close to sRGB's 2.2) and its exact inverse, so a pixel left as it was comes
// back unchanged.
float3 softness_to_linear(float3 c)
{
    return c * c;
}
float3 softness_from_linear(float3 c)
{
    return sqrt(max(c, 0.0));
}

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

    // A Gaussian from points on a spiral out to 3 standard deviations, each
    // standing for an equal area of it and the last turned by the golden
    // angle: 24, or 48 for a blur wider than 2 pixels, so it stays smooth. The spiral is turned differently at each pixel, so the gaps
    // between its points come out as an even fine noise, not a pattern. In
    // (near enough) linear light, weighted by transparency. Samples are kept
    // half a pixel inside the picture (so a full-frame picture's edges stay
    // opaque), unless this pixel is outside it, in added space.
    float2 lo = min(v_in.uv, 0.5 * uv_pixel_interval);
    float2 hi = max(v_in.uv, 1.0 - 0.5 * uv_pixel_interval);
    float2 px = v_in.uv / uv_pixel_interval;
    float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    float2 dir = float2(cos(turn), sin(turn));
    float2 reach = sigma * 3.0 * uv_pixel_interval;
    float3 sum = float3(0.0, 0.0, 0.0);
    float cover = 0.0;
    float total = 0.0;
    int n = sigma > 2.0 ? 48 : 24;
    float step_w = exp(-4.5 / float(n));
    float w = sqrt(step_w);
    for (int i = 0; i < n; i++) {
        float4 s = image.Sample(textureSampler, clamp(v_in.uv + dir * reach * sqrt((float(i) + 0.5) / float(n)), lo, hi));
        sum += w * softness_to_linear(s.rgb) * s.a;
        cover += w * s.a;
        total += w;
        dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
        w *= step_w;
    }
    if (cover <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);

    // Back to the sRGB curve, over the colour the covered parts have.
    return float4(softness_from_linear(sum / cover), cover / total);
}
