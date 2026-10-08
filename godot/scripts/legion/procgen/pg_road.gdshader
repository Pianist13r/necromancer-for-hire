shader_type canvas_item;
// Полотно дороги сборки процедурной карты (PgArtRoad, линия art3; «вписать в землю» — road-1003).
// Полоса-лента вдоль оси: UV.x — длина пути в периодах тайла (растёт непрерывно и на поворотах,
// текстура не рвётся), UV.y — поперёк 0…1. Фактура — вырезка настоящей нарисованной дороги из
// фонов кампании (tools/procgen_road_tiles.py). Здесь:
//   1. неровный «съеденный» край: порог альфы поперёк сдвигается шумом трёх масштабов по длине,
//      и редкими выщербинами — сквозь них видна земля подложки и тень края (RoadShade), а не
//      ровная кайма линейкой (траву и камешки на край кладёт PgArtScatter.build_edge);
//   2. второй проход «только полотно» (core_only) — на развилках и слияниях середина одной
//      дороги ложится поверх каймы другой, и кайма не перечёркивает перекрёсток;
//   3. светлота — от ЛОКАЛЬНОЙ земли (подложка ground_tex под дорогой, размытая кольцом выборок):
//      ×ratio к земле в коридоре (BOOK §8.2 п.2 — ×1,4 и выше, дорога читается), без «засветки»
//      на тёмных биомах; оттенок полотна частично берёт оттенок той же земли (cast_k) — дорога
//      той же краски, что земля вокруг, а не одинаковая кремовая лента во всех биомах;
//   4. нарисованный тёмный контур вырезки смягчён к тёмному тону земли (contour_soft): чёрная
//      обводка по всей длине делала ленту наклейкой;
//   5. износ: пятна грязи цветом земли (fbm), две колеи, лёгкое зерно, затемнение к краю;
//   6. две вырезки (B-170): вторая (tex_b) сменяет первую по длине пути кусками по гладкому
//      шуму — повтор одного тайла на длинной прямой перестаёт читаться.
// Альфа концов (плавный конец у Котла) приходит цветом вершин.

uniform float brightness = 1.0; // запасной множитель, когда подложки нет (use_ground = 0)
uniform float period_world = 160.0;
uniform float width_world = 56.0;
uniform float edge_amp = 0.14;
uniform float edge_freq = 0.045;
uniform float edge_soft = 0.05;
uniform float bite_amp = 0.06;   // редкие выщербины края, доля полуширины
uniform float core_only = 0.0;
uniform float core_half = 0.52;
uniform float core_soft = 0.10;
uniform sampler2D tex_b : source_color, repeat_enable, filter_linear;
uniform float use_b = 0.0;
uniform float period_b_world = 160.0;
uniform float swap_len = 260.0; // мира px: характерная длина куска одной вырезки
uniform float swap_soft = 0.22;
uniform float phase = 0.0; // сдвиг шума по дороге: у разных дорог — разный рисунок

// земля подложки: мир → UV подложки (одиночка — мир/размер; поле PvP — вырезка и зеркало)
uniform sampler2D ground_tex : source_color, filter_linear, repeat_disable;
uniform float use_ground = 0.0;
uniform vec2 g_scale = vec2(0.00078125, 0.00138889);
uniform vec2 g_off = vec2(0.0);
uniform float g_mirror = 0.0; // ширина зеркального поля PvP; 0 — одиночка
uniform float land_r = 34.0;  // мира px: радиус кольца выборок «локальной земли»
uniform float tex_luma = 0.8; // средняя светлота полотна вырезки (road.json)
uniform float ratio = 1.6;
uniform float ratio_min = 1.4;
uniform float ratio_max = 2.1;
uniform float l_min = 0.48;
uniform float l_max = 0.9;
uniform float bright_min = 0.55;
uniform float bright_max = 1.18;
uniform float cast_k = 0.45;
uniform float contour_soft = 0.8;
uniform float dirt_k = 0.42;
uniform float rut_k = 0.10;
uniform float edge_dark = 0.08;
uniform float grain_k = 0.07;

// цвет вершин (альфа концов) — через varying: во fragment COLOR уже умножен на TEXTURE
varying vec4 vcol;
varying vec2 wpos;

void vertex() {
	vcol = COLOR;
	wpos = VERTEX;
}

float hash1(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// гладкий шум по одной координате: соседние значения интерполированы кубикой
float vnoise(float x) {
	float i = floor(x);
	float f = fract(x);
	float u = f * f * (3.0 - 2.0 * f);
	return mix(hash1(i), hash1(i + 1.0), u);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), u.x),
		mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	return 0.55 * vnoise2(p) + 0.3 * vnoise2(p * 2.03 + 17.0) + 0.15 * vnoise2(p * 4.1 + 41.0);
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec2 ground_uv(vec2 w) {
	if (g_mirror > 0.0 && w.x > g_mirror * 0.5) {
		w.x = g_mirror - w.x;
	}
	return g_off + w * g_scale;
}

// Локальная земля: центр и два кольца по 8 выборок (радиусы land_r и 2·land_r) — тон земли
// вокруг, без мелкой фактуры травы.
vec3 local_land(vec2 w) {
	vec3 acc = texture(ground_tex, ground_uv(w)).rgb;
	float n = 1.0;
	for (int i = 0; i < 8; i++) {
		float ang = float(i) * 0.785398 + 0.39;
		vec2 dir = vec2(cos(ang), sin(ang));
		acc += texture(ground_tex, ground_uv(w + dir * land_r)).rgb;
		acc += texture(ground_tex, ground_uv(w + dir * land_r * 2.0)).rgb;
		n += 2.0;
	}
	return acc / n;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float d = abs(UV.y - 0.5) * 2.0;
	float s = UV.x * period_world;
	float y = (UV.y - 0.5) * width_world;
	// Длинные прямые: две перекрывающиеся выборки с непериодическим сдвигом.
	// Меняем лишь краску внутри полотна — нарисованная кайма и коллизия прежние.
	float cell = floor(s / 310.0 + phase);
	float blend = smoothstep(0.0, 1.0, fract(s / 310.0 + phase));
	vec3 shifted_a = texture(TEXTURE, vec2(UV.x + hash1(cell) * 5.3, UV.y)).rgb;
	vec3 shifted_b = texture(TEXTURE, vec2(UV.x + hash1(cell + 1.0) * 5.3, UV.y)).rgb;
	float interior = 1.0 - smoothstep(0.42, 0.72, d);
	tex.rgb = mix(tex.rgb, mix(shifted_a, shifted_b, blend), interior * 0.72);
	if (use_b > 0.5) {
		vec4 tb = texture(tex_b, vec2(fract(s / period_b_world), UV.y));
		float w = smoothstep(0.5 - swap_soft, 0.5 + swap_soft, vnoise(s / swap_len + phase));
		// Кайма двух вырезок лежит на разных строках: смешиваем только землю полотна,
		// иначе на переходе появляется вторая параллельная обводка.
		w *= 1.0 - smoothstep(0.45, 0.7, d);
		tex = mix(tex, tb, w);
	}
	// 1. край: сторона дороги — свой шум, иначе края колышутся зеркально
	float side = UV.y < 0.5 ? 0.0 : 37.0;
	float sp = s + phase * 61.0;
	float n = vnoise(sp * edge_freq + side) * 0.55 + vnoise(sp * edge_freq * 3.1 + side + 11.0) * 0.3
		+ vnoise(sp * edge_freq * 9.0 + side + 23.0) * 0.15;
	float edge = 1.0 - edge_amp * n;
	edge -= bite_amp * smoothstep(0.6, 0.95, vnoise(sp * 0.035 + side + 5.0));
	float a = 1.0 - smoothstep(edge - edge_soft, edge, d);
	if (core_only > 0.5) {
		a *= 1.0 - smoothstep(core_half - core_soft, core_half, d);
	}

	vec3 col = tex.rgb;
	vec3 land = vec3(tex_luma / max(ratio, 0.01));
	float k = brightness;
	if (use_ground > 0.5) {
		land = local_land(wpos);
		float lg = max(luma(land), 0.02);
		float target = clamp(lg * ratio, l_min, l_max);
		target = clamp(target, lg * ratio_min, lg * ratio_max);
		k = clamp(target / max(tex_luma, 0.01), bright_min, bright_max);
	}
	float lt = max(luma(land), 0.02);
	// 4. нарисованный тёмный контур вырезки — к тёмному тону земли
	float outer = smoothstep(0.66, 0.9, d);
	float dark = 1.0 - smoothstep(0.3, 0.7, luma(col) / max(tex_luma, 0.01));
	// на длинных кусках контур совсем растворяется в землю (как на фоне «Болото», где обводка
	// есть не везде), на других остаётся тёмной ниткой — линия «от руки», а не по линейке
	float line_vis = smoothstep(0.35, 0.7, vnoise(sp * 0.012 + side + 90.0));
	col = mix(col, land * mix(0.95, 0.7, line_vis) / k,
		dark * outer * mix(1.0, contour_soft, line_vis));
	// 3. светлота и оттенок земли
	col *= k;
	// оттенок земли без потери светлоты: цветность (цвет / светлота) полотна смешана с цветностью
	// земли — смена краски, а не притемнение и не перенасыщение (произведение двух тёплых
	// цветов давало «жёлтую ленту», кадр болота it6)
	float lc = luma(col);
	col = lc * mix(col / max(lc, 0.001), land / lt, cast_k);
	// 5. износ: пятна грязи цветом земли, колеи, затемнение к краю, зерно
	vec2 p = vec2(sp, y);
	float dirt = smoothstep(0.5, 0.78, fbm(p / vec2(46.0, 22.0)));
	col = mix(col, mix(col, land, 0.55) * 0.95, dirt * dirt_k);
	float rut = exp(-pow((abs(y) - width_world * 0.17) / (width_world * 0.05), 2.0));
	col *= 1.0 - rut * rut_k * (0.4 + 0.6 * vnoise(sp / 80.0 + 3.0));
	col *= 1.0 - edge_dark * smoothstep(0.3, 1.0, d / max(edge, 0.5));
	col *= 1.0 - grain_k * 0.5 + grain_k * hash2(floor(p * 0.67));
	COLOR = vec4(col, tex.a * a) * vcol;
}
