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
	[Color(0.78, 0.7, 0.58), Color(0.72, 0.62, 0.5), Color(0.5, 0.45, 0.38), Color(0.18, 0.16, 0.13), 0.62, 0.35],
	[Color(0.85, 0.82, 0.72), Color(0.8, 0.76, 0.66), Color(0.32, 0.3, 0.26), Color(0.03, 0.03, 0.03), 0.78, 0.04],
	[Color(0.45, 0.62, 0.42), Color(0.35, 0.55, 0.32), Color(0.16, 0.36, 0.22), Color(0.02, 0.07, 0.04), 0.66, 0.06],
	[Color(0.55, 0.42, 0.3), Color(0.45, 0.34, 0.25), Color(0.32, 0.22, 0.14), Color(0.05, 0.03, 0.02), 0.7, 0.05],
	[Color(0.45, 0.55, 0.58), Color(0.38, 0.48, 0.5), Color(0.22, 0.3, 0.34), Color(0.18, 0.23, 0.27), 0.74, 0.08],
	[Color(0.6, 0.58, 0.62), Color(0.5, 0.48, 0.52), Color(0.24, 0.22, 0.28), Color(0.04, 0.03, 0.05), 0.72, 0.05],
	[Color(0.62, 0.76, 0.95), Color(0.55, 0.7, 0.9), Color(0.25, 0.38, 0.55), Color(0.04, 0.08, 0.14), 0.7, 0.1],
	[Color(0.6, 0.35, 0.25), Color(0.5, 0.28, 0.2), Color(0.5, 0.18, 0.08), Color(0.2, 0.04, 0.01), 0.6, 0.3],
	[Color(0.5, 0.22, 0.24), Color(0.42, 0.18, 0.2), Color(0.42, 0.08, 0.08), Color(0.12, 0.01, 0.01), 0.72, 0.18],
	[Color(0.62, 0.55, 0.45), Color(0.55, 0.48, 0.4), Color(0.14, 0.11, 0.08), Color(0.01, 0.01, 0.01), 0.9, 0.0],
]

var L: Dictionary = {}
var _env: Environment
var _cur_biome := -1
var _blend := 0.0
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
		fl.uv1_scale = Vector3(0.09, 0.09, 0.09)
		_floor_mat.append(fl)
	_mat_bar = StandardMaterial3D.new()
	_mat_bar.albedo_color = Color(0.32, 0.12, 0.08)
	_mat_bar.metallic = 0.7
	_mat_bar.roughness = 0.45
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
float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p) { vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), f.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), f.x), f.y); }
void fragment() {
	vec2 p = VERTEX.xz * 0.08 + vec2(t * 0.03, t * 0.02);
	float v = n(p) * 0.6 + n(p * 2.3 + t * 0.05) * 0.3 + n(p * 5.1) * 0.1;
	vec3 dark = vec3(0.35, 0.03, 0.0); vec3 hot = vec3(1.0, 0.55, 0.08);
	float k = smoothstep(0.35, 0.75, v);
	ALBEDO = mix(dark, hot, k);
	EMISSION = ALBEDO * (0.8 + 2.2 * k);
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
		var ruin: bool = path.contains("Village_") or path.contains("Ghost_Tower")
		for mi in n.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).visibility_range_end = float(p.get("vis", 300.0))
			(mi as GeometryInstance3D).visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			if ruin:
				(mi as GeometryInstance3D).material_override = _mat_ruin


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
		var r: float
		if bool(d.get("up", false)):
			r = ab.size.y * 0.5 * sc
		else:
			r = maxf(ab.size.x, ab.size.z) * 0.5 * sc
		var centre_off: Vector3 = ab.get_center() * sc
		n.position = hit + nrm * (r * (1.0 - 2.0 * embed)) - Vector3(0, centre_off.y, 0)
		n.rotation = Vector3(float(d.get("tilt", 0.0)), float(d.get("yaw", 0.0)), float(d.get("roll", 0.0)))
		n.scale = Vector3.ONE * sc
		add_child(n)
		for mi in n.find_children("*", "GeometryInstance3D", true, false):
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
	o.distance_fade_begin = 140.0
	o.distance_fade_length = 40.0
	add_child(o)
	_lights.append(o)
	return o


func _place_fires() -> void:
	for f in L.get("fires", []):
		_add_fire(_v(f["pos"]), float(f["scale"]))


func _add_fire(pos: Vector3, s: float) -> Node3D:
	var ps: PackedScene = load(PYRELIGHT)
	if ps == null:
		return null
	var n: Node3D = ps.instantiate()
	n.position = pos
	n.scale = Vector3(s, s, s)
	add_child(n)
	return n


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

func _place_bars() -> void:
	for b in L.get("bars", []):
		var bar := MonkeyBar.new()
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
		var pm := PlaneMesh.new()
		pm.size = Vector2(hw * 2.0, hl * 2.0)
		pm.subdivide_width = 24
		pm.subdivide_depth = 12
		mi.mesh = pm
		mi.material_override = _mat_lava
		mi.position = c
		mi.rotation.y = -yaw
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
			add_child(n)
	CoopSync.show_banner("Something is coming.", 3.0)
	Game.audio.play_dark_transition()


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
		var want: bool = best < 170.0
		if mi.visible != want:
			mi.visible = want
			var body: StaticBody3D = mi.get_child(0)
			body.collision_layer = 1 if want else 0


func _setup_environment() -> void:
	var we := get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	_env = we.environment.duplicate()
	we.environment = _env
	_env.fog_depth_end = 220.0
	_look_from = LOOKS[0]
	_look_to = LOOKS[0]
	_apply_look(LOOKS[0])


func _apply_look(k: Array) -> void:
	_env.ambient_light_color = k[2]
	_env.ambient_light_energy = 0.7
	_env.fog_light_color = k[3]
	_env.fog_density = k[4]
	_env.background_color = k[3]
	_env.background_energy_multiplier = k[5]
	_env.volumetric_fog_albedo = k[3].lightened(0.5)
	_env.volumetric_fog_emission = k[3] * 0.4
	_env.volumetric_fog_emission_energy = 0.4


func _biome_at(p: Vector3) -> int:
	var best := -1
	var bd := 1e9
	for z in L.get("zones", []):
		var c := _v(z["center"])
		var d := (Vector3(p.x, 0, p.z) - Vector3(c.x, 0, c.z)).length() + absf(p.y - c.y) * 0.5
		if d < bd:
			bd = d
			best = int(z["biome"])
	return best


func _update_environment(delta: float) -> void:
	if _env == null:
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var b := _biome_at(c.global_position)
	if b < 0:
		return
	if b != _cur_biome:
		_cur_biome = b
		_look_from = _current_look()
		_look_to = LOOKS[b]
		_blend = 0.0
		if _music:
			_music.set_biome(b)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta * 0.25)
		var mixed: Array = []
		for i in _look_to.size():
			if _look_to[i] is Color:
				mixed.append((_look_from[i] as Color).lerp(_look_to[i], _blend))
			else:
				mixed.append(lerpf(_look_from[i], _look_to[i], _blend))
		_apply_look(mixed)


func _current_look() -> Array:
	return [_wall_mat[0].albedo_color, _floor_mat[0].albedo_color, _env.ambient_light_color, _env.fog_light_color, _env.fog_density, _env.background_energy_multiplier]


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
	_hud_depth.text = "%s   %d m   %02d:%02d" % [bname, int(-c.global_position.y), secs / 60, secs % 60]


# ------------------------------------------------------------------ debug tour (screenshots)

func _update_tour(delta: float) -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var stops: Array = L.get("tour", [])
	if stops.is_empty():
		return
	_tour_t -= delta
	if _tour_t < 0.9 and not _tour_shot_done and _tour_i >= 0:
		_tour_shot_done = true
		var img := get_viewport().get_texture().get_image()
		if img:
			if img.get_width() > 960:
				img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
			img.save_png("user://underdark_tour_%02d.png" % _tour_i)
		print("[Underdark] tour fps %d at stop %d" % [Engine.get_frames_per_second(), _tour_i])
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
	# A hookable iron beam hanging from chains. The top is a StaticBody3D so the claw
	# attaches to it like any ledge. Wide enough to climb onto and stand.
	# One of them is rigged: hang from it too long and it rumbles, then sinks 3.5 m.
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
		# the hook rides the bar down instead of hanging in mid-air where the bar was
		if not sinking:
			return
		var c = Game.climber
		if not is_instance_valid(c) or not (c.activeClimberState is ClimberState_Attached) or not is_instance_valid(c.Rope._claw):
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
		bar = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(width, thick, length)
		bar.mesh = bm
		bar.material_override = mat
		bar.position = pos - Vector3(0, thick * 0.5, 0)
		bar.rotation.y = float(b["yaw"])
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.physics_material_override = load("res://physics_materials/stone.tres")
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = bm.size
		cs.shape = bs
		body.add_child(cs)
		bar.add_child(body)
		add_child(bar)
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

