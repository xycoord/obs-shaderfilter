// Dust & Scratches for obs-shaderfilter: the dirt and damage on a film print,
// different on every frame. Dust and hairs on the negative print as light
// specks (the sparkle of old film); dust on the print itself projects dark.
// A scratch along the film stays in about the same place for as long as the
// damaged stretch takes to go through the projector, wandering a little.
//
// Dust is set as specks a frame, on average, and their size in pixels on a
// 1080-line picture (scaled for other sizes); scratches as how many are on
// screen at once, on average. Give it the same Speed as Film Grain, Gate Weave
// and Projector Flicker. It goes after Film Grain and before Gate Weave (the
// dirt is on the film, which weaves). Light marks show on a transparent
// source too, as round a logo, with their own transparency.

uniform float Dust<
    string label = "Dust";
    string tooltip = "How many specks of dust or hair are on each frame, on average (each is on screen for one frame). 1 or 2 for a clean print, 5 or more for a dirty one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 16.0;
    float step = 0.1;
> = 3.0;
uniform float Speck_Size<
    string label = "Speck Size";
    string tooltip = "How wide a typical speck is, in pixels on a 1080-line picture (they vary, from about half to twice this). Dust looks bigger on smaller film, magnified more.";
    string widget_type = "slider";
    float minimum = 2.0;
    float maximum = 24.0;
    float step = 0.5;
> = 8.0;
uniform float Light_Specks<
    string label = "Light Specks";
    string tooltip = "The share of specks that are light (dirt on the negative), in percent; the rest are dark (dirt on the print). On a logo on black, only light specks show on the black.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 70.0;
uniform float Scratches<
    string label = "Scratches";
    string tooltip = "How many scratches are on screen at once, on average (up to 3). Each lasts a second or so, wandering a little.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 0.5;
uniform int Speed<
    string label = "Speed";
    string tooltip = "Frames of film a second: the dust changes this often. 24 for sound film, 16 to 18 for silent film and Super 8. Use the same as Film Grain's, Gate Weave's and Projector Flicker's Speed.";
    string widget_type = "slider";
    int minimum = 1;
    int maximum = 60;
    int step = 1;
> = 24;

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 dust_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float seed = rand_instance_f * 61.0;

    // The frame of film, counted as the other film shaders count them; the
    // hash's inputs repeat after 9973.
    float frame_count = floor(elapsed_time * float(Speed));
    float frame = fmod(frame_count, 9973.0);

    // This pixel in pixels of a 1080-line picture, and the picture's width in them.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 p = v_in.uv * float2(1080.0 * aspect, 1080.0);

    // Light marks (positive) and dark ones (negative).
    float mark = 0.0;

    // Dust: 16 places a frame, each with a speck Dust / 16 of the time, so
    // Dust specks a frame on average.
    for (int i = 0; i < 16; i++) {
        float3 h = dust_hash(float3(frame, float(i), seed));
        if (h.z * 16.0 >= Dust)
            continue;
        float3 g = dust_hash(float3(frame, float(i) + 31.0, seed + 7.0));
        float2 q = p - float2(h.x * 1080.0 * aspect, h.y * 1080.0);
        float ang = g.x * 6.2831853;
        q = float2(cos(ang) * q.x + sin(ang) * q.y, -sin(ang) * q.x + cos(ang) * q.y);
        // Radius from about a quarter to the whole of Speck_Size (half of it
        // typically, for a speck Speck_Size wide); one in eight is a hair,
        // long and thin.
        float size = Speck_Size * 0.5 * (0.45 + 1.65 * g.y * g.y);
        float3 k = dust_hash(float3(frame, float(i) + 63.0, seed + 13.0));
        float2 shape = k.x < 0.125 ? float2(size * (4.0 + 6.0 * k.y), size * 0.35) : float2(size, size * (0.7 + 0.3 * k.y));
        float s = saturate(1.5 - length(q / shape));
        mark += (k.z * 100.0 < Light_Specks ? 1.0 : -1.0) * s;
    }

    // Scratches: 3 places, each with a scratch Scratches / 3 of the time,
    // lasting about 1.25 seconds of film, wandering a little each frame and
    // slowly across.
    float life_len = max(float(Speed) * 1.25, 1.0);
    for (int j = 0; j < 3; j++) {
        float offset = float(j) / 3.0;
        float life = floor(frame_count / life_len + offset);
        float3 h = dust_hash(float3(fmod(life, 9973.0), float(j) + 50.0, seed));
        if (h.z * 3.0 >= Scratches)
            continue;
        float3 f = dust_hash(float3(frame, float(j) + 70.0, seed));
        float age = frame_count / life_len + offset - life;
        float x = h.x * 1080.0 * aspect + (f.x - 0.5) * 2.0 + (age - 0.5) * (h.y - 0.5) * 30.0;
        float width = 0.6 + 1.2 * h.y;
        float along = 0.6 + 0.4 * sin(p.y * 0.013 + h.x * 40.0 + frame * 0.3);
        mark += saturate(1.0 - abs(p.x - x) / width) * along * (0.5 + 0.5 * f.y) * 0.8;
    }

    // Dark marks take the picture away; light ones add a warm white over it,
    // with their own transparency where the source is transparent.
    float3 rgb = c.rgb * (1.0 - saturate(-mark));
    float light = max(mark, 0.0);
    float3 lit = rgb * c.a + float3(0.85, 0.82, 0.75) * light;
    float alpha = max(c.a, saturate(light));
    if (alpha <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(lit / alpha, alpha);
}
