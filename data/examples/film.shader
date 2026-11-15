// Film for obs-shaderfilter: everything the film itself adds, in one pass.
// Film Print (the print's tone and colour), Halation (the halo round bright
// parts), the film's own softness (as Lens Softness's Softness), Film Grain and
// Dust & Scratches together, with the same settings, and one Amount to turn
// the whole film up or down. The projector (weave, flicker, gate) is in
// Projector and the lens in Lens; in a film look Film goes first, then
// Projector, then Lens.
//
// Amount scales every effect from none (0: the picture comes through
// untouched) through the settings as set (100) to twice as strong (200). In
// one pass the softness and the halo's threshold work on the picture before
// the print rather than after it, so it differs a little from the separate
// filters chained (by about a level in 255 on average). The halo is
// red-orange on a colour stock and neutral on the others, as on black and
// white film. Grain and dust change Speed times a second; set it the same as
// Projector's (Film Look does all three, in step). Sizes are in pixels on a 1080-line picture (scaled for other
// sizes). Where the source is transparent, as round a logo, the halo and light
// specks are drawn with their own transparency.

uniform int Film_Amount<
    string label = "Amount";
    string tooltip = "How strong the whole film is, in percent of the settings below: 0 is none (the picture untouched), 100 as set, 200 twice as strong.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 200;
    int step = 1;
> = 100;
uniform string Full_Look<
    string label = "Switch to Film Look";
    string widget_type = "switch";
    string tooltip = "Make this filter a Film Look (the film, projector and lens in one filter), keeping these settings: the parts this filter doesn't have are set to the same Look.";
> = "film_look.shader";
uniform int Speed<
    string label = "Speed";
    string show = "more";
    string tooltip = "Frames of film a second: the grain and dust change this often. 24 for sound film, 16 to 18 for silent film and Super 8.";
    string widget_type = "slider";
    string suffix = " fps";
    int minimum = 1;
    int maximum = 60;
    int step = 1;
> = 24;

#include "film_parts.hlsl"

float4 mainImage(VertData v_in) : TARGET
{
    return film_at(v_in.uv, float(Film_Amount) * 0.01, floor(elapsed_time * float(Speed)));
}
