shader_type canvas_item;

uniform float blur_radius : hint_range(0.0, 20.0) = 4.0;

void fragment() {
	vec2 ps = TEXTURE_PIXEL_SIZE;
	if (ps.x <= 0.0) {
		ps = 1.0 / vec2(textureSize(SCREEN_TEXTURE, 0));
	}

	vec4 col = vec4(0.0);

	// 5x5 box blur
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			col += texture(SCREEN_TEXTURE, SCREEN_UV + vec2(float(x), float(y)) * ps * blur_radius);
		}
	}
	col /= 25.0;

	// 暗化处理，营造毛玻璃效果
	col.rgb *= 0.65;
	col.a = 0.92;

	COLOR = col;
}
