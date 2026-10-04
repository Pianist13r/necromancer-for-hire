shader_type canvas_item;

void fragment() {
	// In Godot's canvas_item fragment stage COLOR already includes TEXTURE × modulate.
	vec4 sample_color = COLOR;
	float process_pixel = 1.0 - step(sample_color.a, 0.001);

	// Слегка смягчает холодный почти чёрный ink, не трогая оранжевые детали и альфа-силуэт.
	float luminance = dot(sample_color.rgb, vec3(0.2126, 0.7152, 0.0722));
	float dark_ink = 1.0 - smoothstep(0.045, 0.20, luminance);
	float cool_ink = smoothstep(0.008, 0.11, sample_color.b - sample_color.r);
	float ink_mask = dark_ink * cool_ink * 0.20;
	vec3 softened = mix(sample_color.rgb, vec3(0.17, 0.12, 0.105), ink_mask);

	// Очень лёгкая крупная вариация тона: около 9 px в кадре при ширине спрайта 90 px.
	vec2 cell = floor(UV * vec2(10.0, 8.0));
	float grain = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453) - 0.5;
	float material_mask = smoothstep(0.18, 0.58, luminance)
		* (1.0 - smoothstep(0.82, 0.98, luminance));
	softened *= 1.0 + grain * 0.025 * material_mask;
	COLOR = vec4(mix(sample_color.rgb, softened, process_pixel), sample_color.a);
}
