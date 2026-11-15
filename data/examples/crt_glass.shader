// CRT Glass for obs-shaderfilter: the thick glass face of a picture tube.
// Light from the phosphors scatters in the glass, so everything bright has a
// soft, faint glow round it in its own colour (more noticeable the darker
// the room). And the picture has the tube's shape: rounded corners, and a
// little dimmer towards the edges and corners, where the beam lands at a
// slant and the glass is thicker.
//
// Glow is the share of light the glass spreads out, in percent, over Glow
// Size (how far it reaches, in percent of the picture's height); it's added
// as light (linear), neutral, with no threshold, so dim parts glow faintly
// too. Corner Radius is in pixels on a 1080-line picture, and
// Edge Falloff is the share of light lost in the corners. Outside the
// rounded corners is transparent; black stays black. It goes last in a CRT
// look, after CRT Mask.

uniform float Glow<
    string label = "Glow";
    string tooltip = "How much of the light the glass spreads into a soft glow, in percent. 1 to 3 for a TV in a dark room; more is dreamier.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.1;
> = 1.5;
uniform float Glow_Size<
    string label = "Glow Size";
    string tooltip = "How far the glow reaches, in percent of the picture's height (where it has faded out). In a TV's glass, about 4 to 6: light reflected inside the thick faceplate.";
    string widget_type = "slider";
    float minimum = 0.5;
    float maximum = 20.0;
    float step = 0.1;
> = 4.0;
uniform float Corner_Radius<
    string label = "Corner Radius";
    string tooltip = "How rounded the picture's corners are, in pixels on a 1080-line picture. 0 for square; 30 to 60 for a TV's tube.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 40.0;
uniform float Edge_Falloff<
    string label = "Edge Falloff";
    string tooltip = "How much light is lost in the corners, in percent: none in the middle, falling off smoothly towards the edges.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 80.0;
    float step = 1.0;
> = 10.0;

// The sRGB curve, both ways, carried on above 1.
float3 glass_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 glass_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float3 lit = glass_to_linear(c.rgb) * c.a;
    float cover = c.a;

    // The glow: a Gaussian blur of the light from 32 points on a spiral out
    // to 3 standard deviations, each the last turned by the golden angle,
    // the spiral turned differently at each pixel so its gaps come out as an
    // even fine noise. Glow percent of the light moves into it.
    float g = Glow * 0.01;
    if (g > 0.0) {
        float sigma = Glow_Size * 0.01 / 3.0;
        float2 reach = sigma * 3.0 * float2(uv_pixel_interval.x / uv_pixel_interval.y, 1.0);
        float2 pxy = v_in.uv / uv_pixel_interval;
        float turn = 6.2831853 * frac(52.9829189 * frac(dot(pxy, float2(0.06711056, 0.00583715))));
        float2 dir = float2(cos(turn), sin(turn));
        float3 sum = float3(0.0, 0.0, 0.0);
        float sum_a = 0.0;
        float total = 0.0;
        float step_w = exp(-4.5 / 32.0);
        float w = sqrt(step_w);
        for (int i = 0; i < 32; i++) {
            float4 s = image.Sample(textureSampler, v_in.uv + dir * reach * sqrt((float(i) + 0.5) / 32.0));
            // (The sRGB curve by a close cubic, within 0.002: it's only the glow.)
            sum += w * s.rgb * (s.rgb * (s.rgb * 0.305306011 + 0.682171111) + 0.012522878) * s.a;
            sum_a += w * s.a;
            total += w;
            dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
            w *= step_w;
        }
        lit = lit * (1.0 - g) + sum / total * g;
        cover = cover * (1.0 - g) + sum_a / total * g;
    }

    // The tube's shape: rounded corners (soft over a pixel), and light
    // falling off towards the corners by the cos^4 law.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float k = (1.0 / sqrt(1.0 - min(Edge_Falloff, 99.0) * 0.01) - 1.0) / ((aspect * aspect + 1.0) * 0.25);
    float q = 1.0 + k * dot(d, d);
    lit /= q * q;
    float r = Corner_Radius / 1080.0;
    float2 half_size = float2(aspect * 0.5, 0.5);
    float2 e = max(abs(d) - (half_size - r), 0.0);
    float inside = saturate(0.5 - (length(e) - r) / uv_pixel_interval.y);
    lit *= inside;
    cover *= inside;

    if (cover <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(glass_from_linear(lit / cover), saturate(cover));
}
