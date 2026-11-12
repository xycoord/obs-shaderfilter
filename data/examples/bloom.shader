// Bloom shader by Charles Fettinger for obs-shaderfilter plugin 3/2019
//https://github.com/Oncorporation/obs-shaderfilter
//Converted to OpenGL by Exeldro February 15, 2022
uniform int Angle_Steps<
    string label = "Angle Steps";
    string widget_type = "slider";
    int minimum = 1;
    int maximum = 20;
    int step = 1;
    string tooltip = "Number of angle steps, limited to 1 - 20. Edit bloom.shader to remove the limit at your own risk.";
> = 5; //<range 1 - 20>
uniform int Radius_Steps<
    string label = "Radius Steps";
    string widget_type = "slider";
    int minimum = 0;
    int maximum = 20;
    int step = 1;
    string tooltip = "Number of radius steps, limited to 0 - 20. Edit bloom.shader to remove the limit at your own risk.";
> = 9; //<range 0 - 20>
uniform float ampFactor<
    string label = "amp Factor";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 10.0;
    float step = 0.01;
> = 2.0;

float4 mainImage(VertData v_in) : TARGET
{
	int radiusSteps = clamp(Radius_Steps, 0, 20);
	int angleSteps = clamp(Angle_Steps, 1, 20);
	float PI = 3.1415926535897932384626433832795;//acos(-1);
	float minRadius = (0.0 * uv_pixel_interval.y);
	float maxRadius = (10.0 * uv_pixel_interval.y);

	float4 c0 = image.Sample(textureSampler, v_in.uv);
	float4 outputPixel = c0;
	float4 accumulatedColor = float4(0,0,0,0);

	int totalSteps = radiusSteps * angleSteps;
	float angleDelta = (2.0 * PI) / float(angleSteps);
	float radiusDelta = (maxRadius - minRadius) / float(radiusSteps);

	// The first ring has radius 0: every angle reads the centre pixel, c0.
	float4 centreTerm = radiusSteps > 0 ? c0 / float(totalSteps) : float4(0,0,0,0);

	// Angles outside, radii inside: each direction's cos/sin is worked out once.
	for (float angle=0.0; angle <(2.0*PI); angle += angleDelta) {
		float2 direction = float2(cos(angle), sin(angle));
		accumulatedColor += centreTerm;

		for (int radiusStep = 1; radiusStep < radiusSteps; radiusStep++) {
			float radius = minRadius + float(radiusStep) * radiusDelta;
			float4 currentColor = image.Sample(textureSampler, v_in.uv + radius * direction);
			float currentFraction = float(radiusSteps+1 - radiusStep) / float(radiusSteps + 1);

			accumulatedColor +=   currentFraction * currentColor / float(totalSteps);
		}
	}

	outputPixel += accumulatedColor * ampFactor;

	return outputPixel;
}
