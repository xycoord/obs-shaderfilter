// Density-Saturation-Hue Shader for OBS Shaderfilter
// Modified by CameraTim for use with obs-shaderfilter 12/2024 v.12

uniform string notes<
    string widget_type = "info";
> = "Density, saturation and hue adjustments per color range.";

uniform float density_r <
    string label = "Red Density";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Density of reds. Density reduces luminance.";
> = 0.0;

uniform float saturation_r <
    string label = "Red Sat";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Saturation of reds. It is increased subtractively to avoid grayish colors.";
> = 0.0;

uniform float hueShift_r <
    string label = "Red Hue Shift";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
> = 0.0;

uniform float density_y <
    string label = "Yellow Density";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Density of yellows. Density reduces luminance.";
> = 0.0;

uniform float saturation_y <
    string label = "Yellow Sat";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Saturation of yellows. It is increased subtractively to avoid grayish colors.";
> = 0.0;

uniform float hueShift_y <
    string label = "Yellow Hue Shift";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
> = 0.0;

uniform float density_g <
    string label = "Green Density";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Density of greens. Density reduces luminance.";
> = 0.0;

uniform float saturation_g <
    string label = "Green Sat";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Saturation of greens. It is increased subtractively to avoid grayish colors.";
> = 0.0;

uniform float hueShift_g <
    string label = "Green Hue Shift";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
> = 0.0;

uniform float density_c <
    string label = "Cyan Density";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Density of cyans. Density reduces luminance.";
> = 0.0;

uniform float saturation_c <
    string label = "Cyan Sat";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Saturation of cyans. It is increased subtractively to avoid grayish colors.";
> = 0.0;

uniform float hueShift_c <
    string label = "Cyan Hue Shift";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
> = 0.0;

uniform float density_b <
    string label = "Blue Density";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Density of blues. Density reduces luminance.";
> = 0.0;

uniform float saturation_b <
    string label = "Blue Sat";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Saturation of blues. It is increased subtractively to avoid grayish colors.";
> = 0.0;

uniform float hueShift_b <
    string label = "Blue Hue Shift";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
> = 0.0;

uniform float density_m <
    string label = "Magenta Density";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Density of magentas. Density reduces luminance.";
> = 0.0;

uniform float saturation_m <
    string label = "Magenta Sat";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Saturation of magentas. It is increased subtractively to avoid grayish colors.";
> = 0.0;

uniform float hueShift_m <
    string label = "Magenta Hue Shift";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
> = 0.0;

uniform float global_density < 
    string label = "Global Density";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Density of all colors. Density reduces luminance.";
> = 0.0;

uniform float global_saturation < 
    string label = "Global Sat";
    string widget_type = "slider";
    float minimum = -1.0;
    float maximum = 1.0;
    float step = 0.001;
    string tooltip = "Saturation of all colors. It is increased subtractively to avoid grayish colors.";
> = 0.0;

// Tetrahedral interpolation based on the ordering of the input color channels
float3 applyAdjustments(float3 p) {
    // Pre-calculate the flipped density values for each channel:
    float d_r = -(density_r + global_density);
    float d_y = -(density_y + global_density);
    float d_g = -(density_g + global_density);
    float d_c = -(density_c + global_density);
    float d_b = -(density_b + global_density);
    float d_m = -(density_m + global_density);
    
    // Compute the color vectors for each hue region using the flipped densities:
    float3 red = float3(
        1.0 + d_r,
        d_r - (saturation_r + global_saturation),
        d_r + hueShift_r - (saturation_r + global_saturation)
    );
    
    float3 yellow = float3(
        1.0 + hueShift_y + d_y,
        1.0 + d_y,
        d_y - (saturation_y + global_saturation)
    );
    
    float3 green = float3(
        d_g - (saturation_g + global_saturation),
        1.0 + d_g,
        d_g + hueShift_g - (saturation_g + global_saturation)
    );
    
    float3 cyan = float3(
        d_c - (saturation_c + global_saturation),
        1.0 + hueShift_c + d_c,
        1.0 + d_c
    );
    
    float3 blue = float3(
        d_b + hueShift_b - (saturation_b + global_saturation),
        d_b - (saturation_b + global_saturation),
        1.0 + d_b
    );
    
    float3 magenta = float3(
        1.0 + d_m,
        d_m - (saturation_m + global_saturation),
        1.0 + hueShift_m + d_m
    );
    
    // Define the black and white endpoints:
    float3 blk = float3(0.0, 0.0, 0.0);
    float3 wht = float3(1.0, 1.0, 1.0);
    
    float3 rgb;
    if (p.r > p.g) {
        if (p.g > p.b) {
            // p.r >= p.g >= p.b
            rgb = p.r * (red - blk) + blk + p.g * (yellow - red) + p.b * (wht - yellow);
        } else if (p.r > p.b) {
            // p.r >= p.b > p.g
            rgb = p.r * (red - blk) + blk + p.g * (wht - magenta) + p.b * (magenta - red);
        } else {
            // p.b >= p.r > p.g
            rgb = p.r * (magenta - blue) + p.g * (wht - magenta) + p.b * (blue - blk) + blk;
        }
    } else {
        if (p.b > p.g) {
            // p.b >= p.g >= p.r
            rgb = p.r * (wht - cyan) + p.g * (cyan - blue) + p.b * (blue - blk) + blk;
        } else if (p.b > p.r) {
            // p.g >= p.r and p.b > p.r
            rgb = p.r * (wht - cyan) + p.g * (green - blk) + blk + p.b * (cyan - green);
        } else {
            // p.g >= p.b >= p.r
            rgb = p.r * (yellow - green) + p.g * (green - blk) + blk + p.b * (wht - yellow);
        }
    }
    return clamp(rgb, 0.0, 1.0);
}

float4 mainImage(VertData v_in) : TARGET {
    float4 inputColor = image.Sample(textureSampler, v_in.uv);
    float3 adjustedColor = applyAdjustments(inputColor.rgb);
    return float4(adjustedColor, inputColor.a);
}
