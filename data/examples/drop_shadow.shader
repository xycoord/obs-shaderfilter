// Drop Shadow shader modified by Charles Fettinger 
// impose a limiter to keep from crashing the system
//Converted to OpenGL by Exeldro February 19, 2022
uniform int shadow_offset_x<
    string label = "Shadow offset x";
    string widget_type = "slider";
    int minimum = -100;
    int maximum = 100;
    int step = 1;
> = 5;
uniform int shadow_offset_y<
    string label = "Shadow offset y";
    string widget_type = "slider";
    int minimum = -100;
    int maximum = 100;
    int step = 1;
> = 5;
uniform int shadow_blur_size<
    string label = "Shadow blur size";
    string tooltip = "How soft the shadow edge is. Limited to a maximum of 15 to keep the GPU load manageable.";
    string widget_type = "slider";
    int minimum = 0;
    int maximum = 15;
    int step = 1;
> = 3;

uniform float4 shadow_color;

uniform bool is_alpha_premultiplied;

float4 mainImage(VertData v_in) : TARGET
{
    int shadow_blur_size_limited = max(0, min(15, shadow_blur_size));
    int shadow_blur_samples = int(pow(float(shadow_blur_size_limited * 2 + 1), 2.0));
    
    float4 color = image.Sample(textureSampler, v_in.uv);
    float2 shadow_uv = float2(v_in.uv.x - uv_pixel_interval.x * float(shadow_offset_x), 
                              v_in.uv.y - uv_pixel_interval.y * float(shadow_offset_y));
    
    // Box blur of the alpha over (2r+1) x (2r+1) pixels. The sampler filters
    // linearly, so a read halfway between pixels averages them: each read
    // covers a 2x2 block (weight 4), with single rows/columns (weight 2 or 1)
    // for the last offset +r. (r+1)^2 reads instead of (2r+1)^2.
    int r = shadow_blur_size_limited;
    float sampled_shadow_alpha = 0.0;

    for (int bx = 0; bx <= r; bx++)
    {
        float ox = bx < r ? float(2 * bx - r) + 0.5 : float(r);
        float wx = bx < r ? 2.0 : 1.0;
        for (int by = 0; by <= r; by++)
        {
            float oy = by < r ? float(2 * by - r) + 0.5 : float(r);
            float wy = by < r ? 2.0 : 1.0;
            float2 blur_uv = shadow_uv + uv_pixel_interval * float2(ox, oy);
            sampled_shadow_alpha += image.Sample(textureSampler, blur_uv).a * (wx * wy);
        }
    }
    sampled_shadow_alpha /= float(shadow_blur_samples);
    
    float4 final_shadow_color = float4(shadow_color.r, shadow_color.g, shadow_color.b, shadow_color.a * sampled_shadow_alpha);
    return final_shadow_color * (1.0-color.a) + color * (is_alpha_premultiplied?color.a:1.0);
}
