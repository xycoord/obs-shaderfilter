// Gamma Correction shader by Charles Fettinger for obs-shaderfilter plugin 4/2019
//https://github.com/Oncorporation/obs-shaderfilter

uniform float Red<
    string label = "Red";
    string tooltip = "Gamma for the red channel. Use equal Red, Green and Blue values for general gamma correction.";
    string widget_type = "slider";
    float minimum = 0.1;
    float maximum = 10.0;
    float step = 0.01;
> = 2.2;
uniform float Green<
    string label = "Green";
    string tooltip = "Gamma for the green channel. Use equal Red, Green and Blue values for general gamma correction.";
    string widget_type = "slider";
    float minimum = 0.1;
    float maximum = 10.0;
    float step = 0.01;
> = 2.2;
uniform float Blue<
    string label = "Blue";
    string tooltip = "Gamma for the blue channel. Use equal Red, Green and Blue values for general gamma correction.";
    string widget_type = "slider";
    float minimum = 0.1;
    float maximum = 10.0;
    float step = 0.01;
> = 2.2;

float4 mainImage(VertData v_in) : TARGET
{  
	float3 gammaRGB = float3(clamp(Red,0.1,10.0),clamp(Green,0.1,10.0),clamp(Blue,0.1,10.0));
	float4 c = image.Sample(textureSampler, v_in.uv);
		c.rgb = pow(c.rgb, 1.0 / gammaRGB);	
	return c;
}