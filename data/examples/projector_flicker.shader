// Projector Flicker for obs-shaderfilter: the unsteady brightness of a film
// projected on a screen. Made to go with Film Grain: put it after Film Grain
// (the grain is in the film, and the lamp lights all of it), and give both the
// same Speed so grain and flicker change at the same rate.
//
// Four things make it up, each its own slider:
//   - each frame of film is exposed and developed a little differently, so
//     brightness steps from frame to frame (part random, part a slow drift);
//   - the projector's lamp wavers smoothly, a few times a second;
//   - now and then a frame is clearly darker (dirt, a splice) or brighter;
//   - the light isn't even across the picture, and which side is brighter
//     changes from frame to frame.
// And for really old film: the speed wavering as film was cranked by hand.
// Brightness is multiplied, as a lamp's would be: black stays black, and
// nothing is clipped, so HDR highlights survive. It only reads the pixel it
// draws, so the plugin can merge it into a neighbouring shader filter's pass.

uniform float Amount<
    string label = "Amount";
    string tooltip = "How much the brightness changes from one frame of film to the next.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 30.0;
uniform float Lamp<
    string label = "Lamp";
    string tooltip = "A smooth wavering of the projector's lamp, a few times a second, between the frame-to-frame changes.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 20.0;
uniform float Bumps<
    string label = "Bumps";
    string tooltip = "How often a single frame comes out clearly darker (dirt, a splice) or now and then brighter. 0 never; 100 about once a second at 24 frames a second.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 10.0;
uniform float Unevenness<
    string label = "Unevenness";
    string tooltip = "How much the flicker varies across the picture: one side or the middle a little brighter, changing each frame.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 25.0;
uniform int Speed<
    string label = "Speed";
    string tooltip = "Frames of film a second: the brightness steps this often. 24 for sound film, 16 to 18 for silent film and Super 8. Use the same as Film Grain's Speed. 0 leaves only the lamp.";
    string widget_type = "slider";
    int minimum = 0;
    int maximum = 60;
    int step = 1;
> = 24;

uniform float Hand_Cranked<
    string label = "Hand Cranked";
    string tooltip = "How much the speed wavers, as film did when cranked by hand (until about 1915): frames come a little faster, then slower. At 100 it wavers by up to 30%.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 0.0;
// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 flicker_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Roughly Gaussian, mean 0 and standard deviation 1: three uniform numbers, rescaled.
float flicker_gauss(float x, float seed)
{
    float3 u = flicker_hash(float3(x, seed, seed * 0.37 + 5.0));
    return (u.x + u.y + u.z - 1.5) * 2.0;
}

// Smooth noise along one dimension, standard deviation about 1: Gaussian
// values at whole numbers, blended smoothly (and rescaled so the blend between
// them isn't weaker than the values themselves).
float flicker_smooth(float x, float seed)
{
    float i = floor(x);
    float f = x - i;
    float u = f * f * (3.0 - 2.0 * f);
    float v = lerp(flicker_gauss(i, seed), flicker_gauss(i + 1.0, seed), u);
    return v / sqrt((1.0 - u) * (1.0 - u) + u * u);
}

// Hand cranking: how far ahead of (or behind) steady running the film is at
// time t, in seconds. The speed varies with two slow waves at unrelated rates,
// by at most 30%, so the film never runs backwards.
float flicker_crank(float t, float seed)
{
    float h = Hand_Cranked * 0.003;
    float w1 = 6.2831853 * 0.23;
    float w2 = 6.2831853 * 0.61;
    float p1 = seed * 0.71;
    float p2 = seed * 1.37;
    return h * (0.6 * (cos(p1) - cos(w1 * t + p1)) / w1 + 0.4 * (cos(p2) - cos(w2 * t + p2)) / w2);
}

// Where the film is at time t, in frames: Speed frames a second, wavering
// when cranked by hand. With Hand_Cranked at 0 this counts frames exactly as
// Film Grain does.
float flicker_film_position(float t, float seed)
{
    return float(Speed) * (t + flicker_crank(t, seed));
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float seed = rand_instance_f * 61.0;

    // The lamp: two octaves of smooth noise, about 3 and 7 times a second.
    float t = fmod(elapsed_time, 9973.0);
    float lamp = (flicker_smooth(t * 3.1, seed + 1.0) + 0.5 * flicker_smooth(t * 7.3, seed + 2.0)) / 1.118;
    float gain = Lamp * 0.0012 * lamp;

    if (Speed > 0) {
        // Frames counted as Film Grain counts them (unless hand cranked); the
        // sequence repeats only after 9973 frames (7 minutes at 24), small
        // enough for the hash.
        float position = flicker_film_position(elapsed_time, seed);
        float frame = fmod(floor(position), 9973.0);

        // From frame to frame: mostly new each frame, partly a drift over
        // about six frames, as density changes along a print.
        float jump = flicker_gauss(frame, seed + 3.0);
        float drift = flicker_smooth(frame / 6.0, seed + 4.0);
        gain += Amount * 0.0012 * (0.8 * jump + 0.6 * drift);

        // A bump: about Bumps / 2400 of frames (once a second at 100 and
        // 24 frames a second); three in four darker, by 15 to 35%.
        float3 b = flicker_hash(float3(frame, seed + 5.0, 7.0));
        if (b.x < Bumps / 2400.0)
            gain += (b.y < 0.75 ? -1.0 : 0.6) * (0.15 + 0.2 * b.z);

        // Uneven light: brighter towards one side, at an angle that changes
        // each frame, and a centre brighter or dimmer than the edges.
        float3 r = flicker_hash(float3(frame, seed + 6.0, 11.0));
        float angle = r.x * 6.2831853;
        float2 d = v_in.uv - 0.5;
        float side = dot(d, float2(cos(angle), sin(angle))) * 2.0;
        float middle = 0.5 - 2.0 * dot(d, d);
        float uneven = (r.y - 0.5) * side * 2.0 + (r.z - 0.5) * middle * 2.0;
        gain += Unevenness * 0.0015 * uneven;
    }

    // Brightness multiplied, as a lamp's: black stays black, nothing clipped.
    c.rgb *= max(1.0 + gain, 0.0);
    return c;
}
