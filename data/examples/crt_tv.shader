// CRT TV for obs-shaderfilter: CRT Geometry, CRT Scanlines, CRT Mask and
// CRT Glass in one filter, with one Amount to turn the whole set up or
// down. The set's own settings (the same as the four separate filters', in
// the same units) give its character; Amount says how much of it there is:
// 0 is the picture untouched, 100 the set as described, 200 twice as far
// from a perfect flat screen (twice the bow, convergence error, mask, glow
// and falloff, and thinner beams). See the separate filters for what each
// setting does. The lines and the mask are drawn flat, in the picture's own
// pixels, and the picture is bent under them, so neither beats against the
// pixels. In light (linear); black stays black. It goes after any VHS
// filters. Show it at the projector's own resolution for the lines and mask
// to stay even.

uniform float Amount<
    string label = "Amount";
    string tooltip = "How much of the set's character there is, in percent: 0 is the picture untouched, 100 the set as described below, 200 twice as far from a perfect flat screen.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 100.0;
uniform float Curvature<
    string label = "Curvature";
    string tooltip = "How far the picture's corners are pulled in, in percent of their distance from the middle: the bow of a curved tube. 1 is gentle, 3 strong; 0 is flat.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 15.0;
    float step = 0.1;
> = 1.0;
uniform float Convergence<
    string label = "Convergence";
    string tooltip = "How far red and blue sit either side of green at the left and right edges, in pixels on a 1080-line picture: none in the middle. Up to 1 for a typical TV.";
    string widget_type = "slider";
    float minimum = -5.0;
    float maximum = 5.0;
    float step = 0.05;
> = 0.8;
uniform int Standard<
    string label = "Lines";
    string tooltip = "How many lines: a TV's broadcast picture (576 or 480, a faint texture), or games and computers (270 or 360 on a 1080-line picture, 4 or 3 pixels apart, with clear gaps between them; on other sizes rounded to whole pixels apart).";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "TV, PAL (576 lines)";
    int option_1_value = 1;
    string option_1_label = "TV, NTSC (480 lines)";
    int option_2_value = 2;
    string option_2_label = "Games and computers (270 lines)";
    int option_3_value = 3;
    string option_3_label = "Games and computers, fine (360 lines)";
> = 0;
uniform float Beam_Width<
    string label = "Beam Width";
    string tooltip = "How wide a full-brightness line is, as its width at half height (FWHM) in percent of the distance between lines. At 90 bright parts keep a faint ripple; at 120 their lines merge.";
    string widget_type = "slider";
    float minimum = 40.0;
    float maximum = 150.0;
    float step = 1.0;
> = 90.0;
uniform float Blooming<
    string label = "Blooming";
    string tooltip = "How much wider a full-brightness line is than a dim one, in percent: the beam spreading as it's driven harder.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 40.0;
uniform int Mask_Type<
    string label = "Mask";
    string tooltip = "The tube's phosphor pattern: a shadow mask (dots in triangles, most TVs), an aperture grille (vertical stripes, Trinitron) or a slot mask (stripes in short slots).";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "Shadow mask";
    int option_1_value = 1;
    string option_1_label = "Aperture grille";
    int option_2_value = 2;
    string option_2_label = "Slot mask";
> = 1;
uniform float Pitch<
    string label = "Mask Pitch";
    string tooltip = "The width of one red, green and blue set, in whole pixels on a 1080-line picture: 3 is about a TV's.";
    string widget_type = "slider";
    float minimum = 3.0;
    float maximum = 8.0;
    float step = 1.0;
> = 3.0;
uniform float Mask_Strength<
    string label = "Mask Strength";
    string tooltip = "How much light the mask's dark parts lose, in percent; the picture loses half this with the aperture grille, more with the slot and shadow masks.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 10.0;
uniform float Glow<
    string label = "Glow";
    string tooltip = "How much of the light the glass spreads into a soft glow, in percent. 1 to 3 for a TV in a dark room.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.1;
> = 1.5;
uniform float Glow_Size<
    string label = "Glow Size";
    string tooltip = "How far the glow reaches, in percent of the picture's height. About 4 to 6 in a TV's glass.";
    string widget_type = "slider";
    float minimum = 0.5;
    float maximum = 20.0;
    float step = 0.1;
> = 4.0;
uniform float Corner_Radius<
    string label = "Corner Radius";
    string tooltip = "How rounded the picture's corners are, in pixels on a 1080-line picture. 30 to 60 for a TV's tube.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 40.0;
uniform float Edge_Falloff<
    string label = "Edge Falloff";
    string tooltip = "How much light is lost in the corners, in percent, falling off smoothly from the middle.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 80.0;
    float step = 1.0;
> = 10.0;

// The sRGB curve, both ways, carried on above 1.
float3 tv_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 tv_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// The share of a unit Gaussian below z (a close approximation).
float3 tv_cdf(float3 z)
{
    return 0.5 + 0.5 * tanh(0.7978846 * (z + 0.044715 * z * z * z));
}

// Where on the source a point of the screen shows, bent by the tube
// (barrel) and moved sideways by conv (in units of the picture's height).
float2 tv_warp(float2 uv, float k, float conv, float aspect)
{
    float2 d = (uv - 0.5) * float2(aspect, 1.0);
    float2 s = d * (1.0 + k * dot(d, d)) + float2(conv, 0.0);
    return s / float2(aspect, 1.0) + 0.5;
}

// The tube's bow (as in mainImage), for the glow.
float tv_k()
{
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float curv = min(Curvature * Amount * 0.01, 50.0);
    return (1.0 / (1.0 - curv * 0.01) - 1.0) / ((aspect * aspect + 1.0) * 0.25);
}

// The glow, drawn small where the plugin draws stages (see glow_parts.hlsl):
// of the bent picture.
#define GLOW_SIGMA Glow_Size * 0.01 / 3.0 / uv_pixel_interval.y
#define GLOW_ON Glow > 0.0 && Amount > 0.0
#define GLOW_SAMPLE(uv) glow_source(tv_warp(uv, tv_k(), 0.0, uv_pixel_interval.y / uv_pixel_interval.x))
#include "glow_parts.hlsl"

float4 stage1(VertData v_in) : TARGET
{
    return glow_down(v_in.uv);
}

float4 stage2(VertData v_in) : TARGET
{
    return glow_blur(v_in.uv, float2(1.0, 0.0));
}

float4 stage3(VertData v_in) : TARGET
{
    return glow_blur(v_in.uv, float2(0.0, 1.0));
}

// The bent picture at p, its colours converged conv apart: light (each
// colour from its own sample, premultiplied by its transparency) and the
// largest transparency.
float4 tv_sample(float2 p, float k, float conv, float aspect)
{
    float4 sr = glow_source(tv_warp(p, k, -conv, aspect));
    float4 sg = glow_source(tv_warp(p, k, 0.0, aspect));
    float4 sb = glow_source(tv_warp(p, k, conv, aspect));
    return float4(tv_to_linear(float3(sr.r, sg.g, sb.b)) * float3(sr.a, sg.a, sb.a), max(sg.a, max(sr.a, sb.a)));
}

// One line's light over this pixel, from its filtered colour f (light and
// transparency): each colour's beam wider the brighter it is, its light
// spread over the line's share of height and summed over this pixel; and
// the line's transparency if this pixel is in its share. None for a line
// outside the picture.
void tv_line(float li, float last, float gap, float y, float s_dark, float s_bright, float4 f, inout float3 light,
             inout float cover)
{
    if (li < 0.0 || li >= last)
        return;
    float yc = (li + 0.5) * gap;
    float3 sig = lerp(float3(s_dark, s_dark, s_dark), float3(s_bright, s_bright, s_bright), sqrt(saturate(f.rgb)));
    float3 share = tv_cdf((y + 0.5 - yc) / sig) - tv_cdf((y - 0.5 - yc) / sig);
    light += f.rgb * share * gap;
    if (abs(y - yc) <= gap * 0.5)
        cover = f.a;
}

float4 mainImage(VertData v_in) : TARGET
{
    float A = Amount * 0.01;
    if (A <= 0.0)
        return glow_source(v_in.uv);

    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float corner2 = (aspect * aspect + 1.0) * 0.25;

    // --- Geometry: the bow, and convergence growing towards the sides.
    float curv = min(Curvature * A, 50.0);
    float k = (1.0 / (1.0 - curv * 0.01) - 1.0) / corner2;
    float conv = Convergence * A / 1080.0 * (d.x / (aspect * 0.5));

    // --- Scanlines, drawn flat in the output's pixels, each line filtered
    // from the bent picture (three samples down, per colour).
    float lines = Standard == 1 ? 480.0 : (Standard == 2 ? 270.0 : (Standard == 3 ? 360.0 : 576.0));
    float height = 1.0 / uv_pixel_interval.y;
    float gap = height / lines;
    // Games and computers' lines in whole pixels of this picture, whatever its size.
    if (Standard >= 2)
        gap = max(floor(gap + 0.5), 2.0);
    float y = v_in.uv.y * height;
    float bw = Beam_Width / max(1.0 + (A - 1.0) * 0.5, 1.0);
    float s_bright = bw * 0.01 * gap / 2.3548;
    float s_dark = s_bright / (1.0 + Blooming * 0.01 * max(A, 1.0));
    float n = floor(y / gap - 0.5);
    float last = floor(height / gap + 0.5);
    // Each of the four lines filtered from the bent picture (three samples
    // down, half a line apart, per colour). Next lines' samples overlap, so
    // the four lines take nine, not twelve.
    float base = (n - 0.5) * gap - gap * 0.5;
    float4 p0 = tv_sample(float2(v_in.uv.x, (base + 0.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p1 = tv_sample(float2(v_in.uv.x, (base + 1.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p2 = tv_sample(float2(v_in.uv.x, (base + 2.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p3 = tv_sample(float2(v_in.uv.x, (base + 3.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p4 = tv_sample(float2(v_in.uv.x, (base + 4.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p5 = tv_sample(float2(v_in.uv.x, (base + 5.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p6 = tv_sample(float2(v_in.uv.x, (base + 6.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p7 = tv_sample(float2(v_in.uv.x, (base + 7.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float4 p8 = tv_sample(float2(v_in.uv.x, (base + 8.0 * gap * 0.5) * uv_pixel_interval.y), k, conv, aspect);
    float3 light = float3(0.0, 0.0, 0.0);
    float cover = 0.0;
    tv_line(n - 1.0, last, gap, y, s_dark, s_bright, (0.60653066 * p0 + p1 + 0.60653066 * p2) / 2.21306132, light, cover);
    tv_line(n, last, gap, y, s_dark, s_bright, (0.60653066 * p2 + p3 + 0.60653066 * p4) / 2.21306132, light, cover);
    tv_line(n + 1.0, last, gap, y, s_dark, s_bright, (0.60653066 * p4 + p5 + 0.60653066 * p6) / 2.21306132, light, cover);
    tv_line(n + 2.0, last, gap, y, s_dark, s_bright, (0.60653066 * p6 + p7 + 0.60653066 * p8) / 2.21306132, light, cover);

    // Amount under 100 blends the lines with the bent picture itself.
    float4 here = glow_source(tv_warp(v_in.uv, k, 0.0, aspect));
    float3 flat_light = tv_to_linear(here.rgb) * here.a;
    float sl = min(A, 1.0);
    light = lerp(flat_light, light, sl);
    cover = max(lerp(here.a, cover, sl), max(light.r, max(light.g, light.b)));

    // --- Mask, flat in the output's pixels.
    float ms = min(Mask_Strength * A, 100.0) * 0.01;
    if (ms > 0.0) {
        float pitch = max(floor(Pitch / (uv_pixel_interval.y * 1080.0) + 0.5), 3.0);
        float2 q = (floor(v_in.uv / uv_pixel_interval) + float2(0.0, 0.5)) / pitch;
        float3 phase = float3(0.0, 1.0 / 3.0, 2.0 / 3.0);
        float3 g;
        if (Mask_Type == 0) {
            float rows = q.y * pitch / max(floor(0.866 * pitch + 0.5), 2.0);
            float row = floor(rows);
            g = (0.5 + 0.5 * cos(6.2831853 * (q.x + fmod(row, 2.0) * 0.5 - phase))) * (0.5 - 0.5 * cos(6.2831853 * (rows - row)));
        } else if (Mask_Type == 2) {
            float down = 0.7 + 0.3 * cos(6.2831853 * (q.y * pitch / max(floor(1.5 * pitch + 0.5), 2.0) + fmod(floor(q.x), 2.0) * 0.5));
            g = (0.5 + 0.5 * cos(6.2831853 * (q.x - phase))) * down;
        } else {
            g = 0.5 + 0.5 * cos(6.2831853 * (q.x - phase));
        }
        light *= 1.0 - ms * (1.0 - g);
    }

    // --- Glass: a neutral glow from the bent picture (its light through
    // the mask on average), then the tube's corners and falloff.
    float gl = Glow * 0.01 * A;
    if (gl > 0.0) {
        float4 glow = glow_at(v_in.uv);
        float through = Mask_Type == 0 ? 0.25 : (Mask_Type == 2 ? 0.35 : 0.5);
        light = light * (1.0 - gl) + glow.rgb * (1.0 - ms * (1.0 - through)) * gl;
        cover = cover * (1.0 - gl) + glow.a * gl;
    }

    float fall = min(Edge_Falloff * A, 95.0) * 0.01;
    float kf = (1.0 / sqrt(1.0 - fall) - 1.0) / corner2;
    float q2 = 1.0 + kf * dot(d, d);
    light /= q2 * q2;
    float r = Corner_Radius * A / 1080.0;
    float2 qd = abs(d) - (float2(aspect * 0.5, 0.5) - r);
    float dist = length(max(qd, 0.0)) + min(max(qd.x, qd.y), 0.0) - r;
    float inside = saturate(0.5 - dist / uv_pixel_interval.y);
    light *= inside;
    cover = saturate(cover) * inside;

    if (cover <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(tv_from_linear(light / cover), cover);
}
