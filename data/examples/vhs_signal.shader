// VHS Signal for obs-shaderfilter: the picture as a VHS recorder records and
// plays it back. A VHS tape carries brightness (luma) at only about 3 MHz,
// about 240 TV lines of detail across, and colour (chroma) at only about
// 0.5 MHz, a fraction of that: colour is smeared sideways well past the
// edges it belongs to, and arrives a little late, so it sits slightly to the
// right. The player's detail circuit sharpens what's left, which leaves a
// faint light and dark outline either side of strong edges. Playback also
// averages colour over two lines, so it sits about a line low.
//
// Settings are in TV lines (TVL: how many alternating light and dark lines
// can be told apart across a width equal to the picture's height, where
// they're down to half contrast) and pixels on a 1080-line picture (scaled
// for other sizes). It works on the signal as recorded (gamma-encoded Y'IQ,
// not light), as a VCR does. Colour bleeds past coloured edges, as on tape,
// onto the black beside them, but black away from any colour stays black. Transparency is blurred
// with the picture.
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
    string tooltip = "How much brightness detail survives across the picture, in TV lines. About 240 for VHS, 400 for S-VHS, 330 for broadcast TV; lower is softer.";
    string widget_type = "slider";
    float minimum = 100.0;
    float maximum = 600.0;
    float step = 5.0;
> = 240.0;
uniform float Chroma_Resolution<
    string label = "Chroma Resolution";
    string tooltip = "How much colour detail survives across the picture, in TV lines: far less than brightness on tape. About 30 for VHS, 40 for S-VHS, 100 for broadcast TV; lower smears colour further.";
    string widget_type = "slider";
    float minimum = 10.0;
    float maximum = 200.0;
    float step = 1.0;
> = 35.0;
uniform float Chroma_Delay<
    string label = "Chroma Delay";
    string tooltip = "How far colour sits to the right of where it belongs, in pixels on a 1080-line picture (about 37 ns of signal each). 3 to 6 on a typical VCR; 0 on a well-adjusted one; negative moves it left.";
    string widget_type = "slider";
    float minimum = -10.0;
    float maximum = 10.0;
    float step = 0.1;
> = 4.0;
uniform float Sharpening<
    string label = "Sharpening";
    string tooltip = "How far a sharp edge overshoots, in percent of the step: the faint light and dark outline the player's detail circuit draws either side of strong edges. 0 for none, 10 to 15 for a typical VCR.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 40.0;
    float step = 0.5;
> = 12.0;
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

    // Gaussian filters whose response is down to half at the set resolution:
    // a standard deviation of 404.8 / TVL pixels on a 1080-line picture.
    float sigma_l = 404.8 / max(Luma_Resolution, 1.0);
    float sigma_w = sigma_l * 2.5;
    float sigma_c = 404.8 / max(Chroma_Resolution, 1.0);

    // Luma, and a wider luma for the detail circuit, from one row of 21
    // samples out to 3 of the wider one's standard deviations (premultiplied
    // by transparency, which is filtered with luma).
    float step_l = sigma_l * 0.75;
    float y_l = 0.0;
    float y_w = 0.0;
    float a_l = 0.0;
    float a_w = 0.0;
    float wl = 0.0;
    float ww = 0.0;
    for (int i = -10; i <= 10; i++) {
        float o = float(i) * step_l;
        float4 s = image.Sample(textureSampler, v_in.uv + float2(o * px.x, 0.0));
        float y = dot(s.rgb, float3(0.299, 0.587, 0.114)) * s.a;
        float kl = exp(-0.5 * (o / sigma_l) * (o / sigma_l));
        float kw = exp(-0.5 * (o / sigma_w) * (o / sigma_w));
        y_l += kl * y;
        a_l += kl * s.a;
        wl += kl;
        y_w += kw * y;
        a_w += kw * s.a;
        ww += kw;
    }
    y_l /= wl;
    a_l /= wl;
    y_w /= ww;

    // The detail circuit: the luma's difference from the wider luma, scaled
    // so a sharp edge overshoots Sharpening percent of its step.
    float y_out = y_l + (Sharpening / 16.2) * (y_l - y_w);

    // Chroma: 15 samples across, half a standard deviation apart, on the
    // line above and the one above that (playback averages two lines, and
    // colour lands about a line low), late by Chroma_Delay.
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
        float dy = -(float(r) + 0.5) * line_gap * px.y;
        for (int j = -7; j <= 7; j++) {
            float t = float(j) + jitter;
            float o = t * step_c - Chroma_Delay;
            float4 s = image.Sample(textureSampler, v_in.uv + float2(o * px.x, dy));
            float k = exp(-0.5 * (t * 0.5) * (t * 0.5));
            yiq_c += k * vhs_to_yiq(s.rgb * s.a);
            a_c += k * s.a;
        }
    }
    // Colour of what's covered (straight, not premultiplied). It's kept
    // wherever there's picture within the colour's reach (luma averaged the
    // same way, above 3%), so colour smears past coloured edges, but fades
    // out where everything round is black: black far from colour stays black.
    yiq_c /= max(a_c, 0.0001);
    float2 iq = yiq_c.yz * (Saturation * 0.01) * smoothstep(0.0, 0.03, yiq_c.x);

    // Back to RGB, luma out of premultiplied. The detail circuit's undershoot
    // can't go below black.
    if (a_l <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    float3 rgb = max(vhs_from_yiq(float3(y_out / a_l, iq)), 0.0);
    return float4(rgb, saturate(a_l));
}
