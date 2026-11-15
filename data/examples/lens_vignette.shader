// Lens Vignette for obs-shaderfilter: a projector lens's falloff in
// brightness towards the corners of the picture. Light reaching the screen at
// an angle to the lens's axis is spread thinner and passes the lens's
// aperture at a slant, so the picture is darker the further from the middle:
// by the cos^4 law, the fourth power of the cosine of that angle. A projector
// lens loses about 10 to 30% of its light in the corners, a small 16mm or
// Super 8 projector more.
//
// One setting, the share of light lost in the corners. The middle is
// untouched and it falls off smoothly to the corners, multiplying light as a
// lens does (in linear light), so black stays black and nothing is clipped.
// Unlike Vignette, it only ever darkens, and doesn't change transparency. It
// only reads the pixel it draws, so it can be merged with neighbouring shader
// filters. It goes last in a film look, with Lens Chromatic Aberration.

uniform float Corner_Falloff<
    string label = "Corner Falloff";
    string tooltip = "How much of the light is lost in the corners, in percent: none in the middle, falling off smoothly. 15 for a cinema's lens, 25 for 16mm, 40 or more for an old or small projector.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 80.0;
    float step = 1.0;
> = 25.0;

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);

    // Distance from the middle, squared, in the picture's proportions.
    float aspect = uv_pixel_interval.y / uv_pixel_interval.x;
    float2 d = (v_in.uv - 0.5) * float2(aspect, 1.0);
    float corner = (aspect * aspect + 1.0) * 0.25;

    // cos^4 of the angle off the lens's axis is 1 / (1 + tan^2)^2, with tan^2
    // proportional to the distance squared, scaled so the corners lose
    // Corner_Falloff percent.
    float k = (1.0 / sqrt(1.0 - Corner_Falloff * 0.01) - 1.0) / corner;
    float q = 1.0 + k * dot(d, d);

    // Light multiplied in linear light: on the sRGB-encoded picture, nearly
    // the same as multiplying by its power 1/2.2.
    c.rgb *= pow(1.0 / (q * q), 1.0 / 2.2);
    return c;
}
