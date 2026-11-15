// Tape Transfer for obs-shaderfilter: the frame of a video tape that has been
// digitised. A tape's picture is 4:3, and a capture shows the edges of the
// video signal that a television hid: a dark band down the left side where
// each line's picture starts, a thinner one on the right, a dark line along
// the top, and edges that are a little soft. A full-frame video with clean,
// square edges is what makes a projector look like one in an office; this
// gives it a tape's frame instead.
//
// Sizes are in pixels on a 1080-line picture (scaled for other sizes). With
// Aspect at 4:3 a wider source is cropped to the middle 4:3, not squeezed;
// outside it the picture turns transparent (black on a projector). It goes
// last, after VHS Tape. It only reads the pixel it draws, so it can be merged
// with neighbouring shader filters.

uniform int Aspect<
    string label = "Aspect";
    string tooltip = "The shape of the picture: 4:3, as a tape's, cropping a wider source to its middle; or the source's own.";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "4:3";
    int option_1_value = 1;
    string option_1_label = "Source";
> = 0;
uniform float Left_Band<
    string label = "Left Band";
    string tooltip = "How wide the dark band down the left side is, in pixels on a 1080-line picture: where each line of the signal starts. About 10 to 20 in a capture; 0 for none.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 60.0;
    float step = 0.5;
> = 14.0;
uniform float Right_Band<
    string label = "Right Band";
    string tooltip = "How wide the dark band down the right side is, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 3.0;
uniform float Top_Band<
    string label = "Top Band";
    string tooltip = "How tall the dark line along the top is, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 5.0;
uniform float Edge_Softness<
    string label = "Edge Softness";
    string tooltip = "How soft the edges of the bands and the picture are, in pixels on a 1080-line picture: how far they take to fade.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 20.0;
    float step = 0.5;
> = 2.0;

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);

    // This pixel from the middle, in pixels of a 1080-line picture, and the
    // picture's half width.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 p = (v_in.uv - 0.5) * float2(1080.0 * aspect, 1080.0);
    float half_w = Aspect == 0 ? min(720.0, 540.0 * aspect) : 540.0 * aspect;
    float s = max(Edge_Softness, 0.001);

    // Distances in from the picture's left, right and top edges.
    float from_left = p.x + half_w;
    float from_right = half_w - p.x;
    float from_top = p.y + 540.0;

    // Outside the picture: transparent, the edge fading over Edge_Softness.
    float inside = smoothstep(-0.5 * s, 0.5 * s, min(from_left, from_right));
    c.a *= inside;

    // The bands: dark, fading into the picture over Edge_Softness.
    float lit = smoothstep(Left_Band - 0.5 * s, Left_Band + 0.5 * s, from_left)
              * smoothstep(Right_Band - 0.5 * s, Right_Band + 0.5 * s, from_right)
              * smoothstep(Top_Band - 0.5 * s, Top_Band + 0.5 * s, from_top);
    c.rgb *= lit;
    return c;
}
