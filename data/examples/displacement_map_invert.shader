uniform string displacement_info<
  string label = "Displacement";
  string widget_type = "info";
> = "Displaces the Background Layer using the current image as a displacement map. Mid-gray rgb(.5, .5, .5) means no displacement.";

uniform float displacement_x<
  string label = "Displacement X (px)";
  string tooltip = "Maximum horizontal displacement in pixels. The red channel of the current image drives the horizontal shift.";
> = 16.0;

uniform float displacement_y<
  string label = "Displacement Y (px)";
  string tooltip = "Maximum vertical displacement in pixels. The green channel of the current image drives the vertical shift.";
> = 16.0;

uniform texture2d background_layer <string label = "Background Layer"; string tooltip = "The source that gets displaced by the current image.";>;

float4 mainImage(VertData v_in) : TARGET
{
    float4 map = image.Sample(textureSampler, v_in.uv);
		float4 base = background_layer.Sample(textureSampler, v_in.uv);

    float2 displace_strength = float2(displacement_x, displacement_y) / uv_size;
    float4 displace = float4(
      (map.r * 2) - 1,
      (map.g * 2) - 1,
      (map.b * 2) - 1,
      map.a
    );

    float2 displace_uv = float2(displace.r, displace.g) * displace_strength;
		float4 displaced = background_layer.Sample(textureSampler, v_in.uv + displace_uv);

    return float4(displaced.r, displaced.g, displaced.b, displaced.a * displace.a);
}
