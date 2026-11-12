// Remove Partial Pixels shader by Charles Fettinger for obs-shaderfilter plugin 8/2020
// https://github.com/Oncorporation/obs-shaderfilter
//Converted to OpenGL by Exeldro February 21, 2022
uniform int minimum_alpha_percent<
    string label = "minimum alpha percent";
    string tooltip = "Pixels less opaque than this are removed. The default is 50%; lower it to reveal more pixels.";
    string widget_type = "slider";
    int minimum = 0;
    int maximum = 100;
    int step = 1;
> = 50;
uniform string notes<
    string widget_type = "info";
> = "Removes partially transparent pixels. Excellent for cleaning up a green screen key.";

float4 mainImage(VertData v_in) : TARGET
{
    float min_alpha = clamp(minimum_alpha_percent * .01, -1.0, 101.0);
    float4 output_color = image.Sample(textureSampler, v_in.uv);
    if (output_color.a < min_alpha)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    else
    {
        return float4(output_color);
    }
}