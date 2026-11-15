// Lens Distortion for obs-shaderfilter: a lens bending the picture's straight
// lines. With barrel distortion (positive) the picture is magnified a little
// less towards its edges, so its straight edges bow outwards and its corners
// come in; with pincushion distortion (negative) the corners go out, and are
// cut off. Projector lenses distort a little; it takes the dead-straight edges
// off a picture that fills the frame.
//
// Set as how strongly the picture bends, in percent (the corners would come
// in by this much). The picture is then enlarged so the middles of its left
// and right edges stay at the frame's edges: it still fills the frame there,
// and only bows away from it towards the corners, where the bent edge fades
// out over a few pixels into transparent (black on a projector). 2 is a
// lens's slight bend. It goes with the other lens effects, near the end of a
// film look.

uniform float Distortion<
    string label = "Distortion";
    string tooltip = "How strongly the picture bends, in percent: positive for barrel (its edges bow outwards and its corners round in), negative for pincushion. The middles of the left and right edges stay at the frame's edges, so the picture still fills the frame there. About 2 for a projector lens; 5 or more is a strong bend.";
    string widget_type = "slider";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.0;

float4 mainImage(VertData v_in) : TARGET
{
    // Distance from the middle in the picture's proportions; the corners at
    // rc2 squared. Each pixel shows the picture from 1 + k r^2 further out
    // (k set so the corners would come in by Distortion percent), then the
    // whole is enlarged by z so the middles of the left and right edges stay
    // put.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float rc2 = (aspect * aspect + 1.0) * 0.25;
    float m = max(1.0 - Distortion * 0.01, 0.01);
    float k = (1.0 / m - 1.0) / (m * m * rc2);
    float z = 1.0 / (1.0 + k * aspect * aspect * 0.25);
    float2 uv = 0.5 + (v_in.uv - 0.5) * (1.0 + k * dot(d, d)) * z;

    // Sampled half a pixel inside the picture; where the bent edge falls
    // inside the frame it fades out over a few pixels beyond it (with no bend,
    // the picture's own edge pixels are left as they are).
    float4 c = image.Sample(textureSampler, clamp(uv, 0.5 * uv_pixel_interval, 1.0 - 0.5 * uv_pixel_interval));
    float2 q = (abs(uv - 0.5) - 0.5) / uv_pixel_interval;
    float outside = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float feather = 2.0 / (uv_pixel_interval.y * 1080.0);
    c.a *= 1.0 - smoothstep(0.0, 2.0 * feather, outside + 0.5);
    return c;
}
