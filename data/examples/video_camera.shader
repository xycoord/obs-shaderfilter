// Video Camera for obs-shaderfilter: the look of a picture shot on a 1980s or
// 90s video camera, before it ever reached tape. Its detail circuit (aperture
// correction) sharpens every edge, across and up and down, into a bright and
// a dark outline, which is the strongest cue of shot-on-video footage; its
// highlights clip hard to a flat white, unlike film's soft shoulder; and its
// colour is rich.
//
// Like the camera, it works on the video signal (the gamma-encoded picture),
// on brightness for the detail and the clip and on colour for saturation.
// Sizes are in pixels on a 1080-line picture (scaled for other sizes). It goes
// first, before VHS Tape (or VHS Signal), which then softens and smears the
// outlines as a tape does. Black stays black: the outlines can't go below it,
// and nothing is added where the picture is black.

uniform float Detail<
    string label = "Detail";
    string tooltip = "How strongly edges are sharpened, in percent of the detail signal added back: about 50 for a broadcast camera, 80 to 130 for the bright outlines of a home or industrial video. A sharp edge overshoots by about a third of this either side.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 80.0;
uniform float Detail_Size<
    string label = "Detail Size";
    string tooltip = "How wide the outlines are, in pixels on a 1080-line picture (the detail circuit's reach, as a blur's standard deviation).";
    string widget_type = "slider";
    float minimum = 0.5;
    float maximum = 6.0;
    float step = 0.1;
> = 2.0;
uniform float Coring<
    string label = "Coring";
    string tooltip = "How small a difference is left unsharpened, in percent of white, so fine noise and texture aren't sharpened into grit. 1 to 3 is typical.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.1;
> = 2.0;
uniform float Knee<
    string label = "Knee";
    string tooltip = "The brightness, in percent, above which the highlights are stretched to the clip: below it the picture is as it was.";
    string widget_type = "slider";
    float minimum = 50.0;
    float maximum = 100.0;
    float step = 0.5;
> = 80.0;
uniform float Clip<
    string label = "Clip";
    string tooltip = "The brightness, in percent, that comes out as full white: anything brighter is flat white, as a video camera's highlights are. 100 clips nothing.";
    string widget_type = "slider";
    float minimum = 60.0;
    float maximum = 100.0;
    float step = 0.5;
> = 92.0;
uniform float Saturation<
    string label = "Saturation";
    string tooltip = "How strong colours are, in percent: 100 keeps them; video cameras of the time were often set a little rich.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 115.0;

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float3 lw = float3(0.299, 0.587, 0.114);
    float y = dot(c.rgb, lw);

    // The detail signal: brightness minus a Gaussian blur of it, from the
    // pixel and two rings of eight (at 1 and 2 standard deviations), fixed, so
    // the blur adds no noise of its own to sharpen.
    float2 r = Detail_Size / (uv_pixel_interval.y * 1080.0) * uv_pixel_interval;
    float blur = y;
    float total = 1.0;
    for (int i = 0; i < 8; i++) {
        float ang = float(i) * 0.7853982;
        float2 dir = float2(cos(ang), sin(ang));
        float a = dot(image.Sample(textureSampler, v_in.uv + dir * r).rgb, lw);
        float b = dot(image.Sample(textureSampler, v_in.uv + dir * r * 2.0).rgb, lw);
        blur += 0.6065307 * a + 0.1353353 * b;
        total += 0.6065307 + 0.1353353;
    }
    blur /= total;
    float detail = y - blur;
    detail = sign(detail) * max(abs(detail) - Coring * 0.01, 0.0);
    float y2 = max(y + detail * Detail * 0.01, 0.0);

    // The knee and clip: unchanged below Knee, stretched from Knee to reach
    // white at Clip, flat white above.
    float k = Knee * 0.01;
    float cl = max(Clip * 0.01, k + 0.001);
    if (y2 > k)
        y2 = k + (1.0 - k) * min((y2 - k) / (cl - k), 1.0);

    // Colour round the new brightness, then clipped per channel, so a
    // clipped highlight goes white.
    float3 rgb = y2 + (c.rgb - y) * (Saturation * 0.01);
    return float4(saturate(rgb), c.a);
}
