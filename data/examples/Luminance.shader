//Converted to OpenGL by Exeldro February 22, 2022
uniform float4 color< string tooltip = "Color multiplied with the original image to tint it. White means no tint."; >;
uniform float level<
    string label = "Level";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.01;
    string tooltip = "Transparency amount, where 1.0 is the base luminance. Recommended range is 0 to 10.";
> = 1.0;
uniform bool invertImageColor< string tooltip = "Inverts the colors of the image. Great for testing and fine tuning."; >;
uniform bool invertAlphaChannel< string tooltip = "Flips which areas become transparent, from darks (default) to lights."; >;

float4 InvertColor(float4 rgba_in)
{	
	rgba_in.r = 1.0 - rgba_in.r;
	rgba_in.g = 1.0 - rgba_in.g;
	rgba_in.b = 1.0 - rgba_in.b;
	rgba_in.a = 1.0 - rgba_in.a;
	return rgba_in;
}

float4 mainImage(VertData v_in) : TARGET
{

	float4 rgba = image.Sample(textureSampler, v_in.uv);
    if (rgba.a > 0.0)
    {
		
    if (invertImageColor)
    {
        rgba = InvertColor(rgba);
    }
    float intensity = rgba.r * color.r * 0.299 + rgba.g * color.g * 0.587 + rgba.b * color.b * 0.114;

    //intensity = min(max(intensity,minIntensity),maxIntensity);


    if (invertAlphaChannel)
    {
        intensity = 1.0 - intensity;
    }
    rgba *= color;
    rgba.a = clamp((intensity * level), 0.0, 1.0);
	
    }
	return rgba;
}
