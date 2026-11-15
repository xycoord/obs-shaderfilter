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

uniform float Amount<
    string label = "Amount";
    string tooltip = "How strong the whole lens is, in percent of the settings below: 0 is a perfect lens (the picture untouched), 100 as set, 200 twice as strong.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 100.0;
uniform float Distortion<
    string label = "Distortion";
    string tooltip = "How far the corners move, in percent: positive for barrel (edges bow out, corners come in), negative for pincushion (corners go out and are cut off).";
    string widget_type = "slider";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.0;
uniform float Edge_Softness<
    string label = "Edge Softness";
    string tooltip = "How soft the corners are, in pixels on a 1080-line picture (a blur's standard deviation): none in the middle, growing towards the edges, all of it in the corners.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 1.0;
uniform float Fringing<
    string label = "Fringing";
    string tooltip = "How far apart red and blue are at the left and right edges, in pixels on a 1080-line picture: none in the middle, more towards the edges. Negative swaps which side they fall on.";
    string widget_type = "slider";
    float minimum = -20.0;
    float maximum = 20.0;
    float step = 0.1;
> = 5.0;
uniform float Corner_Falloff<
    string label = "Corner Falloff";
    string tooltip = "How much of the light is lost in the corners, in percent: none in the middle, falling off smoothly (the cos^4 law).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 80.0;
    float step = 1.0;
> = 25.0;

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

float4 mainImage(VertData v_in) : TARGET
{
    float a = Amount * 0.01;
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float rc2 = (aspect * aspect + 1.0) * 0.25;
    float e = dot(d, d) / rc2;

    // Distortion: this pixel shows the picture from 1 + k r^2 further out, k
    // set so the corners come in by Distortion percent.
    float m = max(1.0 - Distortion * a * 0.01, 0.01);
    float k = (1.0 / m - 1.0) / (m * m * rc2);
    float2 uv0 = 0.5 + (v_in.uv - 0.5) * (1.0 + k * dot(d, d));

    // The corner softness here (standard deviation, in the source's pixels)
    // and the fringes' size difference between red and blue (as in Lens
    // Chromatic Aberration, for many samples).
    float sigma = Edge_Softness * a * e / (uv_pixel_interval.y * 1080.0);
    float spread = Fringing * a / 0.6389 * 2.0 * uv_pixel_interval.x / (uv_pixel_interval.y * 1080.0);

    float4 c;
    if (sigma < 0.05 && spread == 0.0) {
        c = image.Sample(textureSampler, uv0);
    } else {
        // Samples on a spiral out to 3 standard deviations (each standing for
        // an equal area, the last turned by the golden angle; the spiral turned
        // differently at each pixel), each at its own wavelength t, spread
        // evenly from red to blue in a scrambled order. A bent picture's edge
        // is left to fade into the transparent outside; otherwise samples stay
        // half a pixel inside the picture, so a full frame's edges keep their
        // colour.
        int n = sigma > 2.0 ? 48 : 24;
        float step_w = exp(-4.5 / float(n));
        float w = sqrt(step_w);
        float2 px = v_in.uv / uv_pixel_interval;
        float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
        float2 dir = float2(cos(turn), sin(turn));
        float2 reach = max(sigma, 0.0) * 3.0 * uv_pixel_interval;
        float2 lo = Distortion * a > 0.0 ? float2(-1.0, -1.0) : min(v_in.uv, 0.5 * uv_pixel_interval);
        float2 hi = Distortion * a > 0.0 ? float2(2.0, 2.0) : max(v_in.uv, 1.0 - 0.5 * uv_pixel_interval);
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

    // Corner falloff, the cos^4 law, in linear light, as Lens Vignette.
    float falloff = min(Corner_Falloff * a, 99.0);
    if (falloff > 0.0) {
        float kv = (1.0 / sqrt(1.0 - falloff * 0.01) - 1.0) / rc2;
        float q = 1.0 + kv * dot(d, d);
        c.rgb = lens_from_linear(lens_to_linear(c.rgb) / (q * q));
    }
    return c;
}
