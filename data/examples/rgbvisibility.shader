// RGB visibility separation filter, created by EposVox

uniform float Red<
    string label = "Red";
    string tooltip = "Gamma correction for the red channel. Use equal Red, Green and Blue values for general correction.";
    string widget_type = "slider";
    float minimum = 0.1;
    float maximum = 10.0;
    float step = 0.01;
> = 2.2;

uniform float Green<
    string label = "Green";
    string tooltip = "Gamma correction for the green channel. Use equal Red, Green and Blue values for general correction.";
    string widget_type = "slider";
    float minimum = 0.1;
    float maximum = 10.0;
    float step = 0.01;
> = 2.2;

uniform float Blue<
    string label = "Blue";
    string tooltip = "Gamma correction for the blue channel. Use equal Red, Green and Blue values for general correction.";
    string widget_type = "slider";
    float minimum = 0.1;
    float maximum = 10.0;
    float step = 0.01;
> = 2.2;

uniform float RedVisibility<
    string label = "Red Visibility";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 1.0;

uniform float GreenVisibility<
    string label = "Green Visibility";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 1.0;

uniform float BlueVisibility<
    string label = "Blue Visibility";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 1.0;

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    float redChannel = pow(c.r, Red) * RedVisibility;
    float greenChannel = pow(c.g, Green) * GreenVisibility;
    float blueChannel = pow(c.b, Blue) * BlueVisibility;
    
    return float4(redChannel, greenChannel, blueChannel, c.a);
}
