// Edge Detection for OBS Studio
// originally from Andersama (https://github.com/Andersama)
// Modified and improved my Charles Fettinger (https://github.com/Oncorporation)  1/2019
//Converted to OpenGL by Q-mii & Exeldro March 8, 2022
uniform float sensitivity<
    string label = "Sensitivity";
    string tooltip = "Edge detection threshold. 0.01 detects the most edges; increasing it detects fewer edges.";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.001;
> = 0.05;
uniform bool invert_edge<
    string tooltip = "Flips which areas count as edges. Great for testing and fine-tuning the sensitivity.";
>;
uniform float4 edge_color<
    string tooltip = "Color that replaces the original image color on edges.";
> = {1.0,1.0,1.0,1.0};
uniform bool edge_multiply<
    string tooltip = "Multiplies the edge color with the original color to tint it instead of replacing it. White means no tint.";
>;
uniform float4 non_edge_color<
    string tooltip = "Color that replaces the original image color on non-edges.";
> = {0.0,0.0,0.0,0.0};
uniform bool non_edge_multiply<
    string tooltip = "Multiplies the non-edge color with the original color to tint it instead of replacing it. White means no tint.";
>;
uniform bool alpha_channel<
    string tooltip = "Uses an alpha channel to replace the original color with transparency.";
>;
uniform float alpha_level<
    string label = "Alpha level";
    string tooltip = "Transparency amount, where 1.0 is the base luminance (0.00 to 2.00 recommended).";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 100.0;
    float step = 1.0;
> = 100.0;
uniform bool alpha_invert<
    string tooltip = "Flips what becomes transparent, from darks (default) to lights.";
>;
uniform float rand_f;

float4 mainImage(VertData v_in) : TARGET
{
	float4 c = image.Sample(textureSampler, v_in.uv);
	
	 float s = 3;
     float hstep = uv_pixel_interval.x;
     float vstep = uv_pixel_interval.y;
	
	float offsetx = (hstep * s) / 2.0;
	float offsety = (vstep * s) / 2.0;
	
	float4 lum = float4(0.30, 0.59, 0.11, 1 );
	float samples[9];
	
	int index = 0;
	for(int i = 0; i < s; i++){
		for(int j = 0; j < s; j++){
			samples[index] = dot(image.Sample(textureSampler, float2(v_in.uv.x + (i * hstep) - offsetx, v_in.uv.y + (j * vstep) - offsety )), lum);
			index++;
		}
	}
	
	float vert = samples[2] + samples[8] + (2 * samples[5]) - samples[0] - (2 * samples[3]) - samples[6];
	float hori = samples[6] + (2 * samples[7]) + samples[8] - samples[0] - (2 * samples[1]) - samples[2];
	float4 col;
	
	float o = ((vert * vert) + (hori * hori));
	bool isEdge = o > sensitivity;
	if(invert_edge){
		isEdge = !isEdge;
	}
	if(isEdge) {
		col = edge_color;
		if(edge_multiply){
			col *= c;
		}
	} else {
		col = non_edge_color;
		if(non_edge_multiply){
			col *= c;
		}
	}

	if (alpha_invert) {
		lum = 1.0 - lum;
	}

	if(alpha_channel){
		if (edge_multiply && isEdge) {
			return clamp(lerp(c, col, alpha_level), 0.0, 1.0);
		}
		else {
			// use max instead of multiply
			return clamp(lerp(c, float4(max(c.r, col.r), max(c.g, col.g), max(c.b, col.b), 1.0), alpha_level), 0.0, 1.0);
		}
	} else {
		// col.a = col.a * alpha_level;
		return col;
	}
}
