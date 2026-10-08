shader_type canvas_item;
render_mode unshaded;
// Через ось продолжается та же земля, а не отражённые друг в друга мазки.
// Только подложка: стены, проёмы, дорога и предметы остаются зеркально честными.
uniform sampler2D ground_tex : source_color, filter_linear, repeat_disable;
uniform vec2 uv_scale;
uniform vec2 uv_offset;
uniform float middle = 800.0;
uniform float feather = 128.0;
varying vec2 world_pos;

void vertex() {
	world_pos = VERTEX;
}

void fragment() {
	vec2 uv = uv_offset + world_pos * uv_scale;
	float weight = 1.0 - smoothstep(0.0, feather, abs(world_pos.x - middle));
	COLOR = vec4(texture(ground_tex, uv).rgb, weight);
}
