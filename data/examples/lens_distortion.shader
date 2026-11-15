// Lens Distortion for obs-shaderfilter: a lens bending the picture's straight
// lines. With barrel distortion (positive) the picture is magnified a little
// less towards its edges, so its straight edges bow outwards and its corners
// come in; with pincushion distortion (negative) the corners go out, and are
// cut off. Projector lenses distort a little; it takes the dead-straight edges
// off a picture that fills the frame.
//
// Set as how far the corners move, in percent of the distance to them: 2 is
// a lens's slight bend. The middle stays where it is. Outside the bent picture
// is transparent (black on a projector). It goes with the other lens effects,
// near the end of a film look, before Lens Softness's edges and the vignette.

uniform float Distortion<
    string label = "Distortion";
    string tooltip = "How far the corners move, in percent: positive for barrel (edges bow out, corners come in), negative for pincushion (corners go out and are cut off). About 2 for a projector lens; 5 or more is a strong bend.";
    string widget_type = "slider";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.0;

float4 mainImage(VertData v_in) : TARGET
{
    // Distance from the middle in the picture's proportions; the corners at
    // rc2 squared. Each pixel shows the picture from 1 + k r^2 further out,
    // with k set so the corners come in by Distortion percent.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float rc2 = (aspect * aspect + 1.0) * 0.25;
    float m = max(1.0 - Distortion * 0.01, 0.01);
    // Corners: the picture's corner lands where r (1 + k r^2) = rc, so pick k
    // for r = m rc: m (1 + k m^2 rc2) = 1.
    float k = (1.0 / m - 1.0) / (m * m * rc2);
    return image.Sample(textureSampler, 0.5 + (v_in.uv - 0.5) * (1.0 + k * dot(d, d)));
}
