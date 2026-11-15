// CRT Scanlines for obs-shaderfilter: a picture drawn line by line by an
// electron beam. Each line is a soft stripe of light (a Gaussian beam) whose
// width grows with brightness, as the beam spreads when it's driven harder
// (blooming): bright parts' lines are fat and nearly merge, dark parts'
// thin, with dark gaps between. A TV showing broadcast pictures drew 576
// lines (PAL) or 480 (NTSC), too close together on a 1080-line picture to
// show as more than a faint texture; games consoles and home computers drew
// half as many, 288 or 240, with the gaps plain to see. Those are drawn here
// at 270 lines (4 pixels each) or 360 (3 pixels): whole pixels, so the lines
// don't beat against the picture's pixels.
//
// The beam is drawn in light (linear), each colour's own width, and summed
// over each output pixel. A line's brightness is the picture filtered down
// to the lines (a Gaussian about a line wide), so fine detail dims rather
// than breaking up. Black stays black; the gaps between lines are dark, not
// see-through, and light reaching past a transparent edge shows. It goes
// after CRT Geometry and before CRT Mask and CRT Glass. For the lines to
// stay even, show the picture at the projector's own resolution.

uniform int Standard<
    string label = "Lines";
    string tooltip = "How many lines: a TV's broadcast picture (576 or 480, a faint texture), or games and computers (270 or 360 on a 1080-line picture, 4 or 3 pixels apart, with clear gaps between them; on other sizes rounded to whole pixels apart).";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "TV, PAL (576 lines)";
    int option_1_value = 1;
    string option_1_label = "TV, NTSC (480 lines)";
    int option_2_value = 2;
    string option_2_label = "Games and computers (270 lines)";
    int option_3_value = 3;
    string option_3_label = "Games and computers, fine (360 lines)";
> = 0;
uniform float Beam_Width<
    string label = "Beam Width";
    string tooltip = "How wide a full-brightness line is, as its width at half height (FWHM) in percent of the distance between lines. At 90 bright parts keep a faint ripple (about a tenth); at 120 their lines merge.";
    string widget_type = "slider";
    float minimum = 40.0;
    float maximum = 150.0;
    float step = 1.0;
> = 90.0;
uniform float Blooming<
    string label = "Blooming";
    string tooltip = "How much wider a full-brightness line is than a dim one, in percent: the beam spreading as it's driven harder. 0 keeps every line the same width; 40 makes dim lines about two thirds as wide, so gaps show more in dark parts.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 40.0;

// The sRGB curve, both ways, carried on above 1.
float3 scan_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 scan_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// The share of a unit Gaussian below z (a close approximation).
float3 scan_cdf(float3 z)
{
    return 0.5 + 0.5 * tanh(0.7978846 * (z + 0.044715 * z * z * z));
}

// One line's light over this pixel: the line's colour v (its picture
// filtered down to it), each colour's beam wider the brighter it is, its
// light spread over the line's share of height and summed over this pixel;
// none for a line outside the picture.
float3 scan_line(float li, float last, float gap, float y0, float y1, float s_dark, float s_bright, float3 v)
{
    if (li < 0.0 || li >= last)
        return float3(0.0, 0.0, 0.0);
    float yc = (li + 0.5) * gap;
    float3 sig = lerp(float3(s_dark, s_dark, s_dark), float3(s_bright, s_bright, s_bright), sqrt(saturate(v)));
    float3 share = scan_cdf((y1 - yc) / sig) - scan_cdf((y0 - yc) / sig);
    return v * share * gap;
}

float4 mainImage(VertData v_in) : TARGET
{
    // Lines down the picture.
    float lines = Standard == 1 ? 480.0 : (Standard == 2 ? 270.0 : (Standard == 3 ? 360.0 : 576.0));

    // Positions in output pixels, down the picture.
    float height = 1.0 / uv_pixel_interval.y;
    float gap = height / lines;
    // Games and computers' lines in whole pixels of this picture, whatever its size.
    if (Standard >= 2)
        gap = max(floor(gap + 0.5), 2.0);
    float y = v_in.uv.y * height;
    float y0 = y - 0.5;
    float y1 = y + 0.5;

    // Beam widths as standard deviations: FWHM = 2.355 sigma.
    float s_bright = Beam_Width * 0.01 * gap / 2.3548;
    float s_dark = s_bright / (1.0 + Blooming * 0.01);

    // The two nearest lines above and below.
    float n = floor(y / gap - 0.5);
    float last = floor(height / gap + 0.5);
    // The picture filtered down to each of the four lines, in light,
    // premultiplied by transparency: a Gaussian over half a line either way
    // (five samples), so detail finer than the lines dims and softens rather
    // than breaking up. Next lines' samples overlap (each half a line
    // apart), so the four lines take eleven samples, not twenty.
    float base = (n - 1.0 + 0.5) * gap - gap;
    float4 t0 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 0.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p0 = scan_to_linear(t0.rgb) * t0.a;
    float4 t1 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 1.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p1 = scan_to_linear(t1.rgb) * t1.a;
    float4 t2 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 2.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p2 = scan_to_linear(t2.rgb) * t2.a;
    float4 t3 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 3.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p3 = scan_to_linear(t3.rgb) * t3.a;
    float4 t4 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 4.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p4 = scan_to_linear(t4.rgb) * t4.a;
    float4 t5 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 5.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p5 = scan_to_linear(t5.rgb) * t5.a;
    float4 t6 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 6.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p6 = scan_to_linear(t6.rgb) * t6.a;
    float4 t7 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 7.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p7 = scan_to_linear(t7.rgb) * t7.a;
    float4 t8 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 8.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p8 = scan_to_linear(t8.rgb) * t8.a;
    float4 t9 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 9.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p9 = scan_to_linear(t9.rgb) * t9.a;
    float4 t10 = image.Sample(textureSampler, float2(v_in.uv.x, (base + 10.0 * gap * 0.5) * uv_pixel_interval.y));
    float3 p10 = scan_to_linear(t10.rgb) * t10.a;
    float3 light = float3(0.0, 0.0, 0.0);
    light += scan_line(n - 1.0, last, gap, y0, y1, s_dark, s_bright, (0.13533528 * p0 + 0.60653066 * p1 + p2 + 0.60653066 * p3 + 0.13533528 * p4) / 2.48373188);
    light += scan_line(n, last, gap, y0, y1, s_dark, s_bright, (0.13533528 * p2 + 0.60653066 * p3 + p4 + 0.60653066 * p5 + 0.13533528 * p6) / 2.48373188);
    light += scan_line(n + 1.0, last, gap, y0, y1, s_dark, s_bright, (0.13533528 * p4 + 0.60653066 * p5 + p6 + 0.60653066 * p7 + 0.13533528 * p8) / 2.48373188);
    light += scan_line(n + 2.0, last, gap, y0, y1, s_dark, s_bright, (0.13533528 * p6 + 0.60653066 * p7 + p8 + 0.60653066 * p9 + 0.13533528 * p10) / 2.48373188);

    // Coverage: the picture's own here (the gaps between lines are dark,
    // not see-through), and wherever a beam's light reaches past it.
    float alpha = saturate(max(image.Sample(textureSampler, v_in.uv).a, max(light.r, max(light.g, light.b))));
    if (alpha <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    return float4(scan_from_linear(light / alpha), alpha);
}
