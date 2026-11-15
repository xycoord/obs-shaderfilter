// Gate Weave for obs-shaderfilter: the picture not sitting quite still, as
// film doesn't in a projector. The film is pulled down a frame at a time and
// held in the gate while it's shown, but no frame lands in exactly the same
// place: it jumps a little up or down (the claw and the sprocket holes are
// never perfect) and floats from side to side between the gate's edge guides
// (weave). The whole picture moves together, once each frame of film, and
// drifts slowly as well.
//
// Distances are in pixels on a 1080-line picture (scaled for other sizes), as
// typical deviations: 1 means about a pixel either way. A good 35mm cinema
// projector holds the picture within a pixel or so; 16mm and Super 8 less
// well; film from before about 1910, shot in cameras without registration
// pins, jumps several pixels.
//
// It goes after Film Grain, so the grain moves with the picture (it's in the
// film), and before Projector Flicker, whose uneven light stays put on the
// screen. Give it the same Speed as both. The picture's edges stay where they
// are: what moves in is transparent, as at the edge of a logo.

uniform float Weave<
    string label = "Weave";
    string tooltip = "How far the picture floats from side to side (in pixels on a 1080-line picture, typical). It wanders over about half a second, with a little jitter each frame.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 0.8;
uniform float Jump<
    string label = "Jump";
    string tooltip = "How far the picture jumps up or down from one frame to the next (in pixels on a 1080-line picture, typical). Worn or damaged sprocket holes make it worse.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 0.6;
uniform int Speed<
    string label = "Speed";
    string tooltip = "Frames of film a second: the picture moves this often. 24 for sound film, 16 to 18 for silent film and Super 8. Use the same as Film Grain's and Projector Flicker's Speed.";
    string widget_type = "slider";
    int minimum = 1;
    int maximum = 60;
    int step = 1;
> = 24;

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 weave_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Roughly Gaussian, mean 0 and standard deviation 1: three uniform numbers, rescaled.
float weave_gauss(float x, float seed)
{
    float3 u = weave_hash(float3(x, seed, seed * 0.37 + 5.0));
    return (u.x + u.y + u.z - 1.5) * 2.0;
}

// Smooth noise along one dimension, standard deviation about 1.
float weave_smooth(float x, float seed)
{
    float i = floor(x);
    float f = x - i;
    float u = f * f * (3.0 - 2.0 * f);
    float v = lerp(weave_gauss(i, seed), weave_gauss(i + 1.0, seed), u);
    return v / sqrt((1.0 - u) * (1.0 - u) + u * u);
}

float4 mainImage(VertData v_in) : TARGET
{
    float seed = rand_instance_f * 61.0;

    // The frame of film in the gate, counted as Film Grain and Projector
    // Flicker count them. The sequence repeats after 9973 frames.
    float frame = fmod(floor(elapsed_time * float(Speed)), 9973.0);

    // Side to side: mostly a wander over about half a second of frames, a
    // little new each frame. Up and down: mostly new each frame, a little
    // drift over a few frames. (Each pair is scaled to the set deviation.)
    float wander = float(Speed) * 0.5;
    float x = Weave * (0.45 * weave_gauss(frame, seed + 1.0) + 0.89 * weave_smooth(frame / wander, seed + 2.0));
    float y = Jump * (0.8 * weave_gauss(frame, seed + 3.0) + 0.6 * weave_smooth(frame / 4.0, seed + 4.0));

    float2 uv = v_in.uv - float2(x, y) * (uv_size.y / 1080.0) * uv_pixel_interval;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return image.Sample(textureSampler, uv);
}
