shader_type canvas_item;
// Сторона бойца в «Схватке» (B-346): насыщенные цвета одежды (оранжевая каска и жилет подрядчика,
// синяя форма вахтёра …) перекрашиваются в цвет стороны; зелёное (штаны), кожа и кости не
// трогаются. Работает по текстуре, а не по modulate: Е, «Аврал» и предметы красят через
// modulate / self_modulate — принадлежность стороне они не стирают.
uniform float side_hue = 0.44;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	// В этой версии COLOR уже равен «текстура × цвет узла»: цвет узла (modulate, вспышки,
	// отлив Е) вынимаем делением по каналам и накладываем обратно после перекраски.
	vec4 t = texture(TEXTURE, UV);
	vec3 node = vec3(t.r > 0.04 ? COLOR.r / t.r : 1.0, t.g > 0.04 ? COLOR.g / t.g : 1.0,
		t.b > 0.04 ? COLOR.b / t.b : 1.0);
	vec3 h = rgb2hsv(t.rgb);
	float not_green = 1.0 - smoothstep(0.17, 0.21, h.x) * (1.0 - smoothstep(0.42, 0.46, h.x));
	float w = not_green * smoothstep(0.38, 0.5, h.y) * smoothstep(0.2, 0.32, h.z);
	vec3 body = mix(t.rgb, hsv2rgb(vec3(side_hue, h.y * 0.9, h.z)), w);
	COLOR = vec4(body * node, COLOR.a);
}
