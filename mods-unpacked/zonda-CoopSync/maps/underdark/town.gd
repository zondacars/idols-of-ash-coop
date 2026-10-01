extends Node

# ============================================================================================
# DRY GULCH (ZondaCoopSync 5.1, feature module "town"): the weird-west ghost town on the dry
# lake bed under the Drowned Galleries, and THE NOON DUEL.
#
# The generator (wave2.py) writes L["town"]: the street frame (center, u along the main street,
# v across it), the buildings, the boardwalks, the boats, the clock tower and the gallows. The
# cave mesh only has the bed; everything wooden is built here at load, with box collision, so it
# can be walked on, climbed and hooked. Its western props (ext/west/) come through the map's
# normal prop path (L["props"]).
#
# THE NOON DUEL. The first time a living player steps onto the plaza, the clock tower strikes
# twelve: twelve tolls, one every 2 s (24 s of warning you hear across the whole bed, the clock's
# face brighter on every toll). From the sixth toll a spectral marshal stands in front of the tower
# at the far end of the main street. On the twelfth he draws: every living player he can see down
# the street (a 40 degree cone, 300 m, an unbroken line from his gun to their chest) takes 35 HP
# and a shove. Anything solid between is cover: a wagon, a barrel, a trough, a post, a wall, a
# doorway. Then he fades, and the clock strikes again every 75 s while anyone is still in the town.
#   authority only decides; every PC plays the same 24 s timeline from the event:
#   duel_<n>  non-persistent  {n}            the clock starts striking (authority -> all)
#   cbite_duel<n>                            the map's bite plumbing (register_bites "duel")
#
# PUBLIC API (the sidewinder module reads it)
#   func ready_town() -> bool
#   func surface_at(p: Vector3) -> String    "sand" (the bed: the street, the flats), "planks" (a
#                                            boardwalk or porch), "inside" (a building's floor),
#                                            "roof", "off" (not in the town's bed band)
#   func in_town(p: Vector3) -> bool         over the lake bed, within 6 m of its floor
#   func bed_y(p: Vector3) -> float          the bed's height under p (no noise)
#   func duel_state() -> Dictionary          {"n", "toll", "drawn"} for tests
#
# DEV TEST: maps/underdark/town.flag ("" = build + duel; "duel" = the duel only). Tag [TOWN],
#   last line "[TOWN] test done N/N PASS".
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const TEX := DIR + "tex/town/"
const TAG := "[TOWN]"
const PLAYER_LAYER := 4

const STOREY := 4.2
const WALL_T := 0.22
const DOOR_W := 1.8
const DOOR_H := 2.7
const PORCH_H := 3.7

const TOLLS := 12
const TOLL_EVERY := 2.0
const MARSHAL_FROM := 6              # he is there from this toll on
const DUEL_EVERY := 75.0
const DRAW_DMG := 70.0               # what take_damage gets (the game halves it: 35 HP)
const DRAW_PUSH := 9.0
const DRAW_CONE := 0.766             # cos 40 deg
const DRAW_RANGE := 300.0
const PLAZA_R := 22.0

const SFX_TOLL := "town_toll_73678_1.ogg"
const SFX_SHOT := "duel_shot_683175_1.ogg"
const SFX_SPURS := ["duel_spur_828863_1.ogg", "duel_spur_400593_1.ogg", "duel_spur_400593_2.ogg"]
const SFX_PIANO := "bed_gulch_piano_476558.ogg"
const SFX_WHISPER := "res://sfx/soundsnap/1022742.audio-HUMAN_VOCAL_Female_4_Breath_Medium_01.wav"

signal bit(who: Node3D, damage: float, id: String)

var map: Node = null
var T: Dictionary = {}
var root: Node3D = null
var built := false
var _c := Vector3.ZERO
var _u := Vector3.FORWARD
var _v := Vector3.RIGHT
var _floor := 0.0
var _shore := 0.0
var _radius := 200.0
var _half_len := 112.0
var _half_w := 9.0
var _walk_h := 0.55
var _rects: Array = []               # [{"c": Vector3, "x": Vector3, "z": Vector3, "hx", "hz", "top", "kind"}]
var _mats: Dictionary = {}
var _lamps: Array = []               # [OmniLight3D, base energy, phase]
var _clock_face: MeshInstance3D = null
var _clock_glow: OmniLight3D = null
var _hand_m: Node3D = null
var _hand_h: Node3D = null
var _bell_node: Node3D = null
var _toll_player: AudioStreamPlayer3D = null
var _piano: AudioStreamPlayer3D = null
var _gallows_body: Node3D = null
var _marshal: Node3D = null
var _marshal_mats: Array = []
var _muzzle: OmniLight3D = null
var _shot_player: AudioStreamPlayer3D = null
var _spur_player: AudioStreamPlayer3D = null
var _warned: Dictionary = {}
var _rng := RandomNumberGenerator.new()

# the duel (every PC plays the timeline; the authority decides the hits)
var duel_n := 0
var _duel_t := -1.0                  # seconds since the clock started striking, -1 = quiet
var _duel_tolls := 0
var _duel_drawn := false
var _next_duel := -1.0               # authority: run time of the next strike (-1 = not armed)
var _plaza_seen := false
var _run_t := 0.0
var _was_auth := false
var _hint_shown := false
var hits_log: Array = []             # tests: [n, name, damage] per draw hit
var cover_log: Array = []            # tests: [n, name, "cover"/"cone"/"far"] for each player not hit
var _test: Node = null


# ============================================================================ setup

func setup(m: Node) -> void:
	map = m
	_was_auth = CoopSync.map_is_authority()
	var L = m.get("L")
	if L is Dictionary and (L as Dictionary).get("town") is Dictionary:
		T = (L as Dictionary)["town"]
	if T.is_empty():
		print("[Underdark] town: none in this layout")
		return
	_c = _v3(T.get("center", [0, 0, 0]))
	_u = _v3(T.get("u", [0, 0, 1])).normalized()
	_v = _v3(T.get("v", [1, 0, 0])).normalized()
	_floor = float(T.get("floor", _c.y))
	_shore = float(T.get("shore", _floor))
	_radius = float(T.get("radius", 200.0))
	var st: Dictionary = T.get("street", {})
	_half_len = float(st.get("half_len", 112.0))
	_half_w = float(st.get("half_w", 9.0))
	_walk_h = float(st.get("walk_h", 0.55))
	var t0 := Time.get_ticks_msec()
	root = Node3D.new()
	root.name = "DryGulch"
	m.add_child(root)
	_build_materials()
	for b in T.get("buildings", []):
		if b is Dictionary:
			_build_building(b)
	for w in T.get("boardwalks", []):
		if w is Dictionary:
			_build_walk(w)
	for bt in T.get("boats", []):
		if bt is Dictionary:
			_build_boat(bt)
	if T.get("clock") is Dictionary:
		_build_clock(T["clock"])
	if T.get("gallows") is Dictionary:
		_build_gallows(T["gallows"])
	_build_marshal()
	_build_sounds()
	built = true
	print("[Underdark] town: DRY GULCH built, %d buildings, %d boardwalks, %d boats, %d surfaces, %d ms" % [
			(T.get("buildings", []) as Array).size(), (T.get("boardwalks", []) as Array).size(),
			(T.get("boats", []) as Array).size(), _rects.size(), Time.get_ticks_msec() - t0])
	if map.has_method("register_events"):
		map.call("register_events", ["duel_"], _on_duel_event, true)
	if map.has_method("register_bites"):
		map.call("register_bites", "duel", self)
	if map.has_method("register_threats"):
		map.call("register_threats", self)
	_setup_test()


func ready_town() -> bool:
	return built


func _warn(key: String, text: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("%s %s" % [TAG, text])


static func _v3(a) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if a is Vector3:
		return a
	return Vector3.ZERO


# ============================================================================ materials

func _tex(file: String) -> Texture2D:
	var path := TEX + file
	if not FileAccess.file_exists(path):
		_warn("tex " + file, "missing texture " + path)
		return null
	var img := Image.new()
	if img.load_jpg_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_materials() -> void:
	var alb := _tex("planks_albedo.jpg")
	var nrm := _tex("planks_normal.jpg")
	var wood := StandardMaterial3D.new()
	wood.albedo_texture = alb
	# dark, old boards: the lantern a metre away must not wash them white (tour shot, saloon)
	wood.albedo_color = Color(0.42, 0.37, 0.32)
	if nrm != null:
		wood.normal_enabled = true
		wood.normal_texture = nrm
		wood.normal_scale = 0.7
	wood.roughness = 0.96
	wood.metallic_specular = 0.12
	wood.uv1_triplanar = true
	wood.uv1_world_triplanar = true
	wood.uv1_scale = Vector3(0.62, 0.62, 0.62)
	wood.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	wood.set_meta("zonda_town", "wood")
	_mats["wood"] = wood
	var dark: StandardMaterial3D = wood.duplicate()
	dark.albedo_color = Color(0.26, 0.21, 0.18)
	_mats["trim"] = dark
	var bleached: StandardMaterial3D = wood.duplicate()
	bleached.albedo_color = Color(0.62, 0.58, 0.5)
	_mats["sign"] = bleached
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.36, 0.33, 0.29)
	stone.roughness = 0.95
	stone.set_meta("zonda_town", "stone")
	_mats["stone"] = stone
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.02, 0.02, 0.025)
	glass.roughness = 0.35
	glass.metallic_specular = 0.6
	_mats["glass"] = glass
	var lit: StandardMaterial3D = glass.duplicate()
	lit.albedo_color = Color(0.08, 0.05, 0.02)
	lit.emission_enabled = true
	lit.emission = Color(0.55, 0.32, 0.12)
	lit.emission_energy_multiplier = 0.35
	_mats["glass_lit"] = lit
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.12, 0.11, 0.1)
	iron.metallic = 0.6
	iron.roughness = 0.55
	_mats["iron"] = iron
	var rope := StandardMaterial3D.new()
	rope.albedo_color = Color(0.32, 0.27, 0.19)
	rope.roughness = 1.0
	_mats["rope"] = rope
	var face := StandardMaterial3D.new()
	face.albedo_color = Color(0.42, 0.44, 0.38)
	face.emission_enabled = true
	face.emission = Color(0.55, 0.62, 0.45)
	face.emission_energy_multiplier = 0.12
	face.roughness = 0.7
	_mats["face"] = face


# ============================================================================ building blocks

func _mesh_box(parent: Node3D, pos: Vector3, size: Vector3, mat_key: String, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mats.get(mat_key)
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


func _col_box(body: StaticBody3D, pos: Vector3, size: Vector3, rot := Vector3.ZERO) -> void:
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	cs.position = pos
	cs.rotation = rot
	body.add_child(cs)


func _part(node: Node3D, body: StaticBody3D, pos: Vector3, size: Vector3, mat_key: String, collide := true, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := _mesh_box(node, pos, size, mat_key, rot)
	if collide and body != null:
		_col_box(body, pos, size, rot)
	return mi


func _new_body(node: Node3D, mat := "wood") -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var pm_path := "res://physics_materials/wood.tres" if mat == "wood" else "res://physics_materials/stone.tres"
	if ResourceLoader.exists(pm_path):
		body.physics_material_override = load(pm_path)
	node.add_child(body)
	return body


func _rect(node: Node3D, local_c: Vector3, hx: float, hz: float, top_local: float, kind: String) -> void:
	# a walkable surface for surface_at(): its centre and axes in world space
	var xf: Transform3D = node.global_transform
	_rects.append({"c": xf * local_c, "x": (xf.basis.x).normalized(), "z": (xf.basis.z).normalized(),
			"hx": hx, "hz": hz, "top": (xf * Vector3(local_c.x, top_local, local_c.z)).y, "kind": kind})


func _label(node: Node3D, pos: Vector3, text: String, size: int, col: Color) -> Label3D:
	var lb := Label3D.new()
	lb.text = text
	lb.font_size = size
	lb.pixel_size = 0.012
	lb.modulate = col
	lb.outline_size = 8
	lb.outline_modulate = Color(0.04, 0.03, 0.02, 0.9)
	lb.position = pos
	lb.double_sided = false
	lb.shaded = true
	lb.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	node.add_child(lb)
	return lb


func _place(node: Node3D, b: Dictionary) -> void:
	node.position = _v3(b.get("pos", [0, 0, 0]))
	node.rotation = Vector3(0.0, float(b.get("yaw", 0.0)), float(b.get("lean", 0.0)))


# ============================================================================ buildings

func _build_building(b: Dictionary) -> void:
	var node := Node3D.new()
	node.name = str(b.get("id", "bld"))
	_rng.seed = hash(str(b.get("id", "bld")))
	root.add_child(node)
	_place(node, b)
	var kind := str(b.get("kind", "house"))
	if kind == "church":
		_build_church(node, b)
		return
	var w := float(b.get("w", 10.0))
	var d := float(b.get("d", 12.0))
	var h := float(b.get("h", STOREY))
	var storeys := int(b.get("storeys", 1))
	var open := bool(b.get("open", false))
	var F := _walk_h                                    # the floor is level with the boardwalk
	var body := _new_body(node)
	var stone := _new_body(node, "stone")
	# the foundation (stone), the floor (boards)
	_part(node, stone, Vector3(0, F * 0.5 - 0.15, 0), Vector3(w, F + 0.3, d), "stone")
	_mesh_box(node, Vector3(0, F + 0.02, 0), Vector3(w - 0.1, 0.06, d - 0.1), "wood")
	_rect(node, Vector3.ZERO, w * 0.5, d * 0.5, F, "inside")
	var z_front := -d * 0.5 + WALL_T * 0.5
	var z_back := d * 0.5 - WALL_T * 0.5
	var wall_y := F + h * 0.5
	# back and side walls
	_part(node, body, Vector3(0, wall_y, z_back), Vector3(w, h, WALL_T), "wood")
	_part(node, body, Vector3(-w * 0.5 + WALL_T * 0.5, wall_y, 0), Vector3(WALL_T, h, d), "wood")
	_part(node, body, Vector3(w * 0.5 - WALL_T * 0.5, wall_y, 0), Vector3(WALL_T, h, d), "wood")
	# the front wall, with its door (a gap when you can go in, boarded up when not)
	var seg := (w - DOOR_W) * 0.5
	var fh := minf(h, STOREY)
	_part(node, body, Vector3(-w * 0.5 + seg * 0.5, F + fh * 0.5, z_front), Vector3(seg, fh, WALL_T), "wood")
	_part(node, body, Vector3(w * 0.5 - seg * 0.5, F + fh * 0.5, z_front), Vector3(seg, fh, WALL_T), "wood")
	_part(node, body, Vector3(0, F + DOOR_H + (fh - DOOR_H) * 0.5, z_front), Vector3(DOOR_W, fh - DOOR_H, WALL_T), "wood")
	if not open:
		_part(node, body, Vector3(0, F + DOOR_H * 0.5, z_front + 0.06), Vector3(DOOR_W - 0.1, DOOR_H, 0.08), "trim")
		for k in 3:
			_mesh_box(node, Vector3(0, F + 0.6 + k * 0.85, z_front - 0.07), Vector3(DOOR_W + 0.3, 0.16, 0.06), "trim",
					Vector3(0, 0, _rng.randf_range(-0.25, 0.25)))
	# the upper storey: a front wall with the balcony door, a floor with a stair hole, a ramp up
	if storeys >= 2:
		var uh := h - STOREY
		var bal := bool(b.get("balcony", false))
		if bal:
			_part(node, body, Vector3(-w * 0.5 + seg * 0.5, F + STOREY + uh * 0.5, z_front), Vector3(seg, uh, WALL_T), "wood")
			_part(node, body, Vector3(w * 0.5 - seg * 0.5, F + STOREY + uh * 0.5, z_front), Vector3(seg, uh, WALL_T), "wood")
			_part(node, body, Vector3(0, F + STOREY + DOOR_H + (uh - DOOR_H) * 0.5, z_front), Vector3(DOOR_W, maxf(uh - DOOR_H, 0.2), WALL_T), "wood")
		else:
			_part(node, body, Vector3(0, F + STOREY + uh * 0.5, z_front), Vector3(w, uh, WALL_T), "wood")
		if open:
			var hole_w := 2.4
			var hole_d := 5.6
			var main_w := w - 2.0 * WALL_T - hole_w
			_part(node, body, Vector3(hole_w * 0.5, F + STOREY, 0), Vector3(main_w, 0.16, d - 2.0 * WALL_T), "wood")
			_part(node, body, Vector3(-w * 0.5 + WALL_T + hole_w * 0.5, F + STOREY, -hole_d * 0.5), Vector3(hole_w, 0.16, d - 2.0 * WALL_T - hole_d), "wood")
			# the stair: a ramp along the side wall, from the back up to the hole's front edge
			var run := hole_d + 2.2
			var ang := atan2(STOREY, run)
			var rl := sqrt(run * run + STOREY * STOREY)
			_part(node, body, Vector3(-w * 0.5 + WALL_T + hole_w * 0.5, F + STOREY * 0.5, d * 0.5 - WALL_T - run * 0.5),
					Vector3(hole_w - 0.2, 0.18, rl), "trim", true, Vector3(ang, 0, 0))
			_rect(node, Vector3(hole_w * 0.5, 0, 0), main_w * 0.5, d * 0.5, F + STOREY, "inside")
		else:
			_part(node, body, Vector3(0, F + STOREY, 0), Vector3(w - 2.0 * WALL_T, 0.16, d - 2.0 * WALL_T), "wood")
	# the roof (flat, walkable) and the false front with its sign
	_part(node, body, Vector3(0, F + h + 0.1, 0), Vector3(w + 0.4, 0.2, d + 0.4), "trim")
	_rect(node, Vector3.ZERO, w * 0.5 + 0.2, d * 0.5 + 0.2, F + h + 0.2, "roof")
	var front_h := float(b.get("front_h", h + 2.0))
	if front_h > h + 0.3:
		var ph := front_h - h
		_part(node, body, Vector3(0, F + h + ph * 0.5, z_front), Vector3(w, ph, WALL_T), "wood")
		var sign := str(b.get("sign", ""))
		if sign != "":
			_mesh_box(node, Vector3(0, F + h + ph * 0.5, z_front - 0.14), Vector3(w * 0.78, minf(1.3, ph - 0.3), 0.08), "sign")
			var lb := _label(node, Vector3(0, F + h + ph * 0.5, z_front - 0.19), sign, 64, Color(0.13, 0.1, 0.08))
			lb.outline_size = 0
			lb.rotation.y = PI
			lb.pixel_size = clampf((w * 0.68) / maxf(float(sign.length()) * 38.0, 1.0), 0.006, 0.02)
	# windows (dark glass; a few still lit from inside)
	var lit := bool(b.get("lamp", false))
	for wx in [-w * 0.32, w * 0.32]:
		if absf(wx) < DOOR_W * 0.5 + 0.8:
			continue
		_mesh_box(node, Vector3(wx, F + 1.9, z_front - 0.12), Vector3(1.2, 1.5, 0.05), "glass_lit" if lit else "glass")
		if storeys >= 2:
			_mesh_box(node, Vector3(wx, F + STOREY + 1.9, z_front - 0.12), Vector3(1.2, 1.4, 0.05), "glass")
	for sx in [-1.0, 1.0]:
		_mesh_box(node, Vector3(sx * (w * 0.5 + 0.03), F + 1.9, d * 0.1), Vector3(0.05, 1.4, 1.1), "glass")
	# the porch over the boardwalk (or the balcony, for the saloon and the hotel)
	var walk_w := float((T.get("street", {}) as Dictionary).get("walk_w", 3.2))
	var z_post := -d * 0.5 - walk_w + 0.25
	for px in [-w * 0.5 + 0.25, w * 0.5 - 0.25]:
		_part(node, body, Vector3(px, PORCH_H * 0.5 + F * 0.5, z_post), Vector3(0.22, PORCH_H + F, 0.22), "trim")
	if bool(b.get("balcony", false)) and storeys >= 2:
		var by := F + STOREY
		_part(node, body, Vector3(0, by, -d * 0.5 - walk_w * 0.5 + 0.1), Vector3(w, 0.16, walk_w + 0.2), "wood")
		_rect(node, Vector3(0, 0, -d * 0.5 - walk_w * 0.5), w * 0.5, walk_w * 0.5, by + 0.08, "planks")
		_part(node, body, Vector3(0, by + 0.55, z_post), Vector3(w, 0.1, 0.1), "trim")
		for k in int(w / 1.2):
			_mesh_box(node, Vector3(-w * 0.5 + 0.6 + k * 1.2, by + 0.3, z_post), Vector3(0.06, 0.5, 0.06), "trim")
		for px2 in [-w * 0.5 + 0.25, w * 0.5 - 0.25]:
			_part(node, body, Vector3(px2, by + (h - STOREY) * 0.5, z_post), Vector3(0.2, h - STOREY, 0.2), "trim")
		_part(node, body, Vector3(0, F + h - 0.2, -d * 0.5 - walk_w * 0.5), Vector3(w + 0.3, 0.12, walk_w + 0.4), "trim", true, Vector3(0.1, 0, 0))
	else:
		_part(node, body, Vector3(0, F + PORCH_H + 0.05, -d * 0.5 - walk_w * 0.5 + 0.1), Vector3(w + 0.3, 0.12, walk_w + 0.5), "trim", true, Vector3(0.09, 0, 0))
	if open:
		_furnish(node, body, kind, w, d, F, storeys)
	if lit:
		var lamp := Vector3(0, F + PORCH_H - 0.5, -d * 0.5 - walk_w * 0.5)
		_add_lamp(node.global_transform * lamp, 0.5)
		if open:
			_add_lamp(node.global_transform * Vector3(0, F + 3.0, 0), 0.35)


func _furnish(node: Node3D, body: StaticBody3D, kind: String, w: float, d: float, F: float, storeys: int) -> void:
	var back := d * 0.5 - 1.2
	match kind:
		"saloon":
			_part(node, body, Vector3(w * 0.12, F + 0.55, back - 0.4), Vector3(w * 0.55, 1.1, 0.8), "trim")
			_prop(node, "Piano.glb", Vector3(-w * 0.32, F, back - 0.3), PI, 0.55)
			_prop(node, "WesternTable.glb", Vector3(-w * 0.15, F, -d * 0.12), 0.3, 0.55)
			_prop(node, "WesternPlayTable.glb", Vector3(w * 0.22, F, -d * 0.18), -0.4, 0.55)
			_prop(node, "WesternChair.glb", Vector3(-w * 0.15 + 1.0, F, -d * 0.12 + 0.6), 1.9, 0.55)
			_prop(node, "WesternChair.glb", Vector3(w * 0.22 - 0.8, F, -d * 0.18 - 0.9), 3.6, 0.55)
			_prop(node, "Beer.glb", Vector3(w * 0.1, F + 1.1, back - 0.4), 0.0, 0.6)
			_prop(node, "StuffedBullHead.glb", Vector3(0, F + 2.6, d * 0.5 - WALL_T - 0.3), PI, 1.0)
			_prop(node, "WantedPoster.glb", Vector3(-w * 0.5 + WALL_T + 0.03, F + 1.8, 0.0), PI * 0.5, 1.1)
		"bank":
			_part(node, body, Vector3(0, F + 0.6, d * 0.1), Vector3(w * 0.75, 1.2, 0.6), "trim")
			_prop(node, "Chest_Base.glb", Vector3(w * 0.25, F, back - 0.6), 0.0, 0.6)
			_prop(node, "Chest_Top.glb", Vector3(w * 0.25, F, back - 0.6), 0.0, 0.6)
		"jail":
			for k in 9:
				_part(node, body, Vector3(-w * 0.5 + 1.0 + k * 0.45, F + 1.35, d * 0.15), Vector3(0.06, 2.7, 0.06), "iron")
			_part(node, body, Vector3(-w * 0.5 + 2.8, F + 2.75, d * 0.15), Vector3(4.0, 0.1, 0.1), "iron")
			_prop(node, "WesternBed.glb", Vector3(-w * 0.3, F, back - 0.5), 0.0, 0.42)
			_prop(node, "WesternTable.glb", Vector3(w * 0.25, F, -d * 0.1), 0.2, 0.5)
		"store":
			for k in 6:
				_prop(node, ["Crate.glb", "WesternBarrel.glb", "WesternBarrel_hay.glb"][k % 3],
						Vector3(_rng.randf_range(-w * 0.35, w * 0.35), F, _rng.randf_range(-d * 0.1, back - 0.6)), _rng.randf() * TAU, 0.9)
			_part(node, body, Vector3(0, F + 1.0, back), Vector3(w * 0.8, 2.0, 0.5), "trim")
		"undertaker":
			for k in 3:
				_part(node, body, Vector3(-w * 0.3 + k * 1.3, F + 1.05, back - 0.3), Vector3(0.65, 2.1, 0.35), "trim", true, Vector3(-0.18, 0, 0))
			_part(node, body, Vector3(w * 0.15, F + 0.35, -d * 0.05), Vector3(0.7, 0.55, 2.0), "trim")
		"livery":
			for k in 5:
				_prop(node, "WesternBarrel_hay.glb", Vector3(_rng.randf_range(-w * 0.35, w * 0.35), F, _rng.randf_range(0.0, back - 0.5)), _rng.randf() * TAU, 0.9)
			_prop(node, "WoodWheel.glb", Vector3(-w * 0.5 + WALL_T + 0.1, F + 0.75, 0.0), PI * 0.5, 1.0)
			_prop(node, "Log.glb", Vector3(w * 0.2, F, back - 0.4), 0.3, 1.2)
		"hotel":
			_part(node, body, Vector3(-w * 0.2, F + 0.55, d * 0.05), Vector3(3.0, 1.1, 0.7), "trim")
			_prop(node, "OldBench.glb", Vector3(w * 0.2, F, -d * 0.25), 0.0, 0.5)
			if storeys >= 2:
				_prop(node, "WesternBed.glb", Vector3(w * 0.25, F + STOREY + 0.1, back - 1.0), 0.0, 0.42)
		_:
			pass


func _prop(node: Node3D, file: String, local: Vector3, yaw: float, scale: float) -> Node3D:
	if map == null or not map.has_method("ext_instance"):
		return null
	var n = map.call("ext_instance", "ext/west/" + file, 0.34)
	if not (n is Node3D):
		return null
	node.add_child(n)
	(n as Node3D).position = local
	(n as Node3D).rotation.y = yaw
	(n as Node3D).scale = Vector3.ONE * scale
	return n


func _add_lamp(pos: Vector3, energy: float) -> void:
	if map == null or not map.has_method("add_light"):
		return
	var l = map.call("add_light", pos, Color(1.0, 0.6, 0.28), energy, 10.0)
	if l is OmniLight3D:
		_lamps.append([l, energy, randf() * 10.0])


# ---------------------------------------------------------------------------- the church

func _build_church(node: Node3D, b: Dictionary) -> void:
	var w := float(b.get("w", 13.0))
	var d := float(b.get("d", 22.0))
	var h := float(b.get("h", 7.5))
	var F := float(b.get("foundation", 1.3))
	var body := _new_body(node)
	var stone := _new_body(node, "stone")
	_part(node, stone, Vector3(0, F * 0.5 - 0.2, 0), Vector3(w + 0.6, F + 0.4, d + 0.6), "stone")
	_rect(node, Vector3.ZERO, w * 0.5, d * 0.5, F, "inside")
	# steps up to the door
	for k in 4:
		var sh := F * (k + 1) / 4.0
		_part(node, stone, Vector3(0, sh * 0.5, -d * 0.5 - 0.3 - (3 - k) * 0.55), Vector3(3.2, sh, 0.6), "stone")
	var z_front := -d * 0.5 + WALL_T * 0.5
	var seg := (w - DOOR_W - 0.6) * 0.5
	_part(node, body, Vector3(0, F + h * 0.5, d * 0.5 - WALL_T * 0.5), Vector3(w, h, WALL_T), "wood")
	_part(node, body, Vector3(-w * 0.5 + WALL_T * 0.5, F + h * 0.5, 0), Vector3(WALL_T, h, d), "wood")
	_part(node, body, Vector3(w * 0.5 - WALL_T * 0.5, F + h * 0.5, 0), Vector3(WALL_T, h, d), "wood")
	_part(node, body, Vector3(-w * 0.5 + seg * 0.5, F + h * 0.5, z_front), Vector3(seg, h, WALL_T), "wood")
	_part(node, body, Vector3(w * 0.5 - seg * 0.5, F + h * 0.5, z_front), Vector3(seg, h, WALL_T), "wood")
	_part(node, body, Vector3(0, F + 3.2 + (h - 3.2) * 0.5, z_front), Vector3(DOOR_W + 0.6, h - 3.2, WALL_T), "wood")
	# the gable roof: two slopes meeting on the ridge
	var pitch := 0.62
	var half := w * 0.5 + 0.5
	var sl := half / cos(pitch)
	for sx in [-1.0, 1.0]:
		_part(node, body, Vector3(sx * half * 0.5, F + h + tan(pitch) * half * 0.5, 0), Vector3(sl, 0.22, d + 0.8), "trim", true,
				Vector3(0, 0, -sx * pitch))
	# the gable ends (triangles, as two stacked boxes)
	for zz in [z_front, d * 0.5 - WALL_T * 0.5]:
		_part(node, body, Vector3(0, F + h + 0.9, zz), Vector3(w * 0.66, 1.8, WALL_T), "wood")
		_part(node, body, Vector3(0, F + h + 2.5, zz), Vector3(w * 0.3, 1.6, WALL_T), "wood")
	# the steeple over the door, with its cross
	var sh2 := float(b.get("steeple", 16.0))
	var sp := Vector3(0, 0, -d * 0.5 + 1.8)
	_part(node, body, sp + Vector3(0, F + h + (sh2 - h) * 0.4, 0), Vector3(3.0, (sh2 - h) * 0.8 + 2.0, 3.0), "wood")
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 2.3
	cm.height = 5.0
	cm.radial_segments = 4
	cone.mesh = cm
	cone.material_override = _mats["trim"]
	cone.position = sp + Vector3(0, F + sh2 + 2.2, 0)
	cone.rotation.y = PI * 0.25
	node.add_child(cone)
	_mesh_box(node, sp + Vector3(0, F + sh2 + 5.4, 0), Vector3(0.18, 1.8, 0.18), "iron")
	_mesh_box(node, sp + Vector3(0, F + sh2 + 5.7, 0), Vector3(1.0, 0.16, 0.18), "iron")
	# pews, the altar, two candles that are somehow still burning
	for k in 7:
		for sx in [-1.0, 1.0]:
			_part(node, body, Vector3(sx * w * 0.24, F + 0.45, -d * 0.25 + k * 1.6), Vector3(w * 0.36, 0.5, 0.45), "trim")
	_part(node, body, Vector3(0, F + 0.6, d * 0.5 - 2.4), Vector3(2.6, 1.2, 1.1), "stone")
	_add_lamp(node.global_transform * Vector3(0, F + 1.9, d * 0.5 - 2.4), 0.3)
	for wx in [-w * 0.5 - 0.03, w * 0.5 + 0.03]:
		for k in 3:
			_mesh_box(node, Vector3(wx, F + 3.4, -d * 0.25 + k * d * 0.25), Vector3(0.05, 2.6, 1.0), "glass")


# ---------------------------------------------------------------------------- boardwalks

func _build_walk(wk: Dictionary) -> void:
	var a := _v3(wk.get("a", [0, 0, 0]))
	var bb := _v3(wk.get("b", [0, 0, 0]))
	var ww := float(wk.get("w", 3.2))
	var hh := float(wk.get("h", _walk_h))
	var mid := (a + bb) * 0.5
	var dir := bb - a
	dir.y = 0.0
	var ln := dir.length()
	if ln < 0.5:
		return
	var node := Node3D.new()
	node.name = "walk"
	root.add_child(node)
	node.position = Vector3(mid.x, bed_y(mid), mid.z)
	node.rotation.y = atan2(dir.x, dir.z)       # local +Z runs along the walk
	var body := _new_body(node)
	_part(node, body, Vector3(0, hh - 0.08, 0), Vector3(ww, 0.16, ln), "wood")
	_rect(node, Vector3.ZERO, ww * 0.5, ln * 0.5, hh, "planks")
	# posts under it, and a ramp down to the street at each end and in the middle
	var k := -ln * 0.5 + 1.0
	while k < ln * 0.5:
		for sx in [-ww * 0.5 + 0.15, ww * 0.5 - 0.15]:
			_mesh_box(node, Vector3(sx, (hh - 0.16) * 0.5, k), Vector3(0.14, hh - 0.16, 0.14), "trim")
		k += 2.2
	var ramp_l := 2.2
	var ang := atan2(hh, ramp_l)
	var rl := sqrt(ramp_l * ramp_l + hh * hh)
	for zz in [-ln * 0.5 - ramp_l * 0.5 + 0.05, ln * 0.5 + ramp_l * 0.5 - 0.05]:
		var sgn := -1.0 if zz < 0.0 else 1.0
		_part(node, body, Vector3(0, hh * 0.5 - 0.05, zz), Vector3(ww * 0.9, 0.12, rl), "wood", true, Vector3(sgn * ang, 0, 0))
	# from the street side (local -X faces the street when the walk runs along +Z with the buildings at +X:
	# whichever side is nearer the street axis) a ramp in the middle
	var to_axis: float = (_c - mid).dot(_v)
	var side := 1.0
	var xl: Vector3 = node.global_transform.basis.x
	if xl.dot(_v * signf(to_axis)) < 0.0:
		side = -1.0
	_part(node, body, Vector3(side * (ww * 0.5 + ramp_l * 0.5 - 0.05), hh * 0.5 - 0.05, 0), Vector3(rl, 0.12, 2.4), "wood", true,
			Vector3(0, 0, -side * ang))


# ---------------------------------------------------------------------------- boats on the flats

func _build_boat(bt: Dictionary) -> void:
	var node := Node3D.new()
	node.name = "boat"
	root.add_child(node)
	var p := _v3(bt.get("pos", [0, 0, 0]))
	var up := bool(bt.get("upturned", false))
	node.position = Vector3(p.x, bed_y(p) + (0.55 if up else 0.25), p.z)
	node.rotation = Vector3(0.0, float(bt.get("yaw", 0.0)), float(bt.get("roll", 0.0)) + (PI if up else 0.0))
	var ln := float(bt.get("len", 8.0))
	var mesh := _hull_mesh(ln, ln * 0.26, ln * 0.12)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mats["wood"]
	node.add_child(mi)
	var body := _new_body(node)
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_convex_shape(true, true)
	body.add_child(cs)
	for k in 2:
		_mesh_box(node, Vector3(0, ln * 0.06, -ln * 0.15 + k * ln * 0.3), Vector3(ln * 0.24, 0.08, 0.3), "trim")


func _hull_mesh(ln: float, beam: float, depth: float) -> ArrayMesh:
	# an open dory: half-ellipse sections along the length, pinched at both ends
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nl := 14
	var nr := 8
	var rings: Array = []
	for i in nl + 1:
		var t := float(i) / nl
		var z := (t - 0.5) * ln
		var k := sin(PI * clampf(t * 1.04 - 0.02, 0.0, 1.0))
		var r: Array = []
		for j in nr + 1:
			var a := PI * float(j) / nr
			r.append(Vector3(cos(a) * beam * 0.5 * k, -sin(a) * depth * (0.35 + 0.65 * k) + depth * (1.0 - k) * 0.6, z))
		rings.append(r)
	for i in nl:
		for j in nr:
			var a0: Vector3 = rings[i][j]
			var a1: Vector3 = rings[i][j + 1]
			var b0: Vector3 = rings[i + 1][j]
			var b1: Vector3 = rings[i + 1][j + 1]
			st.add_vertex(a0); st.add_vertex(b0); st.add_vertex(a1)
			st.add_vertex(a1); st.add_vertex(b0); st.add_vertex(b1)
			st.add_vertex(a0); st.add_vertex(a1); st.add_vertex(b0)
			st.add_vertex(a1); st.add_vertex(b1); st.add_vertex(b0)
	st.generate_normals()
	return st.commit()


# ---------------------------------------------------------------------------- the clock tower

func _build_clock(ck: Dictionary) -> void:
	var node := Node3D.new()
	node.name = "ClockTower"
	root.add_child(node)
	var p := _v3(ck.get("pos", [0, 0, 0]))
	node.position = Vector3(p.x, bed_y(p), p.z)
	node.rotation.y = float(ck.get("yaw", 0.0))
	var w := float(ck.get("w", 6.0))
	var h := float(ck.get("h", 19.0))
	var body := _new_body(node)
	var stone := _new_body(node, "stone")
	_part(node, stone, Vector3(0, 1.0, 0), Vector3(w + 1.0, 2.0, w + 1.0), "stone")
	_part(node, body, Vector3(0, 2.0 + (h - 6.0) * 0.5, 0), Vector3(w, h - 6.0, w), "wood")
	# the belfry: four posts, the bell, a pyramid roof
	var by := h - 4.0
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_part(node, body, Vector3(sx * (w * 0.5 - 0.3), by + 2.0, sz * (w * 0.5 - 0.3)), Vector3(0.5, 4.0, 0.5), "trim")
	_part(node, body, Vector3(0, by, 0), Vector3(w, 0.3, w), "trim")
	_bell_node = Node3D.new()
	_bell_node.position = Vector3(0, by + 3.4, 0)
	node.add_child(_bell_node)
	var bell := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.45
	bm.bottom_radius = 1.0
	bm.height = 1.5
	bell.mesh = bm
	bell.material_override = _mats["iron"]
	bell.position = Vector3(0, -0.9, 0)
	_bell_node.add_child(bell)
	var roof := MeshInstance3D.new()
	var rm := CylinderMesh.new()
	rm.top_radius = 0.05
	rm.bottom_radius = w * 0.78
	rm.height = 4.0
	rm.radial_segments = 4
	roof.mesh = rm
	roof.material_override = _mats["trim"]
	roof.position = Vector3(0, h + 2.0, 0)
	roof.rotation.y = PI * 0.25
	node.add_child(roof)
	# the face, looking down the street (local -Z), with its hands at two minutes to twelve
	var face_c := Vector3(0, h - 7.5, -w * 0.5 - 0.06)
	_clock_face = MeshInstance3D.new()
	var fm := CylinderMesh.new()
	fm.top_radius = 1.8
	fm.bottom_radius = 1.8
	fm.height = 0.1
	fm.radial_segments = 24
	_clock_face.mesh = fm
	_clock_face.material_override = _mats["face"]
	_clock_face.position = face_c
	_clock_face.rotation.x = PI * 0.5
	node.add_child(_clock_face)
	for k in 12:
		var a := TAU * k / 12.0
		_mesh_box(node, face_c + Vector3(sin(a) * 1.5, cos(a) * 1.5, -0.08), Vector3(0.1, 0.32 if k % 3 == 0 else 0.18, 0.03), "iron")
	_hand_h = Node3D.new()
	_hand_h.position = face_c + Vector3(0, 0, -0.12)
	node.add_child(_hand_h)
	_mesh_box(_hand_h, Vector3(0, 0.5, 0), Vector3(0.14, 1.0, 0.03), "iron")
	_hand_m = Node3D.new()
	_hand_m.position = face_c + Vector3(0, 0, -0.15)
	node.add_child(_hand_m)
	_mesh_box(_hand_m, Vector3(0, 0.7, 0), Vector3(0.08, 1.4, 0.03), "iron")
	_hand_h.rotation.z = -0.02
	_hand_m.rotation.z = TAU * 2.0 / 60.0           # two minutes to twelve, forever
	_clock_glow = OmniLight3D.new()
	_clock_glow.light_color = Color(0.7, 0.85, 0.6)
	_clock_glow.light_energy = 0.25
	_clock_glow.omni_range = 9.0
	_clock_glow.shadow_enabled = false
	_clock_glow.position = face_c + Vector3(0, 0, -1.2)
	_clock_glow.set_meta("zonda_keep", true)
	_clock_glow.set_meta("zonda_not_real_light", true)
	node.add_child(_clock_glow)
	_toll_player = AudioStreamPlayer3D.new()
	_toll_player.stream = _sfx(SFX_TOLL, false)
	_toll_player.volume_db = 4.0
	_toll_player.unit_size = 40.0
	_toll_player.max_distance = 700.0
	_toll_player.attenuation_filter_cutoff_hz = 9000.0
	_toll_player.bus = _bus()
	_toll_player.position = Vector3(0, by + 3.0, 0)
	node.add_child(_toll_player)


# ---------------------------------------------------------------------------- the gallows

func _build_gallows(g: Dictionary) -> void:
	var node := Node3D.new()
	node.name = "Gallows"
	root.add_child(node)
	var p := _v3(g.get("pos", [0, 0, 0]))
	node.position = Vector3(p.x, bed_y(p), p.z)
	node.rotation.y = float(g.get("yaw", 0.0))
	var body := _new_body(node)
	var top := 3.0
	_part(node, body, Vector3(0, top, 0), Vector3(4.6, 0.25, 4.6), "wood")
	_rect(node, Vector3.ZERO, 2.3, 2.3, top + 0.12, "planks")
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_part(node, body, Vector3(sx * 2.1, top * 0.5, sz * 2.1), Vector3(0.25, top, 0.25), "trim")
	var run := 5.0
	var ang := atan2(top, run)
	_part(node, body, Vector3(0, top * 0.5, 2.3 + run * 0.5), Vector3(1.4, 0.15, sqrt(run * run + top * top)), "wood", true, Vector3(-ang, 0, 0))
	_part(node, body, Vector3(-1.6, top + 2.8, 0), Vector3(0.3, 5.6, 0.3), "trim")
	_part(node, body, Vector3(0.0, top + 5.5, 0), Vector3(3.6, 0.3, 0.3), "trim")
	_part(node, body, Vector3(-1.0, top + 4.7, 0), Vector3(1.4, 0.18, 0.18), "trim", true, Vector3(0, 0, 0.75))
	# the rope and what hangs from it
	_gallows_body = Node3D.new()
	_gallows_body.position = Vector3(1.0, top + 5.35, 0)
	node.add_child(_gallows_body)
	_mesh_box(_gallows_body, Vector3(0, -0.9, 0), Vector3(0.05, 1.8, 0.05), "rope")
	var ps = load("res://Art/Corpse_02.glb")
	if ps is PackedScene:
		var cp: Node3D = (ps as PackedScene).instantiate()
		for co in cp.find_children("*", "CollisionObject3D", true, false):
			co.queue_free()
		cp.position = Vector3(0, -3.9, 0)
		_gallows_body.add_child(cp)
		if map != null and map.has_method("_dim_materials"):
			map.call("_dim_materials", cp, 0.45)


# ---------------------------------------------------------------------------- the marshal

func _build_marshal() -> void:
	var mp := _v3(T.get("marshal", []))
	if mp == Vector3.ZERO:
		return
	_marshal = Node3D.new()
	_marshal.name = "Marshal"
	root.add_child(_marshal)
	_marshal.position = Vector3(mp.x, bed_y(mp), mp.z)
	_marshal.rotation.y = atan2(_u.x, _u.z)            # local -Z looks back down the street (toward -u)
	var ghost := StandardMaterial3D.new()
	ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.albedo_color = Color(0.55, 0.68, 0.6, 0.0)
	ghost.emission_enabled = true
	ghost.emission = Color(0.45, 0.62, 0.52)
	ghost.emission_energy_multiplier = 0.6
	ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost.cull_mode = BaseMaterial3D.CULL_DISABLED
	_marshal_mats.append(ghost)
	var ps = load("res://Art/Corpse_01.glb")
	if ps is PackedScene:
		var body: Node3D = (ps as PackedScene).instantiate()
		for co in body.find_children("*", "CollisionObject3D", true, false):
			co.queue_free()
		for mi in body.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = ghost
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.scale = Vector3.ONE * 1.12
		_marshal.add_child(body)
	var hat = map.call("ext_instance", "ext/west/CowboyHat.glb", 0.3) if map != null and map.has_method("ext_instance") else null
	if hat is Node3D:
		_marshal.add_child(hat)
		(hat as Node3D).position = Vector3(0, 1.95, 0)
		(hat as Node3D).scale = Vector3.ONE * 0.62
		for mi in (hat as Node3D).find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = ghost
	# the gun, held low at first
	var gun := Node3D.new()
	gun.name = "Gun"
	gun.position = Vector3(0.35, 1.05, -0.15)
	_marshal.add_child(gun)
	var g1 := _mesh_box(gun, Vector3(0, 0, -0.18), Vector3(0.06, 0.08, 0.36), "iron")
	g1.material_override = ghost
	var g2 := _mesh_box(gun, Vector3(0, -0.1, 0.0), Vector3(0.05, 0.16, 0.08), "iron")
	g2.material_override = ghost
	_muzzle = OmniLight3D.new()
	_muzzle.light_color = Color(1.0, 0.85, 0.55)
	_muzzle.light_energy = 0.0
	_muzzle.omni_range = 14.0
	_muzzle.shadow_enabled = false
	_muzzle.position = Vector3(0, 0, -0.45)
	_muzzle.set_meta("zonda_keep", true)
	gun.add_child(_muzzle)
	_shot_player = AudioStreamPlayer3D.new()
	_shot_player.stream = _sfx(SFX_SHOT, false)
	_shot_player.volume_db = 10.0
	_shot_player.unit_size = 45.0
	_shot_player.max_distance = 800.0
	_shot_player.bus = _bus()
	_shot_player.position = Vector3(0, 1.2, 0)
	_marshal.add_child(_shot_player)
	_spur_player = AudioStreamPlayer3D.new()
	_spur_player.volume_db = 2.0
	_spur_player.unit_size = 10.0
	_spur_player.max_distance = 120.0
	_spur_player.bus = _bus()
	_marshal.add_child(_spur_player)
	_marshal.visible = false


func _marshal_alpha(a: float) -> void:
	for m in _marshal_mats:
		var sm := m as StandardMaterial3D
		sm.albedo_color.a = a * 0.55
		sm.emission_energy_multiplier = 0.6 * a


# ---------------------------------------------------------------------------- sounds

func _bus() -> StringName:
	return &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"


func _sfx(file: String, loop: bool) -> AudioStream:
	var ss = map.get("_ss") if map != null else null
	if is_instance_valid(ss) and ss.has_method("_stream"):
		var st = ss.call("_stream", file, loop)
		if st is AudioStream:
			return st
	var full := DIR + "sfx/" + file
	if not FileAccess.file_exists(full):
		_warn("sfx " + file, "missing sound " + full)
		return null
	var ogg := AudioStreamOggVorbis.load_from_buffer(FileAccess.get_file_as_bytes(full))
	if ogg != null:
		ogg.loop = loop
	return ogg


func _build_sounds() -> void:
	# the saloon's piano, out of tune, behind its doors
	for b in T.get("buildings", []):
		if b is Dictionary and str(b.get("kind", "")) == "saloon":
			_piano = AudioStreamPlayer3D.new()
			_piano.stream = _sfx(SFX_PIANO, true)
			_piano.volume_db = -6.0
			_piano.unit_size = 5.0
			_piano.max_distance = 70.0
			_piano.bus = _bus()
			root.add_child(_piano)
			var p := _v3(b.get("pos", [0, 0, 0]))
			_piano.global_position = p + Vector3(0, 1.5, 0)
			break


# ============================================================================ the town's ground

func bed_y(p: Vector3) -> float:
	# the lake bed under p: the shore height out past 85% of the radius, DISH lower in the middle
	var d := Vector2(p.x - _c.x, p.z - _c.z).length()
	var x := clampf((d / maxf(_radius, 1.0) - 0.62) / 0.23, 0.0, 1.0)
	var k := x * x * (3.0 - 2.0 * x)
	return _shore - 0.15 - (_shore - _floor) * (1.0 - k)


func in_town(p: Vector3) -> bool:
	if not built:
		return false
	var d := Vector2(p.x - _c.x, p.z - _c.z).length()
	if d > _radius:
		return false
	var by := bed_y(p)
	return p.y > by - 3.0 and p.y < by + 14.0


func surface_at(p: Vector3) -> String:
	# what a player at p (feet or body origin) stands on
	if not in_town(p):
		return "off"
	var best := ""
	var best_dy := 1e9
	for r in _rects:
		var q: Vector3 = p - (r["c"] as Vector3)
		var lx: float = absf(q.dot(r["x"]))
		var lz: float = absf(q.dot(r["z"]))
		if lx > float(r["hx"]) + 0.3 or lz > float(r["hz"]) + 0.3:
			continue
		var dy: float = p.y - float(r["top"])
		if dy < -0.6 or dy > 2.4:
			continue
		if dy < best_dy:
			best_dy = dy
			best = str(r["kind"])
	if best != "":
		return best
	return "sand" if p.y < bed_y(p) + 2.6 else "off"


func street_s(p: Vector3) -> float:
	return (p - _c).dot(_u)


func street_t(p: Vector3) -> float:
	return (p - _c).dot(_v)


# ============================================================================ per frame

func _process(delta: float) -> void:
	if not built:
		return
	var now := Time.get_ticks_msec()
	# the porch lamps gutter
	for e in _lamps:
		var l: OmniLight3D = e[0]
		if is_instance_valid(l):
			var ph: float = float(e[2]) + float(now) * 0.001
			var f := 0.82 + 0.12 * sin(ph * 7.3) + 0.06 * sin(ph * 19.1)
			if fmod(ph, 9.0) < 0.12:
				f *= 0.3                                   # a dropout now and then
			l.light_energy = float(e[1]) * f
	if is_instance_valid(_gallows_body):
		_gallows_body.rotation.z = sin(float(now) * 0.0007) * 0.05
		_gallows_body.rotation.y += delta * 0.05
	_update_duel(delta)


# ============================================================================ THE NOON DUEL

func _players() -> Array:
	var out: Array = []
	if CoopSync.has_method("alive_player_nodes"):
		for p in CoopSync.call("alive_player_nodes"):
			if is_instance_valid(p) and (p as Node3D).is_inside_tree():
				out.append(p)
	else:
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree():
			out.append(c)
	return out


func _update_duel(delta: float) -> void:
	var auth: bool = CoopSync.map_is_authority()
	_run_t += delta
	if auth:
		var anyone := false
		var on_plaza := false
		for p in _players():
			var q: Vector3 = (p as Node3D).global_position
			if in_town(q):
				anyone = true
				if Vector2(q.x - _c.x, q.z - _c.z).length() < PLAZA_R:
					on_plaza = true
		if _duel_t < 0.0:
			if on_plaza and not _plaza_seen:
				_plaza_seen = true
				_start_duel()
			elif _next_duel > 0.0 and _run_t >= _next_duel:
				if anyone:
					_start_duel()
				else:
					_next_duel = -1.0
					_plaza_seen = false          # gone: the next one to step on the plaza starts it again
	if _duel_t < 0.0:
		return
	_duel_t += delta
	var toll := int(floor(_duel_t / TOLL_EVERY)) + 1
	if toll > _duel_tolls and toll <= TOLLS:
		_duel_tolls = toll
		_toll(toll)
	# the marshal fades in from the sixth toll, the gun comes up through the last two
	var since := _duel_t - float(MARSHAL_FROM - 1) * TOLL_EVERY
	var draw_t := float(TOLLS - 1) * TOLL_EVERY
	if is_instance_valid(_marshal):
		if since > 0.0 and not _duel_drawn:
			_marshal.visible = true
			_marshal_alpha(clampf(since / 4.0, 0.0, 1.0))
			var gun := _marshal.get_node_or_null("Gun") as Node3D
			if gun != null:
				gun.rotation.x = lerpf(-1.2, 0.0, clampf((_duel_t - draw_t + 3.0) / 3.0, 0.0, 1.0))
			if int(since * 2.0) != int((since - delta) * 2.0) and since < 10.0 and is_instance_valid(_spur_player):
				_spur_player.stream = _sfx(SFX_SPURS[randi() % SFX_SPURS.size()], false)
				_spur_player.play()
	if not _duel_drawn and _duel_t >= draw_t:
		_duel_drawn = true
		_draw()
	if _duel_drawn:
		var after := _duel_t - draw_t
		if is_instance_valid(_muzzle):
			_muzzle.light_energy = maxf(0.0, 3.0 * (1.0 - after / 0.12))
		if is_instance_valid(_marshal):
			_marshal_alpha(clampf(1.0 - (after - 0.6) / 2.5, 0.0, 1.0))
			if after > 3.2:
				_marshal.visible = false
		if after > 3.5:
			_duel_t = -1.0
			if auth:
				_next_duel = _run_t + DUEL_EVERY
	if is_instance_valid(_clock_glow):
		var tl := fmod(_duel_t, TOLL_EVERY) if _duel_t >= 0.0 else 9.0
		_clock_glow.light_energy = 0.25 + 1.4 * exp(-tl * 2.5) * (float(_duel_tolls) / TOLLS)


func _start_duel() -> void:
	duel_n += 1
	print("%s the clock strikes twelve (duel_%d)" % [TAG, duel_n])
	CoopSync.map_event("duel_%d" % duel_n, {"n": duel_n}, false)


func _on_duel_event(key: String, data: Dictionary, replay: bool) -> void:
	if replay:
		return
	var n := int(data.get("n", key.substr(5).to_int()))
	duel_n = maxi(duel_n, n)
	_duel_t = 0.0
	_duel_tolls = 0
	_duel_drawn = false
	if is_instance_valid(_marshal):
		_marshal.visible = false
	if not _hint_shown and map != null and map.has_method("hint_once"):
		_hint_shown = true
		map.call("hint_once", "noon_duel", "The town clock is striking twelve. On the last stroke something at the end of the street draws. Get behind something solid.", 7.0)


func _toll(k: int) -> void:
	if is_instance_valid(_toll_player) and _toll_player.stream != null and _toll_player.is_inside_tree():
		_toll_player.pitch_scale = 1.0 - 0.012 * k
		_toll_player.play()
	if is_instance_valid(_bell_node):
		var tw := create_tween()
		tw.tween_property(_bell_node, "rotation:x", 0.35 if k % 2 == 0 else -0.35, 0.3)
		tw.tween_property(_bell_node, "rotation:x", 0.0, 1.4)
	if k == 1 or k == TOLLS:
		print("%s toll %d" % [TAG, k])


func _gun_pos() -> Vector3:
	if is_instance_valid(_marshal):
		return _marshal.global_position + Vector3(0, 1.45, 0) + (-_u) * 0.5
	return _c


func _draw() -> void:
	if is_instance_valid(_shot_player) and _shot_player.stream != null and _shot_player.is_inside_tree():
		_shot_player.play()
	print("%s the marshal draws (duel_%d)" % [TAG, duel_n])
	if not CoopSync.map_is_authority():
		return
	var gp := _gun_pos()
	var space := (root as Node3D).get_world_3d().direct_space_state if is_instance_valid(root) else null
	for p in _players():
		var pn := p as Node3D
		var chest: Vector3 = pn.global_position + Vector3(0, 0.9, 0)
		var name_s := str(pn.get("player_name")) if pn != Game.climber else CoopSync.local_name
		if not in_town(pn.global_position):
			cover_log.append([duel_n, name_s, "far"])
			continue
		var to := chest - gp
		var dist := to.length()
		if dist > DRAW_RANGE:
			cover_log.append([duel_n, name_s, "far"])
			continue
		if (to / maxf(dist, 0.01)).dot(-_u) < DRAW_CONE:
			cover_log.append([duel_n, name_s, "cone"])
			continue
		if _blocked(space, gp, chest):
			cover_log.append([duel_n, name_s, "cover"])
			print("%s %s is behind cover" % [TAG, name_s])
			continue
		hits_log.append([duel_n, name_s, DRAW_DMG])
		print("%s the marshal hits %s (%.0f m)" % [TAG, name_s, dist])
		bit.emit(pn, DRAW_DMG, "duel%d" % duel_n)


func _blocked(space, a: Vector3, b: Vector3) -> bool:
	if space == null:
		return false
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	return not (space as PhysicsDirectSpaceState3D).intersect_ray(q).is_empty()


# the map's bite plumbing (register_bites "duel")
func bite_origin(_id: String) -> Vector3:
	return _gun_pos()


func play_bite(_id: String) -> void:
	pass                                          # every PC already plays the shot on its own timeline


func bite_opts(_id: String) -> Dictionary:
	return {"heavy": true, "push": DRAW_PUSH}


func threat_positions() -> Array:
	# the heartbeat quickens while the clock strikes
	if _duel_t >= 0.0 and not _duel_drawn and is_instance_valid(_marshal) and _marshal.visible:
		return [_marshal.global_position]
	return []


func hud_line() -> String:
	# v5.1: the ear: how loud your voice is to the things that hunt by sound (only while you make some)
	var t := int(CoopSync.get("noise_tier")) if CoopSync.get("noise_tier") != null else 0
	if t <= 0:
		return ""
	return ["", "(( your voice: a whisper ))", "(( your voice: talking ))", "(( your voice: SHOUTING ))"][clampi(t, 0, 3)]


func duel_state() -> Dictionary:
	return {"n": duel_n, "toll": _duel_tolls, "drawn": _duel_drawn, "t": _duel_t}


func on_session_ended() -> void:
	_was_auth = CoopSync.map_is_authority()


func on_exit() -> void:
	built = false


# ============================================================================ dev test

func _setup_test() -> void:
	var flag = null
	if map != null and map.has_method("dev_flag"):
		flag = map.call("dev_flag", "town.flag")
	if flag == null:
		return
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	var t := TownTest.new()
	t.name = "TownTest"
	t.tm = self
	t.map = map
	t.variant = str(flag).strip_edges().to_lower()
	print("%s test on: variant '%s'" % [TAG, t.variant])
	add_child(t)


class TownTest extends Node:
	var tm = null
	var map = null
	var variant := ""
	var t := 0.0
	var phase := 0
	var n_pass := 0
	var n_total := 0
	var fails: Array = []
	var mark := -1.0
	var hp0 := 0.0
	var shots: Array = []

	func ok(key: String, cond: bool, text: String) -> void:
		n_total += 1
		if cond:
			n_pass += 1
			print("%s PASS %s" % [TAG, text])
		else:
			fails.append(key)
			print("%s FAIL %s" % [TAG, text])

	func park(p: Vector3, look: Vector3) -> void:
		if map.has_method("debug_park"):
			map.call("debug_park", p)
		if map.has_method("debug_look"):
			map.call("debug_look", look)

	func shot(name: String) -> void:
		if map.has_method("debug_shot"):
			map.call("debug_shot", "user://underdark_town_%s.png" % name)

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		t += delta
		if phase < 0:
			return
		c.prevent_player_death = true
		match phase:
			0:
				if t < 3.0:
					return
				ok("built", tm.built and tm._rects.size() > 20, "town built: %d surfaces, %d lamps" % [tm._rects.size(), tm._lamps.size()])
				# stand at the gallows end, look down the street
				var p0: Vector3 = tm._c - tm._u * (tm._half_len - 4.0)
				park(Vector3(p0.x, tm.bed_y(p0) + 1.2, p0.z), tm._c + Vector3(0, 6, 0))
				mark = t
				phase = 1
			1:
				if t - mark < 2.5:
					return
				shot("street")
				var sp: Vector3 = c.global_position
				ok("sand", tm.surface_at(sp) == "sand", "surface at the street's end: %s" % tm.surface_at(sp))
				# the surfaces: a boardwalk, inside the saloon, a roof
				var wk: Dictionary = (tm.T.get("boardwalks", []) as Array)[0]
				var wm: Vector3 = (tm._v3(wk["a"]) + tm._v3(wk["b"])) * 0.5
				park(Vector3(wm.x, tm.bed_y(wm) + float(wk.get("h", 0.55)) + 1.0, wm.z), wm + tm._u * 10.0)
				mark = t
				phase = 2
			2:
				if t - mark < 2.0:
					return
				var s2: String = tm.surface_at(c.global_position)
				ok("planks", s2 == "planks", "surface on a boardwalk: %s (y %.2f)" % [s2, c.global_position.y])
				var sal: Dictionary = {}
				for b in tm.T.get("buildings", []):
					if str(b.get("kind", "")) == "saloon":
						sal = b
				if not sal.is_empty():
					var bp: Vector3 = tm._v3(sal["pos"])
					park(Vector3(bp.x, tm.bed_y(bp) + tm._walk_h + 1.0, bp.z), bp + Vector3(0, 1.5, 0) + tm._u * 4.0)
				mark = t
				phase = 3
			3:
				if t - mark < 2.0:
					return
				var s3: String = tm.surface_at(c.global_position)
				ok("inside", s3 == "inside", "surface inside the saloon: %s (y %.2f)" % [s3, c.global_position.y])
				shot("saloon")
				# the duel: stand in the open street 60 m from the marshal, walk onto the plaza first
				park(Vector3(tm._c.x, tm.bed_y(tm._c) + 1.0, tm._c.z), tm._c + tm._u * 50.0)
				mark = t
				hp0 = float(c.health)
				phase = 4
			4:
				if tm.duel_n >= 1 and t - mark > 1.0:
					ok("strike", true, "the clock started striking when the plaza was reached (%.1f s)" % (t - mark))
					var open_p: Vector3 = _clear_spot()
					park(open_p, tm._v3(tm.T["marshal"]))
					mark = t
					phase = 5
				elif t - mark > 6.0:
					ok("strike", false, "no strike 6 s after reaching the plaza")
					_finish()
			5:
				if tm._duel_tolls >= 7 and not shots.has("marshal"):
					shots.append("marshal")
					shot("marshal")
				if tm._duel_drawn:
					var hit := false
					for e in tm.hits_log:
						if int(e[0]) == tm.duel_n:
							hit = true
					ok("hit open", hit, "standing in the open street the marshal hit me (tolls %d)" % tm._duel_tolls)
					mark = t
					phase = 6
				elif t - mark > 30.0:
					ok("hit open", false, "no draw in 30 s (tolls %d)" % tm._duel_tolls)
					_finish()
			6:
				# the next strike: stand behind a box (a wagon-sized crate of our own) between me and him
				if t - mark < 4.0:
					return
				tm._next_duel = tm._run_t + 1.0
				var cov: Vector3 = tm._c + tm._u * 30.0
				var fy: float = tm.bed_y(cov)
				map.call("add_box_body", Vector3(cov.x, fy + 1.2, cov.z) + tm._u * 2.0, Vector3(3.0, 2.4, 1.0), atan2(tm._u.x, tm._u.z))
				park(Vector3(cov.x, fy + 1.0, cov.z), tm._v3(tm.T["marshal"]))
				mark = t
				phase = 7
			7:
				if tm.duel_n >= 2 and tm._duel_drawn:
					var hit2 := false
					var cover := false
					for e in tm.hits_log:
						if int(e[0]) == tm.duel_n:
							hit2 = true
					for e2 in tm.cover_log:
						if int(e2[0]) == tm.duel_n and str(e2[2]) == "cover":
							cover = true
					ok("cover", cover and not hit2, "behind cover the marshal missed (cover %s, hit %s)" % [str(cover), str(hit2)])
					_finish()
				elif t - mark > 40.0:
					ok("cover", false, "no second strike in 40 s (duel %d)" % tm.duel_n)
					_finish()

	func _clear_spot() -> Vector3:
		# a spot on the street the marshal's gun sees (nothing between): the open-street check
		var space = Game.climber.get_world_3d().direct_space_state
		var gp: Vector3 = tm._gun_pos()
		for s_ in [40.0, 30.0, 50.0, 20.0, 60.0, 70.0]:
			for t_ in [0.0, 2.0, -2.0, 4.0, -4.0, 6.0, -6.0]:
				var q: Vector3 = tm._c + tm._u * s_ + tm._v * t_
				q.y = tm.bed_y(q) + 1.0
				if not tm._blocked(space, gp, q + Vector3(0, 0.9, 0)) and not tm._blocked(space, gp, q + Vector3(0, 0.2, 0)):
					print("%s open spot s=%.0f t=%.0f" % [TAG, s_, t_])
					return q
		var q0: Vector3 = tm._c + tm._u * 40.0
		q0.y = tm.bed_y(q0) + 1.0
		return q0

	func _finish() -> void:
		phase = -1
		var c = Game.climber
		if is_instance_valid(c):
			c.prevent_player_death = false
		if fails.is_empty():
			print("%s test done %d/%d PASS" % [TAG, n_pass, n_total])
		else:
			print("%s test done %d/%d FAIL: %s" % [TAG, n_pass, n_total, ", ".join(PackedStringArray(fails))])
