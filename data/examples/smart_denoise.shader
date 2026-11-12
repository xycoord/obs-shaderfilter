// Smart DeNoise By Michele Morrone (https://github.com/BrutPitt/glslSmartDeNoise)
// Converted to OBS version of HLSL by Euiko on February 10, 2025

#define INV_SQRT_OF_2PI 0.39894228040143267793994605993439  // 1.0/SQRT_OF_2PI
#define INV_PI          0.31830988618379067153776752674503
#ifndef SD_CUTOFF
#define SD_CUTOFF 4.0
#endif

uniform float uSigma<
    string label = "Sigma";
    string widget_type = "slider";
    float minimum = 0.01;
    float maximum = 3;  // max based on the webgl sample, which is 3 
    float step = 0.01;
> = 5.0;  // default value based on shadertoy
uniform float uKSigma<
    string label = "K-Sigma";
    string widget_type = "slider";
    float minimum = 0.01;
    float maximum = 24; // max based on the webgl sample, which is 24 
    float step = 0.01;
> = 7.0;  // the default value is based on the webgl sample
uniform float uThreshold<
    string label = "Edge Threshold";
    string widget_type = "slider";
    float minimum = 0.01;
    float maximum = 2;  // max based on the webgl sample, which is 2
    float step = 0.01;
> = 0.190;  // the default value is based on the webgl sample

//  smartDeNoise - parameters
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//  float2 uv         - actual fragment coord
//  float2 size       - window size
//  float sigma  >  0 - sigma Standard Deviation
//  float kSigma >= 0 - sigma coefficient 
//      kSigma * sigma  -->  radius of the circular kernel
//  float threshold   - edge sharpening threshold 
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// NOTE: image's texture2d data will be supplied by the OBS shaderfilter by default
float4 smartDeNoise(float2 uv, float2 size, float sigma, float kSigma, float threshold)
{
    // Pixels further than SD_CUTOFF sigmas from the centre get a spatial weight
    // below exp(-SD_CUTOFF^2 / 2) and can't change the result visibly, so the
    // kernel stops there even when K-Sigma asks for a wider one.
    float radius = round(min(kSigma, SD_CUTOFF) * sigma);
    float radQ = radius * radius;

    // The normalising constants of both Gaussians cancel in aBuff / zBuff.
    float invSigmaQx2 = 0.5 / (sigma * sigma);
    float invThresholdSqx2 = 0.5 / (threshold * threshold);
    float2 texel = 1.0 / size;

    float4 centrPx = image.Sample(textureSampler, uv);

    float zBuff = 0.0;
    float4 aBuff = float4(0.0, 0.0, 0.0, 0.0);

    float2 d;
    for (d.x = -radius; d.x <= radius; d.x += 1.0)
    {
        float pt = sqrt(radQ - (d.x * d.x));  // pt = yRadius: have circular trend
        d.y = -pt;
        for (; d.y <= pt; d.y += 1.0)
        {
            float4 walkPx = image.Sample(textureSampler, uv + d * texel);
            float4 dC = walkPx - centrPx;
            float deltaFactor = exp(-dot(d, d) * invSigmaQx2 - dot(dC.xyz, dC.xyz) * invThresholdSqx2);
            zBuff += deltaFactor;
            aBuff += walkPx * deltaFactor;
        }
    }
    return aBuff / zBuff;
}

float4 mainImage(VertData v_in) : TARGET
{
    return smartDeNoise(v_in.uv, uv_size, uSigma, uKSigma, uThreshold);
}
