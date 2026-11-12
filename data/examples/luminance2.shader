//Converted to OpenGL by Q-mii & Exeldro February 25, 2022
uniform float4 color;
uniform float lumaMax<
    string label = "Luma Max";
    string tooltip = "Anything brighter than this becomes transparent.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.001;
> = 1.05;
uniform float lumaMin<
    string label = "Luma Min";
    string tooltip = "Anything darker than this becomes transparent.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.001;
> = 0.01;
uniform float lumaMaxSmooth<
    string label = "Luma Max Smooth";
    string tooltip = "Softens the Luma Max cutoff so the transparency fades in over this distance.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.001;
> = 0.10;
uniform float lumaMinSmooth<
    string label = "Luma Min Smooth";
    string tooltip = "Softens the Luma Min cutoff so the transparency fades in over this distance.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.001;
> = 0.01;
uniform bool invertImageColor<
    string tooltip = "Inverts the colors of the image.";
>;
uniform bool invertAlphaChannel<
    string tooltip = "Flips which areas are transparent, which is great for testing your settings.";
>;

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
    float luminance = rgba.r * color.r * 0.299 + rgba.g * color.g * 0.587 + rgba.b * color.b * 0.114;

	//intensity = min(max(intensity,minIntensity),maxIntensity);
    float clo = smoothstep(lumaMin, lumaMin + lumaMinSmooth, luminance);
    float chi = 1. - smoothstep(lumaMax - lumaMaxSmooth, lumaMax, luminance);

    float amask = clo * chi;

    if (invertAlphaChannel)
    {
        amask = 1.0 - amask;
    }
    rgba *= color;
    rgba.a = clamp(amask, 0.0, 1.0);
        
    }
	return rgba;
}
