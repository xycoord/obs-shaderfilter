// Projector for obs-shaderfilter: everything the film projector adds, in one
// pass. Gate Weave (the picture not sitting still in the gate), Projector
// Flicker (the lamp and the film's density changing frame to frame) and
// Projector Gate (the soft, round-cornered frame) together, with the same
// settings, and one Amount to turn the whole projector up or down.
//
// Amount scales every effect from none (0: the picture comes through
// untouched) through the settings as set (100) to twice as strong (200).
// Weave and flicker step together, once per frame of film, at Speed (with
// Hand Cranking wavering both). Set Speed the same as Film's or Film Grain's;
// each filter counts time from when it was added, so their frames change at
// the same rate but not at the same moment.
// It goes after the film's own effects (grain and dust move with the picture)
// and before the lens's. Outside the gate the picture turns transparent
// (black on a projector).

uniform int Projector_Amount<
    string label = "Amount";
    string tooltip = "How strong the whole projector is, in percent of the settings below: 0 is none (the picture untouched), 100 as set, 200 twice as strong.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 200;
    int step = 1;
> = 100;
uniform int Speed<
    string label = "Speed";
    string show = "more";
    string tooltip = "Frames of film a second: the weave and flicker change this often. 24 for sound film, 16 to 18 for silent film and Super 8.";
    string widget_type = "slider";
    string suffix = " fps";
    int minimum = 1;
    int maximum = 60;
    int step = 1;
> = 24;

#include "projector_parts.hlsl"

float4 mainImage(VertData v_in) : TARGET
{
    float a = float(Projector_Amount) * 0.01;
    float frame = projector_frame(a);
    float4 c = image.Sample(textureSampler, v_in.uv - projector_weave(frame, a));
    c.rgb *= projector_light(v_in.uv, frame, a);
    c.a *= projector_gate(v_in.uv, a);
    return c;
}
