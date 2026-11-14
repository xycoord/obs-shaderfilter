// Projector Flicker for obs-shaderfilter: the unsteady brightness of a film
// projected on a screen. Made to go with Film Grain: put it after Film Grain
// (the grain is in the film, and the lamp lights all of it), and give both the
// same frame rate (Film Grain's Speed) so grain and flicker change at the same
// rate. Each filter counts time from when it was created, so their frames
// aren't in step with each other, and with hand cranking the flicker's frames
// waver while the grain's don't.
//
// What it's made of, each its own setting, in percent of brightness where
// that applies (a typical deviation, so 4% means about 4% brighter or darker):
//   - exposure flicker: each frame of film is exposed, developed and printed a
//     little differently, so its density, and the brightness on the screen,
//     steps from frame to frame (part random, part a slow drift along the
//     print). This is what restorers call flicker;
//   - lamp flicker: the projector's arc lamp wavers smoothly, a few times a
//     second;
//   - dark frames: now and then a single frame comes out dark (dirt, a splice,
//     an underexposed frame);
//   - uneven illumination: the light isn't even across the screen, and the
//     brighter side moves from frame to frame;
//   - hand cranking: film cranked by hand (until about 1915) didn't run at a
//     steady frame rate.
// Brightness is multiplied, as a lamp's would be: black stays black, and
// nothing is clipped, so HDR highlights survive. White can't get brighter,
// though: lower Lamp Brightness a little to let it flicker upwards too. It
// only reads the pixel it draws, so the plugin can merge it into a
// neighbouring shader filter's pass.

uniform float Exposure_Flicker<
    string label = "Exposure Flicker";
    string tooltip = "How much brightness changes from one frame of film to the next, as each frame's density differs a little (in percent: about this much brighter or darker). 2% is a good print; 5% or more is old or badly printed film.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 15.0;
    float step = 0.1;
> = 3.0;
uniform float Lamp_Flicker<
    string label = "Lamp Flicker";
    string tooltip = "How much the projector's lamp wavers, smoothly, a few times a second (in percent). Carbon arc lamps, in cinemas until the 1970s, wavered most; a modern xenon lamp is steady.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.0;
uniform float Dark_Frames<
    string label = "Dark Frames";
    string tooltip = "How many single frames a minute come out dark: dirt, a splice, an underexposed frame. 0 for none.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 60.0;
    float step = 0.5;
> = 4.0;
uniform float Dark_Frame_Depth<
    string label = "Dark Frame Depth";
    string tooltip = "How much darker a dark frame is (in percent, each one a little more or less than this).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 50.0;
    float step = 0.5;
> = 15.0;
uniform float Uneven_Illumination<
    string label = "Uneven Illumination";
    string tooltip = "How much brighter one side, or the middle, of the picture is than the rest (in percent), the brighter part moving from frame to frame.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 1.5;
uniform int Speed<
    string label = "Frame Rate";
    string tooltip = "Frames of film a second: the flicker steps this often. 24 for sound film, 16 to 18 for silent film and Super 8. Use the same as Film Grain's Speed, so grain and flicker change at the same rate. 0 leaves only the lamp flicker.";
    string widget_type = "slider";
    int minimum = 0;
    int maximum = 60;
    int step = 1;
> = 24;
uniform float Hand_Cranking<
    string label = "Hand Cranking";
    string tooltip = "How much the frame rate wavers (in percent), as it did when film was cranked by hand, until about 1915: frames come a little faster, then slower. 0 is a motor-driven projector.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 0.0;
uniform float Lamp_Brightness<
    string label = "Lamp Brightness";
    string tooltip = "The picture's average brightness, in percent. White can't get any brighter, so at 100 the flicker only shows on white as dips; at 90 or so it can flicker both ways.";
    string widget_type = "slider";
    float minimum = 50.0;
    float maximum = 100.0;
    float step = 0.5;
> = 100.0;

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
// time t, in seconds. The frame rate varies with two slow waves at unrelated
// rates, by at most Hand_Cranking percent, so the film never runs backwards.
float flicker_crank(float t, float seed)
{
    float h = Hand_Cranking * 0.01;
    float w1 = 6.2831853 * 0.23;
    float w2 = 6.2831853 * 0.61;
    float p1 = seed * 0.71;
    float p2 = seed * 1.37;
    return h * (0.6 * (cos(p1) - cos(w1 * t + p1)) / w1 + 0.4 * (cos(p2) - cos(w2 * t + p2)) / w2);
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float seed = rand_instance_f * 61.0;

    // Lamp flicker: two octaves of smooth noise, about 3 and 7 times a second.
    float t = fmod(elapsed_time, 9973.0);
    float lamp = (flicker_smooth(t * 3.1, seed + 1.0) + 0.5 * flicker_smooth(t * 7.3, seed + 2.0)) / 1.118;
    float gain = Lamp_Flicker * 0.01 * lamp;

    if (Speed > 0) {
        // The frame of film on screen: Speed frames a second, wavering when
        // hand cranked (without, counted exactly as Film Grain counts them).
        // The sequence repeats only after 9973 frames (7 minutes at 24),
        // small enough for the hash.
        float position = float(Speed) * (elapsed_time + flicker_crank(elapsed_time, seed));
        float frame = fmod(floor(position), 9973.0);

        // Exposure flicker: mostly new each frame, partly a drift over about
        // six frames, as density changes along a print (the two scaled so the
        // total has the set standard deviation).
        float jump = flicker_gauss(frame, seed + 3.0);
        float drift = flicker_smooth(frame / 6.0, seed + 4.0);
        gain += Exposure_Flicker * 0.01 * (0.8 * jump + 0.6 * drift);

        // A dark frame: Dark_Frames a minute on average, each 75% to 125% of
        // the set depth.
        float3 b = flicker_hash(float3(frame, seed + 5.0, 7.0));
        if (b.x < Dark_Frames / (60.0 * float(Speed)))
            gain -= Dark_Frame_Depth * 0.01 * (0.75 + 0.5 * b.y);

        // Uneven illumination: brighter towards one side, at an angle that
        // changes each frame, and a middle brighter or dimmer than the edges
        // (scaled so the left and right halves of the picture differ by the
        // set amount, as a standard deviation over frames).
        float3 r = flicker_hash(float3(frame, seed + 6.0, 11.0));
        float angle = r.x * 6.2831853;
        float2 d = v_in.uv - 0.5;
        float side = dot(d, float2(cos(angle), sin(angle))) * 2.0;
        float middle = 0.5 - 2.0 * dot(d, d);
        float uneven = (r.y - 0.5) * side * 2.0 + (r.z - 0.5) * middle * 2.0;
        gain += Uneven_Illumination * 0.0245 * uneven;
    }

    // Brightness multiplied, as a lamp's: black stays black, nothing clipped.
    c.rgb *= Lamp_Brightness * 0.01 * max(1.0 + gain, 0.0);
    return c;
}
