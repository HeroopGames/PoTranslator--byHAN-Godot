// === PoTranslatorByHAN · 黑客帝国数字雨 Shader ===
// 全屏 GPU 着色器，每列为独立雨流，头部亮白 → 尾部暗绿
// uniform: speed(下落速度 0.1~3.0), density(列密度 0.1~1.0)
// 特点: 6种随机ASCII字符、头部闪烁、列间速度/偏移/长度各异、兼容 GL Compatibility 渲染器
shader_type canvas_item;

uniform float speed : hint_range(0.1, 3.0) = 0.8;
uniform float density : hint_range(0.1, 1.0) = 0.7;

float hash(float n) {
	return fract(sin(n) * 43758.5453123);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

void fragment() {
	float cell_w = 14.0;
	float cell_h = 17.0;

	float col = floor(FRAGCOORD.x / cell_w);
	float row = floor(FRAGCOORD.y / cell_h);

	float col_seed = hash(col * 0.73 + 42.0);

	float stream_speed = 0.4 + col_seed * 1.8;
	float offset = col_seed * 800.0;
	float stream_len = 10.0 + col_seed * 20.0;

	float stream_y = mod(row - TIME * stream_speed * speed * 12.0 + offset * 0.02, 60.0);

	float visible = step(col_seed, density) * step(stream_y, stream_len);
	if (visible < 0.5) {
		COLOR = vec4(0.0);
	} else {
		float t = 1.0 - stream_y / stream_len;

		vec2 cuv = fract(FRAGCOORD.xy / vec2(cell_w, cell_h));

		float glyph = hash2(vec2(col, row + floor(TIME * 0.3 + col_seed * 50.0)));

		float vbar = smoothstep(0.38, 0.45, cuv.x) * (1.0 - smoothstep(0.55, 0.62, cuv.x))
		           * smoothstep(0.08, 0.15, cuv.y) * (1.0 - smoothstep(0.85, 0.92, cuv.y));

		float hbar = smoothstep(0.08, 0.15, cuv.x) * (1.0 - smoothstep(0.85, 0.92, cuv.x))
		           * smoothstep(0.40, 0.47, cuv.y) * (1.0 - smoothstep(0.53, 0.60, cuv.y));

		float slash1 = 1.0 - smoothstep(0.0, 0.07, abs(cuv.x - cuv.y));
		float slash2 = 1.0 - smoothstep(0.0, 0.07, abs(cuv.x + cuv.y - 1.0));

		float block_dist = max(abs(cuv.x - 0.5), abs(cuv.y - 0.5));
		float block = 1.0 - smoothstep(0.18, 0.22, block_dist);

		float cross_char = max(
			vbar * smoothstep(0.30, 0.38, cuv.y) * (1.0 - smoothstep(0.62, 0.70, cuv.y)),
			hbar * smoothstep(0.30, 0.38, cuv.x) * (1.0 - smoothstep(0.62, 0.70, cuv.x))
		);

		float char_alpha = 0.0;
		char_alpha = mix(char_alpha, vbar,       step(0.0,  glyph) * step(glyph, 0.18));
		char_alpha = mix(char_alpha, hbar,       step(0.18, glyph) * step(glyph, 0.36));
		char_alpha = mix(char_alpha, slash1,     step(0.36, glyph) * step(glyph, 0.52));
		char_alpha = mix(char_alpha, slash2,     step(0.52, glyph) * step(glyph, 0.68));
		char_alpha = mix(char_alpha, block,      step(0.68, glyph) * step(glyph, 0.82));
		char_alpha = mix(char_alpha, cross_char, step(0.82, glyph));

		float head_fade = exp(-t * 4.0);
		float white_fade = exp(-t * 10.0);

		vec3 trail_green = vec3(0.08, 0.55, 0.18);
		vec3 col_out = mix(trail_green, vec3(1.0), white_fade * 0.9) * head_fade;
		float alpha_out = head_fade * char_alpha;

		float sparkle = hash2(vec2(col, row + floor(TIME * 4.0)));
		float near_head = step(t, 0.15);
		float flash = (1.0 - t / 0.15) * 0.6 * (0.5 + sparkle * 0.5);
		alpha_out = mix(alpha_out, mix(alpha_out, 1.0, flash), near_head);

		COLOR = vec4(col_out, alpha_out);
	}
}
