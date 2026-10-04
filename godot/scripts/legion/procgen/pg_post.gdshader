shader_type canvas_item;
// Обработка собранной картинки карты — один проход (BOOK.md §9, D-0927-71; линия art3,
// D-0927-210 «как предложил инстанс», прототип C:/AI/necro/assets/procgen/npr/).
// Читает сборку как обычную текстуру TEXTURE (не hint_screen_texture — во вложенном SubViewport
// тот давал выбеленный буфер, линия terrain) и карту зон mask_tex (PgArtMask):
//   1. слабый анизотропный Кувахара (Kyprianidis): эллипс вдоль структурного тензора, 8
//      секторов; ограды, предметы и кайма дороги — слабее (маска), чтобы не мылить детали;
//   2. перенос цвета по зонам в Lab (Рейнхард): земля / дорога / предметы — каждая к
//      статистике своей зоны на фонах кампании того же биома (zones_lab.json); вода — без
//      переноса; статистику сборки PgArt считает по кадру до этого прохода;
//   3. мягкое затемнение земли у подножий — по «карте расстояний» до оснований (канал B маски,
//      выборка по двум кольцам — приближение расстояния размытием), вместо Пуассона прототипа;
//   4. тон биома, виньетка, туман — как было.
// Lab — sRGB → линейный → XYZ D65 → Lab, та же формула, что tools/procgen_zone_lab.py и PgArt.

uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform vec3 biome_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.12;
uniform float vignette_edge : hint_range(0.0, 1.0) = 0.57;
uniform vec3 fog_color : source_color = vec3(0.75, 0.78, 0.85);
uniform float fog_strength : hint_range(0.0, 1.0) = 0.0;
uniform float preserve_ground_light = 0.0;

// 0 — земля, 1 — дорога, 2 — предметы
uniform vec3 src_mu[3];
uniform vec3 src_sd[3];
uniform vec3 ref_mu[3];
uniform vec3 ref_sd[3];
uniform vec3 zone_strength = vec3(0.0); // сила переноса по зонам; 0 — зоны нет (статистики не было)

uniform float kuw_radius = 3.0;        // px картинки
uniform float kuw_strength = 0.45;     // земля и полотно
uniform float kuw_protect = 0.75;      // доля ослабления на предметах и кайме
uniform float kuw_q = 8.0;

uniform float foot_strength = 0.22;    // затемнение земли у самого основания
uniform float foot_r1 = 0.0055;        // радиусы выборки маски, доли ширины кадра
uniform float foot_r2 = 0.0115;
uniform vec2 foot_bias = vec2(-0.0015, -0.0025); // свет сверху слева — тень гуще справа-снизу

const int SECTORS = 8;

vec3 to_lin(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

float lab_f(float t) {
	return t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0;
}

float lab_fi(float t) {
	return t > 0.206893 ? t * t * t : (t - 16.0 / 116.0) / 7.787;
}

vec3 rgb2lab(vec3 rgb) {
	vec3 l = to_lin(rgb);
	vec3 xyz = vec3(
		dot(l, vec3(0.4124564, 0.3575761, 0.1804375)) / 0.95047,
		dot(l, vec3(0.2126729, 0.7151522, 0.0721750)),
		dot(l, vec3(0.0193339, 0.1191920, 0.9503041)) / 1.08883);
	float fx = lab_f(xyz.x);
	float fy = lab_f(xyz.y);
	float fz = lab_f(xyz.z);
	return vec3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz));
}

vec3 lab2rgb(vec3 lab) {
	float fy = (lab.x + 16.0) / 116.0;
	float fx = fy + lab.y / 500.0;
	float fz = fy - lab.z / 200.0;
	vec3 xyz = vec3(lab_fi(fx) * 0.95047, lab_fi(fy), lab_fi(fz) * 1.08883);
	vec3 l = vec3(
		dot(xyz, vec3(3.2404542, -1.5371385, -0.4985314)),
		dot(xyz, vec3(-0.9692660, 1.8760108, 0.0415560)),
		dot(xyz, vec3(0.0556434, -0.2040259, 1.0572252)));
	return clamp(to_srgb(l), 0.0, 1.0);
}

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// Анизотропный Кувахара в одном проходе: тензор — Собель по яркости с шагом 2 px (ловит
// крупную структуру, а не шум фактуры), эллипс вдоль изолиний, секторы по 3 выборки.
vec3 kuwahara(sampler2D tex, vec2 uv, vec2 px) {
	float tl = luma(texture(tex, uv + px * vec2(-2.0, -2.0)).rgb);
	float tc = luma(texture(tex, uv + px * vec2(0.0, -2.0)).rgb);
	float tr = luma(texture(tex, uv + px * vec2(2.0, -2.0)).rgb);
	float ml = luma(texture(tex, uv + px * vec2(-2.0, 0.0)).rgb);
	float mr = luma(texture(tex, uv + px * vec2(2.0, 0.0)).rgb);
	float bl = luma(texture(tex, uv + px * vec2(-2.0, 2.0)).rgb);
	float bc = luma(texture(tex, uv + px * vec2(0.0, 2.0)).rgb);
	float br = luma(texture(tex, uv + px * vec2(2.0, 2.0)).rgb);
	float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
	float gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
	float e = gx * gx;
	float f = gx * gy;
	float g = gy * gy;
	float root = sqrt((e - g) * (e - g) + 4.0 * f * f);
	float l1 = 0.5 * (e + g + root);
	float l2 = 0.5 * (e + g - root);
	vec2 t = vec2(l1 - e, -f);
	t = length(t) > 1e-6 ? normalize(t) : vec2(1.0, 0.0);
	float an = (l1 + l2) > 1e-6 ? (l1 - l2) / (l1 + l2) : 0.0;
	float a = kuw_radius * (1.0 + an);
	float b = kuw_radius / (1.0 + an);
	vec2 ax = t * a;
	vec2 ay = vec2(-t.y, t.x) * b;
	vec3 c0 = texture(tex, uv).rgb;
	vec3 num = vec3(0.0);
	float den = 0.0;
	for (int k = 0; k < SECTORS; k++) {
		vec3 m = c0;
		vec3 q = c0 * c0;
		for (int j = 0; j < 3; j++) {
			float ang = (float(k) + (float(j) - 1.0) * 0.3) * 6.2831853 / float(SECTORS);
			float r = j == 1 ? 0.95 : 0.6;
			vec2 off = ax * cos(ang) * r + ay * sin(ang) * r;
			vec3 c = texture(tex, uv + off * px).rgb;
			m += c;
			q += c * c;
		}
		m /= 4.0;
		vec3 v = max(q / 4.0 - m * m, vec3(0.0));
		float sd = sqrt(v.r + v.g + v.b) * 255.0;
		float w = 1.0 / (1.0 + pow(sd, kuw_q * 0.25));
		num += m * w;
		den += w;
	}
	return num / max(den, 1e-6);
}

vec3 transfer(vec3 lab, int z) {
	return (lab - src_mu[z]) / max(src_sd[z], vec3(0.5)) * ref_sd[z] + ref_mu[z];
}

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec3 original = texture(TEXTURE, UV).rgb;
	vec4 m = texture(mask_tex, UV);
	float w_item = smoothstep(0.3, 0.7, m.g);
	float w_road = (1.0 - w_item) * smoothstep(0.62, 0.72, m.r);
	float w_water = (1.0 - w_item) * (1.0 - w_road)
		* smoothstep(0.3, 0.42, m.r) * (1.0 - smoothstep(0.58, 0.7, m.r));
	float w_ground = max(0.0, 1.0 - w_item - w_road - w_water);
	float kerb = w_road * (1.0 - smoothstep(0.82, 0.95, m.r));

	// 1. Кувахара — по исходной сборке (перенос цвета поточечный, порядок почти не важен)
	float protect = max(w_item, kerb);
	float ks = kuw_strength * (1.0 - kuw_protect * protect);
	vec3 col = mix(original, kuwahara(TEXTURE, UV, px), ks);

	// 2. перенос цвета по зонам
	vec3 lab = rgb2lab(col);
	vec3 d = vec3(0.0);
	d += w_ground * zone_strength.x * (transfer(lab, 0) - lab);
	d += w_road * zone_strength.y * (transfer(lab, 1) - lab);
	d += w_item * zone_strength.z * (transfer(lab, 2) - lab);
	lab += d;
	lab.x = clamp(lab.x, 0.0, 100.0);
	col = lab2rgb(lab);

	// 3. затемнение у подножий
	vec2 asp = vec2(1.0, 1280.0 / 720.0);
	float occ = 0.0;
	for (int i = 0; i < 8; i++) {
		vec2 dir = vec2(cos(float(i) * 0.785398), sin(float(i) * 0.785398)) * asp;
		occ += texture(mask_tex, UV + foot_bias * asp + dir * foot_r1).b;
		occ += 0.6 * texture(mask_tex, UV + foot_bias * asp + dir * foot_r2).b;
	}
	occ /= 12.8;
	float foot = foot_strength * smoothstep(0.03, 0.55, occ) * w_ground * (1.0 - m.b);
	col *= 1.0 - foot;

	// 4. тон биома, виньетка, туман
	col = mix(col, col * biome_tint, tint_strength);
	vec2 c = UV - 0.5;
	float dist = length(c * vec2(1.0, 0.5625)) * 2.0;
	col *= mix(1.0, vignette_edge, smoothstep(0.30, 1.05, dist));
	col = mix(col, fog_color, fog_strength * smoothstep(0.15, 1.0, dist));
	// Подложка уже освещена: переносим оттенок, сохраняя локальную светлоту земли.
	// Контактная тень остаётся отдельным затемнением у подножий.
	vec3 kept_light = col * luma(original) * (1.0 - foot) / max(luma(col), 0.001);
	col = mix(col, kept_light, preserve_ground_light * w_ground);
	COLOR = vec4(col, 1.0);
}
