// Projector Gate for obs-shaderfilter: the shape of the picture a film
// projector throws. The film runs behind an aperture plate, the gate, which
// sits just out of the lens's focus, so the edge of the picture lands on the
// screen a little soft, and its corners a little round. A video that fills the
// frame edge to edge, with hard square corners, is what makes a projector look
// like one in an office or a classroom; this gives it a projected film's
// shape instead.
//
// Sizes are in pixels on a 1080-line picture (scaled for other sizes). Outside
// the gate the picture turns transparent (black on a projector), so it only
// changes anything where the picture reaches its edges: a logo on black is
// left as it is. It goes after Gate Weave, so the picture weaves inside a
// steady frame, as it does in a projector. It only reads the pixel it draws,
// so it can be merged with neighbouring shader filters.

uniform string Full_Look<
    string label = "Switch to Film Look (adds the rest of the look)";
    string widget_type = "switch";
    string tooltip = "Make this filter a Film Look (the film, projector and lens in one filter), keeping these settings: the parts this filter doesn't have are set to the same Look.";
> = "film_look.shader";
uniform float Corner_Radius<
    string label = "Corner Radius";
    string tooltip = "How round the picture's corners are, in pixels on a 1080-line picture. A projector gate's corners are slightly round: about 30 for 16mm.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 30.0;
uniform float Edge_Softness<
    string label = "Edge Softness";
    string tooltip = "How soft the picture's edge is, in pixels on a 1080-line picture: how far it takes to fade out. The gate is a little out of focus: about 8 for 16mm; 20 or more is a very soft, dreamy edge.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 40.0;
    float step = 0.5;
> = 8.0;
uniform float Inset<
    string label = "Inset";
    string tooltip = "How far in from the source's edges the gate's edge sits, in pixels on a 1080-line picture, so the soft edge fades out inside the picture rather than being cut off by the source's own edge.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.5;
> = 6.0;

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);

    // This pixel from the middle, in pixels of a 1080-line picture.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 p = (v_in.uv - 0.5) * float2(1080.0 * aspect, 1080.0);

    // How far outside the gate's rounded rectangle it is (negative inside).
    float2 half_size = max(float2(540.0 * aspect, 540.0) - Inset, 1.0);
    float r = min(Corner_Radius, min(half_size.x, half_size.y));
    float2 q = abs(p) - (half_size - r);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;

    // Fades out over Edge_Softness, centred on the gate's edge.
    float s = max(Edge_Softness, 0.001);
    c.a *= 1.0 - smoothstep(-0.5 * s, 0.5 * s, d);
    return c;
}
