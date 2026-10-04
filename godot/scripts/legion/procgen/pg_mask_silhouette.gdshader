shader_type canvas_item;
render_mode blend_add;
// Силуэт спрайта в канал G карты зон PgArtMask: где у предмета есть картинка — там «предмет».
// Аддитивно: перекрытия не стирают соседние каналы (R — дорога/вода, B — основания).

void fragment() {
	float a = texture(TEXTURE, UV).a;
	COLOR = vec4(0.0, step(0.35, a), 0.0, 1.0);
}
