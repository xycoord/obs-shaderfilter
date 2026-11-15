// Film Print for obs-shaderfilter: the tone and colour of a picture printed on
// film and projected. A print has a toe and a shoulder: shadows are pressed
// down and midtones filled out (contrast), and the brightest parts roll off
// smoothly into the clear film's white instead of clipping. Old prints were
// black and white, sepia toned, or tinted a colour all over; colour prints
// fade as their dyes do; and a projector's lamp, a tungsten one above all,
// lights it all warm.
//
// It's a grade, on the picture as it's stored (sRGB), like a LUT: pointwise,
// so it can be merged with neighbouring shader filters. Transparency is kept.
// It goes first in a film look, before Halation and Film Grain. Brighter than
// white (HDR) rolls off into the shoulder too.

uniform int Stock<
    string label = "Stock";
    string tooltip = "What the print is: colour; black and white; black and white toned brown (sepia); or black and white tinted a colour all over, as silent films were (amber for daylight and interiors, blue for night).";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "Colour";
    int option_1_value = 1;
    string option_1_label = "Black and white";
    int option_2_value = 2;
    string option_2_label = "Sepia toned";
    int option_3_value = 3;
    string option_3_label = "Amber tint";
    int option_4_value = 4;
    string option_4_label = "Blue tint";
> = 0;
uniform float Contrast<
    string label = "Contrast";
    string tooltip = "How strong the print's S-curve is, in percent: shadows pressed down and midtones filled out. 0 leaves them as they are.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 35.0;
uniform float White<
    string label = "White";
    string tooltip = "How bright white is, in percent: light through clear film is never quite full white. The brightest parts roll off smoothly into it, so nothing clips.";
    string widget_type = "slider";
    float minimum = 70.0;
    float maximum = 100.0;
    float step = 0.5;
> = 96.0;
uniform float Roll_Off<
    string label = "Highlight Roll-off";
    string tooltip = "How softly the brightest parts roll off into White (the print's shoulder), in percent: 0 is a straight line up to White; more compresses the highlights and lifts the midtones a little.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 40.0;
uniform float Fade<
    string label = "Fade";
    string tooltip = "How much colour has faded out of the print, in percent: 0 is a new print, 100 has no colour left.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 20.0;
uniform float Warmth<
    string label = "Warmth";
    string tooltip = "How warm the projector's light is, in percent: 0 is neutral, 100 a tungsten lamp, as in 16mm and Super 8 projectors. Warmer in the shadows than the highlights, which turn cream.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 50.0;
uniform float Black_Lift<
    string label = "Black Lift";
    string tooltip = "How far black is lifted, in percent, as an old print's base never gets to full black. It lifts black everywhere, so on a projector it shows the edge of the picture: leave it at 0 for a logo on black.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 20.0;
    float step = 0.5;
> = 0.0;
uniform string Full_Look<
    string label = "Switch to Film Look";
    string widget_type = "switch";
    string tooltip = "Make this filter a Film Look (the film, projector and lens in one filter), keeping these settings: the parts this filter doesn't have are set to the same Look.";
> = "film_look.shader";

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float3 x = max(c.rgb, 0.0);

    // The toe: an S-curve over 0 to 1, a straight line above (HDR).
    float3 xs = min(x, 1.0);
    float3 s = xs * xs * (3.0 - 2.0 * xs) + (x - xs);
    float3 rgb = lerp(x, s, Contrast * 0.01);

    // The shoulder: rolls off smoothly into White (exactly White at 1; a
    // straight line at a Roll-off of 0).
    float k = max(Roll_Off * 0.02, 0.0001);
    rgb = (1.0 - exp(-k * rgb)) / (1.0 - exp(-k)) * (White * 0.01);

    // The stock.
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    if (Stock == 1)
        rgb = float3(l, l, l);
    else if (Stock == 2)
        rgb = l * lerp(float3(0.42, 0.28, 0.17), float3(1.0, 0.93, 0.80), saturate(l)) * float3(1.12, 1.03, 0.92);
    else if (Stock == 3)
        rgb = l * float3(1.0, 0.78, 0.45);
    else if (Stock == 4)
        rgb = l * float3(0.55, 0.72, 1.0);

    // Fade: colour drains out.
    l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = lerp(rgb, float3(l, l, l), Fade * 0.01);

    // Warmth: the lamp's colour, cream in the highlights and browner in the
    // shadows.
    rgb *= lerp(float3(1.0, 1.0, 1.0), lerp(float3(1.0, 0.86, 0.70), float3(1.0, 0.95, 0.84), saturate(l)), Warmth * 0.01);

    // Black lift: the print's base, a little warm.
    rgb += (1.0 - min(rgb, 1.0)) * (Black_Lift * 0.01) * float3(1.0, 0.85, 0.70);

    return float4(rgb, c.a);
}
