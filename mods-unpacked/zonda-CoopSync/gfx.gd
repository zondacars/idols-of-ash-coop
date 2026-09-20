extends Node

# Enhanced graphics, per player. F4 cycles OFF -> LOW -> HIGH -> HIGH + HD and remembers
# the choice. Everything it changes is backed up and restored when switched off, and it
# works on every scene (campaign, sandbox maps, custom maps).
#   LOW : normal/roughness maps on stone, glow, filmic tonemap, shadows on the 8 nearest lights
#   HIGH: LOW + real-time bounce light (SDFGI), SSIL, SSR, 20 nearest shadowed lights, softer shadows
#   HD  : HIGH rendered at the window's native resolution instead of 640x360

const DIR := "res://mods-unpacked/zonda-CoopSync/gfx/"
const CFG := "user://zonda_gfx.cfg"
const NAMES := ["OFF", "LOW", "HIGH", "HIGH + HD"]
const SHADOW_BUDGET := [0, 8, 20, 20]
const SHADOW_RANGE := [0.0, 55.0, 90.0, 90.0]

var mode := 0
var _maps: Dictionary = {}           # texture key -> [normal, roughness]
var _maps_loaded := false
var _mat_done: Dictionary = {}        # material instance id -> backup
var _env_backup: Dictionary = {}      # environment instance id -> [env, backup]
var _lights: Array = []               # [light, originally_shadowed]
var _light_ids: Dictionary = {}
var _pending: Array = []              # new nodes to look at
var _scene_id := 0
var _light_t := 0.0
var _env_t := 0.0
var _orig_scale_mode := -1
var _orig_atlas := -1
var _report_t := 6.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cf := ConfigFile.new()
	if cf.load(CFG) == OK:
		mode = clampi(int(cf.get_value("gfx", "mode", 0)), 0, 3)
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_apply_global")


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
		set_mode((mode + 1) % 4)
		get_viewport().set_input_as_handled()


func set_mode(m: int) -> void:
	var was := mode
	mode = m
	var cf := ConfigFile.new()
	cf.set_value("gfx", "mode", mode)
	cf.save(CFG)
	if was > 0 and mode == 0:
		_restore_all()
	_apply_global()
	_rescan_scene()
	CoopSync.show_banner("Graphics: %s   (F4 to change)" % NAMES[mode], 3.0)
	print("[CoopSync] graphics mode -> ", NAMES[mode])


func perf_label() -> String:
	return NAMES[mode]


# ------------------------------------------------------------------ global settings

func _apply_global() -> void:
	var root := get_tree().root
	if _orig_scale_mode < 0:
		_orig_scale_mode = root.content_scale_mode
		_orig_atlas = root.positional_shadow_atlas_size
	if mode == 3:
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	else:
		root.content_scale_mode = _orig_scale_mode
	if mode >= 1:
		root.positional_shadow_atlas_size = 8192
		RenderingServer.positional_soft_shadow_filter_set_quality(
			RenderingServer.SHADOW_QUALITY_SOFT_HIGH if mode >= 2 else RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
		RenderingServer.directional_soft_shadow_filter_set_quality(
			RenderingServer.SHADOW_QUALITY_SOFT_HIGH if mode >= 2 else RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	else:
		root.positional_shadow_atlas_size = _orig_atlas
		RenderingServer.positional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_LOW)
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_LOW)


# ------------------------------------------------------------------ per scene

func _on_node_added(n: Node) -> void:
	if mode == 0:
		return
	if n is GeometryInstance3D or n is Light3D or n is WorldEnvironment:
		_pending.append(n)


func _rescan_scene() -> void:
	_lights.clear()
	_light_ids.clear()
	_pending.clear()
	var scene := get_tree().current_scene
	if scene == null:
		return
	if mode == 0:
		return
	for n in scene.find_children("*", "Light3D", true, false):
		_pending.append(n)
	for n in scene.find_children("*", "GeometryInstance3D", true, false):
		_pending.append(n)
	for n in scene.find_children("*", "WorldEnvironment", true, false):
		_pending.append(n)


func _process(delta: float) -> void:
	var scene := get_tree().current_scene
	if scene and scene.get_instance_id() != _scene_id:
		_scene_id = scene.get_instance_id()
		_env_backup.clear()
		_report_t = 6.0
		_rescan_scene()
	if mode == 0:
		return
	# work through new nodes a slice at a time so a big scene never hitches
	var budget := 400
	while budget > 0 and _pending.size() > 0:
		var n = _pending.pop_back()
		budget -= 1
		if not is_instance_valid(n) or not n.is_inside_tree():
			continue
		if n is Light3D:
			_register_light(n)
		elif n is WorldEnvironment:
			_enhance_env(n.environment)
		elif n is GeometryInstance3D:
			_enhance_geometry(n)
	_env_t -= delta
	if _env_t <= 0.0:
		_env_t = 1.0
		# maps swap their environment resource at runtime; keep up with them
		if scene:
			for we in scene.find_children("*", "WorldEnvironment", true, false):
				_enhance_env(we.environment)
	_light_t -= delta
	if _light_t <= 0.0:
		_light_t = 0.4
		_update_shadow_budget()
	_report_t -= delta
	if _report_t <= 0.0 and _pending.is_empty():
		_report_t = 1e9
		var shadowed := 0
		for e in _lights:
			if is_instance_valid(e[0]) and e[0].shadow_enabled:
				shadowed += 1
		var envs := ""
		for id in _env_backup.keys():
			var env: Environment = _env_backup[id][0]
			if is_instance_valid(env):
				envs += " sdfgi=%s ssil=%s ssr=%s glow=%s" % [env.sdfgi_enabled, env.ssil_enabled, env.ssr_enabled, env.glow_enabled]
		var mats := 0
		for id in _mat_done.keys():
			if _mat_done[id] != null:
				mats += 1
		print("[CoopSync] gfx %s: %d lights tracked, %d shadowed, %d materials with normal maps,%s" % [NAMES[mode], _lights.size(), shadowed, mats, envs])


# ------------------------------------------------------------------ lights

func _register_light(l: Light3D) -> void:
	var id := l.get_instance_id()
	if _light_ids.has(id) or l.has_meta("zonda_no_shadow"):
		return
	_light_ids[id] = true
	_lights.append([l, l.shadow_enabled])


func _update_shadow_budget() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position
	var alive: Array = []
	var ranked: Array = []
	for e in _lights:
		var l = e[0]
		if not is_instance_valid(l) or not l.is_inside_tree():
			continue
		alive.append(e)
		if e[1]:
			continue   # the game's own shadowed lights keep their shadows
		if not l.visible or l.light_energy <= 0.01:
			if l.shadow_enabled:
				l.shadow_enabled = false
			continue
		var d: float = (l.global_position - eye).length()
		if l is DirectionalLight3D:
			d = 0.0
		ranked.append([d, l])
	_lights = alive
	ranked.sort_custom(func(a, b): return a[0] < b[0])
	var budget: int = SHADOW_BUDGET[mode]
	var max_d: float = SHADOW_RANGE[mode]
	for i in ranked.size():
		var l: Light3D = ranked[i][1]
		var want: bool = i < budget and ranked[i][0] < max_d
		if l.shadow_enabled != want:
			l.shadow_enabled = want
			if want:
				l.shadow_bias = 0.05
				l.shadow_normal_bias = 1.2


# ------------------------------------------------------------------ environment

func _enhance_env(env: Environment) -> void:
	if env == null:
		return
	var id := env.get_instance_id()
	if not _env_backup.has(id):
		var b := {}
		for k in ["sdfgi_enabled", "ssil_enabled", "ssr_enabled", "glow_enabled", "glow_intensity", "glow_bloom",
				"glow_threshold", "tonemap_mode", "tonemap_exposure", "tonemap_white", "sdfgi_energy", "ssr_max_steps",
				"ssil_intensity", "adjustment_brightness"]:
			b[k] = env.get(k)
		_env_backup[id] = [env, b]
	var hi := mode >= 2
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.06
	env.glow_threshold = 0.95
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.25
	env.tonemap_white = 6.0
	env.sdfgi_enabled = hi
	env.sdfgi_energy = 1.5
	env.ssil_enabled = hi
	env.ssil_intensity = 2.6
	env.ssr_enabled = hi
	env.ssr_max_steps = 48


# ------------------------------------------------------------------ materials

func _load_maps() -> void:
	_maps_loaded = true
	var f := FileAccess.open(DIR + "index.txt", FileAccess.READ)
	if f == null:
		push_warning("[CoopSync] gfx maps missing")
		return
	for line in f.get_as_text().split("\n"):
		var key := line.strip_edges()
		if key.is_empty():
			continue
		var n := _tex(DIR + key + "_n.png")
		var r := _tex(DIR + key + "_r.png")
		if n and r:
			_maps[key.to_lower()] = [n, r]
	print("[CoopSync] gfx maps loaded: %d" % _maps.size())


func _tex(path: String) -> ImageTexture:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _key_for(tex: Texture2D) -> String:
	if tex == null:
		return ""
	var k := ""
	if tex.resource_path != "":
		k = tex.resource_path.get_file().get_basename()
		# imported glb textures look like "Model.glb::Image_xyz"; fall back to the name
		if k.contains("::") or k.is_empty():
			k = ""
	if k == "":
		k = tex.resource_name
	return k.to_lower()


func _enhance_geometry(g: GeometryInstance3D) -> void:
	if not _maps_loaded:
		_load_maps()
	if g.material_override:
		_enhance_material(g.material_override)
	if g is MeshInstance3D:
		var mi: MeshInstance3D = g
		if mi.mesh == null:
			return
		for i in mi.mesh.get_surface_count():
			var m: Material = mi.get_surface_override_material(i)
			if m == null:
				m = mi.mesh.surface_get_material(i)
			if m:
				_enhance_material(m)


func _enhance_material(m: Material) -> void:
	if not (m is StandardMaterial3D):
		return
	var id := m.get_instance_id()
	if _mat_done.has(id):
		return
	var sm: StandardMaterial3D = m
	var key := _key_for(sm.albedo_texture)
	if key == "" or not _maps.has(key) or sm.normal_enabled:
		_mat_done[id] = null
		return
	_mat_done[id] = [sm, sm.normal_enabled, sm.normal_texture, sm.normal_scale, sm.roughness_texture, sm.roughness]
	sm.normal_enabled = true
	sm.normal_texture = _maps[key][0]
	sm.normal_scale = 1.7
	sm.roughness_texture = _maps[key][1]
	sm.roughness = 1.0


# ------------------------------------------------------------------ restore

func _restore_all() -> void:
	for id in _mat_done.keys():
		var b = _mat_done[id]
		if b == null or not is_instance_valid(b[0]):
			continue
		var sm: StandardMaterial3D = b[0]
		sm.normal_enabled = b[1]
		sm.normal_texture = b[2]
		sm.normal_scale = b[3]
		sm.roughness_texture = b[4]
		sm.roughness = b[5]
	_mat_done.clear()
	for id in _env_backup.keys():
		var e = _env_backup[id]
		if not is_instance_valid(e[0]):
			continue
		var env: Environment = e[0]
		for k in e[1].keys():
			env.set(k, e[1][k])
	_env_backup.clear()
	for e in _lights:
		if is_instance_valid(e[0]):
			e[0].shadow_enabled = e[1]
	_lights.clear()
	_light_ids.clear()
	_pending.clear()
