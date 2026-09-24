extends Node

# Enhanced graphics, per player. F4 toggles NORMAL PIXELS <-> ULTRA HD and remembers the
# choice (by design: either full ULTRA HD or the game's own pixels, no in between). Everything
# it changes is backed up and restored when switched off; works on every scene.
#   NORMAL PIXELS: the game's own look at 640x360, but lit properly: indirect light (SSIL)
#                  and soft shadows on the 16 nearest lights. No SDFGI (measured: it darkens a
#                  cave's flat ambient by 40% even at energy 2.4), no glow, no filmic colour,
#                  no normal maps: the pixels and the palette stay as shipped.
#   ULTRA HD     : native resolution through AMD FSR 2.2 (3D drawn at 77% and upscaled, with
#                  FSR's own temporal anti-aliasing instead of 4x MSAA, so weaker PCs keep their
#                  frame rate; 4x MSAA at full size where FSR 2.2 is unavailable), normal/roughness
#                  maps on stone, glow, filmic tonemap, bounce light (SDFGI), SSIL, SSR,
#                  ultra-soft shadows on the 32 nearest lights, and the game's SSAO capped so
#                  full resolution is as bright as NORMAL PIXELS
# Modes 1 and 2 (LOW, HIGH) still exist internally so nothing else has to change; F4 and the
# saved setting never land on them.
#
# API (v4.9, K11): signal mode_changed(mode: int), emitted after every mode change and once
# after startup; func is_ultra() -> bool. Maps (the Underdark's rock textures) follow it.

signal mode_changed(mode: int)

const DIR := "res://mods-unpacked/zonda-CoopSync/gfx/"
const CFG := "user://zonda_gfx.cfg"
const NAMES := ["NORMAL PIXELS", "LOW", "HIGH", "ULTRA HD"]
const PIX_SDFGI := false            # NORMAL PIXELS: bounce light on/off, its energy, indirect light strength
const PIX_SDFGI_ENERGY := 2.4
const ULTRA_WHITE := 6.0            # ULTRA HD filmic white point, bounce light energy, indirect light strength
const ULTRA_TONEMAP := Environment.TONE_MAPPER_FILMIC   # -1 = the game's own
const ULTRA_SDFGI_ON := true
const ULTRA_SDFGI_ENERGY := 1.5
const ULTRA_SSIL := 2.6
# ULTRA HD caps on the game's SSAO (strength, and how much it also darkens lamp light). At 640x360
# the game's SSAO (6.03 / 1.0) is coarse; at full resolution with normal maps it finds every
# crevice and halved NORMAL light (measured 0.038 vs 0.088 mean). These caps bring ULTRA HD to
# 0.086 in NORMAL and 0.039 in LANTERN (NORMAL PIXELS: 0.088 / 0.037), bounce light kept.
# Caps, not scales: applying them twice changes nothing.
const ULTRA_SSAO_MAX := 3.0
const ULTRA_SSAO_LIGHT_MAX := 0.3
const PIX_SSIL := 0.8               # measured: 1.6 left NORMAL PIXELS 15% darker than shipped, 0.8 is within 8% and keeps the crevices
const SHADOW_BUDGET := [16, 8, 20, 32]
const SHADOW_RANGE := [70.0, 55.0, 90.0, 120.0]
const FSR_SCALE := 0.77             # ULTRA HD: 3D drawn at 77% of the window, FSR 2.2 upscales it

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
var _orig_msaa := -1
var _orig_3d_mode := -1
var _orig_3d_scale := 1.0
var _fsr_logged := false
var _report_t := 6.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cf := ConfigFile.new()
	if cf.load(CFG) == OK:
		mode = 3 if int(cf.get_value("gfx", "mode", 0)) > 0 else 0
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_startup")


func _startup() -> void:
	_apply_global()
	mode_changed.emit(mode)


func is_ultra() -> bool:
	return mode == 3


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
		set_mode(0 if mode == 3 else 3)
		get_viewport().set_input_as_handled()


func set_mode(m: int) -> void:
	var was := mode
	mode = m
	var cf := ConfigFile.new()
	cf.set_value("gfx", "mode", mode)
	cf.save(CFG)
	if was == 3 and mode == 0:
		_restore_all()               # materials, env and shadows back to shipped, then lit again below
	_apply_global()
	_rescan_scene()
	_report_t = 6.0                  # print the "N shadowed" report again for the new mode
	CoopSync.show_banner("Graphics: %s   (F4 to change)" % NAMES[mode], 3.0)
	print("[CoopSync] graphics mode -> ", NAMES[mode])
	mode_changed.emit(mode)


func perf_label() -> String:
	return NAMES[mode]


# ------------------------------------------------------------------ global settings

func _apply_global() -> void:
	var root := get_tree().root
	if _orig_scale_mode < 0:
		_orig_scale_mode = root.content_scale_mode
		_orig_atlas = root.positional_shadow_atlas_size
		_orig_msaa = root.msaa_3d
		_orig_3d_mode = root.scaling_3d_mode
		_orig_3d_scale = root.scaling_3d_scale
	_read_dev()
	if mode == 3 and _dev_pixels:
		root.content_scale_mode = _orig_scale_mode       # developer test: ULTRA effects at 640x360
		root.scaling_3d_mode = _orig_3d_mode
		root.scaling_3d_scale = _orig_3d_scale
	elif mode == 3:
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		if _fsr2_available() and not _dev_nofsr:
			# FSR 2.2 does its own temporal anti-aliasing, so MSAA on top would only cost frames
			root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			root.scaling_3d_scale = FSR_SCALE
			root.msaa_3d = Viewport.MSAA_DISABLED
		else:
			root.scaling_3d_mode = _orig_3d_mode
			root.scaling_3d_scale = _orig_3d_scale
			root.msaa_3d = Viewport.MSAA_4X
	else:
		root.content_scale_mode = _orig_scale_mode
		root.msaa_3d = _orig_msaa
		root.scaling_3d_mode = _orig_3d_mode
		root.scaling_3d_scale = _orig_3d_scale
	# NORMAL PIXELS keeps the game's own 4096 atlas (FPS pack); ULTRA HD keeps its big one
	root.positional_shadow_atlas_size = 4096 if mode < 3 else 16384
	var q := RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
	if mode == 3:
		q = RenderingServer.SHADOW_QUALITY_SOFT_ULTRA
	elif mode == 2:
		q = RenderingServer.SHADOW_QUALITY_SOFT_HIGH
	RenderingServer.positional_soft_shadow_filter_set_quality(q)
	RenderingServer.directional_soft_shadow_filter_set_quality(q)


func _fsr2_available() -> bool:
	# FSR 2.2 exists only on the Forward+ renderer (the game ships Forward+)
	var rm := str(RenderingServer.get_current_rendering_method())
	var ok := rm == "forward_plus" or rm.is_empty()
	if not _fsr_logged:
		_fsr_logged = true
		print("[CoopSync] renderer '%s': ULTRA HD upscaler %s" % [rm, "FSR 2.2 at %d%%" % int(FSR_SCALE * 100.0) if ok else "off (4x MSAA)"])
	return ok


# ------------------------------------------------------------------ per scene

func _on_node_added(n: Node) -> void:
	if n is Light3D or n is WorldEnvironment or (n is GeometryInstance3D and mode == 3):
		_pending.append(n)


func _rescan_scene() -> void:
	# hand every tracked light back its shipped shadow flag before forgetting it, or shadows the
	# budget switched on stay on and pile up across F4 toggles (the new budget re-picks in 0.4 s)
	for e in _lights:
		if is_instance_valid(e[0]):
			e[0].shadow_enabled = e[1]
	_lights.clear()
	_light_ids.clear()
	_pending.clear()
	var scene := get_tree().current_scene
	if scene == null:
		return
	for n in scene.find_children("*", "Light3D", true, false):
		_pending.append(n)
	if mode == 3:
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
		elif n is GeometryInstance3D and mode == 3:
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
	# the game's own value, recorded once per light: a light seen again after a rescan must not
	# have a shadow our budget switched on mistaken for one the game shipped
	if not l.has_meta("zonda_orig_shadow"):
		l.set_meta("zonda_orig_shadow", l.shadow_enabled)
	var orig: bool = bool(l.get_meta("zonda_orig_shadow"))
	if not orig and l.shadow_enabled:
		l.shadow_enabled = false
	_lights.append([l, orig])


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
	_read_dev()
	var budget: int = SHADOW_BUDGET[mode]
	if mode == 3 and _dev_budget >= 0:
		budget = _dev_budget
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
				"ssil_intensity", "adjustment_brightness", "ssao_enabled", "ssao_intensity", "ssao_light_affect"]:
			b[k] = env.get(k)
		_env_backup[id] = [env, b]
	if mode == 0:
		# the shipped look, lit better: indirect light fills the shadows (SDFGI darkens a cave's
		# flat ambient, so it is only used at an energy that pays that back)
		var dev := ConfigFile.new()
		var d := dev.load("user://zonda_gfx_dev.cfg") == OK       # developer overrides for tuning runs
		env.sdfgi_enabled = bool(dev.get_value("dev", "sdfgi", PIX_SDFGI)) if d else PIX_SDFGI
		env.sdfgi_energy = float(dev.get_value("dev", "energy", PIX_SDFGI_ENERGY)) if d else PIX_SDFGI_ENERGY
		env.ssil_enabled = true
		env.ssil_intensity = float(dev.get_value("dev", "ssil", PIX_SSIL)) if d else PIX_SSIL
		return
	var hi := mode >= 2
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.06
	env.glow_threshold = 0.95
	var udev := ConfigFile.new()
	var ud := udev.load("user://zonda_gfx_dev.cfg") == OK        # developer overrides for tuning runs
	var tm: int = int(udev.get_value("dev", "ultra_tonemap", ULTRA_TONEMAP)) if ud else ULTRA_TONEMAP
	if tm >= 0:
		env.tonemap_mode = tm
	else:
		env.tonemap_mode = _env_backup[id][1]["tonemap_mode"]    # -1: keep the game's own tonemapper
	# no tonemap_exposure here: the game writes it every frame from the player's gamma slider
	# (world_environment.gd), so a value set here never rendered. ULTRA HD was judged as it
	# renders (exposure = gamma), and the gamma slider keeps working.
	env.tonemap_white = float(udev.get_value("dev", "ultra_white", ULTRA_WHITE)) if ud else ULTRA_WHITE
	env.sdfgi_enabled = hi and (bool(udev.get_value("dev", "ultra_sdfgi_on", ULTRA_SDFGI_ON)) if ud else ULTRA_SDFGI_ON)
	env.sdfgi_energy = float(udev.get_value("dev", "ultra_sdfgi", ULTRA_SDFGI_ENERGY)) if ud else ULTRA_SDFGI_ENERGY
	env.ssil_enabled = hi
	env.ssil_intensity = float(udev.get_value("dev", "ultra_ssil", ULTRA_SSIL)) if ud else ULTRA_SSIL
	env.ssr_enabled = hi and (bool(udev.get_value("dev", "ultra_ssr", true)) if ud else true)
	env.ssr_max_steps = 48
	if ud:
		env.glow_enabled = bool(udev.get_value("dev", "ultra_glow", true))
	var b0: Dictionary = _env_backup[id][1]
	var cap_i: float = float(udev.get_value("dev", "ultra_ssao_max", ULTRA_SSAO_MAX)) if ud else ULTRA_SSAO_MAX
	var cap_l: float = float(udev.get_value("dev", "ultra_ssao_light_max", ULTRA_SSAO_LIGHT_MAX)) if ud else ULTRA_SSAO_LIGHT_MAX
	env.ssao_intensity = minf(float(b0["ssao_intensity"]), cap_i)
	env.ssao_light_affect = minf(float(b0["ssao_light_affect"]), cap_l)


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


var _dev_budget := -2          # -2 unread, -1 none; developer override from user://zonda_gfx_dev.cfg
var _dev_nomaps := false
var _dev_pixels := false
var _dev_nofsr := false


func _read_dev() -> void:
	if _dev_budget != -2:
		return
	_dev_budget = -1
	var c := ConfigFile.new()
	if c.load("user://zonda_gfx_dev.cfg") == OK:
		_dev_budget = int(c.get_value("dev", "ultra_shadow_budget", -1))
		_dev_nomaps = bool(c.get_value("dev", "ultra_nomaps", false))
		_dev_pixels = bool(c.get_value("dev", "ultra_pixels", false))
		_dev_nofsr = bool(c.get_value("dev", "ultra_nofsr", false))


func _enhance_material(m: Material) -> void:
	_read_dev()
	if _dev_nomaps:
		return
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
