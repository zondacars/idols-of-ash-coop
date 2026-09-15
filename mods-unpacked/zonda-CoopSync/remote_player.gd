extends Node3D

const SnapBuffer := preload("res://mods-unpacked/zonda-CoopSync/snap_buffer.gd")

const MODEL_PATH := "res://Art/Knight.glb"
const FEET_OFFSET := -0.78
const INTERP_DELAY_MS := 60
const TELEPORT_DIST_SQ := 400.0

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
	var now := Time.get_ticks_msec()
	player_name = str(msg.get("n", player_name))
	scene_path = str(msg.get("scene", ""))
	var hp: float = float(msg.get("hp", 100.0))
	var label_text := "%s  ♥ %d" % [player_name, int(round(hp))]
	if _label.text != label_text:
		_label.text = label_text

	var was_attached := attached
	attached = bool(msg.get("att", false))
	if attached and not was_attached:
		attached_time = 0.0

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
