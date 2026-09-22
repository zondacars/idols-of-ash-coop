extends Node3D

const SnapBuffer := preload("res://mods-unpacked/zonda-CoopSync/snap_buffer.gd")

const MODEL_PATH := "res://Art/Knight.glb"
const FEET_OFFSET := -0.78
const INTERP_DELAY_MS := 60
const TELEPORT_DIST_SQ := 400.0

const SFX_HOOK_THROWN := "res://sfx/soundsnap/Grapple_THrow.wav"
const SFX_ROPE_CREAK := "res://sfx/soundsnap/202422-EFX_INT_Hanging_by_Rope_Creak.wav"
const SFX_HOOK_ATTACHED := [
	"res://sfx/soundsnap/273276-Builder-Game-Item-Pickaxe-Hit-Metal-3.wav",
	"res://sfx/soundsnap/273280-Builder-Game-Item-Pickaxe-Hit-Stone-Metal-1.wav",
	"res://sfx/soundsnap/273281-Builder-Game-Item-Pickaxe-Hit-Stone-Metal-2.wav",
	"res://sfx/soundsnap/273272-Builder-Game-Item-Pickaxe-Broken-3.wav",
]

var peer_id: int = 0
var player_name := "Player"
var scene_path := ""
var attached := false
var attached_time := 0.0
var claw_node: Node3D = null
var last_update_ms := 0
var alive := true
var has_ground := false
var last_ground_pos: Vector3

var _buf = SnapBuffer.new()
var _label: Label3D
var _body: Node3D = null
var _rope_visuals: Array = []
var _rope_lines: Array = []
var _rope_materials: Array = []
var _rope_material_base: Material = null

var _sfx_hook_thrown: AudioStreamPlayer3D
var _sfx_hook_attached: AudioStreamPlayer3D
var _sfx_rope_loop: AudioStreamPlayer3D
var _had_rope := false
var _cos := -1
var _crown: MeshInstance3D = null
var _lantern: Node3D = null
var _lantern_light: OmniLight3D = null


static func build_cage_lantern(dot_tex: Texture2D, energy: float, rng: float, shadows: bool) -> Array:
	# returns [root, light]. Colours are kept dim: the game doubles brightness in post.
	var root := Node3D.new()
	root.name = "ZondaLantern"
	var iron := StandardMaterial3D.new()
	iron.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	iron.albedo_color = Color(0.05, 0.04, 0.035)
	for k in 4:
		var bar := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.008
		cm.bottom_radius = 0.008
		cm.height = 0.2
		cm.radial_segments = 6
		bar.mesh = cm
		bar.material_override = iron
		bar.position = Vector3(0.045 * (1 if k % 2 == 0 else -1), 0.0, 0.045 * (1 if k < 2 else -1))
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(bar)
	for y in [0.1, -0.1]:
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.055
		tm.outer_radius = 0.07
		tm.rings = 10
		tm.ring_segments = 6
		ring.mesh = tm
		ring.material_override = iron
		ring.position = Vector3(0, y, 0)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(ring)
	var handle := MeshInstance3D.new()
	var hm := TorusMesh.new()
	hm.inner_radius = 0.03
	hm.outer_radius = 0.042
	hm.rings = 10
	hm.ring_segments = 6
	handle.mesh = hm
	handle.material_override = iron
	handle.position = Vector3(0, 0.145, 0)
	handle.rotation.x = PI * 0.5
	handle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(handle)
	var flame := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.032
	sm.height = 0.064
	sm.radial_segments = 8
	sm.rings = 4
	flame.mesh = sm
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(0.5, 0.3, 0.1)
	flame.material_override = fm
	flame.position = Vector3(0, -0.02, 0)
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(flame)
	if dot_tex != null:
		var fire := CPUParticles3D.new()
		fire.amount = 7
		fire.lifetime = 0.45
		fire.randomness = 0.6
		fire.local_coords = true
		fire.direction = Vector3.UP
		fire.spread = 12.0
		fire.gravity = Vector3(0, 0.6, 0)
		fire.initial_velocity_min = 0.08
		fire.initial_velocity_max = 0.16
		fire.scale_amount_min = 0.5
		fire.scale_amount_max = 1.0
		var grad := Gradient.new()
		grad.set_color(0, Color(0.55, 0.3, 0.08, 0.6))
		grad.set_color(1, Color(0.25, 0.04, 0.0, 0.0))
		fire.color_ramp = grad
		var fq := QuadMesh.new()
		fq.size = Vector2(0.05, 0.065)
		var fqm := StandardMaterial3D.new()
		fqm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fqm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fqm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		fqm.albedo_texture = dot_tex
		fqm.vertex_color_use_as_albedo = true
		fq.material = fqm
		fire.mesh = fq
		fire.position = Vector3(0, -0.01, 0)
		fire.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(fire)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.72, 0.42)
	light.light_energy = energy
	light.omni_range = rng
	light.omni_attenuation = 1.0
	light.shadow_enabled = shadows
	light.shadow_bias = 0.08
	light.light_volumetric_fog_energy = 1.0
	light.set_meta("zonda_keep", true)
	light.position = Vector3(0, -0.02, 0)
	root.add_child(light)
	return [root, light]
const GOLD := Color(1.0, 0.8, 0.32)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_body()

	_label = Label3D.new()
	_label.position = Vector3(0, 1.2, 0)
	_label.pixel_size = 0.005
	_label.font_size = 48
	_label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_label.no_depth_test = true
	_label.text = player_name
	add_child(_label)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.85, 0.6)
	light.light_energy = 0.8
	light.omni_range = 7.0
	light.position = Vector3(0, 0.6, 0)
	add_child(light)

	_rope_material_base = load("res://materials/rope_line_material.tres")

	var claw_scene: PackedScene = load("res://scenes/ClimberClaw.tscn")
	if claw_scene:
		var claw = claw_scene.instantiate()
		claw.set_script(null)
		claw.freeze = true
		claw.collision_layer = 0
		claw.collision_mask = 0
		claw.contact_monitor = false
		claw.top_level = true
		claw.visible = false
		var claw_light := claw.get_node_or_null("OmniLight3D")
		if claw_light:
			claw_light.shadow_enabled = false
		add_child(claw)
		claw_node = claw

	_sfx_hook_thrown = AudioStreamPlayer3D.new()
	_sfx_hook_thrown.stream = load(SFX_HOOK_THROWN)
	_sfx_hook_thrown.volume_db = -40.0
	_sfx_hook_thrown.bus = &"MainBus"
	add_child(_sfx_hook_thrown)

	_sfx_hook_attached = AudioStreamPlayer3D.new()
	_sfx_hook_attached.volume_db = -10.0
	_sfx_hook_attached.attenuation_filter_cutoff_hz = 10000.0
	_sfx_hook_attached.bus = &"MainBus"
	add_child(_sfx_hook_attached)

	_sfx_rope_loop = AudioStreamPlayer3D.new()
	_sfx_rope_loop.stream = load(SFX_ROPE_CREAK)
	_sfx_rope_loop.volume_db = -14.0
	_sfx_rope_loop.bus = &"MainBus"
	_sfx_rope_loop.autoplay = false
	add_child(_sfx_rope_loop)


func _build_body() -> void:
	var ps = load(MODEL_PATH)
	if ps is PackedScene:
		_body = ps.instantiate()
		_strip_physics(_body)
	else:
		var mi := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = 0.3
		mesh.height = 1.567
		mi.mesh = mesh
		_body = mi
	_body.position = Vector3(0, FEET_OFFSET, 0)
	_body.rotation.y = PI
	add_child(_body)


func _strip_physics(n: Node) -> void:
	for c in n.get_children():
		if c is CollisionObject3D or c is CollisionShape3D:
			c.queue_free()
		else:
			_strip_physics(c)


func update_state(msg: Dictionary) -> void:
	# During a scene change this node can keep receiving packets after it has left the
	# tree. Touching audio or global transforms then just spams errors, so bail out.
	if not is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	player_name = CoopSync.sanitize_name(str(msg.get("n", player_name)))
	scene_path = str(msg.get("scene", ""))
	var hp: float = float(msg.get("hp", 100.0))
	var label_text := "%s  ♥ %d" % [player_name, int(round(hp))]
	if _label.text != label_text:
		_label.text = label_text
	if _label.no_depth_test != CoopSync.nametags_through_walls:
		_label.no_depth_test = CoopSync.nametags_through_walls
	var cos := int(msg.get("cos", 0))
	if cos != _cos:
		_cos = cos
		_apply_cosmetics()
	var lan: bool = bool(msg.get("lan", false))
	if lan and _lantern == null:
		# the knight holds it in its right hand, a little forward, swinging as it walks
		var pair := build_cage_lantern(null, 3.5, 16.0, false)
		_lantern = pair[0]
		_lantern_light = pair[1]
		_lantern.position = Vector3(0.36, 0.92, -0.22)
		add_child(_lantern)
	if _lantern != null and _lantern.visible != lan:
		_lantern.visible = lan

	var was_attached := attached
	attached = bool(msg.get("att", false))
	if attached and not was_attached:
		attached_time = 0.0
		if is_instance_valid(claw_node):
			_sfx_hook_attached.global_position = claw_node.global_position
		_sfx_hook_attached.stream = load(SFX_HOOK_ATTACHED.pick_random())
		_sfx_hook_attached.play()

	var has_rope_now: bool = msg.has("rope")
	if has_rope_now and not _had_rope:
		_sfx_hook_thrown.global_position = msg.get("pos", global_position)
		_sfx_hook_thrown.play()
	_had_rope = has_rope_now

	var snap := {
		"pos": msg.get("pos", global_position),
		"yaw": float(msg.get("cam", 0.0)),
		"rope": msg.get("rope", PackedVector3Array()),
		"claw": msg.get("claw", Transform3D.IDENTITY),
		"has_rope": msg.has("rope"),
	}
	var sender_t: int = int(msg.get("ts", now))
	if _buf.is_empty():
		global_position = snap["pos"]
	_buf.push(sender_t, snap)

	alive = bool(msg.get("alive", true))
	if bool(msg.get("gnd", false)):
		last_ground_pos = snap["pos"]
		has_ground = true
	last_update_ms = now
	visible = alive


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	CoopSync.perf_add(Time.get_ticks_usec() - t0)


func _process_inner(delta: float) -> void:
	if _buf.is_empty():
		return
	if Time.get_ticks_msec() - last_update_ms > 6000:
		visible = false
		_hide_rope()
		return
	var s := _buf.sample(INTERP_DELAY_MS)
	if s.is_empty():
		return
	var a: Dictionary = s["a"]
	var b: Dictionary = s["b"]
	var k: float = s["alpha"]
	var k01 := clampf(k, 0.0, 1.0)

	var pa: Vector3 = a["pos"]
	var pb: Vector3 = b["pos"]
	if pa.distance_squared_to(pb) > TELEPORT_DIST_SQ:
		global_position = pb
	else:
		global_position = pa.lerp(pb, k)
	global_rotation.y = lerp_angle(a["yaw"], b["yaw"], k01)

	if attached:
		attached_time += delta

	var has_rope: bool = b["has_rope"]
	if is_instance_valid(claw_node):
		claw_node.visible = has_rope
		if has_rope:
			var ca: Transform3D = a["claw"]
			var cb: Transform3D = b["claw"]
			if a["has_rope"] and ca.origin.distance_squared_to(cb.origin) < TELEPORT_DIST_SQ:
				claw_node.global_transform = ca.interpolate_with(cb, k01)
			else:
				claw_node.global_transform = cb
	if has_rope:
		var ra: PackedVector3Array = a["rope"]
		var rb: PackedVector3Array = b["rope"]
		_draw_rope(ra, rb, k01)
	else:
		_hide_rope()

	if has_rope and not attached:
		if not _sfx_rope_loop.playing:
			_sfx_rope_loop.play()
	elif _sfx_rope_loop.playing:
		_sfx_rope_loop.stop()


func _apply_cosmetics() -> void:
	# relics earned on the hard routes: 1 = gold name, 2 = gold rope, 3 = a crown
	_label.modulate = GOLD if _cos >= 1 else Color.WHITE
	for m in _rope_materials:
		if m is StandardMaterial3D:
			(m as StandardMaterial3D).albedo_color = Color(0.55, 0.4, 0.12) if _cos >= 2 else Color.WHITE
	if _cos >= 3 and _crown == null:
		_crown = MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.13
		tm.outer_radius = 0.19
		tm.rings = 12
		tm.ring_segments = 6
		_crown.mesh = tm
		var cm := StandardMaterial3D.new()
		cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cm.albedo_color = Color(0.5, 0.36, 0.08)
		_crown.material_override = cm
		_crown.position = Vector3(0, 1.98, 0)
		add_child(_crown)
	elif _cos < 3 and _crown != null:
		_crown.queue_free()
		_crown = null


func _ensure_rope_pool(n: int) -> void:
	while _rope_visuals.size() < n:
		var scene: PackedScene = load("res://scenes/grapple_point_visual.tscn")
		var vis: Node3D = scene.instantiate()
		vis.top_level = true
		vis.visible = false
		add_child(vis)
		var line: MeshInstance3D = vis.get_node("Line")
		var m: Material = _rope_material_base.duplicate() if _rope_material_base else null
		if m:
			line.set_surface_override_material(0, m)
		_rope_visuals.append(vis)
		_rope_lines.append(line)
		_rope_materials.append(m)
		if m is StandardMaterial3D and _cos >= 2:
			(m as StandardMaterial3D).albedo_color = Color(0.55, 0.4, 0.12)


func _hide_rope() -> void:
	for v in _rope_visuals:
		v.visible = false


func _draw_rope(ra: PackedVector3Array, rb: PackedVector3Array, alpha: float) -> void:
	var segs := rb.size() - 1
	if segs < 1:
		_hide_rope()
		return
	_ensure_rope_pool(segs)
	var can_interp := ra.size() == rb.size()
	for i in _rope_visuals.size():
		var vis: Node3D = _rope_visuals[i]
		if i >= segs:
			vis.visible = false
			continue
		var p0: Vector3 = rb[i]
		var p1: Vector3 = rb[i + 1]
		if can_interp:
			p0 = ra[i].lerp(p0, alpha)
			p1 = ra[i + 1].lerp(p1, alpha)
		vis.visible = true
		vis.global_position = p0
		var dir := p1 - p0
		var dist := dir.length()
		if dist > 0.01:
			var up := Vector3.UP
			if absf(dir.normalized().dot(Vector3.UP)) > 0.99:
				up = Vector3.RIGHT
			vis.look_at(p1, up)
		var line: MeshInstance3D = _rope_lines[i]
		line.position = Vector3.FORWARD * dist * 0.5
		line.scale = Vector3(1.0, dist * 0.5, 1.0)
		var m = _rope_materials[i]
		if m and m is StandardMaterial3D:
			m.uv1_scale = Vector3(0.25, -dist, 1.0)
