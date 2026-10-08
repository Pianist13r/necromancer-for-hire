shader_type canvas_item;

uniform vec4 rim_color : source_color = vec4(0.06, 0.04, 0.09, 0.9);
uniform float width = 2.0;
varying vec4 modulation;

void vertex() {
	modulation = COLOR;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec2 d = TEXTURE_PIXEL_SIZE * width;
	float edge = max(max(texture(TEXTURE, UV + vec2(d.x, 0.0)).a,
		texture(TEXTURE, UV - vec2(d.x, 0.0)).a),
		max(texture(TEXTURE, UV + vec2(0.0, d.y)).a,
		texture(TEXTURE, UV - vec2(0.0, d.y)).a));
	float alpha = base.a + (1.0 - base.a) * edge * rim_color.a;
	vec3 rgb = mix(rim_color.rgb, base.rgb, base.a / max(alpha, 0.001));
	COLOR = vec4(rgb, alpha) * modulation;
}
