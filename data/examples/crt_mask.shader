// CRT Mask for obs-shaderfilter: the pattern of red, green and blue
// phosphors a colour picture tube is made of. Behind a TV's glass the
// picture is coloured dots or stripes, each lit by its own beam: a shadow
// mask (dots in triangles, most TVs), an aperture grille (unbroken vertical
// stripes, Sony Trinitron) or a slot mask (stripes broken into short slots,
// many later TVs). From a distance it's a fine texture that takes a little
// light away.
//
// Pitch is the width of one complete red, green and blue set, in pixels on a
// 1080-line picture (scaled for other sizes): a real TV's is about 3. The
// pattern is drawn with smooth stripes, in whole pixels, never finer than
// 3, so it doesn't beat against the picture's pixels (it can against a
// projector's own scaling: show it at the projector's resolution). Strength
// is how much light the dark parts lose; the picture loses half that on
// average with the aperture grille, more with the dot and slot masks,
// which let less light through (it isn't brightened back, which would clip
// white). In light
// (linear); black stays black and transparency is kept. It only reads the
// pixel it draws, so it can be merged with neighbouring shader filters. It
// goes after CRT Scanlines and before CRT Glass.

uniform int Mask_Type<
    string label = "Type";
    string tooltip = "The tube's phosphor pattern: a shadow mask (dots in triangles, most TVs), an aperture grille (vertical stripes, Trinitron) or a slot mask (stripes in short slots).";
    string widget_type = "select";
    int option_0_value = 0;
    string option_0_label = "Shadow mask";
    int option_1_value = 1;
    string option_1_label = "Aperture grille";
    int option_2_value = 2;
    string option_2_label = "Slot mask";
> = 1;
uniform float Pitch<
    string label = "Pitch";
    string tooltip = "The width of one red, green and blue set, in whole pixels on a 1080-line picture: 3, the finest it draws, is about a TV's (around 600 sets across the picture); more is coarser than any TV. Whole pixels keep it from beating against the picture's pixels.";
    string widget_type = "slider";
    float minimum = 3.0;
    float maximum = 8.0;
    float step = 1.0;
> = 3.0;
uniform float Strength<
    string label = "Strength";
    string tooltip = "How much light the pattern's dark parts lose, in percent; the picture as a whole loses half this with the aperture grille, about two thirds with the slot mask and three quarters with the shadow mask. 10 to 20 is a texture, which at a distance only dims a little; past 40 it darkens and colours the picture.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 10.0;

// The sRGB curve, both ways, carried on above 1.
float3 mask_to_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4)), step(0.04045, c));
}
float3 mask_from_linear(float3 c)
{
    c = max(c, 0.0);
    return lerp(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);

    // This pixel's position in units of the pitch: Pitch on a 1080-line
    // picture, rounded to whole pixels of this one, at least 3.
    float p = max(floor(Pitch / (uv_pixel_interval.y * 1080.0) + 0.5), 3.0);
    float2 q = (floor(v_in.uv / uv_pixel_interval) + float2(0.0, 0.5)) / p;

    // How much of each colour's phosphor is here, from 0 to 1, smooth.
    float3 phase = float3(0.0, 1.0 / 3.0, 2.0 / 3.0);
    float3 g;
    if (Mask_Type == 0) {
        // Dots in triangles: rows 0.87 pitch apart (in whole pixels), each shifted half a
        // pitch from the last; each dot fades at its row's top and bottom.
        float rows = q.y * p / max(floor(0.866 * p + 0.5), 2.0);
        float row = floor(rows);
        float shift = fmod(row, 2.0) * 0.5;
        float3 across = 0.5 + 0.5 * cos(6.2831853 * (q.x + shift - phase));
        float down = 0.5 - 0.5 * cos(6.2831853 * (rows - row));
        g = across * down;
    } else if (Mask_Type == 2) {
        // Slots: stripes broken every 1.5 pitches (in whole pixels), alternate columns
        // shifted half a slot, the breaks shallow.
        float3 across = 0.5 + 0.5 * cos(6.2831853 * (q.x - phase));
        float column = floor(q.x);
        float down = 0.7 + 0.3 * cos(6.2831853 * (q.y * p / max(floor(1.5 * p + 0.5), 2.0) + fmod(column, 2.0) * 0.5));
        g = across * down;
    } else {
        // Unbroken vertical stripes.
        g = 0.5 + 0.5 * cos(6.2831853 * (q.x - phase));
    }

    // Light through the pattern: the dark parts lose Strength percent.
    float3 m = 1.0 - Strength * 0.01 * (1.0 - g);
    c.rgb = mask_from_linear(mask_to_linear(c.rgb) * m);
    return c;
}
