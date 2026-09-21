extends Node3D

# THE UNDERDARK. The cave itself is a pre-built glTF (underdark.glb, generated offline
# from a fixed seed so every player has the identical world). This script loads it,
# builds collision, places every prop, light, trap, puzzle and creature from layout.json,
# and runs them. Anything that changes the world goes through CoopSync.map_event so all
# players see the same thing, and re-applies after a death reload.

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const PYRELIGHT := "res://Art/Pyrelight.tscn"
const EMBER := "res://Treasure_Pickup.tscn"
const CENTIPEDE := "res://scenes/centipede.tscn"
const TEXT_AREA_SCRIPT := "res://scripts/ending_text_display_area.gd"
const SFX_RUMBLE := "res://sfx/soundsnap/304185-Chair-Rumble-Contact-Resonant-Distorted-Crisp-High.wav"
const SFX_GRAVEL := "res://sfx/soundsnap/41281-FOLEY_FOOTSTEPS_BOOTS_SLIDE_GRAVEL_SCATTER_01.wav"
const SFX_METAL := ["res://sfx/soundsnap/273280-Builder-Game-Item-Pickaxe-Hit-Stone-Metal-1.wav", "res://sfx/soundsnap/273281-Builder-Game-Item-Pickaxe-Hit-Stone-Metal-2.wav"]
const SFX_WIND := "res://sfx/soundsnap/249565-Heavy_Wind_Ambience_2.wav"
const PLAYER_LAYER := 4
const CLAW_LAYER := 2

# per-biome look: [wall albedo, floor albedo, ambient, fog color, fog density, bg energy]
const LOOKS := [
	[Color(0.78, 0.7, 0.58), Color(0.72, 0.62, 0.5), Color(0.5, 0.45, 0.38), Color(0.085, 0.078, 0.064), 0.82, 0.3],
	[Color(0.85, 0.82, 0.72), Color(0.8, 0.76, 0.66), Color(0.36, 0.34, 0.3), Color(0.066, 0.068, 0.062), 0.84, 0.1],
	[Color(0.45, 0.62, 0.42), Color(0.35, 0.55, 0.32), Color(0.18, 0.4, 0.25), Color(0.028, 0.085, 0.055), 0.84, 0.1],
	[Color(0.55, 0.42, 0.3), Color(0.45, 0.34, 0.25), Color(0.36, 0.25, 0.16), Color(0.082, 0.056, 0.03), 0.84, 0.1],
	[Color(0.45, 0.55, 0.58), Color(0.38, 0.48, 0.5), Color(0.24, 0.32, 0.36), Color(0.045, 0.072, 0.088), 0.86, 0.1],
	[Color(0.6, 0.58, 0.62), Color(0.5, 0.48, 0.52), Color(0.28, 0.25, 0.32), Color(0.06, 0.05, 0.088), 0.84, 0.1],
	[Color(0.62, 0.76, 0.95), Color(0.55, 0.7, 0.9), Color(0.27, 0.4, 0.58), Color(0.038, 0.075, 0.13), 0.82, 0.1],
	[Color(0.6, 0.35, 0.25), Color(0.5, 0.28, 0.2), Color(0.5, 0.18, 0.08), Color(0.125, 0.044, 0.012), 0.8, 0.2],
	[Color(0.5, 0.22, 0.24), Color(0.42, 0.18, 0.2), Color(0.42, 0.08, 0.08), Color(0.09, 0.012, 0.012), 0.8, 0.18],
	[Color(0.62, 0.55, 0.45), Color(0.55, 0.48, 0.4), Color(0.14, 0.11, 0.08), Color(0.01, 0.01, 0.01), 0.9, 0.0],
	# 10 and 11 are surfaces, not places: bone (the Ribs) and bark (the great roots)
	[Color(1.9, 1.8, 1.5), Color(1.9, 1.8, 1.5), Color(0.36, 0.34, 0.3), Color(0.066, 0.068, 0.062), 0.84, 0.1],
	[Color(0.4, 0.27, 0.16), Color(0.46, 0.31, 0.18), Color(0.36, 0.25, 0.16), Color(0.082, 0.056, 0.03), 0.84, 0.1],
]

var L: Dictionary = {}
var _env: Environment
var _cur_biome := -1
var _blend := 0.0
var _look_now: Array = []
var _weather: Weather
var _rope_gold_t := 0.0
var _dimmed: Dictionary = {}
var _dress_mat: Array = []
var _sky: DirectionalLight3D
var _glow: DirectionalLight3D
var _look_from: Array = []
var _look_to: Array = []
var _chunks: Array = []          # [MeshInstance3D, center, radius]
var _lod_accum := 0.0
var _lod_index := 0
var _clock := 0.0
var _finished := false
var _gates: Dictionary = {}
var _kilns: Dictionary = {}       # idx -> node
var _plates: Array = []
var _fragments: Dictionary = {}
var _frag_count := 0
var _stalkers: Array = []
var _crumbles: Dictionary = {}
var _droppers: Dictionary = {}
var _dying: Dictionary = {}
var _spawned_cents: Dictionary = {}
var _follower: Node3D
var _follow_best := 1e9
var _follow_stall := 0.0
var _cent_tick := 0.0
var _territorial: Array = []          # [node, y_top, y_bottom, home]
var _hud: CanvasLayer
var _hud_depth: Label
var _run_start_ms := 0
var _debug_tour := false
var _tour_i := -1
var _tour_t := 0.0
var _tour_shots: Array = []
var _tour_shot_done := false
var _wall_mat: Array = []
var _floor_mat: Array = []
var _mat_bar: StandardMaterial3D
var _mat_crystal: StandardMaterial3D
var _mat_ruin: StandardMaterial3D
var _crystal_n := 0
var _lava_kill_y := -1e9
var _lava_box: Array = []       # [center, d, s, half_w, half_l]
var _bars: Array = []
var _bells: Dictionary = {}
var _platforms: Dictionary = {}
var _fall_speed := 0.0
var _lethal_fall := 38.0
var _bruise_from := 19.0
var _bruise_per := 4.5
var _bruise_told := false
# The game pins ambient energy to 0.18 every frame (world_environment.gd), so the only way to
# lift the dark is through the ambient COLOUR. And its colour-correction ramp clips to white at
# about 0.28 raw and crushes below 0.06, so everything here lives between those two numbers.
const AMB_GAIN := 2.3
# light that falls down the rift from far above, per biome. It is what lets you see a balcony
# 300 m away. Off inside the side caves.
const SKYGLOW := [0.44, 0.4, 0.32, 0.33, 0.33, 0.33, 0.37, 0.14, 0.0, 0.0]
const VIEW_RANGE := 425.0        # the campaign shows 150-300 m of void; the rift needs the same
const SOLID_RANGE := 150.0
var _mat_lava: ShaderMaterial
var _lights: Array = []
var _nest_lights: Array = []
var _music: MusicDirector
var _idol_taken := false
var _idol_node: Node3D
var _altar_light: OmniLight3D
var _altar_pos: Vector3


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	var f := FileAccess.open(DIR + "layout.json", FileAccess.READ)
	if f == null:
		push_error("[Underdark] layout.json missing")
		return
	L = JSON.parse_string(f.get_as_text())
	_lethal_fall = float(L.get("rules", {}).get("lethal_fall_speed", 38.0))
	_bruise_from = float(L.get("rules", {}).get("bruise_from", 19.0))
	_bruise_per = float(L.get("rules", {}).get("bruise_per", 4.5))
	_debug_tour = FileAccess.file_exists(DIR + "tour.flag")
	_build_materials()
	_setup_environment()
	_load_cave()
	_place_start()
	_place_barriers()
	_place_props()
	_place_dress()
	_place_lights()
	_place_fires()
	_place_embers()
	_place_crystals()
	_place_texts()
	_place_checkpoints()
	_place_crumbles()
	_place_vents()
	_place_droppers()
	_place_spikes()
	_place_ice()
	_place_gates()
	_place_kilns()
	_place_plates()
	_place_fragments()
	_place_bells()
	_place_relics()
	_place_lanterns()
	_place_mist()
	_weather = Weather.new()
	_weather.build(_soft_dot())
	add_child(_weather)
	_place_platforms()
	_place_spars()
	_place_falls()
	_place_ghosts()
	_place_bars()
	_place_lava()
	_place_ambience()
	_place_dying_lights()
	_place_altar()
	_build_hud()
	_music = MusicDirector.new()
	add_child(_music)
	_run_start_ms = Time.get_ticks_msec()
	# creatures after a frame so Game.centipedes is clean for this scene
	call_deferred("_place_creatures")
	CoopSync.nametags_through_walls = true
	CoopSync.map_request_sync()
	call_deferred("_reapply_events")
	print("[Underdark] built in %d ms: %d chunks, %d props" % [Time.get_ticks_msec() - t0, _chunks.size(), L.get("props", []).size()])


# ------------------------------------------------------------------ world

func _build_materials() -> void:
	var rock: StandardMaterial3D = load("res://Art/Textures/Rock_01.tres")
	var wall4: StandardMaterial3D = load("res://Art/Textures/Wall_04.tres")
	for i in LOOKS.size():
		var w: StandardMaterial3D = rock.duplicate()
		w.albedo_color = LOOKS[i][0]
		w.vertex_color_use_as_albedo = true
		w.cull_mode = BaseMaterial3D.CULL_DISABLED
		w.uv1_scale = Vector3(0.11, 0.11, 0.11)
		_wall_mat.append(w)
		var fl: StandardMaterial3D = wall4.duplicate()
		fl.albedo_color = LOOKS[i][1]
		fl.vertex_color_use_as_albedo = true
		fl.cull_mode = BaseMaterial3D.CULL_DISABLED
		fl.metallic = 0.0                       # the game's sand is half metal, which reads as black with no sky to reflect
		fl.uv1_scale = Vector3(0.09, 0.09, 0.09)
		_floor_mat.append(fl)
		var dm: StandardMaterial3D = w.duplicate()
		dm.vertex_color_use_as_albedo = false
		dm.albedo_color = Color(LOOKS[i][0].r * 0.62, LOOKS[i][0].g * 0.62, LOOKS[i][0].b * 0.62)
		dm.cull_mode = BaseMaterial3D.CULL_BACK
		_dress_mat.append(dm)
	_mat_bar = StandardMaterial3D.new()
	_mat_bar.albedo_color = Color(0.32, 0.12, 0.08)
	_mat_bar.metallic = 0.2
	_mat_bar.roughness = 0.6
	_mat_crystal = StandardMaterial3D.new()
	# the game's environment doubles brightness and color-corrects, so anything emissive
	# and blue turns pure white. Dark albedo, no emission, let the room lights do it.
	_mat_crystal.albedo_color = Color(0.1, 0.22, 0.42)
	_mat_crystal.roughness = 0.9
	_mat_crystal.emission_enabled = false
	_mat_ruin = wall4.duplicate()
	_mat_ruin.albedo_color = Color(0.42, 0.4, 0.44)
	_mat_ruin.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_ruin.uv1_scale = Vector3(0.2, 0.2, 0.2)
	_mat_lava = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float t = 0.0;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p) { vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), f.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), f.x), f.y); }
void fragment() {
	vec2 p = wp.xz * 0.045 + vec2(t * 0.02, t * 0.013);
	float v = n(p) * 0.6 + n(p * 2.3 + t * 0.05) * 0.3 + n(p * 5.1) * 0.1;
	// linear values. The game doubles brightness in display space and clips to white there,
	// so linear 0.064 is already white. These land on deep red and orange.
	vec3 dark = vec3(0.008, 0.0008, 0.0); vec3 hot = vec3(0.062, 0.0095, 0.0006);
	float k = smoothstep(0.4, 0.78, v);
	ALBEDO = mix(dark, hot, k);
	EMISSION = vec3(0.0);
}
"""
	_mat_lava.shader = sh


func _load_cave() -> void:
	var bytes := FileAccess.get_file_as_bytes(DIR + "underdark.glb")
	if bytes.is_empty():
		push_error("[Underdark] underdark.glb missing or empty")
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_buffer(bytes, "", state)
	if err != OK:
		push_error("[Underdark] could not read cave mesh: %s" % err)
		return
	var root: Node = doc.generate_scene(state)
	if root == null:
		push_error("[Underdark] cave scene empty")
		return
	var count := 0
	var found: Array = []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		found.append(mi)
	# the runtime importer can hand back ImporterMeshInstance3D instead; convert those
	for imi in root.find_children("*", "ImporterMeshInstance3D", true, false):
		var im: ImporterMesh = imi.mesh
		if im == null:
			continue
		var conv := MeshInstance3D.new()
		conv.mesh = im.get_mesh()
		found.append(conv)
	for mi in found:
		var m: MeshInstance3D = mi
		var mesh: Mesh = m.mesh
		if mesh == null:
			continue
		if m.get_parent():
			m.get_parent().remove_child(m)
		add_child(m)
		m.transform = Transform3D.IDENTITY
		for si in mesh.get_surface_count():
			var mat: Material = mesh.surface_get_material(si)
			var nm: String = mat.resource_name if mat else ""
			var b := 0
			var is_floor := false
			if nm.begins_with("B"):
				var parts := nm.substr(1).split("_")
				b = clampi(int(parts[0]), 0, LOOKS.size() - 1)
				is_floor = parts.size() > 1 and parts[1] == "F"
			m.set_surface_override_material(si, _floor_mat[b] if is_floor else _wall_mat[b])
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.physics_material_override = load("res://physics_materials/stone.tres")
		var shape := CollisionShape3D.new()
		var tri: ConcavePolygonShape3D = mesh.create_trimesh_shape()
		tri.backface_collision = true
		shape.shape = tri
		body.add_child(shape)
		m.add_child(body)
		var aabb := mesh.get_aabb()
		var c := aabb.get_center()
		_chunks.append([m, c, aabb.size.length() * 0.5])
		m.visibility_range_end = 0.0
		count += 1
	root.queue_free()
	print("[Underdark] cave chunks: %d" % count)


func _place_start() -> void:
	var st: Dictionary = L["start"]
	var c = get_node_or_null("Climber")
	if c:
		var p: Array = st["pos"]
		c.position = Vector3(p[0], p[1], p[2])
		c.rotation.y = float(st["yaw"])


func _place_barriers() -> void:
	# invisible walls around the surface bowl so nobody walks off the edge of the world
	for b in L.get("barriers", []):
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var s: Array = b["size"]
		box.size = Vector3(s[0], s[1], s[2])
		cs.shape = box
		body.add_child(cs)
		body.position = _v(b["pos"])
		body.rotation.y = float(b["yaw"])
		add_child(body)


func _place_props() -> void:
	var cache: Dictionary = {}
	for p in L.get("props", []):
		var path: String = p["scene"]
		if not cache.has(path):
			cache[path] = load(path)
		var ps: PackedScene = cache[path]
		if ps == null:
			continue
		var n: Node3D = ps.instantiate()
		n.position = _v(p["pos"])
		var r: Array = p["rot"]
		n.rotation = Vector3(r[0], r[1], r[2])
		n.scale = Vector3.ONE * float(p["scale"])
		add_child(n)
		if p.get("box") != null:
			var bx: Array = p["box"]
			var body := StaticBody3D.new()
			body.collision_layer = 1
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(bx[0] * 2.0, bx[1] * 2.0, bx[2] * 2.0)
			cs.shape = shape
			cs.position = Vector3(0, bx[1], 0)
			body.add_child(cs)
			body.rotation = n.rotation
			body.position = n.position
			add_child(body)
		var ruin: bool = path.contains("Village_") or path.contains("Ghost_Tower") or path.contains("Building_") or path.contains("Roof_") or path.contains("Door.glb") or path.contains("Tower_0")
		if path.contains("Plant_"):
			_dim_materials(n, 0.3)
		elif path.contains("Woman") or path.contains("Player_Corpse") or path.contains("Rope") or path.contains("WaterWheel") or path.contains("StoneSphere"):
			_dim_materials(n, 0.4)
		for mi in n.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).visibility_range_end = float(p.get("vis", 300.0))
			(mi as GeometryInstance3D).visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			if ruin:
				(mi as GeometryInstance3D).material_override = _mat_ruin


func _dim_materials(n: Node, k: float) -> void:
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for si in m.mesh.get_surface_count():
			var src: Material = m.get_active_material(si)
			if not (src is StandardMaterial3D):
				continue
			if not _dimmed.has(src):
				var d: StandardMaterial3D = src.duplicate()
				d.albedo_color = Color(d.albedo_color.r * k, d.albedo_color.g * k, d.albedo_color.b * k, d.albedo_color.a)
				d.emission_enabled = false
				_dimmed[src] = d
			m.set_surface_override_material(si, _dimmed[src])


func _place_dress() -> void:
	# Kit rocks half-buried in the generated walls and floors. Each piece is measured
	# at runtime so the embed depth is right whatever its real bounds are.
	var cache: Dictionary = {}
	var placed := 0
	for d in L.get("dress", []):
		var path: String = d["scene"]
		if not cache.has(path):
			cache[path] = load(path)
		var ps: PackedScene = cache[path]
		if ps == null:
			continue
		var n: Node3D = ps.instantiate()
		var sc := float(d["scale"])
		var ab := _merged_aabb(n)
		if ab.size == Vector3.ZERO:
			n.queue_free()
			continue
		var hit := _v(d["hit"])
		var nrm := _v(d["n"])
		var embed := float(d.get("embed", 0.45))
		n.rotation = Vector3(float(d.get("tilt", 0.0)), float(d.get("yaw", 0.0)), float(d.get("roll", 0.0)))
		n.scale = Vector3.ONE * sc
		# Several kit rocks have their pivot at one end, so the mesh centre must be pushed
		# back through the same rotation, or the piece ends up floating out in the room.
		var basis := Basis.from_euler(n.rotation)
		var centre_off: Vector3 = basis * (ab.get_center() * sc)
		var half: Vector3 = ab.size * 0.5 * sc
		var reach: float = absf(basis.x.dot(nrm)) * half.x + absf(basis.y.dot(nrm)) * half.y + absf(basis.z.dot(nrm)) * half.z
		n.position = hit + nrm * (reach * (1.0 - 2.0 * embed)) - centre_off
		add_child(n)
		# same stone as the wall it grows out of, or it reads as a slab pasted on
		var db := clampi(_biome_at(hit), 0, _dress_mat.size() - 1)
		for mi in n.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).material_override = _dress_mat[db]
			(mi as GeometryInstance3D).visibility_range_end = 240.0
			(mi as GeometryInstance3D).visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		placed += 1
	print("[Underdark] dressing pieces: %d" % placed)


func _merged_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		if m.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var node: Node = m
		while node != null and node != root:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var ab: AABB = xf * m.mesh.get_aabb()
		if first:
			out = ab
			first = false
		else:
			out = out.merge(ab)
	return out


func _place_lights() -> void:
	for l in L.get("lights", []):
		_add_light(_v(l["pos"]), _c(l["color"]), float(l["energy"]), float(l["range"]))


func _add_light(pos: Vector3, color: Color, energy: float, rng: float) -> OmniLight3D:
	var o := OmniLight3D.new()
	o.light_color = color
	o.light_energy = energy
	o.omni_range = rng
	o.shadow_enabled = false
	o.position = pos
	o.distance_fade_enabled = true
	o.distance_fade_begin = 380.0 if rng >= 60.0 else 140.0      # landmark lights carry across the rift
	o.distance_fade_length = 40.0
	add_child(o)
	_lights.append(o)
	return o


func _place_fires() -> void:
	for f in L.get("fires", []):
		_add_fire(_v(f["pos"]), float(f["scale"]), bool(f.get("beacon", false)))


var _dot_tex: GradientTexture2D


func _soft_dot() -> GradientTexture2D:
	if _dot_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_dot_tex = GradientTexture2D.new()
		_dot_tex.gradient = g
		_dot_tex.fill = GradientTexture2D.FILL_RADIAL
		_dot_tex.fill_from = Vector2(0.5, 0.5)
		_dot_tex.fill_to = Vector2(0.5, 0.0)
		_dot_tex.width = 64
		_dot_tex.height = 64
	return _dot_tex


func _add_fire(pos: Vector3, s: float, beacon: bool = false) -> Node3D:
	# The game's "Pyrelight" is the tall pillar the campaign puts over its kiln shrines,
	# so it only belongs at checkpoints. Everything else gets an actual flame.
	if beacon:
		var ps: PackedScene = load(PYRELIGHT)
		if ps == null:
			return null
		var n: Node3D = ps.instantiate()
		n.position = pos
		n.scale = Vector3(s, s, s)
		add_child(n)
		return n
	var flame := CPUParticles3D.new()
	flame.amount = 12
	flame.lifetime = 0.9
	flame.explosiveness = 0.0
	flame.randomness = 0.6
	flame.local_coords = false
	flame.direction = Vector3.UP
	flame.spread = 14.0
	flame.gravity = Vector3(0, 1.4, 0)
	flame.initial_velocity_min = 0.7 * s
	flame.initial_velocity_max = 1.6 * s
	flame.scale_amount_min = 0.5 * s
	flame.scale_amount_max = 1.1 * s
	flame.damping_min = 0.6
	flame.damping_max = 1.4
	var grad := Gradient.new()
	# kept dim on purpose: the game doubles brightness in post, bright fire turns white
	grad.set_color(0, Color(0.55, 0.3, 0.08, 0.5))
	grad.set_color(1, Color(0.25, 0.04, 0.0, 0.0))
	grad.add_point(0.4, Color(0.5, 0.16, 0.02, 0.4))
	flame.color_ramp = grad
	var quad := QuadMesh.new()
	quad.size = Vector2(0.55, 0.7)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	fm.albedo_texture = _soft_dot()
	fm.vertex_color_use_as_albedo = true
	fm.disable_receive_shadows = true
	quad.material = fm
	flame.mesh = quad
	flame.position = pos + Vector3(0, 0.25 * s, 0)
	flame.visibility_range_end = 140.0
	add_child(flame)
	var fl := Flicker.new()
	fl.setup(_add_light(pos + Vector3(0, 0.9 * s, 0), Color(1.0, 0.6, 0.25), 1.1 * s, 13.0 * s))
	add_child(fl)
	return flame


func _place_embers() -> void:
	var ps: PackedScene = load(EMBER)
	if ps == null:
		return
	for e in L.get("embers", []):
		var n: Node3D = ps.instantiate()
		n.position = _v(e["pos"])
		add_child(n)


func _place_crystals() -> void:
	for c in L.get("crystals", []):
		var mi := MeshInstance3D.new()
		var prism := PrismMesh.new()
		prism.size = Vector3(0.6, 1.6, 0.6)
		mi.mesh = prism
		mi.material_override = _mat_crystal
		var s := float(c["s"])
		mi.position = _v(c["pos"]) + Vector3(0, 0.8 * s, 0)
		mi.scale = Vector3.ONE * s
		mi.rotation = Vector3(float(c["tilt"]), float(c["yaw"]), 0.0)
		mi.visibility_range_end = 220.0
		add_child(mi)
		_crystal_n += 1
		if _crystal_n % 4 == 0:
			_add_light(_v(c["pos"]) + Vector3(0, 2.5 * s, 0), Color(0.45, 0.75, 1.0), 0.6, 14.0 + 3.0 * s)


func _place_texts() -> void:
	for t in L.get("texts", []):
		var a := _area(_v(t["pos"]), float(t["r"]), PLAYER_LAYER)
		a.set_script(load(TEXT_AREA_SCRIPT))
		a.set("displayed_text", t["text"])
		add_child(a)


# ------------------------------------------------------------------ checkpoints and respawn

func _place_checkpoints() -> void:
	for c in L.get("checkpoints", []):
		var a := _area(_v(c["pos"]), float(c["r"]), PLAYER_LAYER)
		var id := int(c["id"])
		a.body_entered.connect(func(body: Node3D): _on_checkpoint(id, body))
		add_child(a)
	# a death reloads the map: put the player at the team's furthest checkpoint
	var cp := CoopSync.map_checkpoint_for(scene_file_path)
	if cp >= 0:
		for c in L.get("checkpoints", []):
			if int(c["id"]) == cp:
				var climber = get_node_or_null("Climber")
				if climber:
					climber.position = _v(c["pos"]) + Vector3(0.5, 0.2, 0.5)
				break


func _on_checkpoint(id: int, body: Node3D) -> void:
	if body != Game.climber:
		return
	if id <= CoopSync.map_checkpoint_for(scene_file_path):
		return
	Game.audio.play_player_healed()
	if is_instance_valid(Game.climber):
		Game.climber.heal(60.0)
	var label := ""
	for c in L["checkpoints"]:
		if int(c["id"]) == id:
			label = str(c["label"])
	CoopSync.map_checkpoint(id)
	CoopSync.show_banner("Checkpoint: %s" % label, 4.0)


# ------------------------------------------------------------------ traps

func _place_crumbles() -> void:
	var ps: PackedScene = load("res://Art/Sand_Shelf_Base.glb")
	if ps == null:
		return
	for c in L.get("crumbles", []):
		var n: Node3D = ps.instantiate()
		n.position = _v(c["pos"])
		n.rotation.y = float(c["yaw"])
		n.scale = Vector3.ONE * float(c["scale"])
		add_child(n)
		var trap := Crumble.new()
		trap.setup(str(c["id"]), n, 4.7 * float(c["scale"]) + 1.4)
		add_child(trap)
		_crumbles[str(c["id"])] = trap


func _place_vents() -> void:
	for v in L.get("vents", []):
		var pos := _v(v["pos"])
		var fire := _add_fire(pos, 0.35)
		var light := _add_light(pos + Vector3(0, 1.5, 0), Color(1.0, 0.55, 0.2), 0.7, 14.0)
		var vent := FireVent.new()
		vent.setup(fire, light, pos, float(v["period"]), float(v["phase"]))
		add_child(vent)


func _place_droppers() -> void:
	for d in L.get("droppers", []):
		var kind := str(d["kind"])
		var icicle: bool = kind == "icicle"
		var tower: bool = kind == "tower"
		var ps: PackedScene = load("res://Art/Ghost_Tower_02.glb" if tower else ("res://Art/Spikes_01.glb" if icicle else "res://Art/Stone_09.glb"))
		if ps == null:
			continue
		var rock: Node3D = ps.instantiate()
		for body in rock.find_children("*", "StaticBody3D", true, false):
			body.queue_free()
		rock.position = _v(d["hang"])
		if tower:
			rock.scale = Vector3.ONE * 0.45
			rock.rotation = Vector3(PI, randf() * TAU, 0)
			for mi in rock.find_children("*", "GeometryInstance3D", true, false):
				(mi as GeometryInstance3D).material_override = _mat_ruin
		elif icicle:
			rock.scale = Vector3.ONE * 0.16
			rock.rotation = Vector3(PI, randf() * TAU, 0)
			for mi in rock.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).material_override = _mat_crystal
		else:
			rock.scale = Vector3.ONE * 0.5
			rock.rotation = Vector3(randf_range(-0.3, 0.3), randf() * TAU, randf_range(-0.3, 0.3))
		add_child(rock)
		var trap := Dropper.new()
		var trip: Array = d["trip"]
		trap.setup(str(d["id"]), rock, _v(trip[0]), float(trip[1]), 7.0 if tower else (2.4 if icicle else 3.6), float(d["floor"]))
		if tower:
			trap.damage = 90.0
			trap.fall_time = 1.6
			trap.reset_after = 9999.0
		add_child(trap)
		_droppers[str(d["id"])] = trap


func _place_spikes() -> void:
	for s in L.get("spikes", []):
		var a := _area(_v(s["pos"]), float(s["r"]), PLAYER_LAYER)
		add_child(a)
		var trap := SpikeBed.new()
		trap.setup(a, _v(s["push"]))
		add_child(trap)


func _place_ice() -> void:
	for i in L.get("ice", []):
		var a := _area(_v(i["pos"]), float(i["r"]), PLAYER_LAYER)
		add_child(a)
		var sl := IceShelf.new()
		sl.setup(a, _v(i["dir"]))
		add_child(sl)


# ------------------------------------------------------------------ puzzles

func _place_gates() -> void:
	for g in L.get("gates", []):
		var gate := Gate.new()
		gate.setup(g, _mat_bar)
		add_child(gate)
		_gates[str(g["id"])] = gate


func _place_kilns() -> void:
	var ps: PackedScene = load("res://Art/Ancient_Kiln.glb")
	for k in L.get("kilns", []):
		var pos := _v(k["pos"])
		var n: Node3D = null
		if ps:
			n = ps.instantiate()
			n.position = pos
			n.scale = Vector3.ONE * 0.8
			add_child(n)
		var kiln := Kiln.new()
		kiln.setup(str(k["gate"]), int(k["idx"]), pos)
		add_child(kiln)
		_kilns[int(k["idx"])] = kiln


func _place_plates() -> void:
	for p in L.get("plates", []):
		var plate := Plate.new()
		plate.setup(str(p["gate"]), int(p["idx"]), _v(p["pos"]), _mat_bar)
		add_child(plate)
		_plates.append(plate)


func _place_fragments() -> void:
	for f in L.get("fragments", []):
		var frag := Fragment.new()
		frag.setup(str(f["id"]), _v(f["pos"]), _mat_crystal)
		add_child(frag)
		_fragments[str(f["id"])] = frag


# ------------------------------------------------------------------ relics of the short way

func _place_relics() -> void:
	# One at the bottom of each secret ladder. Taking it is permanent and per player:
	# 1 = your name burns gold for your team, 2 = your rope turns gold, 3 = a crown.
	for r in L.get("relics", []):
		var id := str(r["id"])
		var pos := _v(r["pos"])
		var root := Node3D.new()
		root.position = pos
		for spec in [[1.5, Color(0.36, 0.26, 0.06, 0.8)], [0.5, Color(0.5, 0.4, 0.14, 0.95)]]:
			var mi := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(spec[0], spec[0])
			mi.mesh = qm
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_texture = _soft_dot()
			m.albedo_color = spec[1]
			m.disable_fog = true
			mi.material_override = m
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)
		var l := _add_light(pos, Color(1.0, 0.78, 0.3), 0.7, 12.0)
		if CoopSync.relic_has(id):
			root.scale = Vector3.ONE * 0.45          # you already carry this one
			l.light_energy = 0.25
		add_child(root)
		var a := _area(pos, 2.4, PLAYER_LAYER)
		a.body_entered.connect(func(body: Node3D): _on_relic(id, body, root, l))
		add_child(a)
	_apply_rope_gold()


func _on_relic(id: String, body: Node3D, root: Node3D, l: OmniLight3D) -> void:
	if body != Game.climber or _debug_tour or Game.climber.prevent_player_death:
		return          # the developer tour teleports through here: it must never hand out relics
	if not CoopSync.relic_grant(id):
		return
	root.scale = Vector3.ONE * 0.45
	l.light_energy = 0.25
	var n: int = CoopSync.cosmetics
	var what := "Your name burns gold for your team."
	if n == 2:
		what = "Your rope is gold now."
	elif n >= 3:
		what = "All three. Your team will see the crown."
	CoopSync.show_banner("A relic of the short way  (%d of 3).  %s" % [n, what], 7.0)
	Game.audio.play_dark_transition()
	_apply_rope_gold()


func _apply_rope_gold() -> void:
	if CoopSync.cosmetics < 2:
		return
	var c = Game.climber
	if not is_instance_valid(c):
		return
	for n in c.find_children("*", "", true, false):
		var mats = n.get("grapplePointLineMaterial")
		if mats is Array:
			for m in mats:
				if m is StandardMaterial3D:
					(m as StandardMaterial3D).albedo_color = Color(0.55, 0.4, 0.12)


func _place_altar() -> void:
	for a in L.get("altar", []):
		var pos := _v(a["pos"])
		var plinth := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 1.6
		cyl.bottom_radius = 2.1
		cyl.height = 1.4
		plinth.mesh = cyl
		plinth.material_override = _wall_mat[8]
		plinth.position = pos + Vector3(0, 0.7, 0)
		add_child(plinth)
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var sh := CylinderShape3D.new()
		sh.radius = 1.9
		sh.height = 1.4
		cs.shape = sh
		body.add_child(cs)
		body.position = plinth.position
		add_child(body)
		var idol: PackedScene = load("res://Art/Praxthos.glb")
		if idol:
			_idol_node = idol.instantiate()
			_idol_node.position = pos + Vector3(0, 1.4, 0)
			_idol_node.scale = Vector3.ONE * 1.3
			add_child(_idol_node)
		_altar_pos = pos
		_altar_light = _add_light(pos + Vector3(0, 3.5, 0), Color(1.0, 0.85, 0.5), 2.0, 26.0)
		var grab := _area(pos + Vector3(0, 2.2, 0), 3.2, PLAYER_LAYER)
		grab.body_entered.connect(_on_idol_touch)
		add_child(grab)
	for f in L.get("finish", []):
		var fin := _area(_v(f["pos"]), float(f["r"]), PLAYER_LAYER)
		fin.body_entered.connect(_on_finish)
		add_child(fin)


func _on_idol_touch(body: Node3D) -> void:
	if body != Game.climber or _idol_taken:
		return
	CoopSync.map_event("idol", {"by": CoopSync.local_name})


func _finale(by: String) -> void:
	if _idol_taken:
		return
	_idol_taken = true
	if is_instance_valid(_idol_node):
		_idol_node.visible = false
	Game.audio.play_dark_transition()
	# every light in the Nest dies for two seconds, then comes back red and pulsing
	_nest_lights.clear()
	for l in _lights:
		if is_instance_valid(l) and (l.position - _altar_pos).length() < 110.0:
			_nest_lights.append([l, l.light_energy, l.light_color])
	for e in _nest_lights:
		var tw := create_tween()
		tw.tween_property(e[0], "light_energy", 0.0, 0.4)
	CoopSync.show_banner("%s took the idol. THE NEST WAKES. RUN." % by, 6.0)
	if _music:
		_music.finale()
	await get_tree().create_timer(2.0).timeout
	if not is_inside_tree():
		return
	for e in _nest_lights:
		e[0].light_color = Color(1.0, 0.12, 0.08)
		var tw := create_tween()
		tw.tween_property(e[0], "light_energy", e[1] * 0.7, 1.0)
	if is_instance_valid(_altar_light):
		_altar_light.light_color = Color(1.0, 0.15, 0.1)
	for c in L.get("centipedes", []):
		if str(c.get("on", "")) == "idol":
			_release_centipedes(str(c["id"]))
	if _gates.has("gate_exit"):
		_gates["gate_exit"].latched = true
		_gates["gate_exit"].open()


# ------------------------------------------------------------------ the crucible

func _place_lanterns() -> void:
	# points of light hung along the rift, so the eye can measure the dark
	var sphere := QuadMesh.new()
	sphere.size = Vector2(1.0, 1.0)
	var mats: Dictionary = {}
	for ln in L.get("lanterns", []):
		var col := _c(ln["color"])
		var key := col.to_html()
		if not mats.has(key):
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_texture = _soft_dot()
			m.albedo_color = Color(col.r * 0.3, col.g * 0.3, col.b * 0.3, 0.9)
			m.disable_fog = true
			mats[key] = m
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = mats[key]
		mi.position = _v(ln["pos"])
		mi.scale = Vector3.ONE * float(ln["s"])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = 520.0
		add_child(mi)


func _place_mist() -> void:
	# Clouds that sit in the world: spore banks on the Fungal balconies, mist over the Drowned
	# footholds, cold haze in the Crystal Veins. They need the game's volumetric fog (on by
	# default in its video settings); with it off they simply are not there.
	for m in L.get("mist", []):
		var fv := FogVolume.new()
		fv.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
		var sz: Array = m["size"]
		fv.size = Vector3(float(sz[0]), float(sz[1]), float(sz[2]))
		var fm := FogMaterial.new()
		fm.density = float(m["density"])
		var col := _c(m["color"])
		fm.albedo = col
		fm.emission = Color(col.r * 0.06, col.g * 0.06, col.b * 0.06)
		fm.edge_fade = 0.6
		fv.material = fm
		fv.position = _v(m["pos"])
		add_child(fv)


func _place_platforms() -> void:
	var wood: StandardMaterial3D = load("res://Art/Textures/Wood_01.tres")
	for d in L.get("platforms", []):
		var pf := HangingPlatform.new()
		pf.setup(d, _mat_bar if str(d["kind"]) == "iron" else wood, _mat_bar)
		add_child(pf)
		_platforms[str(d["id"])] = pf


func _place_spars() -> void:
	for d in L.get("spars", []):
		var sp := CrystalSpar.new()
		sp.setup(_v(d["a"]), _v(d["b"]), float(d["r"]))
		add_child(sp)


func _place_falls() -> void:
	for d in L.get("falls", []):
		var wf := Waterfall.new()
		wf.setup(_v(d["pos"]), float(d["height"]), _v(d["push"]))
		add_child(wf)


func _place_ghosts() -> void:
	var ps: PackedScene = load("res://Art/Knight.glb")
	if ps == null:
		return
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.albedo_color = Color(0.1, 0.14, 0.16, 0.3)
	gm.cull_mode = BaseMaterial3D.CULL_BACK
	for g in L.get("ghosts", []):
		var gh := Ghost.new()
		gh.setup(ps, gm, _v(g["pos"]), float(g["yaw"]))
		add_child(gh)


func _place_bells() -> void:
	for b in L.get("bells", []):
		var bell := Bell.new()
		bell.setup(b, _mat_bar)
		add_child(bell)
		_bells[str(b["id"])] = bell


func _place_bars() -> void:
	for b in L.get("bars", []):
		var bar := MonkeyBar.new()
		bar.dot_tex = _soft_dot()
		bar.setup(b, _mat_bar)
		add_child(bar)
		_bars.append(bar)


func _place_lava() -> void:
	for lv in L.get("lava", []):
		var c := _v(lv["center"])
		var yaw := float(lv["yaw"])
		var d := Vector3(cos(yaw), 0, sin(yaw))
		var s := Vector3(-sin(yaw), 0, cos(yaw))
		var hw := float(lv["half_w"])
		var hl := float(lv["half_l"])
		var mi := MeshInstance3D.new()
		var stl := SurfaceTool.new()
		stl.begin(Mesh.PRIMITIVE_TRIANGLES)
		var rr := maxf(hw, hl) * 1.25
		for i in 48:
			var a0 := TAU * float(i) / 48.0
			var a1 := TAU * float(i + 1) / 48.0
			stl.set_normal(Vector3.UP)
			stl.add_vertex(Vector3.ZERO)
			stl.set_normal(Vector3.UP)
			stl.add_vertex(Vector3(cos(a1) * rr, 0, sin(a1) * rr))
			stl.set_normal(Vector3.UP)
			stl.add_vertex(Vector3(cos(a0) * rr, 0, sin(a0) * rr))
		mi.mesh = stl.commit()
		mi.material_override = _mat_lava
		mi.position = c
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_add_light(c + Vector3(0, 6, 0), Color(1.0, 0.45, 0.1), 3.0, 70.0)
		_add_light(c + d * hw * 0.6 + Vector3(0, 6, 0), Color(1.0, 0.45, 0.1), 2.0, 50.0)
		_add_light(c - d * hw * 0.6 + Vector3(0, 6, 0), Color(1.0, 0.45, 0.1), 2.0, 50.0)
		_lava_box = [c, d, s, hw, hl]
		_lava_kill_y = c.y + 3.0


func _check_lava() -> void:
	if _lava_box.is_empty():
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating"):
		return
	var p: Vector3 = c.global_position
	if p.y > _lava_kill_y:
		return
	var q: Vector3 = p - _lava_box[0]
	if absf(q.dot(_lava_box[1])) < _lava_box[3] and absf(q.dot(_lava_box[2])) < _lava_box[4]:
		if c.health > 0.0 and not c.lethalDamageHandled:
			c.take_damage(400.0)


# ------------------------------------------------------------------ creatures and scares

func _place_creatures() -> void:
	for s in L.get("stalkers", []):
		var st := Stalker.new()
		st.setup(s)
		add_child(st)
		_stalkers.append(st)
	for c in L.get("centipedes", []):
		if c.has("on"):
			continue
		var trig: Array = c["trigger"]
		var a := _area(_v(trig[0]), float(trig[1]), PLAYER_LAYER)
		var id := str(c["id"])
		a.body_entered.connect(func(body: Node3D): _on_centipede_trigger(id, body))
		add_child(a)


func _on_centipede_trigger(id: String, body: Node3D) -> void:
	if body != Game.climber:
		return
	CoopSync.map_event("cent_" + id, {"id": id})


func _release_centipedes(id: String) -> void:
	if _spawned_cents.has(id):
		return
	_spawned_cents[id] = true
	# Guests get puppets from the host's centipede stream, so only the authority spawns.
	if not CoopSync.map_is_authority():
		return
	var ps: PackedScene = load(CENTIPEDE)
	if ps == null:
		return
	for c in L["centipedes"]:
		if str(c["id"]) != id:
			continue
		for sp in c["spawn"]:
			var n: Node3D = ps.instantiate()
			n.position = _v(sp)
			if c.has("territory"):
				# it belongs to this biome and stays here after you leave
				var t: Array = c["territory"]
				n.set_meta("zonda_territory", [float(t[0]), float(t[1])])
				_territorial.append([n, float(t[0]), float(t[1]), _v(sp)])
			add_child(n)
			if bool(c.get("follower", false)):
				_follower = n
	if id == "follower":
		CoopSync.show_banner("Something followed you in. It will not stop.", 4.0)
	else:
		CoopSync.show_banner("Something lives here.", 3.0)
	Game.audio.play_dark_transition()


# One centipede follows the team for the whole descent. It cannot squeeze through the Burrows
# or path around the Lid, so when it falls far behind (or is walled off) the host puts it back
# on the rift wall above and behind the team, out of sight. It never appears ahead of you.
func _update_centipedes(delta: float) -> void:
	if not CoopSync.map_is_authority():
		return
	_cent_tick -= delta
	if _cent_tick > 0.0:
		return
	_cent_tick = 2.0
	var players: Array = CoopSync.alive_player_nodes()
	if players.is_empty():
		return
	if _spawned_cents.has("follower"):
		var need := false
		if not is_instance_valid(_follower) or not _follower.is_inside_tree():
			need = true
		else:
			var d := 1e9
			for p in players:
				d = minf(d, (p as Node3D).global_position.distance_to(_follower.global_position))
			if d < _follow_best - 6.0:
				_follow_best = d
				_follow_stall = 0.0
			else:
				_follow_stall += 2.0
			if d > 240.0 or (_follow_stall >= 36.0 and d > 55.0):
				need = true
		if need:
			var spot = _follower_spot(players)
			if spot != null:
				if is_instance_valid(_follower):
					Game.centipedes.erase(_follower)
					_follower.queue_free()
				var ps: PackedScene = load(CENTIPEDE)
				var n: Node3D = ps.instantiate()
				n.position = spot
				add_child(n)
				_follower = n
				_follow_best = 1e9
				_follow_stall = 0.0
	# the ones that live in a biome: idle when nobody is in it, and never wander out of it
	for e in _territorial:
		var n2 = e[0]
		if not is_instance_valid(n2) or not n2.is_inside_tree():
			continue
		var target = CoopSync.target_player_for(n2)
		if target == null and (n2._current_state is centipede_state_hunting or n2._current_state is centipede_state_attack):
			n2.set_state(centipede_state_wander.new())
		var y: float = n2.global_position.y
		if target == null and (y > float(e[1]) + 40.0 or y < float(e[2]) - 40.0):
			var near := 1e9
			for p in players:
				near = minf(near, (p as Node3D).global_position.distance_to(n2.global_position))
			if near > 120.0:
				n2.global_position = e[3]
				n2.set_state(centipede_state_wander.new())


func _follower_spot(players: Array):
	var top_y := -1e9
	for p in players:
		top_y = maxf(top_y, (p as Node3D).global_position.y)
	var best = null
	var best_score := 1e9
	for st in L.get("stations", []):
		var pos := _v(st["pos"])
		if pos.y < top_y + 25.0:
			continue
		var dmin := 1e9
		for p in players:
			dmin = minf(dmin, (p as Node3D).global_position.distance_to(pos))
		if dmin < 70.0 or dmin > 150.0:
			continue
		var score := absf(dmin - 100.0)
		if score < best_score:
			best_score = score
			best = pos + Vector3(0, 3.0, 0)
	return best


func _place_ambience() -> void:
	for a in L.get("ambience", []):
		var amb := Ambience.new()
		amb.setup(a)
		add_child(amb)


func _place_dying_lights() -> void:
	for d in L.get("dying_lights", []):
		var dl := DyingLights.new()
		dl.setup(d)
		add_child(dl)
		_dying[str(d["id"])] = dl


# ------------------------------------------------------------------ events (synced)

func coop_map_event(key: String, data: Dictionary) -> void:
	if key.begins_with("cent_"):
		_release_centipedes(str(data.get("id", key.substr(5))))
	elif key.begins_with("crumble_"):
		var id := key.substr(8)
		if _crumbles.has(id):
			_crumbles[id].remote_collapse()
	elif key.begins_with("drop_"):
		var id := key.substr(5)
		if _droppers.has(id):
			_droppers[id].remote_drop()
	elif key.begins_with("kiln_"):
		var idx := int(key.substr(5))
		if _kilns.has(idx):
			_kilns[idx].light_up()
		_check_kiln_gate()
	elif key.begins_with("frag_"):
		var id := key.substr(5)
		if _fragments.has(id):
			_fragments[id].collect(str(data.get("by", "")))
		_frag_count = 0
		for fid in _fragments.keys():
			if _fragments[fid].collected:
				_frag_count += 1
		CoopSync.show_banner("Idol fragment %d / 3" % _frag_count, 4.0)
		_check_idol_gate()
	elif key.begins_with("gate_"):
		if _gates.has(key):
			_gates[key].open()
	elif key.begins_with("dying_"):
		var id := key.substr(6)
		if _dying.has(id):
			_dying[id].begin()
	elif key.begins_with("stalkbite_"):
		if int(data.get("who", -1)) == CoopSync.my_id():
			var sid := key.substr(10)
			for s in _stalkers:
				if s.id == sid:
					s.bite_local()
	elif key.begins_with("pfdrop_"):
		var pid := key.substr(7)
		if _platforms.has(pid):
			_platforms[pid].drop_now()
	elif key.begins_with("bell_"):
		var bid := key.substr(5)
		if _bells.has(bid):
			_bells[bid].toll()
	elif key == "idol":
		_finale(str(data.get("by", "")))
	elif key.begins_with("barsink_"):
		var bi := int(key.substr(8))
		for b in _bars:
			if b.idx == bi:
				b.sink_now()
	elif key == "finish":
		_finish(str(data.get("by", "")))


func _reapply_events() -> void:
	var ev := CoopSync.map_events_for(scene_file_path)
	for k in ev.keys():
		var d = ev[k]
		coop_map_event(str(k), d if typeof(d) == TYPE_DICTIONARY else {})


func coop_map_stream(d: Dictionary, _ts: int) -> void:
	# host -> guests: stalker positions and plate state
	if d.has("st"):
		var arr: Array = d["st"]
		for i in mini(arr.size(), _stalkers.size()):
			_stalkers[i].remote_state(arr[i])
	if d.has("pl"):
		var pl: Array = d["pl"]
		for i in mini(pl.size(), _plates.size()):
			_plates[i].remote_pressed(bool(pl[i]))
	if d.has("open"):
		for gid in d["open"]:
			if _gates.has(str(gid)) and not _gates[str(gid)].is_open:
				_gates[str(gid)].open()
	if d.has("closed"):
		for gid in d["closed"]:
			if _gates.has(str(gid)) and _gates[str(gid)].is_open and not _gates[str(gid)].latched:
				_gates[str(gid)].close()


func _check_kiln_gate() -> void:
	var lit := 0
	for k in _kilns.values():
		if k.lit:
			lit += 1
	if lit >= 4 and _gates.has("gate_kilns") and not _gates["gate_kilns"].is_open:
		_gates["gate_kilns"].latched = true
		CoopSync.map_event("gate_kilns", {})
		CoopSync.show_banner("The kilns roar. Stone grinds somewhere ahead.", 5.0)


func _check_idol_gate() -> void:
	if _frag_count >= 3 and _gates.has("gate_idol") and not _gates["gate_idol"].is_open:
		_gates["gate_idol"].latched = true
		CoopSync.map_event("gate_idol", {})
		CoopSync.show_banner("The idol is whole. The Foundry door opens.", 5.0)


func _update_plates(delta: float) -> void:
	# Host decides. Plates needed = living players; solo gets a 6 s window.
	if _plates.is_empty() or not _gates.has("gate_plates"):
		return
	var gate: Gate = _gates["gate_plates"]
	if gate.latched:
		return
	var states: Array = []
	var pressed := 0
	for p in _plates:
		var on: bool = p.check_local_press()
		states.append(on)
		if on:
			pressed += 1
	if not CoopSync.map_is_authority():
		return
	var need: int = maxi(1, CoopSync.alive_player_count())
	var want_open: bool = pressed >= need
	if need == 1 and pressed >= 1:
		gate.solo_timer = 16.0
	if gate.solo_timer > 0.0:
		gate.solo_timer -= delta
		want_open = true
	if want_open and not gate.is_open:
		gate.open()
		if need > 1:
			gate.latched = true
			CoopSync.map_event("gate_plates", {})
		else:
			CoopSync.show_banner("The door opens... for a moment. Run.", 3.0)
	elif not want_open and gate.is_open and not gate.latched:
		gate.close()
	_stream_accum += delta
	if _stream_accum > 0.1:
		_stream_accum = 0.0
		var open_ids: Array = []
		var closed_ids: Array = []
		for gid in _gates.keys():
			if _gates[gid].is_open:
				open_ids.append(gid)
			elif gid == "gate_plates":
				closed_ids.append(gid)
		var st: Array = []
		for s in _stalkers:
			st.append(s.state_packet())
		CoopSync.map_stream({"pl": states, "open": open_ids, "closed": closed_ids, "st": st})


var _stream_accum := 0.0


func _on_finish(body: Node3D) -> void:
	if body != Game.climber or _finished:
		return
	if not _idol_taken:
		CoopSync.show_banner("The way out is sealed. The idol on the altar is the key.", 4.0)
		return
	CoopSync.map_event("finish", {"by": CoopSync.local_name})


func _finish(by: String) -> void:
	if _finished:
		return
	_finished = true
	Game.audio.play_player_healed()
	var secs := (Time.get_ticks_msec() - _run_start_ms) / 1000
	CoopSync.show_banner("%s took the idol. THE UNDERDARK is cleared in %02d:%02d." % [by, secs / 60, secs % 60], 10.0)
	await get_tree().create_timer(10.0).timeout
	if not is_inside_tree():
		return
	if CoopSync.in_session() and not CoopSync.is_host:
		return
	SceneLoader.load_scene(func():
		Game.on_new_loaded_level()
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn"))


# ------------------------------------------------------------------ per frame

func _physics_process(_delta: float) -> void:
	# On Normal the game caps fall damage at 62 HP, so jumping down was always the fast way.
	# Here LANDING a fall of 40 m or more (38 m/s) kills, and even a one-balcony jump costs a
	# third of your health. The rope itself is untouched: a catch forgives the fall.
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating"):
		_fall_speed = 0.0
		return
	if c.is_on_floor():
		if _fall_speed > _lethal_fall and c.health > 0.0 and not c.lethalDamageHandled and not c.prevent_player_death:
			CoopSync.show_banner("The fall killed you. In the Underdark, trust the rope.", 4.0)
			c.take_damage(1000.0)
		elif _fall_speed > _bruise_from and c.health > 0.0 and not c.lethalDamageHandled and not c.prevent_player_death:
			# take_damage halves what it is given
			c.take_damage((_fall_speed - _bruise_from) * _bruise_per * 2.0)
			if not _bruise_told:
				_bruise_told = true
				CoopSync.show_banner("That landing cost you. Let the rope out instead of jumping.", 4.0)
		_fall_speed = 0.0
	elif c.activeClimberState is ClimberState_Attached:
		# The rope is left exactly as the game made it: a catch forgives the fall, at any speed.
		_fall_speed = minf(_fall_speed, maxf(0.0, -c.velocity.y))
	else:
		_fall_speed = maxf(_fall_speed * 0.98, -c.velocity.y)


func _process(delta: float) -> void:
	_clock += delta
	_mat_lava.set_shader_parameter("t", _clock)
	if _idol_taken and _nest_lights.size() > 0:
		var k := 0.55 + 0.45 * absf(sin(_clock * 2.6))
		for e in _nest_lights:
			if is_instance_valid(e[0]):
				e[0].light_energy = e[1] * 0.7 * k
	_update_lod(delta)
	_update_environment(delta)
	_update_plates(delta)
	_update_centipedes(delta)
	_rope_gold_t -= delta
	if _rope_gold_t <= 0.0:
		_rope_gold_t = 3.0
		_apply_rope_gold()          # the game rebuilds its rope materials now and then
	_update_hud()
	_check_lava()
	if _debug_tour:
		_update_tour(delta)


func _update_lod(delta: float) -> void:
	# Only chunks near the local player (or any teammate) are visible / collidable.
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var centers: Array = [c.global_position]
	for rp in CoopSync.remote_players():
		centers.append(rp.global_position)
	var n := _chunks.size()
	if n == 0:
		return
	var per_frame := maxi(8, n / 6)
	for k in per_frame:
		_lod_index = (_lod_index + 1) % n
		var entry: Array = _chunks[_lod_index]
		var mi: MeshInstance3D = entry[0]
		var best := 1e9
		for p in centers:
			best = minf(best, (p - entry[1]).length() - entry[2])
		var want: bool = best < VIEW_RANGE
		if mi.visible != want:
			mi.visible = want
		var body: StaticBody3D = mi.get_child(0)
		var solid: int = 1 if best < SOLID_RANGE else 0
		if body.collision_layer != solid:
			body.collision_layer = solid


func _setup_environment() -> void:
	var we := get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	_env = we.environment.duplicate()
	we.environment = _env
	_env.fog_depth_begin = 14.0
	_env.fog_depth_end = 400.0
	_look_from = LOOKS[0]
	_look_to = LOOKS[0]
	_apply_look(LOOKS[0])
	_make_sky_lights()


func _make_sky_lights() -> void:
	# added late on purpose: the game collects the level's directional lights one frame after
	# load and switches them off 250 m down. These two are not in its list.
	await get_tree().create_timer(1.0).timeout
	_sky = DirectionalLight3D.new()
	_sky.set_meta("zonda_no_shadow", true)
	_sky.shadow_enabled = false
	_sky.light_energy = 0.0
	_sky.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	_sky.rotation = Vector3(deg_to_rad(-62.0), deg_to_rad(35.0), 0.0)
	add_child(_sky)
	_glow = DirectionalLight3D.new()                      # the lava lake, from underneath
	_glow.set_meta("zonda_no_shadow", true)
	_glow.shadow_enabled = false
	_glow.light_energy = 0.0
	_glow.light_color = Color(1.0, 0.34, 0.07)
	_glow.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	_glow.rotation = Vector3(deg_to_rad(76.0), deg_to_rad(-25.0), 0.0)
	add_child(_glow)


func _in_zone(p: Vector3) -> bool:
	for z in L.get("zones", []):
		var c := _v(z["center"])
		if p.y > float(z["floor"]) - 8.0 and p.y < float(z["top"]) + 8.0:
			if (Vector3(p.x, 0, p.z) - Vector3(c.x, 0, c.z)).length() < float(z["radius"]):
				return true
	return false


func _update_sky_lights(delta: float, p: Vector3) -> void:
	if _sky == null or _glow == null or _look_now.is_empty():
		return
	var inside := _in_zone(p)
	var want: float = 0.0 if inside else float(SKYGLOW[clampi(_cur_biome, 0, SKYGLOW.size() - 1)])
	_sky.light_energy = lerpf(_sky.light_energy, want, minf(1.0, delta * (8.0 if _debug_tour else 0.7)))
	var a: Color = _look_now[2]
	var m := maxf(0.001, maxf(a.r, maxf(a.g, a.b)))
	_sky.light_color = Color(a.r / m, a.g / m, a.b / m).lerp(Color.WHITE, 0.35)
	var lake := float(L["lava"][0]["center"][1]) if L.get("lava", []).size() > 0 else -1e9
	var heat := 0.0 if inside else clampf(1.0 - (p.y - lake) / 430.0, 0.0, 1.0)
	_glow.light_energy = lerpf(_glow.light_energy, 0.42 * heat * heat, minf(1.0, delta * (8.0 if _debug_tour else 0.7)))


func _apply_look(k: Array) -> void:
	_look_now = k.duplicate()
	var amb: Color = k[2]
	_env.ambient_light_color = Color(amb.r * AMB_GAIN, amb.g * AMB_GAIN, amb.b * AMB_GAIN)
	_env.fog_light_color = k[3]
	_env.fog_density = k[4]
	_env.background_color = k[3]
	_env.background_energy_multiplier = k[5]
	_env.volumetric_fog_albedo = k[3].lightened(0.5)
	_env.volumetric_fog_emission = k[3] * 0.4
	_env.volumetric_fog_emission_energy = 0.4


func _biome_at(p: Vector3) -> int:
	for z in L.get("zones", []):
		var c := _v(z["center"])
		if p.y > float(z["floor"]) - 8.0 and p.y < float(z["top"]) + 8.0:
			if (Vector3(p.x, 0, p.z) - Vector3(c.x, 0, c.z)).length() < float(z["radius"]):
				return int(z["biome"])
	for st in L.get("strata", []):
		if p.y <= float(st["top"]) and p.y > float(st["bottom"]):
			return int(st["biome"])
	return 0 if p.y > -40.0 else 8


func _update_environment(delta: float) -> void:
	if _env == null:
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var b := _biome_at(c.global_position)
	if b < 0:
		return
	_update_sky_lights(delta, c.global_position)
	if _weather:
		_weather.follow(c, b)
	if b != _cur_biome:
		_cur_biome = b
		_look_from = _current_look()
		_look_to = LOOKS[b]
		_blend = 0.0
		if _music:
			_music.set_biome(b)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta * (6.0 if _debug_tour else 0.25))
		var mixed: Array = []
		for i in _look_to.size():
			if _look_to[i] is Color:
				mixed.append((_look_from[i] as Color).lerp(_look_to[i], _blend))
			else:
				mixed.append(lerpf(_look_from[i], _look_to[i], _blend))
		_apply_look(mixed)


func _current_look() -> Array:
	if not _look_now.is_empty():
		return _look_now.duplicate()
	return LOOKS[0].duplicate()


# ------------------------------------------------------------------ hud

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 60
	_hud_depth = Label.new()
	_hud_depth.anchor_left = 1.0
	_hud_depth.anchor_right = 1.0
	_hud_depth.offset_left = -230.0
	_hud_depth.offset_right = -10.0
	_hud_depth.offset_top = 8.0
	_hud_depth.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var ls := LabelSettings.new()
	ls.font_size = 11
	ls.outline_size = 3
	ls.outline_color = Color.BLACK
	ls.font_color = Color(0.9, 0.85, 0.75)
	_hud_depth.label_settings = ls
	_hud.add_child(_hud_depth)
	add_child(_hud)


func _update_hud() -> void:
	var c = Game.climber
	if _hud_depth == null or not is_instance_valid(c) or not c.is_inside_tree():
		return
	var secs := (Time.get_ticks_msec() - _run_start_ms) / 1000
	var b := _cur_biome
	var bname: String = str(L["biomes"][b]) if b >= 0 else ""
	var relics := ""
	if CoopSync.cosmetics > 0:
		relics = "   relics %d/3" % CoopSync.cosmetics
	_hud_depth.text = "%s   %d m   %02d:%02d%s" % [bname, int(-c.global_position.y), secs / 60, secs % 60, relics]


# ------------------------------------------------------------------ debug tour (screenshots)

func _update_tour(delta: float) -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var stops: Array = L.get("tour", [])
	if stops.is_empty():
		return
	_tour_t -= delta
	if _tour_i >= 0 and _tour_i < stops.size() and stops[_tour_i].get("air", false):
		c.velocity = Vector3.ZERO
		c.AirVelocity = Vector3.ZERO
		c.global_position = _v(stops[_tour_i]["pos"])
	if _tour_t < 0.9 and not _tour_shot_done and _tour_i >= 0:
		_tour_shot_done = true
		var img := get_viewport().get_texture().get_image()
		if img:
			if img.get_width() > 960:
				img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
			img.save_png("user://underdark_tour_%02d.png" % _tour_i)
		print("[Underdark] tour fps %d at stop %d y=%.1f floor=%s" % [Engine.get_frames_per_second(), _tour_i, c.global_position.y, str(c.is_on_floor())])
	if _tour_t > 0.0:
		return
	_tour_i += 1
	_tour_shot_done = false
	if _tour_i >= stops.size():
		_debug_tour = false
		print("[Underdark] tour done")
		return
	_tour_t = 2.2
	var s: Dictionary = stops[_tour_i]
	var pos := _v(s["pos"])
	var look := _v(s["look"])
	c.prevent_player_death = true
	c.health = c.healthMax
	c.set_climber_state(c.defaultClimberState)
	c.velocity = Vector3.ZERO
	c.AirVelocity = Vector3.ZERO
	c.teleport_to_location(pos)
	var dir := (look - pos).normalized()
	var yaw := atan2(-dir.x, -dir.z)
	var pitch := asin(clampf(dir.y, -1.0, 1.0))
	c.PlayerCamera.set_camera_rotation(Vector3(pitch, yaw, 0.0))
	c.global_rotation = Vector3.ZERO
	print("[Underdark] tour %d/%d %s at %s" % [_tour_i + 1, stops.size(), s.get("label", ""), pos])


# ------------------------------------------------------------------ helpers

func _v(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _c(a) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


func _area(pos: Vector3, radius: float, mask: int) -> Area3D:
	var a := Area3D.new()
	a.collision_layer = 0
	a.collision_mask = mask
	var shape := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = radius
	shape.shape = sph
	a.add_child(shape)
	a.position = pos
	return a


class Weather extends Node3D:
	# Particles that live in a box around the local camera. One emitter per kind of weather,
	# switched by biome. Colours are kept dim: the game doubles brightness and clips early.
	var kinds: Dictionary = {}
	var dot: Texture2D
	var cur := -2
	const BY_BIOME := {
		0: ["dust"], 1: ["bone_ash"], 2: ["spores", "spores_big"], 3: ["dust", "drips_light"],
		4: ["drips", "mist_motes"], 5: ["dust_violet"], 6: ["glitter"], 7: ["ash", "sparks"],
		8: ["red_motes"], 9: [],
	}

	func build(dot_tex: Texture2D) -> void:
		dot = dot_tex
		#      name            n    life  box                   gravity                 v0    v1   size   colour                          streak  y_off spread
		_add("dust",          210, 8.0, Vector3(26, 14, 26), Vector3(0.05, -0.08, 0.0), 0.05, 0.3, 0.15, Color(0.30, 0.27, 0.21, 0.5), false, 0.0, 180.0)
		_add("dust_violet",   210, 8.0, Vector3(26, 14, 26), Vector3(-0.04, -0.1, 0.03), 0.05, 0.3, 0.15, Color(0.24, 0.2, 0.32, 0.5), false, 0.0, 180.0)
		_add("bone_ash",      260, 7.0, Vector3(26, 16, 26), Vector3(0.0, -0.55, 0.0), 0.1, 0.5, 0.14, Color(0.33, 0.32, 0.29, 0.6), false, 4.0, 60.0)
		_add("spores",        300, 9.0, Vector3(24, 12, 24), Vector3(0.0, 0.22, 0.0), 0.05, 0.35, 0.14, Color(0.1, 0.34, 0.2, 0.8), false, -3.0, 180.0)
		_add("spores_big",     26, 12.0, Vector3(20, 10, 20), Vector3(0.0, 0.1, 0.0), 0.02, 0.15, 0.55, Color(0.05, 0.2, 0.11, 0.35), false, -2.0, 180.0)
		_add("drips_light",    70, 1.7, Vector3(22, 0.5, 22), Vector3(0.0, -14.0, 0.0), 2.0, 5.0, 1.0, Color(0.2, 0.24, 0.26, 0.55), true, 12.0, 4.0)
		_add("drips",         260, 1.7, Vector3(24, 0.5, 24), Vector3(0.0, -14.0, 0.0), 2.0, 6.0, 1.0, Color(0.18, 0.25, 0.3, 0.6), true, 12.0, 5.0)
		_add("mist_motes",     30, 10.0, Vector3(22, 6, 22), Vector3(0.1, 0.02, 0.0), 0.05, 0.25, 1.6, Color(0.1, 0.14, 0.16, 0.22), false, -2.0, 180.0)
		_add("glitter",       280, 6.0, Vector3(22, 12, 22), Vector3(0.0, -0.3, 0.0), 0.05, 0.3, 0.08, Color(0.22, 0.32, 0.5, 0.9), false, 3.0, 180.0)
		_add("ash",           280, 7.0, Vector3(26, 16, 26), Vector3(0.1, -0.5, 0.0), 0.1, 0.5, 0.16, Color(0.15, 0.13, 0.12, 0.8), false, 5.0, 70.0)
		_add("sparks",        170, 3.5, Vector3(24, 6, 24), Vector3(0.0, 1.7, 0.0), 0.5, 2.2, 0.09, Color(0.5, 0.16, 0.03, 0.9), false, -8.0, 40.0)
		_add("red_motes",     140, 8.0, Vector3(24, 12, 24), Vector3(0.0, 0.05, 0.0), 0.05, 0.3, 0.09, Color(0.34, 0.04, 0.04, 0.7), false, 0.0, 180.0)

	func _add(kind: String, n: int, life: float, ext: Vector3, grav: Vector3, v0: float, v1: float, size: float, col: Color, streak: bool, y_off: float, spread: float) -> void:
		var p := CPUParticles3D.new()
		p.amount = n
		p.lifetime = life
		p.randomness = 1.0
		p.local_coords = false
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		p.emission_box_extents = ext
		p.direction = Vector3.UP if grav.y > 0.0 else Vector3.DOWN
		p.spread = spread
		p.gravity = grav
		p.initial_velocity_min = v0
		p.initial_velocity_max = v1
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.4
		p.color = col
		var fm := StandardMaterial3D.new()
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fm.vertex_color_use_as_albedo = true
		fm.disable_receive_shadows = true
		if streak:
			var bm := BoxMesh.new()
			bm.size = Vector3(0.025, 0.55, 0.025)
			bm.material = fm
			p.mesh = bm
			p.particle_flag_align_y = true
		else:
			fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
			fm.albedo_texture = dot
			var qm := QuadMesh.new()
			qm.size = Vector2(size, size)
			qm.material = fm
			p.mesh = qm
		p.position = Vector3(0, y_off, 0)
		p.emitting = false
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		kinds[kind] = p

	func follow(c: Node3D, biome: int) -> void:
		var cam = c.get("Camera")
		global_position = (cam as Node3D).global_position if is_instance_valid(cam) else c.global_position
		if biome == cur:
			return
		cur = biome
		var on: Array = BY_BIOME.get(biome, [])
		for k in kinds.keys():
			var want: bool = on.has(k)
			var p: CPUParticles3D = kinds[k]
			if p.emitting != want:
				p.emitting = want


class U:
	static func sfx(path: String, db: float, pos: Vector3, parent: Node, max_dist: float = 40.0) -> AudioStreamPlayer3D:
		var p := AudioStreamPlayer3D.new()
		p.stream = load(path)
		p.volume_db = db
		p.max_distance = max_dist
		p.bus = &"MainBus"
		p.position = pos
		parent.add_child(p)
		return p


# ================================================================== trap classes

class Crumble extends Node3D:
	# Rumbles and shakes for a full second, then drops. Synced: whoever triggers it
	# tells everyone, and the fall happens on every screen.
	var id := ""
	var piece: Node3D
	var area: Area3D
	var origin: Vector3
	var stand_time := 0.0
	var state := 0
	var shake_t := 0.0
	var sfx_rumble: AudioStreamPlayer3D
	var sfx_gravel: AudioStreamPlayer3D
	var reach := 4.0

	func setup(i: String, p: Node3D, r: float) -> void:
		id = i
		piece = p
		reach = r
		origin = p.position
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = r
		shape.shape = sph
		area.add_child(shape)
		area.position = origin + Vector3(0, 1.2, 0)

	func _ready() -> void:
		add_child(area)
		sfx_rumble = U.sfx(SFX_RUMBLE, -4.0, origin, self, 45.0)
		sfx_gravel = U.sfx(SFX_GRAVEL, -2.0, origin, self, 45.0)

	func _process(delta: float) -> void:
		if not is_instance_valid(piece):
			return
		if state == 0:
			var c = Game.climber
			if is_instance_valid(c) and area.overlaps_body(c):
				stand_time += delta
				if stand_time > 0.9:
					CoopSync.map_event("crumble_" + id, {}, false)
			else:
				stand_time = maxf(0.0, stand_time - delta * 2.0)
		elif state == 1:
			shake_t += delta
			var k := 0.06 + 0.16 * shake_t
			piece.position = origin + Vector3(sin(shake_t * 60.0) * k, -shake_t * 0.12, cos(shake_t * 52.0) * k)
			if shake_t > 1.05:
				_fall()

	func remote_collapse() -> void:
		if state != 0:
			return
		state = 1
		shake_t = 0.0
		sfx_rumble.play()
		sfx_gravel.play()

	func _fall() -> void:
		state = 2
		var c = Game.climber
		if is_instance_valid(c) and c.activeClimberState is ClimberState_Attached and is_instance_valid(c.Rope._claw):
			if c.Rope._claw.global_position.distance_to(piece.global_position) < reach + 1.5:
				c.set_climber_state(c.defaultClimberState)
				Game.audio.play_rope_snap_sfx()
		Game.audio.play_metal_hit(piece.global_position)
		var tw := create_tween()
		tw.tween_property(piece, "position:y", origin.y - 80.0, 1.7).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(_hide)
		await get_tree().create_timer(30.0).timeout
		if not is_instance_valid(piece):
			return
		piece.position = origin
		piece.visible = true
		_collision(true)
		stand_time = 0.0
		state = 0

	func _hide() -> void:
		if is_instance_valid(piece):
			piece.visible = false
			_collision(false)

	func _collision(on: bool) -> void:
		for body in piece.find_children("*", "StaticBody3D", true, false):
			body.collision_layer = 1 if on else 0


class FireVent extends Node3D:
	var fire: Node3D
	var light: OmniLight3D
	var area: Area3D
	var period := 7.0
	var phase := 0.0
	var clock := 0.0
	var tick := 0.0
	var was_active := false

	func setup(f: Node3D, l: OmniLight3D, pos: Vector3, p: float, ph: float) -> void:
		fire = f
		light = l
		period = p
		phase = ph
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 3.2
		shape.shape = sph
		area.add_child(shape)
		area.position = pos + Vector3(0, 1.4, 0)

	func _ready() -> void:
		add_child(area)

	func _process(delta: float) -> void:
		clock += delta
		var t: float = fmod(clock + phase, period)
		var active: bool = t < 2.2
		if is_instance_valid(fire):
			var target := 1.15 if active else 0.35
			var sc: float = lerpf(fire.scale.x, target, clampf(delta * 8.0, 0.0, 1.0))
			fire.scale = Vector3(sc, sc, sc)
		if is_instance_valid(light):
			light.light_energy = lerpf(light.light_energy, 0.7 + (2.6 if active else 0.0), clampf(delta * 8.0, 0.0, 1.0))
		if not active:
			was_active = false
			tick = 0.0
			return
		var c = Game.climber
		if not is_instance_valid(c):
			return
		if area.overlaps_body(c):
			tick -= delta
			if tick <= 0.0:
				tick = 0.7
				c.take_damage(12.0)
				if not was_active:
					c.additional_velocity_next_frame += Vector3.UP * 7.0
			was_active = true


class Dropper extends Node3D:
	var id := ""
	var rock: Node3D
	var trip: Area3D
	var hurt: Area3D
	var rest: Vector3
	var floor_y := 0.0
	var falling := false
	var armed := true
	var hit_done := false
	var damage := 60.0
	var fall_time := 1.1
	var reset_after := 28.0

	func setup(i: String, r: Node3D, trip_pos: Vector3, trip_r: float, hurt_r: float, fy: float) -> void:
		id = i
		rock = r
		rest = r.position
		floor_y = fy
		trip = Area3D.new()
		trip.collision_layer = 0
		trip.collision_mask = 4
		var ts := CollisionShape3D.new()
		var tsph := SphereShape3D.new()
		tsph.radius = trip_r
		ts.shape = tsph
		trip.add_child(ts)
		trip.position = trip_pos
		hurt = Area3D.new()
		hurt.collision_layer = 0
		hurt.collision_mask = 4
		var hs := CollisionShape3D.new()
		var hsph := SphereShape3D.new()
		hsph.radius = hurt_r
		hs.shape = hsph
		hurt.add_child(hs)

	func _ready() -> void:
		add_child(trip)
		add_child(hurt)
		trip.body_entered.connect(_on_trip)

	func _on_trip(body: Node3D) -> void:
		if not armed or body != Game.climber:
			return
		CoopSync.map_event("drop_" + id, {}, false)

	func remote_drop() -> void:
		if not armed:
			return
		armed = false
		falling = true
		hit_done = false
		Game.audio.play_metal_hit(rock.global_position)
		var tw := create_tween()
		tw.tween_property(rock, "position:y", floor_y - 1.0, fall_time).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(func(): falling = false)
		await get_tree().create_timer(reset_after).timeout
		if not is_instance_valid(rock):
			return
		rock.position = rest
		armed = true

	func _process(_delta: float) -> void:
		if not falling or hit_done or not is_instance_valid(rock) or not is_instance_valid(Game.climber):
			return
		hurt.global_position = rock.global_position
		if hurt.overlaps_body(Game.climber):
			hit_done = true
			var c = Game.climber
			c.take_damage(damage)
			var away: Vector3 = c.global_position - rock.global_position
			away.y = 0.0
			away = away.normalized() if away.length_squared() > 0.001 else Vector3.RIGHT
			c.additional_velocity_next_frame += away * 14.0 + Vector3.DOWN * 6.0
			Game.audio.play_player_was_bit()


class SpikeBed extends Node3D:
	var hurt: Area3D
	var shove: Vector3
	var cooldown := 0.0

	func setup(h: Area3D, push: Vector3) -> void:
		hurt = h
		shove = push

	func _process(delta: float) -> void:
		cooldown = maxf(0.0, cooldown - delta)
		if cooldown > 0.0 or not is_instance_valid(hurt) or not is_instance_valid(Game.climber):
			return
		if hurt.overlaps_body(Game.climber):
			cooldown = 1.4
			var c = Game.climber
			c.take_damage(40.0)
			c.additional_velocity_next_frame += shove * 15.0 + Vector3.UP * 5.0
			if c.activeClimberState is ClimberState_Attached:
				c.set_climber_state(c.defaultClimberState)
				Game.audio.play_rope_snap_sfx()


class IceShelf extends Node3D:
	var area: Area3D
	var slide: Vector3

	func setup(a: Area3D, dir: Vector3) -> void:
		area = a
		slide = dir

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		if c.is_on_floor() and area.overlaps_body(c):
			c.additional_velocity_next_frame += slide * 0.05


# ================================================================== puzzle classes

class Gate extends Node3D:
	var id := ""
	var is_open := false
	var latched := false
	var solo_timer := 0.0
	var door: MeshInstance3D
	var body: StaticBody3D
	var closed_y := 0.0
	var open_y := 0.0
	var sfx: AudioStreamPlayer3D
	var tw: Tween

	func setup(g: Dictionary, mat: Material) -> void:
		id = str(g["id"])
		var pos := Vector3(g["pos"][0], g["pos"][1], g["pos"][2])
		var w := float(g["w"])
		var h := float(g["h"])
		closed_y = pos.y
		open_y = pos.y + h - 0.6
		door = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h, 1.6)
		door.mesh = bm
		var m: StandardMaterial3D = load("res://Art/Textures/Wall_04.tres").duplicate()
		m.albedo_color = Color(0.35, 0.3, 0.28)
		door.material_override = m
		body = StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = bm.size
		cs.shape = bs
		body.add_child(cs)
		door.add_child(body)
		door.position = pos
		door.rotation.y = float(g["yaw"])
		# frame the door with two iron pillars so it reads as a puzzle door
		for side in [-1.0, 1.0]:
			var pil := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.5
			cm.bottom_radius = 0.6
			cm.height = h + 2.0
			pil.mesh = cm
			pil.material_override = mat
			pil.position = Vector3(side * (w * 0.5 + 0.7), 0.0, 0.0)
			add_child(pil)
		position = Vector3.ZERO
		add_child(door)
		for p in get_children():
			if p != door:
				p.position = door.position + door.basis * p.position
				p.rotation.y = door.rotation.y

	func _ready() -> void:
		sfx = U.sfx(SFX_METAL[0], 0.0, door.position, self, 60.0)

	func open() -> void:
		if is_open:
			return
		is_open = true
		_slide(open_y)

	func close() -> void:
		if not is_open:
			return
		is_open = false
		_slide(closed_y)

	func _slide(target_y: float) -> void:
		if tw:
			tw.kill()
		sfx.play()
		tw = create_tween()
		tw.tween_property(door, "position:y", target_y, 2.2).set_trans(Tween.TRANS_SINE)


class Kiln extends Node3D:
	var gate := ""
	var idx := 0
	var lit := false
	var pos: Vector3
	var fire: Node3D
	var light: OmniLight3D
	var area: Area3D

	func setup(g: String, i: int, p: Vector3) -> void:
		gate = g
		idx = i
		pos = p

	func _ready() -> void:
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 3.0
		cs.shape = sph
		area.add_child(cs)
		area.position = pos + Vector3(0, 1.5, 0)
		add_child(area)
		light = OmniLight3D.new()
		light.light_color = Color(1.0, 0.5, 0.15)
		light.light_energy = 0.15
		light.omni_range = 18.0
		light.shadow_enabled = false
		light.position = pos + Vector3(0, 3.0, 0)
		add_child(light)
		var ps: PackedScene = load(PYRELIGHT)
		if ps:
			fire = ps.instantiate()
			fire.position = pos + Vector3(0, 1.0, 0)
			fire.scale = Vector3(0.12, 0.12, 0.12)
			add_child(fire)

	func _process(_delta: float) -> void:
		if lit:
			return
		var c = Game.climber
		if is_instance_valid(c) and area.overlaps_body(c):
			CoopSync.map_event("kiln_%d" % idx, {})

	func light_up() -> void:
		if lit:
			return
		lit = true
		if is_instance_valid(fire):
			var tw := create_tween()
			tw.tween_property(fire, "scale", Vector3(0.9, 0.9, 0.9), 1.2)
		if is_instance_valid(light):
			var tw2 := create_tween()
			tw2.tween_property(light, "light_energy", 1.8, 1.2)
		Game.audio.play_player_healed()
		CoopSync.show_banner("Kiln lit.", 2.0)


class Plate extends Node3D:
	var gate := ""
	var idx := 0
	var pos: Vector3
	var area: Area3D
	var mesh: MeshInstance3D
	var pressed := false

	func setup(g: String, i: int, p: Vector3, mat: Material) -> void:
		gate = g
		idx = i
		pos = p
		mesh = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 2.2
		cm.bottom_radius = 2.4
		cm.height = 0.35
		mesh.mesh = cm
		mesh.material_override = mat
		mesh.position = pos + Vector3(0, 0.17, 0)

	func _ready() -> void:
		add_child(mesh)
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 2.6
		cs.shape = sph
		area.add_child(cs)
		area.position = pos + Vector3(0, 1.0, 0)
		add_child(area)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.7, 0.3)
		l.light_energy = 0.5
		l.omni_range = 8.0
		l.shadow_enabled = false
		l.position = pos + Vector3(0, 1.2, 0)
		add_child(l)

	func check_local_press() -> bool:
		# a plate is down if the local player or any teammate is on it
		var on := false
		var c = Game.climber
		if is_instance_valid(c) and area.overlaps_body(c):
			on = true
		if not on:
			for rp in CoopSync.remote_players():
				if (rp.global_position - (pos + Vector3(0, 0.8, 0))).length() < 2.6:
					on = true
					break
		_set_pressed(on)
		return on

	func remote_pressed(on: bool) -> void:
		_set_pressed(on)

	func _set_pressed(on: bool) -> void:
		if on == pressed:
			return
		pressed = on
		mesh.position.y = pos.y + (0.05 if on else 0.17)
		if on:
			Game.audio.play_metal_hit(pos)


class Fragment extends Node3D:
	var id := ""
	var pos: Vector3
	var collected := false
	var mesh: MeshInstance3D
	var area: Area3D
	var light: OmniLight3D

	func setup(i: String, p: Vector3, mat: Material) -> void:
		id = i
		pos = p
		mesh = MeshInstance3D.new()
		var pm := PrismMesh.new()
		pm.size = Vector3(0.7, 1.1, 0.7)
		mesh.mesh = pm
		var m: StandardMaterial3D = mat.duplicate()
		m.albedo_color = Color(0.7, 0.5, 0.15)
		m.emission_enabled = true
		m.emission = Color(1.0, 0.7, 0.2)
		m.emission_energy_multiplier = 0.25
		mesh.material_override = m
		mesh.position = p

	func _ready() -> void:
		add_child(mesh)
		light = OmniLight3D.new()
		light.light_color = Color(1.0, 0.8, 0.35)
		light.light_energy = 1.4
		light.omni_range = 16.0
		light.shadow_enabled = false
		light.position = pos + Vector3(0, 0.6, 0)
		add_child(light)
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 2.4
		cs.shape = sph
		area.add_child(cs)
		area.position = pos
		add_child(area)

	func _process(delta: float) -> void:
		if collected:
			return
		mesh.rotation.y += delta * 1.6
		mesh.position.y = pos.y + sin(Time.get_ticks_msec() * 0.003) * 0.25
		var c = Game.climber
		if is_instance_valid(c) and area.overlaps_body(c):
			CoopSync.map_event("frag_" + id, {"by": CoopSync.local_name})

	func collect(_by: String) -> void:
		if collected:
			return
		collected = true
		mesh.visible = false
		light.visible = false
		Game.audio.play_player_healed()


# ================================================================== the crucible

class MonkeyBar extends Node3D:
	# A thin rod of hot iron hanging from chains. Grapple only: the game's hook test is a ray
	# on layer 1, which the player also collides with, so the collision is a steep invisible
	# ridge around the rod (58 degree faces: the hook bites, feet slide off) and anyone who
	# still manages to perch on it is pushed off.
	# Some are rigged: hang from one too long and it rumbles, then sinks 3.5 m.
	var bar: MeshInstance3D
	var idx := 0
	var sink := false
	var sunk := false
	var sinking := false
	var hang_t := 0.0
	var top_y := 0.0
	var chains: Array = []
	var light: OmniLight3D
	var sfx_rumble: AudioStreamPlayer3D
	var half_len := 6.0
	var dot_tex: Texture2D

	func _ready() -> void:
		if sink:
			sfx_rumble = U.sfx(SFX_RUMBLE, 0.0, bar.position, self, 60.0)

	func _process(delta: float) -> void:
		if not sink or sunk:
			return
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var on_it := false
		var top := bar.position + Vector3(0, 0.4, 0)
		if c.activeClimberState is ClimberState_Attached and is_instance_valid(c.Rope._claw):
			on_it = (c.Rope._claw.global_position - top).length() < 3.0
		if not on_it and c.is_on_floor() and (c.global_position - top).length() < 3.2:
			on_it = true
		if on_it:
			hang_t += delta
			if hang_t > 1.2:
				CoopSync.map_event("barsink_%d" % idx, {})
		else:
			hang_t = maxf(0.0, hang_t - delta)

	func sink_now() -> void:
		if sunk:
			return
		sunk = true
		sinking = true
		if sfx_rumble:
			sfx_rumble.play()
		var start := bar.position
		var tw := create_tween()
		# shake for 0.8 s, then drop 3.5 m over 1.4 s
		for i in 10:
			tw.tween_property(bar, "position", start + Vector3(randf_range(-0.12, 0.12), -0.05 * i, randf_range(-0.12, 0.12)), 0.08)
		tw.tween_property(bar, "position:y", start.y - 3.5, 1.4).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(func(): sinking = false)
		if light:
			var tl := create_tween()
			tl.tween_property(light, "position:y", light.position.y - 3.5, 2.2)
		for ch in chains:
			var cm: CylinderMesh = ch.mesh
			var tc := create_tween()
			tc.tween_property(cm, "height", cm.height + 3.5, 2.2)
			tc.parallel().tween_property(ch, "position:y", ch.position.y - 1.75, 2.2)

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		# nobody stands on a rod
		if c.is_on_floor():
			var lp: Vector3 = bar.global_transform.affine_inverse() * c.global_position
			if absf(lp.x) < 1.3 and absf(lp.z) < half_len + 0.6 and lp.y > -1.4 and lp.y < 1.8:
				var side: Vector3 = bar.global_basis.x * (1.0 if lp.x >= 0.0 else -1.0)
				c.additional_velocity_next_frame += side * 6.0 + Vector3.DOWN * 2.0
		# the hook rides the bar down instead of hanging in mid-air where the bar was
		if not sinking:
			return
		if not (c.activeClimberState is ClimberState_Attached) or not is_instance_valid(c.Rope._claw):
			return
		var claw: RigidBody3D = c.Rope._claw
		var top := bar.position + Vector3(0, 0.6, 0)
		var flat: Vector3 = claw.global_position
		flat.y = top.y
		if (flat - top).length() < 3.2 and claw.global_position.y > top.y:
			claw.global_position.y = top.y
			PhysicsServer3D.body_set_state(claw.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D.IDENTITY.translated(claw.global_position))

	func setup(b: Dictionary, mat: Material) -> void:
		idx = int(b["idx"])
		sink = bool(b.get("sink", false))
		var pos := Vector3(b["pos"][0], b["pos"][1], b["pos"][2])
		var length := float(b["length"])
		var width := float(b["width"])
		var thick := float(b["thick"])
		half_len = length * 0.5
		bar = MeshInstance3D.new()
		bar.position = pos
		bar.rotation.y = float(b["yaw"])
		var rod := MeshInstance3D.new()
		var rm := CylinderMesh.new()
		rm.top_radius = maxf(0.08, width * 0.5)
		rm.bottom_radius = rm.top_radius
		rm.height = length
		rm.radial_segments = 8
		rm.rings = 1
		rod.mesh = rm
		var hot := StandardMaterial3D.new()                   # iron that has hung over a lava lake for a long time
		hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hot.albedo_color = Color(0.5, 0.15, 0.04)
		rod.material_override = hot
		rod.rotation.x = PI * 0.5
		rod.position = Vector3(0, -0.3, 0)
		bar.add_child(rod)
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.physics_material_override = load("res://physics_materials/stone.tres")
		var cs := CollisionShape3D.new()
		var ridge := ConvexPolygonShape3D.new()
		var hl := length * 0.5
		ridge.points = PackedVector3Array([
			Vector3(0, 0, -hl), Vector3(0.55, -0.88, -hl), Vector3(-0.55, -0.88, -hl),
			Vector3(0, 0, hl), Vector3(0.55, -0.88, hl), Vector3(-0.55, -0.88, hl)])
		cs.shape = ridge
		body.add_child(cs)
		bar.add_child(body)
		add_child(bar)
		for e in [-1.0, 1.0]:                                  # a glow at each end so you can find it from a rope away
			var dot := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(1.6, 1.6)
			dot.mesh = qm
			var gm := StandardMaterial3D.new()
			gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			gm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			gm.albedo_texture = dot_tex
			gm.albedo_color = Color(0.4, 0.13, 0.03, 0.9)
			gm.disable_fog = true
			dot.material_override = gm
			dot.position = Vector3(0, -0.3, e * (hl - 0.8))
			bar.add_child(dot)
		# chains up to the ceiling
		var tops: Array = b["chain_top"]
		for i in 2:
			var side := -1.0 if i == 0 else 1.0
			var local := Vector3(0, 0, side * (length * 0.5 - 0.8))
			var world := bar.position + bar.basis * local
			var top_y := float(tops[i])
			var ch := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.09
			cm.bottom_radius = 0.09
			cm.height = maxf(0.5, top_y - world.y)
			ch.mesh = cm
			ch.material_override = mat
			ch.position = Vector3(world.x, (world.y + top_y) * 0.5, world.z)
			add_child(ch)
			chains.append(ch)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.55, 0.2)
		l.light_energy = 0.5
		l.omni_range = 10.0
		l.shadow_enabled = false
		l.position = pos + Vector3(0, 1.5, 0)
		add_child(l)
		light = l


# ================================================================== creatures

class Stalker extends Node3D:
	# A centipede-shaped thing that only moves while nobody on the team can see it.
	# Host runs it and streams its position; guests just show it. It hunts the nearest
	# living player inside its zone, bites, and retreats to the dark.
	var id := ""
	var home: Vector3
	var zone: Array = []
	var speed := 26.0
	var body: Node3D
	var segs: Array = []
	var trail: Array = []
	var target_pos: Vector3
	var bite_cd := 0.0
	var hidden_t := 0.0
	var sfx_breath: AudioStreamPlayer3D
	var sfx_snarl: AudioStreamPlayer3D
	var visible_to_someone := false
	var rp_pos: Vector3
	var rp_yaw := 0.0
	var retreat := 0.0

	func setup(s: Dictionary) -> void:
		id = str(s["id"])
		home = Vector3(s["home"][0], s["home"][1], s["home"][2])
		zone = s["zone"]
		speed = float(s.get("speed", 26.0))
		target_pos = home

	func _ready() -> void:
		body = Node3D.new()
		var head_ps: PackedScene = load("res://Art/Monster_Head_Redesign.glb")
		var seg_ps: PackedScene = load("res://Art/Monster_BodySection_Redesign.glb")
		if head_ps:
			var h: Node3D = head_ps.instantiate()
			h.scale = Vector3.ONE * 1.4
			body.add_child(h)
		for i in 9:
			if seg_ps:
				var sg: Node3D = seg_ps.instantiate()
				sg.scale = Vector3.ONE * 1.3
				add_child(sg)
				segs.append(sg)
				sg.position = home
		body.position = home
		add_child(body)
		for i in 60:
			trail.append(home)
		sfx_breath = U.sfx("res://sfx/soundsnap/monster_idle/306004-Creature-Oxbow-Breaths-Wet-Fast.wav", 2.0, Vector3.ZERO, body, 45.0)
		sfx_snarl = U.sfx("res://sfx/soundsnap/monster_attack/306011-Creature-Oxbow-Snarls-Breaths-Aggressive_2.wav", 4.0, Vector3.ZERO, body, 60.0)
		var l := OmniLight3D.new()
		l.light_color = Color(0.6, 0.1, 0.1)
		l.light_energy = 0.35
		l.omni_range = 9.0
		l.shadow_enabled = false
		body.add_child(l)
		rp_pos = home

	func _in_zone(p: Vector3) -> bool:
		for z in zone:
			var c := Vector3(z[0][0], z[0][1], z[0][2])
			if (p - c).length() < float(z[1]) + 6.0:
				return true
		return false

	func _seen_by(p: Vector3, cam: Camera3D) -> bool:
		if cam == null:
			return false
		var to := p - cam.global_position
		var d := to.length()
		if d > 90.0:
			return false
		var fwd := -cam.global_basis.z
		if fwd.dot(to / maxf(d, 0.01)) < 0.55:
			return false
		var space := get_world_3d().direct_space_state
		var ray := PhysicsRayQueryParameters3D.create(cam.global_position, p, 1)
		return space.intersect_ray(ray).is_empty()

	func _process(delta: float) -> void:
		bite_cd = maxf(0.0, bite_cd - delta)
		if CoopSync.map_is_authority():
			_think(delta)
		else:
			body.position = body.position.lerp(rp_pos, clampf(delta * 10.0, 0.0, 1.0))
			body.rotation.y = lerp_angle(body.rotation.y, rp_yaw, clampf(delta * 8.0, 0.0, 1.0))
		_update_segments(delta)

	func _think(delta: float) -> void:
		var players := CoopSync.alive_player_nodes()
		var nearest: Node3D = null
		var nd := 1e9
		for p in players:
			if not _in_zone(p.global_position):
				continue
			var d: float = (p.global_position - body.position).length()
			if d < nd:
				nd = d
				nearest = p
		# seen by the local camera, or (approx) by a teammate facing it
		var seen := false
		var c = Game.climber
		if is_instance_valid(c) and c.Camera:
			seen = _seen_by(body.position, c.Camera)
		if not seen:
			for rp in CoopSync.remote_players():
				var fwd: Vector3 = -rp.global_basis.z
				var to: Vector3 = body.position - rp.global_position
				var d: float = to.length()
				if d < 70.0 and fwd.dot(to / maxf(d, 0.01)) > 0.6:
					var ray := PhysicsRayQueryParameters3D.create(rp.global_position + Vector3.UP * 1.5, body.position, 1)
					if get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
						seen = true
						break
		visible_to_someone = seen
		if retreat > 0.0:
			retreat -= delta
			target_pos = home
		elif nearest:
			target_pos = nearest.global_position + Vector3.UP * 0.8
			if not sfx_breath.playing and nd < 40.0:
				sfx_breath.play()
		else:
			target_pos = home
		if not seen or retreat > 0.0:
			hidden_t += delta
			var step := speed * delta
			var to := target_pos - body.position
			if to.length() > step:
				body.position += to.normalized() * step
			else:
				body.position = target_pos
			if to.length() > 0.5:
				body.rotation.y = atan2(-to.x, -to.z)
		if nearest and nd < 2.6 and bite_cd <= 0.0 and retreat <= 0.0:
			bite_cd = 3.0
			retreat = 4.0
			sfx_snarl.play()
			if nearest == Game.climber:
				bite_local()
			else:
				CoopSync.map_event("stalkbite_" + id, {"who": nearest.get("peer_id")}, false)

	func bite_local() -> void:
		var c = Game.climber
		if not is_instance_valid(c):
			return
		c.take_damage(45.0)
		var away: Vector3 = (c.global_position - body.position)
		away.y = 0.3
		c.additional_velocity_next_frame += away.normalized() * 16.0
		if c.activeClimberState is ClimberState_Attached:
			c.set_climber_state(c.defaultClimberState)
			Game.audio.play_rope_snap_sfx()
		Game.audio.play_player_was_bit()

	func _update_segments(delta: float) -> void:
		trail.push_front(body.position)
		trail.pop_back()
		for i in segs.size():
			var k := mini(trail.size() - 1, (i + 1) * 3)
			var sg: Node3D = segs[i]
			sg.position = sg.position.lerp(trail[k], clampf(delta * 14.0, 0.0, 1.0))
			var ahead: Vector3 = trail[maxi(0, k - 3)]
			var dir := ahead - sg.position
			if dir.length() > 0.2:
				sg.rotation.y = atan2(-dir.x, -dir.z)

	func state_packet() -> Array:
		return [body.position.x, body.position.y, body.position.z, body.rotation.y]

	func remote_state(a: Array) -> void:
		rp_pos = Vector3(a[0], a[1], a[2])
		rp_yaw = float(a[3])


class Ambience extends Node3D:
	var sounds: Array = []
	var lo := 8.0
	var hi := 20.0
	var t := 0.0
	var player: AudioStreamPlayer3D
	var pos: Vector3

	func setup(a: Dictionary) -> void:
		pos = Vector3(a["pos"][0], a["pos"][1], a["pos"][2])
		sounds = a["sounds"]
		lo = float(a["min"])
		hi = float(a["max"])
		player = AudioStreamPlayer3D.new()
		player.volume_db = float(a.get("db", 0.0))
		player.max_distance = float(a.get("range", 30.0))
		player.bus = &"MainBus"
		player.position = pos
		t = randf_range(lo, hi)

	func _ready() -> void:
		add_child(player)

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or (c.global_position - pos).length() > player.max_distance + 20.0:
			return
		t -= delta
		if t <= 0.0:
			t = randf_range(lo, hi)
			player.stream = load(sounds[randi() % sounds.size()])
			player.position = pos + Vector3(randf_range(-6, 6), randf_range(-2, 3), randf_range(-6, 6))
			player.play()


class DyingLights extends Node3D:
	# Torches along a tunnel that go out one by one as the player passes, and the
	# gravel sound of something following in the dark.
	var id := ""
	var trigger: Area3D
	var lights: Array = []
	var fires: Array = []
	var started := false
	var next := 0
	var t := 0.0

	func setup(d: Dictionary) -> void:
		id = str(d["id"])
		var tr: Array = d["trigger"]
		trigger = Area3D.new()
		trigger.collision_layer = 0
		trigger.collision_mask = 4
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = float(tr[1])
		cs.shape = sph
		trigger.add_child(cs)
		trigger.position = Vector3(tr[0][0], tr[0][1] + 1.0, tr[0][2])
		var ps: PackedScene = load(PYRELIGHT)
		for lp in d["lights"]:
			var p := Vector3(lp[0], lp[1], lp[2])
			var l := OmniLight3D.new()
			l.light_color = Color(1.0, 0.6, 0.3)
			l.light_energy = 1.1
			l.omni_range = 16.0
			l.shadow_enabled = false
			l.position = p + Vector3(0, 1.6, 0)
			add_child(l)
			lights.append(l)
			if ps:
				var f: Node3D = ps.instantiate()
				f.position = p
				f.scale = Vector3(0.3, 0.3, 0.3)
				add_child(f)
				fires.append(f)

	func _ready() -> void:
		add_child(trigger)
		trigger.body_entered.connect(func(b: Node3D):
			if b == Game.climber and not started:
				CoopSync.map_event("dying_" + id, {}))

	func begin() -> void:
		if started:
			return
		started = true
		t = 2.5
		Game.audio.play_dark_transition2()

	func _process(delta: float) -> void:
		if not started or next >= lights.size():
			return
		t -= delta
		if t > 0.0:
			return
		t = randf_range(2.0, 4.0)
		var l: OmniLight3D = lights[next]
		var tw := create_tween()
		tw.tween_property(l, "light_energy", 0.0, 0.6)
		if next < fires.size():
			fires[next].visible = false
		Game.audio.play_sfx_gravel_footstep()
		next += 1
		if next == lights.size():
			CoopSync.show_banner("The last light is out.", 3.0)


# ================================================================== music

class MusicDirector extends Node:
	# The game's own ambience only runs in the campaign scene, so a custom map is silent
	# without this. Three layers (drone, music, accent) cross-fade per biome, and the
	# finale pushes the Wasteland theme up. Streams restart themselves to loop.
	const WIND := "res://sfx/soundsnap/ambience/528557-WINDTonl-Ash_Meadows_At_Dawn_01-JATH-WDV-LOM_Mikro_Usi.wav"
	const A22 := "res://sfx/soundsnap/ambience/276358-22.wav"
	const A23 := "res://sfx/soundsnap/ambience/276359-23.wav"
	const D004 := "res://sfx/soundsnap/ambience/221904-Dark-SciFi-Drone-Mixed-004.wav"
	const D087 := "res://sfx/soundsnap/ambience/221989-Dark-SciFi-Drone-Mixed-087.wav"
	const DOOM := "res://sfx/soundsnap/ambience/1238574.audio-DSGNDron-SMorph-Doom_Drones_2_-Horror_Winds_Far_Whistle_01.wav"
	const ASHES := "res://sfx/Edited/Ashes_Text.wav"
	const WLONG := "res://sfx/music/Wasteland_LONG_LOOP_53BPM.wav"
	const WSHORT := "res://sfx/music/Wasteland_SHORT_LOOP_STRING53BPM.wav"
	# per biome: [drone, music, accent], each [path, linear volume] or null.
	# Volumes follow the campaign's own mix (drones ~0.05, wind ~1.5, theme 0.2).
	const SETS := [
		[[WIND, 1.4], null, null],
		[[A22, 0.05], null, [ASHES, 0.05]],
		[[A23, 0.05], [ASHES, 0.12], null],
		[[D004, 0.06], null, null],
		[[D087, 0.06], [WIND, 0.35], null],
		[[A22, 0.05], [ASHES, 0.14], null],
		[[A23, 0.05], [WSHORT, 0.09], null],
		[[DOOM, 0.07], null, null],
		[[DOOM, 0.08], [WLONG, 0.09], null],
		[[D004, 0.035], null, null],
	]
	var players: Array = []
	var target_path: Array = ["", "", ""]
	var target_vol: Array = [0.0, 0.0, 0.0]
	var current_path: Array = ["", "", ""]
	var boost := 1.0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		for i in 3:
			var p := AudioStreamPlayer.new()
			p.bus = &"MainBus"
			p.volume_db = -80.0
			p.finished.connect(func(): if p.stream: p.play())
			add_child(p)
			players.append(p)

	func set_biome(b: int) -> void:
		if b < 0 or b >= SETS.size():
			return
		var set_: Array = SETS[b]
		for i in 3:
			if set_[i] == null:
				target_path[i] = ""
				target_vol[i] = 0.0
			else:
				target_path[i] = set_[i][0]
				target_vol[i] = float(set_[i][1])

	func finale() -> void:
		target_path[1] = WLONG
		target_vol[1] = 0.26
		target_vol[0] = 0.11
		boost = 1.0

	func _process(delta: float) -> void:
		for i in 3:
			var p: AudioStreamPlayer = players[i]
			var want_path: String = target_path[i]
			var want_vol: float = target_vol[i] * boost
			if current_path[i] != want_path:
				# fade out what is playing, then swap
				want_vol = 0.0
				if p.volume_linear < 0.006 or current_path[i] == "":
					current_path[i] = want_path
					p.stop()
					if want_path != "":
						p.stream = load(want_path)
					continue
			var nv: float = lerpf(p.volume_linear, maxf(want_vol, 0.001), clampf(delta * 0.6, 0.0, 1.0))
			p.volume_db = linear_to_db(nv)
			if nv >= 0.005 and not p.playing and p.stream:
				p.play()
			if nv < 0.005 and p.playing:
				p.stop()


class Flicker extends Node:
	var light: OmniLight3D
	var base := 1.0
	var t := 0.0

	func setup(l: OmniLight3D) -> void:
		light = l
		base = l.light_energy
		t = randf() * 10.0

	func _process(delta: float) -> void:
		if not is_instance_valid(light):
			return
		t += delta
		light.light_energy = base * (0.82 + 0.18 * sin(t * 9.1) + 0.1 * sin(t * 23.7))


class Bell extends Node3D:
	# An old miners' bell hung from the roof. Hit it with your hook and every centipede
	# in the map comes to the sound for 20 seconds instead of coming for you.
	var id := ""
	var bell: Node3D
	var pos: Vector3
	var sfx: AudioStreamPlayer3D
	var area: Area3D
	var cool := 0.0
	var swing := 0.0
	var lure_left := 0.0

	func setup(b: Dictionary, mat: Material) -> void:
		id = str(b["id"])
		pos = Vector3(b["pos"][0], b["pos"][1], b["pos"][2])
		var sc := float(b["scale"])
		var ps: PackedScene = load("res://Art/Ancient_Kiln.glb")
		bell = Node3D.new()
		if ps:
			var k: Node3D = ps.instantiate()
			for body in k.find_children("*", "StaticBody3D", true, false):
				body.queue_free()
			k.rotation = Vector3(PI, 0, 0)     # the kiln dome upside down reads as a bell
			k.scale = Vector3.ONE * sc * 0.42
			for mi in k.find_children("*", "GeometryInstance3D", true, false):
				(mi as GeometryInstance3D).material_override = mat
			bell.add_child(k)
		# clapper
		var cl := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.35 * sc
		sm.height = 0.7 * sc
		cl.mesh = sm
		cl.material_override = mat
		cl.position = Vector3(0, -1.5 * sc, 0)
		bell.add_child(cl)
		bell.position = pos
		add_child(bell)
		# chain up to the roof
		var ch := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.12
		cm.bottom_radius = 0.12
		cm.height = maxf(0.5, float(b["ceiling"]) - pos.y)
		ch.mesh = cm
		ch.material_override = mat
		ch.position = Vector3(pos.x, (pos.y + float(b["ceiling"])) * 0.5, pos.z)
		add_child(ch)
		# hookable: the claw needs something solid with an upward face to land on
		var body2 := StaticBody3D.new()
		body2.collision_layer = 1
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 1.5 * sc
		cyl.height = 2.0 * sc
		cs.shape = cyl
		body2.add_child(cs)
		body2.position = pos
		add_child(body2)

	func _ready() -> void:
		sfx = U.sfx(SFX_METAL[1], 6.0, pos, self, 400.0)
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 2 | 4     # the claw and players
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 3.4
		cs.shape = sph
		area.add_child(cs)
		area.position = pos
		add_child(area)

	func _process(delta: float) -> void:
		cool = maxf(0.0, cool - delta)
		if swing > 0.0:
			swing -= delta
			var k: float = swing / 2.5
			bell.rotation.z = sin(swing * 11.0) * 0.32 * k
			bell.rotation.x = cos(swing * 9.0) * 0.22 * k
		if lure_left > 0.0:
			lure_left -= delta
			if CoopSync.map_is_authority():
				CoopSync.set_lure(bell, lure_left)
		if cool > 0.0:
			return
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var hit := false
		if is_instance_valid(c.Rope._claw) and c.Rope._claw.visible:
			hit = (c.Rope._claw.global_position - pos).length() < 3.2
		if not hit and c.velocity.length() > 7.0 and (c.global_position - pos).length() < 3.4:
			hit = true
		if hit:
			cool = 6.0
			CoopSync.map_event("bell_" + id, {}, false)

	func toll() -> void:
		swing = 2.5
		lure_left = 20.0
		cool = 6.0
		sfx.play()
		Game.audio.play_dark_transition2()
		CoopSync.show_banner("The bell rings. Everything hunting turns toward it.", 5.0)


class Ghost extends Node3D:
	# One of the climbers who came before. Stands where the way continues, watching it.
	# Fades when the local player comes close; each player sees their own.
	const WHISPERS := ["res://sfx/soundsnap/1022742.audio-HUMAN_VOCAL_Female_4_Breath_Medium_01.wav",
			"res://sfx/soundsnap/463323-HUMAN_BREATH_Female-Deep_Opened_Mouth_Normal_Speed_Breath-B.wav"]
	var body: Node3D
	var mat: StandardMaterial3D
	var fading := false
	var t := 0.0

	func setup(ps: PackedScene, base: StandardMaterial3D, pos: Vector3, yaw: float) -> void:
		body = ps.instantiate()
		mat = base.duplicate()
		for mi in body.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).material_override = mat
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			(mi as GeometryInstance3D).visibility_range_end = 70.0
		position = pos
		rotation.y = yaw
		add_child(body)
		t = randf() * 6.0

	func _process(delta: float) -> void:
		t += delta
		if fading:
			mat.albedo_color.a = maxf(0.0, mat.albedo_color.a - delta * 0.3)
			body.position.y += delta * 0.25
			if mat.albedo_color.a <= 0.0:
				queue_free()
			return
		body.position.y = sin(t * 0.8) * 0.04
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree() and (c.global_position - global_position).length() < 10.0:
			fading = true
			var p := U.sfx(WHISPERS[randi() % WHISPERS.size()], -8.0, Vector3(0, 1.5, 0), self, 22.0)
			p.play()


# ================================================================== the rift's furniture

class HangingPlatform extends Node3D:
	# A deck hung on chains over the void (village floors, foundry gantries, rests on the
	# Crucible). Some are rigged: stand on one too long and its chains let go, for everyone.
	var id := ""
	var deck: MeshInstance3D
	var body: StaticBody3D
	var rigged := false
	var gone := false
	var stand := 0.0
	var top: Vector3
	var half: Vector3
	var sfx: AudioStreamPlayer3D
	var chains: Array = []

	func setup(d: Dictionary, mat: Material, chain_mat: Material) -> void:
		id = str(d["id"])
		rigged = bool(d.get("drop", false))
		top = Vector3(d["pos"][0], d["pos"][1], d["pos"][2])
		var sz := Vector3(d["size"][0], d["size"][1], d["size"][2])
		half = sz * 0.5
		deck = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sz
		deck.mesh = bm
		deck.material_override = mat
		deck.position = top - Vector3(0, sz.y * 0.5, 0)
		deck.rotation.y = float(d.get("yaw", 0.0))
		body = StaticBody3D.new()
		body.collision_layer = 1
		body.physics_material_override = load("res://physics_materials/stone.tres")
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = sz
		cs.shape = bs
		body.add_child(cs)
		deck.add_child(body)
		add_child(deck)
		var clen := float(d.get("chain", 0.0))
		if clen > 0.0:
			for cx in [-1.0, 1.0]:
				for cz in [-1.0, 1.0]:
					var ch := MeshInstance3D.new()
					var cm := CylinderMesh.new()
					cm.top_radius = 0.08
					cm.bottom_radius = 0.08
					cm.height = clen
					cm.radial_segments = 5
					ch.mesh = cm
					ch.material_override = chain_mat
					ch.position = Vector3(cx * (half.x - 0.4), clen * 0.5 + sz.y * 0.5, cz * (half.z - 0.4))
					deck.add_child(ch)
					chains.append(ch)

	func _ready() -> void:
		if rigged:
			sfx = U.sfx(SFX_RUMBLE, 2.0, top, self, 55.0)

	func _process(delta: float) -> void:
		if not rigged or gone:
			return
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var q: Vector3 = c.global_position - top
		if c.is_on_floor() and absf(q.x) < half.x + 0.5 and absf(q.z) < half.z + 0.5 and q.y > -0.5 and q.y < 2.5:
			stand += delta
			if stand > 1.4:
				CoopSync.map_event("pfdrop_" + id, {})
		else:
			stand = maxf(0.0, stand - delta)

	func drop_now() -> void:
		if gone:
			return
		gone = true
		if sfx:
			sfx.play()
		Game.audio.play_rope_snap_sfx()
		var start := deck.position
		var tw := create_tween()
		for i in 10:
			tw.tween_property(deck, "position", start + Vector3(randf_range(-0.15, 0.15), -0.04 * i, randf_range(-0.15, 0.15)), 0.09)
		tw.tween_property(deck, "position:y", start.y - 260.0, 4.0).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.parallel().tween_property(deck, "rotation:z", 0.9, 4.0)
		tw.tween_callback(func(): body.collision_layer = 0; deck.visible = false)
		for ch in chains:
			ch.visible = false
		var c = Game.climber
		if is_instance_valid(c) and c.activeClimberState is ClimberState_Attached and is_instance_valid(c.Rope._claw):
			if (c.Rope._claw.global_position - top).length() < half.length() + 2.0:
				c.set_climber_state(c.defaultClimberState)


class CrystalSpar extends Node3D:
	# A crystal grown clean across the rift: a six-sided prism with a flat top face, slick
	# as glass. Step on and you slide where it goes.
	var a: Vector3
	var b: Vector3
	var r := 7.0
	var down: Vector3
	var t_axis: Vector3
	var length := 0.0

	func setup(pa: Vector3, pb: Vector3, radius: float) -> void:
		a = pa
		b = pb
		r = radius
		length = (b - a).length()
		t_axis = (b - a) / length
		var u := Vector3.UP.cross(t_axis).normalized()
		var v := t_axis.cross(u).normalized()       # the deck normal, mostly up
		down = t_axis if t_axis.y < 0.0 else -t_axis
		var half_h := r * 0.866
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var ring: Array = []
		for k in 6:
			var ang := deg_to_rad(60.0 * k)          # vertices at 0,60,..: a flat face sits on top
			ring.append(u * cos(ang) * r + v * sin(ang) * r - v * half_h)
		for k in 6:
			var p0: Vector3 = ring[k]
			var p1: Vector3 = ring[(k + 1) % 6]
			var nrm := ((p0 + p1) * 0.5 + v * half_h).normalized()
			for tri in [[a + p0, a + p1, b + p1], [a + p0, b + p1, b + p0]]:
				for q in tri:
					st.set_normal(nrm)
					st.add_vertex(q)
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.12, 0.24, 0.42)
		m.roughness = 0.25
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = m
		mi.visibility_range_end = 420.0
		add_child(mi)
		# collision: a box whose top is the prism's top face (the deck line a-b)
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(r, half_h * 2.0, length)
		cs.shape = bs
		body.add_child(cs)
		body.transform = Transform3D(Basis(u, v, t_axis), (a + b) * 0.5 - v * half_h)
		add_child(body)

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree() or not c.is_on_floor():
			return
		var q: Vector3 = c.global_position - a
		var along := q.dot(t_axis)
		if along < 6.0 or along > length - 14.0:
			return
		var off := q - t_axis * along
		if off.length() < r * 0.9 + 1.2:
			c.additional_velocity_next_frame += down * 0.085     # glass: you go where it goes


class Waterfall extends Node3D:
	# Water pouring out of the wall into nothing. It shoves you toward the edge.
	var top: Vector3
	var height := 30.0
	var push: Vector3

	func setup(p: Vector3, h: float, shove: Vector3) -> void:
		top = p
		height = h
		push = shove

	func _ready() -> void:
		var ps := CPUParticles3D.new()
		ps.amount = 90
		ps.lifetime = 2.2
		ps.local_coords = false
		ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		ps.emission_box_extents = Vector3(2.2, 0.3, 2.2)
		ps.direction = Vector3.DOWN
		ps.spread = 6.0
		ps.gravity = Vector3(0, -14.0, 0)
		ps.initial_velocity_min = 3.0
		ps.initial_velocity_max = 6.0
		ps.scale_amount_min = 0.7
		ps.scale_amount_max = 1.5
		var quad := QuadMesh.new()
		quad.size = Vector2(0.9, 3.2)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.09, 0.12, 0.13, 0.22)
		m.albedo_texture = get_parent()._soft_dot()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		quad.material = m
		ps.mesh = quad
		ps.position = top
		ps.visibility_range_end = 200.0
		add_child(ps)
		var snd := U.sfx(SFX_WIND, -6.0, top - Vector3(0, height * 0.8, 0), self, 50.0)
		snd.finished.connect(func(): snd.play())
		snd.play()

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var q: Vector3 = c.global_position - top
		if q.y < 2.0 and q.y > -height and Vector2(q.x, q.z).length() < 3.6:
			c.additional_velocity_next_frame += push * 0.012

