// What the projector adds, shared by Projector and Film Look (included by them;
// not a shader on its own): gate weave, flicker and the frame's edge (the
// gate), each a section with a tick to switch it off. A shader including this
// declares Speed (frames a second). See Projector for what each does.

uniform bool Weave_On<
    string label = "Gate Weave (picture wobble)";
    string widget_type = "section";
    string group = "Gate Weave";
    string tooltip = "The picture not sitting quite still in the projector: a slow drift from side to side and a small jump up or down each frame.";
> = true;
uniform float Weave<
    string label = "Weave";
    string group = "Gate Weave";
    string tooltip = "How far the picture floats from side to side, in pixels on a 1080-line picture (typical).";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 0.8;
uniform float Jump<
    string label = "Jump";
    string group = "Gate Weave";
    string show = "more";
    string tooltip = "How far the picture jumps up or down from one frame to the next, in pixels on a 1080-line picture (typical).";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 0.6;
uniform float Hand_Cranking<
    string label = "Hand Cranking";
    string group = "Gate Weave";
    string show = "more";
    string tooltip = "How much the frame rate wavers, as it did when film was cranked by hand, until about 1915: the weave and the flicker both speed up and slow down. 0 is a motor-driven projector.";
    string widget_type = "slider";
    string suffix = " %";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 0.0;
uniform bool Flicker_On<
    string label = "Flicker";
    string widget_type = "section";
    string group = "Flicker";
    string tooltip = "The picture's brightness changing from frame to frame: the film's density and the projector's lamp. Kept gentle, as fast flashing across a big picture can be uncomfortable to watch.";
> = true;
uniform float Exposure_Flicker<
    string label = "Exposure Flicker";
    string group = "Flicker";
    string tooltip = "How much brightness changes from one frame of film to the next (typical): 2% is a good print, 5% or more old film.";
    string widget_type = "slider";
    string suffix = " %";
    float minimum = 0.0;
    float maximum = 15.0;
    float step = 0.1;
> = 3.5;
uniform float Lamp_Flicker<
    string label = "Lamp Flicker";
    string group = "Flicker";
    string tooltip = "How much the projector's lamp wavers, smoothly, a few times a second.";
    string widget_type = "slider";
    string suffix = " %";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.5;
uniform float Dark_Frames<
    string label = "Dark Frames";
    string group = "Flicker";
    string show = "more";
    string tooltip = "How many single frames a minute come out dark: dirt, a splice, an underexposed frame.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 60.0;
    float step = 0.5;
> = 4.0;
uniform int Dark_Frame_Depth<
    string label = "Dark Frame Depth";
    string group = "Flicker";
    string show = "more";
    string tooltip = "How much darker a dark frame is.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 50;
    int step = 1;
> = 15;
uniform float Uneven_Illumination<
    string label = "Uneven Illumination";
    string group = "Flicker";
    string show = "more";
    string tooltip = "How much brighter one side, or the middle, of the picture is than the rest, moving from frame to frame: the lamp's, unlike the lens's steady Corner Falloff.";
    string widget_type = "slider";
    string suffix = " %";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 1.5;
uniform float Lamp_Brightness<
    string label = "Lamp Brightness";
    string group = "Flicker";
    string show = "more";
    string tooltip = "The picture's average brightness. At 100 white can only flicker darker; at 90 or so it flickers both ways.";
    string widget_type = "slider";
    string suffix = " %";
    float minimum = 50.0;
    float maximum = 100.0;
    float step = 0.5;
> = 100.0;
uniform bool Gate_On<
    string label = "Frame Edge";
    string widget_type = "section";
    string group = "Frame Edge";
    string tooltip = "The projected frame's edge (the projector's gate): slightly in from the picture's edges, with round corners and a soft edge, so a full-frame picture doesn't look like an office projector's. Outside it is transparent (black on a projector).";
> = true;
uniform float Corner_Radius<
    string label = "Corner Radius";
    string group = "Frame Edge";
    string tooltip = "How round the frame's corners are, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 30.0;
uniform float Inset<
    string label = "Inset";
    string group = "Frame Edge";
    string tooltip = "How far in from the picture's edges the frame's edge sits, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.5;
> = 6.0;
uniform float Gate_Softness<
    string label = "Edge Softness";
    string group = "Frame Edge";
    string show = "more";
    string tooltip = "How soft the frame's edge is, in pixels on a 1080-line picture (the gate is a little out of focus).";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 0.0;
    float maximum = 40.0;
    float step = 0.5;
> = 8.0;

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

// The frame of film on screen: Speed frames a second, wavering when hand
// cranked (by at most Hand_Cranking percent, from two slow waves, so the film
// never runs backwards). Weave, flicker and the film's grain and dust all
// step on it.
float projector_frame(float a)
{
    float seed = rand_instance_f * 61.0;
    float h = Weave_On ? Hand_Cranking * 0.01 * a : 0.0;
    float w1 = 6.2831853 * 0.23;
    float w2 = 6.2831853 * 0.61;
    float t = elapsed_time;
    float crank = h * (0.6 * (cos(seed * 0.71) - cos(w1 * t + seed * 0.71)) / w1 + 0.4 * (cos(seed * 1.37) - cos(w2 * t + seed * 1.37)) / w2);
    return floor(float(Speed) * (t + crank));
}

// How far the picture has moved in the gate on this frame, in uv: side to
// side mostly a wander over about half a second, up and down mostly new each
// frame.
float2 projector_weave(float frame, float a)
{
    if (!Weave_On)
        return float2(0.0, 0.0);
    float seed = rand_instance_f * 61.0;
    float wander = float(Speed) * 0.5;
    float x = Weave * a * (0.45 * projector_gauss(frame, seed + 21.0) + 0.89 * projector_smooth(frame / wander, seed + 22.0));
    float y = Jump * a * (0.8 * projector_gauss(frame, seed + 23.0) + 0.6 * projector_smooth(frame / 4.0, seed + 24.0));
    return float2(x, y) * uv_pixel_interval / (uv_pixel_interval.y * 1080.0);
}

// The lamp and the film's density on this frame, at uv: what the picture's
// light is multiplied by.
float projector_light(float2 uv, float frame, float a)
{
    if (!Flicker_On)
        return 1.0;
    float seed = rand_instance_f * 61.0;
    float tl = fmod(elapsed_time, 9973.0);
    float lamp = (projector_smooth(tl * 3.1, seed + 1.0) + 0.5 * projector_smooth(tl * 7.3, seed + 2.0)) / 1.118;
    float gain = Lamp_Flicker * 0.01 * lamp;
    gain += Exposure_Flicker * 0.01 * (0.8 * projector_gauss(frame, seed + 3.0) + 0.6 * projector_smooth(frame / 6.0, seed + 4.0));
    float3 b = projector_hash(float3(fmod(frame, 9973.0), seed + 5.0, 7.0));
    if (b.x < Dark_Frames / (60.0 * float(Speed)))
        gain -= float(Dark_Frame_Depth) * 0.01 * (0.75 + 0.5 * b.y);
    float3 r = projector_hash(float3(fmod(frame, 9973.0), seed + 6.0, 11.0));
    float angle = r.x * 6.2831853;
    float2 dd = uv - 0.5;
    float side = dot(dd, float2(cos(angle), sin(angle))) * 2.0;
    float middle = 0.5 - 2.0 * dot(dd, dd);
    gain += Uneven_Illumination * 0.0245 * ((r.y - 0.5) * side * 2.0 + (r.z - 0.5) * middle * 2.0);
    float lamp_level = lerp(1.0, Lamp_Brightness * 0.01, min(a, 1.0));
    return lamp_level * max(1.0 + gain * a, 0.0);
}

// How much of the picture the gate lets through at uv (the frame's own,
// unmoved coordinates): a rounded rectangle, its edge softened.
float projector_gate(float2 uv, float a)
{
    if (!Gate_On)
        return 1.0;
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 p = (uv - 0.5) * float2(1080.0 * aspect, 1080.0);
    float2 half_size = max(float2(540.0 * aspect, 540.0) - Inset * a, 1.0);
    float rr = min(Corner_Radius * a, min(half_size.x, half_size.y));
    float2 q = abs(p) - (half_size - rr);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
    float s = max(Gate_Softness * a, 0.001);
    return 1.0 - smoothstep(-0.5 * s, 0.5 * s, d);
}
