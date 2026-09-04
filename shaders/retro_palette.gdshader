shader_type canvas_item;

// Aplicado no SubViewportContainer de cada jogador: acha o TEXTURE do
// viewport de baixa resolução e posteriza + dithera as cores, pra imitar
// uma paleta limitada de console 16-bit em cima do render 3D normal.

uniform float color_levels : hint_range(3.0, 32.0) = 6.0;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.5;

const float BAYER_4X4[16] = float[16](
	0.0,  8.0,  2.0, 10.0,
	12.0, 4.0, 14.0,  6.0,
	3.0, 11.0,  1.0,  9.0,
	15.0, 7.0, 13.0,  5.0
);

void fragment() {
	vec4 tex = texture(TEXTURE, UV);

	int bx = int(mod(FRAGCOORD.x, 4.0));
	int by = int(mod(FRAGCOORD.y, 4.0));
	float threshold = (BAYER_4X4[bx + by * 4] / 16.0 - 0.5) * dither_strength / color_levels;

	vec3 dithered = tex.rgb + threshold;
	vec3 posterized = floor(dithered * color_levels + 0.5) / color_levels;

	COLOR = vec4(posterized, tex.a);
}
