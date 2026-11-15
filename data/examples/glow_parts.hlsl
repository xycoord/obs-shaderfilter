// A soft glow of the whole picture (CRT Glass, CRT TV), drawn small, as the
// halo is (see halo_parts.hlsl): the picture's light averaged into a picture
// a quarter the size each way (stage 1), blurred across (stage 2) and down
// (stage 3) there, and read back smoothly at full size, instead of 32
// samples a pixel at full size. A host that draws only mainImage leaves
// stages_drawn false, and the glow is sampled the old way.
//
// The including shader defines GLOW_SIGMA (the glow's standard deviation in
// the source's pixels) and GLOW_ON, and GLOW_SAMPLE(uv), the picture the glow
// is of (from glow_source(), below); its stages 1 to
// 3 return glow_down(), glow_blur(..., float2(1, 0)) and
// glow_blur(..., float2(0, 1)).

#define STAGE1_SCALE 4
#define STAGE2_SCALE 4
#define STAGE3_SCALE 4

uniform texture2d source_image;
uniform texture2d stage3_image;
uniform bool stages_drawn;

// The picture the shader works on: the filter's input, whichever pass this is.
float4 glow_source(float2 uv)
{
    return stages_drawn ? source_image.Sample(textureSampler, uv) : image.Sample(textureSampler, uv);
}

// A sample's light, premultiplied by its transparency (the sRGB curve by a
// close cubic, within 0.002: it's only the glow), and the transparency.
float4 glow_light(float4 s)
{
    return float4(s.rgb * (s.rgb * (s.rgb * 0.305306011 + 0.682171111) + 0.012522878) * s.a, s.a);
}

// Whether the glow is drawn small: stages are drawn, and it's wide enough.
bool glow_small()
{
    return stages_drawn && float(GLOW_SIGMA) >= 4.0;
}

// Stage 1: the light averaged over the 4 by 4 pixels round each pixel of the
// small picture, from four samples each between 2 by 2 pixels (as the
// full-size glow's samples between pixels were).
float4 glow_down(float2 uv)
{
    if (!(GLOW_ON) || !glow_small())
        return float4(0.0, 0.0, 0.0, 0.0);
    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    for (int j = 0; j < 2; j++)
        for (int i = 0; i < 2; i++)
            sum += glow_light(GLOW_SAMPLE(uv + (float2(float(i), float(j)) * 2.0 - 1.0) * uv_pixel_interval));
    return sum / 4.0;
}

// Stages 2 and 3: a Gaussian along one axis of the small picture, out to 3
// standard deviations (as the full-size glow was), less the little the
// averaging and reading back blur themselves.
float4 glow_blur(float2 uv, float2 axis)
{
    if (!(GLOW_ON) || !glow_small())
        return float4(0.0, 0.0, 0.0, 0.0);
    float sigma = float(GLOW_SIGMA);
    float s = sqrt(max(sigma * sigma - 3.9, 1.0)) / 4.0;
    int r = int(ceil(3.0 * s));
    float2 step_uv = axis * uv_pixel_interval * 4.0;
    float k = -0.5 / (s * s);
    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    float total = 0.0;
    for (int i = -r; i <= r; i++) {
        float w = exp(k * float(i * i));
        sum += w * image.SampleLevel(textureSampler, uv + float(i) * step_uv, 0.0);
        total += w;
    }
    return sum / total;
}

// The glow at uv: its light (premultiplied) and transparency, from the small
// picture, or (no stages, or a narrow glow) from 32 points on a spiral out
// to 3 standard deviations, each the last turned by the golden angle, the
// spiral turned differently at each pixel so its gaps come out as an even
// fine noise.
float4 glow_at(float2 uv)
{
    if (glow_small())
        return stage3_image.Sample(textureSampler, uv);
    float2 reach = float(GLOW_SIGMA) * 3.0 * uv_pixel_interval;
    float2 pxy = uv / uv_pixel_interval;
    float turn = 6.2831853 * frac(52.9829189 * frac(dot(pxy, float2(0.06711056, 0.00583715))));
    float2 dir = float2(cos(turn), sin(turn));
    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    float total = 0.0;
    float step_w = exp(-4.5 / 32.0);
    float w = sqrt(step_w);
    for (int i = 0; i < 32; i++) {
        sum += w * glow_light(GLOW_SAMPLE(uv + dir * reach * sqrt((float(i) + 0.5) / 32.0)));
        total += w;
        dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
        w *= step_w;
    }
    return sum / total;
}
