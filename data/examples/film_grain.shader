// Film Grain for obs-shaderfilter.
// Gaussian-distributed grain, smoothly interpolated between grain centres and
// strongest in the midtones, as on film. Like film grain it belongs to the
// frame: its size is given for a 1080-line picture and scales with the
// source, so a small source scaled up in a scene doesn't get coarse grain.
// It only reads the pixel it draws, so the plugin can merge it into a
// neighbouring shader filter's pass.

uniform float Amount<
    string label = "Amount";
    string tooltip = "How strong the grain is.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 30.0;
uniform float Grain_Size<
    string label = "Grain Size";
    string tooltip = "Size of a grain, in pixels of a 1080-line picture. Grain belongs to the frame, so it scales with the source: twice as many pixels across at 4K, finer on smaller sources.";
    string widget_type = "slider";
    float minimum = 1.0;
    float maximum = 6.0;
    float step = 0.05;
> = 1.5;
uniform float Color_Amount<
    string label = "Color";
    string tooltip = "0 gives black-and-white grain, as on most film; 100 gives each color channel its own grain.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 0.0;
uniform float Shadows<
    string label = "Shadows";
    string tooltip = "Grain strength in the darkest parts, compared with the midtones (100).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 60.0;
uniform float Highlights<
    string label = "Highlights";
    string tooltip = "Grain strength in the brightest parts, compared with the midtones (100).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 25.0;
uniform int Speed<
    string label = "Speed";
    string tooltip = "How many times a second the grain changes. 24 looks like film; 0 freezes it.";
    string widget_type = "slider";
    int minimum = 0;
    int maximum = 60;
    int step = 1;
> = 24;

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 grain_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Roughly Gaussian noise with mean 0 and standard deviation 1 for each channel
// at a grain centre: the sum of three uniform numbers, rescaled.
float3 grain_at(float2 cell, float seed)
{
    float3 sum = grain_hash(float3(cell, seed))
               + grain_hash(float3(cell, seed + 17.0))
               + grain_hash(float3(cell, seed + 43.0));
    return (sum - 1.5) * 2.0;
}

// One layer of grain at grid position p: the four nearest centres blended
// smoothly, keeping the spread the same everywhere (a plain blend would be
// weaker between centres than on them).
float3 grain_layer(float2 p, float seed)
{
    float2 cell = floor(p);
    float2 f = p - cell;
    float2 u = f * f * (3.0 - 2.0 * f);
    float4 w = float4((1.0 - u.x) * (1.0 - u.y), u.x * (1.0 - u.y), (1.0 - u.x) * u.y, u.x * u.y);
    float3 n = w.x * grain_at(cell, seed)
             + w.y * grain_at(cell + float2(1.0, 0.0), seed)
             + w.z * grain_at(cell + float2(0.0, 1.0), seed)
             + w.w * grain_at(cell + float2(1.0, 1.0), seed);
    return n / sqrt(dot(w, w));
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);

    // A new pattern Speed times a second; the sequence repeats only after
    // 9973 patterns (7 minutes at 24), small enough for the hash to stay precise.
    float frame = Speed > 0 ? floor(elapsed_time * float(Speed)) : 0.0;
    float seed = fmod(frame, 9973.0) * 1.618 + rand_instance_f * 61.0;

    // Grain size in this source's pixels. Grains smaller than a pixel would
    // average out within it: use one per pixel, weakened to match.
    float cell_px = Grain_Size * uv_size.y / 1080.0;
    float fine = min(cell_px, 1.0);
    cell_px = max(cell_px, 1.0);

    // Grain centres sit every cell_px pixels; at 1, one per pixel. Large grain
    // would show the grid they sit on, so from 2 px a second layer on a grid
    // turned against the first fades in (fully from 3 px); below that it
    // isn't needed and isn't computed.
    float2 p = (v_in.uv * uv_size - 0.5) / cell_px;
    float3 n = grain_layer(p, seed);
    float second = saturate(cell_px - 2.0);
    if (second > 0.0) {
        float2 q = float2(0.8660 * p.x - 0.5 * p.y, 0.5 * p.x + 0.8660 * p.y) + 0.37;
        n = (n + second * grain_layer(q, seed + 101.0)) / sqrt(1.0 + second * second);
    }

    // Black-and-white grain uses the first channel's noise for all three.
    float3 grain = lerp(n.xxx, n, Color_Amount * 0.01);

    // Film grain shows most in the midtones.
    float luma = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    float response = luma < 0.5 ? lerp(Shadows * 0.01, 1.0, smoothstep(0.0, 0.5, luma))
                                : lerp(1.0, Highlights * 0.01, smoothstep(0.5, 1.0, luma));

    // Kept above 0 but not clipped at 1, so HDR highlights survive.
    c.rgb = max(c.rgb + grain * (Amount * 0.0015 * response * fine), 0.0);
    return c;
}
