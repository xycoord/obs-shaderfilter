// Film for obs-shaderfilter: everything the film itself adds, in one pass.
// Film Print (the print's tone and colour), Halation (the halo round bright
// parts), the film's own softness (as Lens Softness's Softness), Film Grain and
// Dust & Scratches together, with the same settings, and one Amount to turn
// the whole film up or down. The projector (weave, flicker, gate) is in
// Projector and the lens in Lens; in a film look Film goes first, then
// Projector, then Lens.
//
// Amount scales every effect from none (0: the picture comes through
// untouched) through the settings as set (100) to twice as strong (200). The
// halo is red-orange on a colour stock and neutral on the others, as on black
// and white film. Grain and dust change Speed times a second; set it the same
// as Projector's. Sizes are in pixels on a 1080-line picture (scaled for other
// sizes). Where the source is transparent, as round a logo, the halo and light
// specks are drawn with their own transparency.

uniform float Amount<
    string label = "Amount";
    string tooltip = "How strong the whole film is, in percent of the settings below: 0 is none (the picture untouched), 100 as set, 200 twice as strong.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 200.0;
    float step = 1.0;
> = 100.0;
uniform int Speed<
    string label = "Speed";
    string tooltip = "Frames of film a second: the grain and dust change this often. 24 for sound film, 16 to 18 for silent film and Super 8. Use the same as Projector's.";
    string widget_type = "slider";
    int minimum = 1;
    int maximum = 60;
    int step = 1;
> = 24;
uniform int Stock<
    string label = "Stock";
    string group = "Print";
    string tooltip = "What the print is: colour; black and white; sepia toned; or tinted all over, amber or blue, as silent films were.";
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
    string group = "Print";
    string tooltip = "How strong the print's S-curve is, in percent: shadows pressed down and midtones filled out.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 35.0;
uniform float White<
    string label = "White";
    string group = "Print";
    string tooltip = "How bright white is, in percent: the brightest parts roll off into it.";
    string widget_type = "slider";
    float minimum = 70.0;
    float maximum = 100.0;
    float step = 0.5;
> = 96.0;
uniform float Roll_Off<
    string label = "Highlight Roll-off";
    string group = "Print";
    string tooltip = "How softly the brightest parts roll off into White, in percent: 0 is a straight line up to White.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 40.0;
uniform float Fade<
    string label = "Fade";
    string group = "Print";
    string tooltip = "How much colour has faded out of the print, in percent.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 30.0;
uniform float Warmth<
    string label = "Warmth";
    string group = "Print";
    string tooltip = "How warm the projector's light is, in percent: 0 neutral, 100 a tungsten lamp.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 50.0;
uniform float Black_Lift<
    string label = "Black Lift";
    string group = "Print";
    string tooltip = "How far black is lifted, in percent. It lifts black everywhere, which shows a projector's picture edge: leave it at 0 for a logo on black.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 20.0;
    float step = 0.5;
> = 0.0;
uniform float Halation_Strength<
    string label = "Strength";
    string group = "Halation";
    string tooltip = "How bright the halo is, in percent: the share of the light above the threshold that spreads into it.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 15.0;
uniform float Halation_Size<
    string label = "Size";
    string group = "Halation";
    string tooltip = "How far the halo reaches from a bright edge (to a tenth of its brightness at the edge), in pixels on a 1080-line picture.";
    string widget_type = "slider";
    float minimum = 2.0;
    float maximum = 120.0;
    float step = 0.5;
> = 30.0;
uniform float Halation_Threshold<
    string label = "Threshold";
    string group = "Halation";
    string tooltip = "How bright a part of the picture has to be to glow, in percent of white.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 99.0;
    float step = 1.0;
> = 70.0;
uniform float Softness<
    string label = "Softness";
    string group = "Softness";
    string tooltip = "How soft the film's picture is, in pixels on a 1080-line picture (a blur's standard deviation), all over: about 0.5 for 35mm, 1 for 16mm. The lens's softer corners are in Lens.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 1.0;
uniform float Grain<
    string label = "Amount";
    string group = "Grain";
    string tooltip = "How strong the grain is (as Film Grain's Amount).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 30.0;
uniform float Grain_Size<
    string label = "Grain Size";
    string group = "Grain";
    string tooltip = "Size of a grain, in pixels of a 1080-line picture.";
    string widget_type = "slider";
    float minimum = 1.0;
    float maximum = 6.0;
    float step = 0.05;
> = 2.4;
uniform float Grain_Colour<
    string label = "Colour";
    string group = "Grain";
    string tooltip = "0 gives black-and-white grain, as on most film; 100 gives each colour channel its own grain.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 25.0;
uniform float Grain_Shadows<
    string label = "Shadows";
    string group = "Grain";
    string tooltip = "Grain strength in the darkest parts, compared with the midtones (100).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 85.0;
uniform float Grain_Highlights<
    string label = "Highlights";
    string group = "Grain";
    string tooltip = "Grain strength in the brightest parts, compared with the midtones (100).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 0.1;
> = 30.0;
uniform float Dust<
    string label = "Dust";
    string group = "Dust & Scratches";
    string tooltip = "How many specks of dust or hair are on each frame, on average.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 16.0;
    float step = 0.05;
> = 0.5;
uniform float Speck_Size<
    string label = "Speck Size";
    string group = "Dust & Scratches";
    string tooltip = "How wide a typical speck is, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    float minimum = 2.0;
    float maximum = 24.0;
    float step = 0.5;
> = 5.0;
uniform float Light_Specks<
    string label = "Light Specks";
    string group = "Dust & Scratches";
    string tooltip = "The share of specks that are light (dirt on the negative), in percent; the rest are dark.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 25.0;
uniform float Dust_Strength<
    string label = "Strength";
    string group = "Dust & Scratches";
    string tooltip = "How visible each mark is, in percent.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 50.0;
uniform float Scratches<
    string label = "Scratches";
    string group = "Dust & Scratches";
    string tooltip = "How many scratches are on screen at once, on average (up to 3).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 0.0;

// The sRGB curve, both ways, carried on above 1.
float3 film_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 film_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

// Three uniform random numbers in [0, 1) for a point (hash by Dave Hoskins, MIT).
float3 film_hash(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// Grain: roughly Gaussian noise at a grain centre, and one layer of it with
// the four nearest centres blended smoothly (as Film Grain).
float3 film_grain_at(float2 cell, float seed)
{
    float3 sum = film_hash(float3(cell, seed)) + film_hash(float3(cell, seed + 17.0)) + film_hash(float3(cell, seed + 43.0));
    return (sum - 1.5) * 2.0;
}
float3 film_grain_layer(float2 p, float seed)
{
    float2 cell = floor(p);
    float2 f = p - cell;
    float2 u = f * f * (3.0 - 2.0 * f);
    float4 w = float4((1.0 - u.x) * (1.0 - u.y), u.x * (1.0 - u.y), (1.0 - u.x) * u.y, u.x * u.y);
    float3 n = w.x * film_grain_at(cell, seed) + w.y * film_grain_at(cell + float2(1.0, 0.0), seed)
             + w.z * film_grain_at(cell + float2(0.0, 1.0), seed) + w.w * film_grain_at(cell + float2(1.0, 1.0), seed);
    return n / sqrt(dot(w, w));
}

// The print, as Film Print, with every setting taken a of the way from
// neutral.
float3 film_print(float3 x, float a)
{
    x = max(x, 0.0);
    float3 xs = min(x, 1.0);
    float3 rgb = lerp(x, xs * xs * (3.0 - 2.0 * xs) + (x - xs), Contrast * 0.01 * a);
    float k = max(Roll_Off * 0.02 * a, 0.0001);
    rgb = (1.0 - exp(-k * rgb)) / (1.0 - exp(-k)) * lerp(1.0, White * 0.01, a);
    float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float3 stocked = rgb;
    if (Stock == 1)
        stocked = float3(l, l, l);
    else if (Stock == 2)
        stocked = l * lerp(float3(0.42, 0.28, 0.17), float3(1.0, 0.93, 0.80), saturate(l)) * float3(1.12, 1.03, 0.92);
    else if (Stock == 3)
        stocked = l * float3(1.0, 0.78, 0.45);
    else if (Stock == 4)
        stocked = l * float3(0.55, 0.72, 1.0);
    rgb = lerp(rgb, stocked, min(a, 1.0));
    l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = lerp(rgb, float3(l, l, l), min(Fade * 0.01 * a, 1.0));
    rgb *= lerp(float3(1.0, 1.0, 1.0), lerp(float3(1.0, 0.86, 0.70), float3(1.0, 0.95, 0.84), saturate(l)), min(Warmth * 0.01 * a, 1.0));
    rgb += (1.0 - min(rgb, 1.0)) * (Black_Lift * 0.01 * a) * float3(1.0, 0.85, 0.70);
    return rgb;
}

float4 mainImage(VertData v_in) : TARGET
{
    float a = Amount * 0.01;
    float2 px = v_in.uv / uv_pixel_interval;
    float scale = 1.0 / (uv_pixel_interval.y * 1080.0);
    float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    float3 lw = float3(0.2126, 0.7152, 0.0722);

    // The film's softness: a Gaussian from 24 points on a turned spiral (as
    // Lens Softness), in near-linear light, kept inside the picture.
    float4 c = image.Sample(textureSampler, v_in.uv);
    float sigma = Softness * a * scale;
    if (sigma >= 0.05) {
        float2 lo = min(v_in.uv, 0.5 * uv_pixel_interval);
        float2 hi = max(v_in.uv, 1.0 - 0.5 * uv_pixel_interval);
        float2 dir = float2(cos(turn), sin(turn));
        float2 reach = sigma * 3.0 * uv_pixel_interval;
        float3 sum = float3(0.0, 0.0, 0.0);
        float cover = 0.0;
        float total = 0.0;
        float w = 0.91051036;
        for (int i = 0; i < 24; i++) {
            float4 s = image.Sample(textureSampler, clamp(v_in.uv + dir * reach * sqrt((float(i) + 0.5) / 24.0), lo, hi));
            sum += w * s.rgb * s.rgb * s.a;
            cover += w * s.a;
            total += w;
            dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
            w *= 0.82902912;
        }
        c = cover > 0.0 ? float4(sqrt(max(sum / cover, 0.0)), cover / total) : float4(0.0, 0.0, 0.0, 0.0);
    }

    // The halo: a Gaussian blur of the light above the threshold, from 64
    // points on a turned spiral (as Halation), less the pixel's own share.
    float glow = 0.0;
    float strength = Halation_Strength * 0.01 * a;
    if (strength > 0.0) {
        float t = Halation_Threshold * 0.01;
        t = t <= 0.04045 ? t / 12.92 : pow((t + 0.055) / 1.055, 2.4);
        float2 reach = max(Halation_Size, 1.0) / 1.645 * scale * 3.2 * uv_pixel_interval;
        float2 dir = float2(cos(turn + 1.0), sin(turn + 1.0));
        float w = 0.96078944;
        for (int i = 0; i < 64; i++) {
            float4 s = image.Sample(textureSampler, v_in.uv + dir * reach * sqrt((float(i) + 0.5) / 64.0));
            float3 lin = s.rgb * (s.rgb * (s.rgb * 0.305306011 + 0.682171111) + 0.012522878);
            glow += w * s.a * max(dot(lin, lw) - t, 0.0);
            dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
            w *= 0.92311635;
        }
        glow /= 12.421987 * (1.0 - t);
        float own = c.a * max(dot(film_to_linear(c.rgb), lw) - t, 0.0) / (1.0 - t);
        glow = max(glow - own, 0.0) * strength;
    }

    // The print, then the halo added as light over it (red-orange on colour
    // stock, neutral on the others), with its own transparency.
    c.rgb = film_print(c.rgb, a);
    float3 h = (Stock == 0 ? float3(1.0, 0.13, 0.03) : float3(0.31, 0.31, 0.31)) * glow;
    float3 lit = film_to_linear(c.rgb) * c.a + h;
    float alpha = saturate(max(c.a, max(h.r, max(h.g, h.b))));
    if (alpha <= 0.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    c = float4(film_from_linear(lit / alpha), alpha);

    // The frame of film: grain and dust change Speed times a second.
    float frame_count = floor(elapsed_time * float(Speed));
    float frame = fmod(frame_count, 9973.0);
    float seed = rand_instance_f * 61.0;

    // Grain, as Film Grain: strongest in the midtones, finer than a pixel
    // averaged into one, a second turned layer for large grain.
    float grain_amount = Grain * a;
    if (grain_amount > 0.0) {
        float gseed = frame * 1.618 + seed;
        float cell_px = Grain_Size * scale;
        float fine = min(cell_px, 1.0);
        cell_px = max(cell_px, 1.0);
        float2 p = (px - 0.5) / cell_px;
        float3 n = film_grain_layer(p, gseed);
        float second = saturate(cell_px - 2.0);
        if (second > 0.0) {
            float2 q = float2(0.8660 * p.x - 0.5 * p.y, 0.5 * p.x + 0.8660 * p.y) + 0.37;
            n = (n + second * film_grain_layer(q, gseed + 101.0)) / sqrt(1.0 + second * second);
        }
        float3 gr = lerp(n.xxx, n, Grain_Colour * 0.01);
        float luma = dot(c.rgb, lw);
        float response = luma < 0.5 ? lerp(Grain_Shadows * 0.01, 1.0, smoothstep(0.0, 0.5, luma))
                                    : lerp(1.0, Grain_Highlights * 0.01, smoothstep(0.5, 1.0, luma));
        c.rgb = max(c.rgb + gr * (grain_amount * 0.0015 * response * fine), 0.0);
    }

    // Dust and scratches, as Dust & Scratches: light marks (positive) and
    // dark ones (negative), in pixels of a 1080-line picture.
    float marks = Dust_Strength * 0.01 * a;
    if (marks > 0.0 && (Dust > 0.0 || Scratches > 0.0)) {
        float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
        float2 p = v_in.uv * float2(1080.0 * aspect, 1080.0);
        float mark = 0.0;
        for (int i = 0; i < 16; i++) {
            float3 hh = film_hash(float3(frame, float(i), seed));
            if (hh.z * 16.0 >= Dust)
                continue;
            float3 g = film_hash(float3(frame, float(i) + 31.0, seed + 7.0));
            float3 k = film_hash(float3(frame, float(i) + 63.0, seed + 13.0));
            float size = Speck_Size * 0.5 * (0.45 + 1.65 * g.y * g.y);
            float2 shape = k.x < 0.125 ? float2(size * (4.0 + 6.0 * k.y), size * 0.35) : float2(size, size * (0.7 + 0.3 * k.y));
            float2 q = p - float2(hh.x * 1080.0 * aspect, hh.y * 1080.0);
            float extent = 1.5 * max(shape.x, shape.y);
            if (dot(q, q) > extent * extent)
                continue;
            float ang = g.x * 6.2831853;
            q = float2(cos(ang) * q.x + sin(ang) * q.y, -sin(ang) * q.x + cos(ang) * q.y);
            mark += (k.z * 100.0 < Light_Specks ? 1.0 : -1.0) * saturate(1.5 - length(q / shape));
        }
        float life_len = max(float(Speed) * 1.25, 1.0);
        for (int j = 0; j < 3; j++) {
            float offset = float(j) / 3.0;
            float life = floor(frame_count / life_len + offset);
            float3 hh = film_hash(float3(fmod(life, 9973.0), float(j) + 50.0, seed));
            if (hh.z * 3.0 >= Scratches)
                continue;
            float3 f = film_hash(float3(frame, float(j) + 70.0, seed));
            float age = frame_count / life_len + offset - life;
            float x = hh.x * 1080.0 * aspect + (f.x - 0.5) * 2.0 + (age - 0.5) * (hh.y - 0.5) * 30.0;
            float width = 0.6 + 1.2 * hh.y;
            float along = 0.6 + 0.4 * sin(p.y * 0.013 + hh.x * 40.0 + frame * 0.3);
            mark += saturate(1.0 - abs(p.x - x) / width) * along * (0.5 + 0.5 * f.y) * 0.8;
        }
        mark *= marks;
        float3 rgb = c.rgb * (1.0 - saturate(-mark));
        float light = max(mark, 0.0);
        float3 lit2 = rgb * c.a + float3(0.85, 0.82, 0.75) * light;
        float alpha2 = max(c.a, saturate(light));
        c = alpha2 > 0.0 ? float4(lit2 / alpha2, alpha2) : float4(0.0, 0.0, 0.0, 0.0);
    }
    return c;
}
