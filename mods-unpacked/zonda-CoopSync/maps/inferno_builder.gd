extends Node3D

# INFERNO: a procedurally built descent for ZondaCoopSync.
# Everything is generated from a fixed seed, so every player builds the exact same shaft.
#
# Layout (top to bottom):
#   0 .. -520     HELL      red rock, fire, lava light, the traps
#   -520 .. -600  THE DARK  no lights at all, follow your friends' name tags
#   -600 .. -1100 COCYTUS   the frozen circle: ice shelves that slide, icicles, blizzards

const SEED := 66613
const DEPTH := 1100.0
const DARK_TOP := -520.0
const DARK_BOTTOM := -600.0
const RADIUS := 17.0
const RING_STEP := 3.0
const SEGMENTS := 28
const TOP_RADIUS := 46.0
const RIM_HEIGHT := 22.0
const WANDER := 7.0
const PLAYER_LAYER := 4
const CLAW_LAYER := 2
const SECOND_CENTIPEDE_Y := -330.0

enum Biome { HELL, DARK, FROST }

const MAT_ROCK := "res://Art/Textures/Rock_01.tres"
const MAT_SAND := "res://Art/Textures/Sand.tres"
const PHYS_STONE := "res://physics_materials/stone.tres"
const PHYS_SAND := "res://physics_materials/Sand.tres"
const PYRELIGHT := "res://Art/Pyrelight.tscn"
const EMBER := "res://Treasure_Pickup.tscn"
const CENTIPEDE := "res://scenes/centipede.tscn"
const TENT := "res://Art/Tent.glb"
const KNIGHT := "res://Art/Knight.glb"
const TEXT_AREA_SCRIPT := "res://scripts/ending_text_display_area.gd"
const FORCE_VOLUME_SCRIPT := "res://scenes/force_volume.gd"
const FORCE_VOLUME := "res://scenes/force_volume.tscn"

# path -> [half extent in xz, y_min, y_max] at scale 1, taken from the mesh bounds
const PIECES := {
	"res://Art/Stone_03.glb": [4.1, -0.79, 0.79],
	"res://Art/Sand_Shelf_Base.glb": [4.7, -1.0, 1.0],
	"res://Art/Stone_10.glb": [7.6, -0.06, 2.36],
	"res://Art/Stone_07.glb": [9.0, -7.99, 7.87],
	"res://Art/Stone_09.glb": [4.9, -8.03, 8.04],
	"res://Art/Stone_08.glb": [12.8, -12.55, 12.2],
	"res://Art/Rock_02.glb": [12.0, -8.91, 8.93],
	"res://Art/Spikes_01.glb": [3.5, -1.0, 44.19],
	"res://Art/Spikes_02.glb": [13.5, -23.0, 24.0],
}
const STONE_LEDGE := "res://Art/Stone_03.glb"
const SAND_LEDGE := "res://Art/Sand_Shelf_Base.glb"
const BIG_PIECES := ["res://Art/Stone_07.glb", "res://Art/Stone_09.glb", "res://Art/Rock_02.glb", "res://Art/Stone_08.glb", "res://Art/Spikes_01.glb"]
const REST_PIECE := "res://Art/Stone_10.glb"
const BOULDER_PIECE := "res://Art/Stone_09.glb"
const ICICLE_PIECE := "res://Art/Spikes_01.glb"
const SPIKES_PIECE := "res://Art/Spikes_02.glb"
const CORPSES := [
	"res://Art/Corpse_01.glb", "res://Art/Corpse_02.glb", "res://Art/Corpse_03.glb",
	"res://Art/Corpse_04.glb", "res://Art/Corpse_05.glb", "res://Art/Corpse_06.glb",
]

var _rng := RandomNumberGenerator.new()
var _noise_a := FastNoiseLite.new()
var _noise_b := FastNoiseLite.new()
var _noise_c := FastNoiseLite.new()
var _mat_rock: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ice: StandardMaterial3D
var _mat_crystal: StandardMaterial3D
var _phys_stone: PhysicsMaterial
var _phys_sand: PhysicsMaterial
var _finish_done := false
var _checkpoints_hit: Dictionary = {}
var _trap_counts := {"crumble": 0, "vent": 0, "boulder": 0, "icicle": 0, "draft": 0, "spikes": 0, "ice": 0}
var _env: Environment
var _second_centipede_spawned := false
var _snow: GPUParticles3D
var _clock := 0.0


func _ready() -> void:
	_rng.seed = SEED
	for n in [_noise_a, _noise_b, _noise_c]:
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.fractal_octaves = 3
	_noise_a.seed = SEED + 1
	_noise_a.frequency = 0.012
	_noise_b.seed = SEED + 2
	_noise_b.frequency = 0.012
	_noise_c.seed = SEED + 3
	_noise_c.frequency = 0.09

	_mat_rock = (load(MAT_ROCK) as StandardMaterial3D).duplicate()
	_mat_rock.albedo_color = Color(0.9, 0.55, 0.42)
	_mat_rock.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_floor = (load(MAT_SAND) as StandardMaterial3D).duplicate()
	_mat_floor.albedo_color = Color(0.55, 0.3, 0.22)
	_mat_floor.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_ice = (load(MAT_ROCK) as StandardMaterial3D).duplicate()
	_mat_ice.albedo_color = Color(0.72, 0.84, 1.0)
	_mat_ice.roughness = 0.35
	_mat_ice.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_crystal = StandardMaterial3D.new()
	_mat_crystal.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_crystal.albedo_color = Color(0.55, 0.85, 1.0)
	_mat_crystal.emission_enabled = true
	_mat_crystal.emission = Color(0.4, 0.8, 1.0)
	_mat_crystal.emission_energy_multiplier = 2.5
	_phys_stone = load(PHYS_STONE)
	_phys_sand = load(PHYS_SAND)

	_setup_environment()
	_build_shaft()
	_build_top_area()
	_build_bottom()
	_build_ledges()
	_build_wall_lights()
	_build_spawn_camp()
	_build_biome_signs()
	_build_snow()
	_spawn_centipede(-75.0, PI)
	print("[Inferno] built: depth %d m, traps %s" % [int(DEPTH), str(_trap_counts)])


func _process(delta: float) -> void:
	_clock += delta
	_update_environment(delta)
	_update_snow()
	_check_second_centipede()


# ------------------------------------------------------------------ shape helpers

func _biome(y: float) -> int:
	if y > DARK_TOP:
		return Biome.HELL
	if y > DARK_BOTTOM:
		return Biome.DARK
	return Biome.FROST


func _center_at(y: float) -> Vector3:
	return Vector3(_noise_a.get_noise_1d(y) * WANDER, y, _noise_b.get_noise_1d(y) * WANDER)


func _radius_at(y: float, angle: float) -> float:
	var n: float = _noise_c.get_noise_3d(cos(angle) * 12.0, y * 0.6, sin(angle) * 12.0)
	var r := RADIUS
	if y < DARK_BOTTOM:
		r = RADIUS * 1.15  # the frozen circle opens up a little
	return r * (1.0 + 0.22 * n)


func _wall_point(y: float, angle: float) -> Vector3:
	return _center_at(y) + Vector3(cos(angle), 0.0, sin(angle)) * _radius_at(y, angle)


func _inward(y: float, angle: float) -> Vector3:
	var d: Vector3 = _center_at(y) - _wall_point(y, angle)
	d.y = 0.0
	return d.normalized()


func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, face_toward: Vector3, uv_scale: float) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if n.dot(face_toward - a) < 0.0:
		var t := b
		b = c
		c = t
	for p in [a, b, c]:
		st.set_uv(Vector2(p.x, p.z) * uv_scale)
		st.add_vertex(p)


func _commit_static(st: SurfaceTool, mat: Material, phys: PhysicsMaterial) -> MeshInstance3D:
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)
	var body := StaticBody3D.new()
	body.physics_material_override = phys
	var shape := CollisionShape3D.new()
	var tri: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	tri.backface_collision = true
	shape.shape = tri
	body.add_child(shape)
	mi.add_child(body)
	return mi


func _make_area(pos: Vector3, radius: float, mask: int) -> Area3D:
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


func _tint_ice(n: Node3D) -> void:
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = _mat_ice


# ------------------------------------------------------------------ geometry

func _build_shaft() -> void:
	# One mesh per biome so the frozen circle gets its own material.
	_build_shaft_section(0.0, DARK_TOP, _mat_rock)
	_build_shaft_section(DARK_TOP, DARK_BOTTOM, _mat_rock)
	_build_shaft_section(DARK_BOTTOM, -DEPTH - 8.0, _mat_ice)


func _build_shaft_section(y_top: float, y_bottom: float, mat: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := y_top
	while y > y_bottom:
		var y2: float = maxf(y - RING_STEP, y_bottom)
		var c1 := _center_at(y)
		var c2 := _center_at(y2)
		for i in SEGMENTS:
			var a1 := TAU * float(i) / float(SEGMENTS)
			var a2 := TAU * float(i + 1) / float(SEGMENTS)
			var p00 := _wall_point(y, a1)
			var p10 := _wall_point(y, a2)
			var p01 := _wall_point(y2, a1)
			var p11 := _wall_point(y2, a2)
			var mid: Vector3 = (c1 + c2) * 0.5
			_add_tri(st, p00, p10, p11, mid, 0.05)
			_add_tri(st, p00, p11, p01, mid, 0.05)
		y = y2
	_commit_static(st, mat, _phys_stone)


func _build_top_area() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGMENTS:
		var a1 := TAU * float(i) / float(SEGMENTS)
		var a2 := TAU * float(i + 1) / float(SEGMENTS)
		var p0 := _wall_point(0.0, a1)
		var p1 := _wall_point(0.0, a2)
		var q0 := Vector3(cos(a1), 0.0, sin(a1)) * TOP_RADIUS
		var q1 := Vector3(cos(a2), 0.0, sin(a2)) * TOP_RADIUS
		var up_ref: Vector3 = (p0 + q1) * 0.5 + Vector3.UP * 10.0
		_add_tri(st, p0, q0, q1, up_ref, 0.02)
		_add_tri(st, p0, q1, p1, up_ref, 0.02)
	_commit_static(st, _mat_floor, _phys_sand)

	var wall := SurfaceTool.new()
	wall.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGMENTS:
		var a1 := TAU * float(i) / float(SEGMENTS)
		var a2 := TAU * float(i + 1) / float(SEGMENTS)
		var r1: float = TOP_RADIUS * (1.0 + 0.08 * _noise_c.get_noise_2d(cos(a1) * 9.0, sin(a1) * 9.0))
		var r2: float = TOP_RADIUS * (1.0 + 0.08 * _noise_c.get_noise_2d(cos(a2) * 9.0, sin(a2) * 9.0))
		var q0 := Vector3(cos(a1), 0.0, sin(a1)) * r1
		var q1 := Vector3(cos(a2), 0.0, sin(a2)) * r2
		var q0t := q0 + Vector3(0.0, RIM_HEIGHT, 0.0) - Vector3(cos(a1), 0.0, sin(a1)) * 3.0
		var q1t := q1 + Vector3(0.0, RIM_HEIGHT, 0.0) - Vector3(cos(a2), 0.0, sin(a2)) * 3.0
		var axis_ref := Vector3(0.0, RIM_HEIGHT * 0.5, 0.0)
		_add_tri(wall, q0, q1, q1t, axis_ref, 0.05)
		_add_tri(wall, q0, q1t, q0t, axis_ref, 0.05)
	_commit_static(wall, _mat_rock, _phys_stone)


func _build_bottom() -> void:
	var y := -DEPTH
	var c := _center_at(y)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGMENTS:
		var a1 := TAU * float(i) / float(SEGMENTS)
		var a2 := TAU * float(i + 1) / float(SEGMENTS)
		var p0 := _wall_point(y, a1) - _inward(y, a1) * 1.5
		var p1 := _wall_point(y, a2) - _inward(y, a2) * 1.5
		_add_tri(st, c, p0, p1, c + Vector3.UP * 5.0, 0.02)
	_commit_static(st, _mat_ice, _phys_stone)

	# The frozen lake: a pale glowing disc with figures locked in it.
	var lake := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 9.0
	disc.bottom_radius = 9.0
	disc.height = 0.3
	disc.radial_segments = 24
	lake.mesh = disc
	var ice := StandardMaterial3D.new()
	ice.albedo_color = Color(0.6, 0.8, 1.0)
	ice.roughness = 0.1
	ice.emission_enabled = true
	ice.emission = Color(0.25, 0.5, 0.8)
	ice.emission_energy_multiplier = 1.2
	lake.material_override = ice
	lake.position = c + Vector3(0.0, 0.12, 0.0)
	add_child(lake)

	var light := OmniLight3D.new()
	light.light_color = Color(0.55, 0.75, 1.0)
	light.light_energy = 2.5
	light.omni_range = 50.0
	light.position = c + Vector3(0.0, 5.0, 0.0)
	add_child(light)

	var kp: PackedScene = load(KNIGHT)
	if kp:
		for i in 5:
			var k: Node3D = kp.instantiate()
			var a := TAU * float(i) / 5.0 + 0.4
			k.position = c + Vector3(cos(a), 0.0, sin(a)) * 5.5 + Vector3(0.0, -0.9, 0.0)
			k.rotation.y = a + PI
			k.rotation.x = _rng.randf_range(-0.3, 0.3)
			add_child(k)

	var finish := _make_area(c + Vector3(0.0, 3.0, 0.0), 8.0, PLAYER_LAYER)
	finish.body_entered.connect(_on_finish_entered)
	add_child(finish)

	_add_text_area(c + Vector3(0.0, 2.0, 0.0), 14.0, "The ninth circle. Even the fire froze here. They are still waiting.")


func _build_ledges() -> void:
	var y := -9.0
	var angle: float = PI * 0.5
	var since_rest := 0.0
	var since_big := 20.0
	var since_boulder := 40.0
	var since_draft := 60.0
	var since_spikes := 30.0
	while y > -DEPTH + 16.0:
		var biome := _biome(y)
		angle += _rng.randf_range(-1.05, 1.05)
		if since_rest > 95.0 and biome != Biome.DARK:
			_place_rest_platform(y, angle)
			since_rest = 0.0
			y -= 14.0
			continue
		var ledge_top := _place_ledge(y, angle)
		if _rng.randf() < 0.35:
			_place_ledge(y - _rng.randf_range(2.5, 5.0), angle + _rng.randf_range(-1.3, 1.3), true)
		if since_big > 42.0:
			_place_big_piece(y - _rng.randf_range(4.0, 9.0), angle + _rng.randf_range(2.0, 4.3))
			since_big = 0.0
		if since_boulder > 115.0 and ledge_top != Vector3.INF and biome != Biome.DARK:
			_place_boulder_trap(y, angle, ledge_top)
			since_boulder = 0.0
		if since_draft > 135.0 and biome == Biome.HELL:
			_place_updraft(y - 6.0)
			since_draft = 0.0
		if since_spikes > 95.0 and biome != Biome.DARK:
			_place_spike_bed(y - _rng.randf_range(3.0, 7.0), angle + _rng.randf_range(1.2, 2.4))
			since_spikes = 0.0
		var gap := _rng.randf_range(8.0, 12.5)
		if biome == Biome.DARK:
			gap = _rng.randf_range(7.0, 10.0)  # more ledges, you cannot see them anyway
		y -= gap
		since_rest += gap
		since_big += gap
		since_boulder += gap
		since_draft += gap
		since_spikes += gap


func _place_kit(path: String, wall_y: float, angle: float, scale_f: float, protrude: float, yaw: float, tilt: float = 0.0) -> Node3D:
	var ps: PackedScene = load(path)
	if ps == null:
		return null
	var n: Node3D = ps.instantiate()
	var dims: Array = PIECES[path]
	var half: float = dims[0] * scale_f
	var y_max: float = dims[2] * scale_f
	var w := _wall_point(wall_y, angle)
	var inward := _inward(wall_y, angle)
	n.position = w + inward * (protrude - half) + Vector3(0.0, -y_max, 0.0)
	n.scale = Vector3.ONE * scale_f
	n.rotation = Vector3(tilt, yaw, 0.0)
	add_child(n)
	if _biome(wall_y) == Biome.FROST:
		_tint_ice(n)
	return n


func _place_ledge(wall_y: float, angle: float, small: bool = false) -> Vector3:
	var biome := _biome(wall_y)
	var crumble_chance := 0.32
	if biome == Biome.DARK:
		crumble_chance = 0.18
	elif biome == Biome.FROST:
		crumble_chance = 0.28
	var crumble: bool = _rng.randf() < crumble_chance
	var path: String = SAND_LEDGE if crumble else STONE_LEDGE
	var s: float = _rng.randf_range(0.5, 0.75) if not small else _rng.randf_range(0.35, 0.5)
	var protrude: float = _rng.randf_range(2.6, 3.8) if not small else _rng.randf_range(1.8, 2.6)
	var n := _place_kit(path, wall_y, angle, s, protrude, _rng.randf() * TAU, _rng.randf_range(-0.08, 0.08))
	if n == null:
		return Vector3.INF
	var inward := _inward(wall_y, angle)
	var top := _wall_point(wall_y, angle) + inward * (protrude * 0.55)
	var reach: float = PIECES[path][0] * s + 1.5
	if crumble:
		var trap := CrumbleLedge.new()
		trap.setup(n, top, reach)
		add_child(trap)
		_trap_counts["crumble"] += 1
		if not small and _rng.randf() < 0.5:
			_place_ember(top + Vector3(0.0, 1.3, 0.0))
		return top
	if biome == Biome.FROST and not small and _rng.randf() < 0.55:
		# Ice shelf: tilted toward the pit, you slide unless you keep moving or hook in.
		var slide := IceShelf.new()
		slide.setup(top, reach, inward)
		add_child(slide)
		_trap_counts["ice"] += 1
	if not small and _rng.randf() < 0.4:
		_place_ember(top + Vector3(0.0, 1.3, 0.0))
	if not small and _rng.randf() < 0.3 and biome != Biome.FROST:
		_place_corpse(top + Vector3(0.0, 0.05, 0.0), _rng.randf() * TAU, _rng.randf_range(0.8, 1.0))
	if biome == Biome.HELL and not small and _rng.randf() < 0.28:
		if _rng.randf() < 0.6:
			_place_fire_vent(top + Vector3(0.0, 0.1, 0.0))
		else:
			_place_fire(top + Vector3(0.0, 0.1, 0.0), 0.35, 0.7, 14.0)
	elif biome == Biome.FROST and not small and _rng.randf() < 0.45:
		_place_crystal(top + Vector3(_rng.randf_range(-1.5, 1.5), 0.0, _rng.randf_range(-1.5, 1.5)), _rng.randf_range(0.6, 1.3))
	return top


func _place_rest_platform(wall_y: float, angle: float) -> void:
	var s := 0.85
	var protrude := 8.5
	var n := _place_kit(REST_PIECE, wall_y, angle, s, protrude, _rng.randf() * TAU)
	if n == null:
		return
	var top := _wall_point(wall_y, angle) + _inward(wall_y, angle) * (protrude * 0.5)
	_place_fire(top + Vector3(1.5, 0.1, 0.0), 0.7, 1.4, 22.0)
	_place_ember(top + Vector3(-2.5, 1.3, 1.5))
	_place_corpse(top + Vector3(2.5, 0.05, -2.0), _rng.randf() * TAU, 1.0)
	_place_corpse(top + Vector3(-1.0, 0.05, -3.0), _rng.randf() * TAU, 0.9)
	_add_checkpoint(top + Vector3(0.0, 2.0, 0.0), 5.5)
	var depth_m := int(-wall_y)
	if _biome(wall_y) == Biome.FROST:
		_add_text_area(top + Vector3(0.0, 2.0, 0.0), 9.0, "A resting shelf, %d meters down. Someone lit a fire in the ice. It is still burning." % depth_m)
	else:
		_add_text_area(top + Vector3(0.0, 2.0, 0.0), 9.0, "A resting shelf, %d meters down. The walls are warm to the touch." % depth_m)


func _place_big_piece(wall_y: float, angle: float) -> void:
	var path: String = BIG_PIECES[_rng.randi_range(0, BIG_PIECES.size() - 1)]
	var s := _rng.randf_range(0.7, 1.15)
	var protrude := _rng.randf_range(2.5, 4.5)
	var tilt := _rng.randf_range(-0.35, 0.35)
	if path.ends_with("Spikes_01.glb"):
		s = _rng.randf_range(0.35, 0.6)
		tilt = _rng.randf_range(-0.25, 0.25)
	_place_kit(path, wall_y, angle, s, protrude, _rng.randf() * TAU, tilt)


func _place_ember(pos: Vector3) -> void:
	var ps: PackedScene = load(EMBER)
	if ps == null:
		return
	var e: Node3D = ps.instantiate()
	e.position = pos
	add_child(e)


func _place_corpse(pos: Vector3, yaw: float, s: float) -> void:
	var path: String = CORPSES[_rng.randi_range(0, CORPSES.size() - 1)]
	var ps: PackedScene = load(path)
	if ps == null:
		return
	var c: Node3D = ps.instantiate()
	c.position = pos
	c.rotation.y = yaw
	c.scale = Vector3.ONE * s
	add_child(c)


func _place_fire(pos: Vector3, fire_scale: float, energy: float, light_range: float) -> Array:
	var f: Node3D = null
	var ps: PackedScene = load(PYRELIGHT)
	if ps:
		f = ps.instantiate()
		f.position = pos
		f.scale = Vector3(fire_scale, fire_scale, fire_scale)
		add_child(f)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.55, 0.2)
	l.light_energy = energy
	l.omni_range = light_range
	l.position = pos + Vector3(0.0, 1.5, 0.0)
	add_child(l)
	return [f, l]


func _place_crystal(pos: Vector3, s: float) -> void:
	var mi := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.6, 1.6, 0.6)
	mi.mesh = prism
	mi.material_override = _mat_crystal
	mi.position = pos + Vector3(0.0, 0.8 * s, 0.0)
	mi.scale = Vector3.ONE * s
	mi.rotation = Vector3(_rng.randf_range(-0.25, 0.25), _rng.randf() * TAU, _rng.randf_range(-0.25, 0.25))
	add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color(0.45, 0.75, 1.0)
	l.light_energy = 0.9
	l.omni_range = 16.0
	l.position = pos + Vector3(0.0, 1.5, 0.0)
	add_child(l)


func _build_wall_lights() -> void:
	var y := -14.0
	while y > -DEPTH + 10.0:
		var biome := _biome(y)
		var a := _rng.randf() * TAU
		var p := _wall_point(y, a) + _inward(y, a) * 2.5
		if biome == Biome.HELL:
			var l := OmniLight3D.new()
			l.light_color = Color(1.0, 0.3, 0.12)
			l.light_energy = 0.45
			l.omni_range = 28.0
			l.position = p
			add_child(l)
			y -= _rng.randf_range(20.0, 26.0)
		elif biome == Biome.FROST:
			var l := OmniLight3D.new()
			l.light_color = Color(0.5, 0.7, 1.0)
			l.light_energy = 0.35
			l.omni_range = 26.0
			l.position = p
			add_child(l)
			_place_crystal(_wall_point(y, a) + _inward(y, a) * 0.6, _rng.randf_range(1.5, 2.6))
			y -= _rng.randf_range(24.0, 32.0)
		else:
			y -= 10.0  # the dark: no lights at all


func _build_spawn_camp() -> void:
	var camp := Vector3(0.0, 0.0, RADIUS + 15.0)
	var ps: PackedScene = load(TENT)
	if ps:
		var t: Node3D = ps.instantiate()
		t.position = camp + Vector3(4.5, 0.0, 1.0)
		t.rotation.y = -0.6
		add_child(t)
	_place_fire(camp + Vector3(-3.0, 0.0, 0.5), 0.8, 1.6, 26.0)
	_place_ember(camp + Vector3(0.0, 1.3, -4.0))
	_place_corpse(camp + Vector3(-6.0, 0.0, 3.0), 1.2, 1.0)
	_add_text_area(camp + Vector3(0.0, 1.5, -2.0), 9.0, "The pit breathes heat. Nothing that fell in ever climbed out. Sand shelves crumble. Stone holds.")


func _build_biome_signs() -> void:
	var c1 := _center_at(DARK_TOP + 6.0)
	_add_text_area(c1, RADIUS + 4.0, "The fires die here. Follow the voices of your friends.")
	var c2 := _center_at(DARK_BOTTOM - 8.0)
	_add_text_area(c2, RADIUS + 6.0, "Cold. The deepest circle was never fire. Ice shelves tilt toward the pit. Keep moving, or hook in.")
	var c3 := _center_at(SECOND_CENTIPEDE_Y - 4.0)
	_add_text_area(c3, RADIUS + 4.0, "Something moved above you.")


func _build_snow() -> void:
	_snow = GPUParticles3D.new()
	_snow.amount = 700
	_snow.lifetime = 9.0
	_snow.emitting = false
	_snow.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 80, 80))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(24.0, 10.0, 24.0)
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 25.0
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.0
	pm.gravity = Vector3(0.0, -1.5, 0.0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.2
	pm.turbulence_noise_scale = 4.0
	_snow.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.9, 0.95, 1.0, 0.85)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = m
	_snow.draw_pass_1 = quad
	add_child(_snow)


func _spawn_centipede(y: float, a: float) -> Node3D:
	var ps: PackedScene = load(CENTIPEDE)
	if ps == null:
		return null
	var c: Node3D = ps.instantiate()
	c.position = _wall_point(y, a) + _inward(y, a) * 2.5
	add_child(c)
	return c


func _check_second_centipede() -> void:
	if _second_centipede_spawned:
		return
	# Puppets on guests are created automatically from the host's centipede list,
	# so only the host (or a solo player) spawns the real one.
	if CoopSync.in_session() and not CoopSync.is_host:
		_second_centipede_spawned = true
		return
	var players: Array = CoopSync._alive_player_nodes() if CoopSync.in_session() else [Game.climber]
	for p in players:
		if is_instance_valid(p) and p.is_inside_tree() and p.global_position.y < SECOND_CENTIPEDE_Y:
			_second_centipede_spawned = true
			_spawn_centipede(SECOND_CENTIPEDE_Y + 55.0, _rng.randf() * TAU)
			CoopSync.show_banner("Something moved above you.", 4.0)
			print("[Inferno] second centipede released")
			return


# ------------------------------------------------------------------ traps

func _place_fire_vent(pos: Vector3) -> void:
	var parts := _place_fire(pos, 0.35, 0.7, 14.0)
	var vent := FireVent.new()
	vent.setup(parts[0], parts[1], pos, _rng.randf_range(5.5, 9.0), _rng.randf() * 9.0)
	add_child(vent)
	_trap_counts["vent"] += 1


func _place_boulder_trap(ledge_y: float, angle: float, ledge_top: Vector3) -> void:
	var drop_from_y := ledge_y + 34.0
	if drop_from_y > -12.0:
		return
	var frost := _biome(ledge_y) == Biome.FROST
	var ps: PackedScene = load(ICICLE_PIECE if frost else BOULDER_PIECE)
	if ps == null:
		return
	var rock: Node3D = ps.instantiate()
	for body in rock.find_children("*", "StaticBody3D", true, false):
		body.queue_free()
	var w := _wall_point(drop_from_y, angle)
	var inward := _inward(drop_from_y, angle)
	if frost:
		# An icicle: the spike piece hung point-down from the wall.
		rock.scale = Vector3.ONE * 0.18
		rock.rotation = Vector3(PI + _rng.randf_range(-0.15, 0.15), _rng.randf() * TAU, 0.0)
		rock.position = w + inward * 2.4 + Vector3(0.0, 4.0, 0.0)
		_tint_ice(rock)
		_trap_counts["icicle"] += 1
	else:
		rock.scale = Vector3.ONE * 0.55
		rock.rotation = Vector3(_rng.randf_range(-0.3, 0.3), _rng.randf() * TAU, _rng.randf_range(-0.3, 0.3))
		rock.position = w + inward * 3.2
		_trap_counts["boulder"] += 1
	add_child(rock)
	var trap := Boulder.new()
	trap.setup(rock, ledge_top + Vector3(0.0, 1.5, 0.0), 6.5, 2.6 if frost else 3.6)
	add_child(trap)


func _place_updraft(y: float) -> void:
	var c := _center_at(y)
	var a := _rng.randf() * TAU
	var offset := Vector3(cos(a), 0.0, sin(a)) * _rng.randf_range(3.0, 7.0)
	var pos := c + offset
	var side := Vector3(cos(a + 1.3), 0.0, sin(a + 1.3)) * _rng.randf_range(14.0, 22.0)
	var force := Vector3.UP * 48.0 + side
	var area: Area3D = null
	var fv: PackedScene = load(FORCE_VOLUME)
	if fv:
		area = fv.instantiate()
		area.set("force_direction", force)
		var cs: CollisionShape3D = area.get_node_or_null("CollisionShape3D")
		if cs:
			var cyl := CylinderShape3D.new()
			cyl.radius = 5.5
			cyl.height = 30.0
			cs.shape = cyl
		var gp: GPUParticles3D = area.get_node_or_null("GPUParticles3D")
		if gp:
			gp.position = Vector3(0.0, -14.0, 0.0)
			gp.visibility_aabb = AABB(Vector3(-20, -20, -20), Vector3(40, 60, 40))
	else:
		area = Area3D.new()
		area.set_script(load(FORCE_VOLUME_SCRIPT))
		area.collision_layer = 0
		area.set("force_direction", force)
		var shape := CollisionShape3D.new()
		var cyl2 := CylinderShape3D.new()
		cyl2.radius = 5.5
		cyl2.height = 30.0
		shape.shape = cyl2
		area.add_child(shape)
	area.collision_mask = PLAYER_LAYER | CLAW_LAYER
	area.position = pos
	add_child(area)
	var ps: PackedScene = load(PYRELIGHT)
	if ps:
		var f: Node3D = ps.instantiate()
		f.position = pos + Vector3(0.0, -15.0, 0.0)
		f.scale = Vector3(1.4, 1.4, 1.4)
		add_child(f)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.5, 0.15)
	l.light_energy = 1.8
	l.omni_range = 30.0
	l.position = pos + Vector3(0.0, -8.0, 0.0)
	add_child(l)
	_add_text_area(pos, 8.0, "Hot air rushes upward. It will throw your hook.")
	_trap_counts["draft"] += 1


func _place_spike_bed(wall_y: float, angle: float) -> void:
	var s := _rng.randf_range(0.25, 0.4)
	var n := _place_kit(SPIKES_PIECE, wall_y, angle, s, _rng.randf_range(3.0, 4.5), _rng.randf() * TAU, _rng.randf_range(-0.4, 0.4))
	if n == null:
		return
	var hurt := _make_area(n.position + Vector3(0.0, PIECES[SPIKES_PIECE][2] * s * 0.6, 0.0), 6.0 * s + 2.0, PLAYER_LAYER)
	var inward := _inward(wall_y, angle)
	var trap := SpikeBed.new()
	trap.setup(hurt, inward)
	add_child(hurt)
	add_child(trap)
	var l := OmniLight3D.new()
	if _biome(wall_y) == Biome.FROST:
		l.light_color = Color(0.4, 0.7, 1.0)
	else:
		l.light_color = Color(1.0, 0.15, 0.05)
	l.light_energy = 0.8
	l.omni_range = 16.0
	l.position = hurt.position
	add_child(l)
	_trap_counts["spikes"] += 1


class CrumbleLedge extends Node3D:
	var piece: Node3D
	var area: Area3D
	var reach := 4.0
	var origin: Vector3
	var stand_time := 0.0
	var state := 0  # 0 armed, 1 shaking, 2 falling/gone
	var shake_t := 0.0

	func setup(p: Node3D, top: Vector3, r: float) -> void:
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
		area.position = top + Vector3(0.0, 0.8, 0.0)

	func _ready() -> void:
		add_child(area)

	func _process(delta: float) -> void:
		if not is_instance_valid(piece) or not is_instance_valid(Game.climber):
			return
		if state == 0:
			if area.overlaps_body(Game.climber):
				stand_time += delta
				if stand_time > 1.1:
					state = 1
					shake_t = 0.0
					Game.audio.play_metal_hit(piece.global_position)
			else:
				stand_time = maxf(0.0, stand_time - delta * 2.0)
		elif state == 1:
			shake_t += delta
			piece.position = origin + Vector3(sin(shake_t * 55.0) * 0.12, -shake_t * 0.25, cos(shake_t * 47.0) * 0.12)
			if shake_t > 0.7:
				_collapse()

	func _collapse() -> void:
		state = 2
		var c = Game.climber
		if is_instance_valid(c) and c.activeClimberState is ClimberState_Attached and is_instance_valid(c.Rope._claw):
			if c.Rope._claw.global_position.distance_to(piece.global_position) < reach + 1.5:
				c.set_climber_state(c.defaultClimberState)
				Game.audio.play_rope_snap_sfx()
		var tw := create_tween()
		tw.tween_property(piece, "position:y", origin.y - 70.0, 1.6).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(_hide_piece)
		await get_tree().create_timer(24.0).timeout
		if not is_instance_valid(piece):
			return
		piece.position = origin
		piece.visible = true
		_set_collision(true)
		stand_time = 0.0
		state = 0

	func _hide_piece() -> void:
		if is_instance_valid(piece):
			piece.visible = false
			_set_collision(false)

	func _set_collision(on: bool) -> void:
		for body in piece.find_children("*", "StaticBody3D", true, false):
			body.collision_layer = 1 if on else 0


class IceShelf extends Node3D:
	var area: Area3D
	var slide: Vector3

	func setup(top: Vector3, r: float, inward: Vector3) -> void:
		slide = inward
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = r
		shape.shape = sph
		area.add_child(shape)
		area.position = top + Vector3(0.0, 0.8, 0.0)

	func _ready() -> void:
		add_child(area)

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		if c.is_on_floor() and area.overlaps_body(c):
			# Steady drift of roughly 1.2 m/s toward the pit unless the player keeps walking.
			c.additional_velocity_next_frame += slide * 0.05


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
		area.position = pos + Vector3(0.0, 1.4, 0.0)

	func _ready() -> void:
		add_child(area)

	func _process(delta: float) -> void:
		clock += delta
		var t: float = fmod(clock + phase, period)
		var active: bool = t < 2.2
		var k: float = 1.0 if active else 0.0
		if is_instance_valid(fire):
			var target := 1.15 if active else 0.35
			var sc: float = lerpf(fire.scale.x, target, clampf(delta * 8.0, 0.0, 1.0))
			fire.scale = Vector3(sc, sc, sc)
		if is_instance_valid(light):
			light.light_energy = lerpf(light.light_energy, 0.7 + 2.6 * k, clampf(delta * 8.0, 0.0, 1.0))
		if not active:
			was_active = false
			tick = 0.0
			return
		if not is_instance_valid(Game.climber):
			return
		if area.overlaps_body(Game.climber):
			tick -= delta
			if tick <= 0.0:
				tick = 0.7
				Game.climber.take_damage(12.0)
				if not was_active:
					Game.climber.additional_velocity_next_frame += Vector3.UP * 7.0
			was_active = true


class Boulder extends Node3D:
	var rock: Node3D
	var trip: Area3D
	var hurt: Area3D
	var rest: Vector3
	var falling := false
	var armed := true
	var hit_done := false

	func setup(r: Node3D, trip_pos: Vector3, trip_radius: float, hurt_radius: float) -> void:
		rock = r
		rest = r.position
		trip = Area3D.new()
		trip.collision_layer = 0
		trip.collision_mask = 4
		var ts := CollisionShape3D.new()
		var tsph := SphereShape3D.new()
		tsph.radius = trip_radius
		ts.shape = tsph
		trip.add_child(ts)
		trip.position = trip_pos
		hurt = Area3D.new()
		hurt.collision_layer = 0
		hurt.collision_mask = 4
		var hs := CollisionShape3D.new()
		var hsph := SphereShape3D.new()
		hsph.radius = hurt_radius
		hs.shape = hsph
		hurt.add_child(hs)

	func _ready() -> void:
		add_child(trip)
		add_child(hurt)
		trip.body_entered.connect(_on_trip)

	func _on_trip(body: Node3D) -> void:
		if not armed or body != Game.climber:
			return
		armed = false
		falling = true
		hit_done = false
		Game.audio.play_metal_hit(rock.global_position)
		var tw := create_tween()
		tw.tween_property(rock, "position:y", rest.y - 95.0, 1.9).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(func(): rock.visible = false; falling = false)
		await get_tree().create_timer(26.0).timeout
		if not is_instance_valid(rock):
			return
		rock.position = rest
		rock.visible = true
		armed = true

	func _process(_delta: float) -> void:
		if not falling or hit_done or not is_instance_valid(rock) or not is_instance_valid(Game.climber):
			return
		hurt.global_position = rock.global_position
		if hurt.overlaps_body(Game.climber):
			hit_done = true
			var c = Game.climber
			c.take_damage(60.0)
			var away: Vector3 = (c.global_position - rock.global_position)
			away.y = 0.0
			away = away.normalized() if away.length_squared() > 0.001 else Vector3.RIGHT
			c.additional_velocity_next_frame += away * 14.0 + Vector3.DOWN * 6.0
			Game.audio.play_player_was_bit()


class SpikeBed extends Node3D:
	var hurt: Area3D
	var shove: Vector3
	var cooldown := 0.0

	func setup(h: Area3D, inward: Vector3) -> void:
		hurt = h
		shove = inward

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


# ------------------------------------------------------------------ triggers

func _add_text_area(pos: Vector3, radius: float, text: String) -> void:
	var a := _make_area(pos, radius, PLAYER_LAYER)
	a.set_script(load(TEXT_AREA_SCRIPT))
	a.set("displayed_text", text)
	add_child(a)


func _add_checkpoint(pos: Vector3, radius: float) -> void:
	var a := _make_area(pos, radius, PLAYER_LAYER)
	var id := _checkpoints_hit.size()
	_checkpoints_hit[id] = false
	a.body_entered.connect(func(body: Node3D): _on_checkpoint_entered(id, body))
	add_child(a)


func _on_checkpoint_entered(id: int, body: Node3D) -> void:
	if body != Game.climber or _checkpoints_hit.get(id, true):
		return
	_checkpoints_hit[id] = true
	Game.audio.play_player_healed()
	if is_instance_valid(Game.climber):
		Game.climber.heal(50.0)
	if CoopSync.in_session():
		CoopSync.broadcast_checkpoint()
		CoopSync.on_checkpoint_reached()
	else:
		CoopSync.show_banner("Checkpoint reached.", 3.0)


func _on_finish_entered(body: Node3D) -> void:
	if body != Game.climber or _finish_done:
		return
	_finish_done = true
	Game.audio.play_player_healed()
	CoopSync.show_banner("You reached the bottom of the Inferno.", 8.0)
	await get_tree().create_timer(8.0).timeout
	if not is_inside_tree():
		return
	if CoopSync.in_session() and not CoopSync.is_host:
		return
	SceneLoader.load_scene(func():
		Game.on_new_loaded_level()
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn"))


# ------------------------------------------------------------------ atmosphere

# [background, bg_energy, ambient, fog_color, fog_density, vol_albedo, vol_emission, vol_energy]
const ENV_HELL := [Color(0.22, 0.03, 0.01), 0.35, Color(0.5, 0.16, 0.08), Color(0.32, 0.05, 0.01), 0.55, Color(1.0, 0.45, 0.25), Color(0.18, 0.02, 0.0), 0.6]
const ENV_DARK := [Color(0.0, 0.0, 0.0), 0.0, Color(0.03, 0.02, 0.02), Color(0.0, 0.0, 0.0), 0.9, Color(0.2, 0.2, 0.2), Color(0.0, 0.0, 0.0), 0.0]
const ENV_FROST := [Color(0.35, 0.45, 0.6), 0.45, Color(0.42, 0.52, 0.68), Color(0.5, 0.62, 0.8), 0.7, Color(0.85, 0.92, 1.0), Color(0.03, 0.06, 0.1), 0.35]


func _setup_environment() -> void:
	var we := get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	_env = we.environment.duplicate()
	we.environment = _env
	_env.fog_depth_end = 260.0
	_env.adjustment_saturation = 0.8
	_apply_env(ENV_HELL, 0.0)


func _env_blend_for(y: float) -> Array:
	# Returns [settings_a, settings_b, alpha] for the given depth, with soft edges between biomes.
	var edge := 25.0
	if y > DARK_TOP + edge:
		return [ENV_HELL, ENV_HELL, 0.0]
	if y > DARK_TOP - edge:
		return [ENV_HELL, ENV_DARK, (DARK_TOP + edge - y) / (2.0 * edge)]
	if y > DARK_BOTTOM + edge:
		return [ENV_DARK, ENV_DARK, 0.0]
	if y > DARK_BOTTOM - edge:
		return [ENV_DARK, ENV_FROST, (DARK_BOTTOM + edge - y) / (2.0 * edge)]
	return [ENV_FROST, ENV_FROST, 0.0]


func _apply_env(s: Array, blizzard: float) -> void:
	_env.background_color = s[0]
	_env.background_energy_multiplier = s[1]
	_env.ambient_light_color = s[2]
	_env.fog_light_color = s[3]
	_env.fog_density = clampf(s[4] + blizzard, 0.0, 1.0)
	_env.volumetric_fog_albedo = s[5]
	_env.volumetric_fog_emission = s[6]
	_env.volumetric_fog_emission_energy = s[7]


func _update_environment(_delta: float) -> void:
	if _env == null or not is_instance_valid(Game.climber) or not Game.climber.is_inside_tree():
		return
	var y: float = Game.climber.global_position.y
	var b := _env_blend_for(y)
	var a: Array = b[0]
	var c: Array = b[1]
	var t: float = b[2]
	var mixed: Array = []
	for i in a.size():
		if a[i] is Color:
			mixed.append((a[i] as Color).lerp(c[i], t))
		else:
			mixed.append(lerpf(a[i], c[i], t))
	var blizzard := 0.0
	if y < DARK_BOTTOM:
		# Gusts: fog thickens for a few seconds every half minute or so.
		var g: float = sin(_clock * 0.21) * 0.5 + sin(_clock * 0.53) * 0.5
		blizzard = clampf((g - 0.55) * 0.9, 0.0, 0.28)
	_apply_env(mixed, blizzard)


func _update_snow() -> void:
	if _snow == null or not is_instance_valid(Game.climber) or not Game.climber.is_inside_tree():
		return
	var pos: Vector3 = Game.climber.global_position
	var want: bool = pos.y < DARK_BOTTOM
	if _snow.emitting != want:
		_snow.emitting = want
	if want:
		_snow.global_position = pos + Vector3(0.0, 9.0, 0.0)
