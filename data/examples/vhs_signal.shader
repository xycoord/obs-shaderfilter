// VHS Signal for obs-shaderfilter: the picture as a VHS recorder records and
// plays it back. A VHS tape carries brightness (luma) at only about 3 MHz,
// about 240 TV lines of detail across, and colour (chroma) at only about
// 0.5 MHz, a fraction of that: colour is smeared sideways well past the
// edges it belongs to, and arrives a little late, so it sits slightly to the
// right. The tape's steep luma filter rings a little at sharp edges, and the
// player's detail circuit sharpens what's left, which leaves a
// faint light and dark outline either side of strong edges. Playback also
// averages colour over two lines, so it sits half a line low. 70% of the
// colour is laid on the brightness detail it belongs to, so thin coloured
// lettering keeps some colour (strict tape loses nearly all of it).
//
// Settings are in TV lines (TVL: how many alternating light and dark lines
// can be told apart across a width equal to the picture's height, where
// they're down to half contrast) and pixels on a 1080-line picture (scaled
// for other sizes). It works on the signal as recorded (gamma-encoded Y'IQ,
// not light), as a VCR does. Colour bleeds past coloured edges, as on tape,
// onto the black beside them, but black away from any colour stays black.
// Transparency is blurred with the picture.
//
// It goes first in a VHS look, before VHS Noise and VHS Tracking, and before
// any CRT filters.

uniform int Standard<
    string label = "Standard";
    string tooltip = "The TV system: PAL (576 lines, as in the UK and Europe) or NTSC (480 lines, as in the US and Japan). Sets how far apart the lines are whose colour playback averages.";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "PAL";
    int option_1_value = 1;
    string option_1_label = "NTSC";
> = 0;
uniform float Luma_Resolution<
    string label = "Luma Resolution";
    string tooltip = "How much brightness detail survives across the picture, in TV lines (where it's down to half; it's all but gone a third above). About 240 for VHS, 400 for S-VHS, 330 for broadcast TV; lower is softer.";
    string widget_type = "slider";
    float minimum = 100.0;
    float maximum = 600.0;
    float step = 5.0;
> = 240.0;
uniform float Chroma_Resolution<
    string label = "Chroma Resolution";
    string tooltip = "How much colour detail survives across the picture, in TV lines (for colour changing at the same brightness): far less than brightness on tape. About 30 to 40 for VHS, 45 for S-VHS, 100 for broadcast TV; lower smears colour further.";
    string widget_type = "slider";
    float minimum = 10.0;
    float maximum = 200.0;
    float step = 1.0;
> = 40.0;
uniform float Chroma_Delay<
    string label = "Chroma Delay";
    string tooltip = "How far colour sits to the right of where it belongs, in pixels on a 1080-line picture (about 37 ns of signal each). 2 to 6 on a typical VCR; 0 on a well-adjusted one; negative moves it left.";
    string widget_type = "slider";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 3.0;
uniform float Sharpening<
    string label = "Sharpening";
    string tooltip = "How much further a sharp edge overshoots, in percent of its step, from the player's detail circuit: a faint light and dark outline either side. The steep tape filter already rings about 6% by itself; 2 to 5 more is a typical VCR, 0 a plain one.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 30.0;
    float step = 0.5;
> = 2.0;
uniform float White_Level<
    string label = "White Level";
    string tooltip = "How bright full white plays back, in percent. 100 keeps it; a worn or long-play tape plays back a little grey (92 to 96), which also leaves room for its noise to show in the whites.";
    string widget_type = "slider";
    float minimum = 80.0;
    float maximum = 100.0;
    float step = 0.5;
> = 100.0;
uniform float Saturation<
    string label = "Saturation";
    string tooltip = "How strong colours are, in percent: 100 keeps them as they are; tape often loses a little.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 150.0;
    float step = 1.0;
> = 90.0;

float3 vhs_to_yiq(float3 c)
{
    return float3(dot(c, float3(0.299, 0.587, 0.114)), dot(c, float3(0.596, -0.274, -0.322)), dot(c, float3(0.211, -0.523, 0.312)));
}
float3 vhs_from_yiq(float3 y)
{
    return float3(y.x + 0.956 * y.y + 0.621 * y.z, y.x - 0.272 * y.y - 0.647 * y.z, y.x - 1.106 * y.y + 1.703 * y.z);
}

float4 mainImage(VertData v_in) : TARGET
{
    // One pixel on a 1080-line picture, in uv, across and down.
    float2 px = uv_pixel_interval / (uv_pixel_interval.y * 1080.0);

    // Luma: a steep low-pass (a windowed sinc, as a VCR's luma filter is
    // steep), its response down to half at Luma_Resolution and to under a
    // tenth a third of the way above it, from 25 samples across two of its
    // periods either side. A wider Gaussian of the same samples (standard
    // deviation 1012 / TVL pixels) is the detail circuit's reference, and a
    // positive Gaussian filters transparency, which can't ring. All the
    // weights are fixed: only the spacing follows the setting.
    float step_l = 360.0 / max(Luma_Resolution, 1.0);
    float y_l = 0.0;
    float y_w = 0.0;
    float a_l = 0.0;
    float wl = 0.0;
    float ww = 0.0;
    float wa = 0.0;
    float a_s = 0.0;
    for (int i = -12; i <= 12; i++) {
        float u = float(i) / 12.0;
        float4 s = image.Sample(textureSampler, v_in.uv + float2(float(i) * step_l * px.x, 0.0));
        float y = dot(s.rgb, float3(0.299, 0.587, 0.114)) * s.a;
        float sinc = i == 0 ? 1.0 : sin(12.566371 * u) / (12.566371 * u);
        float kl = sinc * (0.42 + 0.5 * cos(3.1415927 * u) + 0.08 * cos(6.2831853 * u));
        float kw = exp(-0.5 * (4.27 * u) * (4.27 * u));
        float ka = exp(-0.5 * (10.67 * u) * (10.67 * u));
        y_l += kl * y;
        wl += kl;
        y_w += kw * y;
        ww += kw;
        a_l += ka * s.a;
        wa += ka;
        a_s += kl * s.a;
    }
    // (Brightness is taken out of premultiplied with transparency filtered
    // the same way, held between half the smooth transparency and 1 so the
    // filter's ringing can't dim or brighten it; the result's transparency
    // is that same filtered transparency, so over black an edge against
    // transparency is as bright as the same picture on black.)
    a_s = clamp(a_s / wl, a_l / wa * 0.5, 1.0);
    y_l /= wl;
    a_l /= wa;
    y_w /= ww;
    float sigma_c = 404.8 / max(Chroma_Resolution, 1.0);

    // The detail circuit: the luma's difference from the wider luma, scaled
    // so a sharp edge overshoots Sharpening percent of its step more.
    float y_out = y_l + (Sharpening / 24.1) * (y_l - y_w);

    // Chroma: 15 samples across, half a standard deviation apart, on this
    // line and the one above (playback averages two lines, so colour lands
    // half a line low), late by Chroma_Delay.
    // The samples are shifted by a different fraction of their spacing at
    // each pixel, so thin coloured detail smears smoothly (with a faint
    // grain, as tape colour has) rather than in copies.
    float line_gap = Standard == 1 ? 1080.0 / 480.0 : 1080.0 / 576.0;
    float step_c = sigma_c * 0.5;
    float2 pix = v_in.uv / uv_pixel_interval;
    float jitter = frac(52.9829189 * frac(dot(pix, float2(0.06711056, 0.00583715)))) - 0.5;
    float3 yiq_c = float3(0.0, 0.0, 0.0);
    float a_c = 0.0;
    for (int r = 0; r < 2; r++) {
        float dy = -float(r) * line_gap * px.y;
        for (int j = -7; j <= 7; j++) {
            float t = float(j) + jitter;
            float o = t * step_c - Chroma_Delay;
            float4 s = image.Sample(textureSampler, v_in.uv + float2(o * px.x, dy));
            float k = exp(-0.5 * (t * 0.5) * (t * 0.5));
            yiq_c += k * vhs_to_yiq(s.rgb * s.a);
            a_c += k * s.a;
        }
    }
    if (a_l <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    float y_here = max(y_out / a_s, 0.0) * (White_Level * 0.01);

    // The colour, two ways. 30% is tape colour as it is: the
    // smeared average (straight, not premultiplied), kept wherever there's
    // picture within its reach (luma averaged the same way, above 3%), so it
    // bleeds past coloured edges but fades out where everything round is
    // black. The other 70% is the same colour per unit of brightness, laid
    // on this pixel's brightness: it follows the detail it belongs to, so
    // thin coloured lettering keeps some colour where strict tape would lose
    // nearly all of it. Black far from colour stays black.
    float2 smeared = yiq_c.yz / max(a_c, 0.0001) * smoothstep(0.0, 0.03, yiq_c.x / max(a_c, 0.0001));
    float2 follows = yiq_c.yz / max(yiq_c.x, 0.0001) * y_here;
    float2 iq = (0.3 * smeared + 0.7 * follows) * (Saturation * 0.01);

    // Back to RGB. The detail circuit's undershoot can't go below black.
    float3 rgb = max(vhs_from_yiq(float3(y_here, iq)), 0.0);
    return float4(rgb, a_s);
}
