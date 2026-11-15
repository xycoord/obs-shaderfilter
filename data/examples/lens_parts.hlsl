// What the projector's lens does, shared by Lens and Film Look (included by
// them; not a shader on its own): distortion, fringing, corner falloff and
// corner softness. In Film Look they are one section with a tick (define
// FILM_LOOK before including this). See Lens for what each does.

#ifdef FILM_LOOK
uniform bool Lens_On<
    string label = "Lens · Glass (colour fringes, dark corners, bend)";
    string widget_type = "section";
    string group = "Lens";
    string tooltip = "What the projector's lens does: straight edges bow a little, colours fringe towards the edges, the corners darken and soften.";
> = true;
#endif
uniform float Fringing<
    string label = "Colour Fringes";
#ifdef FILM_LOOK
    string group = "Lens";
#endif
    string tooltip = "How far apart red and blue are at the left and right edges, in pixels on a 1080-line picture: none in the middle, more towards the edges. Negative swaps which side they fall on.";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = -20.0;
    float maximum = 20.0;
    float step = 0.1;
> = 5.0;
uniform int Corner_Falloff<
    string label = "Dark Corners";
#ifdef FILM_LOOK
    string group = "Lens";
#endif
    string tooltip = "How much of the light is lost in the corners: none in the middle, falling off smoothly (the cos^4 law). It stays still; the projector's Uneven Illumination is the lamp's, moving from frame to frame.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 80;
    int step = 1;
> = 25;
uniform float Distortion<
    string label = "Bend";
#ifdef FILM_LOOK
    string group = "Lens";
#endif
    string tooltip = "How strongly the picture bends: positive for barrel (its edges bow outwards and its corners round in), negative for pincushion. The middles of the left and right edges stay at the frame's edges. About 2 for a projector lens; 5 or more is a strong bend. It shows on a full-frame picture, not on a logo on black.";
    string widget_type = "slider";
    string suffix = " %";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.0;
uniform float Corner_Softness<
    string from = "lens_softness:Edge_Softness";
    string label = "Corner Blur";
#ifdef FILM_LOOK
    string group = "Lens";
#endif
    string show = "more";
    string tooltip = "How soft the corners are, in pixels on a 1080-line picture (a blur's standard deviation): none in the middle, growing towards the edges, all of it in the corners. The film's softness all over is the print's Softness.";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 1.0;

// The sRGB curve, both ways, carried on above 1.
float3 lens_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 lens_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// The picture as the lens shows it at uv, every effect a of the way from
// none.
float4 lens_at(float2 uv, float a)
{
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (uv - 0.5) * float2(aspect, 1.0);
    float rc2 = (aspect * aspect + 1.0) * 0.25;
    float e = dot(d, d) / rc2;

    // Distortion: this pixel shows the picture from 1 + k r^2 further out (k
    // set so that, before anything else, the corners would come in by
    // Distortion percent), then the whole picture is enlarged so the middles
    // of its left and right edges stay at the frame's edges: the picture
    // still fills the frame there, and only bows away from it towards the
    // corners. (Pincushion is the same the other way.)
    float m = max(1.0 - Distortion * a * 0.01, 0.01);
    float k = (1.0 / m - 1.0) / (m * m * rc2);
    float z = 1.0 / (1.0 + k * aspect * aspect * 0.25);
    float2 uv0 = 0.5 + (uv - 0.5) * (1.0 + k * dot(d, d)) * z;

    // Where the bent picture's edge falls inside the frame, it fades out over
    // a few pixels beyond it rather than cutting off, as a projected edge does
    // (with no bend, the picture's own edge pixels are left as they are).
    float2 qe = (abs(uv0 - 0.5) - 0.5) / uv_pixel_interval;
    float outside = length(max(qe, 0.0)) + min(max(qe.x, qe.y), 0.0);
    float feather = 2.0 / (uv_pixel_interval.y * 1080.0);
    float edge = 1.0 - smoothstep(0.0, 2.0 * feather, outside + 0.5);

    // The corner softness here (standard deviation, in the source's pixels)
    // and the fringes' size difference between red and blue (as in Lens
    // Chromatic Aberration, for many samples).
    float sigma = Corner_Softness * a * e / (uv_pixel_interval.y * 1080.0);
    float spread = Fringing * a / 0.6389 * 2.0 * uv_pixel_interval.x / (uv_pixel_interval.y * 1080.0);

    float4 c;
    if (sigma < 0.05 && spread == 0.0) {
        c = image.Sample(textureSampler, clamp(uv0, 0.5 * uv_pixel_interval, 1.0 - 0.5 * uv_pixel_interval));
    } else {
        // Samples on a spiral out to 3 standard deviations (each standing for
        // an equal area, the last turned by the golden angle; the spiral turned
        // differently at each pixel), each at its own wavelength t, spread
        // evenly from red to blue in a scrambled order. Samples stay half a
        // pixel inside the picture, so its edges keep their colour (no fringe
        // along the frame); the bent edge's fade is applied after.
        int n = sigma > 2.0 ? 48 : 24;
        float step_w = exp(-4.5 / float(n));
        float w = sqrt(step_w);
        float2 px = uv / uv_pixel_interval;
        float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
        float2 dir = float2(cos(turn), sin(turn));
        float2 reach = max(sigma, 0.0) * 3.0 * uv_pixel_interval;
        float2 lo = 0.5 * uv_pixel_interval;
        float2 hi = 1.0 - 0.5 * uv_pixel_interval;
        float3 sum = float3(0.0, 0.0, 0.0);
        float3 cover = float3(0.0, 0.0, 0.0);
        float3 total = float3(0.0, 0.0, 0.0);
        for (int i = 0; i < n; i++) {
            float t = frac((float(i) + 0.5) * 0.6180340);
            float kk = 3.0 * t - 1.5;
            float3 ws = saturate(float3(-kk, 1.0 - abs(kk), kk)) * w;
            float2 at = uv0 + dir * reach * sqrt((float(i) + 0.5) / float(n));
            float4 s = image.Sample(textureSampler, clamp(0.5 + (at - 0.5) * (1.0 + spread * (0.5 - t)), lo, hi));
            // Light added in (near enough) linear light: the square, undone
            // exactly below.
            sum += ws * s.rgb * s.rgb * s.a;
            cover += ws * s.a;
            total += ws;
            dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
            w *= step_w;
        }
        sum /= total;
        cover /= total;
        float alpha = max(cover.r, max(cover.g, cover.b));
        if (alpha <= 0.0)
            return float4(0.0, 0.0, 0.0, 0.0);
        c = float4(sqrt(max(sum / alpha, 0.0)), alpha);
    }

    c.a *= edge;

    // Corner falloff, the cos^4 law, in linear light, as Lens Vignette.
    float falloff = min(float(Corner_Falloff) * a, 99.0);
    if (falloff > 0.0) {
        float kv = (1.0 / sqrt(1.0 - falloff * 0.01) - 1.0) / rc2;
        float q = 1.0 + kv * dot(d, d);
        c.rgb = lens_from_linear(lens_to_linear(c.rgb) / (q * q));
    }
    return c;
}
