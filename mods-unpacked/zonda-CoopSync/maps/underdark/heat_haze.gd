extends CanvasLayer

# Foundry heat haze (K9). A full-screen screen-space shimmer: it only moves pixels a little along a
# slow rising noise, never changes their colour or brightness, and draws nothing on its own (no
# specks, no particles). Sits on canvas layer -1: above the 3D world, below every HUD / banner.
#
# API (for the integrators)
#   const HeatHaze := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/heat_haze.gd")
#   var haze: CanvasLayer = HeatHaze.new()
#   add_child(haze)                # the map; free it with the map
#   haze.set_strength(k)           # 0..1, safe to call every frame (only real changes reach the GPU)
#                                  # 0 hides the rect: no screen copy, no cost
#   haze.strength                  # read-only: the last value set
# Suggested driver (map side): k = 1 near the Crucible's lava lake, fading to 0 about 60 m above
# it or outside THE FOUNDRY (biome 7); smooth it over ~1 s so it never pops.
# Full strength moves pixels by about 2 px at 640x360 (more near the bottom of the screen, where
# the heat rises from).

const SHADER := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform float strength = 0.0;
uniform float amp = 0.0055;

float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1.0, 0.0)), f.x), mix(h(i + vec2(0.0, 1.0)), h(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float asp = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	// the pattern drifts upward (heat rises) and slowly sideways
	vec2 p = vec2(uv.x * asp * 6.0 + TIME * 0.07, uv.y * 6.0 + TIME * 0.6);
	float dx = n(p) - 0.5 + (n(p * 2.1 + vec2(7.3, 1.9)) - 0.5) * 0.5;
	float dy = n(p + vec2(19.7, 4.1)) - 0.5 + (n(p * 2.3 + vec2(3.1, 11.7)) - 0.5) * 0.5;
	float k = strength * amp * mix(0.5, 1.0, uv.y);
	vec2 off = vec2(dx * 0.6 / asp, dy) * k;
	COLOR = vec4(texture(screen_tex, clamp(uv + off, vec2(0.001), vec2(0.999))).rgb, 1.0);
}
"""

var strength := 0.0
var _rect: ColorRect
var _mat: ShaderMaterial
var _sent := -1.0


func _ready() -> void:
	layer = -1
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER
	_mat.shader = sh
	_rect = ColorRect.new()
	_rect.name = "HeatHaze"
	_rect.color = Color(1, 1, 1, 1)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.material = _mat
	_rect.visible = false
	add_child(_rect)
	set_strength(strength)


func set_strength(k: float) -> void:
	strength = clampf(k, 0.0, 1.0)
	if _rect == null:
		return                            # before _ready: applied there
	var on := strength > 0.004
	if _rect.visible != on:
		_rect.visible = on
	if on and absf(strength - _sent) > 0.002:
		_sent = strength
		_mat.set_shader_parameter("strength", strength)
