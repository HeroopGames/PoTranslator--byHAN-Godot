// === PoTranslatorByHAN · 扫描线特效 Shader ===
// 全屏扫描线 + 光晕余晖，用于启动时的环境检测动画
// uniform: scan_pos(0~1 垂直位置)、line_width(线宽)、glow_color(光晕颜色)
// 由 start.gd 通过 set_shader_parameter("scan_pos", val) 驱动上下移动
shader_type canvas_item;

uniform float scan_pos : hint_range(0.0, 1.0) = 0.5;
uniform float line_width : hint_range(0.001, 0.1) = 0.015;
uniform vec4 glow_color : source_color = vec4(0.3, 1.0, 0.5, 0.8);

float remap(float t, float a, float b, float c, float d) {
	return c + (d - c) * (t - a) / (b - a);
}

void fragment() {
	float dist = abs(FRAGCOORD.y / (1.0 / TEXTURE_PIXEL_SIZE.y) - scan_pos);

	// 核心扫描线：窄亮线
	float line = 1.0 - smoothstep(0.0, line_width * 0.5, dist);

	// 光晕衰减
	float glow = exp(-dist * 40.0) * 0.4;

	// 上方余晖
	float trail = exp(-dist * 8.0) * 0.15 * step(0.003, dist);

	float alpha = max(line, max(glow, trail));

	COLOR = vec4(glow_color.rgb, alpha * glow_color.a);
}
