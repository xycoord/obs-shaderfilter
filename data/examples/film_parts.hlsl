// The film's own effects, shared by Film and Film Look (included by them; not
// a shader on its own): the print's tone and colour, halation, the film's
// softness, grain, and dust and scratches. Each is a section with a tick to
// switch it off. A shader including this declares Speed (frames a second).
// See Film for what each does.

uniform bool Print_On<
#ifdef FILM_LOOK
    string label = "Film · Print (tone and colour)";
#else
    string label = "Print (tone and colour)";
#endif
    string widget_type = "section";
    string group = "Print";
    string tooltip = "The print's tone and colour: its contrast, how it fades, how warm the light is, and its stock (colour, black and white, sepia, tinted).";
> = true;
uniform int Stock<
    string from = "halation:Film";
    string label = "Film Type";
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
uniform int Warmth<
    string label = "Warmth";
    string group = "Print";
    string tooltip = "How warm the projector's light is: 0 neutral, 100 a tungsten lamp.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 50;
uniform int Fade<
    string label = "Fade";
    string group = "Print";
    string tooltip = "How much colour has faded out of the print.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 15;
uniform int Contrast<
    string label = "Contrast";
    string group = "Print";
    string show = "more";
    string tooltip = "How strong the print's S-curve is: shadows pressed down and midtones filled out.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 35;
uniform int White<
    string label = "White Level";
    string group = "Print";
    string show = "more";
    string tooltip = "How bright white is: the brightest parts roll off into it.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 70;
    int maximum = 100;
    int step = 1;
> = 97;
uniform int Roll_Off<
    string label = "Highlight Softening";
    string group = "Print";
    string show = "more";
    string tooltip = "How softly the brightest parts roll off into White: 0 is a straight line up to White.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 40;
uniform int Black_Lift<
    string label = "Lifted Blacks";
    string group = "Print";
    string show = "more";
    string tooltip = "How far black is lifted. It lifts black everywhere, which shows a projector's own picture edge on the wall: leave it at 0 for a logo on black.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 20;
    int step = 1;
> = 0;
uniform float Softness<
    string label = "Picture Softness";
    string group = "Print";
    string show = "more";
    string tooltip = "How soft the film's picture is all over, in pixels on a 1080-line picture (a blur's standard deviation): about 0.5 for 35mm, 1 for 16mm. The lens's softer corners are in Lens.";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 0.8;
uniform bool Halation_On<
#ifdef FILM_LOOK
    string label = "Film · Halation (glow round bright parts)";
#else
    string label = "Halation (glow round bright parts)";
#endif
    string widget_type = "section";
    string group = "Halation";
    string tooltip = "The red-orange glow film gives round bright parts, from light scattering back through it.";
> = true;
uniform int Halation_Strength<
    string from = "halation:Strength";
    string label = "Glow";
    string group = "Halation";
    string tooltip = "How bright the glow is: the share of the light above the threshold that spreads into it.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 11;
uniform int Halation_Size<
    string from = "halation:Size";
    string label = "Glow Size";
    string group = "Halation";
    string show = "more";
    string tooltip = "How far the glow reaches from a bright edge (to a tenth of its brightness at the edge), in pixels on a 1080-line picture.";
    string widget_type = "slider";
    string suffix = " px";
    int minimum = 2;
    int maximum = 120;
    int step = 1;
> = 22;
uniform int Halation_Threshold<
    string from = "halation:Threshold";
    string label = "Glows Above";
    string group = "Halation";
    string show = "more";
    string tooltip = "How bright a part of the picture has to be to glow, in percent of white.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 99;
    int step = 1;
> = 80;
uniform bool Grain_On<
#ifdef FILM_LOOK
    string label = "Film · Grain (texture)";
#else
    string label = "Grain (texture)";
#endif
    string widget_type = "section";
    string group = "Grain";
    string tooltip = "The film's grain, moving every frame.";
> = true;
uniform int Grain<
    string from = "film_grain:Amount";
    string label = "Strength";
    string group = "Grain";
    string tooltip = "How strong the grain is (as Film Grain's Strength).";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 23;
uniform float Grain_Size<
    string label = "Grain Size";
    string group = "Grain";
    string show = "more";
    string tooltip = "Size of a grain, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    string suffix = " px";
    float minimum = 1.0;
    float maximum = 6.0;
    float step = 0.05;
> = 1.9;
uniform int Grain_Colour<
    string from = "film_grain:Color_Amount";
    string label = "Colour Grain";
    string group = "Grain";
    string show = "more";
    string tooltip = "0 gives black-and-white grain, as on most film; 100 gives each colour channel its own grain.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 10;
uniform int Grain_Shadows<
    string from = "film_grain:Shadows";
    string label = "In Shadows";
    string group = "Grain";
    string show = "more";
    string tooltip = "Grain strength in the darkest parts, compared with the midtones (100). It always fades out just above black, so black stays black.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 70;
uniform int Grain_Highlights<
    string from = "film_grain:Highlights";
    string label = "In Highlights";
    string group = "Grain";
    string show = "more";
    string tooltip = "Grain strength in the brightest parts, compared with the midtones (100).";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 30;
uniform bool Dust_On<
#ifdef FILM_LOOK
    string label = "Film · Dust & Scratches (specks and lines)";
#else
    string label = "Dust & Scratches (specks and lines)";
#endif
    string widget_type = "section";
    string group = "Dust & Scratches";
    string tooltip = "Specks of dust and hair, and scratches, on the film.";
> = true;
uniform float Dust<
    string label = "Dust";
    string group = "Dust & Scratches";
    string tooltip = "How many specks of dust or hair are on each frame, on average.";
    string widget_type = "slider";
    string suffix = " per frame";
    float minimum = 0.0;
    float maximum = 16.0;
    float step = 0.05;
> = 0.5;
uniform float Scratches<
    string label = "Scratches";
    string group = "Dust & Scratches";
    string tooltip = "How many scratches are on screen at once, on average (up to 3).";
    string widget_type = "slider";
    string suffix = " at once";
    float minimum = 0.0;
    float maximum = 3.0;
    float step = 0.05;
> = 0.0;
uniform int Speck_Size<
    string label = "Speck Size";
    string group = "Dust & Scratches";
    string show = "more";
    string tooltip = "How wide a typical speck is, in pixels on a 1080-line picture.";
    string widget_type = "slider";
    string suffix = " px";
    int minimum = 2;
    int maximum = 24;
    int step = 1;
> = 5;
uniform int Light_Specks<
    string label = "White Specks";
    string group = "Dust & Scratches";
    string show = "more";
    string tooltip = "The share of specks that are light (dirt on the negative); the rest are dark.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 25;
uniform int Dust_Strength<
    string from = "dust_scratches:Strength";
    string label = "Visibility";
    string group = "Dust & Scratches";
    string show = "more";
    string tooltip = "How visible each mark is.";
    string widget_type = "slider";
    string suffix = " %";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 50;

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
    // The S-curve, blended in up to its full strength, then (above 100%, at
    // Amount over 100) blended towards the curve applied twice, so stronger
    // contrast steepens the curve rather than pushing shadows below black.
    float cs = float(Contrast) * 0.01 * a;
    float3 s1 = xs * xs * (3.0 - 2.0 * xs) + (x - xs);
    float3 s1c = min(s1, 1.0);
    float3 s2 = s1c * s1c * (3.0 - 2.0 * s1c) + (s1 - s1c);
    float3 rgb = cs <= 1.0 ? lerp(x, s1, cs) : lerp(s1, s2, min(cs - 1.0, 1.0));
    float k = max(float(Roll_Off) * 0.02 * a, 0.0001);
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
    rgb = lerp(rgb, float3(l, l, l), min(float(Fade) * 0.01 * a, 1.0));
    rgb *= lerp(float3(1.0, 1.0, 1.0), lerp(float3(1.0, 0.86, 0.70), float3(1.0, 0.95, 0.84), saturate(l)), min(float(Warmth) * 0.01 * a, 1.0));
    rgb += (1.0 - min(rgb, 1.0)) * (Black_Lift * 0.01 * a) * float3(1.0, 0.85, 0.70);
    return rgb;
}

// The film at uv (the picture's own coordinates: a weaving projector passes
// them moved, so everything here moves with the picture), with every effect
// a of the way from none. frame_count is the frame of film being shown.
float4 film_at(float2 uv, float a, float frame_count)
{
    float a_print = Print_On ? a : 0.0;
    float2 px = uv / uv_pixel_interval;
    float scale = 1.0 / (uv_pixel_interval.y * 1080.0);
    float turn = 6.2831853 * frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
    float3 lw = float3(0.2126, 0.7152, 0.0722);

    // The film's softness: a Gaussian from points on a turned spiral (as Lens
    // Softness: 24, 48 wider than 2 pixels, 96 wider than 5), in near-linear
    // light, kept inside the picture.
    float4 raw = image.Sample(textureSampler, uv);
    float4 c = raw;
    float sigma = Softness * a_print * scale;
    if (sigma >= 0.05) {
        float2 lo = min(uv, 0.5 * uv_pixel_interval);
        float2 hi = max(uv, 1.0 - 0.5 * uv_pixel_interval);
        float2 dir = float2(cos(turn), sin(turn));
        float2 reach = sigma * 3.0 * uv_pixel_interval;
        float3 sum = float3(0.0, 0.0, 0.0);
        float cover = 0.0;
        float total = 0.0;
        int n = sigma > 5.0 ? 96 : (sigma > 2.0 ? 48 : 24);
        float step_w = exp(-4.5 / float(n));
        float w = sqrt(step_w);
        for (int i = 0; i < n; i++) {
            float4 s = image.Sample(textureSampler, clamp(uv + dir * reach * sqrt((float(i) + 0.5) / float(n)), lo, hi));
            sum += w * s.rgb * s.rgb * s.a;
            cover += w * s.a;
            total += w;
            dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
            w *= step_w;
        }
        c = cover > 0.0 ? float4(sqrt(max(sum / cover, 0.0)), cover / total) : float4(0.0, 0.0, 0.0, 0.0);
    }

    // The halo: a Gaussian blur of the light above the threshold, from 64
    // points on a turned spiral (as Halation), less the pixel's own share.
    float glow = 0.0;
    float strength = Halation_On ? float(Halation_Strength) * 0.01 * a : 0.0;
    if (strength > 0.0) {
        float t = float(Halation_Threshold) * 0.01;
        t = t <= 0.04045 ? t / 12.92 : pow((t + 0.055) / 1.055, 2.4);
        float2 reach = max(Halation_Size, 1.0) / 1.645 * scale * 3.2 * uv_pixel_interval;
        float2 dir = float2(cos(turn + 1.0), sin(turn + 1.0));
        float w = 0.96078944;
        for (int i = 0; i < 64; i++) {
            float4 s = image.Sample(textureSampler, uv + dir * reach * sqrt((float(i) + 0.5) / 64.0));
            float3 lin = s.rgb * (s.rgb * (s.rgb * 0.305306011 + 0.682171111) + 0.012522878);
            glow += w * s.a * max(dot(lin, lw) - t, 0.0);
            dir = float2(dir.x * -0.73736886 - dir.y * 0.67549032, dir.x * 0.67549032 + dir.y * -0.73736886);
            w *= 0.92311635;
        }
        glow /= 12.421987 * (1.0 - t);
        // (The pixel's own share from the unsoftened pixel, as the samples
        // are, so a softened bright edge doesn't let the halo in.)
        float3 raw_lin = raw.rgb * (raw.rgb * (raw.rgb * 0.305306011 + 0.682171111) + 0.012522878);
        float own = raw.a * max(dot(raw_lin, lw) - t, 0.0) / (1.0 - t);
        glow = max(glow - own, 0.0) * strength;
    }

    // The print, then the halo added as light over it (red-orange on colour
    // stock, neutral on the others), with its own transparency.
    if (a_print > 0.0)
        c.rgb = film_print(c.rgb, a_print);
    if (glow > 0.0) {
        int stock = Print_On ? Stock : 0;
        float3 h = (stock == 0 ? float3(1.0, 0.13, 0.03) : float3(0.31, 0.31, 0.31)) * glow;
        float3 lit = film_to_linear(c.rgb) * c.a + h;
        float alpha = saturate(max(c.a, max(h.r, max(h.g, h.b))));
        c = alpha > 0.0 ? float4(film_from_linear(lit / alpha), alpha) : float4(0.0, 0.0, 0.0, 0.0);
    }

    float frame = fmod(frame_count, 9973.0);
    float seed = rand_instance_f * 61.0;

    // Grain, as Film Grain: strongest in the midtones, finer than a pixel
    // averaged into one, a second turned layer for large grain.
    float grain_amount = Grain_On ? Grain * a : 0.0;
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
        float3 gr = lerp(n.xxx, n, float(Grain_Colour) * 0.01);
        float luma = dot(c.rgb, lw);
        float response = luma < 0.5 ? lerp(float(Grain_Shadows) * 0.01, 1.0, smoothstep(0.0, 0.5, luma))
                                    : lerp(1.0, float(Grain_Highlights) * 0.01, smoothstep(0.5, 1.0, luma));
        // Fading to nothing below about 3% brightness, so black stays black.
        response *= smoothstep(0.005, 0.03, luma);
        c.rgb = max(c.rgb + gr * (grain_amount * 0.0015 * response * fine), 0.0);
    }

    // Dust and scratches, as Dust & Scratches: light marks (positive) and
    // dark ones (negative), in pixels of a 1080-line picture.
    float marks = Dust_On ? float(Dust_Strength) * 0.01 * a : 0.0;
    if (marks > 0.0 && (Dust > 0.0 || Scratches > 0.0)) {
        float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
        float2 p = uv * float2(1080.0 * aspect, 1080.0);
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
            mark += (k.z * 100.0 < float(Light_Specks) ? 1.0 : -1.0) * saturate(1.5 - length(q / shape));
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
