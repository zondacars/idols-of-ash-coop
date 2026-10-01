extends Node

# ============================================================================================
# THE SQUEEZES (ZondaCoopSync 5.1, feature module "squeezes"). Owner plan 2026-09-30: "a squeeze
# at each big biome change", "different flavor for sure". The generator writes L["squeezes"]:
# every one is a rift-wide part boundary (underdark.gd 7A: the big ones stay behind), with its
# centre line ("path"), its mouth and its exit, and its flavour. This module dresses each one and
# plays the moment the team gets through: the Follower they left behind comes to the hole, claws
# and snarls and bites at it for a few seconds, and gives up.
#   the Throat (chimney)   a crack that drops most of the way, an old rope down it, a cold draught
#   the Root Knot (roots)  the Kiln Gate's passage, grown through with roots
#   the Culvert (pipe)     a round stone pipe, half full of black water, dripping
#   the Spillway           the drain the lake left by: a trickle down its floor
#   the Adit (mine)        timber frames, rails, a cart, two lamps nobody refills
#   the Crypt Gap (crawl)  coffins in the walls, the dead underfoot (bones from the generator)
#   the Vent (chimney)     hot breath in slow sighs, steam, a red glow from below
# THE REACH (authority): _nc_part_release calls on_part_change(old_follower, old_part, new_part).
#   The left-behind Follower is pinned to a decoy at the squeeze's mouth (CoopSync.hunt_pins, meta
#   "zonda_pin_decoy": it never lunges at it) for REACH_S; within 14 m of the mouth it snarls,
#   teeth and chomps at the hole (non-persistent "reach_<k>_<n>" events: every PC plays them).
# DEV TEST: squeezes.flag. Tag [SQUEEZE], "[SQUEEZE] test done N/N PASS".
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const TAG := "[SQUEEZE]"
const REACH_S := 10.0
const REACH_NEAR := 14.0
const SNARLS := ["res://sfx/soundsnap/monster_attack/306010-Creature-Oxbow-Snarls-Breaths-Aggressive_1.wav",
		"res://sfx/soundsnap/monster_attack/306013-Creature-Oxbow-Snarls-Breaths-Aggressive_4.wav"]
const TEETH := ["res://sfx/MonsterIdeas/Teeth_01.wav", "res://sfx/MonsterIdeas/Teeth_02.wav",
		"res://sfx/MonsterIdeas/Teeth_03.wav", "res://sfx/MonsterIdeas/Teeth_04.wav"]
const CHOMP := ["res://sfx/MonsterIdeas/Chomp_01.wav", "res://sfx/MonsterIdeas/Chomp_02.wav"]
const BEDS := {"chimney": "bed_burrows_draft.ogg", "roots": "bed_rootworks_creak.ogg", "pipe": "bed_drowned_drips.ogg",
		"spillway": "bed_drowned_trickle.ogg", "mine": "bed_rootworks_creak.ogg", "crawl": "bed_burrows_breath.ogg"}

var map: Node = null
var list: Array = []                  # the layout's squeezes
var _root: Node3D = null
var _mats: Dictionary = {}
var _steam: Array = []                # [CPUParticles3D, AudioStreamPlayer3D, timer]
var _reach: Dictionary = {}           # k -> {"fol", "decoy", "until_ms", "pos", "n", "next"}
var _warned: Dictionary = {}
var reach_log: Array = []             # tests: [ms, part, name, "start"/"sound"/"end"]
var dressed := 0
var _pending: Array = []              # squeezes not dressed yet (their rock gets collision only near a player)
var _pend_t := 0.0


func setup(m: Node) -> void:
	map = m
	var L = m.get("L")
	if L is Dictionary and (L as Dictionary).get("squeezes") is Array:
		list = (L as Dictionary)["squeezes"]
	if list.is_empty():
		print("[Underdark] squeezes: none in this layout")
		return
	_root = Node3D.new()
	_root.name = "Squeezes"
	_root.top_level = true
	m.add_child(_root)
	_build_materials()
	if map.has_method("register_events"):
		map.call("register_events", ["reach_"], _on_reach_event, true)
	print("[Underdark] squeezes: %d (%s)" % [list.size(), ", ".join(PackedStringArray(list.map(func(e): return str(e.get("name", "?")))))])
	call_deferred("_dress_all")
	_setup_test()


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


func _build_materials() -> void:
	var water := StandardMaterial3D.new()
	water.albedo_color = Color(0.01, 0.012, 0.014, 0.92)
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.roughness = 0.08
	water.metallic_specular = 0.9
	_mats["water"] = water
	var wood := StandardMaterial3D.new()
	# old wet timber: dark, so a lantern an arm's length away does not burn it white (tour shot, the Adit)
	wood.albedo_color = Color(0.07, 0.055, 0.04)
	wood.roughness = 1.0
	wood.metallic_specular = 0.08
	_mats["wood"] = wood
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.1, 0.09, 0.085)
	iron.metallic = 0.6
	iron.roughness = 0.5
	_mats["iron"] = iron
	var coffin := StandardMaterial3D.new()
	coffin.albedo_color = Color(0.06, 0.045, 0.035)
	coffin.roughness = 1.0
	coffin.metallic_specular = 0.08
	_mats["coffin"] = coffin
	var rope := StandardMaterial3D.new()
	rope.albedo_color = Color(0.3, 0.25, 0.18)
	_mats["rope"] = rope


# ============================================================================ dressing

func _space():
	if map != null and map is Node3D and (map as Node3D).is_inside_tree():
		return (map as Node3D).get_world_3d().direct_space_state
	return null


func _floor_at(p: Vector3, down := 6.0):
	var space = _space()
	if space == null:
		return null
	var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.3, 0), p + Vector3(0, -down, 0), 1))
	return null if hit.is_empty() else hit["position"]


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: String, look: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mats.get(mat)
	parent.add_child(mi)
	mi.global_position = pos
	if look.length() > 0.01:
		var up := Vector3.UP if absf(look.normalized().y) < 0.95 else Vector3.RIGHT
		mi.look_at(pos + look, up)
	return mi


func _dress_all() -> void:
	# a squeeze is dressed when a player first comes within 120 m of it: the map gives rock its
	# collision only near a player, and the dressing stands on that rock
	for e in list:
		if e is Dictionary:
			_pending.append(e)


func _dress_near(delta: float) -> void:
	if _pending.is_empty():
		return
	_pend_t -= delta
	if _pend_t > 0.0:
		return
	_pend_t = 1.0
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var p: Vector3 = c.global_position
	for e in _pending.duplicate():
		var mouth := _v3(e.get("mouth", e.get("pos", [0, 0, 0])))
		var ex := _v3(e.get("exit", e.get("pos", [0, 0, 0])))
		if p.distance_to(mouth) < 120.0 or p.distance_to(ex) < 120.0:
			_pending.erase(e)
			_dress(e)
			print("%s dressed %s" % [TAG, str(e.get("name", "?"))])


func _dress(e: Dictionary) -> void:
	var path: Array = []
	for p in e.get("path", []):
		path.append(_v3(p))
	if path.size() < 2:
		return
	var flavor := str(e.get("flavor", ""))
	var node := Node3D.new()
	node.name = str(e.get("name", "squeeze"))
	_root.add_child(node)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(node.name)
	# a sound bed at the mouth that tells you what is down there
	var bed := str(BEDS.get(flavor, ""))
	if bed != "":
		var ap := AudioStreamPlayer3D.new()
		ap.stream = _sfx(bed, true)
		ap.volume_db = -4.0
		ap.unit_size = 4.0
		ap.max_distance = 30.0
		ap.bus = &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
		node.add_child(ap)
		ap.global_position = _v3(e.get("mouth", path[0])) + Vector3(0, 1.0, 0)
		if ap.stream != null:
			ap.play()
	var segs := path.size() - 1
	for i in segs:
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		var d := b - a
		var ln := d.length()
		if ln < 0.3:
			continue
		var dir := d / ln
		var steep := absf(dir.y) > 0.6
		var mid := (a + b) * 0.5
		match flavor:
			"pipe", "spillway":
				if steep:
					continue
				var fa = _floor_at(a + Vector3(0, 1.0, 0))
				var fb = _floor_at(b + Vector3(0, 1.0, 0))
				if fa == null or fb == null:
					continue
				var depth := 0.32 if flavor == "pipe" else 0.06
				var wmid: Vector3 = ((fa as Vector3) + (fb as Vector3)) * 0.5 + Vector3(0, depth, 0)
				var wd: Vector3 = (fb as Vector3) - (fa as Vector3)
				_box(node, wmid, Vector3(2.0 if flavor == "pipe" else 0.9, 0.02, wd.length() + 0.4), "water", wd)
			"mine":
				var k := 1.5
				while k < ln - 1.0:
					var q := a + dir * k
					var f = _floor_at(q + Vector3(0, 1.0, 0))
					if f != null:
						var side := Vector3(-dir.z, 0, dir.x).normalized()
						var fp: Vector3 = f
						for sx in [-1.0, 1.0]:
							_box(node, fp + side * sx * 1.9 + Vector3(0, 1.4, 0), Vector3(0.25, 2.8, 0.25), "wood")
						_box(node, fp + Vector3(0, 2.85, 0), Vector3(0.28, 0.28, 4.2), "wood", side)
						for sx2 in [-0.55, 0.55]:
							_box(node, fp + side * sx2 + Vector3(0, 0.05, 0), Vector3(0.08, 0.08, 4.5), "iron", dir)
						if rng.randf() < 0.2:
							_box(node, fp + Vector3(0, 0.4, 0) + dir * 0.5, Vector3(0.18, 0.06, 2.6), "wood", side)
					k += 4.5
				if i == segs / 2:
					var cf = _floor_at(mid + Vector3(0, 1.0, 0))
					if cf != null:
						_box(node, (cf as Vector3) + Vector3(0, 0.55, 0), Vector3(1.2, 0.9, 1.8), "iron", dir)
						if map != null and map.has_method("add_light"):
							map.call("add_light", (cf as Vector3) + Vector3(0, 2.4, 0), Color(1.0, 0.6, 0.3), 0.3, 8.0)
			"crawl":
				var k2 := 1.0
				while k2 < ln - 0.5:
					var q2 := a + dir * k2
					var side2 := Vector3(-dir.z, 0, dir.x).normalized()
					var sx3 := 1.0 if rng.randf() < 0.5 else -1.0
					var r := float(e.get("radius", 1.35))
					_box(node, q2 + side2 * sx3 * (r + 0.2) + Vector3(0, -0.2, 0), Vector3(0.7, 0.5, 2.0), "coffin", dir.rotated(Vector3.UP, rng.randf_range(-0.3, 0.3)))
					k2 += rng.randf_range(2.6, 4.0)
			"chimney":
				if steep and flavor == "chimney":
					var rp := MeshInstance3D.new()
					var cm := CylinderMesh.new()
					cm.top_radius = 0.035
					cm.bottom_radius = 0.035
					cm.height = ln + 1.0
					rp.mesh = cm
					rp.material_override = _mats["rope"]
					node.add_child(rp)
					rp.global_position = mid + Vector3(0.4, 0, 0.3)
			"roots":
				var k3 := 3.0
				while k3 < ln - 2.0:
					var q3 := a + dir * k3
					var th := rng.randf_range(0.4, 2.7)
					var side3 := Vector3(-dir.z, 0, dir.x).normalized()
					var dw := side3 * cos(th) + Vector3.UP * sin(th)
					var space = _space()
					if space != null and map.has_method("ext_instance"):
						var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(q3, q3 + dw * 9.0, 1))
						if not hit.is_empty():
							var root_n = map.call("ext_instance", "ext/ph/single_root.glb", 0.4)
							if root_n is Node3D:
								node.add_child(root_n)
								(root_n as Node3D).global_position = hit["position"] - dw * 0.3
								(root_n as Node3D).rotation = Vector3(rng.randf_range(-0.6, 0.6), rng.randf() * TAU, rng.randf_range(-0.6, 0.6))
								(root_n as Node3D).scale = Vector3.ONE * rng.randf_range(1.2, 2.0)
					k3 += rng.randf_range(4.0, 7.0)
	if str(e.get("name", "")) == "the Vent":
		_dress_vent(node, path)
	dressed += 1


func _dress_vent(node: Node3D, path: Array) -> void:
	# hot breath: steam that rises up the chimney in slow sighs, a red glow from below
	var low: Vector3 = path[path.size() - 1]
	for i in [1, path.size() / 2]:
		var p: Vector3 = path[clampi(i, 0, path.size() - 1)]
		var ps := CPUParticles3D.new()
		ps.amount = 26
		ps.lifetime = 3.0
		ps.emitting = false
		ps.one_shot = false
		ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		ps.emission_sphere_radius = 0.8
		ps.direction = Vector3.UP
		ps.spread = 25.0
		ps.initial_velocity_min = 0.8
		ps.initial_velocity_max = 1.8
		ps.gravity = Vector3(0, 0.3, 0)
		ps.scale_amount_min = 0.6
		ps.scale_amount_max = 1.6
		var q := QuadMesh.new()
		q.size = Vector2(1.0, 1.0)
		var sm := StandardMaterial3D.new()
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.albedo_color = Color(0.55, 0.5, 0.48, 0.16)
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var dot = map.call("soft_dot") if map != null and map.has_method("soft_dot") else null
		if dot is Texture2D:
			sm.albedo_texture = dot
		q.material = sm
		ps.mesh = q
		node.add_child(ps)
		ps.global_position = p
		var hiss := AudioStreamPlayer3D.new()
		hiss.stream = _sfx("fire_hiss_579098_1.ogg", false)
		hiss.volume_db = -2.0
		hiss.unit_size = 4.0
		hiss.max_distance = 30.0
		node.add_child(hiss)
		hiss.global_position = p
		_steam.append([ps, hiss, randf_range(2.0, 6.0)])
	if map != null and map.has_method("add_light"):
		map.call("add_light", low + Vector3(0, -0.5, 0), Color(1.0, 0.35, 0.1), 0.6, 10.0)


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


func _process(delta: float) -> void:
	_dress_near(delta)
	for s in _steam:
		s[2] = float(s[2]) - delta
		if float(s[2]) <= 0.0:
			# a sigh: steam for 2.5 s, then quiet for 4-8 s
			var ps: CPUParticles3D = s[0]
			if is_instance_valid(ps):
				ps.emitting = not ps.emitting
				if ps.emitting:
					var h: AudioStreamPlayer3D = s[1]
					if is_instance_valid(h) and h.stream != null and h.is_inside_tree():
						h.play()
				s[2] = 2.5 if ps.emitting else randf_range(4.0, 8.0)
	_reach_tick()


# ============================================================================ THE REACH

func _boundary_entry(old_k: int, new_k: int) -> Dictionary:
	# the squeeze the team just came through: the one whose layer sits between the two parts
	if map == null or not map.has_method("part_band"):
		return {}
	var band_old: Array = map.call("part_band", old_k)
	var floor_old := float(band_old[1])
	var best: Dictionary = {}
	var bd := 1e9
	var sq: Array = map.call("squeezes") if map.has_method("squeezes") else []
	for e in sq:
		if not (e is Dictionary) or not bool(e.get("layer", false)):
			continue
		var d := absf(float(e.get("top", 0.0)) - floor_old)
		if d < bd:
			bd = d
			best = e
	if best.is_empty():
		return {}
	# the layout entry carries the mouth (the built-in Lid does not: the Burrow Mouth stands in)
	var mouth := Vector3.ZERO
	for e2 in list:
		if str(e2.get("name", "")) == str(best.get("name", "")):
			mouth = _v3(e2.get("mouth", e2.get("pos", [0, 0, 0])))
	if mouth == Vector3.ZERO:
		for e3 in sq:
			if str(e3.get("name", "")) == "the Burrow Mouth":
				mouth = e3["pos"]
	if mouth == Vector3.ZERO:
		mouth = best["pos"]
	return {"name": str(best.get("name", "")), "mouth": mouth}


func on_part_change(fol: Node3D, old_k: int, new_k: int) -> void:
	# authority: the team is through; the Follower it left behind comes to the hole
	if not CoopSync.map_is_authority() or not is_instance_valid(fol):
		return
	var e := _boundary_entry(old_k, new_k)
	if e.is_empty():
		return
	var decoy := Node3D.new()
	decoy.name = "ReachDecoy_%d" % new_k
	decoy.set_meta("zonda_pin_decoy", true)
	decoy.top_level = true
	add_child(decoy)
	var mpos: Vector3 = e["mouth"]
	var f = _floor_at(mpos + Vector3(0, 1.5, 0), 8.0)
	decoy.global_position = (f as Vector3) + Vector3(0, 0.8, 0) if f != null else mpos
	var key := "reach_%d" % new_k
	fol.set_meta("zonda_hunt_pin", key)
	var pins = CoopSync.get("hunt_pins")
	if pins is Dictionary:
		pins[key] = decoy
	_reach[new_k] = {"fol": fol, "decoy": decoy, "until_ms": Time.get_ticks_msec() + int(REACH_S * 1000.0) + 20000,
			"pos": decoy.global_position, "n": 0, "next": 0, "near_ms": -1, "name": e["name"], "key": key}
	reach_log.append([Time.get_ticks_msec(), new_k, e["name"], "start"])
	print("%s the Follower left in part %d goes to %s" % [TAG, old_k, e["name"]])


func _reach_tick() -> void:
	if _reach.is_empty() or not CoopSync.map_is_authority():
		return
	var now := Time.get_ticks_msec()
	for k in _reach.keys():
		var r: Dictionary = _reach[k]
		var fol = r["fol"]
		var gone := not is_instance_valid(fol) or now > int(r["until_ms"])
		if not gone:
			var d: float = (fol as Node3D).global_position.distance_to(r["pos"])
			if d <= REACH_NEAR:
				if int(r["near_ms"]) < 0:
					r["near_ms"] = now
					r["until_ms"] = now + int(REACH_S * 1000.0)
				if now >= int(r["next"]) and int(r["n"]) < 7:
					r["n"] = int(r["n"]) + 1
					r["next"] = now + randi_range(900, 1600)
					var kind: String = ["snarl", "teeth", "chomp"][int(r["n"]) % 3]
					CoopSync.map_event("reach_%d_%d" % [k, int(r["n"])], {"pos": [r["pos"].x, r["pos"].y, r["pos"].z], "fx": kind}, false)
		if gone:
			_end_reach(k)


func _end_reach(k) -> void:
	var r: Dictionary = _reach[k]
	var fol = r["fol"]
	if is_instance_valid(fol) and str(fol.get_meta("zonda_hunt_pin", "")) == str(r["key"]):
		fol.remove_meta("zonda_hunt_pin")
	var pins = CoopSync.get("hunt_pins")
	if pins is Dictionary:
		pins.erase(r["key"])
	if is_instance_valid(r["decoy"]):
		(r["decoy"] as Node).queue_free()
	reach_log.append([Time.get_ticks_msec(), k, r["name"], "end"])
	print("%s the Follower gives up at %s" % [TAG, r["name"]])
	_reach.erase(k)


func _on_reach_event(key: String, data: Dictionary, replay: bool) -> void:
	if replay:
		return
	var pos := _v3(data.get("pos", []))
	var fx := str(data.get("fx", "snarl"))
	var arr: Array = SNARLS if fx == "snarl" else (TEETH if fx == "teeth" else CHOMP)
	var p := AudioStreamPlayer3D.new()
	p.stream = load(arr[randi() % arr.size()])
	p.volume_db = 6.0 if fx == "snarl" else 3.0
	p.unit_size = 10.0
	p.max_distance = 90.0
	p.pitch_scale = randf_range(0.85, 1.0)
	p.bus = &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
	add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()
	reach_log.append([Time.get_ticks_msec(), -1, key, "sound " + fx])


func on_exit() -> void:
	for k in _reach.keys():
		_end_reach(k)


# ============================================================================ dev test

func _setup_test() -> void:
	var flag = null
	if map != null and map.has_method("dev_flag"):
		flag = map.call("dev_flag", "squeezes.flag")
	if flag == null:
		return
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	var t := SqTest.new()
	t.name = "SqTest"
	t.sq = self
	t.map = map
	print("%s test on" % TAG)
	add_child(t)


class SqTest extends Node:
	# walk every squeeze: park at its mouth, then at points along its centre line, then at its exit;
	# each must have floor under it and headroom; a screenshot of each one's middle
	var sq = null
	var map = null
	var t := 0.0
	var i := 0
	var step := 0
	var mark := 0.0
	var n_pass := 0
	var n_total := 0
	var fails: Array = []

	func ok(key: String, cond: bool, text: String) -> void:
		n_total += 1
		if cond:
			n_pass += 1
			print("%s PASS %s" % [TAG, text])
		else:
			fails.append(key)
			print("%s FAIL %s" % [TAG, text])

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree() or i < 0:
			return
		t += delta
		c.prevent_player_death = true
		if t < 4.0:
			return
		if i >= sq.list.size():
			ok("dressed", sq.dressed == sq.list.size(), "squeezes dressed %d of %d once visited" % [sq.dressed, sq.list.size()])
			_finish()
			return
		var e: Dictionary = sq.list[i]
		var path: Array = e.get("path", [])
		if t - mark < 1.2:
			return
		mark = t
		var pts: Array = []
		for p in path:
			pts.append(sq._v3(p))
		if step == 0:
			# go to a quarter of the way along (its rock gets collision near a player), then look
			var q0: Vector3 = pts[maxi(1, pts.size() / 4)]
			if map.has_method("debug_park"):
				map.call("debug_park", q0 + Vector3(0, 0.3, 0))
			step = 2
		elif step == 2:
			var q1: Vector3 = pts[maxi(1, pts.size() / 4)]
			var f = sq._floor_at(q1 + Vector3(0, 0.6, 0), 16.0)
			ok("floor " + str(e["name"]), f != null, "%s: floor under the passage (%s)" % [str(e["name"]), str(f)])
			if f != null and map.has_method("debug_park"):
				map.call("debug_park", (f as Vector3) + Vector3(0, 1.0, 0))
			if map.has_method("debug_look"):
				map.call("debug_look", pts[mini(pts.size() / 4 + 2, pts.size() - 1)])
			step = 1
		elif step == 1:
			if map.has_method("debug_shot"):
				map.call("debug_shot", "user://underdark_squeeze_%d.png" % i)
			step = 0
			i += 1

	func _finish() -> void:
		i = -1
		var c = Game.climber
		if is_instance_valid(c):
			c.prevent_player_death = false
		if fails.is_empty():
			print("%s test done %d/%d PASS" % [TAG, n_pass, n_total])
		else:
			print("%s test done %d/%d FAIL: %s" % [TAG, n_pass, n_total, ", ".join(PackedStringArray(fails))])
