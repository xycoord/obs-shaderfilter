// CRT Geometry for obs-shaderfilter: a picture-tube television's shape and
// aim. The tube's face is curved and its scan isn't perfectly straight, so
// the picture bows outwards a little (barrel distortion), more towards the
// corners; and the three electron beams, red, green and blue, never land in
// exactly the same place, so colours separate slightly towards the edges
// (convergence error). On a well-set-up set both are small.
//
// Curvature is how far the corners are pulled in, in percent of the distance
// from the middle; Convergence is how far red and blue sit either side of
// green at the left and right edges, in pixels on a 1080-line picture
// (scaled for other sizes), none in the middle. What moves in from outside
// the picture is transparent. It goes first among the CRT filters, after any
// VHS ones, before CRT Scanlines (whose lines then follow the curve).

uniform float Curvature<
    string label = "Curvature";
    string tooltip = "How far the picture's corners are pulled in, in percent of their distance from the middle: the bow of a curved tube. 1 is a gentle bow, 3 a strong one; 0 for a flat screen. A bent logo on a flat wall soon looks like a filter, so keep it low.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 15.0;
    float step = 0.1;
> = 1.0;
uniform float Convergence<
    string label = "Convergence";
    string tooltip = "How far red and blue sit either side of green at the left and right edges, in pixels on a 1080-line picture: none in the middle. Up to 1 for a typical TV; more for an old or badly set-up one. Negative swaps red and blue.";
    string widget_type = "slider";
    float minimum = -5.0;
    float maximum = 5.0;
    float step = 0.05;
> = 0.8;

float4 mainImage(VertData v_in) : TARGET
{
    // From the middle, in units of the picture's height, and the corners'
    // distance squared.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float corner2 = (aspect * aspect + 1.0) * 0.25;

    // Barrel: sample further out the further from the middle, by a factor
    // that's 1 / (1 - Curvature) at the corners, so they come in Curvature
    // percent.
    float k = (1.0 / (1.0 - Curvature * 0.01) - 1.0) / corner2;
    float2 src = d * (1.0 + k * dot(d, d));

    // Convergence: red and blue apart from green, in proportion to the
    // distance across from the middle (Convergence pixels at the edges).
    float conv = Convergence / 1080.0 * (d.x / (aspect * 0.5));
    float2 to_uv = float2(1.0 / aspect, 1.0);
    float4 g = image.Sample(textureSampler, src * to_uv + 0.5);
    float4 r = image.Sample(textureSampler, (src - float2(conv, 0.0)) * to_uv + 0.5);
    float4 b = image.Sample(textureSampler, (src + float2(conv, 0.0)) * to_uv + 0.5);

    // Each colour from its own beam; coverage from the widest of them, so a
    // fringe past a transparent edge shows.
    float alpha = max(g.a, max(r.a, b.a));
    if (alpha <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(float3(r.r * r.a, g.g * g.a, b.b * b.a) / alpha, alpha);
}
