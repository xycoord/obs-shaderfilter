// The halo of Halation, Film and Film Look, drawn small. The halo is a wide,
// soft blur (13 pixels or more on a 1080-line picture), and blurring it at
// full size took 64 samples a pixel. Here the light above the threshold is
// averaged into a picture a quarter the size each way (stage 1), blurred
// across (stage 2) and down (stage 3) there, and read back, smoothly, at
// full size: a few samples a pixel, and an exact Gaussian rather than a
// sampled one. A host that draws only mainImage (an older version of the
// plugin) leaves stages_drawn false, and the halo is drawn the old way.
//
// The including shader defines HALO_SIZE and HALO_THRESHOLD (its settings'
// names) and HALO_ON, and has its stages 1 to 3 return halo_down(),
// halo_blur(..., float2(1, 0)) and halo_blur(..., float2(0, 1)).

#define STAGE1_SCALE 4
#define STAGE2_SCALE 4
#define STAGE3_SCALE 4

uniform texture2d source_image;
uniform texture2d stage3_image;
uniform bool stages_drawn;

// The threshold, set as an everyday brightness, in linear light.
float halo_threshold()
{
    float t = float(HALO_THRESHOLD) * 0.01;
    return t <= 0.04045 ? t / 12.92 : pow((t + 0.055) / 1.055, 2.4);
}

// A sample's light above the threshold (the sRGB curve as a close cubic,
// within 0.002), with its transparency.
float halo_light(float4 s, float t)
{
    float3 lin = s.rgb * (s.rgb * (s.rgb * 0.305306011 + 0.682171111) + 0.012522878);
    return s.a * max(dot(lin, float3(0.2126, 0.7152, 0.0722)) - t, 0.0);
}

// The halo's standard deviation, in the source's own pixels. Size is 1.645
// of them: there, the halo outside a straight bright edge has faded to a
// tenth of its brightness at the edge.
float halo_sigma()
{
    return max(float(HALO_SIZE), 1.0) / 1.645 / (uv_pixel_interval.y * 1080.0);
}

// Whether the halo is drawn small: stages are drawn, and it's wide enough
// (a narrow one, under 4 pixels, isn't smooth at a quarter of the size).
bool halo_small()
{
    return stages_drawn && halo_sigma() >= 4.0;
}

// The picture the shader works on: the filter's input, whichever pass this is.
float4 halo_source(float2 uv)
{
    return stages_drawn ? source_image.Sample(textureSampler, uv) : image.Sample(textureSampler, uv);
}

// Stage 1: the light above the threshold averaged over the 4 by 4 pixels
// round each pixel of the small picture, from four samples each between 2 by
// 2 pixels (thresholded after that blending, as the full-size halo's samples
// between pixels were, so fine bright detail glows as it did).
float4 halo_down(float2 uv)
{
    if (!(HALO_ON) || !halo_small())
        return float4(0.0, 0.0, 0.0, 1.0);
    float t = halo_threshold();
    float sum = 0.0;
    for (int j = 0; j < 2; j++)
        for (int i = 0; i < 2; i++)
            sum += halo_light(image.Sample(textureSampler, uv + (float2(float(i), float(j)) * 2.0 - 1.0) * uv_pixel_interval), t);
    return float4(sum / 4.0, 0.0, 0.0, 1.0);
}

// Stages 2 and 3: a Gaussian along one axis of the small picture, out to 3.2
// standard deviations (as the full-size halo was). The averaging into the
// small picture and the smooth reading back out of it blur a little
// themselves (a variance of about 4 pixels squared), which this leaves out.
float4 halo_blur(float2 uv, float2 axis)
{
    if (!(HALO_ON) || !halo_small())
        return float4(0.0, 0.0, 0.0, 1.0);
    float sigma = halo_sigma();
    float s = sqrt(max(sigma * sigma - 3.9, 1.0)) / 4.0;
    int r = int(ceil(3.2 * s));
    float2 step_uv = axis * uv_pixel_interval * 4.0;
    float k = -0.5 / (s * s);
    float sum = 0.0;
    float total = 0.0;
    for (int i = -r; i <= r; i++) {
        float w = exp(k * float(i * i));
        sum += w * image.Sample(textureSampler, uv + float(i) * step_uv).r;
        total += w;
    }
    return float4(sum / total, 0.0, 0.0, 1.0);
}

// The halo at uv, as the mean light above the threshold round it: from the
// small picture, or (no stages, or a narrow halo) from 64 points on a spiral
// out to 3.2 standard deviations, turned differently at each pixel so the
// gaps between them come out as an even fine noise; each point the last
// turned by the golden angle, its weight the last times a constant.
float halo_at(float2 uv, float t, float turn)
{
    if (halo_small())
        return stage3_image.Sample(textureSampler, uv).r;
    float2 reach = halo_sigma() * 3.2 * uv_pixel_interval;
    float2 dir = float2(cos(turn), sin(turn));
    float w = 0.96078944;
    float glow = 0.0;
    for (int i = 0; i < 64; i++) {
        glow += w * halo_light(halo_source(uv + dir * reach * sqrt((float(i) + 0.5) / 64.0)), t);
        dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
        w *= 0.92311635;
    }
    // (12.421987 is the sum of the weights.)
    return glow / 12.421987;
}
