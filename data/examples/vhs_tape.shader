// VHS Tape for obs-shaderfilter: VHS Signal, VHS Noise and VHS Tracking in
// one filter, with one Amount to turn the whole tape up or down. The tape's
// own settings (the same as the three separate filters', in the same units)
// set its character: a good tape, a worn one, long play. Amount says how
// much of it there is: 0 is a perfect copy of the picture, 100 the tape as
// set, 200 twice as far from perfect (twice the blur, delay, noise and
// wobble). See VHS Signal, VHS Noise and VHS Tracking for what each setting
// does. Black stays black. It goes before any CRT filters.

uniform float Amount<
    string label = "Amount";
    string tooltip = "How much of the tape's character there is, in percent: 0 is the picture untouched, 100 the tape as set below, 200 twice as far from perfect.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 100.0;
uniform int Standard<
    string label = "Standard";
    string tooltip = "The TV system: PAL (576 lines, 50 fields a second, as in the UK and Europe) or NTSC (480 lines, 59.94 fields a second, as in the US and Japan).";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "PAL";
    int option_1_value = 1;
    string option_1_label = "NTSC";
> = 0;
uniform float Luma_Resolution<
    string label = "Luma Resolution";
    string tooltip = "How much brightness detail survives across the picture, in TV lines. About 240 for VHS, 220 for long play, 400 for S-VHS.";
    string widget_type = "slider";
    float minimum = 100.0;
    float maximum = 600.0;
    float step = 5.0;
> = 240.0;
uniform float Chroma_Resolution<
    string label = "Chroma Resolution";
    string tooltip = "How much colour detail survives across the picture, in TV lines: far less than brightness on tape. About 30 to 40 for VHS.";
    string widget_type = "slider";
    float minimum = 10.0;
    float maximum = 200.0;
    float step = 1.0;
> = 40.0;
uniform float Chroma_Delay<
    string label = "Chroma Delay";
    string tooltip = "How far colour sits to the right of where it belongs, in pixels on a 1080-line picture. 2 to 6 on a typical VCR.";
    string widget_type = "slider";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 3.0;
uniform float Sharpening<
    string label = "Sharpening";
    string tooltip = "How much further a sharp edge overshoots, in percent of its step, from the player's detail circuit: a faint light and dark outline either side. The steep tape filter already rings about 6% by itself; 2 to 5 more is a typical VCR, 0 a plain one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 2.0;
uniform float White_Level<
    string label = "White Level";
    string tooltip = "How bright full white plays back, in percent. 100 keeps it; a worn or long-play tape plays back a little grey (92 to 96), which also leaves room for its noise to show in the whites.";
    string widget_type = "slider";
    float minimum = 80.0;
    float maximum = 100.0;
    float step = 0.5;
> = 100.0;
uniform float Saturation<
    string label = "Saturation";
    string tooltip = "How strong colours are, in percent: 100 keeps them as they are; tape often loses a little.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 150.0;
    float step = 1.0;
> = 90.0;
uniform float Noise<
    string label = "Noise";
    string tooltip = "Brightness noise, as a typical deviation in percent of full white, in short streaks along the lines. About 1 for a good tape, 2 for long play, 3 or more worn.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 6.0;
    float step = 0.05;
> = 1.3;
uniform float Colour_Noise<
    string label = "Colour Noise";
    string tooltip = "Colour noise, as a typical deviation in percent of full colour, in long soft blotches. About 2 for a good tape, 6 for a worn one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 15.0;
    float step = 0.1;
> = 2.0;
uniform float Dropouts<
    string label = "Dropouts";
    string tooltip = "Dropouts a minute, on average: a short stretch of a line replaced by the line above (or, one in four, a dim streak), for 1/24 s. 10 or so for a good tape, hundreds for a worn one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 600.0;
    float step = 1.0;
> = 12.0;
uniform float Jitter<
    string label = "Jitter";
    string tooltip = "How far lines sit to one side or the other, as a typical deviation in pixels on a 1080-line picture, bending down the picture and wandering slowly. 0.2 to 0.5 for a normal tape.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 5.0;
    float step = 0.05;
> = 0.4;
uniform float Head_Switching<
    string label = "Head Switching";
    string tooltip = "Torn, noisy lines at the bottom where the player switches heads, in TV lines. A TV's overscan hides them: 0 to hide, 6 to 10 to show them.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 20.0;
    float step = 1.0;
> = 0.0;
uniform float Tracking_Noise<
    string label = "Tracking Noise";
    string tooltip = "How strong the band of torn, noisy lines from bad tracking is, in percent, creeping up the picture. 0 for a well-tracked tape.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 0.0;
uniform float Skew<
    string label = "Skew";
    string tooltip = "How far the top few lines bend sideways (flagging), in pixels on a 1080-line picture. 0 for none.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 0.0;

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 tape_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Roughly Gaussian, mean 0 and deviation 1.
float tape_gauss(float3 p)
{
    float3 u = tape_hash(p);
    return (u.x + u.y + u.z - 1.5) * 2.0;
}

// Smooth noise along a line (whole-number points), deviation about 1.
float tape_smooth(float x, float line, float seed)
{
    float i = floor(x);
    float f = x - i;
    float u = f * f * (3.0 - 2.0 * f);
    float v = lerp(tape_gauss(float3(i, line, seed)), tape_gauss(float3(i + 1.0, line, seed)), u);
    return v / sqrt((1.0 - u) * (1.0 - u) + u * u);
}

// Smooth noise over two dimensions (down the lines, and in time).
float tape_smooth2(float2 p, float seed)
{
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = tape_gauss(float3(fmod(i.x, 9973.0), fmod(i.y, 9973.0), seed));
    float b = tape_gauss(float3(fmod(i.x + 1.0, 9973.0), fmod(i.y, 9973.0), seed));
    float c = tape_gauss(float3(fmod(i.x, 9973.0), fmod(i.y + 1.0, 9973.0), seed));
    float d = tape_gauss(float3(fmod(i.x + 1.0, 9973.0), fmod(i.y + 1.0, 9973.0), seed));
    float v = lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
    float2 s = (1.0 - u) * (1.0 - u) + u * u;
    return v / sqrt(s.x * s.y);
}

float3 tape_to_yiq(float3 c)
{
    return float3(dot(c, float3(0.299, 0.587, 0.114)), dot(c, float3(0.596, -0.274, -0.322)), dot(c, float3(0.211, -0.523, 0.312)));
}
float3 tape_from_yiq(float3 y)
{
    return float3(y.x + 0.956 * y.y + 0.621 * y.z, y.x - 0.272 * y.y - 0.647 * y.z, y.x - 1.106 * y.y + 1.703 * y.z);
}

float4 mainImage(VertData v_in) : TARGET
{
    float A = Amount * 0.01;
    if (A <= 0.0)
        return image.Sample(textureSampler, v_in.uv);

    float seed = rand_instance_f * 61.0;
    float lines = Standard == 1 ? 480.0 : 576.0;
    float rate = Standard == 1 ? 59.94 : 50.0;
    float field = fmod(floor(elapsed_time * rate), 9973.0);
    float line = floor(v_in.uv.y * lines);
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float x = v_in.uv.x * 1080.0 * aspect;
    float2 px = uv_pixel_interval / (uv_pixel_interval.y * 1080.0);

    // --- Tracking: this line's sideways shift, in pixels (VHS Tracking).
    float t = elapsed_time + seed;
    float shift = Jitter * A * (0.95 * tape_smooth2(float2(line / 60.0, t * 1.2), seed + 1.0) + 0.3 * tape_smooth2(float2(line / 8.0, t * 2.5), seed + 2.0));
    shift += Skew * A * exp(-line / 12.0) * (0.8 + 0.4 * tape_hash(float3(field, 3.0, seed)).x);
    float torn = 0.0;
    float hs = floor(Head_Switching * A + 0.5);
    float from_bottom = lines - 1.0 - line;
    if (from_bottom < hs) {
        float depth = 1.0 - from_bottom / max(hs, 1.0);
        shift += depth * (12.0 + 10.0 * tape_hash(float3(line, field, seed + 4.0)).x);
        torn = max(torn, depth * 0.35);
    }
    if (Tracking_Noise > 0.0) {
        float band_pos = (1.0 - frac(elapsed_time / 8.0 + seed * 0.13)) * (lines + 40.0) - 20.0;
        float d = abs(line - band_pos) / 10.0;
        float b = Tracking_Noise * 0.01 * A * saturate(1.0 - d * d);
        shift += b * 25.0 * tape_gauss(float3(line, field, seed + 6.0));
        torn = max(torn, b);
    }
    float2 uv = v_in.uv - float2(shift * px.x, 0.0);

    // --- Signal (VHS Signal): a steep luma low-pass (windowed sinc, fixed
    // weights) and a wider Gaussian for the detail circuit; then chroma over
    // two lines, late, 30% smeared and 70% laid on the brightness detail.
    // Filter widths grow with Amount from none.
    float step_l = 360.0 / max(Luma_Resolution, 1.0) * A;
    float y_l = 0.0;
    float y_w = 0.0;
    float a_l = 0.0;
    float wl = 0.0;
    float ww = 0.0;
    float wa = 0.0;
    float a_s = 0.0;
    for (int i = -12; i <= 12; i++) {
        float u = float(i) / 12.0;
        float4 s = image.Sample(textureSampler, uv + float2(float(i) * step_l * px.x, 0.0));
        float y = dot(s.rgb, float3(0.299, 0.587, 0.114)) * s.a;
        float sinc = i == 0 ? 1.0 : sin(12.566371 * u) / (12.566371 * u);
        float kl = sinc * (0.42 + 0.5 * cos(3.1415927 * u) + 0.08 * cos(6.2831853 * u));
        float kw = exp(-0.5 * (4.27 * u) * (4.27 * u));
        float ka = exp(-0.5 * (10.67 * u) * (10.67 * u));
        y_l += kl * y;
        wl += kl;
        y_w += kw * y;
        ww += kw;
        a_l += ka * s.a;
        wa += ka;
        a_s += kl * s.a;
    }
    y_l /= wl;
    a_l /= wa;
    y_w /= ww;
    // Nothing here to see: fully (or all but) transparent.
    if (a_l < 0.001)
        return float4(0.0, 0.0, 0.0, 0.0);
    // Brightness is taken out of premultiplied with transparency filtered
    // the same way, held between half the smooth transparency and 1 so the
    // filter's ringing can't dim or brighten it; the result's transparency
    // is that same filtered transparency, so over black an edge against
    // transparency is as bright as the same picture on black.
    a_s = clamp(a_s / wl, max(a_l * 0.5, 0.001), 1.0);
    float y_out = y_l + (Sharpening * A / 24.1) * (y_l - y_w);

    float sigma_c = 404.8 / max(Chroma_Resolution, 1.0) * A;
    float line_gap = Standard == 1 ? 1080.0 / 480.0 : 1080.0 / 576.0;
    float step_c = sigma_c * 0.5;
    float2 pix = v_in.uv / uv_pixel_interval;
    float jitter = frac(52.9829189 * frac(dot(pix, float2(0.06711056, 0.00583715)))) - 0.5;
    float3 yiq_c = float3(0.0, 0.0, 0.0);
    float a_c = 0.0;
    for (int r = 0; r < 2; r++) {
        float dy = -float(r) * line_gap * px.y * min(A, 1.0);
        for (int j = -7; j <= 7; j++) {
            float tj = float(j) + jitter;
            float o = tj * step_c - Chroma_Delay * A;
            float4 s = image.Sample(textureSampler, uv + float2(o * px.x, dy));
            float k = exp(-0.5 * (tj * 0.5) * (tj * 0.5));
            yiq_c += k * tape_to_yiq(s.rgb * s.a);
            a_c += k * s.a;
        }
    }
    float y_here = clamp(y_out / a_s, 0.0, 2.0) * (1.0 + (White_Level * 0.01 - 1.0) * A);
    float2 smeared = yiq_c.yz / max(a_c, 0.0001) * smoothstep(0.0, 0.03, yiq_c.x / max(a_c, 0.0001));
    float2 follows = yiq_c.yz / max(yiq_c.x, 0.0001) * y_here;
    float sat = 1.0 + (Saturation * 0.01 - 1.0) * A;
    float2 iq = (0.3 * smeared + 0.7 * follows) * max(sat, 0.0);
    float3 yiq = float3(y_here, iq);

    // --- Noise (VHS Noise): kept off black.
    float tick = fmod(floor(elapsed_time * 120.0), 9973.0);
    float drop_t = fmod(floor(elapsed_time * 24.0), 9973.0);
    float lseed = line + tick * 0.618;
    float keep = smoothstep(0.02, 0.08, yiq.x) * a_l;
    yiq.x += tape_smooth(x / 4.5, lseed, seed + 11.0) * Noise * 0.01 * A * keep;
    yiq.y += tape_smooth(x / 50.0, lseed, seed + 12.0) * Colour_Noise * 0.01 * A * 0.6 * keep;
    yiq.z += tape_smooth(x / 50.0, lseed, seed + 13.0) * Colour_Noise * 0.01 * A * 0.5 * keep;
    float3 rgb = max(tape_from_yiq(yiq), 0.0);
    float alpha = a_s;

    // Dropouts: the line above in place of a short stretch of this one.
    float per_chance = Dropouts * A / 60.0 / (4.0 * 24.0);
    for (int k = 0; k < 4; k++) {
        float3 h = tape_hash(float3(drop_t, float(k) + 21.0, seed));
        if (h.z >= per_chance)
            continue;
        float3 g = tape_hash(float3(drop_t, float(k) + 33.0, seed + 5.0));
        float len = 30.0 + 270.0 * g.x * g.x;
        float along = (x - h.y * 1080.0 * aspect) / len;
        if (line == floor(h.x * lines) && along >= 0.0 && along <= 1.0) {
            float shape = smoothstep(0.0, 0.15, along) * smoothstep(1.0, 0.7, along);
            // The line above, softened about as much as the tape softens
            // (three samples), at the tape's white level and saturation.
            float2 up = uv - float2(0.0, 1.0 / lines);
            float soft = 404.8 / max(Luma_Resolution, 1.0) * A * 1.5 * px.x;
            float4 a1 = image.Sample(textureSampler, up - float2(soft, 0.0));
            float4 a2 = image.Sample(textureSampler, up);
            float4 a3 = image.Sample(textureSampler, up + float2(soft, 0.0));
            float4 above = float4(a1.rgb * a1.a + a2.rgb * a2.a + a3.rgb * a3.a, a1.a + a2.a + a3.a) / 3.0;
            above.rgb /= max(above.a, 0.0001);
            float3 ay = tape_to_yiq(above.rgb);
            ay.x *= 1.0 + (White_Level * 0.01 - 1.0) * A;
            ay.yz *= max(sat, 0.0);
            float3 rep = max(tape_from_yiq(ay), 0.0) * (1.0 + 0.08 * tape_smooth(x / 4.5, lseed + 7.0, seed + 9.0));
            if (g.y < 0.25)
                rep = rgb * min(0.45 + 0.1 * tape_smooth(x / 8.0, lseed + 9.0, seed + 10.0), 0.8);
            rgb = lerp(rgb, max(rep, 0.0), shape);
            alpha = lerp(alpha, above.a, shape);
        }
    }

    // Torn lines' snow, kept off black.
    if (torn > 0.0) {
        float n = tape_hash(float3(floor(x / 2.0), lseed, seed + 8.0)).x;
        float snow = torn * smoothstep(0.55, 1.0, n) * smoothstep(0.02, 0.15, dot(rgb, float3(0.299, 0.587, 0.114)) * alpha);
        rgb = rgb * (1.0 - snow) + float3(0.9, 0.9, 0.9) * snow;
    }
    return float4(rgb, alpha);
}
