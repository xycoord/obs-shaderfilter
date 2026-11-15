// Lens Chromatic Aberration for obs-shaderfilter: the colour fringes a lens
// gives towards the edges of the picture. Glass bends each wavelength of light
// a little differently, so a lens makes the picture a slightly different size
// in each colour: nothing at the centre, and towards the edges red and blue
// part, leaving coloured edges on bright shapes (lateral chromatic
// aberration). A projector's lens does it to everything it projects, colour or
// black-and-white film alike.
//
// Unlike Chromatic Aberration (which bends the picture as well, by a lot, and
// adds noise) and RGB Split (which shifts colours the same everywhere), this
// does only the lens's colour fringing, in pixels: how far apart red and blue
// are at the left and right edges of a 1080-line picture (scaled for other
// sizes). A good projector lens gives under a pixel; an old or cheap one two to
// four. The colours are a spread of wavelengths, mixed in linear light, so a
// fringe fades from one colour to the next and white stays white.
//
// It goes last in a film look (the lens is the last thing the light goes
// through). Where the source is transparent, as round a logo, the fringes are
// drawn with their own transparency.

uniform float Fringing<
    string label = "Fringing";
    string tooltip = "How far apart red and blue are at the left and right edges of the picture, in pixels on a 1080-line picture: none in the middle, more towards the edges, most in the corners. Under 1 for a good projector lens, 2 to 4 for an old one. Negative swaps which side red and blue fall on.";
    string widget_type = "slider";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 1.2;

float3 lens_ca_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 lens_ca_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

float4 mainImage(VertData v_in) : TARGET
{
    // Size difference between red and blue: Fringing pixels (on a 1080-line
    // picture, scaled to the source's own height) over half its width. 1.408
    // makes it the gap between the red and blue parts' centres, from the
    // weights below; green stays where it is.
    float spread = Fringing * 1.408 * 2.0 * uv_pixel_interval.x / (uv_pixel_interval.y * 1080.0);
    if (spread == 0.0)
        return image.Sample(textureSampler, v_in.uv);
    float2 d = v_in.uv - 0.5;

    // Samples are kept inside the picture, half a pixel in from its edges
    // (a projected frame's colours all reach its edge), unless this pixel is
    // outside it, in added space.
    float2 lo = min(v_in.uv, 0.5 * uv_pixel_interval);
    float2 hi = max(v_in.uv, 1.0 - 0.5 * uv_pixel_interval);

    // Nine wavelengths from red (t = 0) to blue (t = 1), each a slightly
    // different size, summed per channel by how much of it that channel sees.
    float3 sum = float3(0.0, 0.0, 0.0);
    float3 cover = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < 9; i++) {
        float t = float(i) / 8.0;
        float k = 3.0 * t - 1.5;
        float3 w = saturate(float3(-k, 1.0 - abs(k), k));
        float4 s = image.Sample(textureSampler, clamp(0.5 + d * (1.0 + spread * (0.5 - t)), lo, hi));
        sum += w * lens_ca_to_linear(s.rgb) * s.a;
        cover += w * s.a;
    }
    // (The weights' sums per channel.)
    sum /= float3(3.125, 2.75, 3.125);
    cover /= float3(3.125, 2.75, 3.125);

    // Each channel has its own coverage at a fringe; drawn as one colour at
    // the largest of them, which looks the same over black.
    float alpha = max(cover.r, max(cover.g, cover.b));
    if (alpha <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(lens_ca_from_linear(sum / alpha), alpha);
}
