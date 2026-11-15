// VHS Tracking for obs-shaderfilter: a tape's unsteady timing. A VCR plays
// each line back a little early or late (timebase error); the TV's line
// lock smooths most of it, so what shows is a slow, wandering waver: lines a
// fraction of a pixel to one side or the other, bending gently down the
// picture and drifting about once or twice a second. At the
// bottom, where the player switches from one video head to the other, a few
// lines are torn sideways and noisy (usually hidden by a TV's overscan, so 0
// by default). A badly tracked tape adds a band of torn, noisy lines that
// creeps up the picture, and bends the top few lines sideways (flagging).
//
// Distances are in pixels on a 1080-line picture (scaled for other sizes),
// heights in TV lines. Edges that move in from outside the picture are
// transparent, and the torn lines' snow is kept off black, so black stays
// black. It goes after VHS Signal and VHS Noise.

uniform int Standard<
    string label = "Standard";
    string tooltip = "The TV system: PAL (576 lines, 50 fields a second) or NTSC (480 lines, 59.94 fields a second). Sets the lines and how often they change.";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "PAL";
    int option_1_value = 1;
    string option_1_label = "NTSC";
> = 0;
uniform float Jitter<
    string label = "Jitter";
    string tooltip = "How far lines sit to one side or the other, as a typical deviation in pixels on a 1080-line picture, bending down the picture and wandering slowly. 0.2 to 0.5 for a normal tape; above 1.5 it looks broken.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 5.0;
    float step = 0.05;
> = 0.3;
uniform float Head_Switching<
    string label = "Head Switching";
    string tooltip = "How many lines at the bottom are torn sideways and noisy where the player switches heads, in TV lines. A TV's overscan usually hides them: 0 to hide, 6 to 10 to show them, as on a monitor.";
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
    string tooltip = "How far the top few lines bend sideways (flagging), in pixels on a 1080-line picture. 0 for none; a few pixels for a tape recorded on another machine.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 0.0;

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 vhst_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Roughly Gaussian, mean 0 and deviation 1.
float vhst_gauss(float3 p)
{
    float3 u = vhst_hash(p);
    return (u.x + u.y + u.z - 1.5) * 2.0;
}

// Smooth noise over two dimensions (down the lines, and in time), deviation
// about 1.
float vhst_smooth2(float2 p, float seed)
{
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = vhst_gauss(float3(fmod(i.x, 9973.0), fmod(i.y, 9973.0), seed));
    float b = vhst_gauss(float3(fmod(i.x + 1.0, 9973.0), fmod(i.y, 9973.0), seed));
    float c = vhst_gauss(float3(fmod(i.x, 9973.0), fmod(i.y + 1.0, 9973.0), seed));
    float d = vhst_gauss(float3(fmod(i.x + 1.0, 9973.0), fmod(i.y + 1.0, 9973.0), seed));
    float v = lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
    float2 s = (1.0 - u) * (1.0 - u) + u * u;
    return v / sqrt(s.x * s.y);
}

float4 mainImage(VertData v_in) : TARGET
{
    float seed = rand_instance_f * 61.0;
    float lines = Standard == 1 ? 480.0 : 576.0;
    float rate = Standard == 1 ? 59.94 : 50.0;
    float field_count = floor(elapsed_time * rate);
    float field = fmod(field_count, 9973.0);
    float line = floor(v_in.uv.y * lines);

    // Sideways shift of this line, in pixels on a 1080-line picture.
    // Timebase error: a long bend over about 60 lines drifting about once a
    // second, and a little finer waver over about 8 lines, a bit faster.
    float t = elapsed_time + seed;
    float shift = Jitter * (0.95 * vhst_smooth2(float2(line / 60.0, t * 1.2), seed + 1.0) + 0.3 * vhst_smooth2(float2(line / 8.0, t * 2.5), seed + 2.0));

    // Flagging: the top lines bend, by about Skew at the top, fading over
    // about 12 lines, a little different each field.
    shift += Skew * exp(-line / 12.0) * (0.8 + 0.4 * vhst_hash(float3(field, 3.0, seed)).x);

    // Head switching: the bottom lines torn sideways, more towards the
    // bottom, ragged from field to field, and noisy.
    float noise = 0.0;
    float from_bottom = lines - 1.0 - line;
    if (from_bottom < Head_Switching) {
        float depth = 1.0 - from_bottom / max(Head_Switching, 1.0);
        shift += depth * (12.0 + 10.0 * vhst_hash(float3(line, field, seed + 4.0)).x);
        noise = max(noise, depth * 0.35);
    }

    // Tracking noise: a band about 20 lines high, creeping up the picture
    // once every 8 seconds or so, its lines torn and noisy.
    if (Tracking_Noise > 0.0) {
        float band_pos = (1.0 - frac(elapsed_time / 8.0 + seed * 0.13)) * (lines + 40.0) - 20.0;
        float d = abs(line - band_pos) / 10.0;
        float b = Tracking_Noise * 0.01 * saturate(1.0 - d * d);
        shift += b * 25.0 * vhst_gauss(float3(line, field, seed + 6.0));
        noise = max(noise, b);
    }

    // The picture, shifted; edges moving in from outside are transparent
    // (the sampler's border).
    float2 px = uv_pixel_interval / (uv_pixel_interval.y * 1080.0);
    float4 c = image.Sample(textureSampler, v_in.uv - float2(shift * px.x, 0.0));

    // Noise where the line is torn: bright snow, in streaks along the line.
    if (noise > 0.0) {
        float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
        float n = vhst_hash(float3(floor(v_in.uv.x * 1080.0 * aspect / 2.0), line + field * 0.618, seed + 8.0)).x;
        float snow = noise * smoothstep(0.55, 1.0, n) * smoothstep(0.02, 0.15, dot(c.rgb, float3(0.299, 0.587, 0.114)) * c.a);
        c.rgb = c.rgb * (1.0 - snow) + float3(0.9, 0.9, 0.9) * snow;
    }
    return c;
}
