extends Node

# ============================================================================================
# THE SPAN FALLS and THE CHANDELIER COMES DOWN (ZondaCoopSync 5.1, feature "setpieces";
# big-batch contract 3.7 / 3.8). The generator cut the falling pieces out of the cave and meshed
# them into setpieces.glb (setpieces.py); L["span"] and L["chandelier"] hold their timing.
#
# THE SPAN FALLS. The Ossuary bridge stands until nobody alive is left on the near side and a
#   living player has been 30 m or more out on the deck for 0.75 s. Then a crack behind you, and
#   the far end's last slab drops at once (an 11 m gap to hook across); from 2 s the slabs fall
#   behind you at 6.5 m/s, each shaking and grinding for 1.2 s first; the far half holds 3 s
#   longer. Walkers die, sprinters live. It stays fallen. The Miners' Pegs (always there) go
#   down the wall from the near side to the shelf below; the near sign says so after the fall.
# THE CHANDELIER COMES DOWN. Six seconds after the first player reaches the Fungal Hollow
#   landing, the spikes under the Lid crack, one about every 4 s, shortest first, flicker their
#   green lights and drop; a boom from the shelf far below. The biggest groans for 6 s and falls
#   last. None can reach the route (the generator keeps every fall 20 m clear of it).
# Sync: persistent "span_fall" / "chand_fall" {t0} (authority only, R4); every PC plays its own
#   timeline from the event; the host streams the elapsed time ("spf", "chf") and a guest only
#   ever jumps forward (0.4 s or more behind). A reload or a late join shows the end state.
# DEV TEST: setpieces.flag ("span" or "chand"). Tag [SET], "[SET] test done N/N PASS".
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const TAG := "[SET]"
const SHAKE_LEAD := 1.2
const TRIGGER_D := 30.0
const TRIGGER_HOLD := 0.75
const CHAND_VANISH_Y := -1450.0

var map: Node = null
var span: Dictionary = {}
var chand: Dictionary = {}
var _pieces: Dictionary = {}          # node name -> {"pivot": Node3D, "body": StaticBody3D, "y0": float}
var _span_t := -1.0                   # seconds into the collapse (-1: standing)
var _span_done := false
var _chand_t := -1.0
var _chand_done := false
var _hold_t := 0.0
var _chand_arm_t := -1.0
var _tick := 0.0
var _slab_state: Dictionary = {}      # name -> 0 standing, 1 shaking, 2 falling, 3 gone
var _cone_state: Dictionary = {}
var _shake := 0.0
var _shake_until := 0.0
var _clock := 0.0
var _warned: Dictionary = {}
var _b0a := Vector3.ZERO
var _b0t := Vector3.FORWARD
var _b0u := Vector3.RIGHT
var _b1b := Vector3.ZERO
var _b1t := Vector3.FORWARD
var _wreck: Array = []
var log_lines: Array = []             # tests: [ms, text]
var loaded := false


func setup(m: Node) -> void:
	map = m
	var L = m.get("L")
	if L is Dictionary:
		span = (L as Dictionary).get("span", {}) if (L as Dictionary).get("span") is Dictionary else {}
		chand = (L as Dictionary).get("chandelier", {}) if (L as Dictionary).get("chandelier") is Dictionary else {}
	if span.is_empty() and chand.is_empty():
		print("[Underdark] setpieces: none in this layout")
		return
	_load_pieces()
	if not span.is_empty():
		var b0: Array = span.get("b0", [])
		var b1: Array = span.get("b1", [])
		if b0.size() == 2 and b1.size() == 2:
			_b0a = _v3(b0[0])
			_b0t = (_v3(b0[1]) - _b0a).normalized()
			_b0u = Vector3.UP.cross(_b0t).normalized()
			_b1b = _v3(b1[1])
			_b1t = (_v3(b1[1]) - _v3(b1[0])).normalized()
	if map.has_method("register_events"):
		map.call("register_events", ["span_fall", "chand_fall"], _on_event, false)
	if map.has_method("register_stream"):
		map.call("register_stream", "spf", _send_spf, _recv_spf)
		map.call("register_stream", "chf", _send_chf, _recv_chf)
	call_deferred("_adopt_children")
	print("[Underdark] setpieces: the span %d slabs, the chandelier %d spikes (%d pieces loaded)" % [
			(span.get("slabs", []) as Array).size(), (chand.get("cones", []) as Array).size(), _pieces.size()])
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


# ============================================================================ the pieces

func _load_pieces() -> void:
	var path := DIR + "setpieces.glb"
	if not FileAccess.file_exists(path):
		_warn("glb", "setpieces.glb missing: the bridge and the spikes stay up")
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_buffer(FileAccess.get_file_as_bytes(path), "", state) != OK:
		_warn("glb read", "setpieces.glb unreadable")
		return
	var scene: Node = doc.generate_scene(state)
	if scene == null:
		return
	var walls = map.get("_wall_mat")
	var floors = map.get("_floor_mat")
	var centers: Dictionary = {}
	for s in span.get("slabs", []):
		centers[str(s["node"])] = _v3(s["c"])
	for c in chand.get("cones", []):
		if bool(c.get("falls", false)):
			centers[str(c["node"])] = _v3(c["base"])
	var found: Array = scene.find_children("*", "MeshInstance3D", true, false)
	for imi in scene.find_children("*", "ImporterMeshInstance3D", true, false):
		var im: ImporterMesh = imi.mesh
		if im != null:
			var conv := MeshInstance3D.new()
			conv.mesh = im.get_mesh()
			conv.name = imi.name
			found.append(conv)
	for mi in found:
		var m: MeshInstance3D = mi
		var nm := str(m.name)
		var key := ""
		for k in centers.keys():
			if nm.begins_with(str(k)):
				key = str(k)
		if key == "" or m.mesh == null:
			continue
		var pivot := Node3D.new()
		pivot.name = "Piece_" + key
		pivot.top_level = true
		add_child(pivot)
		pivot.global_position = centers[key]
		if m.get_parent():
			m.get_parent().remove_child(m)
		pivot.add_child(m)
		m.position = -centers[key]
		for si in m.mesh.get_surface_count():
			var mat: Material = m.mesh.surface_get_material(si)
			var mn: String = mat.resource_name if mat else ""
			if mn.begins_with("B") and walls is Array and floors is Array:
				var parts := mn.substr(1).split("_")
				var b := clampi(int(parts[0]), 0, (walls as Array).size() - 1)
				var fl := parts.size() > 1 and parts[1] == "F"
				m.set_surface_override_material(si, floors[b] if fl else walls[b])
		var body: StaticBody3D = null
		if key.begins_with("sp"):
			var tri: ConcavePolygonShape3D = m.mesh.create_trimesh_shape()
			if tri != null:
				tri.backface_collision = true
				body = StaticBody3D.new()
				body.collision_layer = 1
				if ResourceLoader.exists("res://physics_materials/stone.tres"):
					body.physics_material_override = load("res://physics_materials/stone.tres")
				var cs := CollisionShape3D.new()
				cs.shape = tri
				body.add_child(cs)
				m.add_child(body)
		_pieces[key] = {"pivot": pivot, "body": body, "y0": centers[key].y, "mesh": m}
	scene.queue_free()
	loaded = not _pieces.is_empty()


func _adopt_children() -> void:
	# the props, lamps and lights the generator stood on a slab or hung under a spike go with it
	if map == null:
		return
	var targets: Array = []
	for s in span.get("slabs", []):
		var pc = _pieces.get(str(s["node"]))
		if pc == null:
			continue
		targets.append([pc["pivot"], _v3(s["c"]), _v3(s["axis"]), s.get("half", [5, 5, 6])])
	var moved := 0
	for ch in map.get_children():
		if not (ch is Node3D) or ch == self or (ch as Node3D).top_level:
			continue
		var p: Vector3 = (ch as Node3D).global_position
		for tg in targets:
			var d: Vector3 = p - (tg[1] as Vector3)
			var ax: Vector3 = tg[2]
			var side := Vector3.UP.cross(ax).normalized()
			var h: Array = tg[3]
			if absf(d.dot(ax)) <= float(h[2]) + 0.5 and absf(d.dot(side)) <= float(h[0]) + 1.0 and d.y > -float(h[1]) - 1.0 and d.y < 9.0:
				var gt: Transform3D = (ch as Node3D).global_transform
				map.remove_child(ch)
				(tg[0] as Node3D).add_child(ch)
				(ch as Node3D).global_transform = gt
				moved += 1
				break
	# the spikes' green tip lights and lamp dots
	for c in chand.get("cones", []):
		if not bool(c.get("falls", false)):
			continue
		var pc2 = _pieces.get(str(c["node"]))
		if pc2 == null:
			continue
		var tip := _v3(c["tip"])
		for ch2 in map.get_children():
			if not (ch2 is Node3D) or (ch2 as Node3D).top_level:
				continue
			var q: Vector3 = (ch2 as Node3D).global_position
			if absf(q.x - tip.x) < 0.8 and absf(q.z - tip.z) < 0.8 and q.y < tip.y + 0.5 and q.y > tip.y - 8.0:
				var gt2: Transform3D = (ch2 as Node3D).global_transform
				map.remove_child(ch2)
				(pc2["pivot"] as Node3D).add_child(ch2)
				(ch2 as Node3D).global_transform = gt2
				moved += 1
	print("%s %d props and lights ride on the pieces" % [TAG, moved])
	# a replayed fall (a reload, a late join) shows the end state: the event came before this
	if _span_done:
		_span_end_state()
	if _chand_done:
		_chand_end_state()


# ============================================================================ events and streams

func _on_event(key: String, data: Dictionary, replay: bool) -> void:
	if key == "span_fall":
		if replay:
			_span_done = true
			_span_t = -1.0
			_span_end_state()
		elif _span_t < 0.0 and not _span_done:
			_span_t = 0.0
			_log("span falls")
			_span_start()
	elif key == "chand_fall":
		if replay:
			_chand_done = true
			_chand_t = -1.0
			_chand_end_state()
		elif _chand_t < 0.0 and not _chand_done:
			_chand_t = 0.0
			_log("chandelier comes down")


func _send_spf():
	return snappedf(_span_t, 0.01) if _span_t >= 0.0 else null


func _recv_spf(v) -> void:
	if CoopSync.map_is_authority() or v == null:
		return
	var e := float(v)
	if _span_t >= 0.0 and e - _span_t >= 0.4:
		_span_t = e                           # only ever forward


func _send_chf():
	return snappedf(_chand_t, 0.01) if _chand_t >= 0.0 else null


func _recv_chf(v) -> void:
	if CoopSync.map_is_authority() or v == null:
		return
	var e := float(v)
	if _chand_t >= 0.0 and e - _chand_t >= 0.4:
		_chand_t = e


func _log(t: String) -> void:
	log_lines.append([Time.get_ticks_msec(), t])
	print("%s %s" % [TAG, t])


# ============================================================================ per frame

func _players() -> Array:
	var out: Array = []
	if CoopSync.has_method("alive_player_nodes"):
		for p in CoopSync.call("alive_player_nodes"):
			if is_instance_valid(p) and (p as Node3D).is_inside_tree():
				out.append(p)
	return out


func _process(delta: float) -> void:
	if not loaded:
		return
	_clock += delta
	var auth: bool = CoopSync.map_is_authority()
	_tick -= delta
	if auth and _tick <= 0.0:
		_tick = 0.25
		_span_check(0.25)
		_chand_check(0.25)
	if _span_t >= 0.0:
		_span_t += delta
		_span_update()
	if _chand_t >= 0.0:
		_chand_t += delta
		_chand_update()
	_apply_shake(delta)


# ---------------------------------------------------------------------------- THE SPAN

func span_d(p: Vector3) -> float:
	# deck distance from the near stub's edge, along the near half
	return (p - _b0a).dot(_b0t) - float(span.get("near_stub", 20.5))


func span_check_positions(ps: Array) -> bool:
	# public (tests): the trigger rule on a list of positions
	if span.is_empty():
		return false
	var near_left := false
	var out_on := false
	for p in ps:
		var q: Vector3 = p
		var d := span_d(q)
		var lat := absf((q - _b0a).dot(_b0u))
		var deck_y := _b0a.y + _b0t.y * (d + float(span.get("near_stub", 20.5)))
		if d < TRIGGER_D and q.y > -760.0:
			near_left = true
		if d >= TRIGGER_D and lat <= float(span.get("hw", 5.0)) + 0.3 and q.y - deck_y > -0.5 and q.y - deck_y < 2.5 and d < float(span.get("len0", 156.0)):
			out_on = true
	return out_on and not near_left


func _span_check(dt: float) -> void:
	if span.is_empty() or _span_done or _span_t >= 0.0:
		return
	if map != null and (bool(map.get("_debug_tour")) or bool(map.get("_debug_bright")) or bool(map.get("_debug_reload"))):
		return
	var ps: Array = []
	for p in _players():
		ps.append((p as Node3D).global_position)
	if span_check_positions(ps):
		_hold_t += dt
		if _hold_t >= TRIGGER_HOLD:
			CoopSync.map_event("span_fall", {"t0": Time.get_unix_time_from_system(), "q": false})
	else:
		_hold_t = 0.0


func _span_start() -> void:
	var near := _b0a + _b0t * float(span.get("near_stub", 20.5))
	_boom("stone_crack", near, 2.0, 300.0)
	_boom("stone_groan", _b1b, 0.0, 300.0)
	_shake_at(near, 0.25, 0.6, 60.0)


func _span_update() -> void:
	var slabs: Array = span.get("slabs", [])
	var c = Game.climber
	for s in slabs:
		var name := str(s["node"])
		var pc = _pieces.get(name)
		if pc == null:
			continue
		var st := int(_slab_state.get(name, 0))
		if st == 3:
			continue
		var dt := float(s["drop_t"])
		var pivot: Node3D = pc["pivot"]
		var base := _v3(s["c"])
		if _span_t < dt - SHAKE_LEAD:
			continue
		if _span_t < dt:
			if st == 0:
				_slab_state[name] = 1
				_boom("stone_groan", base, -8.0, 120.0)
			pivot.global_position = base + Vector3(randf_range(-0.08, 0.08), randf_range(-0.03, 0.03), randf_range(-0.08, 0.08))
			continue
		if st < 2:
			_slab_state[name] = 2
			if pc["body"] != null:
				(pc["body"] as StaticBody3D).collision_layer = 0
			_release_rope(base, s)
		var t := _span_t - dt
		var fall := 4.9 * t * t
		pivot.global_position = base - Vector3(0, fall, 0)
		var k := clampf(t * t * 0.15, 0.0, 1.0)
		pivot.rotation = Vector3(k * 0.6 * (1.0 if hash(name) % 2 == 0 else -1.0), 0.0, k * 0.35)
		var lands = s.get("lands")
		var land_y := float(lands) if lands != null else base.y - 400.0
		if base.y - fall <= land_y + 2.0:
			_slab_state[name] = 3
			pivot.visible = false
			var hit := Vector3(base.x, land_y, base.z)
			_boom("stone_boom", hit, 6.0, 700.0, true)
			_shake_at(hit, 0.12, 0.5, 200.0)
			if lands != null and _wreck.size() < 8:
				_place_wreck(hit, hash(name))
	if _span_t > float(span.get("end_t", 60.0)):
		_span_t = -1.0
		_span_done = true
		_span_texts()
		_log("span fallen")


func _release_rope(base: Vector3, s: Dictionary) -> void:
	# a claw hooked in a slab that drops lets go (the HangingPlatform.drop_now pattern, R8's one exception)
	var c = Game.climber
	if not is_instance_valid(c) or not (c.activeClimberState is ClimberState_Attached) or not is_instance_valid(c.Rope._claw):
		return
	var h: Array = s.get("half", [5, 5, 6])
	var d: Vector3 = c.Rope._claw.global_position - base
	var ax := _v3(s["axis"])
	var side := Vector3.UP.cross(ax).normalized()
	if absf(d.dot(ax)) <= float(h[2]) + 1.0 and absf(d.dot(side)) <= float(h[0]) + 1.0 and absf(d.y) <= float(h[1]) + 1.0:
		c.set_climber_state(c.defaultClimberState)


func _place_wreck(p: Vector3, seed_: int) -> void:
	if map == null or not map.has_method("ext_instance"):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var n = map.call("ext_instance", "ext/ph/namaqualand_boulder_0%d.glb" % rng.randi_range(2, 6), 0.45)
	if n is Node3D:
		add_child(n)
		(n as Node3D).top_level = true
		(n as Node3D).global_position = p + Vector3(rng.randf_range(-3, 3), -0.6, rng.randf_range(-3, 3))
		(n as Node3D).rotation = Vector3(rng.randf_range(-0.4, 0.4), rng.randf() * TAU, rng.randf_range(-0.4, 0.4))
		(n as Node3D).scale = Vector3.ONE * rng.randf_range(1.6, 2.6)
		_wreck.append(n)


func _span_end_state() -> void:
	for s in span.get("slabs", []):
		var name := str(s["node"])
		var pc = _pieces.get(name)
		if pc == null:
			continue
		_slab_state[name] = 3
		(pc["pivot"] as Node3D).visible = false
		if pc["body"] != null:
			(pc["body"] as StaticBody3D).collision_layer = 0
		var lands = s.get("lands")
		if lands != null and _wreck.size() < 8:
			_place_wreck(Vector3(_v3(s["c"]).x, float(lands), _v3(s["c"]).z), hash(name))
	_span_texts()


func _span_texts() -> void:
	# the near sign now says where the bridge was; the pegs are the way down
	if map == null:
		return
	for ch in map.get_children():
		if ch is Area3D and ch.get("displayed_text") != null:
			var t := str(ch.get("displayed_text"))
			if t.begins_with("A bridge of fallen stone"):
				ch.set("displayed_text", "Where the bridge was, there is nothing. At the other end of this ledge, pegs go down the wall to the shelf below.")


func spawn_filter(p: Vector3) -> Vector3:
	# a respawn over the fallen deck goes to solid rock: the near stub or the far stub
	if span.is_empty() or not _span_done:
		return p
	var d := span_d(p)
	var lat := absf((p - _b0a).dot(_b0u))
	var total := float(span.get("len0", 156.0)) * 2.0
	if d > -1.0 and d < total and lat < 8.0 and absf(p.y - _b0a.y) < 30.0:
		if d < float(span.get("len0", 156.0)) - float(span.get("near_stub", 20.5)):
			return _b0a + _b0t * 8.0 + Vector3(0, 1.2, 0)
		return _b1b - _b1t * 10.0 + Vector3(0, 1.2, 0)
	return p


# ---------------------------------------------------------------------------- THE CHANDELIER

func _chand_check(dt: float) -> void:
	if chand.is_empty() or _chand_done or _chand_t >= 0.0:
		return
	if map != null and (bool(map.get("_debug_tour")) or bool(map.get("_debug_bright"))):
		return
	var trg: Dictionary = chand.get("trigger", {})
	var tp = trg.get("pos")
	if not (tp is Array):
		return
	var tpos := _v3(tp)
	if _chand_arm_t < 0.0:
		for p in _players():
			if (p as Node3D).global_position.distance_to(tpos) <= float(trg.get("r", 45.0)):
				_chand_arm_t = 0.0
				_log("chandelier armed")
				break
		return
	_chand_arm_t += dt
	if _chand_arm_t >= float(trg.get("delay", 6.0)):
		_chand_arm_t = 99999.0
		CoopSync.map_event("chand_fall", {"t0": Time.get_unix_time_from_system(), "q": false})


func _chand_update() -> void:
	for c in chand.get("cones", []):
		if not bool(c.get("falls", false)):
			continue
		var name := str(c["node"])
		var pc = _pieces.get(name)
		if pc == null:
			continue
		var st := int(_cone_state.get(name, 0))
		if st == 3:
			continue
		var crack := float(c.get("crack_t", 0.0))
		var drop := float(c.get("drop_t", crack + 2.0))
		var biggest := int(c.get("k", -1)) == 0
		if biggest:
			crack = drop - 6.0                 # the big one groans for 6 s first
		var pivot: Node3D = pc["pivot"]
		var base := _v3(c["base"])
		if _chand_t < crack:
			continue
		if _chand_t < drop:
			if st == 0:
				_cone_state[name] = 1
				_boom("stone_groan" if biggest else "stone_crack", base, 0.0 if biggest else -2.0, 500.0)
			pivot.global_position = base + Vector3(randf_range(-0.05, 0.05), 0.0, randf_range(-0.05, 0.05))
			pivot.rotation = Vector3(sin(_chand_t * 3.0) * (0.035 if biggest else 0.01), 0.0, 0.0)
			# its green tip flickers
			for l in pivot.find_children("*", "OmniLight3D", true, false):
				(l as OmniLight3D).visible = randf() > 0.3
			continue
		if st < 2:
			_cone_state[name] = 2
			for l in pivot.find_children("*", "OmniLight3D", true, false):
				(l as OmniLight3D).visible = true
		var t := _chand_t - drop
		var fall := 4.9 * t * t
		pivot.global_position = base - Vector3(0, fall, 0)
		var k := clampf(t * t * 0.08, 0.0, 1.0)
		pivot.rotation = Vector3(k * 0.4, 0.0, k * 0.25 * (1.0 if hash(name) % 2 == 0 else -1.0))
		var tip_y := _v3(c["tip"]).y - fall
		var lands = c.get("lands")
		if lands != null and tip_y <= float(lands) + 1.0:
			_cone_state[name] = 3
			pivot.visible = false
			var hit := Vector3(_v3(c["tip"]).x, float(lands), _v3(c["tip"]).z)
			_boom("stone_boom", hit, 8.0 if not biggest else 10.0, 700.0, true)
			_shake_at(hit, 0.12 if not biggest else 0.25, 0.5, 450.0)
		elif lands == null and tip_y < CHAND_VANISH_Y:
			_cone_state[name] = 3
			pivot.visible = false
	if _chand_t > float(chand.get("end_t", 90.0)):
		_chand_t = -1.0
		_chand_done = true
		_log("chandelier down")


func _chand_end_state() -> void:
	for c in chand.get("cones", []):
		if not bool(c.get("falls", false)):
			continue
		var pc = _pieces.get(str(c["node"]))
		if pc == null:
			continue
		_cone_state[str(c["node"])] = 3
		(pc["pivot"] as Node3D).visible = false


# ---------------------------------------------------------------------------- sound and shake

func _boom(kind: String, pos: Vector3, db: float, maxd: float, delayed := false) -> void:
	var ss = map.get("_ss") if map != null else null
	if not is_instance_valid(ss):
		return
	var shots = (ss.get("manifest") as Dictionary).get("oneshots", {}) if ss.get("manifest") is Dictionary else {}
	var list: Array = shots.get(kind, []) if shots is Dictionary else []
	if list.is_empty():
		return
	var e: Dictionary = list[randi() % list.size()]
	var st = ss.call("_stream", str(e.get("file", "")), false)
	if not (st is AudioStream):
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = st
	p.volume_db = float(e.get("db", 0.0)) + db
	p.unit_size = clampf(maxd / 18.0, 8.0, 40.0)
	p.max_distance = maxd
	p.bus = &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
	add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	var delay := 0.0
	var c = Game.climber
	if delayed and is_instance_valid(c) and c.is_inside_tree():
		delay = (c.global_position as Vector3).distance_to(pos) / 343.0
	if delay > 0.05:
		get_tree().create_timer(delay).timeout.connect(func(): if is_instance_valid(p) and p.is_inside_tree(): p.play())
	else:
		p.play()


func _shake_at(pos: Vector3, amount: float, secs: float, radius: float) -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var d := (c.global_position as Vector3).distance_to(pos)
	if d > radius:
		return
	var k := pow(1.0 - d / radius, 2.0)
	_shake = maxf(_shake, amount * k)
	_shake_until = maxf(_shake_until, _clock + secs)


func _apply_shake(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	if _clock < _shake_until and _shake > 0.0:
		cam.h_offset = randf_range(-_shake, _shake) * 0.3
		cam.v_offset = randf_range(-_shake, _shake) * 0.3
	elif cam.h_offset != 0.0 or cam.v_offset != 0.0:
		cam.h_offset = 0.0
		cam.v_offset = 0.0
		_shake = 0.0


func on_exit() -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam != null:
		cam.h_offset = 0.0
		cam.v_offset = 0.0


# ============================================================================ dev test

func _setup_test() -> void:
	var flag = null
	if map != null and map.has_method("dev_flag"):
		flag = map.call("dev_flag", "setpieces.flag")
	if flag == null:
		return
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	var t := SetTest.new()
	t.name = "SetTest"
	t.sp = self
	t.map = map
	t.variant = str(flag).strip_edges().to_lower()
	print("%s test on: %s" % [TAG, t.variant])
	add_child(t)


class SetTest extends Node:
	var sp = null
	var map = null
	var variant := ""
	var t := 0.0
	var phase := 0
	var mark := 0.0
	var n_pass := 0
	var n_total := 0
	var fails: Array = []
	var fell_by := 0.0
	var shots_done: Dictionary = {}

	func ok(key: String, cond: bool, text: String) -> void:
		n_total += 1
		if cond:
			n_pass += 1
			print("%s PASS %s" % [TAG, text])
		else:
			fails.append(key)
			print("%s FAIL %s" % [TAG, text])

	func shot(n: String) -> void:
		if map.has_method("debug_shot"):
			map.call("debug_shot", "user://underdark_set_%s.png" % n)

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree() or phase < 0:
			return
		t += delta
		c.prevent_player_death = true
		if variant == "chand":
			_chand(c)
		else:
			_span(c)

	func _span(c) -> void:
		match phase:
			0:
				if t < 3.0:
					return
				ok("loaded", sp.loaded and sp._pieces.size() >= 22, "pieces loaded: %d" % sp._pieces.size())
				# the trigger rule on synthetic teams
				var a: Vector3 = sp._b0a
				var on_deck: Vector3 = a + sp._b0t * (sp.span.get("near_stub", 20.5) + 31.0) + Vector3(0, 0.5, 0)
				var near_stub: Vector3 = a + sp._b0t * 5.0 + Vector3(0, 0.5, 0)
				var far_stub: Vector3 = sp._b1b - sp._b1t * 8.0 + Vector3(0, 0.5, 0)
				ok("trigger far+deck", sp.span_check_positions([far_stub, on_deck]), "[a player on the far stub, me 31 m out on the deck]: it fires")
				ok("trigger near+deck", not sp.span_check_positions([near_stub, on_deck]), "[a player on the near stub, me 31 m out]: it never fires")
				ok("trigger alone", sp.span_check_positions([on_deck]), "[me alone 31 m out]: it fires")
				# stand on the near stub looking along the deck, then walk out
				map.call("debug_park", near_stub + Vector3(0, 0.8, 0))
				map.call("debug_look", on_deck + Vector3(0, 1.0, 0))
				mark = t
				phase = 1
			1:
				if t - mark < 2.0:
					return
				shot("span_before")
				var a2: Vector3 = sp._b0a
				var deck: Vector3 = a2 + sp._b0t * (sp.span.get("near_stub", 20.5) + 32.0) + Vector3(0, 1.0, 0)
				map.call("debug_park", deck)
				map.call("debug_look", deck - sp._b0t * 40.0)
				mark = t
				phase = 2
			2:
				if sp._span_t >= 0.0 or sp._span_done:
					ok("fired", t - mark < 3.0, "standing 32 m out alone it fired after %.1f s" % (t - mark))
					mark = t
					phase = 3
				elif t - mark > 5.0:
					ok("fired", false, "no collapse 5 s after walking out")
					_finish()
			3:
				if t - mark > 3.5 and not shots_done.has("falling"):
					shots_done["falling"] = true
					shot("span_falling")
				if sp._span_done or t - mark > 70.0:
					var gone := 0
					for k in sp._slab_state.keys():
						if int(sp._slab_state[k]) == 3:
							gone += 1
					ok("all fell", gone >= 22, "%d slabs fell" % gone)
					var store: Dictionary = CoopSync.map_events_for(str(map.get("scene_file_path")))
					ok("stored", store.has("span_fall"), "span_fall is stored for reloads")
					ok("wreck", sp._wreck.size() >= 1, "%d wreck stones on the shelf" % sp._wreck.size())
					var p: Vector3 = sp.spawn_filter(sp._b0a + sp._b0t * 60.0)
					ok("respawn", p.distance_to(sp._b0a) < 15.0, "a respawn over the fallen deck goes to the near stub")
					_finish()

	func _chand(c) -> void:
		match phase:
			0:
				if t < 3.0:
					return
				ok("loaded", sp.loaded, "pieces loaded: %d" % sp._pieces.size())
				var tp: Vector3 = sp._v3(sp.chand["trigger"]["pos"])
				map.call("debug_park", tp + Vector3(0, 1.0, 0))
				var cx := Vector3(tp.x + 120.0, tp.y + 60.0, tp.z)
				var cs: Array = sp.chand.get("cones", [])
				if not cs.is_empty():
					cx = sp._v3(cs[0]["base"]) + Vector3(0, -40, 0)
				map.call("debug_look", cx)
				mark = t
				phase = 1
			1:
				if sp._chand_t >= 0.0:
					ok("fired", t - mark >= 5.5 and t - mark < 9.0, "it came down %.1f s after reaching the landing (want 6)" % (t - mark))
					mark = t
					phase = 2
				elif t - mark > 12.0:
					ok("fired", false, "nothing 12 s after reaching the landing")
					_finish()
			2:
				if t - mark > 12.0 and not shots_done.has("chand"):
					shots_done["chand"] = true
					shot("chand_falling")
				if sp._chand_done or t - mark > 100.0:
					var gone := 0
					var want := 0
					for cc in sp.chand.get("cones", []):
						if bool(cc.get("falls", false)):
							want += 1
							if int(sp._cone_state.get(str(cc["node"]), 0)) == 3:
								gone += 1
					ok("all fell", gone == want and want > 0, "%d of %d spikes came down" % [gone, want])
					ok("alive", float(c.health) > 0.0, "standing on the landing the whole time: never hit")
					_finish()

	func _finish() -> void:
		phase = -1
		var c = Game.climber
		if is_instance_valid(c):
			c.prevent_player_death = false
		if fails.is_empty():
			print("%s test done %d/%d PASS" % [TAG, n_pass, n_total])
		else:
			print("%s test done %d/%d FAIL: %s" % [TAG, n_pass, n_total, ", ".join(PackedStringArray(fails))])
