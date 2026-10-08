shader_type canvas_item;
render_mode unshaded, blend_mul;

// Multiply без screen_texture: ни копирования кадра, ни чтения back buffer.
uniform vec4 biome_tone : source_color = vec4(1.0, 0.97, 0.94, 1.0);
uniform float vignette : hint_range(0.0, 0.4) = 0.16;
uniform float grain : hint_range(0.0, 0.02) = 0.0;

void fragment() {
	vec2 p = (UV - vec2(0.5)) * vec2(1.2, 1.0);
	float edge = smoothstep(0.20, 0.72, length(p));
	float noise = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	vec3 tone = biome_tone.rgb * (1.0 - edge * edge * vignette);
	COLOR = vec4(tone * (1.0 - noise * grain), 1.0);
}
