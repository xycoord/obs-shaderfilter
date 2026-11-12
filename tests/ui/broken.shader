// A shader that never compiles, for the UI scenario of a failing shader.
uniform float strength<
    string label = "Strength";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 0.5;

float4 mainImage(VertData v_in) : TARGET
{
    return image.Sample(textureSampler, v_in.uv) * undefined_variable;
}
