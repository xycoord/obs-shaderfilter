// VHS Noise for obs-shaderfilter: the noise of a picture played back from
// tape. Brightness noise runs along each line in short streaks (the signal
// is recorded along the line, at limited bandwidth), new every frame; colour
// noise comes in long, soft blotches of shifting hue, stronger than the
// brightness noise; and now and then a speck of oxide missing from the tape
// loses a stretch of a line for a moment (a dropout). A VCR hides most
// dropouts by repeating the line above in their place, so they show as a
// short streak where the picture doesn't quite match; the rest show as a
// short, dim, noisy streak.
//
// Noise is set as a typical deviation (RMS) in percent of full white, on the
// signal as recorded (gamma-encoded), as a VCR adds it; good tape is about
// 1% (40 dB signal to noise), worn tape 2 or more. It's kept off black, and
// a dropout repeats what's above it, so black stays black: on a picture with
// a black background, noise shows on the picture itself.
//
// It goes after VHS Signal and before VHS Tracking. It changes 120 times a
// second, so it's new on every frame of a 50 or 60 frame-a-second output.

uniform int Standard<
    string label = "Standard";
    string tooltip = "The TV system: PAL (576 lines) or NTSC (480 lines). Sets the lines the noise runs along.";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "PAL";
    int option_1_value = 1;
    string option_1_label = "NTSC";
> = 0;
uniform float Noise<
    string label = "Noise";
    string tooltip = "How much brightness noise there is, as a typical deviation in percent of full white, in short streaks along the lines. About 1 for a good tape (40 dB), 2 for long play, 3 or more for a worn one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 6.0;
    float step = 0.05;
> = 1.3;
uniform float Colour_Noise<
    string label = "Colour Noise";
    string tooltip = "How much colour noise there is, as a typical deviation in percent of full colour, in long soft blotches along the lines: on tape about two or three times the brightness noise. About 2 for a good tape, 6 for a worn one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 15.0;
    float step = 0.1;
> = 2.0;
uniform float Dropouts<
    string label = "Dropouts";
    string tooltip = "How many dropouts a minute, on average: a short stretch of a line replaced by the line above (or, one in four, a dim streak), for 1/24 s. 10 or so for a good tape, a few hundred for a worn one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 600.0;
    float step = 1.0;
> = 12.0;

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 vhsn_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Roughly Gaussian (mean 0, deviation 1) values at whole numbers along a
// line, blended smoothly between, rescaled to keep the deviation.
float vhsn_smooth(float x, float line, float seed)
{
    float i = floor(x);
    float f = x - i;
    float u = f * f * (3.0 - 2.0 * f);
    float3 a = vhsn_hash(float3(i, line, seed));
    float3 b = vhsn_hash(float3(i + 1.0, line, seed));
    float va = (a.x + a.y + a.z - 1.5) * 2.0;
    float vb = (b.x + b.y + b.z - 1.5) * 2.0;
    return lerp(va, vb, u) / sqrt((1.0 - u) * (1.0 - u) + u * u);
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float seed = rand_instance_f * 61.0;

    // The moment (120 a second), the line, and this pixel along the line in
    // pixels of a 1080-line picture. Hash inputs repeat after 9973 moments
    // (83 seconds for the noise, 7 minutes for dropouts).
    float lines = Standard == 1 ? 480.0 : 576.0;
    float field = fmod(floor(elapsed_time * 120.0), 9973.0);
    float drop_t = fmod(floor(elapsed_time * 24.0), 9973.0);
    float line = floor(v_in.uv.y * lines);
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float x = v_in.uv.x * 1080.0 * aspect;
    float lseed = line + field * 0.618;

    // Signal: luma and colour difference, on the encoded picture.
    float y = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float3 iq = float3(y, dot(c.rgb, float3(0.596, -0.274, -0.322)), dot(c.rgb, float3(0.211, -0.523, 0.312)));

    // Kept off black: nothing below 2% grey, all of it from 8%.
    float keep = smoothstep(0.02, 0.08, y) * c.a;

    // Brightness noise in streaks about 4.5 pixels long (the tape's
    // bandwidth), colour noise in blotches about 50.
    float n = vhsn_smooth(x / 4.5, lseed, seed + 1.0);
    iq.x += n * Noise * 0.01 * keep;
    iq.y += vhsn_smooth(x / 50.0, lseed, seed + 2.0) * Colour_Noise * 0.01 * 0.6 * keep;
    iq.z += vhsn_smooth(x / 50.0, lseed, seed + 3.0) * Colour_Noise * 0.01 * 0.5 * keep;

    float3 rgb = float3(iq.x + 0.956 * iq.y + 0.621 * iq.z, iq.x - 0.272 * iq.y - 0.647 * iq.z, iq.x - 1.106 * iq.y + 1.703 * iq.z);
    rgb = max(rgb, 0.0);

    // Dropouts: four chances every 1/24 s, each a stretch 30 to 300 pixels
    // long on one line, held for that 1/24 s (so it's seen at any output
    // rate of 24 frames a second or more), Dropouts a minute on average. The VCR puts the line
    // above in its place (a little noisier), fading in and out at the ends.
    float per_chance = Dropouts / 60.0 / (4.0 * 24.0);
    for (int k = 0; k < 4; k++) {
        float3 h = vhsn_hash(float3(drop_t, float(k) + 11.0, seed));
        if (h.z >= per_chance)
            continue;
        float3 g = vhsn_hash(float3(drop_t, float(k) + 23.0, seed + 5.0));
        float dline = floor(h.x * lines);
        float len = 30.0 + 270.0 * g.x * g.x;
        float along = (x - h.y * 1080.0 * aspect) / len;
        if (line == dline && along >= 0.0 && along <= 1.0) {
            float shape = smoothstep(0.0, 0.15, along) * smoothstep(1.0, 0.7, along);
            float4 above = image.Sample(textureSampler, v_in.uv - float2(0.0, 1.0 / lines));
            float3 rep = above.rgb * (1.0 + 0.08 * vhsn_smooth(x / 4.5, lseed + 7.0, seed + 9.0));
            // One in four the VCR doesn't hide well: a dim, mottled streak
            // instead. It only ever darkens, so black stays black.
            if (g.y < 0.25)
                rep = rgb * min(0.45 + 0.1 * vhsn_smooth(x / 8.0, lseed + 9.0, seed + 10.0), 0.8);
            rgb = lerp(rgb, max(rep, 0.0), shape);
            c.a = lerp(c.a, above.a, shape);
        }
    }
    return float4(rgb, c.a);
}
