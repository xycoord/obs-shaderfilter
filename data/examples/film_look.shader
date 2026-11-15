// Film Look for obs-shaderfilter: the whole look of film on an old projector
// in one filter. Film (the print, halation, grain, dust and scratches), then
// Projector (gate weave, flicker, the frame's edge), then Lens (distortion,
// colour fringes, dark and soft corners), exactly as those three filters do
// one after another, with the same settings, but in step with each other
// (the weave, flicker, grain and dust all change on the same frame of film).
//
// Pick a Look, then turn the whole thing up or down with Amount; untick any
// part you don't want (its settings are kept for when you tick it again).
// Show All Settings shows every setting of every part, and each part's own
// Amount. The film and projector are drawn in one pass, the lens in a second
// over its result (it softens and fringes what the film made). Sizes are in
// pixels on a 1080-line picture (scaled for other sizes).

#define FILM_LOOK 1

uniform int Look_Amount<
    string label = "Amount";
    string tooltip = "How strong the whole look is, in percent of the settings below: 0 is none (the picture untouched), 100 as set, 200 twice as strong.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 200;
    int step = 1;
> = 100;
uniform int Speed<
    string label = "Speed";
    string show = "more";
    string tooltip = "Frames of film a second: the grain, dust, weave and flicker change this often. 24 for sound film, 16 to 18 for silent film and Super 8.";
    string widget_type = "slider";
    string suffix = " fps";
    int minimum = 1;
    int maximum = 60;
    int step = 1;
> = 24;
uniform int Film_Amount<
    string label = "Film Amount";
    string tooltip = "How strong the film's part is (the print, halation, grain, dust and scratches), in percent of its settings.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 200;
    int step = 1;
> = 100;
uniform int Projector_Amount<
    string label = "Projector Amount";
    string tooltip = "How strong the projector's part is (gate weave, flicker, the frame's edge), in percent of its settings.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 200;
    int step = 1;
> = 100;
uniform int Lens_Amount<
    string label = "Lens Amount";
    string tooltip = "How strong the lens's part is (distortion, fringes, dark and soft corners), in percent of its settings.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 200;
    int step = 1;
> = 100;

#include "film_parts.hlsl"
#include "projector_parts.hlsl"
#include "lens_parts.hlsl"

// The film, moved by the weave so that everything on it moves with the
// picture, then lit by the flickering lamp and cut by the gate.
float4 stage1(VertData v_in) : TARGET
{
    float look = float(Look_Amount) * 0.01;
    float ap = float(Projector_Amount) * 0.01 * look;
    float frame = projector_frame(ap);
    float4 c = film_at(v_in.uv - projector_weave(frame, ap), float(Film_Amount) * 0.01 * look, frame);
    c.rgb *= projector_light(v_in.uv, frame, ap);
    c.a *= projector_gate(v_in.uv, ap);
    return c;
}

// The lens, over the projected picture.
float4 mainImage(VertData v_in) : TARGET
{
    if (!Lens_On)
        return image.Sample(textureSampler, v_in.uv);
    return lens_at(v_in.uv, float(Lens_Amount) * 0.01 * float(Look_Amount) * 0.01);
}
