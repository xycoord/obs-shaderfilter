// Projector for obs-shaderfilter: everything the film projector adds, in one
// pass. Gate Weave (the picture not sitting still in the gate), Projector
// Flicker (the lamp and the film's density changing frame to frame) and
// Projector Gate (the soft, round-cornered frame) together, with the same
// settings, and one Amount to turn the whole projector up or down.
//
// Amount scales every effect from none (0: the picture comes through
// untouched) through the settings as set (100) to twice as strong (200).
// Weave and flicker step together, once per frame of film, at Speed (with
// Hand Cranking wavering both). Set Speed the same as Film's or Film Grain's;
// each filter counts time from when it was added, so their frames change at
// the same rate but not at the same moment.
// It goes after the film's own effects (grain and dust move with the picture)
// and before the lens's. Outside the gate the picture turns transparent
// (black on a projector).

uniform float Amount<
    string label = "Amount";
    string tooltip = "How strong the whole projector is, in percent of the settings below: 0 is none (the picture untouched), 100 as set, 200 twice as strong.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 100.0;
uniform int Speed<
    string label = "Speed";
    string group = "Film";
    string tooltip = "Frames of film a second: the picture weaves and flickers this often. 24 for sound film, 16 to 18 for silent film and Super 8.";
    string widget_type = "slider";
    int minimum = 1;
    int maximum = 60;
    int step = 1;
> = 24;
uniform float Hand_Cranking<
    string label = "Hand Cranking";
    string group = "Film";
    string tooltip = "How much the frame rate wavers (in percent), as it did when film was cranked by hand, until about 1915. 0 is a motor-driven projector.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 0.0;
uniform float Weave<
    string label = "Weave";
    string group = "Gate Weave";
    string tooltip = "How far the picture floats from side to side (in pixels on a 1080-line picture, typical).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 0.8;
uniform float Jump<
    string label = "Jump";
    string group = "Gate Weave";
    string tooltip = "How far the picture jumps up or down from one frame to the next (in pixels on a 1080-line picture, typical).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 0.6;
uniform float Exposure_Flicker<
    string label = "Exposure Flicker";
    string group = "Flicker";
    string tooltip = "How much brightness changes from one frame of film to the next (in percent, typical). 2% is a good print; 5% or more is old film.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 15.0;
    float step = 0.1;
> = 3.5;
uniform float Lamp_Flicker<
    string label = "Lamp Flicker";
    string group = "Flicker";
    string tooltip = "How much the projector's lamp wavers, smoothly, a few times a second (in percent).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.5;
uniform float Dark_Frames<
    string label = "Dark Frames";
    string group = "Flicker";
    string tooltip = "How many single frames a minute come out dark: dirt, a splice, an underexposed frame.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 60.0;
    float step = 0.5;
> = 4.0;
uniform float Dark_Frame_Depth<
    string label = "Dark Frame Depth";
    string group = "Flicker";
    string tooltip = "How much darker a dark frame is (in percent).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 50.0;
    float step = 0.5;
> = 15.0;
uniform float Uneven_Illumination<
    string label = "Uneven Illumination";
    string group = "Flicker";
    string tooltip = "How much brighter one side, or the middle, of the picture is than the rest (in percent), moving from frame to frame: the lamp's, unlike Lens's steady Corner Falloff.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 1.5;
uniform float Lamp_Brightness<
    string label = "Lamp Brightness";
    string group = "Flicker";
    string tooltip = "The picture's average brightness, in percent. At 100 white can only flicker darker; at 90 or so it flickers both ways.";
    string widget_type = "slider";
    float minimum = 50.0;
    float maximum = 100.0;
    float step = 0.5;
> = 100.0;
uniform float Corner_Radius<
    string label = "Corner Radius";
    string group = "Gate";
    string tooltip = "How round the picture's corners are, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 30.0;
uniform float Edge_Softness<
    string label = "Edge Softness";
    string group = "Gate";
    string tooltip = "How soft the picture's edge is, in pixels on a 1080-line picture (the gate is a little out of focus).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 40.0;
    float step = 0.5;
> = 8.0;
uniform float Inset<
    string label = "Inset";
    string group = "Gate";
    string tooltip = "How far in from the source's edges the gate's edge sits, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.5;
> = 6.0;

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 projector_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Roughly Gaussian, mean 0 and standard deviation 1. x is a whole number (a
// frame, or a point of the smooth noise); its sequence repeats after 9973.
float projector_gauss(float x, float seed)
{
    float3 u = projector_hash(float3(fmod(x, 9973.0), seed, seed * 0.37 + 5.0));
    return (u.x + u.y + u.z - 1.5) * 2.0;
}

// Smooth noise along one dimension, standard deviation about 1.
float projector_smooth(float x, float seed)
{
    float i = floor(x);
    float f = x - i;
    float u = f * f * (3.0 - 2.0 * f);
    float v = lerp(projector_gauss(i, seed), projector_gauss(i + 1.0, seed), u);
    return v / sqrt((1.0 - u) * (1.0 - u) + u * u);
}

float4 mainImage(VertData v_in) : TARGET
{
    float a = Amount * 0.01;
    float seed = rand_instance_f * 61.0;

    // The frame of film on screen: Speed frames a second, wavering when hand
    // cranked (by at most Hand_Cranking percent, from two slow waves, so the
    // film never runs backwards). Weave and flicker both step on it, so each
    // frame weaves and flickers together.
    float h = Hand_Cranking * 0.01 * a;
    float w1 = 6.2831853 * 0.23;
    float w2 = 6.2831853 * 0.61;
    float t = elapsed_time;
    float crank = h * (0.6 * (cos(seed * 0.71) - cos(w1 * t + seed * 0.71)) / w1 + 0.4 * (cos(seed * 1.37) - cos(w2 * t + seed * 1.37)) / w2);
    float frame = floor(float(Speed) * (t + crank));
    float lit_frame = frame;

    // Gate weave: side to side mostly a wander over about half a second, up
    // and down mostly new each frame; pixels on a 1080-line picture.
    float wander = float(Speed) * 0.5;
    float x = Weave * a * (0.45 * projector_gauss(frame, seed + 21.0) + 0.89 * projector_smooth(frame / wander, seed + 22.0));
    float y = Jump * a * (0.8 * projector_gauss(frame, seed + 23.0) + 0.6 * projector_smooth(frame / 4.0, seed + 24.0));
    float4 c = image.Sample(textureSampler, v_in.uv - float2(x, y) * uv_pixel_interval / (uv_pixel_interval.y * 1080.0));

    // Flicker: lamp (smooth, a few times a second), exposure (each frame, with
    // a drift), dark frames and uneven illumination, as Projector Flicker.
    float tl = fmod(t, 9973.0);
    float lamp = (projector_smooth(tl * 3.1, seed + 1.0) + 0.5 * projector_smooth(tl * 7.3, seed + 2.0)) / 1.118;
    float gain = Lamp_Flicker * 0.01 * lamp;
    gain += Exposure_Flicker * 0.01 * (0.8 * projector_gauss(lit_frame, seed + 3.0) + 0.6 * projector_smooth(lit_frame / 6.0, seed + 4.0));
    float3 b = projector_hash(float3(fmod(lit_frame, 9973.0), seed + 5.0, 7.0));
    if (b.x < Dark_Frames / (60.0 * float(Speed)))
        gain -= Dark_Frame_Depth * 0.01 * (0.75 + 0.5 * b.y);
    float3 r = projector_hash(float3(fmod(lit_frame, 9973.0), seed + 6.0, 11.0));
    float angle = r.x * 6.2831853;
    float2 dd = v_in.uv - 0.5;
    float side = dot(dd, float2(cos(angle), sin(angle))) * 2.0;
    float middle = 0.5 - 2.0 * dot(dd, dd);
    gain += Uneven_Illumination * 0.0245 * ((r.y - 0.5) * side * 2.0 + (r.z - 0.5) * middle * 2.0);
    float lamp_level = lerp(1.0, Lamp_Brightness * 0.01, min(a, 1.0));
    c.rgb *= lamp_level * max(1.0 + gain * a, 0.0);

    // The gate: a rounded rectangle, its edge softened over Edge_Softness.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 p = dd * float2(1080.0 * aspect, 1080.0);
    float2 half_size = max(float2(540.0 * aspect, 540.0) - Inset * a, 1.0);
    float rr = min(Corner_Radius * a, min(half_size.x, half_size.y));
    float2 q = abs(p) - (half_size - rr);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
    float s = max(Edge_Softness * a, 0.001);
    c.a *= 1.0 - smoothstep(-0.5 * s, 0.5 * s, d);
    return c;
}
