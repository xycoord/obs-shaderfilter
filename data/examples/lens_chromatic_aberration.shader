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
// sizes). A real projector lens gives a pixel or two at most, which is too
// little to see on a logo in the middle of the picture (where there's none),
// so the defaults and presets are larger than life: enough to show at a
// centred logo's edges. The colours are a spread of wavelengths, mixed in
// linear light, so a fringe fades from one colour to the next and white stays
// white.
//
// It goes last in a film look (the lens is the last thing the light goes
// through). Where the source is transparent, as round a logo, the fringes are
// drawn with their own transparency.

uniform float Fringing<
    string label = "Fringing";
    string tooltip = "How far apart red and blue are at the left and right edges of the picture, in pixels on a 1080-line picture: none in the middle, more towards the edges, most in the corners. A real lens gives 1 or 2, too little to see on a centred logo; 5 shows at its edges. Negative swaps which side red and blue fall on.";
    string widget_type = "slider";
    float minimum = -20.0;
    float maximum = 20.0;
    float step = 0.1;
> = 5.0;
uniform string Full_Look<
    string label = "Switch to Film Look";
    string widget_type = "switch";
    string tooltip = "Make this filter a Film Look (the film, projector and lens in one filter), keeping these settings: the parts this filter doesn't have are set to the same Look.";
> = "film_look.shader";

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
    if (Fringing == 0.0)
        return image.Sample(textureSampler, v_in.uv);

    // Wavelengths from red (t = 0) to blue (t = 1), each a slightly different
    // size, summed per channel by how much of it that channel sees: nine, and
    // more for wider fringes (always an odd number, for the gap below), so the
    // steps between them stay about a pixel.
    int n = 9 + 2 * int(clamp(abs(Fringing) * 0.6 - 2.5, 0.0, 10.0));

    // The gap between the red and blue parts' centres in t, from the weights
    // below (green stays in the middle), so Fringing is that gap in pixels:
    // 0.71 for nine samples, towards 0.639 for many (within 0.2% for an odd
    // number of them).
    float gap = 0.63889 + 0.569 / float(n - 1);

    // Size difference between red and blue: Fringing pixels (on a 1080-line
    // picture, scaled to the source's own height) over half its width.
    float spread = Fringing / gap * 2.0 * uv_pixel_interval.x / (uv_pixel_interval.y * 1080.0);
    float2 d = v_in.uv - 0.5;

    // Samples are kept inside the picture, half a pixel in from its edges
    // (a projected frame's colours all reach its edge), unless this pixel is
    // outside it, in added space.
    float2 lo = min(v_in.uv, 0.5 * uv_pixel_interval);
    float2 hi = max(v_in.uv, 1.0 - 0.5 * uv_pixel_interval);

    float3 sum = float3(0.0, 0.0, 0.0);
    float3 cover = float3(0.0, 0.0, 0.0);
    float3 weight = float3(0.0, 0.0, 0.0);
    for (int i = 0; i < n; i++) {
        float t = float(i) / float(n - 1);
        float k = 3.0 * t - 1.5;
        float3 w = saturate(float3(-k, 1.0 - abs(k), k));
        float4 s = image.Sample(textureSampler, clamp(0.5 + d * (1.0 + spread * (0.5 - t)), lo, hi));
        sum += w * lens_ca_to_linear(s.rgb) * s.a;
        cover += w * s.a;
        weight += w;
    }
    sum /= weight;
    cover /= weight;

    // Each channel has its own coverage at a fringe; drawn as one colour at
    // the largest of them, which looks the same over black.
    float alpha = max(cover.r, max(cover.g, cover.b));
    if (alpha <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(lens_ca_from_linear(sum / alpha), alpha);
}
